// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GuardedRouter} from "src/guard/GuardedRouter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";
import {MockOracleRouter, MockV2Factory, MockV2Pair} from "./Mock.sol";

contract GuardedRouterTest is Test {
    GuardedRouter private guard;
    MockOracleRouter private oracle;
    MockV2Factory private factory;
    MockV2Pair private pair;

    address private constant BASE = address(0xBEEF);
    address private constant QUOTE = address(0xA11CE);
    address private constant USER = address(0x2222);

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new MockOracleRouter();
        factory = new MockV2Factory();
        guard = new GuardedRouter(address(factory), address(oracle), 400, 800, 1 hours, address(this));

        pair = new MockV2Pair(BASE, QUOTE, 1_000_000, 2_000_000);
        factory.setPair(BASE, QUOTE, address(pair));
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.UsdSplit);
    }

    function testCheckPriceNowHappyPath() public view {
        (uint256 dexMid, uint256 oraclePx, uint256 ts, bool stale, uint16 limit, bool fixedSrc) =
            guard.checkPriceNow(BASE, QUOTE);
        assertEq(dexMid, 2e18, "dex mid");
        assertEq(oraclePx, 2e18, "oracle px");
        assertEq(ts, block.timestamp, "timestamp");
        assertFalse(stale, "should not be stale");
        assertEq(limit, 400, "limit");
        assertFalse(fixedSrc, "src should be usd split");
    }

    function testCheckPriceNowFixedSourceUsesRelaxedLimit() public {
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.Fixed);
        (,,,, uint16 limit, bool fixedSrc) = guard.checkPriceNow(BASE, QUOTE);
        assertTrue(fixedSrc, "src fixed");
        assertEq(limit, 800, "fixed limit uses hardBpsFixed");
    }

    function testCheckPriceNowHandlesReversedPairOrder() public {
        MockV2Pair flipped = new MockV2Pair(QUOTE, BASE, 2_000_000, 1_000_000);
        factory.setPair(BASE, QUOTE, address(flipped));

        (uint256 dexMid, uint256 oraclePx, uint256 ts, bool stale, uint16 limit, bool fixedSrc) =
            guard.checkPriceNow(BASE, QUOTE);
        assertEq(dexMid, 2e18, "dex price should stay aligned");
        assertEq(oraclePx, 2e18, "oracle unchanged");
        assertEq(ts, block.timestamp, "timestamp preserved");
        assertFalse(stale, "not stale");
        assertEq(limit, 400, "default limit");
        assertFalse(fixedSrc, "still USD split source");
    }

    function testCheckSwapExactInWithinThresholdOk() public view {
        address[] memory path = new address[](2);
        path[0] = BASE;
        path[1] = QUOTE;

        (bool ok, uint256 devBps, uint256 limit, bool stale, uint256 dexAfter, uint256 oraclePx) =
            guard.checkSwapExactIn(path, 10_000);
        assertTrue(ok, "should pass");
        assertTrue(devBps < limit, "dev under limit");
        assertFalse(stale, "not stale");
        assertGt(dexAfter, 0, "dex after");
        assertEq(oraclePx, 2e18, "oracle");
    }

    function testCheckSwapExactInDeviationFails() public {
        pair.setReserves(1_000_000, 1_000_000); // price 1 instead of 2
        address[] memory path = new address[](2);
        path[0] = BASE;
        path[1] = QUOTE;

        (bool ok, uint256 devBps, uint256 limit, bool stale,,) = guard.checkSwapExactIn(path, 10_000);
        assertFalse(stale, "not stale");
        assertGt(devBps, limit, "deviation exceeds limit");
        assertFalse(ok, "should fail");
    }

    function testCheckSwapExactInMarksStaleWhenTimestampOld() public {
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp - 2 hours, IOracleRouter.PriceSrc.UsdSplit);
        address[] memory path = new address[](2);
        path[0] = BASE;
        path[1] = QUOTE;

        (bool ok,, uint256 limit, bool stale,,) = guard.checkSwapExactIn(path, 10_000);
        assertTrue(stale, "stale oracle");
        assertFalse(ok, "stale should fail");
        assertEq(limit, 400, "limit stays default");
    }

    function testCheckSwapExactInReturnsFalseWhenPairMissing() public {
        address otherBase = address(0x1234);
        oracle.setPairPrice(otherBase, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.UsdSplit);

        (bool ok, uint256 devBps, uint256 limit, bool stale, uint256 dexAfter, uint256 oraclePx) =
            guard.checkSwapExactIn(_path(otherBase, QUOTE), 10_000);
        assertFalse(ok, "missing pair should fail");
        assertEq(devBps, 0, "dev zero without reserves");
        assertFalse(stale, "oracle fresh");
        assertEq(limit, 400, "uses default limit");
        assertEq(dexAfter, 0, "dex price zero");
        assertEq(oraclePx, 2e18, "oracle returned");
    }

    function testCheckSwapExactOutReturnsInAmount() public view {
        address[] memory path = new address[](2);
        path[0] = BASE;
        path[1] = QUOTE;

        (bool ok,, uint256 limit, bool stale,, uint256 oraclePx, uint256 amountIn) =
            guard.checkSwapExactOut(path, 50_000);
        assertTrue(ok, "should pass exact out");
        assertFalse(stale, "not stale");
        assertEq(limit, 400, "limit");
        assertEq(oraclePx, 2e18, "oracle");
        assertGt(amountIn, 0, "amount in computed");
    }

    function testCheckSwapExactOutFailsWhenAmountExceedsReserves() public view {
        (bool ok, uint256 devBps, uint256 limit, bool stale, uint256 dexAfter, uint256 oraclePx, uint256 amountIn) =
            guard.checkSwapExactOut(_path(BASE, QUOTE), 2_000_000);
        assertFalse(ok, "should fail");
        assertEq(devBps, 0, "dev zero");
        assertFalse(stale, "oracle fresh");
        assertEq(limit, 400, "limit remains default");
        assertEq(dexAfter, 0, "no dex price");
        assertEq(oraclePx, 2e18, "oracle");
        assertEq(amountIn, 0, "no input computed");
    }

    function testCheckSwapExactOutMarksStaleWithOverride() public {
        guard.setPairCfg(BASE, QUOTE, GuardedRouter.PairCfg({hardBps: 0, staleSec: 30, enabled: 1}));
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp - 31, IOracleRouter.PriceSrc.UsdSplit);

        (bool ok,, uint256 limit, bool stale,, uint256 oraclePx,) = guard.checkSwapExactOut(_path(BASE, QUOTE), 50_000);
        assertTrue(stale, "override stale threshold reached");
        assertFalse(ok, "stale should fail");
        assertEq(limit, 400, "limit fallback to default");
        assertEq(oraclePx, 2e18, "oracle price returned");
    }

    function testPairOverrideUsesCustomLimit() public {
        GuardedRouter.PairCfg memory cfg = GuardedRouter.PairCfg({hardBps: 5_000, staleSec: 0, enabled: 1});
        guard.setPairCfg(BASE, QUOTE, cfg);

        pair.setReserves(1_000_000, 1_200_000); // price 1.2 -> 40% deviation
        address[] memory path = new address[](2);
        path[0] = BASE;
        path[1] = QUOTE;

        (bool ok, uint256 devBps, uint256 limit,,,) = guard.checkSwapExactIn(path, 10_000);
        assertEq(limit, 5_000, "override limit");
        assertLt(devBps, limit, "dev within override");
        assertTrue(ok, "override allows swap");
    }

    function testPairOverrideCustomStaleThresholdTriggersEarlier() public {
        GuardedRouter.PairCfg memory cfg = GuardedRouter.PairCfg({hardBps: 0, staleSec: 30, enabled: 1});
        guard.setPairCfg(BASE, QUOTE, cfg);

        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp - 31, IOracleRouter.PriceSrc.UsdSplit);
        (bool ok,, uint256 limit, bool stale,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 10_000);
        assertTrue(stale, "override stale threshold reached");
        assertFalse(ok, "stale should fail");
        assertEq(limit, 400, "hard bps fallback to default when zero");
    }

    function testPairConfigDisableFallsBackToDefaults() public {
        guard.setDefaults(450, 900, 2 hours);
        guard.setPairCfg(BASE, QUOTE, GuardedRouter.PairCfg({hardBps: 600, staleSec: 7200, enabled: 1}));

        (bool okOverride,, uint256 limitOverride,,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 5_000);
        assertTrue(okOverride, "override still allows swap");
        assertEq(limitOverride, 600, "override limit active");

        guard.setPairCfg(BASE, QUOTE, GuardedRouter.PairCfg({hardBps: 0, staleSec: 0, enabled: 0}));

        (bool okFallback,, uint256 limitFallback,,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 5_000);
        assertTrue(okFallback, "fallback still ok");
        assertEq(limitFallback, 450, "defaults restored");
    }

    function testCheckSwapExactInFixedSourceUsesRelaxedLimit() public {
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.Fixed);
        (bool ok, uint256 devBps, uint256 limit, bool stale,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 10_000);
        assertTrue(ok, "fixed source should pass");
        assertFalse(stale, "fixed price source never stale");
        assertEq(limit, 800, "default relaxed limit applies");
        assertLt(devBps, limit, "deviation within relaxed range");
    }

    function testCheckSwapExactInFixedSourceUsesPairOverride() public {
        GuardedRouter.PairCfg memory cfg = GuardedRouter.PairCfg({hardBps: 1_200, staleSec: 0, enabled: 1});
        guard.setPairCfg(BASE, QUOTE, cfg);
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.Fixed);

        (bool ok, uint256 devBps, uint256 limit,,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 10_000);
        assertTrue(ok, "override keeps swap allowed");
        assertEq(limit, 1_200, "override limit takes precedence");
        assertLt(devBps, limit, "deviation below override");
    }

    function testCheckSwapExactInHandlesReversedPairOrder() public {
        MockV2Pair flipped = new MockV2Pair(QUOTE, BASE, 2_000_000, 1_000_000);
        factory.setPair(BASE, QUOTE, address(flipped));

        (bool ok,, uint256 limit, bool stale, uint256 dexAfter,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 10_000);
        assertTrue(ok, "reversed pair should still pass");
        assertFalse(stale, "oracle fresh");
        assertEq(limit, 400, "defaults still apply");
        assertGt(dexAfter, 0, "price computed");
    }

    function testCheckSwapExactInHandlesBaseAsToken1() public {
        (bool ok,, uint256 limit, bool stale, uint256 dexAfter, uint256 oraclePx) =
            guard.checkSwapExactIn(_path(QUOTE, BASE), 10_000);
        assertFalse(ok, "orientation should fail without direct oracle price");
        assertFalse(stale, "oracle fresh");
        assertEq(limit, 400, "defaults in effect");
        assertGt(dexAfter, 0, "dex price still computed");
        assertEq(oraclePx, 2e18, "oracle still returns base/quote price");
    }

    function testSetOracleRouterZeroAddressReverts() public {
        vm.expectRevert(GuardedRouter.ZeroAddress.selector);
        guard.setOracleRouter(address(0));
    }

    function testSetOracleRouterOnlyOwner() public {
        MockOracleRouter newOracle = new MockOracleRouter();
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        guard.setOracleRouter(address(newOracle));

        guard.setOracleRouter(address(newOracle));
        oracle = newOracle;
        oracle.setPairPrice(BASE, QUOTE, 2e18, block.timestamp, IOracleRouter.PriceSrc.UsdSplit);
        (bool ok,,,,,) = guard.checkSwapExactIn(_path(BASE, QUOTE), 5_000);
        assertTrue(ok, "still functional after router switch");
    }

    function testSetDefaultsUpdatesGlobalPolicy() public {
        guard.setDefaults(300, 900, 30 minutes);
        (bool ok,, uint256 limit, bool stale,, uint256 oraclePx) = guard.checkSwapExactIn(_path(BASE, QUOTE), 5_000);
        assertTrue(ok, "should pass");
        assertEq(oraclePx, 2e18);
        assertEq(limit, 300, "new limit");
        assertFalse(stale);
    }

    function testSetDefaultsOnlyOwner() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        guard.setDefaults(300, 900, 30 minutes);
    }

    function testSetPairCfgOnlyOwner() public {
        GuardedRouter.PairCfg memory cfg = GuardedRouter.PairCfg({hardBps: 100, staleSec: 100, enabled: 1});
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        guard.setPairCfg(BASE, QUOTE, cfg);
    }

    function testCheckSwapExactInRevertsOnBadPathLength() public {
        address[] memory bad = new address[](1);
        bad[0] = BASE;
        vm.expectRevert(GuardedRouter.PathLength.selector);
        guard.checkSwapExactIn(bad, 10_000);
    }

    function testCheckSwapExactInRevertsOnDuplicatePath() public {
        address[] memory bad = new address[](2);
        bad[0] = BASE;
        bad[1] = BASE;
        vm.expectRevert(GuardedRouter.PathArgs.selector);
        guard.checkSwapExactIn(bad, 10_000);
    }

    function testCheckSwapExactInRevertsWhenPathContainsZero() public {
        address[] memory bad = new address[](2);
        bad[0] = address(0);
        bad[1] = QUOTE;
        vm.expectRevert(GuardedRouter.PathArgs.selector);
        guard.checkSwapExactIn(bad, 10_000);
    }

    function testCheckPriceNowReturnsZeroWhenNoPair() public view {
        (uint256 dex,,, bool stale,,) = guard.checkPriceNow(BASE, address(0xDEAD));
        assertEq(dex, 0);
        assertTrue(stale);
    }

    // helper to build path
    function _path(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
