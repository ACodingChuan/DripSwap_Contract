// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title DeployV2Deterministic
/// @notice 使用ERC-2470确定性部署UniswapV2 Factory和Router
/// @dev 所有网络统一使用ERC-2470，确保跨链地址一致
contract DeployV2Deterministic is DeployBase {
    using stdJson for string;

    /// @notice 通过ERC-2470部署合约（带幂等性检查）
    /// @param name 合约名称（用于日志）
    /// @param salt 盐值
    /// @param initCode 初始化代码（包含构造参数）
    /// @return deployed 部署的合约地址
    function _deployViaERC2470(string memory name, bytes32 salt, bytes memory initCode)
        internal
        returns (address deployed, bool freshly)
    {
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ERC2470, salt, keccak256(initCode))))));

        if (predicted.code.length > 0) {
            console2.log(string.concat("[SKIP] ", name, " already deployed"));
            console2.log("  Address:", predicted);
            return (predicted, false);
        }

        // 1. 先尝试部署，ERC-2470会返回已存在的地址或新部署的地址
        console2.log(string.concat("Deploying ", name, "..."));
        console2.log("  Predicted address:", predicted);
        console2.logBytes32(salt);
        console2.log("  init code length:", initCode.length);
        console2.logBytes32(keccak256(initCode));

        // 调用 Singleton Factory 的 deploy(bytes initCode, bytes32 salt) 函数
        bytes memory payload = abi.encodeWithSelector(bytes4(0x4af63f02), initCode, salt);
        console2.log("  payload length:", payload.length);
        console2.logBytes32(keccak256(payload));
        (bool success, bytes memory result) = ERC2470.call(payload);
        if (!success) {
            console2.log("  deployment call reverted");
            if (result.length > 0) {
                // Bubble up revert reason
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            } else {
                revert(string.concat(name, ": deployment failed"));
            }
        }

        console2.log("  raw result length:", result.length);
        console2.logBytes(result);
        if (result.length == 20) {
            uint256 word;
            assembly {
                word := mload(add(result, 0x20))
            }
            deployed = address(uint160(word >> 96));
        } else if (result.length == 32) {
            deployed = abi.decode(result, (address));
        } else {
            revert(string.concat(name, ": invalid factory response"));
        }
        console2.log("  deployed address:", deployed);
        require(deployed == predicted, string.concat(name, ": unexpected address"));

        // 2. 验证合约已部署
        require(deployed.code.length > 0, string.concat(name, ": no code at address"));

        console2.log(string.concat("[OK] ", name, " deployed"));
        console2.log("  Address:", deployed);

        return (deployed, true);
    }

    /// @notice 生成盐值
    /// @param contractName 合约名称
    /// @return salt 生成的盐值
    function _generateSalt(string memory contractName) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "DripSwap", // 项目名
                "V2", // 版本
                contractName // 合约名
            )
        );
    }

    function run() external {
        console2.log("=== DripSwap V2 Deterministic Deployment ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Factory (ERC-2470):", ERC2470);
        console2.log("");

        // 在broadcast之前确保ERC-2470存在
        _ensureERC2470();

        vm.startBroadcast();

        address deployer = msg.sender;
        console2.log("Deployer:", deployer);
        console2.log("");

        address weth = address(0x0000000000000000000000000000000000000001);

        // ===== 1. 部署 UniswapV2Factory =====
        console2.log("=== Deploying UniswapV2Factory ===");

        string memory factoryArtifact = vm.readFile("out-v2core/UniswapV2Factory.sol/UniswapV2Factory.json");
        bytes memory factoryCode = vm.parseJsonBytes(factoryArtifact, ".bytecode.object");
        console2.log("factory init code length:", factoryCode.length);
        console2.logBytes32(keccak256(factoryCode));
        bytes memory factoryBytecode = abi.encodePacked(factoryCode, abi.encode(deployer));

        bytes32 saltFactory = _generateSalt("Factory");
        (address factory, bool factoryFresh) = _deployViaERC2470("UniswapV2Factory", saltFactory, factoryBytecode);
        console2.log("");

        // ===== 2. 计算 INIT_CODE_PAIR_HASH =====
        console2.log("=== Computing INIT_CODE_PAIR_HASH ===");

        string memory pairArtifact = vm.readFile("out-v2core/UniswapV2Pair.sol/UniswapV2Pair.json");
        bytes memory pairCode = vm.parseJsonBytes(pairArtifact, ".bytecode.object");
        bytes32 pairHash = keccak256(pairCode);
        console2.log("INIT_CODE_PAIR_HASH:");
        console2.logBytes32(pairHash);
        console2.log("");

        // ===== 3. 部署 UniswapV2Router01 =====
        console2.log("=== Deploying UniswapV2Router01 ===");

        string memory routerArtifact = vm.readFile("out-v2router/UniswapV2Router01.sol/UniswapV2Router01.json");
        bytes memory routerCode = vm.parseJsonBytes(routerArtifact, ".bytecode.object");
        bytes memory routerBytecode = abi.encodePacked(routerCode, abi.encode(factory, weth));

        bytes32 saltRouter = _generateSalt("Router01");
        (address router, bool routerFresh) = _deployViaERC2470("UniswapV2Router01", saltRouter, routerBytecode);
        console2.log("");

        vm.stopBroadcast();

        // ===== 4. 更新配置 =====
        console2.log("=== Updating Config ===");
        _bookSetAddress("v2.factory", factory);
        _bookSetAddress("v2.router", router);
        _bookSetAddress("v2.weth", weth);
        _bookSet("v2.init_code_hash", _toHex(pairHash));

        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Factory Deployer (ERC-2470):", ERC2470);
        console2.log("UniswapV2Factory:", factory);
        console2.log("UniswapV2Router01:", router);
        console2.log("WETH (placeholder):", weth);
        console2.log("INIT_CODE_PAIR_HASH:");
        console2.logBytes32(pairHash);
        console2.log("");
        console2.log("[OK] Deployment complete with deterministic addresses");
        console2.log("   Same addresses across Anvil, Sepolia, and Scroll Sepolia");

        if (factoryFresh || routerFresh) {
            string memory mdPath = _deploymentFile("v2.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[v2]");
            vm.writeLine(mdPath, string.concat("  chain_id: ", vm.toString(block.chainid)));
            vm.writeLine(mdPath, string.concat("  factory: ", vm.toString(factory)));
            vm.writeLine(mdPath, string.concat("  router: ", vm.toString(router)));
            vm.writeLine(mdPath, string.concat("  init_code_hash: ", _toHex(pairHash)));
        }
    }

    function _toHex(bytes32 data) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; ++i) {
            uint8 b = uint8(data[i]);
            str[2 + i * 2] = hexSymbols[b >> 4];
            str[3 + i * 2] = hexSymbols[b & 0x0f];
        }
        return string(str);
    }
}
