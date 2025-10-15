// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
================================================================================
FaucetV2  ——（EIP-712 凭证 + 位图防重放；链上最小可信边界）
--------------------------------------------------------------------------------
【自托管 Relayer 代付 gas】
- 链上只做验签、位图防重放、白名单、每日系统上限、余额检查与转账。
- 是否必须买票、每日次数/软上限、黑名单/KYC/KYT、设备/IP 风控、Relayer 余额阈值等全部放到链下。

【链下待办 / TODO（交给后端 & codex）】
1) 凭证签发服务（Signer）
   - 读链：tokenWhitelist、tokenDailyCap、合约余额、passPriceWei；
   - 风控：黑名单、KYC/KYT、设备/IP 风险分、每日签发上限、软上限等；
   - 生成 EIP-712 Claim（user, token, amount, day, nonce, deadline, pass）并用 SIGNER_ROLE 地址签名；
   - 维护链下 nonce 与对账日志。
2) Relayer 自托管 & 代付
   - HSM/KMS/签名机托管私钥；暴露受控 API；余额阈值切换“需先买票”模式；队列/限流/退避/报警；
   - 监听 Claimed/PassPaid 事件对账。
3) 买票与对账
   - 用户调用 payPass()（仅收款+事件）；后端监听并标记“当日已购票”；余额不足模式下仅对已购票地址签发凭证。

【未来可能演进（需要改合约时再做）】
- 如需“链上硬闸必须买票/必须 Forwarder/只能 Relayer”再加开关或 EIP-2771，当前保持最小边界与低复杂度。

