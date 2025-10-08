// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Faucet
/// @notice 水龙头合约：
///  - 【冷却】同一用户×同一 Token：自然日仅一次 + 滚动秒级冷却（双闸）
///  - 【系统上限】每 Token 的“合约级每日总上限”，按自然日自动归零
///  - 【通行证】可选的当日通行证（付费购买，支持多付找零；退款失败则整笔回滚）
///  - 【权限分离】Owner 做治理；FUNDER_ROLE 负责入金；TREASURER_ROLE 负责财务归集
///  - 【风控】黑名单 + 一键熔断（Pausable）
///  - 【归集】支持 sweepEth / sweepToken（仅当 Token 下线后才允许清扫，避免误扫）
contract Faucet is Ownable2Step, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ===== 常量&角色 =====
    uint256 private constant DAY = 1 days;
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");       // 资方充值
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");  // 财务归集

    // ===== 配置与状态结构 =====

    /// @notice 每种 Token 的配额配置与“自然日”发放状态
    struct TokenConfig {
        uint128 perClaim;        // 单次领取额度；0 表示停用
        uint128 dailyCap;        // 日上限；0 表示无限制
        uint128 issuedToday;     // 当日已发放量
        uint64 lastIssuedDay;    // 最近一次重置时的自然日序号
    }


    // ===== 事件 =====
    event PassPurchased(address indexed buyer, uint256 amountPaid, uint256 dayIndex);
    event VaultFunded(address indexed token, address indexed funder, uint256 amount);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    /// @notice 资金归集事件；asset=address(0) 表示 ETH
    event FundsSwept(address indexed asset, address indexed to, uint256 amount);
    event Claimed(address indexed token, address indexed user, uint256 amount, address indexed to);
    /// @dev 参数更新事件（key 语义见具体 setter；当 key="TREASURY" 时，token 字段承载“新国库地址”）
    event ParamUpdated(bytes32 indexed key, address indexed token, uint256 value);

    // ===== 全局配置/状态 =====
    uint64 private _cooldownDays = 1;                                 // 自然日冷却（默认 1 天）
    mapping(address => TokenConfig) private _tokenConfig;             // Token 配额配置
    mapping(address => mapping(address => uint64)) private _lastClaimDay; // token => user => 最近领取日
    mapping(address => uint64) private _passValidDayPlusOne;         // 用户通行证有效日 + 1
    bool private _paidPassEnabled;
    uint256 private _passPriceEth;
    bool private _blacklistEnabled;
    mapping(address => bool) private _blacklisted;
    address private _treasury;                                        // 财务金库地址

    // ===== 构造 & 初始化权限 =====

    /// @notice 构造：设置初始 owner（使用 OZ v5 的 Ownable 基类构造），并授予默认角色
    /// @dev 这里选择将部署者设为 owner / 三个角色的初始持有者；如需多签可后续转移
    constructor() Ownable(msg.sender) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FUNDER_ROLE,         msg.sender);
        _grantRole(TREASURER_ROLE,      msg.sender);
        _treasury = msg.sender;
    }

    // ===== 核心：领取 =====

    /// @notice 领取指定 Token （自然日冷却 + 日上限）
    function claim(address token, address to) external nonReentrant whenNotPaused {
        if (to == address(0)) revert("INVALID_TO");
        if (_blacklistEnabled && _blacklisted[msg.sender]) revert("BLACKLISTED");

        TokenConfig storage config = _tokenConfig[token];
        uint128 amount = config.perClaim;
        if (amount == 0) revert("CLAIM_DISABLED");

        uint64 currentDay = uint64(block.timestamp / DAY);
        if (config.lastIssuedDay != currentDay) {
            config.lastIssuedDay = currentDay;
            config.issuedToday = 0;
        }

        if (_paidPassEnabled) {
            if (_passPriceEth == 0) revert("PASS_PRICE_ZERO");
            uint64 expectedPassDay = currentDay + 1;
            if (_passValidDayPlusOne[msg.sender] != expectedPassDay) revert("PASS_REQUIRED");
        }

        uint64 storedDay = _lastClaimDay[token][msg.sender];
        if (storedDay != 0) {
            uint64 lastDay = storedDay - 1;
            if (lastDay == currentDay) revert("COOLDOWN_DAY");
            if (_cooldownDays > 1 && lastDay + _cooldownDays > currentDay) revert("COOLDOWN");
        }

        uint256 newIssued = uint256(config.issuedToday) + uint256(amount);
        if (config.dailyCap != 0 && newIssued > config.dailyCap) revert("DAILY_CAP_EXCEEDED");

        config.issuedToday = uint128(newIssued);
        _lastClaimDay[token][msg.sender] = currentDay + 1;

        emit Claimed(token, msg.sender, amount, to);
        IERC20(token).safeTransfer(to, amount);
    }

    function setCooldown(uint256 newCooldown) external onlyOwner {
        uint64 daySpan = uint64(newCooldown / DAY);
        if (daySpan == 0) revert("INVALID_COOLDOWN");
        _cooldownDays = daySpan;
        emit ParamUpdated("COOLDOWN", address(0), uint256(daySpan) * DAY);
    }

    function setPerClaim(address token, uint256 amount) external onlyOwner {
        if (amount > type(uint128).max) revert("PERCLAIM_TOO_LARGE");
        _tokenConfig[token].perClaim = uint128(amount);
        emit ParamUpdated("PER_CLAIM", token, amount);
    }

    function setDailyCap(address token, uint256 cap) external onlyOwner {
        if (cap == type(uint256).max) {
            _tokenConfig[token].dailyCap = 0; // 0 代表无限制
        } else {
            if (cap > type(uint128).max) revert("DAILYCAP_TOO_LARGE");
            _tokenConfig[token].dailyCap = uint128(cap);
        }
        emit ParamUpdated("DAILY_CAP", token, cap);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function systemRemainingToday(address token) external view returns (uint256) {
        TokenConfig storage config = _tokenConfig[token];
        if (config.dailyCap == 0) return type(uint256).max;
        uint64 currentDay = uint64(block.timestamp / DAY);
        uint256 issued = config.lastIssuedDay == currentDay ? uint256(config.issuedToday) : 0;
        uint256 cap = uint256(config.dailyCap);
        return cap > issued ? cap - issued : 0;
    }

    function nextAvailableAt(address token, address user) external view returns (uint256) {
        uint64 storedDay = _lastClaimDay[token][user];
        if (storedDay == 0) return block.timestamp;
        uint64 lastDay = storedDay - 1;
        uint64 nextDay = lastDay + _cooldownDays;
        return uint256(nextDay) * DAY;
    }

    function perClaim(address token) external view returns (uint256) { return _tokenConfig[token].perClaim; }
    function cooldownSec() external view returns (uint256) { return uint256(_cooldownDays) * DAY; }
    function treasury() external view returns (address) { return _treasury; }

    // ===== 通行证（当日有效） =====

    function paidPassEnabled() external view returns (bool) { return _paidPassEnabled; }
    function passPriceEth() external view returns (uint256) { return _passPriceEth; }

    /// @notice 查询地址是否拥有当日通行证
    function hasActivePass(address account) external view returns (bool) {
        if (!_paidPassEnabled) return false;
        return _passValidDayPlusOne[account] == uint64(block.timestamp / DAY + 1);
    }

    /// @notice 购买当日通行证；多付找零，若找零失败则整笔回滚（不会吞钱）
    function buyDailyPass() external payable nonReentrant whenNotPaused {
        if (!_paidPassEnabled) revert("PASS_DISABLED");
        uint256 price = _passPriceEth;
        if (price == 0) revert("PASS_PRICE_ZERO");

        uint256 currentDay = block.timestamp / DAY;
        if (_passValidDayPlusOne[msg.sender] == uint64(currentDay + 1)) revert("PASS_EXISTS");
        if (msg.value < price) revert("PASS_UNDERPAY");

        _passValidDayPlusOne[msg.sender] = uint64(currentDay + 1);

        if (msg.value > price) {
            (bool success, ) = msg.sender.call{value: msg.value - price}("");
            if (!success) revert("PASS_REFUND_FAIL"); // 整笔回滚，状态与资金都不变
        }

        emit PassPurchased(msg.sender, price, currentDay);
    }

    // ===== 入金（资方）与治理参数 =====

    /// @notice 资方受控入金（不会改变 dailyCap，只增加真实余额）
    function fundVault(address token, uint256 amount) external onlyRole(FUNDER_ROLE) {
        if (amount == 0) revert("INVALID_AMOUNT");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit VaultFunded(token, msg.sender, amount);
    }

    /// @notice 设置国库地址（用于财务归集）
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert("TREASURY_ZERO");
        _treasury = newTreasury;
        // 这里复用 ParamUpdated：token 字段承载“新国库地址”，value=0
        emit ParamUpdated("TREASURY", newTreasury, 0);
    }

    /// @notice 启用/关闭付费模式并设置价格
    function setPaidPass(bool enabled, uint256 priceWei) external onlyOwner {
        if (enabled && priceWei == 0) revert("PASS_PRICE_REQUIRED");
        _paidPassEnabled = enabled;
        emit ParamUpdated("PAID_PASS_ENABLED", address(0), enabled ? 1 : 0);
        _passPriceEth = priceWei;
        emit ParamUpdated("PASS_PRICE", address(0), priceWei);
    }

    /// @notice 单独调整通行证价格
    function setPassPriceEth(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert("PASS_PRICE_REQUIRED");
        _passPriceEth = newPrice;
        emit ParamUpdated("PASS_PRICE", address(0), newPrice);
    }

    // ===== 风控：黑名单 =====

    function blacklistEnabled() external view returns (bool) { return _blacklistEnabled; }
    function isBlacklisted(address account) external view returns (bool) { return _blacklisted[account]; }

    function setBlacklistEnabled(bool enabled) external onlyOwner {
        _blacklistEnabled = enabled;
        emit ParamUpdated("BLACKLIST_ENABLED", address(0), enabled ? 1 : 0);
    }

    function setBlacklisted(address account, bool blacklisted_) external onlyOwner {
        _blacklisted[account] = blacklisted_;
        emit BlacklistUpdated(account, blacklisted_);
        emit ParamUpdated("BLACKLIST", account, blacklisted_ ? 1 : 0);
    }

    // ===== 财务归集（重要：ETH 可被强行注入，需正规出口；Token 仅在下线后清扫） =====

    /// @notice 归集 ETH 至国库（处理 SELFDESTRUCT 强注/票款归集）
    function sweepEth(uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        address treasury_ = _treasury;
        if (treasury_ == address(0)) revert("TREASURY_UNSET");
        if (amount == 0 || amount > address(this).balance) revert("SWEEP_ETH_INVALID");

        (bool success, ) = treasury_.call{value: amount}("");
        if (!success) revert("SWEEP_ETH_FAIL");

        emit FundsSwept(address(0), treasury_, amount);
    }

    /// @notice 归集 Token 至国库；仅当该 Token 已“下线”（perClaim==0）时允许，避免误扫在发放库存
    function sweepToken(address token, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        if (token == address(0)) revert("TOKEN_ZERO");
        address treasury_ = _treasury;
        if (treasury_ == address(0)) revert("TREASURY_UNSET");

        TokenConfig storage config = _tokenConfig[token];
        if (config.perClaim != 0) revert("TOKEN_ACTIVE");

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount == 0 || amount > balance) revert("SWEEP_TOKEN_INVALID");

        IERC20(token).safeTransfer(treasury_, amount);
        emit FundsSwept(token, treasury_, amount);
    }


}
