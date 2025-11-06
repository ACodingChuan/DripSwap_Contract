// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ---------------------------
// Minimal interface to CCIP Burn-Mint Pool (v1.5.x)
// ---------------------------
interface IBurnMintTokenPoolMinimal {
    /// Quote CCIP fee for a burn-mint send.
    function quoteSend(
        uint64 dstChainSelector,
        address receiver,
        uint256 amount,
        bool payInLink
    ) external view returns (uint256 fee);

    /// Perform burn on source chain and send message to dst chain.
    function send(
        uint64 dstChainSelector,
        address receiver,
        uint256 amount,
        bool payInLink
    ) external payable returns (bytes32 messageId);

    /// Introspection helpers (optional but handy)
    function token() external view returns (address);
    function router() external view returns (address);
    function linkToken() external view returns (address);
}

// ---------------------------
// OpenZeppelin
// ---------------------------
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Bridge (controller) for CCIP Burn–Mint Pools
/// @notice This contract does **not** interact with CCIP Router directly.
///         It routes user requests to the official BurnMintTokenPool.
///         Flow:
///           1) user approves Bridge for `token` (and LINK if payInLink)
///           2) Bridge pulls assets from user, approves Pool
///           3) Bridge calls `pool.send(...)` (pool burns & sends)
contract Bridge is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Roles ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============ Params ============
    /// @dev optional cached LINK token address (read from any registered pool on demand)
    address public linkToken;                 // Filled on first pool registration or manually
    address public feeCollector;              // 收取固定服务费的地址
    uint256 public serviceFee;                // 固定服务费（以原生币计，发送侧支付给 feeCollector）
    uint256 public minAmount;                 // 单笔最小额
    uint256 public maxAmount;                 // 单笔最大额
    bool    public allowPayInLink;            // 是否允许用 LINK 支付 CCIP 传输费
    bool    public allowPayInNative;          // 是否允许用原生币支付 CCIP 传输费

    // token => local burn-mint pool
    mapping(address => address) public tokenPools;
    address[] public supportedTokens;

    // ============ Events ============
    event TokenPoolRegistered(address indexed token, address indexed pool);
    event TokenPoolRemoved(address indexed token);
    event LimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event PayMethodUpdated(bool nativeAllowed, bool linkAllowed);
    event ServiceFeeUpdated(uint256 newFee, address newCollector);

    event TransferQuoted(
        address indexed token,
        uint64 indexed dstSelector,
        address indexed receiver,
        uint256 amount,
        bool payInLink,
        uint256 ccipFee,
        uint256 totalFee
    );

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

    // ============ Errors ============
    error ZeroAddress();
    error InvalidAmount(uint256);
    error TokenNotSupported(address token);
    error PoolMismatch(address token, address expected);
    error PaymentMethodDisabled();
    error InsufficientMsgValue(uint256 expected, uint256 provided);

    // ============ Ctor ============
    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        feeCollector    = admin_;
        serviceFee      = 0.001 ether;
        minAmount       = 1;
        maxAmount       = type(uint256).max;
        allowPayInLink  = true;
        allowPayInNative= true;
    }

    // ============================================================
    //                       View helpers
    // ============================================================
    function isTokenSupported(address token) public view returns (bool) {
        return tokenPools[token] != address(0);
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /// @notice Quote (ccipFee, totalFee) using the target pool’s `quoteSend`.
    function quoteFee(
        address token,
        uint64 dstSelector,
        address receiver,
        uint256 amount,
        bool payInLink
    ) external view returns (uint256 ccipFee, uint256 totalFee) {
        address pool = tokenPools[token];
        if (pool == address(0)) revert TokenNotSupported(token);
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        if (payInLink && !allowPayInLink) revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        ccipFee = IBurnMintTokenPoolMinimal(pool).quoteSend(
            dstSelector, receiver, amount, payInLink
        );
        totalFee = ccipFee + serviceFee;
    }

    // ============================================================
    //                     Core send (burn-mint)
    // ============================================================
    /// @notice Send `token` to `receiver` on dst chain via its burn-mint pool.
    /// @dev Requirements for caller (front-end需提示)：
    ///      - 先对 Bridge 执行 `approve(token, amount)`
    ///      - 若 `payInLink=true`，还需 `approve(LINK, ccipFee)`
    ///      - `msg.value` 必须 == （payInLink ? serviceFee : (serviceFee + ccipFee)）
    function sendToken(
        address token,
        uint64  dstSelector,
        address receiver,
        uint256 amount,
        bool    payInLink
    ) external payable whenNotPaused nonReentrant returns (bytes32 messageId) {
        if (receiver == address(0) || token == address(0)) revert ZeroAddress();
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount(amount);
        address pool = tokenPools[token];
        if (pool == address(0)) revert TokenNotSupported(token);

        if (payInLink && !allowPayInLink)   revert PaymentMethodDisabled();
        if (!payInLink && !allowPayInNative) revert PaymentMethodDisabled();

        // 预估 CCIP 费用（由池计算）
        uint256 ccipFee = IBurnMintTokenPoolMinimal(pool).quoteSend(
            dstSelector, receiver, amount, payInLink
        );

        // ====== 1) 处理固定服务费 ======
        uint256 expectedMsgValue = serviceFee + (payInLink ? 0 : ccipFee);
        if (msg.value != expectedMsgValue) {
            revert InsufficientMsgValue(expectedMsgValue, msg.value);
        }
        if (serviceFee > 0 && feeCollector != address(0)) {
            (bool ok, ) = feeCollector.call{value: serviceFee}("");
            require(ok, "service fee transfer failed");
        }

        // ====== 2) 从用户处拉取代币并授权给池 ======
        // 池的 send() 会以 msg.sender=Bridge 的身份，执行 transferFrom(Bridge -> Pool) 然后 burn。
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(pool, amount);

        // ====== 3) 支付 CCIP 传输费 ======
        if (payInLink) {
            // 从用户拉取 LINK 给 Bridge，然后授权给池；池在 send() 中会从 Bridge 拉走 LINK
            address link = _ensureLinkToken(pool);
            IERC20(link).safeTransferFrom(msg.sender, address(this), ccipFee);
            IERC20(link).forceApprove(pool, ccipFee);

            // 调用池，不携带原生币
            messageId = IBurnMintTokenPoolMinimal(pool).send(
                dstSelector, receiver, amount, true
            );
        } else {
            // 原生币支付：把 ccipFee 原样随调用转给池
            messageId = IBurnMintTokenPoolMinimal(pool).send{value: ccipFee}(
                dstSelector, receiver, amount, false
            );
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

        // 首次注册时缓存 LINK 地址（仅为省事，也可手动 set）
        if (linkToken == address(0)) {
            // best-effort：若池实现了 linkToken()，读取一次
            try IBurnMintTokenPoolMinimal(pool).linkToken() returns (address l) {
                linkToken = l;
            } catch {}
        }

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
        serviceFee = newFee;
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

    function setLinkToken(address link) external onlyRole(ADMIN_ROLE) {
        if (link == address(0)) revert ZeroAddress();
        linkToken = link;
    }

    function pause()  external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ============================================================
    //                       Internal helpers
    // ============================================================
    function _ensureLinkToken(address pool) internal returns (address) {
        if (linkToken != address(0)) return linkToken;
        // 回退：尽力从池读取一次
        try IBurnMintTokenPoolMinimal(pool).linkToken() returns (address l) {
            linkToken = l;
            return l;
        } catch {
            revert ZeroAddress();
        }
    }
}
