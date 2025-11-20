// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ChainlinkOracle} from "src/oracle/ChainlinkOracle.sol"; // 调整为你的真实路径
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";
import {MockAggregatorV3} from "./Mock.sol";

contract ChainlinkOracleTest is Test {
    using stdStorage for StdStorage;

    ChainlinkOracle private oracle;
    address private owner = address(0xA11CE);
    address private alice = address(0xBEEF);

    // 随机模拟 token 地址
    address private TOKEN_A = address(0xAAA1);
    address private TOKEN_B = address(0xBBB2);
    address private TOKEN_C = address(0xCCC3);

    // 聚合器 mock
    MockAggregatorV3 private agg8; // 8位小数（常见）
    MockAggregatorV3 private agg18; // 18位
    MockAggregatorV3 private agg20; // >18 位，用于除法路径

    function setUp() public {
        vm.warp(1_700_000_000); // 固定一个块时间，方便断言
        oracle = new ChainlinkOracle(owner);

        agg8 = new MockAggregatorV3(8, 123456789, 1_700_000_000); // 1.23456789
        agg18 = new MockAggregatorV3(18, 2e18, 1_700_000_001); // 2.0
        agg20 = new MockAggregatorV3(20, 345e18, 1_700_000_002); // 3.45 (因20位，答案需配合理解)

        // 预置：owner 配置若干 feed
        vm.startPrank(owner);
        // TOKEN_A: 使用 agg8，且缓存 aggDecimals=0 -> 走 aggregator.decimals()
        oracle.setUSDFeed(
            TOKEN_A,
            ChainlinkOracle.FeedUSD({
                aggregator: address(agg8),
                aggDecimals: 0, // 触发运行时读取 decimals()
                fixedUsdE18: 0
            })
        );

        // TOKEN_B: 使用 agg18，且缓存 aggDecimals=18 -> 不读取链上 decimals()
        oracle.setUSDFeed(
            TOKEN_B, ChainlinkOracle.FeedUSD({aggregator: address(agg18), aggDecimals: 18, fixedUsdE18: 0})
        );

        // TOKEN_C: 无喂价，固定锚价 1 USD
        oracle.setUSDFeed(
            TOKEN_C, ChainlinkOracle.FeedUSD({aggregator: address(0), aggDecimals: 0, fixedUsdE18: uint88(1e18)})
        );
        vm.stopPrank();
    }

    // ========== constructor & onlyOwner ==========

    function test_constructor_setsOwner() external {
        // Ownable2Step 的 owner() 在父类，直接检测权限行为更稳
        vm.prank(alice);
        ChainlinkOracle.FeedUSD memory cfg =
            ChainlinkOracle.FeedUSD({aggregator: address(agg20), aggDecimals: 20, fixedUsdE18: 0});
        vm.expectRevert(); // 非 owner 调用应 revert
        oracle.setUSDFeed(TOKEN_A, cfg);
    }

    // ========== 事件 & 存储更新（覆盖 setUSDFeed） ==========

    function test_setUSDFeed_emitsEventAndStores() external {
        vm.startPrank(owner);
        ChainlinkOracle.FeedUSD memory cfg =
            ChainlinkOracle.FeedUSD({aggregator: address(agg20), aggDecimals: 20, fixedUsdE18: 0});

        vm.expectEmit(true, true, true, true);
        emit ChainlinkOracle.USDFeedUpdated(TOKEN_A, address(agg20), 20, 0);
        oracle.setUSDFeed(TOKEN_A, cfg);

        // 读回验证（通过公开 mapping getter）
        (address agg, uint8 d, uint88 fix) = oracle.usdFeeds(TOKEN_A);
        assertEq(agg, address(agg20));
        assertEq(d, 20);
        assertEq(fix, 0);
        vm.stopPrank();
    }

    // ========== getUSDPrice: Fixed 分支（aggregator=0） ==========

    function test_getUSDPrice_Fixed() external view {
        (uint256 px, uint256 ts) = oracle.getUSDPrice(TOKEN_C);
        assertEq(px, 1e18);
        assertEq(ts, block.timestamp); // 固定价按设计返回当前块时间
    }

    // ========== getUSDPrice: Usd 分支，aggDecimals=0 -> 走 decimals() 读取 ==========

    function test_getUSDPrice_UsesAggregatorDecimals_WhenCacheIsZero() external view {
        // TOKEN_A 绑定 agg8：answer=123456789, decimals=8 => 1.23456789 USD
        (uint256 px, uint256 ts) = oracle.getUSDPrice(TOKEN_A);
        // 转成 1e18：1.23456789 * 1e18
        assertEq(px, 1_234_567_890_000_000_000); // 1.23456789e18
        assertEq(ts, 1_700_000_000);
    }

    // ========== getUSDPrice: Usd 分支，使用缓存的 aggDecimals（不触发 view 调用） ==========

    function test_getUSDPrice_UsesCachedDecimals_WhenNonZero() external view {
        // TOKEN_B 缓存了 aggDecimals=18; answer=2e18，保持 2e18 不变
        (uint256 px, uint256 ts) = oracle.getUSDPrice(TOKEN_B);
        assertEq(px, 2e18);
        assertEq(ts, 1_700_000_001);
    }

    // ========== getUSDPrice: d > 18 触发除法路径；d < 18 触发乘法路径 ==========

    function test_getUSDPrice_DecimalsGreaterThan18_DivPath() external {
        vm.startPrank(owner);
        oracle.setUSDFeed(
            address(0xDD01), ChainlinkOracle.FeedUSD({aggregator: address(agg20), aggDecimals: 0, fixedUsdE18: 0})
        );
        vm.stopPrank();

        (uint256 px,) = oracle.getUSDPrice(address(0xDD01));
        // agg20: decimals=20, answer=345e18 表示 3.45 * 10^(20-18) ? 注意：实现是：
        // u=345e18; d=20 -> px = u / 10^(d-18) = 345e18 / 10^2 = 3.45e18
        assertEq(px, 3_450_000_000_000_000_000); // 3.45e18
    }

    function test_getUSDPrice_DecimalsLessThan18_MulPath() external view {
        // TOKEN_A 已经是 d=8（mul 路径），上一测试已验证；此处再覆盖一次确保分支统计
        (uint256 px,) = oracle.getUSDPrice(TOKEN_A);
        assertEq(px, 1_234_567_890_000_000_000);
    }

    // ========== getUSDPrice: 负数答案触发 OracleBadAnswer ==========

    function test_getUSDPrice_RevertOnNegativeAnswer() external {
        agg18.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.OracleBadAnswer.selector, address(agg18)));
        oracle.getUSDPrice(TOKEN_B);
    }

    // ========== latestAnswer 组合：四种 src & 时间规则 ==========

    function test_latestAnswer_BothFixed() external {
        // 把 TOKEN_A 改为 Fixed；TOKEN_C 已是 Fixed
        vm.startPrank(owner);
        oracle.setUSDFeed(
            TOKEN_A,
            ChainlinkOracle.FeedUSD({aggregator: address(0), aggDecimals: 0, fixedUsdE18: uint88(2e18)}) // 2 USD
        );
        vm.stopPrank();

        (uint256 price, uint256 ts, IOracleRouter.PriceSrc src) = oracle.latestAnswer(TOKEN_A, TOKEN_C);
        // (2 / 1) * 1e18 = 2e18
        assertEq(price, 2e18);
        assertEq(uint256(src), uint256(IOracleRouter.PriceSrc.Fixed));
        assertEq(ts, block.timestamp); // 双 Fixed：返回当前块时间
    }

    function test_latestAnswer_BaseFixed_QuoteUsd() external view {
        // base: TOKEN_C=1 USD (Fixed), quote: TOKEN_B=2 USD (Usd)
        (uint256 price, uint256 ts, IOracleRouter.PriceSrc src) = oracle.latestAnswer(TOKEN_C, TOKEN_B);
        // (1 / 2) * 1e18
        assertEq(price, 5e17); // 0.5e18
        assertEq(uint256(src), uint256(IOracleRouter.PriceSrc.Fixed));
        assertEq(ts, 1_700_000_001); // 取非 Fixed 一侧（quote）的时间
    }

    function test_latestAnswer_QuoteFixed_BaseUsd() external view {
        // base: TOKEN_B=2 USD (Usd), quote: TOKEN_C=1 USD (Fixed)
        (uint256 price, uint256 ts, IOracleRouter.PriceSrc src) = oracle.latestAnswer(TOKEN_B, TOKEN_C);
        assertEq(price, 2e18);
        assertEq(uint256(src), uint256(IOracleRouter.PriceSrc.Fixed));
        assertEq(ts, 1_700_000_001); // 取非 Fixed 一侧（base）的时间
    }

    function test_latestAnswer_UsdSplit_BothFromFeeds_MinTimestamp() external view {
        // base: TOKEN_A(ts=1_700_000_000), quote: TOKEN_B(ts=1_700_000_001)
        (uint256 price, uint256 ts, IOracleRouter.PriceSrc src) = oracle.latestAnswer(TOKEN_A, TOKEN_B);
        // base/usd = 1.23456789; quote/usd = 2
        // price = (1.23456789 * 1e18) / 2 = 0.617283945e18
        assertEq(price, 617_283_945_000_000_000);
        assertEq(uint256(src), uint256(IOracleRouter.PriceSrc.UsdSplit));
        assertEq(ts, 1_700_000_000); // 取更旧的一侧
    }

    // ========== latestAnswer: 除数为 0 触发 OracleQuoteZero ==========

    function test_latestAnswer_RevertOnQuoteZero() external {
        // quote 配 Fixed=0（极端测试，不建议生产使用），从而 qPx == 0
        vm.startPrank(owner);
        oracle.setUSDFeed(TOKEN_C, ChainlinkOracle.FeedUSD({aggregator: address(0), aggDecimals: 0, fixedUsdE18: 0}));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.OracleQuoteZero.selector, TOKEN_C));
        oracle.latestAnswer(TOKEN_A, TOKEN_C);
    }
}
