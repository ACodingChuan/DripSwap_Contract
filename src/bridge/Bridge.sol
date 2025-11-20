// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------
// Chainlink CCIP
// ---------------------------
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

// ---------------------------
// OpenZeppelin
// ---------------------------
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ---------------------------
// Uniswap Permit2 (SignatureTransfer facet)
// ---------------------------
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";

/// @title Bridge - CCIP Burn-Mint controller (Router-facing)
/// @notice 通过 CCIP 进行跨链，Bridge 负责：
///         - 从用户处拉取 vToken + 可选 LINK（fee）
///         - 调用 Router.ccipSend
///         - 真正 burn/mint 由各链的 BurnMintTokenPool 完成
contract Bridge is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------
    // Roles
    // -----------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // -----------------------
    // Immutable
    // -----------------------
    IRouterClient public immutable router; // CCIP Router
    address public immutable linkToken; // LINK token（payInLink 时使用）
    ISignatureTransfer public immutable permit2; // Uniswap Permit2

    // -----------------------
    // Configurable params
    // -----------------------
    address public feeCollector; // 固定服务费接收者
    uint256 public serviceFee; // 固定服务费（以原生币支付）
    uint256 public minAmount; // 单笔最小额
    uint256 public maxAmount; // 单笔最大额
    bool public allowPayInLink; // 允许用 LINK 支付 CCIP 费
    bool public allowPayInNative; // 允许用原生币支付 CCIP 费

    // token => local burn-mint pool
    mapping(address => address) public tokenPools;

    // -----------------------
    // Events
    // -----------------------
    event TokenPoolRegistered(address indexed token, address indexed pool);
    event TokenPoolRemoved(address indexed token);

    event LimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event PayMethodUpdated(bool nativeAllowed, bool linkAllowed);
    event ServiceFeeUpdated(uint256 newFee, address newCollector);

    event TransferInitiated(
        bytes32 indexed messageId,
        address indexed sender,
        address indexed token,
        address pool,
        uint64 dstSelector,
        address receiver,
        uint256 amount,
        bool payInLink,
        uint256 ccipFee,
        uint256 serviceFeePaid
    );

    // -----------------------
    // Errors
    // -----------------------
    error ZeroAddress();
    error InvalidAmount(uint256);
    error TokenNotSupported(address token);
    error PaymentMethodDisabled();
    error InsufficientMsgValue(uint256 expected, uint256 provided);
    error PermitAmountTooLow(uint256 permitted, uint256 required);

    /// @notice 前端传入的 batch-permit + 签名
    struct PermitInput {
        ISignatureTransfer.PermitBatchTransferFrom permit;
        bytes signature;
    }

    // -----------------------
    // Constructor
    // -----------------------
    constructor(address admin_, address router_, address link_, address permit2_) {
        if (admin_ == address(0) || router_ == address(0) || link_ == address(0) || permit2_ == address(0)) {
            revert ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        router = IRouterClient(router_);
        linkToken = link_;
        permit2 = ISignatureTransfer(permit2_);

        // 默认参数（可后续修改）
        feeCollector = admin_;
        serviceFee = 0.001 ether;
        minAmount = 1;
        maxAmount = type(uint256).max;
        allowPayInLink = true;
        allowPayInNative = true;
    }

    // ============================================================
    //                         Views
    // ============================================================
    function isTokenSupported(address token) public view returns (bool) {
        return tokenPools[token] != address(0);
    }

    /// @notice 询价：Router.getFee（把要跨的 token 放到 tokenAmounts）
    function quoteFee(address token, uint64 dstSelector, address receiver, uint256 amount, bool payInLink)
        external
        view
        returns (uint256 ccipFee)
    {
        if (tokenPools[token] == address(0)) revert TokenNotSupported(token);
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        if (payInLink && !allowPayInLink) revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        Client.EVM2AnyMessage memory m = _buildMessage(token, receiver, amount, payInLink);
        ccipFee = router.getFee(dstSelector, m);
    }

    // ============================================================
    //                         Send (核心)
    // ============================================================
    /// @notice 发起 burn-mint 跨链（发送侧）
    /// @dev
    ///   - 支持 batch-permit：一次签名覆盖 token + LINK；
    ///   - 当 `permitInput.signature.length == 0` 时，自动退化为老式 safeTransferFrom。
    function sendToken(
        address token,
        uint64 dstSelector,
        address receiver,
        uint256 amount,
        bool payInLink,
        PermitInput calldata permitInput
    ) external payable whenNotPaused nonReentrant returns (bytes32 messageId) {
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();

        address pool = tokenPools[token];
        if (pool == address(0)) revert TokenNotSupported(token);
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        if (payInLink && !allowPayInLink) revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        // 1) 构造消息并询价
        Client.EVM2AnyMessage memory m = _buildMessage(token, receiver, amount, payInLink);
        uint256 ccipFee = router.getFee(dstSelector, m);

        // 2) 处理固定服务费 & 费用路径（原生币 / LINK）
        uint256 expectedMsgValue = serviceFee + (payInLink ? 0 : ccipFee);
        if (msg.value < expectedMsgValue) {
            revert InsufficientMsgValue(expectedMsgValue, msg.value);
        }

        uint256 collectorAmount = msg.value - (payInLink ? 0 : ccipFee);
        if (collectorAmount > 0 && feeCollector != address(0)) {
            (bool ok,) = payable(feeCollector).call{value: collectorAmount}("");
            require(ok, "service fee transfer failed");
        }

        uint256 serviceFeePaid = collectorAmount;

        // 3) 拉取资产到 Bridge（支持 batch-permit）

        uint256 arrayLength = payInLink ? 2 : 1;
        address[] memory assets = new address[](arrayLength);
        uint256[] memory assetAmounts = new uint256[](arrayLength);

        // 设置共同的值
        assets[0] = token;
        assetAmounts[0] = amount;

        // 如果需要支付LINK，设置第二个元素
        if (payInLink) {
            assets[1] = linkToken;
            assetAmounts[1] = ccipFee;
        }

        _collectWithPermit(assets, assetAmounts, permitInput);

        // 4) Bridge -> Router 授权额度
        IERC20(token).forceApprove(address(router), 0);
        IERC20(token).forceApprove(address(router), amount);

        if (payInLink) {
            IERC20(linkToken).forceApprove(address(router), 0);
            IERC20(linkToken).forceApprove(address(router), ccipFee);
            messageId = router.ccipSend(dstSelector, m);
        } else {
            messageId = router.ccipSend{value: ccipFee}(dstSelector, m);
        }

        emit TransferInitiated(
            messageId, msg.sender, token, pool, dstSelector, receiver, amount, payInLink, ccipFee, serviceFeePaid
        );
    }

    // ============================================================
    //                       Admin operations
    // ============================================================
    function registerTokenPool(address token, address pool) external onlyRole(ADMIN_ROLE) {
        if (token == address(0) || pool == address(0)) revert ZeroAddress();
        tokenPools[token] = pool;
        emit TokenPoolRegistered(token, pool);
    }

    function removeTokenPool(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        delete tokenPools[token];
        emit TokenPoolRemoved(token);
    }

    function setServiceFee(uint256 newFee, address newCollector) external onlyRole(ADMIN_ROLE) {
        if (newCollector == address(0)) revert ZeroAddress();
        serviceFee = newFee;
        feeCollector = newCollector;
        emit ServiceFeeUpdated(newFee, newCollector);
    }

    function setLimits(uint256 _min, uint256 _max) external onlyRole(ADMIN_ROLE) {
        if (_min == 0 || _min > _max) revert InvalidAmount(_min);
        minAmount = _min;
        maxAmount = _max;
        emit LimitsUpdated(_min, _max);
    }

    function setPayMethod(bool _allowNative, bool _allowLink) external onlyRole(ADMIN_ROLE) {
        allowPayInNative = _allowNative;
        allowPayInLink = _allowLink;
        emit PayMethodUpdated(_allowNative, _allowLink);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ============================================================
    //                       Internal helpers
    // ============================================================
    /// @dev 构造 Router 所需消息：把要跨的 token 放入 tokenAmounts
    function _buildMessage(address token, address receiver, uint256 amount, bool payInLink)
        internal
        view
        returns (Client.EVM2AnyMessage memory m)
    {
        Client.EVMTokenAmount[] memory toks = new Client.EVMTokenAmount[](1);
        toks[0] = Client.EVMTokenAmount({token: token, amount: amount});

        m = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "", // 纯 token 传输无需 data；如需追踪可放 transferId
            tokenAmounts: toks,
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true})),
            feeToken: payInLink ? linkToken : address(0)
        });
    }

    function _collectWithPermit(address[] memory tokens, uint256[] memory amounts, PermitInput calldata permitInput)
        internal
    {
        uint256 len = tokens.length;
        require(len == amounts.length, "tokens/amounts length mismatch");
        if (len == 0) return;

        // 1) 没签名：完全走老式 safeTransferFrom
        if (permitInput.signature.length == 0) {
            for (uint256 i = 0; i < len; ++i) {
                uint256 amt = amounts[i];
                if (amt == 0) continue;
                IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amt);
            }
            return;
        }

        // 2) 有签名：全部交给 Permit2 处理
        // 要求前端保证：
        //   - permit.permitted.length == len
        //   - permit.permitted[i].token 对应 tokens[i]
        //   - permit.permitted[i].amount >= amounts[i]
        //
        // 如果这些对不上：
        //   - 要么 Permit2 自己 revert（LengthMismatch / InvalidAmount）
        //   - 要么转错 token，属于前端逻辑错误

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](len);

        address self = address(this);
        for (uint256 i = 0; i < len; ++i) {
            details[i] = ISignatureTransfer.SignatureTransferDetails({
                to: self,
                requestedAmount: amounts[i] // 可以为 0，Permit2 会忽略
            });
        }

        // 一次性从 msg.sender 拉走所有 token（长度 1 或 2 都可以）
        permit2.permitTransferFrom(permitInput.permit, details, msg.sender, permitInput.signature);
    }
}
