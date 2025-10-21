// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ChainlinkOracle} from "src/oracle/ChainlinkOracle.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";

contract DeployOracleRouter is Script {
    using stdJson for string;

    address constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        
        console2.log("=== Deploying Oracle Router ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");
        
        // 验证ERC-2470存在
        require(ERC2470.code.length > 0, "ERC-2470 not found");

        string memory bookPath  = _bookPath();
        string memory feedsPath = _feedsPath();
        
        vm.startBroadcast(pk);

        // 1) 部署 Oracle（带幂等性检查）
        address orc = _deployOracle(owner);
        console2.log("OracleRouter:", orc);

        // 2) 配置 feeds
        _configureFeeds(orc, bookPath, feedsPath);
        
        // 3) 写地址簿
        vm.writeJson(vm.toString(orc), bookPath, ".oracle.router");
        console2.log("AddressBook updated:", bookPath);

        vm.stopBroadcast();
        
        console2.log("");
        console2.log("[OK] Oracle Router deployed/configured");
    }

    /// @notice 部署Oracle（带幂等性检查）
    function _deployOracle(address owner) internal returns (address) {
        // 生成盐值
        bytes32 salt = keccak256(
            abi.encodePacked(
                "DripSwap",
                "Oracle",
                "ChainlinkOracle",
                block.chainid
            )
        );
        
        // 准备字节码
        bytes memory creationCode = type(ChainlinkOracle).creationCode;
        bytes memory bytecode = abi.encodePacked(
            creationCode,
            abi.encode(owner)
        );
        
        // 计算预期地址
        address predicted = _computeCreate2Address(salt, bytecode);
        
        // 检查是否已部署
        if (predicted.code.length > 0) {
            console2.log("[OK] Oracle already deployed");
            console2.log("  Address:", predicted);
            return predicted;
        }
        
        // 部署
        console2.log("Deploying Oracle...");
        
        bytes memory payload = abi.encodePacked(salt, bytecode);
        console2.log("  init code length:", bytecode.length);
        console2.logBytes32(keccak256(bytecode));
        console2.log("  payload length:", payload.length);
        console2.logBytes32(keccak256(payload));

        (bool success, bytes memory result) = ERC2470.call(payload);
        if (!success) {
            console2.log("Oracle deployment reverted");
            if (result.length > 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            revert("Oracle deployment failed");
        }

        console2.log("  raw result length:", result.length);
        console2.logBytes(result);

        address deployed;
        if (result.length == 20) {
            uint256 word;
            assembly {
                word := mload(add(result, 0x20))
            }
            deployed = address(uint160(word >> 96));
        } else if (result.length == 32) {
            deployed = abi.decode(result, (address));
        } else {
            revert("Oracle factory response invalid");
        }

        require(deployed == predicted, "Oracle address mismatch");
        
        console2.log("[OK] Oracle deployed");
        console2.log("  Address:", deployed);
        
        return deployed;
    }

    /// @notice 配置价格源
    function _configureFeeds(
        address orc,
        string memory bookPath,
        string memory feedsPath
    ) internal {
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
            address token = _symToAddr(bookPath, sym);

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
                _updateFeedConfig(bookPath, sym, cfg);
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
                    _updateFeedConfig(bookPath, sym, cfg);
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
                    _updateFeedConfig(bookPath, sym, cfg);
                    console2.log("[feed] chainlink (no agg) ", sym, pxE18);
                }
            } else {
                revert("Unknown feed type");
            }
        }

        // 简单自检
        (uint256 px, uint256 ts, IOracleRouter.PriceSrc src) =
            IOracleRouter(orc).latestAnswer(
                _symToAddr(bookPath, "vETH"),
                _symToAddr(bookPath, "vUSDT")
            );
        console2.log("Self-check: vETH/vUSDT price =", px);
    }

    /// @notice 计算CREATE2地址
    function _computeCreate2Address(
        bytes32 salt,
        bytes memory bytecode
    ) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                ERC2470,
                salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    // ========== 工具函数 ==========

    // 从地址簿 tokens 节点把符号映射到地址
    function _symToAddr(string memory bookPath, string memory sym) internal view returns (address) {
        string memory book = vm.readFile(bookPath);
        string memory path = string.concat(".tokens.", sym, ".address");
        if (!book.keyExists(path)) {
            revert(string.concat("Token address missing: ", sym));
        }
        return book.readAddress(path);
    }

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

    function _updateFeedConfig(
        string memory bookPath,
        string memory sym,
        ChainlinkOracle.FeedUSD memory cfg
    ) internal {
        string memory objKey = string.concat("feed_", sym);
        string memory feedJson = vm.serializeAddress(objKey, "aggregator", cfg.aggregator);
        feedJson = vm.serializeUint(objKey, "aggDecimals", cfg.aggDecimals);
        feedJson = vm.serializeUint(objKey, "fixedUsdE18", cfg.fixedUsdE18);
        vm.writeJson(feedJson, bookPath, string.concat(".oracle.feeds.", sym));
    }

    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "deployments/local.m1.json";
        if (block.chainid == 11155111) return "deployments/sepolia.m1.json";
        if (block.chainid == 534351) return "deployments/scroll-sepolia.m1.json";
        revert("DeployOracleRouter: unsupported chain");
    }

    function _feedsPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "configs/local/feeds.json";
        if (block.chainid == 11155111) return "configs/sepolia/feeds.json";
        if (block.chainid == 534351) return "configs/scroll/feeds.json";
        revert("DeployOracleRouter: missing feeds config");
    }
}
