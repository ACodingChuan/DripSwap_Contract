// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";

// ============ Interfaces ============

interface IVToken {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function owner() external view returns (address);
    function BRIDGE_ROLE() external view returns (bytes32);
}

interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(address token) external;
}

interface ITokenAdminRegistry {
    function acceptAdminRole(address token) external;
    function setPool(address token, address pool) external;
    function getPool(address token) external view returns (address);
}

interface IBurnMintTokenPool {
    struct ChainUpdate {
        uint64 remoteChainSelector;
        bytes[] remotePoolAddresses;
        bytes remoteTokenAddress;
        RateLimiterConfig outboundRateLimiterConfig;
        RateLimiterConfig inboundRateLimiterConfig;
    }
    
    struct RateLimiterConfig {
        bool isEnabled;
        uint128 capacity;
        uint128 rate;
    }
    
    function applyChainUpdates(uint64[] calldata remoteChainSelectorsToRemove, ChainUpdate[] calldata chainsToAdd) external;
    function getRemotePools(uint64 remoteChainSelector) external view returns (bytes[] memory);
    function getAllowList() external view returns (address[] memory);
    function applyAllowListUpdates(address[] calldata removes, address[] calldata adds) external;
    function owner() external view returns (address);
}

/// @title FixCCIP_vUSDT
/// @notice 修复 vUSDT 的 CCIP 配置问题：
///         1. 修正 remoteTokenAddress 编码（使用 abi.encode 而非 abi.encodePacked）
///         2. 授予 VToken BRIDGE_ROLE 给 Pool
///         3. 将 Bridge 加入 Pool 的 allowlist
contract FixCCIP_vUSDT is DeployBase {
    
    // ============ Configuration ============
    
    struct CCIPConfig {
        address tokenAdminRegistry;
        address registryModuleOwner;
        uint64 chainSelector;
        uint64 remoteChainSelector;
    }
    
    struct VUSDTConfig {
        address localToken;
        address localPool;
        address remoteToken;
        address remotePool;
        address bridge;
    }
    
    function run() external {
        console2.log("=== Fix CCIP Configuration for vUSDT ===");
        console2.log("Chain ID:", block.chainid);
        
        // 1. 加载配置
        CCIPConfig memory ccipCfg = _loadCCIPConfig();
        VUSDTConfig memory vusdt = _loadVUSDTConfig();
        
        console2.log("\n--- Configuration ---");
        console2.log("Local Token (vUSDT):", vusdt.localToken);
        console2.log("Local Pool:", vusdt.localPool);
        console2.log("Remote Token:", vusdt.remoteToken);
        console2.log("Remote Pool:", vusdt.remotePool);
        console2.log("Bridge:", vusdt.bridge);
        console2.log("Remote Chain Selector:", ccipCfg.remoteChainSelector);
        
        // 使用 DEPLOYER_PK 进行 broadcast
        uint256 deployerPK = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(deployerPK);
        console2.log("\nDeployer address:", deployer);
        
        vm.startBroadcast(deployerPK);
        
        // 2. 步骤 A: 授予 VToken BRIDGE_ROLE 给 Pool
        _stepA_GrantBridgeRole(vusdt.localToken, vusdt.localPool);
        
        // 跳过已经配置好的步骤 B 和 C
        // _stepB_RegisterAdmin(ccipCfg.registryModuleOwner, ccipCfg.tokenAdminRegistry, vusdt.localToken);
        // _stepC_SetPool(ccipCfg.tokenAdminRegistry, vusdt.localToken, vusdt.localPool);
        
        // 4. 步骤 D: 配置远程链（修正编码问题）
        _stepD_ConfigureRemote(vusdt.localPool, ccipCfg.remoteChainSelector, vusdt.remoteToken, vusdt.remotePool);
        
        // 6. 步骤 E: 将 Bridge 加入 Pool allowlist
        _stepE_UpdateAllowlist(vusdt.localPool, vusdt.bridge);
        
        vm.stopBroadcast();
        
        console2.log("\n=== Configuration Completed ===");
    }
    
    // ============ Implementation ============
    
    function _stepA_GrantBridgeRole(address token, address pool) internal {
        console2.log("\n[Step A] Grant BRIDGE_ROLE to Pool");
        
        IVToken vtoken = IVToken(token);
        bytes32 BRIDGE_ROLE = vtoken.BRIDGE_ROLE();
        
        // 检查是否已授权
        if (vtoken.hasRole(BRIDGE_ROLE, pool)) {
            console2.log("[SKIP] Pool already has BRIDGE_ROLE");
            return;
        }
        
        try vtoken.grantRole(BRIDGE_ROLE, pool) {
            console2.log("[OK] Granted BRIDGE_ROLE to Pool:", pool);
        } catch Error(string memory reason) {
            console2.log("[ERROR] Failed to grant BRIDGE_ROLE:", reason);
        } catch {
            console2.log("[ERROR] Failed to grant BRIDGE_ROLE (unknown error)");
        }
    }
    
    function _stepB_RegisterAdmin(address ownerContract, address registry, address token) internal {
        console2.log("\n[Step B] Register Admin (TokenAdminRegistry)");
        
        try IRegistryModuleOwnerCustom(ownerContract).registerAdminViaGetCCIPAdmin(token) {
            console2.log("[OK] registerAdminViaGetCCIPAdmin success");
        } catch {
            console2.log("[INFO] registerAdminViaGetCCIPAdmin failed (maybe already registered)");
        }
        
        try ITokenAdminRegistry(registry).acceptAdminRole(token) {
            console2.log("[OK] acceptAdminRole success");
        } catch {
            console2.log("[INFO] acceptAdminRole failed (maybe already accepted)");
        }
    }
    
    function _stepC_SetPool(address registry, address token, address pool) internal {
        console2.log("\n[Step C] Set Pool (TokenAdminRegistry)");
        
        try ITokenAdminRegistry(registry).getPool(token) returns (address currentPool) {
            if (currentPool == pool) {
                console2.log("[SKIP] Pool already set correctly");
                return;
            }
            console2.log("[INFO] Current pool:", currentPool, "-> New pool:", pool);
        } catch {
            console2.log("[INFO] No pool set yet");
        }
        
        try ITokenAdminRegistry(registry).setPool(token, pool) {
            console2.log("[OK] Pool set:", pool);
        } catch Error(string memory reason) {
            console2.log("[ERROR] Failed to set pool:", reason);
        } catch {
            console2.log("[ERROR] Failed to set pool (unknown error)");
        }
    }
    
    function _stepD_ConfigureRemote(
        address poolAddress,
        uint64 remoteChainSelector,
        address remoteToken,
        address remotePool
    ) internal {
        console2.log("\n[Step D] Configure Remote Chain (Fix Encoding)");
        
        IBurnMintTokenPool pool = IBurnMintTokenPool(poolAddress);
        
        // 检查当前配置（如果是 20 字节说明是错误配置，需要删除）
        bool needsRemoval = false;
        try pool.getRemotePools(remoteChainSelector) returns (bytes[] memory existingPools) {
            if (existingPools.length > 0) {
                console2.log("[INFO] Existing remote pools found:", existingPools.length);
                console2.log("[INFO] First pool bytes length:", existingPools[0].length);
                if (existingPools[0].length == 20) {
                    console2.log("[WARN] Pool address is 20 bytes (abi.encodePacked), need to remove and re-add");
                    needsRemoval = true;
                } else if (existingPools[0].length == 32) {
                    console2.log("[INFO] Pool address is 32 bytes (correct encoding)");
                    console2.log("[SKIP] Remote chain already configured correctly");
                    return;
                }
            }
        } catch {
            console2.log("[INFO] Remote chain not configured yet");
        }
        
        // 步骤 1: 如果需要，先删除旧配置
        if (needsRemoval) {
            console2.log("[ACTION] Removing old configuration...");
            uint64[] memory toRemove = new uint64[](1);
            toRemove[0] = remoteChainSelector;
            IBurnMintTokenPool.ChainUpdate[] memory emptyAdds = new IBurnMintTokenPool.ChainUpdate[](0);
            
            try pool.applyChainUpdates(toRemove, emptyAdds) {
                console2.log("[OK] Old configuration removed");
            } catch Error(string memory reason) {
                console2.log("[ERROR] Failed to remove old config:", reason);
                return;
            } catch {
                console2.log("[ERROR] Failed to remove old config (unknown error)");
                return;
            }
        }
        
        // 步骤 2: 添加新的正确配置（32 字节编码）
        console2.log("[ACTION] Adding new configuration with 32-byte encoding...");
        
        IBurnMintTokenPool.ChainUpdate[] memory chainsToAdd = new IBurnMintTokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        
        // ✅ 修复：使用 abi.encode(address) 生成 32 字节编码
        remotePools[0] = abi.encode(remotePool);
        
        chainsToAdd[0] = IBurnMintTokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteToken), // ✅ 修复：32 字节编码
            outboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });
        
        console2.log("[INFO] Remote Token (32 bytes):", remoteToken);
        console2.log("[INFO] Remote Pool (32 bytes):", remotePool);
        
        try pool.applyChainUpdates(new uint64[](0), chainsToAdd) {
            console2.log("[OK] Remote chain configured successfully with 32-byte encoding");
        } catch Error(string memory reason) {
            console2.log("[ERROR] applyChainUpdates failed:", reason);
        } catch {
            console2.log("[ERROR] applyChainUpdates failed (unknown error)");
        }
    }
    
    function _stepE_UpdateAllowlist(address poolAddress, address bridge) internal {
        console2.log("\n[Step E] Update Pool Allowlist");
        
        IBurnMintTokenPool pool = IBurnMintTokenPool(poolAddress);
        
        // 检查当前 allowlist
        try pool.getAllowList() returns (address[] memory currentList) {
            console2.log("[INFO] Current allowlist length:", currentList.length);
            for (uint256 i = 0; i < currentList.length; i++) {
                if (currentList[i] == bridge) {
                    console2.log("[SKIP] Bridge already in allowlist");
                    return;
                }
            }
        } catch {
            console2.log("[INFO] Cannot read allowlist");
        }
        
        // 添加 Bridge 到 allowlist
        address[] memory adds = new address[](1);
        adds[0] = bridge;
        address[] memory removes = new address[](0);
        
        try pool.applyAllowListUpdates(removes, adds) {
            console2.log("[OK] Added Bridge to allowlist:", bridge);
        } catch Error(string memory reason) {
            console2.log("[ERROR] Failed to update allowlist:", reason);
        } catch {
            console2.log("[ERROR] Failed to update allowlist (unknown error)");
        }
    }
    
    // ============ Config Loaders ============
    
    function _loadCCIPConfig() internal view returns (CCIPConfig memory cfg) {
        if (block.chainid == 534351) { // Scroll Sepolia
            cfg.tokenAdminRegistry = 0xf49C561cf56149517c67793a3035D1877ffE2f04;
            cfg.registryModuleOwner = 0x3325786a3eE3Aa488403A136CF9Ad3E764656C75;
            cfg.chainSelector = 2279865765895943307;
            cfg.remoteChainSelector = 16015286601757825753; // Sepolia
        } else if (block.chainid == 11155111) { // Sepolia
            cfg.tokenAdminRegistry = 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82;
            cfg.registryModuleOwner = 0x62e731218d0D47305aba2BE3751E7EE9E5520790;
            cfg.chainSelector = 16015286601757825753;
            cfg.remoteChainSelector = 2279865765895943307; // Scroll
        } else {
            revert("Unsupported chain");
        }
    }
    
    function _loadVUSDTConfig() internal view returns (VUSDTConfig memory cfg) {
        if (block.chainid == 534351) { // Scroll Sepolia
            cfg.localToken = 0xBAcDBe38Df8421d0AA90262BEB1C20d32a634fe7;
            cfg.localPool = 0xb9046B13780bEcB64A4c0D0263Aa51A8dA34437b;
            cfg.remoteToken = 0xBAcDBe38Df8421d0AA90262BEB1C20d32a634fe7;
            cfg.remotePool = 0x7E4E689a73e6ffAE9B761148926d3fAD3664f116;
            cfg.bridge = 0xBE2CcDA786BF69B0AE4251E6b34dF212CEF4F645;
        } else if (block.chainid == 11155111) { // Sepolia
            cfg.localToken = 0xBAcDBe38Df8421d0AA90262BEB1C20d32a634fe7;
            cfg.localPool = 0x7E4E689a73e6ffAE9B761148926d3fAD3664f116;
            cfg.remoteToken = 0xBAcDBe38Df8421d0AA90262BEB1C20d32a634fe7;
            cfg.remotePool = 0xb9046B13780bEcB64A4c0D0263Aa51A8dA34437b;
            cfg.bridge = 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7;
        } else {
            revert("Unsupported chain");
        }
    }
}
