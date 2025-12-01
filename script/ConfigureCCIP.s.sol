// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Bridge} from "src/bridge/Bridge.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// --- 最小化接口定义 (Reference from DEBUG_SUMMARY.md) ---

interface IBurnMintERC20 is IERC20 {
    function getCCIPAdmin() external view returns (address);
    function burn(uint256 amount) external;
    function mint(address account, uint256 amount) external;
    function grantMintAndBurnRoles(address burnAndMinter) external;
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
    function getToken() external view returns (address);
}

/// @title ConfigureCCIP
/// @notice 自动化配置 CCIP 跨链参数 (注册 Admin, 绑定 Pool, 配置 Remote Chain)
contract ConfigureCCIP is DeployBase {
    using stdJson for string;

    struct CCIPConfig {
        address router;
        address tokenAdminRegistry;
        address registryModuleOwner;
        uint64 chainSelector;
    }

    struct RemoteChainConfig {
        uint64 chainSelector;
    }

    struct TokenConfig {
        address localPool;
        address localToken;
        address remotePool;
        address remoteToken;
        string symbol;
    }

    // 定义需要跳过的 Token (例如 vETH 已经手动配置过)
    mapping(address => bool) public skipTokens;

    function run() external {
        console2.log("=== ConfigureCCIP Automation ===");
        console2.log("Chain ID:", block.chainid);

        // 1. 加载配置
        CCIPConfig memory cfg = _loadCCIPConfig();
        RemoteChainConfig memory remoteCfg = _loadRemoteConfig();
        
        console2.log("TokenAdminRegistry:", cfg.tokenAdminRegistry);
        console2.log("Remote Chain Selector:", remoteCfg.chainSelector);

        // 2. 加载需要配置的 Token 列表 (从 JSON 读取)
        TokenConfig[] memory tokensToConfig = _loadTokenConfigs();

        // 3. 手动标记需要跳过的 Token (vETH 已经手动配置过)
        // 明确跳过 vETH，避免因重复配置导致 Revert，从而使脚本模拟失败
        skipTokens[0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D] = true; // vETH

        vm.startBroadcast();

        for (uint256 i = 0; i < tokensToConfig.length; i++) {
            TokenConfig memory t = tokensToConfig[i];
            console2.log("--- Processing Token:", t.symbol, "---");

            // 检查是否需要跳过
            if (skipTokens[t.localToken]) {
                console2.log("[SKIP] Token marked as skipped");
                continue;
            }

            // 3. 步骤 0: 授予 Burn/Mint 权限 (Token -> EOA & Pool)
            _step_GrantRoles(t.localToken, t.localPool);

            // 4. 步骤 A: 权限注册 (TokenAdminRegistry)
            _stepA_RegisterAdmin(cfg.registryModuleOwner, cfg.tokenAdminRegistry, t.localToken);

            // 5. 步骤 B: 绑定 Pool (TokenAdminRegistry)
            _stepB_SetPool(cfg.tokenAdminRegistry, t.localToken, t.localPool);

            // 6. 步骤 C: 配置远程链 (BurnMintTokenPool)
            if (t.remoteToken != address(0) && t.remotePool != address(0)) {
                _stepC_ConfigureRemote(t.localPool, remoteCfg.chainSelector, t.remoteToken, t.remotePool);
            } else {
                console2.log("[WARN] Missing remote addresses for token");
            }
            
            // 7. 步骤 D: Bridge 注册 (本地 Bridge)
            _stepD_RegisterBridge(t.localToken, t.localPool);
        }

        vm.stopBroadcast();
        console2.log("=== Configuration Completed ===");
    }

    // --- 核心步骤实现 ---

    function _step_GrantRoles(address token, address pool) internal {
        // 1. 授予 EOA (Deployer) 权限
        // 注意: 这通常需要 Deployer 是 Token 的 Owner
        try IBurnMintERC20(token).grantMintAndBurnRoles(msg.sender) {
            console2.log("[OK] Granted roles to Deployer");
        } catch {
            console2.log("[INFO] Grant roles to Deployer failed (maybe already granted or not owner)");
        }

        // 2. 授予 Pool 权限
        try IBurnMintERC20(token).grantMintAndBurnRoles(pool) {
            console2.log("[OK] Granted roles to Pool:", pool);
        } catch {
            console2.log("[INFO] Grant roles to Pool failed (maybe already granted or not owner)");
        }
    }

    function _stepA_RegisterAdmin(address ownerContract, address registry, address token) internal {
        // 尝试注册 Admin
        // 注意：这里假设调用者 deployer 已经是 Token 的 CCIP Admin 候选人 (getCCIPAdmin 指向 deployer)
        // 或者 deployer 是 Owner，可以调用 registerAdminViaGetCCIPAdmin
        
        try IRegistryModuleOwnerCustom(ownerContract).registerAdminViaGetCCIPAdmin(token) {
            console2.log("[OK] registerAdminViaGetCCIPAdmin success");
        } catch {
             console2.log("[INFO] registerAdminViaGetCCIPAdmin failed (maybe already registered or not owner)");
        }

        try ITokenAdminRegistry(registry).acceptAdminRole(token) {
            console2.log("[OK] acceptAdminRole success");
        } catch {
            console2.log("[INFO] acceptAdminRole failed (maybe already accepted)");
        }
    }

    function _stepB_SetPool(address registry, address token, address pool) internal {
        // 检查当前 Pool 设置
        try ITokenAdminRegistry(registry).getPool(token) returns (address currentPool) {
            if (currentPool == pool) {
                console2.log("[SKIP] Pool already set correctly");
                return;
            }
        } catch {}

        console2.log("Setting pool for token...");
        ITokenAdminRegistry(registry).setPool(token, pool);
        console2.log("[OK] Pool set:", pool);
    }

    function _stepC_ConfigureRemote(address poolAddress, uint64 remoteChainSelector, address remoteToken, address remotePool) internal {
        IBurnMintTokenPool pool = IBurnMintTokenPool(poolAddress);

        // 构造 ChainUpdate 结构体
        // 为了解决 Stack Too Deep，此处不打印日志，尽量内联
        IBurnMintTokenPool.ChainUpdate[] memory chainsToAdd = new IBurnMintTokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encodePacked(remotePool);

        chainsToAdd[0] = IBurnMintTokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            remotePoolAddresses: remotePools,
            remoteTokenAddress: abi.encodePacked(remoteToken),
            outboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: IBurnMintTokenPool.RateLimiterConfig({isEnabled: false, capacity: 0, rate: 0})
        });

        try pool.applyChainUpdates(new uint64[](0), chainsToAdd) {
            // Success
        } catch {
            // Fail (likely exists)
        }
    }

    function _stepD_RegisterBridge(address token, address pool) internal {
        address bridgeAddr;
        if (block.chainid == 11155111) {
            bridgeAddr = 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7;
        } else if (block.chainid == 534351) {
            bridgeAddr = 0xBE2CcDA786BF69B0AE4251E6b34dF212CEF4F645;
        } else {
            revert("Unsupported chain for bridge");
        }
        
        Bridge bridge = Bridge(bridgeAddr);

        // 检查是否已经注册
        // Bridge 合约中可能有 view 函数查询 pool，如果没有，直接 set
        // 假设 Bridge 有 registerTokenPool
        try bridge.registerTokenPool(token, pool) {
            console2.log("[OK] Bridge registerTokenPool executed");
        } catch {
            console2.log("[INFO] Bridge registerTokenPool failed (maybe already registered)");
        }
    }


    // --- 辅助函数 ---

    function _loadCCIPConfig() internal returns (CCIPConfig memory c) {
        string memory path;
        if (block.chainid == 11155111) path = "configs/sepolia/bridge.json"; 
        else if (block.chainid == 534351) path = "configs/scroll/bridge.json";
        else revert("Unsupported chain");

        if (block.chainid == 534351) { // Scroll
            c.router = 0x6aF501292f2A33C81B9156203C9A66Ba0d8E3D21;
            c.tokenAdminRegistry = 0xf49C561cf56149517c67793a3035D1877ffE2f04;
            c.registryModuleOwner = 0x3325786a3eE3Aa488403A136CF9Ad3E764656C75;
            c.chainSelector = 2279865765895943307;
        } else { // Sepolia
            c.router = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
            c.tokenAdminRegistry = 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82;
            c.registryModuleOwner = 0x62e731218d0D47305aba2BE3751E7EE9E5520790;
            c.chainSelector = 16015286601757825753;
        }
    }

    function _loadRemoteConfig() internal view returns (RemoteChainConfig memory c) {
        if (block.chainid == 534351) { // Current is Scroll, Remote is Sepolia
            c.chainSelector = 16015286601757825753;
        } else { // Current is Sepolia, Remote is Scroll
            c.chainSelector = 2279865765895943307;
        }
    }

    function _loadTokenConfigs() internal view returns (TokenConfig[] memory) {
        string memory path;
        if (block.chainid == 11155111) path = "configs/sepolia/ccip_tokens.json";
        else if (block.chainid == 534351) path = "configs/scroll/ccip_tokens.json";
        else revert("Unsupported chain for token config");

        string memory json = vm.readFile(path);
        bytes memory rawTokens = vm.parseJson(json, ".tokens");
        return abi.decode(rawTokens, (TokenConfig[]));
    }
}