================================================================================
*/

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FaucetV2（EIP-712 验签 + 位图防重放）
/// @notice 链上最小可信边界：验签、防重放、白名单、每日系统上限、余额检查与转账；
///         payPass() 仅收款+事件（不找零），其是否“必须”由链下策略控制；
///         角色：DEFAULT_ADMIN_ROLE 配置参数与角色；FUNDER_ROLE 入金；TREASURER_ROLE 归集；SIGNER_ROLE 验签信任根。
contract FaucetV2 is AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    // ===== 常量/角色 =====
    uint256 private constant DAY = 1 days;
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE"); // 入金
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE"); // 归集
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE"); // 凭证签发者（EOA/HSM 多签等）

    // EIP-712 类型哈希：Claim(address user,address token,uint256 amount,uint64 day,uint256 nonce,uint256 deadline,bool pass)
    bytes32 private constant _CLAIM_TYPEHASH = keccak256(
        "Claim(address user,address token,uint256 amount,uint64 day,uint256 nonce,uint256 deadline,bool pass)"
    );

    // ===== 事件 =====
    event Claimed(address indexed user, address indexed token, uint256 amount, uint64 day, uint256 nonce);
    event PassPaid(address indexed payer, uint256 amount, uint64 day); // 买票“收款”事件（链下监听）
    event FundsSwept(address indexed asset, address indexed to, uint256 amount); // asset=address(0) 表示 ETH
    event ParamUpdated(bytes32 indexed key, address indexed token, uint256 value);

    // ===== 存储（最小可信边界） =====
    address public treasury; // 国库地址
    mapping(address => bool) public tokenWhitelist; // Token 白名单（必须为 true 才能发放）
    mapping(address => uint256) public tokenDailyCap; // Token 系统日上限（=0 表示无限）

    struct DailyIssued {
        uint64 day;
        uint192 amount;
    } // 打包紧凑：节省 SSTORE（64+192=1 槽）

    mapping(address => DailyIssued) private _issuedToday; // token => 当日已发

    // 防重放：位图 used[user][word]，word = nonce >> 8（每个 word 覆盖 256 连续 nonce）
    mapping(address => mapping(uint256 => uint256)) private _usedNonceBitmap;

    // （可选）链上买票价格（wei）；=0 表示关闭链上买票入口（免费期）
    uint256 public passPriceWei;

    // ===== 自定义错误（省 gas） =====
    error TOKEN_NOT_ALLOWED(address token);
    error VAULT_LOW(address token, uint256 need, uint256 bal);
    error OVER_DAILY_CAP(address token, uint256 next, uint256 cap, uint64 day);
    error INVALID_SIGNER(address recovered);
    error EXPIRED(uint256 nowTs, uint256 deadline);
    error DAY_MISMATCH(uint64 got, uint64 want);
    error NONCE_USED(address user, uint256 nonce);
    error TREASURY_UNSET();
    error SWEEP_ETH_INVALID();
    error SWEEP_FAIL();
    error PRICE_ZERO();
    error UNDERPAY();
    error ZERO_ADDR();

    // ===== 构造 =====
    constructor(address admin, address treasury_, address initialSigner, string memory name_, string memory version_)
        EIP712(name_, version_)
    {
        if (admin == address(0) || treasury_ == address(0)) revert ZERO_ADDR();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FUNDER_ROLE, admin);
        _grantRole(TREASURER_ROLE, admin);
        if (initialSigner != address(0)) _grantRole(SIGNER_ROLE, initialSigner);
        treasury = treasury_;
        emit ParamUpdated("TREASURY", treasury_, 0);
    }

    // ===== 视图 =====
    function currentDay() public view returns (uint64) {
        return uint64(block.timestamp / DAY);
    }

    /// @notice 查询合约当前持有的某 Token 余额
    function balanceOfToken(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _isNonceUsed(address user, uint256 nonce) internal view returns (bool) {
        uint256 word = nonce >> 8;
        uint256 bit = 1 << (nonce & 255);
        return (_usedNonceBitmap[user][word] & bit) != 0;
    }

    // ===== 管理：白名单/上限/价格/国库 =====
    function setTokenWhitelist(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenWhitelist[token] = allowed;
        emit ParamUpdated("TOKEN_WHITELIST", token, allowed ? 1 : 0);
    }

    function setTokenDailyCap(address token, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenDailyCap[token] = cap;
        emit ParamUpdated("TOKEN_DAILY_CAP", token, cap);
    }

    function setPassPriceWei(uint256 price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        passPriceWei = price; // 0=免费期；>0=收费期
        emit ParamUpdated("PASS_PRICE", address(0), price);
    }

    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert ZERO_ADDR();
        treasury = t;
        emit ParamUpdated("TREASURY", t, 0);
    }

    // ===== 入金/归集 =====
    function fund(address token, uint256 amount) external onlyRole(FUNDER_ROLE) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function sweepETH(uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        if (treasury == address(0)) revert TREASURY_UNSET();
        if (amount == 0 || amount > address(this).balance) revert SWEEP_ETH_INVALID();
        (bool ok,) = payable(treasury).call{value: amount}("");
        if (!ok) revert SWEEP_FAIL();
        emit FundsSwept(address(0), treasury, amount);
    }

    function sweepToken(address token, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        IERC20(token).safeTransfer(treasury, amount);
        emit FundsSwept(token, treasury, amount);
    }

    // ===== 可选：链上买票，仅收款 + 事件（不找零；多付留存）=====
    function payPass() external payable nonReentrant whenNotPaused {
        uint256 price = passPriceWei;
        if (price == 0) revert PRICE_ZERO();
        if (msg.value < price) revert UNDERPAY();

        uint64 d = currentDay();
        // 不找零：多付部分留在合约作为收入（由 sweepETH 归集）
        emit PassPaid(msg.sender, msg.value, d);
    }

    // ======= 参数结构体：用于降低 claimWithSig 的栈深 =======
    struct ClaimReq {
        address user;
        address token;
        uint256 amount;
        uint64 day;
        uint256 nonce;
        uint256 deadline;
        bool pass;
    }

    // ===== 内部：单独的事件封装，减少外层函数的栈压力 =====
    function _emitClaim(address u, address t, uint256 a, uint64 d, uint256 n) private {
        emit Claimed(u, t, a, d, n);
    }

    // ===== 核心：凭证领取（Relayer 代付场景：由 Relayer 发交易） =====
    function claimWithSig(ClaimReq calldata p, bytes calldata sig) external nonReentrant whenNotPaused {
        // --- 快速校验（直接用 p.字段减少临时变量） ---
        if (!tokenWhitelist[p.token]) revert TOKEN_NOT_ALLOWED(p.token);

        uint64 dNow = currentDay();
        if (p.day != dNow) revert DAY_MISMATCH(dNow, p.day);
        if (block.timestamp > p.deadline) revert EXPIRED(block.timestamp, p.deadline);

        // --- 防重放：位图（放入局部作用域，缩短 w/b/used 生命周期） ---
        {
            uint256 w = p.nonce >> 8;
            uint256 b = 1 << (p.nonce & 255);
            uint256 used = _usedNonceBitmap[p.user][w];
            if ((used & b) != 0) revert NONCE_USED(p.user, p.nonce);
            _usedNonceBitmap[p.user][w] = used | b;
        }

        // --- EIP-712 验签（放入作用域，digest/signer 生命周期最短） ---
        {
            bytes32 digest = _hashTypedDataV4(
                keccak256(abi.encode(_CLAIM_TYPEHASH, p.user, p.token, p.amount, p.day, p.nonce, p.deadline, p.pass))
            );
            address signer = ECDSA.recover(digest, sig);
            if (!hasRole(SIGNER_ROLE, signer)) revert INVALID_SIGNER(signer);
        }

        // --- 系统日上限护栏（按 token；合约维度） ---
        DailyIssued storage di = _issuedToday[p.token];
        if (di.day != dNow) {
            di.day = dNow;
            di.amount = 0;
        }
        uint256 next = uint256(di.amount) + p.amount;

        uint256 cap = tokenDailyCap[p.token];
        if (cap != 0 && next > cap) revert OVER_DAILY_CAP(p.token, next, cap, dNow);

        // --- 余额护栏（内联，避免持有额外的局部变量） ---
        if (IERC20(p.token).balanceOf(address(this)) < p.amount) {
            revert VAULT_LOW(p.token, p.amount, IERC20(p.token).balanceOf(address(this)));
        }

        // --- Effects & Interactions ---
        di.amount = uint192(next);
        IERC20(p.token).safeTransfer(p.user, p.amount);

        // --- 事件放到内部函数单独调用帧，避免与外层变量堆叠 ---
        _emitClaim(p.user, p.token, p.amount, dNow, p.nonce);
    }

    // ===== 熔断 =====
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ===== 接收 ETH（买票收入、意外注入）=====
    receive() external payable {}
}
