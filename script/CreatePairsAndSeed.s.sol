// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*──────────────────────────────────────────────────────────────────────────────
CreatePairsAndSeed（精简版：不做交换测试 & 不计算部署后偏差）
- 读取地址簿与配置
- 按 oracle 价格 + token decimals 归一化，计算首注数量
- 创建/复用 pair，addLiquidity 首注
- 写回 pair 地址
──────────────────────────────────────────────────────────────────────────────*/

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router01} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

contract CreatePairsAndSeed is Script {
    using stdJson for string;

    uint256 constant ONE_E18 = 1e18;

    struct PairSpec {
        string base;   // 例：vBTC
        string quote;  // 例：vUSDT
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);

        string memory bookPath  = _bookPath();
        string memory pairsPath = _pairsPath();

        // --- 地址簿 ---
        string memory book = vm.readFile(bookPath);
        address factory = vm.parseAddress(book.readString(".v2.factory"));
        address router  = vm.parseAddress(book.readString(".v2.router"));
        address oracle  = vm.parseAddress(book.readString(".oracle.router"));

        // --- 配置 ---
        string memory cfg = vm.readFile(pairsPath);
        bytes memory rawPairs = vm.parseJson(cfg, ".pairs");
        PairSpec[] memory pairs = abi.decode(rawPairs, (PairSpec[]));
        string[] memory pairPaths = new string[](pairs.length);
        string[] memory pairAddrs = new string[](pairs.length);

        // 以 1e18 记账的“quote 侧最小美元规模”（例如 $100 -> 1e20）
        uint256 minQuoteUsdE18 = vm.parseUint(
            cfg.readString(".seedPolicy.minQuoteUsdE18")
        );

        for (uint i = 0; i < pairs.length; i++) {
            string memory baseSym  = pairs[i].base;
            string memory quoteSym = pairs[i].quote;

            address base  = _symToAddr(bookPath, baseSym);
            address quote = _symToAddr(bookPath, quoteSym);

            // 1) 获取/创建 pair
            address pair = IUniswapV2Factory(factory).getPair(base, quote);
            if (pair == address(0)) {
                pair = IUniswapV2Factory(factory).createPair(base, quote);
                console2.log(
                    string.concat("createPair ", baseSym, "/", quoteSym, " -> ", _toHex(pair))
                );
            } else {
                console2.log(
                    string.concat("pair exists ", baseSym, "/", quoteSym, " -> ", _toHex(pair))
                );
            }

            // 2) 读 oracle 价格（base/quote，1e18 精度）
            (uint256 pxE18,,) = IOracleRouter(oracle).latestAnswer(base, quote);
            require(pxE18 > 0, "oracle px=0");

            // 2.5) 读 quote 的 USD 价格，确保实际注入的美元规模符合预期
            (uint256 quoteUsdE18,) = IOracleRouter(oracle).getUSDPrice(quote);
            require(quoteUsdE18 > 0, "oracle quote usd=0");

            // 3) 读取 decimals，做单位归一化
            uint8 baseDec  = IERC20Metadata(base).decimals();
            uint8 quoteDec = IERC20Metadata(quote).decimals();

            // 4) 计算首注数量（Peg 到 oracle）
            //
            // 让 quote 侧达到配置的最小美元规模：
            // amountQuote(最小单位) = minQuoteUsdE18 * 10^quoteDec / quoteUsdE18
            uint256 amountQuote = (minQuoteUsdE18 * (10 ** uint256(quoteDec))) / quoteUsdE18;
            if (amountQuote == 0) amountQuote = 1; // 至少 1 最小单位，避免为 0

            // 按价格配出 base 侧数量：
            // amountBase(最小单位) = amountQuote * 1e18 * 10^baseDec / (pxE18 * 10^quoteDec)
            uint256 amountBase = (amountQuote * ONE_E18 * (10 ** uint256(baseDec))) / (pxE18 * (10 ** uint256(quoteDec)));
            if (amountBase == 0) amountBase = 1; // 保底 1 个最小单位

            // 5) 授权（精确授权；也可用 max，视你偏好）
            _safeApprove(base,  router, 0);
            _safeApprove(quote, router, 0);
            _safeApprove(base,  router, amountBase);
            _safeApprove(quote, router, amountQuote);

            // 6) 首次注入流动性（amountAMin/amountBMin=0；生产可改为非 0 以防前置）
            IUniswapV2Router01(router).addLiquidity(
                base,
                quote,
                amountBase,
                amountQuote,
                0,                    // amountAMin（生产可设为 amountBase*(1-pegBps/1e4)）
                0,                    // amountBMin（同上）
                vm.addr(pk),
                block.timestamp + 600
            );

            // 7) 写回地址簿（记录 pair 地址）
            string memory pairPath = string.concat(".v2.pairs.", baseSym, "_", quoteSym);
            pairPaths[i] = pairPath;
            pairAddrs[i] = vm.toString(pair);
        }

        vm.stopBroadcast();

        for (uint i = 0; i < pairs.length; i++) {
            vm.writeJson(pairAddrs[i], bookPath, pairPaths[i]);
        }

        console2.log(string.concat("AddressBook updated: ", bookPath));
    }

    // ---------- 工具 ----------

    function _symToAddr(string memory bookPath, string memory sym) internal view returns (address) {
        string memory book = vm.readFile(bookPath);
        string memory path = string.concat(".tokens.", sym, ".address");
        return vm.parseAddress(book.readString(path));
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        // 简单安全授权（不少 ERC20 需要先清零再授权）
        (bool ok, ) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok, "approve failed");
    }

    function _toHex(address a) internal pure returns (string memory) {
        bytes20 data = bytes20(a);
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0"; str[1] = "x";
        for (uint i = 0; i < 20; i++) {
            str[2 + i * 2]     = hexSymbols[uint8(data[i] >> 4)];
            str[2 + i * 2 + 1] = hexSymbols[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "deployments/local.m1.json";
        if (block.chainid == 11155111) return "deployments/sepolia.m1.json";
        if (block.chainid == 534351) return "deployments/scroll-sepolia.m1.json";
        revert("CreatePairsAndSeed: unsupported chain");
    }

    function _pairsPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "configs/local/pairs.json";
        if (block.chainid == 11155111) return "configs/sepolia/pairs.json";
        if (block.chainid == 534351) return "configs/scroll/pairs.json";
        revert("CreatePairsAndSeed: missing pairs config");
    }
}
