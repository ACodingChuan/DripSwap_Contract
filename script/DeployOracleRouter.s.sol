// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";
import {ChainlinkOracle} from "src/oracle/ChainlinkOracle.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

contract DeployOracleRouter is Script {
    using stdJson for string;

    string internal constant BOOK  = "deployments/local.m1.json";
    string internal constant FEEDS = "configs/feeds.sepolia.json";

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1) 部署 Oracle（传入 initialOwner）
        ChainlinkOracle orc = new ChainlinkOracle(owner);
        console2.log("OracleRouter:", address(orc));

        // 2) 读取 feeds 配置并落到合约
        string memory jf = vm.readFile(FEEDS);

        // 读取代币列表：优先 ".symbols"，否则用默认 6 个
        string[] memory keys;
        try this._readSymbols(jf) returns (string[] memory syms) {
            keys = syms;
        } catch {
            keys = _defaultSymbols();
        }

        for (uint i = 0; i < keys.length; i++) {
            string memory sym = keys[i];
            string memory base = string.concat(".feeds.", sym, ".");
            string memory typ  = jf.readString(string.concat(base, "type"));

            // 解析地址簿中的 token 地址
            address token = _symToAddr(sym);

            // 组装 FeedUSD 结构
            ChainlinkOracle.FeedUSD memory cfg;

            if (_eq(typ, "fixed")) {
                // fixed: aggregator=0, fixedUSDE18 必须能放进 uint88
                uint256 pxE18 = vm.parseUint(jf.readString(string.concat(base, "priceE18")));
                require(pxE18 <= type(uint88).max, "fixed priceE18 > uint88 max");
                cfg = ChainlinkOracle.FeedUSD({
                    aggregator: address(0),
                    aggDecimals: 0,
                    fixedUSDE18: uint88(pxE18)
                });
                orc.setUSDFeed(token, cfg);
                console2.log("[feed] fixed ", sym, pxE18);
            } else if (_eq(typ, "chainlink")) {
                address agg = vm.parseAddress(jf.readString(string.concat(base, "aggregator")));
                uint8   dec = uint8(vm.parseUint(jf.readString(string.concat(base, "aggDecimals"))));
                cfg = ChainlinkOracle.FeedUSD({
                    aggregator: agg,
                    aggDecimals: dec,
                    fixedUSDE18: 0
                });
                orc.setUSDFeed(token, cfg);
                console2.log("[feed] chainlink ", sym, agg, dec);
            } else {
                revert("Unknown feed type");
            }
        }

        // 3) 简单自检（若全是 fixed 也能返回）
        (uint256 px, uint256 ts, IOracleRouter.PriceSrc src) =
            IOracleRouter(address(orc)).latestAnswer(_symToAddr("vETH"), _symToAddr("vUSDT"));
            console2.log(
                 string.concat(
                 "latestAnswer(vETH,vUSDT) => px=",
                  vm.toString(px),
                  ", ts=",
                  vm.toString(ts),
                  ", src=",
                  vm.toString(uint256(src))));

        // 4) 写地址簿
        string memory book = vm.readFile(BOOK);
        book = book.serialize("oracle.router", address(orc));
        vm.writeJson(book, BOOK);
        console2.log("AddressBook updated:", BOOK);

        vm.stopBroadcast();
    }

    // ========== 工具函数 ==========

    // 从地址簿 tokens 节点把符号映射到地址
    function _symToAddr(string memory sym)  internal view returns (address) {
        string memory book = vm.readFile(BOOK);
        string memory path = string.concat(".tokens.", sym, ".address");
        return vm.parseAddress(book.readString(path));
    }

    // 读取 ".symbols"（Foundry 新版 cheatcode），不存在会 revert
    function _readSymbols(string memory jf) external pure returns (string[] memory) {
        return vm.parseJsonStringArray(jf, ".symbols");
    }

    function _defaultSymbols() internal pure returns (string[] memory arr) {
        arr = new string[](6);
        arr[0] = "vETH";
        arr[1] = "vBTC";
        arr[2] = "vLINK";
        arr[3] = "vUSDT";
        arr[4] = "vUSDC";
        arr[5] = "vDAI";
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
