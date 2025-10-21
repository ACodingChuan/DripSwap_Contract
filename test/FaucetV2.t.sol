// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* =============================================================================
【Foundry 测试最佳实践（强烈建议打印出来贴在桌前）】

1) 固定调用者（msg.sender）——一律用 startPrank/stopPrank
   - vm.startPrank(ADDR); ... 外部调用 ...; vm.stopPrank();
   - 不要在 vm.prank 与真实外部调用之间穿插 expectRevert/expectEmit 等其它 cheatcode。
   - 需要同时赋余额可用 hoax(ADDR, amount)（= deal + prank），但保持片段原子性更安全。

2) 自定义错误断言（OZ v5）
   - 优先用“选择器”匹配：vm.expectRevert(MyError.selector)。
   - 只有需要严格校验错误参数时，才用 abi.encodeWithSelector(MyError.selector, arg1, ...)。

3) 事件断言（vm.expectEmit）
   - 布尔掩码四位：topic1、topic2、topic3、data 是否严格匹配（topic0=事件签名总会匹配）。
   - 与事件中 indexed 参数个数一致：
       * 1 个 indexed → expectEmit(true,  false, false, true)
       * 2 个 indexed → expectEmit(true,  true,  false, true)
       * 3 个 indexed → expectEmit(true,  true,  true,  true)
   - emit 的那一行尽量使用确定值（先存到局部变量，避免在 emit 里动态调用取值函数）。

4) 用例之间的“串味”
   - 改变了时间（vm.warp）、价格、库存、白名单等状态后，要重新构造并签名请求。
   - 想测 VAULT_LOW 但先触发 OVER_DAILY_CAP？要么取消 cap（设为 0），要么跨天重置累计。

5) 调试
   - setUp 开头用 vm.label(address, "NAME") 标记关键地址，可读性暴增。
   - 单例回归：forge test -m testName -vvvv
   - 临时 console2.log / 暴露 harness 视图排查 digest/signer/_msgSender() 等。

6) 断言策略
   - 能用 selector-only 就用 selector-only（更稳健）；只有必须时再精确校验参数。
   - assertEq/require 的失败信息写清楚（方便未来你自己读日志）。

7) 直接写槽（vm.store）审慎使用
   - 仅在确实没公开 setter 时使用；写完立即恢复，避免影响后续用例。

============================================================================= */

import {Test} from "forge-std/Test.sol"; // Foundry 测试基类：断言、cheatcodes（vm.*）
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol"; // stdstore：定位并写入存储槽（高级用）
import {FaucetV2} from "src/faucet/FaucetV2.sol"; // 被测合约
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// === 测试用可铸造 Token（支持自定义小数）===
// 语法点：
// - 继承 OZ 的 ERC20，额外支持自定义 decimals（很多测试场景需要 6/18 位 Token）
// - external 函数 mint 仅供测试铸币
contract MintableToken is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_) // 调父类构造：设定 name/symbol
    {
        _DECIMALS = decimals_; // 设置不可变（immutable）小数位
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// === 模拟国库收款失败的合约，用于 sweepETH 错误场景 ===
// 语法点：receive() 是接收 ETH 的特殊函数；这里故意 revert 来模拟收款失败
contract FailingTreasury {
    receive() external payable {
        revert("TREASURY_FAIL");
    }
}

// === FaucetV2 测试桩：暴露内部工具函数便于断言 ===
// 语法点：
// - 继承被测合约，在测试里“加开小窗”读取内部计算（如 EIP712 digest、nonce 位图）
// - 仅测试使用，生产不部署
contract FaucetV2Harness is FaucetV2 {
    bytes32 internal constant CLAIM_TYPEHASH = keccak256(
        "Claim(address user,address token,uint256 amount,uint64 day,uint256 nonce,uint256 deadline,bool pass)"
    );

    constructor(address admin, address treasury_, address signer, string memory name_, string memory version_)
        FaucetV2(admin, treasury_, signer, name_, version_)
    {}

    // 暴露 hash：链下签名所用的 EIP-712 digest 可与链上重算对齐，避免“签名不一致”隐患
    function hashRequest(ClaimReq memory req) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(CLAIM_TYPEHASH, req.user, req.token, req.amount, req.day, req.nonce, req.deadline, req.pass)
            )
        );
    }

    // 暴露 nonce 位图：便于断言“是否标记已用”
    function isNonceUsed(address user, uint256 nonce) external view returns (bool) {
        return _isNonceUsed(user, nonce);
    }
}

