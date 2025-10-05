// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Faucet} from "src/faucet/Faucet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IFaucet {
    event Claimed(address indexed token, address indexed user, uint256 amount, address indexed to);

    function claim(address token, address to) external;
    function setCooldown(uint256 newCooldown) external;
    function setPerClaim(address token, uint256 amount) external;
    function setDailyCap(address token, uint256 cap) external;
    function systemRemainingToday(address token) external view returns (uint256);
    function nextAvailableAt(address token, address user) external view returns (uint256);
    function perClaim(address token) external view returns (uint256);
    function cooldownSec() external view returns (uint256);
    function pause() external;
    function unpause() external;
}

/// @notice 可配置小数的 ERC20 测试币
contract MintableTestToken is ERC20 {
    uint8 private immutable CUSTOM_DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        CUSTOM_DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return CUSTOM_DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice transfer/transferFrom 返回 false，用于验证 SafeERC20 包装
contract ReturnFalseToken is MintableTestToken {
    constructor() MintableTestToken("ReturnFalseToken", "RFT", 6) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        require(ok, "docs_qamvp1_SafeERC20_MockFail");
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        require(ok, "docs_qamvp1_SafeERC20_MockFail");
        return false;
    }
}

/// @notice 可在接收时尝试重入 Faucet 的测试币
contract ReentrantToken is MintableTestToken {
    IFaucet private immutable FAUCET_TARGET;
    address private _target;
    bool private _reentered;

    constructor(IFaucet faucet_) MintableTestToken("ReentrantToken", "RAT", 18) {
        FAUCET_TARGET = faucet_;
    }

    function setTarget(address target_) external {
        _target = target_;
    }

    function reset() external {
        _reentered = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (!_reentered && from == address(FAUCET_TARGET) && to == _target && amount > 0) {
            _reentered = true;
            FAUCET_TARGET.claim(address(this), _target);
        }
    }
}

/// @notice 触发 claim 尝试重入的攻击者
contract ReentrancyAttacker {
    IFaucet private immutable FAUCET_TARGET;
    address private immutable TOKEN_TARGET;

    constructor(IFaucet faucet_, address token_) {
        FAUCET_TARGET = faucet_;
        TOKEN_TARGET = token_;
    }

    function attack() external {
        FAUCET_TARGET.claim(TOKEN_TARGET, address(this));
    }
}

