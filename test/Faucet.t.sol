// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Faucet} from "src/faucet/Faucet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IFaucet {
    event Claimed(address indexed token, address indexed user, uint256 amount, address indexed to);

    function claim(address token, address to) external;
    function setCooldown(uint256 newCooldown) external;
    function setPerClaim(address token, uint256 amount) external;
    function setDailyCap(address token, uint256 cap) external;
    function buyDailyPass() external payable;
    function setPaidPass(bool enabled, uint256 priceWei) external;
    function setPassPriceEth(uint256 newPrice) external;
    function setBlacklistEnabled(bool enabled) external;
    function setBlacklisted(address account, bool blacklisted_) external;
    function systemRemainingToday(address token) external view returns (uint256);
    function nextAvailableAt(address token, address user) external view returns (uint256);
    function perClaim(address token) external view returns (uint256);
    function cooldownSec() external view returns (uint256);
    function paidPassEnabled() external view returns (bool);
    function passPriceEth() external view returns (uint256);
    function hasActivePass(address account) external view returns (bool);
    function blacklistEnabled() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
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

contract RefundRejector {
    function buy(Faucet target) external payable {
        target.buyDailyPass{value: msg.value}();
    }

    receive() external payable {
        revert("REFUND_BLOCKED");
    }
}

contract FaucetTest is Test {
    using SafeERC20 for IERC20;
    using stdStorage for StdStorage;

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

    function _warpToNextDay() internal { vm.warp(((block.timestamp / 1 days) + 1) * 1 days); }

    address internal student = address(0xBEEF);
    address internal recipient = address(0xBEE1);
    address internal treasuryWallet = address(0xCAFE);

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

        assertEq(vEthToken.balanceOf(recipient), PER_CLAIM_VETH, unicode"docs_qamvp1_T1_1: 首次领取应发放 20e18 vETH");
        assertEq(
            vEthToken.balanceOf(address(faucetImpl)),
            faucetBalanceBefore - PER_CLAIM_VETH,
            unicode"docs_qamvp1_T1_1: 首次领取后 Faucet 库存应减少"
        );
        uint256 claimDay = block.timestamp / 1 days;
        assertEq(
            faucet.nextAvailableAt(address(vEthToken), student),
            (claimDay + 1) * 1 days,
            unicode"docs_qamvp1_T1_1: 冷却时间应返回次日开始时间"
        );

        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(returnFalseToken))
        );
        vm.prank(student);
        faucet.claim(address(returnFalseToken), student);
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

        vm.expectRevert();
        vm.prank(thirdStudent);
        faucet.claim(address(vEthToken), thirdStudent);

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
        vm.expectRevert();
        faucet.setCooldown(0);
    }

    function testNextAvailableAt_RespectsDayAndCooldown__docs_qamvp1_T1_next() public {
        faucet.setCooldown(1 days);
        vm.prank(student);
        faucet.claim(address(vEthToken), student);
        uint64 claimDay = uint64(block.timestamp / 1 days);
        assertEq(
            faucet.nextAvailableAt(address(vEthToken), student),
            uint256(claimDay + 1) * 1 days,
            unicode"docs_qamvp1_T1_next: 冷却为 1 天时应返回次日开始"
        );

        faucet.setCooldown(2 days);
        vm.warp(uint256(claimDay + 2) * 1 days + 1);
        vm.prank(student);
        faucet.claim(address(vEthToken), student);
        claimDay = uint64(block.timestamp / 1 days);
        assertEq(
            faucet.nextAvailableAt(address(vEthToken), student),
            uint256(claimDay + 2) * 1 days,
            unicode"docs_qamvp1_T1_next: 冷却为 2 天时应返回对应自然日"
        );
    }


    function testNextAvailableAt_BranchCoverage__docs_qamvp1_T1_next_branch() public {
        uint256 immediate = faucet.nextAvailableAt(address(vEthToken), student);
        assertEq(immediate, block.timestamp, unicode"首次调用应返回当前时间");

        vm.prank(student);
        faucet.claim(address(vEthToken), student);
        _warpToNextDay();
        uint256 expectedNext = ((block.timestamp / 1 days) + 0) * 1 days;
        assertEq(faucet.nextAvailableAt(address(vEthToken), student), expectedNext, unicode"跨日后应返回自然日起始");
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
        vm.expectRevert();
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

        _warpToNextDay();
        vm.warp(block.timestamp + 1);

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

    function testSetPaidPass_EnableRequiresPrice__docs_prd_T1_paid_pass() public {
        vm.expectRevert();
        faucet.setPaidPass(true, 0);

        faucet.setPaidPass(false, 0);
        assertFalse(faucet.paidPassEnabled(), unicode"关闭通行证模式后应为 false");
    }

    function testBuyDailyPass_AndClaimFlow__docs_qamvp1_T1_pass() public {
        faucet.setPaidPass(true, 5 ether);
        assertEq(faucet.passPriceEth(), 5 ether);

        vm.expectRevert();
        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        vm.deal(student, 10 ether);
        vm.prank(student);
        faucet.buyDailyPass{value: 5 ether}();
        assertTrue(faucet.hasActivePass(student), unicode"购票后应拥有有效通行证");

        vm.expectRevert();
        vm.prank(student);
        faucet.buyDailyPass{value: 5 ether}();

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        _warpToNextDay();
        vm.warp(block.timestamp + 1);
        assertFalse(faucet.hasActivePass(student), unicode"跨日后通行证应失效");

        vm.deal(student, 5 ether);
        vm.prank(student);
        faucet.buyDailyPass{value: 5 ether}();
        vm.prank(student);
        faucet.claim(address(vEthToken), student);
    }

    function testBuyDailyPass_RefundsExcess__docs_qamvp1_T1_pass_refund() public {
        faucet.setPaidPass(true, 1 ether);
        vm.deal(student, 2 ether);

        uint256 balanceBefore = student.balance;
        vm.prank(student);
        faucet.buyDailyPass{value: 2 ether}();

        assertEq(student.balance, balanceBefore - 1 ether, unicode"多付的 ETH 应退回");
    }

    function testSetPassPriceEth_RejectsZero__docs_prd_T1_pass_price() public {
        faucet.setPassPriceEth(3 ether);
        assertEq(faucet.passPriceEth(), 3 ether);

        vm.expectRevert();
        faucet.setPassPriceEth(0);
    }


    function testConstructor_AssignsRolesAndTreasury__docs_prd_T1_treasurer() public {
        Faucet newFaucet = new Faucet();
        assertEq(newFaucet.owner(), address(this));
        assertTrue(newFaucet.hasRole(newFaucet.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(newFaucet.hasRole(newFaucet.FUNDER_ROLE(), address(this)));
        assertTrue(newFaucet.hasRole(newFaucet.TREASURER_ROLE(), address(this)));
        assertEq(newFaucet.treasury(), address(this));
    }

    function testSetTreasury_OnlyOwnerAndEvents__docs_prd_T1_treasurer() public {
        vm.prank(student);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, student));
        faucetImpl.setTreasury(treasuryWallet);

        vm.expectRevert("TREASURY_ZERO");
        faucetImpl.setTreasury(address(0));

        vm.expectEmit(true, true, false, true);
        emit Faucet.ParamUpdated("TREASURY", treasuryWallet, 0);
        faucetImpl.setTreasury(treasuryWallet);
        assertEq(faucetImpl.treasury(), treasuryWallet);
    }

    function testSweepETH_ByTreasurer__docs_prd_T1_treasurer() public {
        faucetImpl.setTreasury(treasuryWallet);
        vm.deal(address(faucetImpl), 5 ether);

        vm.expectEmit(true, true, false, true);
        emit Faucet.FundsSwept(address(0), treasuryWallet, 1 ether);
        faucetImpl.sweepEth(1 ether);
        assertEq(address(faucetImpl).balance, 4 ether);
        assertEq(treasuryWallet.balance, 1 ether);
    }

    function testSweepETH_RevertsWhenTreasuryUnset__docs_prd_T1_treasurer() public {
        uint256 slot = stdstore.target(address(faucetImpl)).sig("treasury()").find();
        vm.store(address(faucetImpl), bytes32(slot), bytes32(uint256(0)));
        vm.expectRevert("TREASURY_UNSET");
        faucetImpl.sweepEth(1 ether);
    }

    function testSweepETH_RevertsForNonTreasurer__docs_prd_T1_treasurer() public {
        faucetImpl.setTreasury(treasuryWallet);
        vm.deal(address(faucetImpl), 1 ether);
        vm.prank(student);
        vm.expectRevert();
        Faucet(address(faucetImpl)).sweepEth(0.5 ether);
    }

    function testSweepToken_GuardAgainstActiveToken__docs_prd_T1_treasurer() public {
        faucetImpl.setTreasury(treasuryWallet);
        vm.expectRevert("TOKEN_ACTIVE");
        faucetImpl.sweepToken(address(vEthToken), 1 ether);
    }

    function testSweepToken_SucceedsWhenInactive__docs_prd_T1_treasurer() public {
        faucetImpl.setTreasury(treasuryWallet);
        faucet.setPerClaim(address(vEthToken), 0);
        MintableTestToken extra = new MintableTestToken("Extra", "EXT", 18);
        extra.mint(address(faucetImpl), 20 ether);

        vm.expectEmit(true, true, false, true);
        emit Faucet.FundsSwept(address(extra), treasuryWallet, 5 ether);
        faucetImpl.sweepToken(address(extra), 5 ether);
        assertEq(extra.balanceOf(treasuryWallet), 5 ether);
    }

    function testClaim_Reverts_WhenBlacklisted__docs_prd_T1_blacklist() public {
        faucet.setBlacklistEnabled(true);
        faucet.setBlacklisted(student, true);

        vm.expectRevert(bytes("BLACKLISTED"));
        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        faucet.setBlacklisted(student, false);
        _warpToNextDay();
        vm.prank(student);
        faucet.claim(address(vEthToken), student);
    }

    function testClaim_Reverts_WhenCooldownNotElapsed__docs_prd_T1_cooldown_branch() public {
        faucet.setCooldown(2 days);

        vm.prank(student);
        faucet.claim(address(vEthToken), student);

        vm.warp(block.timestamp + 1 days + 1);

        vm.startPrank(student);
        vm.expectRevert(bytes("COOLDOWN"));
        faucet.claim(address(vEthToken), student);
        vm.stopPrank();
    }

    function testFundVault_OnlyRoleCanDeposit__docs_prd_T1_funder() public {
        MintableTestToken extraToken = new MintableTestToken("Extra vETH", "xvETH", 18);
        extraToken.mint(student, 50 ether);
        vm.prank(student);
        extraToken.approve(address(faucetImpl), type(uint256).max);

        vm.prank(student);
        vm.expectRevert();
        faucetImpl.fundVault(address(extraToken), 10 ether);

        extraToken.mint(address(this), 50 ether);
        extraToken.approve(address(faucetImpl), type(uint256).max);

        vm.expectRevert();
        faucetImpl.fundVault(address(extraToken), 0);

        faucetImpl.fundVault(address(extraToken), 10 ether);
        assertEq(
            extraToken.balanceOf(address(faucetImpl)),
            10 ether,
            unicode"FUNDER_ROLE 入金后金库存款应增加"
        );
    }

    function testBuyDailyPass_FailsWhenDisabled__docs_prd_T1_pass_disabled() public {
        vm.deal(student, 1 ether);
        vm.prank(student);
        vm.expectRevert();
        faucet.buyDailyPass{value: 1 ether}();
    }

    function testBuyDailyPass_RevertsWhenUnderpay__docs_prd_T1_pass_underpay() public {
        faucet.setPaidPass(true, 2 ether);
        vm.deal(student, 1 ether);

        vm.prank(student);
        vm.expectRevert();
        faucet.buyDailyPass{value: 1 ether}();
    }

    function testViewHelpers_ReportState__docs_prd_T1_views() public {
        assertEq(faucet.cooldownSec(), COOLDOWN);
        assertEq(faucet.perClaim(address(vEthToken)), PER_CLAIM_VETH);
        assertFalse(faucet.blacklistEnabled());
        assertFalse(faucet.isBlacklisted(student));

        faucet.setBlacklistEnabled(true);
        assertTrue(faucet.blacklistEnabled());
        faucet.setBlacklisted(student, true);
        assertTrue(faucet.isBlacklisted(student));

        bytes4 accessInterface = type(IAccessControl).interfaceId;
        assertTrue(Faucet(address(faucet)).supportsInterface(accessInterface));
    }

    function testBuyDailyPass_RefundFailureReverts__docs_prd_T1_refund_fail() public {
        faucet.setPaidPass(true, 1 ether);
        RefundRejector rejector = new RefundRejector();
        vm.deal(address(rejector), 2 ether);

        vm.prank(address(rejector));
        vm.expectRevert(bytes("PASS_REFUND_FAIL"));
        rejector.buy{value: 2 ether}(Faucet(address(faucet)));
    }
}