contract FaucetV2Test is Test {
    using stdStorage for StdStorage;

    // ==== 测试固定数据区 ====
    uint256 private constant SIGNER_PK = 0xA11CE; // 测试用私钥（十六进制常量）
    address private immutable SIGNER = vm.addr(SIGNER_PK); // vm.addr(pk) → 推导公钥地址（Foundry cheatcode）
    address private constant ADMIN = address(0xADAD);
    address private constant TREASURY = address(0xCAFE);
    address private constant RELAYER = address(0x5005);
    address private constant USER = address(0xC0FFEE);
    address private constant OTHER = address(0xBEEF);

    FaucetV2Harness internal faucet;
    MintableToken internal vUsdt;
    MintableToken internal vEth;

    // === 事件再声明（与被测合约一致），用于 expectEmit/emit 匹配 ===
    event Claimed(address indexed user, address indexed token, uint256 amount, uint64 day, uint256 nonce);
    event PassPaid(address indexed payer, uint256 amount, uint64 day);
    event FundsSwept(address indexed asset, address indexed to, uint256 amount);
    event ParamUpdated(bytes32 indexed key, address indexed token, uint256 value);

    // === setUp：每条测试前都会执行一次（保持测试隔离）===
    function setUp() public {
        // 1) 标注地址（日志可读性更高）
        vm.label(ADMIN, "ADMIN");
        vm.label(TREASURY, "TREASURY");
        vm.label(SIGNER, "SIGNER");
        vm.label(RELAYER, "RELAYER");
        vm.label(USER, "USER");
        vm.label(OTHER, "OTHER");

        // 2) 部署被测合约（Harness 版本，带可视窗口）
        faucet = new FaucetV2Harness(ADMIN, TREASURY, SIGNER, "DripFaucet", "2.0");
        vm.label(address(faucet), "FAUCET");

        // 3) 以 ADMIN 身份初始化库存与白名单
        vm.startPrank(ADMIN); // 固定 msg.sender = ADMIN（直到 stopPrank）
        vUsdt = new MintableToken("Virtual USDT", "vUSDT", 6);
        vEth = new MintableToken("Virtual ETH", "vETH", 18);

        // 给管理员铸币后存入 Faucet 作为库存
        vUsdt.mint(ADMIN, 10_000_000 * 1e6);
        vUsdt.approve(address(faucet), type(uint256).max);
        faucet.fund(address(vUsdt), 5_000_000 * 1e6);

        vEth.mint(ADMIN, 1_000 ether);
        vEth.approve(address(faucet), type(uint256).max);
        faucet.fund(address(vEth), 500 ether);

        faucet.setTokenWhitelist(address(vUsdt), true);
        faucet.setTokenDailyCap(address(vUsdt), 3_000_000 * 1e6);
        vm.stopPrank(); // 结束 ADMIN 身份
    }

    // === 工具方法：拼装签名请求 ===
    // 语法点：
    // - memory：内存临时变量；calldata：只读入参；storage：链上存储
    function _buildClaim(uint256 amount, uint256 nonce) internal view returns (FaucetV2.ClaimReq memory req) {
        req.user = USER;
        req.token = address(vUsdt);
        req.amount = amount;
        req.day = faucet.currentDay(); // 固定 day：与服务器签发一致
        req.nonce = nonce;
        req.deadline = block.timestamp + 1 hours;
        req.pass = false;
    }

    // === 工具方法：使用某私钥签名（vm.sign） ===
    function _signClaimWithKey(FaucetV2.ClaimReq memory req, uint256 pk) internal view returns (bytes memory sig) {
        bytes32 digest = faucet.hashRequest(req); // Harness 重算 EIP712 digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v); // r|s|v 拼接（标准 65 字节签名）
    }

    function _signClaim(FaucetV2.ClaimReq memory req) internal view returns (bytes memory) {
        return _signClaimWithKey(req, SIGNER_PK);
    }

    // === 工具方法：模拟 Relayer 发起领取（外部调用） ===
    function _relayedClaim(FaucetV2.ClaimReq memory req, bytes memory sig) internal {
        vm.prank(RELAYER); // 单次 prank：下一次外部调用生效
        faucet.claimWithSig(req, sig);
    }

    // ---------------------------------------------------------------------
    //          构造函数与基础视图
    // ---------------------------------------------------------------------

    // 测试：构造角色授予与事件
    function testConstructorAssignsRolesAndEmitsEvent() public {
        address admin = address(0xAAAA);
        address treasury = address(0xBBBB);
        address signer = address(0xCCCC);

        // 事件 ParamUpdated(bytes32 indexed key, address indexed token, uint256 value)
        // 有 2 个 indexed → (true, true, false, true)
        vm.expectEmit(true, true, false, true);
        emit ParamUpdated("TREASURY", treasury, 0);
        FaucetV2Harness deployed = new FaucetV2Harness(admin, treasury, signer, "Faucet", "2");

        assertTrue(
            deployed.hasRole(deployed.DEFAULT_ADMIN_ROLE(), admin), "Constructor should grant DEFAULT_ADMIN_ROLE"
        );
        assertTrue(deployed.hasRole(deployed.FUNDER_ROLE(), admin), "Constructor should grant FUNDER_ROLE");
        assertTrue(deployed.hasRole(deployed.TREASURER_ROLE(), admin), "Constructor should grant TREASURER_ROLE");
        assertTrue(deployed.hasRole(deployed.SIGNER_ROLE(), signer), "Constructor should grant SIGNER_ROLE");
        assertEq(deployed.treasury(), treasury, "Constructor should persist treasury address");
    }

    // 测试：构造入参校验（ZERO_ADDR 自定义错误）
    function testConstructorValidatesAddresses() public {
        vm.expectRevert(FaucetV2.ZERO_ADDR.selector);
        new FaucetV2Harness(address(0), TREASURY, SIGNER, "F", "2");

        vm.expectRevert(FaucetV2.ZERO_ADDR.selector);
        new FaucetV2Harness(ADMIN, address(0), SIGNER, "F", "2");
    }

    // 测试：视图函数
    function testViewHelpersReportState() public view {
        assertEq(faucet.currentDay(), uint64(block.timestamp / 1 days), "currentDay should equal floor timestamp");
        assertEq(
            faucet.balanceOfToken(address(vUsdt)), vUsdt.balanceOf(address(faucet)), "balanceOfToken should match vault"
        );
    }

    // ---------------------------------------------------------------------
    //          管理员配置与访问控制
    // ---------------------------------------------------------------------

    // 测试：管理员可更新配置并发出事件
    function testAdminCanUpdateConfigAndEmit() public {
        vm.startPrank(ADMIN);

        vm.expectEmit(true, true, false, true); // 2 indexed
        emit ParamUpdated("TOKEN_WHITELIST", address(vEth), 1);
        faucet.setTokenWhitelist(address(vEth), true);
        assertTrue(faucet.tokenWhitelist(address(vEth)));

        vm.expectEmit(true, true, false, true); // 2 indexed
        emit ParamUpdated("TOKEN_DAILY_CAP", address(vEth), 100 ether);
        faucet.setTokenDailyCap(address(vEth), 100 ether);
        assertEq(faucet.tokenDailyCap(address(vEth)), 100 ether);

        vm.expectEmit(true, true, false, true); // 2 indexed
        emit ParamUpdated("PASS_PRICE", address(0), 0.1 ether);
        faucet.setPassPriceWei(0.1 ether);
        assertEq(faucet.passPriceWei(), 0.1 ether);

        address newTreasury = address(0x7777);
        vm.expectEmit(true, true, false, true); // 2 indexed
        emit ParamUpdated("TREASURY", newTreasury, 0);
        faucet.setTreasury(newTreasury);
        vm.stopPrank();

        assertEq(faucet.treasury(), newTreasury);
    }

    // 测试：setTreasury 零地址校验
    function testSetTreasuryRejectsZeroAddress() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(FaucetV2.ZERO_ADDR.selector);
        faucet.setTreasury(address(0));
        vm.stopPrank();
    }

    // 测试：未授权账户调用管理员方法会 revert（严格匹配错误参数）
    function testAdminSettersDenyUnauthorized() public {
        // setTokenWhitelist by OTHER
        vm.startPrank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OTHER, faucet.DEFAULT_ADMIN_ROLE()
            )
        );
        faucet.setTokenWhitelist(address(vUsdt), false);
        vm.stopPrank();

        // setPassPriceWei by OTHER
        vm.startPrank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OTHER, faucet.DEFAULT_ADMIN_ROLE()
            )
        );
        faucet.setPassPriceWei(1 ether);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    //          入金与归集
    // ---------------------------------------------------------------------

    // 测试：fund 需要 FUNDER_ROLE，且成功后库存增加
    function testFundRequiresRoleAndTransfers() public {
        // unauthorized
        vm.startPrank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OTHER, faucet.FUNDER_ROLE()
            )
        );
        faucet.fund(address(vEth), 1 ether);
        vm.stopPrank();

        // authorized
        uint256 beforeBal = vEth.balanceOf(address(faucet));
        vm.startPrank(ADMIN);
        faucet.fund(address(vEth), 10 ether);
        vm.stopPrank();
        assertEq(vEth.balanceOf(address(faucet)), beforeBal + 10 ether, "Funding should raise vault balance");
    }

    // 测试：sweepETH 的各类路径（未设国库/金额非法/收款失败/成功）
    function testSweepEthCoversAllPaths() public {
        vm.deal(address(faucet), 2 ether); // 给合约账户打 2 ETH，便于 sweep

        // 强制将 treasury 置零，验证未配置时的错误
        uint256 slot = stdstore.target(address(faucet)).sig("treasury()").find(); // 定位 treasury 槽位（高级用法）
        vm.store(address(faucet), bytes32(slot), bytes32(uint256(0)));
        vm.startPrank(ADMIN);
        vm.expectRevert(FaucetV2.TREASURY_UNSET.selector);
        faucet.sweepETH(1 ether);
        vm.stopPrank();

        // 恢复 treasury 后测试金额校验（0 与大于余额都会失败）
        vm.store(address(faucet), bytes32(slot), bytes32(uint256(uint160(TREASURY))));
        vm.startPrank(ADMIN);
        vm.expectRevert(FaucetV2.SWEEP_ETH_INVALID.selector);
        faucet.sweepETH(0);
        vm.expectRevert(FaucetV2.SWEEP_ETH_INVALID.selector);
        faucet.sweepETH(5 ether);
        vm.stopPrank();

        // 模拟失败的收款地址：receive() 里 revert
        FailingTreasury failing = new FailingTreasury();
        vm.store(address(faucet), bytes32(slot), bytes32(uint256(uint160(address(failing)))));
        vm.startPrank(ADMIN);
        vm.expectRevert(FaucetV2.SWEEP_FAIL.selector);
        faucet.sweepETH(1 ether);
        vm.stopPrank();

        // 成功归集路径
        vm.store(address(faucet), bytes32(slot), bytes32(uint256(uint160(TREASURY))));
        uint256 treasuryBefore = TREASURY.balance;
        vm.startPrank(ADMIN);
        vm.expectEmit(true, true, false, true); // FundsSwept: 2 indexed
        emit FundsSwept(address(0), TREASURY, 1 ether);
        faucet.sweepETH(1 ether);
        vm.stopPrank();
        assertEq(TREASURY.balance, treasuryBefore + 1 ether, "Treasury balance should increase after sweep");
    }

    // 测试：sweepToken 需要 TREASURER_ROLE，且成功转给国库
    function testSweepTokenRequiresRoleAndTransfers() public {
        // unauthorized
        vm.startPrank(OTHER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OTHER, faucet.TREASURER_ROLE()
            )
        );
        faucet.sweepToken(address(vUsdt), 100);
        vm.stopPrank();

        // authorized
        uint256 beforeTreasury = vUsdt.balanceOf(TREASURY);
        vm.startPrank(ADMIN);
        vm.expectEmit(true, true, false, true); // FundsSwept: 2 indexed
        emit FundsSwept(address(vUsdt), TREASURY, 1_000_000);
        faucet.sweepToken(address(vUsdt), 1_000_000);
        vm.stopPrank();
        assertEq(vUsdt.balanceOf(TREASURY), beforeTreasury + 1_000_000, "Treasury should receive swept tokens");
    }

    // ---------------------------------------------------------------------
    //          付费购票（payPass）
    // ---------------------------------------------------------------------

    // 测试：payPass 的三种路径：未设价/少付/过付成功并发事件
    function testPayPassFlow() public {
        // 未配置价格时应直接报错
        vm.expectRevert(FaucetV2.PRICE_ZERO.selector);
        faucet.payPass{value: 1 ether}();

        // 设置价格
        vm.startPrank(ADMIN);
        faucet.setPassPriceWei(0.5 ether);
        vm.stopPrank();

        // 少付报错
        vm.expectRevert(FaucetV2.UNDERPAY.selector);
        faucet.payPass{value: 0.25 ether}();

        // 过付成功：多余金额留在合约；事件只有 1 个 indexed
        vm.deal(USER, 2 ether);
        vm.startPrank(USER);
        uint64 today = faucet.currentDay();
        vm.expectEmit(true, false, false, true); // PassPaid: 1 indexed
        emit PassPaid(USER, 2 ether, today);
        faucet.payPass{value: 2 ether}();
        vm.stopPrank();
        assertEq(address(faucet).balance, 2 ether, "Excess payment should remain in contract");
    }

    // ---------------------------------------------------------------------
    //          claimWithSig 核心流程
    // ---------------------------------------------------------------------

    // 测试：happy path（签名正确、白名单允许、额度充足）
    function testClaimWithSigHappyPath() public {
        FaucetV2.ClaimReq memory req = _buildClaim(1_000_000, 7);
        bytes memory sig = _signClaim(req);

        assertFalse(faucet.isNonceUsed(req.user, req.nonce), "Nonce should be unused before claim");

        vm.expectEmit(true, true, false, true); // Claimed: user/token 为 indexed
        emit Claimed(USER, address(vUsdt), 1_000_000, faucet.currentDay(), 7);
        _relayedClaim(req, sig);

        assertEq(vUsdt.balanceOf(USER), 1_000_000, "User balance should grow after claim");
        assertTrue(faucet.isNonceUsed(req.user, req.nonce), "Nonce should be marked as used");
    }

    // 测试：白名单校验失败
    function testClaimWithSigChecksWhitelist() public {
        vm.startPrank(ADMIN);
        faucet.setTokenWhitelist(address(vUsdt), false);
        vm.stopPrank();

        FaucetV2.ClaimReq memory req = _buildClaim(1, 1);
        bytes memory sig = _signClaim(req);

        vm.expectRevert(abi.encodeWithSelector(FaucetV2.TOKEN_NOT_ALLOWED.selector, address(vUsdt)));
        _relayedClaim(req, sig);
    }

    // 测试：day 不匹配 & deadline 过期
    function testClaimWithSigValidatesDayAndDeadline() public {
        // day 不匹配（传了明天）
        FaucetV2.ClaimReq memory req = _buildClaim(1, 2);
        req.day = uint64(faucet.currentDay() + 1);
        bytes memory sig = _signClaim(req);
        vm.expectRevert(abi.encodeWithSelector(FaucetV2.DAY_MISMATCH.selector, faucet.currentDay(), req.day));
        _relayedClaim(req, sig);

        // deadline 已过期
        req = _buildClaim(1, 3);
        req.deadline = block.timestamp - 1;
        sig = _signClaim(req);
        vm.expectRevert(abi.encodeWithSelector(FaucetV2.EXPIRED.selector, block.timestamp, req.deadline));
        _relayedClaim(req, sig);
    }

    // 测试：重放与签名者校验
    function testClaimWithSigValidatesSignerAndReplay() public {
        // 第一次成功
        FaucetV2.ClaimReq memory req = _buildClaim(1, 4);
        bytes memory sig = _signClaim(req);
        _relayedClaim(req, sig);

        // 第二次用同 nonce 重放：应命中 NONCE_USED
        vm.expectRevert(abi.encodeWithSelector(FaucetV2.NONCE_USED.selector, USER, req.nonce));
        _relayedClaim(req, sig);

        // 伪造 signer：应命中 INVALID_SIGNER
        FaucetV2.ClaimReq memory invalidReq = _buildClaim(1, 5);
        uint256 fakePk = 0xBEEF;
        address fakeSigner = vm.addr(fakePk);
        bytes memory wrongSig = _signClaimWithKey(invalidReq, fakePk);
        vm.expectRevert(abi.encodeWithSelector(FaucetV2.INVALID_SIGNER.selector, fakeSigner));
        _relayedClaim(invalidReq, wrongSig);
    }

    // 测试：先命中日上限，再验证 VAULT_LOW（取消上限以便走到余额检查）
    function testClaimWithSigChecksDailyCapAndVault() public {
        // 1) 设置当日上限为 1,000,000，并打满当天额度
        vm.startPrank(ADMIN);
        faucet.setTokenDailyCap(address(vUsdt), 1_000_000);
        vm.stopPrank();

        FaucetV2.ClaimReq memory req = _buildClaim(1_000_000, 10);
        bytes memory sig = _signClaim(req);
        _relayedClaim(req, sig);

        // 继续领取 1：应命中 OVER_DAILY_CAP（检查顺序：先 cap 后余额）
        FaucetV2.ClaimReq memory exceedReq = _buildClaim(1, 11);
        bytes memory sig2 = _signClaim(exceedReq);
        vm.expectRevert(
            abi.encodeWithSelector(
                FaucetV2.OVER_DAILY_CAP.selector,
                address(vUsdt),
                uint256(1_000_001), // next = 1_000_000 + 1
                uint256(1_000_000), // cap
                faucet.currentDay()
            )
        );
        _relayedClaim(exceedReq, sig2);

        // 2) 准备 VAULT_LOW：取消当日上限（设 0），并清空库存
        vm.startPrank(ADMIN);
        faucet.setTokenDailyCap(address(vUsdt), 0); // 关键：否则仍会先触发 OVER_DAILY_CAP
        faucet.sweepToken(address(vUsdt), vUsdt.balanceOf(address(faucet))); // 清空库存
        vm.stopPrank();

        // 3) 余额为 0，请求 100 → 命中 VAULT_LOW
        FaucetV2.ClaimReq memory vaultReq = _buildClaim(100, 12);
        bytes memory sig3 = _signClaim(vaultReq);
        vm.expectRevert(abi.encodeWithSelector(FaucetV2.VAULT_LOW.selector, address(vUsdt), uint256(100), uint256(0)));
        _relayedClaim(vaultReq, sig3);
    }

    // 测试：跨天后累计清零，可再次领取
    function testClaimWithSigResetsAcrossDay() public {
        FaucetV2.ClaimReq memory req = _buildClaim(1_000_000, 13);
        bytes memory sig = _signClaim(req);
        _relayedClaim(req, sig);

        uint256 nextTs = block.timestamp + 1 days + 1;
        vm.warp(nextTs); // 跨天（+1 秒避免边界）
        FaucetV2.ClaimReq memory nextDay = _buildClaim(1_000_000, 14);
        nextDay.day = faucet.currentDay(); // 重新绑定新的 day
        nextDay.deadline = nextTs + 1 hours; // 新签名需匹配当前时间窗口
        bytes memory sig2 = _signClaim(nextDay);
        _relayedClaim(nextDay, sig2);

        assertEq(vUsdt.balanceOf(USER), 2_000_000, "Claims should reset after day boundary");
    }

    // ---------------------------------------------------------------------
    //          Pausable 熔断覆盖
    // ---------------------------------------------------------------------

    // 测试：pause 后敏感路径均应 EnforcedPause；unpause 后恢复
    function testPauseAndUnpauseGuardCriticalFlows() public {
        vm.startPrank(ADMIN);
        faucet.pause();
        vm.stopPrank();

        FaucetV2.ClaimReq memory req = _buildClaim(1, 20);
        bytes memory sig = _signClaim(req);

        // OZ v5：自定义错误 selector 断言
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _relayedClaim(req, sig);

        vm.startPrank(ADMIN);
        faucet.setPassPriceWei(1 ether);
        vm.stopPrank();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        faucet.payPass{value: 1 ether}();

        vm.startPrank(ADMIN);
        faucet.unpause();
        vm.stopPrank();

        // 恢复后成功
        _relayedClaim(req, sig);
    }

    // ---------------------------------------------------------------------
    //          Receive 函数
    // ---------------------------------------------------------------------

    // 测试：允许直接向合约转 ETH（收入/意外注入）
    function testReceiveAcceptsEther() public {
        vm.deal(OTHER, 1 ether); // 给 OTHER 打钱，便于发起转账
        vm.startPrank(OTHER);
        (bool ok,) = address(faucet).call{value: 1 ether}(""); // 低级调用转 ETH；返回 (success, returndata)
        vm.stopPrank();
        require(ok, "ETH transfer should succeed");
        assertEq(address(faucet).balance, 1 ether, "Contract should receive ETH");
    }
}
