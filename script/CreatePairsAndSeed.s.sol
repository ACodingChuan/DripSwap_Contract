// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {IUniswapV2Factory}  from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router01} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import {IUniswapV2Pair}     from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IERC20}             from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

/// @notice 读取 configs/pairs.json，批量创建 pairs 并按“最小100 USD + 目标20bps”自动首注
/// @dev    - 读取数组用 vm.parseJson + abi.decode（stdJson 没有 readArray）
///         - log 统一使用 string.concat + vm.toString，避免重载不匹配
contract CreatePairsAndSeed is Script {
    using stdJson for string;

    string internal constant BOOK  = "deployments/local.m1.json";
    string internal constant PAIRS = "configs/pairs.json";

    uint256 constant ONE_E18 = 1e18;

    struct PairSpec {
        string base;
        string quote;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);

        // --- 读取地址簿 ---
        string memory book = vm.readFile(BOOK);
        address factory = vm.parseAddress(book.readString(".v2.factory"));
        address router  = vm.parseAddress(book.readString(".v2.router"));
        address oracle  = vm.parseAddress(book.readString(".oracle.router"));

        // --- 读取配置 ---
        string memory cfg = vm.readFile(PAIRS);

        // 1) pairs 数组（对象数组） -> 先 parseJson 返回 bytes，再 abi.decode
        bytes memory raw = vm.parseJson(cfg, ".pairs");
        PairSpec[] memory pairs = abi.decode(raw, (PairSpec[]));

        // 2) 其他参数
        uint256 minQuoteUsd = vm.parseUint(cfg.readString(".seedPolicy.minQuoteUsdE18"));
        uint256 targetBps   = vm.parseUint(cfg.readString(".seedPolicy.slippageBpsTarget"));

        // --- 主循环：创建 + 首注 ---
        for (uint i = 0; i < pairs.length; i++) {
            string memory baseSym  = pairs[i].base;
            string memory quoteSym = pairs[i].quote;

            address base  = _symToAddr(baseSym);
            address quote = _symToAddr(quoteSym);

            // 1) createPair（已存在则复用）
            address pair = IUniswapV2Factory(factory).getPair(base, quote);
            if (pair == address(0)) {
                pair = IUniswapV2Factory(factory).createPair(base, quote);
                console2.log(string.concat("createPair ", baseSym, "/", quoteSym, " -> ", _toHex(pair)));
            } else {
                console2.log(string.concat("pair exists ", baseSym, "/", quoteSym, " -> ", _toHex(pair)));
            }

            // 2) 取 oracle 公允价（base/quote, 1e18）
            (uint256 pxE18,,) = IOracleRouter(oracle).latestAnswer(base, quote);
            require(pxE18 > 0, "oracle px=0");

            // 3) 粗略初值：从 quote 侧满足最小 USD
            uint256 amountQuote = minQuoteUsd;
            uint256 amountBase  = (amountQuote * ONE_E18) / pxE18;

            // 4) 试算深度：以 testIn=amountBase/10 估算偏离 > targetBps 则同比放大
            (uint256 devBps,) = _estimateDevAfterExactIn(factory, base, quote, amountBase, amountQuote, amountBase/10, pxE18);
            uint256 iter;
            while (devBps > targetBps && iter < 8) {
                amountBase  <<= 1;
                amountQuote <<= 1;
                (devBps,) = _estimateDevAfterExactIn(factory, base, quote, amountBase, amountQuote, amountBase/10, pxE18);
                iter++;
            }

            // 5) 执行首注
            IERC20(base).approve(router, type(uint256).max);
            IERC20(quote).approve(router, type(uint256).max);

            IUniswapV2Router01(router).addLiquidity(
                base, quote,
                amountBase, amountQuote,
                0, 0,
                vm.addr(pk),
                block.timestamp + 600
            );

            // 6) 写回地址簿（记录 pair 地址）
            string memory key = string.concat("v2.pairs.", baseSym, "_", quoteSym);
            book = book.serialize(key, pair);

            // 7) 打印：初始 mid 与 oracle 偏离
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
            address t0 = IUniswapV2Pair(pair).token0();
            uint256 midE18 = (t0 == base)
                ? (uint256(r1) * ONE_E18) / uint256(r0)
                : (uint256(r0) * ONE_E18) / uint256(r1);
            uint256 dev0 = _devBps(midE18, pxE18);

            console2.log(
                string.concat(
                    "seeded ", baseSym, "/", quoteSym,
                    " mid=", vm.toString(midE18),
                    " oracle=", vm.toString(pxE18),
                    " devBps=", vm.toString(dev0)
                )
            );
        }

        vm.writeJson(book, BOOK);
        console2.log(string.concat("AddressBook updated: ", BOOK));

        vm.stopBroadcast();
    }

    // ---------- 工具 ----------

    function _symToAddr(string memory sym) internal view returns (address) {
        string memory book = vm.readFile(BOOK);
        string memory path = string.concat(".tokens.", sym, ".address");
        return vm.parseAddress(book.readString(path));
    }

    /// @dev 估算：给定 seed(base,quote) 后，试算一笔 exact-in，对比 oracle 偏离
    function _estimateDevAfterExactIn(
        address factory,
        address base,
        address quote,
        uint256 seedBase,
        uint256 seedQuote,
        uint256 testInBase,
        uint256 oraclePxE18
    ) internal view returns (uint256 devBps, uint256 afterMidE18) {
        address pair = IUniswapV2Factory(factory).getPair(base, quote);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();

        uint256 inRes  = (t0 == base) ? uint256(r0) + seedBase  : uint256(r1) + seedBase;
        uint256 outRes = (t0 == base) ? uint256(r1) + seedQuote : uint256(r0) + seedQuote;

        uint256 inWithFee = testInBase * 997;
        uint256 out = (inWithFee * outRes) / (inRes * 1000 + inWithFee);

        uint256 newIn  = inRes + testInBase;
        uint256 newOut = outRes - out;

        afterMidE18 = (newOut * ONE_E18) / newIn;
        devBps = _devBps(afterMidE18, oraclePxE18);
    }

    function _devBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return type(uint256).max;
        unchecked {
            return a > b ? ((a - b) * 10_000) / b : ((b - a) * 10_000) / b;
        }
    }

    // 把地址转十六进制字符串（用于日志）
    function _toHex(address a) internal pure returns (string memory) {
        bytes20 data = bytes20(a);
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory str = new bytes(2 + 40);
        str[0] = "0";
        str[1] = "x";
        for (uint i = 0; i < 20; i++) {
            str[2 + i*2]     = hexSymbols[uint8(data[i] >> 4)];
            str[2 + i*2 + 1] = hexSymbols[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
