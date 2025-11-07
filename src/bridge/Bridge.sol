// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------
// Chainlink CCIP
// ---------------------------
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

// ---------------------------
// OpenZeppelin
// ---------------------------
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Bridge - CCIP Burn-Mint controller (Router-facing)
/// @notice 与 Router 交互完成跨链，真正的 burn/mint 由各链的 BurnMintTokenPool 执行。
///         要点：
///           - VToken 的 BRIDGE_ROLE 必须授予各链的 Pool；
///           - Bridge 只在发送前把「要 burn 的额度」授权给本链 Pool；
///           - 询价/发送都走 Router（官方标准做法）。
contract Bridge is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------
    // Roles
    // -----------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // -----------------------
    // Immutable (部署即确定)
    // -----------------------
    IRouterClient public immutable router;   // CCIP Router
    address public immutable linkToken;      // LINK token（payInLink 时使用）

    // -----------------------
    // Configurable params
    // -----------------------
    address public feeCollector;             // 固定服务费接收者
    uint256 public serviceFee;               // 固定服务费（以原生币支付）
    uint256 public minAmount;                // 单笔最小额
    uint256 public maxAmount;                // 单笔最大额
    bool    public allowPayInLink;           // 允许用 LINK 支付 CCIP 费
    bool    public allowPayInNative;         // 允许用原生币支付 CCIP 费

    // token => local burn-mint pool（本链 Pool 地址，用于从 Bridge 拉走额度并 burn）
    mapping(address => address) public tokenPools;
    address[] public supportedTokens;

    // -----------------------
    // Events
    // -----------------------
    event TokenPoolRegistered(address indexed token, address indexed pool);
    event TokenPoolRemoved(address indexed token);

    event LimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event PayMethodUpdated(bool nativeAllowed, bool linkAllowed);
    event ServiceFeeUpdated(uint256 newFee, address newCollector);

    /// 发送侧关键审计事件（便于对账与客服定位）
    event TransferInitiated(
        bytes32 indexed messageId,
        address indexed sender,
        address indexed token,
        address pool,
        uint64  dstSelector,
        address receiver,
        uint256 amount,
        bool    payInLink,
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

    // -----------------------
    // Ctor
    // -----------------------
    constructor(address admin_, address router_, address link_) {
        if (admin_  == address(0) || router_ == address(0) || link_ == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        router = IRouterClient(router_);
        linkToken = link_;

        // 默认参数（可后续修改）
        feeCollector     = admin_;
        serviceFee       = 0.001 ether;
        minAmount        = 1;
        maxAmount        = type(uint256).max;
        allowPayInLink   = true;
        allowPayInNative = true;
    }

    // ============================================================
    //                         Views
    // ============================================================
    function isTokenSupported(address token) public view returns (bool) {
        return tokenPools[token] != address(0);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /// @notice 询价：Router.getFee（把要跨的 token 放到 tokenAmounts）
    function quoteFee(
        address token,
        uint64  dstSelector,
        address receiver,
        uint256 amount,
        bool    payInLink
    ) external view returns (uint256 ccipFee, uint256 totalFee) {
        if (!isTokenSupported(token)) revert TokenNotSupported(token);
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        if (payInLink && !allowPayInLink) revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        Client.EVM2AnyMessage memory m = _buildMessage(token, receiver, amount, payInLink);
        ccipFee  = router.getFee(dstSelector, m);
        totalFee = ccipFee + serviceFee;
    }

    // ============================================================
    //                         Send (核心)
    // ============================================================
    /// @notice 发起 burn-mint 跨链（发送侧）
    /// @dev 前端需确保：先对 Bridge 执行 `approve(token, amount)`；
    ///      payInLink=true 还需对 Bridge 执行 `approve(LINK, ccipFee)`。
    function sendToken(
        address token,
        uint64  dstSelector,
        address receiver,
        uint256 amount,
        bool    payInLink
    ) external payable whenNotPaused nonReentrant returns (bytes32 messageId) {
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();
        if (!isTokenSupported(token)) revert TokenNotSupported(token);
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        if (payInLink && !allowPayInLink) revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        // 1) 从用户拉取要跨的 token 到 Bridge
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // 2) Bridge -> Pool 授权“要 burn 的额度”（后续由 Router 驱动的 Pool 来拉走并 burn）
        address pool = tokenPools[token];
        IERC20(token).forceApprove(pool, 0);
        IERC20(token).forceApprove(pool, amount);

        // 3) 构造消息并询价
        Client.EVM2AnyMessage memory m = _buildMessage(token, receiver, amount, payInLink);
        uint256 ccipFee = router.getFee(dstSelector, m);

        // 4) 处理固定服务费 & 费用路径
        uint256 expectedMsgValue = serviceFee + (payInLink ? 0 : ccipFee);
        if (msg.value != expectedMsgValue) revert InsufficientMsgValue(expectedMsgValue, msg.value);

        if (serviceFee > 0 && feeCollector != address(0)) {
            (bool ok, ) = payable(feeCollector).call{value: serviceFee}("");
            require(ok, "service fee transfer failed");
        }

        if (payInLink) {
            // 用 LINK 支付：从用户拉到 Bridge，再授权给 Router
            IERC20(linkToken).safeTransferFrom(msg.sender, address(this), ccipFee);
            IERC20(linkToken).forceApprove(address(router), 0);
            IERC20(linkToken).forceApprove(address(router), ccipFee);
            messageId = router.ccipSend(dstSelector, m);
        } else {
            // 用原生币支付：随调用附带 ccipFee
            messageId = router.ccipSend{value: ccipFee}(dstSelector, m);
        }

        emit TransferInitiated(
            messageId,
            msg.sender,
            token,
            pool,
            dstSelector,
            receiver,
            amount,
            payInLink,
            ccipFee,
            serviceFee
        );
    }

    // ============================================================
    //                       Admin operations
    // ============================================================
    function registerTokenPool(address token, address pool)
        external onlyRole(ADMIN_ROLE)
    {
        if (token == address(0) || pool == address(0)) revert ZeroAddress();
        if (tokenPools[token] == address(0)) {
            supportedTokens.push(token);
        }
        tokenPools[token] = pool;
        emit TokenPoolRegistered(token, pool);
    }

    function removeTokenPool(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        delete tokenPools[token];

        // 移出数组（不保持顺序）
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
        emit TokenPoolRemoved(token);
    }

    function setServiceFee(uint256 newFee, address newCollector)
        external onlyRole(ADMIN_ROLE)
    {
        if (newCollector == address(0)) revert ZeroAddress();
        serviceFee  = newFee;
        feeCollector = newCollector;
        emit ServiceFeeUpdated(newFee, newCollector);
    }

    function setLimits(uint256 _min, uint256 _max)
        external onlyRole(ADMIN_ROLE)
    {
        if (_min == 0 || _min > _max) revert InvalidAmount(_min);
        minAmount = _min;
        maxAmount = _max;
        emit LimitsUpdated(_min, _max);
    }

    function setPayMethod(bool _allowNative, bool _allowLink)
        external onlyRole(ADMIN_ROLE)
    {
        allowPayInNative = _allowNative;
        allowPayInLink   = _allowLink;
        emit PayMethodUpdated(_allowNative, _allowLink);
    }

    function pause()  external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ============================================================
    //                       Internal helper
    // ============================================================
    /// @dev 构造 Router 所需消息：把要跨的 token 放入 tokenAmounts
    function _buildMessage(
        address token,
        address receiver,
        uint256 amount,
        bool    payInLink
    ) internal view returns (Client.EVM2AnyMessage memory m) {
        Client.EVMTokenAmount[] memory toks = new Client.EVMTokenAmount[](1);
        toks[0] = Client.EVMTokenAmount({token: token, amount: amount});

        m = Client.EVM2AnyMessage({
            receiver:  abi.encode(receiver),
            data:      "", // 纯 token 传输无需 data；如需追踪可放 transferId
            tokenAmounts: toks,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            feeToken:  payInLink ? linkToken : address(0)
        });
    }
}
