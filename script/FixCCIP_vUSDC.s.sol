// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";

// ============ Interfaces ============

interface IVToken {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function BRIDGE_ROLE() external view returns (bytes32);
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
}

contract FixCCIP_vUSDC is DeployBase {
    
    struct CCIPConfig {
        uint64 remoteChainSelector;
    }
    
    struct TokenConfig {
        address localToken;
        address localPool;
        address remoteToken;
        address remotePool;
        address bridge;
    }
    
    function run() external {
        console2.log("=== Fix CCIP Configuration for vUSDC ===");
        
        CCIPConfig memory ccipCfg = _loadCCIPConfig();
        TokenConfig memory token = _loadTokenConfig();
        
        uint256 deployerPK = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(deployerPK);
        
        _stepA_GrantBridgeRole(token.localToken, token.localPool);
        _stepD_ConfigureRemote(token.localPool, ccipCfg.remoteChainSelector, token.remoteToken, token.remotePool);
        _stepE_UpdateAllowlist(token.localPool, token.bridge);
        
        vm.stopBroadcast();
        console2.log("\n=== vUSDC Configuration Completed ===");
    }
    
    function _stepA_GrantBridgeRole(address token, address pool) internal {
        console2.log("\n[Step A] Grant BRIDGE_ROLE to Pool");
        IVToken vtoken = IVToken(token);
        bytes32 BRIDGE_ROLE = vtoken.BRIDGE_ROLE();
        
        if (vtoken.hasRole(BRIDGE_ROLE, pool)) {
            console2.log("[SKIP] Pool already has BRIDGE_ROLE");
            return;
        }
        
        vtoken.grantRole(BRIDGE_ROLE, pool);
        console2.log("[OK] Granted BRIDGE_ROLE");
    }
    
    function _stepD_ConfigureRemote(address poolAddress, uint64 remoteChainSelector, address remoteToken, address remotePool) internal {
        console2.log("\n[Step D] Configure Remote Chain");
        IBurnMintTokenPool pool = IBurnMintTokenPool(poolAddress);
        
        bool needsRemoval = false;
        bytes[] memory existingPools = pool.getRemotePools(remoteChainSelector);
        if (existingPools.length > 0 && existingPools[0].length == 20) {
            console2.log("[WARN] Found 20-byte encoding, will fix");
            needsRemoval = true;
        } else if (existingPools.length > 0 && existingPools[0].length == 32) {
            console2.log("[SKIP] Already configured correctly");
            return;
        }
        
        if (needsRemoval) {
            uint64[] memory toRemove = new uint64[](1);
            toRemove[0] = remoteChainSelector;
            pool.applyChainUpdates(toRemove, new IBurnMintTokenPool.ChainUpdate[](0));
            console2.log("[OK] Removed old config");
        }
        
        IBurnMintTokenPool.ChainUpdate[] memory chainsToAdd = new IBurnMintTokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(remotePool);
        
        chainsToAdd[0] = IBurnMintTokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encode(remoteToken),
            outboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0})
        });
        
        pool.applyChainUpdates(new uint64[](0), chainsToAdd);
        console2.log("[OK] Added 32-byte config");
    }
    
    function _stepE_UpdateAllowlist(address poolAddress, address bridge) internal {
        console2.log("\n[Step E] Update Allowlist");
        IBurnMintTokenPool pool = IBurnMintTokenPool(poolAddress);
        
        address[] memory currentList = pool.getAllowList();
        for (uint256 i = 0; i < currentList.length; i++) {
            if (currentList[i] == bridge) {
                console2.log("[SKIP] Bridge already in allowlist");
                return;
            }
        }
        
        address[] memory adds = new address[](1);
        adds[0] = bridge;
        pool.applyAllowListUpdates(new address[](0), adds);
        console2.log("[OK] Added Bridge to allowlist");
    }
    
    function _loadCCIPConfig() internal view returns (CCIPConfig memory cfg) {
        if (block.chainid == 534351) {
            cfg.remoteChainSelector = 16015286601757825753;
        } else {
            cfg.remoteChainSelector = 2279865765895943307;
        }
    }
    
    function _loadTokenConfig() internal view returns (TokenConfig memory cfg) {
        if (block.chainid == 534351) {
            cfg.localToken = 0x46A906fcA4487C87f0d89D2d0824EC57bdAa947D;
            cfg.localPool = 0xAdE641AB716A4c74F69FAB530CAA5848e9B172A9;
            cfg.remoteToken = 0x46A906fcA4487C87f0d89D2d0824EC57bdAa947D;
            cfg.remotePool = 0xA9CceE83eA56AEB484Cf72b90FA81392719cEcab;
            cfg.bridge = 0xBE2CcDA786BF69B0AE4251E6b34dF212CEF4F645;
        } else {
            cfg.localToken = 0x46A906fcA4487C87f0d89D2d0824EC57bdAa947D;
            cfg.localPool = 0xA9CceE83eA56AEB484Cf72b90FA81392719cEcab;
            cfg.remoteToken = 0x46A906fcA4487C87f0d89D2d0824EC57bdAa947D;
            cfg.remotePool = 0xAdE641AB716A4c74F69FAB530CAA5848e9B172A9;
            cfg.bridge = 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7;
        }
    }
}
