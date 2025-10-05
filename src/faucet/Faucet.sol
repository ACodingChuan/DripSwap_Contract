// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/// @notice Faucet 合约，满足 PRD 与 QA 要求中的冷却与系统日上限逻辑 [mvp-1:§2.1]
contract Faucet is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    uint256 private constant DAY = 1 days;

    struct TokenQuota {
        uint256 perClaim;
        uint256 dailyCap;
        uint256 issuedToday;
        uint256 lastUpdatedDay;
    }

    struct UserRecord {
        uint256 lastClaimAt;
        uint256 lastClaimDay;
    }

    event Claimed(address indexed token, address indexed user, uint256 amount, address indexed to);
    event ParamUpdated(bytes32 indexed key, address indexed token, uint256 value);

    uint256 private _cooldownSec = DAY;
    mapping(address => TokenQuota) private _tokenQuota;
    mapping(address => mapping(address => UserRecord)) private _userRecords;

    /// @notice 构造函数，初始化 owner 为部署者 [mvp-1:§2.1]
    constructor() Ownable(msg.sender) {}

    /// @notice 领取指定 Token 至 to 地址，执行冷却与日上限校验 [qa-mvp1:T1]
    function claim(address token, address to) external nonReentrant whenNotPaused {
        if (to == address(0)) revert("INVALID_TO");

        TokenQuota storage quota = _tokenQuota[token];
        uint256 amount = quota.perClaim;
        if (amount == 0) revert("CLAIM_DISABLED");

        uint256 currentDay = block.timestamp / DAY;
        _resetDailyCounter(quota, currentDay);

        UserRecord storage record = _userRecords[token][msg.sender];
        if (record.lastClaimAt != 0 && record.lastClaimDay == currentDay) revert("COOLDOWN_DAY");
        if (record.lastClaimAt != 0 && block.timestamp < record.lastClaimAt + _cooldownSec) {
            revert("COOLDOWN");
        }

        uint256 newIssued = quota.issuedToday + amount;
        if (quota.dailyCap != 0 && newIssued > quota.dailyCap) revert("DAILY_CAP_EXCEEDED");

        quota.issuedToday = newIssued;

        record.lastClaimAt = block.timestamp;
        record.lastClaimDay = currentDay;

        emit Claimed(token, msg.sender, amount, to);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice 设置全局冷却秒数，必须大于 0 [mvp-1:§2.1]
    function setCooldown(uint256 newCooldown) external onlyOwner {
        if (newCooldown == 0) revert("INVALID_COOLDOWN");
        _cooldownSec = newCooldown;
        emit ParamUpdated("COOLDOWN", address(0), newCooldown);
    }

    /// @notice 配置 Token 单次领取额度，0 代表禁用 [mvp-1:§2.1]
    function setPerClaim(address token, uint256 amount) external onlyOwner {
        _tokenQuota[token].perClaim = amount;
        emit ParamUpdated("PER_CLAIM", token, amount);
    }

    /// @notice 配置 Token 系统日上限，0 代表无限制 [mvp-1:§2.1]
    function setDailyCap(address token, uint256 cap) external onlyOwner {
        TokenQuota storage quota = _tokenQuota[token];
        quota.dailyCap = cap;
        emit ParamUpdated("DAILY_CAP", token, cap);
    }

    /// @notice 暂停领取入口，仅 owner 可调用 [mvp-1:§2.1]
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice 恢复领取入口，仅 owner 可调用 [mvp-1:§2.1]
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice 查询指定 Token 当日剩余额度 [qa-mvp1:T1]
    function systemRemainingToday(address token) external view returns (uint256) {
        TokenQuota storage quota = _tokenQuota[token];
        uint256 cap = quota.dailyCap;
        if (cap == 0) {
            return type(uint256).max;
        }

        uint256 currentDay = block.timestamp / DAY;
        uint256 issued = quota.lastUpdatedDay == currentDay ? quota.issuedToday : 0;
        return cap > issued ? cap - issued : 0;
    }

    /// @notice 查询用户下次可领取时间 [qa-mvp1:T1]
    function nextAvailableAt(address token, address user) external view returns (uint256) {
        UserRecord storage record = _userRecords[token][user];
        if (record.lastClaimAt == 0) {
            return block.timestamp;
        }

        uint256 afterCooldown = record.lastClaimAt + _cooldownSec;
        uint256 afterDay = (record.lastClaimDay + 1) * DAY;
        return afterCooldown > afterDay ? afterCooldown : afterDay;
    }

    /// @notice 查询 Token 单次领取额度 [qa-mvp1:T1]
    function perClaim(address token) external view returns (uint256) {
        return _tokenQuota[token].perClaim;
    }

    /// @notice 查询当前冷却秒数 [qa-mvp1:T1]
    function cooldownSec() external view returns (uint256) {
        return _cooldownSec;
    }

    function _resetDailyCounter(TokenQuota storage quota, uint256 currentDay) private {
        if (quota.lastUpdatedDay != currentDay) {
            quota.lastUpdatedDay = currentDay;
            quota.issuedToday = 0;
        }
    }
}