contract FaucetTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant COOLDOWN = 86400;
    uint256 private constant PER_CLAIM_VETH = 20 ether;
    uint256 private constant PER_CLAIM_VUSDT = 25_000 * 1e6;
    uint256 private constant DAILY_CAP_VETH = 20_000 ether;

    Faucet internal faucetImpl;
    IFaucet internal faucet;
    MintableTestToken internal vEthToken;
    MintableTestToken internal vUsdtToken;
    ReturnFalseToken internal returnFalseToken;
    ReentrantToken internal reentrantToken;

    address internal student = address(0xBEEF);
    address internal recipient = address(0xBEE1);

    function setUp() public {
        faucetImpl = new Faucet();
        faucet = IFaucet(address(faucetImpl));

        vEthToken = new MintableTestToken("Virtual ETH", "vETH", 18);
        vUsdtToken = new MintableTestToken("Virtual USDT", "vUSDT", 6);
        returnFalseToken = new ReturnFalseToken();
        reentrantToken = new ReentrantToken(faucet);

        vEthToken.mint(address(faucetImpl), 100_000 ether);
        vUsdtToken.mint(address(faucetImpl), 10_000_000 * 1e6);
        returnFalseToken.mint(address(faucetImpl), 1_000_000 * 1e6);
        reentrantToken.mint(address(faucetImpl), 100_000 ether);

        faucet.setCooldown(COOLDOWN);
        faucet.setPerClaim(address(vEthToken), PER_CLAIM_VETH);
        faucet.setPerClaim(address(vUsdtToken), PER_CLAIM_VUSDT);
        faucet.setPerClaim(address(returnFalseToken), 1_000 * 1e6);
        faucet.setPerClaim(address(reentrantToken), PER_CLAIM_VETH);
        faucet.setDailyCap(address(vEthToken), DAILY_CAP_VETH);
        faucet.setDailyCap(address(returnFalseToken), type(uint256).max);
        faucet.setDailyCap(address(reentrantToken), DAILY_CAP_VETH);
    }

    function testClaim_FirstTime_Succeeds_AndEmits__docs_qamvp1_T1_1() public {
        uint256 faucetBalanceBefore = vEthToken.balanceOf(address(faucetImpl));

        vm.expectEmit(true, true, true, true);
        emit IFaucet.Claimed(address(vEthToken), student, PER_CLAIM_VETH, recipient);

        vm.prank(student);
        faucet.claim(address(vEthToken), recipient);

        // 首次领取后接收人应拿到 20e18 vETH（docs_qamvp1_T1_1）
        assertEq(vEthToken.balanceOf(recipient), PER_CLAIM_VETH, unicode"docs_qamvp1_T1_1: 首次领取应发放 20e18 vETH");
        // Faucet 库存应同步减少（docs_qamvp1_T1_1）
        assertEq(
            vEthToken.balanceOf(address(faucetImpl)),
            faucetBalanceBefore - PER_CLAIM_VETH,
            unicode"docs_qamvp1_T1_1: 首次领取后 Faucet 库存应减少"
        );
        // 冷却时间应更新至 24 小时后（docs_qamvp1_T1_1）
        assertEq(
            faucet.nextAvailableAt(address(vEthToken), student),
            block.timestamp + COOLDOWN,
            unicode"docs_qamvp1_T1_1: 冷却时间应为 24 小时"
        );

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(returnFalseToken))
        );
        vm.prank(student);
        faucet.claim(address(returnFalseToken), student);
        // SafeERC20 失败时库存必须保持不变（docs_qamvp1_T1_1）
        assertEq(
            returnFalseToken.balanceOf(address(faucetImpl)),
            1_000_000 * 1e6,
            unicode"docs_qamvp1_T1_1: SafeERC20 失败后 Faucet 库存应保持不变"
        );
    }

    function testClaim_WithinCooldown_Reverts__docs_qamvp1_T1_2(address studentA, address studentB) public {
        vm.assume(studentA != address(0));
        vm.assume(studentB != address(0));
        vm.assume(studentA != studentB);

        vm.prank(studentA);
        faucet.claim(address(vEthToken), studentA);

        uint256 faucetBalanceBefore = vEthToken.balanceOf(address(faucetImpl));

        vm.expectRevert();
        vm.prank(studentA);
        faucet.claim(address(vEthToken), studentA);

        // 冷却期命中时 Faucet 库存不得减少（docs_qamvp1_T1_2）
        assertEq(
            vEthToken.balanceOf(address(faucetImpl)),
            faucetBalanceBefore,
            unicode"docs_qamvp1_T1_2: 冷却期命中时 Faucet 库存不得减少"
        );
        // 冷却期内用户余额应保持单次领取额度（docs_qamvp1_T1_2）
        assertEq(
            vEthToken.balanceOf(studentA),
            PER_CLAIM_VETH,
            unicode"docs_qamvp1_T1_2: 冷却期内用户余额不得增加"
        );

        vm.prank(studentB);
        faucet.claim(address(vEthToken), studentB);
        // fuzz：其他地址不受影响可正常领取（docs_qamvp1_T1_2）
        assertEq(
            vEthToken.balanceOf(studentB),
            PER_CLAIM_VETH,
            unicode"docs_qamvp1_T1_2: 其他地址应可正常领取"
        );

        ReentrancyAttacker attacker = new ReentrancyAttacker(faucet, address(reentrantToken));
        reentrantToken.setTarget(address(attacker));
        reentrantToken.reset();

        vm.expectRevert();
        attacker.attack();
        // 校验 nonReentrant + CEI：重入失败不得发放额外代币（docs_qamvp1_T1_2）
        assertEq(
            reentrantToken.balanceOf(address(attacker)),
            0,
            unicode"docs_qamvp1_T1_2: 重入失败后攻击者余额应为 0"
        );
    }

    function testDailyCap_Reverts_WhenReached__docs_qamvp1_T1_3() public {
        uint256 tinyCap = PER_CLAIM_VETH * 2;
        faucet.setDailyCap(address(vEthToken), tinyCap);

        address otherStudent = address(0xBEE2);
        address thirdStudent = address(0xBEE3);

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        vm.prank(otherStudent);
        faucet.claim(address(vEthToken), otherStudent);

        vm.expectRevert(bytes("DAILY_CAP_EXCEEDED"));
        vm.prank(thirdStudent);
        faucet.claim(address(vEthToken), thirdStudent);

        // 日上限命中后系统剩余额度必须为 0（docs_qamvp1_T1_3）
        assertEq(
            faucet.systemRemainingToday(address(vEthToken)),
            0,
            unicode"docs_qamvp1_T1_3: 日上限命中后 remaining 应为 0"
        );
    }

    function testClaim_Reverts_WhenTokenDisabled__docs_qamvp1_T1_disable() public {
        faucet.setPerClaim(address(vEthToken), 0);

        vm.expectRevert(bytes("CLAIM_DISABLED"));
        vm.prank(student);
        faucet.claim(address(vEthToken), student);
    }

    function testClaim_Reverts_WhenPaused__docs_qamvp1_T1_pause() public {
        faucet.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        faucet.unpause();

        vm.prank(student);
        faucet.claim(address(vEthToken), student);
        // 解除暂停后应可正常领取（docs_qamvp1_T1_pause）
        assertEq(
            vEthToken.balanceOf(student),
            PER_CLAIM_VETH,
            unicode"docs_qamvp1_T1_pause: 解除暂停后应能领取"
        );
    }

    function testSetCooldown_Reverts_WhenZero__docs_qamvp1_T1_cooldown() public {
        vm.expectRevert(bytes("INVALID_COOLDOWN"));
        faucet.setCooldown(0);
    }

    function testNextAvailableAt_RespectsDayAndCooldown__docs_qamvp1_T1_next() public {
        faucet.setCooldown(1 hours);

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        uint256 nextTimeShortCooldown = faucet.nextAvailableAt(address(vEthToken), student);
        // 冷却 < 1 天时应受自然日限制（docs_qamvp1_T1_next）
        assertEq(nextTimeShortCooldown, 1 days, unicode"docs_qamvp1_T1_next: 次日才能再次领取");

        faucet.setCooldown(2 days);

        uint256 nextTimeLongCooldown = faucet.nextAvailableAt(address(vEthToken), student);
        // 冷却 > 1 天时以冷却时间为准（docs_qamvp1_T1_next）
        assertEq(
            nextTimeLongCooldown,
            block.timestamp + 2 days,
            unicode"docs_qamvp1_T1_next: 冷却大于一日时应返回冷却结束时间"
        );
    }

    function testSystemRemainingToday_UnlimitedCap__docs_qamvp1_T1_cap() public {
        faucet.setDailyCap(address(vEthToken), 0);

        // 日上限为 0 表示无限制，应返回最大值（docs_qamvp1_T1_cap）
        assertEq(
            faucet.systemRemainingToday(address(vEthToken)),
            type(uint256).max,
            unicode"docs_qamvp1_T1_cap: 日上限 0 时应返回最大值"
        );
    }

    function testClaim_Reverts_WhenRecipientZero__docs_qamvp1_T1_zero_to() public {
        vm.expectRevert(bytes("INVALID_TO"));
        vm.prank(student);
        faucet.claim(address(vEthToken), address(0));
    }

    function testCrossDay_Reset_Works__docs_qamvp1_T1_3_nextday() public {
        uint256 tinyCap = PER_CLAIM_VETH;
        faucet.setDailyCap(address(vEthToken), tinyCap);

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        vm.expectRevert();
        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        uint256 nextDay = ((block.timestamp / 1 days) + 1) * 1 days;
        vm.warp(nextDay + COOLDOWN + 1);

        // 跨日后系统额度应恢复（docs_qamvp1_T1_3_nextday）
        assertEq(
            faucet.systemRemainingToday(address(vEthToken)),
            tinyCap,
            unicode"跨日后 remaining 应恢复上限"
        );

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        // 跨日后应能再次领取并累计余额（docs_qamvp1_T1_3_nextday）
        assertEq(
            vEthToken.balanceOf(student),
            tinyCap * 2,
            unicode"跨日后用户余额应翻倍"
        );
    }
}
