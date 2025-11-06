// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ChainlinkOracle} from "src/oracle/ChainlinkOracle.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

contract DeployOracleRouter is DeployBase {
    using stdJson for string;

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        
        console2.log("=== Deploying Oracle Router ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        _ensureERC2470();

        string memory feedsPath = _feedsPath();
        
        vm.startBroadcast(pk);

        (address orc, bool freshly) = _deployOracle(owner);
        console2.log("OracleRouter:", orc);

        uint256 feedCount = _configureFeeds(orc, feedsPath);

        _bookSetAddress("oracle.router", orc);
        _bookSetAddress("oracle.owner", owner);

        vm.stopBroadcast();
        
        console2.log("");
        console2.log("[OK] Oracle Router deployed/configured");

        if (freshly) {
            string memory mdPath = _deploymentFile("oracle.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[oracle]");
            vm.writeLine(mdPath, string.concat("  address: ", vm.toString(orc)));
            vm.writeLine(mdPath, string.concat("  owner: ", vm.toString(owner)));
            vm.writeLine(mdPath, string.concat("  feeds_configured: ", vm.toString(feedCount)));
        }
    }

    /// @notice 部署Oracle（带幂等性检查）
    function _deployOracle(address owner) internal returns (address deployed, bool freshly) {
        // 生成盐值
        bytes32 salt = keccak256(
            abi.encodePacked(
                "DripSwap",
                "Oracle",
                "ChainlinkOracle"
            )
        );
        
        // 准备字节码
        bytes memory creationCode = type(ChainlinkOracle).creationCode;
        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(owner));

        (deployed, freshly) = _deployDeterministic(bytecode, salt);

        if (freshly) {
            console2.log("Deploying Oracle...");
            console2.log("  init code length:", bytecode.length);
            console2.logBytes32(keccak256(bytecode));
            console2.log("[OK] Oracle deployed");
            console2.log("  Address:", deployed);
        } else {
            console2.log("[SKIP] Oracle already deployed");
            console2.log("  Address:", deployed);
        }
    }

    /// @notice 配置价格源
    function _configureFeeds(address orc, string memory feedsPath) internal returns (uint256 configured) {
        // 读取 feeds 配置
        string memory jf = vm.readFile(feedsPath);

        // 读取代币列表：优先 ".symbols"，否则用默认 6 个
        string[] memory keys;
        try vm.parseJsonStringArray(jf, ".symbols") returns (string[] memory syms) {
            keys = syms;
        } catch {
            keys = _defaultSymbols();
        }

        ChainlinkOracle oracle = ChainlinkOracle(orc);

        for (uint i = 0; i < keys.length; i++) {
            string memory sym = keys[i];
            string memory base = string.concat(".feeds.", sym, ".");
            string memory typ  = jf.readString(string.concat(base, "type"));

            // 解析地址簿中的 token 地址
            address token = _tokenAddress(sym);
            require(token != address(0), string.concat("Token address missing: ", sym));

            // 组装 FeedUSD 结构
            ChainlinkOracle.FeedUSD memory cfg;

            if (_eq(typ, "fixed")) {
                // fixed: aggregator=0, fixedUsdE18 必须能放进 uint88
                uint256 pxE18 = vm.parseUint(jf.readString(string.concat(base, "priceE18")));
                require(pxE18 <= type(uint88).max, "fixed priceE18 > uint88 max");
                cfg = ChainlinkOracle.FeedUSD({
                    aggregator: address(0),
                    aggDecimals: 0,
                    fixedUsdE18: uint88(pxE18)
                });
                oracle.setUSDFeed(token, cfg);
                console2.log("[feed] fixed ", sym, pxE18);
            } else if (_eq(typ, "chainlink")) {
                string memory aggPath = string.concat(base, "aggregator");
                bool hasAggregator = jf.keyExists(aggPath);
                uint8 dec = uint8(vm.parseUint(jf.readString(string.concat(base, "aggDecimals"))));
                if (hasAggregator) {
                    address agg = vm.parseAddress(jf.readString(aggPath));
                    cfg = ChainlinkOracle.FeedUSD({
                        aggregator: agg,
                        aggDecimals: dec,
                        fixedUsdE18: 0
                    });
                    oracle.setUSDFeed(token, cfg);
                    console2.log("[feed] chainlink ", sym, agg, dec);
                } else {
                    uint256 pxE18 = vm.parseUint(jf.readString(string.concat(base, "priceE18")));
                    require(pxE18 <= type(uint88).max, "chainlink priceE18 > uint88 max");
                    cfg = ChainlinkOracle.FeedUSD({
                        aggregator: address(0),
                        aggDecimals: dec,
                        fixedUsdE18: uint88(pxE18)
                    });
                    oracle.setUSDFeed(token, cfg);
                    console2.log("[feed] chainlink (no agg) ", sym, pxE18);
                }
            } else {
                revert("Unknown feed type");
            }

            configured++;
        }

        // 简单自检
        address checkBase = _tokenAddress("vETH");
        address checkQuote = _tokenAddress("vUSDT");

        (uint256 px, uint256 ts, IOracleRouter.PriceSrc src) =
            IOracleRouter(orc).latestAnswer(checkBase, checkQuote);
        console2.log("Self-check: vETH/vUSDT price =", px);

        return configured;
    }

    /// @notice 计算CREATE2地址
    // ========== 工具函数 ==========

    function _defaultSymbols() internal pure returns (string[] memory arr) {
        arr = new string[](7);
        arr[0] = "vETH";
        arr[1] = "vBTC";
        arr[2] = "vLINK";
        arr[3] = "vUSDT";
        arr[4] = "vUSDC";
        arr[5] = "vDAI";
        arr[6] = "vSCR";
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _feedsPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "configs/local/feeds.json";
        if (block.chainid == 11155111) return "configs/sepolia/feeds.json";
        if (block.chainid == 534351) return "configs/scroll/feeds.json"; 
        revert("DeployOracleRouter: missing feeds config");
    }
}
