// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title DeployV2Deterministic
/// @notice 使用ERC-2470确定性部署UniswapV2 Factory和Router
/// @dev 所有网络统一使用ERC-2470，确保跨链地址一致
contract DeployV2Deterministic is Script {
    using stdJson for string;

    // ERC-2470标准地址（所有链统一）
    address constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    
    /// @notice 通过ERC-2470部署合约（带幂等性检查）
    /// @param name 合约名称（用于日志）
    /// @param salt 盐值
    /// @param initCode 初始化代码（包含构造参数）
    /// @return deployed 部署的合约地址
    function _deployViaERC2470(
        string memory name,
        bytes32 salt,
        bytes memory initCode
    ) internal returns (address deployed) {
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            ERC2470,
                            salt,
                            keccak256(initCode)
                        )
                    )
                )
            )
        );

        if (predicted.code.length > 0) {
            console2.log(string.concat("[SKIP] ", name, " already deployed"));
            console2.log("  Address:", predicted);
            return predicted;
        }

        // 1. 先尝试部署，ERC-2470会返回已存在的地址或新部署的地址
        console2.log(string.concat("Deploying ", name, "..."));
        console2.log("  Predicted address:", predicted);
        console2.logBytes32(salt);
        console2.log("  init code length:", initCode.length);
        console2.logBytes32(keccak256(initCode));

        bytes memory payload = abi.encodePacked(salt, initCode);
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
        
        return deployed;
    }
    
    /// @notice 生成盐值
    /// @param contractName 合约名称
    /// @return salt 生成的盐值
    function _generateSalt(string memory contractName) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "DripSwap",      // 项目名
                "V2",            // 版本
                contractName,    // 合约名
                block.chainid    // 链ID
            )
        );
    }

    // ERC-2470运行时字节码
    bytes constant ERC2470_RUNTIME = hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function run() external {
        console2.log("=== DripSwap V2 Deterministic Deployment ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Factory (ERC-2470):", ERC2470);
        console2.log("");

        // 在broadcast之前确保ERC-2470存在
        _ensureERC2470();

        string memory bookPath = _bookPath();

        vm.startBroadcast();
        
        address deployer = msg.sender;
        console2.log("Deployer:", deployer);
        console2.log("");

        address weth = address(0x0000000000000000000000000000000000000001);

        // ===== 1. 部署 UniswapV2Factory =====
        console2.log("=== Deploying UniswapV2Factory ===");
        
        string memory factoryArtifact = vm.readFile(
            "out-v2core/UniswapV2Factory.sol/UniswapV2Factory.json"
        );
        bytes memory factoryCode = vm.parseJsonBytes(factoryArtifact, ".bytecode.object");
        console2.log("factory init code length:", factoryCode.length);
        console2.logBytes32(keccak256(factoryCode));
        bytes memory factoryBytecode = abi.encodePacked(
            factoryCode,
            abi.encode(deployer)
        );
        
        bytes32 saltFactory = _generateSalt("Factory");
        address factory = _deployViaERC2470("UniswapV2Factory", saltFactory, factoryBytecode);
        console2.log("");

        // ===== 2. 计算 INIT_CODE_PAIR_HASH =====
        console2.log("=== Computing INIT_CODE_PAIR_HASH ===");
        
        string memory pairArtifact = vm.readFile(
            "out-v2core/UniswapV2Pair.sol/UniswapV2Pair.json"
        );
        bytes memory pairCode = vm.parseJsonBytes(pairArtifact, ".bytecode.object");
        bytes32 pairHash = keccak256(pairCode);
        console2.log("INIT_CODE_PAIR_HASH:");
        console2.logBytes32(pairHash);
        console2.log("");

        // ===== 3. 部署 UniswapV2Router01 =====
        console2.log("=== Deploying UniswapV2Router01 ===");
        
        string memory routerArtifact = vm.readFile(
            "out-v2router/UniswapV2Router01.sol/UniswapV2Router01.json"
        );
        bytes memory routerCode = vm.parseJsonBytes(routerArtifact, ".bytecode.object");
        bytes memory routerBytecode = abi.encodePacked(
            routerCode,
            abi.encode(factory, weth)
        );
        
        bytes32 saltRouter = _generateSalt("Router01");
        address router = _deployViaERC2470("UniswapV2Router01", saltRouter, routerBytecode);
        console2.log("");

        vm.stopBroadcast();

        // ===== 4. 更新配置 =====
        console2.log("=== Updating Config ===");
        _updateConfig(bookPath, factory, router, weth, pairHash);
        
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
    }

    /// @notice 确保ERC-2470存在
    function _ensureERC2470() internal {
        if (ERC2470.code.length > 0) {
            console2.log("[OK] ERC-2470 found");
            console2.log("");
            return;
        }

        if (block.chainid != 31337) {
            revert("ERC-2470 not found on this network");
        }

        console2.log("Deploying ERC-2470 to Anvil via vm.etch...");
        vm.etch(ERC2470, ERC2470_RUNTIME);
        // 同步更新实际Anvil状态，确保后续广播可以调用
        string memory addr = vm.toString(ERC2470);
        string memory code = vm.toString(ERC2470_RUNTIME);
        string memory params = string.concat("[\"", addr, "\",\"", code, "\"]");
        vm.rpc("anvil_setCode", params);
        require(ERC2470.code.length > 0, "ERC-2470 injection failed");
        console2.log("[OK] ERC-2470 injected for local chain");
        console2.log("");
    }

    /// @notice 更新部署配置文件（使用路径方式避免覆盖）
    function _updateConfig(
        string memory bookPath,
        address factory,
        address router,
        address weth,
        bytes32 pairHash
    ) internal {
        // 写入chainId和factoryDeployer
        vm.writeJson(vm.toString(block.chainid), bookPath, ".chainId");
        vm.writeJson(vm.toString(ERC2470), bookPath, ".factoryDeployer");
        
        // 写入v2配置
        vm.writeJson(vm.toString(factory), bookPath, ".v2.factory");
        vm.writeJson(vm.toString(router), bookPath, ".v2.router");
        vm.writeJson(vm.toString(weth), bookPath, ".v2.weth");
        vm.writeJson(vm.toString(pairHash), bookPath, ".v2.initCodeHash");
        
        console2.log("[OK] Config updated:", bookPath);
    }

    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "deployments/local.m1.json";
        if (block.chainid == 11155111) return "deployments/sepolia.m1.json";
        if (block.chainid == 534351) return "deployments/scroll-sepolia.m1.json";
        revert("DeployV2Deterministic: unsupported chain");
    }
}
