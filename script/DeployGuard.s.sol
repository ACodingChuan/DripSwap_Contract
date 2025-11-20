// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {GuardedRouter} from "src/guard/GuardedRouter.sol";

/// @notice 部署 Guard（软约束）并按可选配置写入默认值与 per-pair 覆盖
/// @dev    兼容旧版 forge-std：不使用 string.indexOf / readKeys，改为 try/catch 读取
contract DeployGuard is DeployBase {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);

        console2.log("=== Deploying Guarded Router ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        _ensureERC2470();

        string memory guardPath = _guardPath();

        vm.startBroadcast(pk);

        address factory = _bookGetAddress("v2.factory");
        address oracle = _bookGetAddress("oracle.router");

        // 2) 默认阈值（若没有 guard 配置，则使用 .env）
        uint16 hardBps = 300;
        uint16 hardBpsFixed = 500;
        uint32 staleSec = 600;

        bool hasGuardCfg = vm.exists(guardPath);
        string memory cfg;
        if (hasGuardCfg) {
            cfg = vm.readFile(guardPath);

            // defaults - 直接使用vm.parseJsonString避免this.调用
            try vm.parseJsonUint(cfg, ".defaults.hardBps") returns (uint256 v) {
                hardBps = uint16(v);
            } catch {}
            try vm.parseJsonUint(cfg, ".defaults.hardBpsFixed") returns (uint256 v) {
                hardBpsFixed = uint16(v);
            } catch {}
            try vm.parseJsonUint(cfg, ".defaults.staleSec") returns (uint256 v) {
                staleSec = uint32(v);
            } catch {}
        } else {
            console2.log("[WARN] guard config not found for network, using built-in defaults");
        }

        // 4) 部署 Guard（带幂等性检查）
        (address guard, bool freshly) = _deployGuard(factory, oracle, hardBps, hardBpsFixed, staleSec, owner);
        console2.log("GuardedRouter:", guard);

        // 5) per-pair overrides（可选）
        if (hasGuardCfg) {
            try vm.parseJsonKeys(cfg, ".overrides") returns (string[] memory keys) {
                for (uint256 i = 0; i < keys.length; i++) {
                    _applyOverride(guard, cfg, keys[i], hardBps, staleSec);
                }
            } catch {}
        }

        _bookSetAddress("guard.router", guard);
        _bookSetUint("guard.defaults.hardBps", hardBps);
        _bookSetUint("guard.defaults.hardBpsFixed", hardBpsFixed);
        _bookSetUint("guard.defaults.staleSec", staleSec);

        vm.stopBroadcast();

        console2.log("");
        console2.log("[OK] Guarded Router deployed/configured");

        if (freshly) {
            string memory mdPath = _deploymentFile("guard.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[guard]");
            vm.writeLine(mdPath, string.concat("  address: ", vm.toString(guard)));
            vm.writeLine(mdPath, string.concat("  factory: ", vm.toString(factory)));
            vm.writeLine(mdPath, string.concat("  oracle: ", vm.toString(oracle)));
            vm.writeLine(mdPath, string.concat("  hard_bps: ", vm.toString(uint256(hardBps))));
            vm.writeLine(mdPath, string.concat("  hard_bps_fixed: ", vm.toString(uint256(hardBpsFixed))));
            vm.writeLine(mdPath, string.concat("  stale_sec: ", vm.toString(uint256(staleSec))));
            vm.writeLine(mdPath, string.concat("  owner: ", vm.toString(owner)));
        }
    }

    /// @notice 部署Guard（带幂等性检查）
    function _deployGuard(
        address factory,
        address oracle,
        uint16 hardBps,
        uint16 hardBpsFixed,
        uint32 staleSec,
        address owner
    ) internal returns (address deployed, bool freshly) {
        // 生成盐值
        bytes32 salt = keccak256(abi.encodePacked("DripSwap", "Guard", "GuardedRouter"));

        // 准备字节码
        bytes memory creationCode = type(GuardedRouter).creationCode;
        bytes memory bytecode =
            abi.encodePacked(creationCode, abi.encode(factory, oracle, hardBps, hardBpsFixed, staleSec, owner));

        (deployed, freshly) = _deployDeterministic(bytecode, salt);

        if (freshly) {
            console2.log("Deploying Guard...");
            console2.log("[OK] Guard deployed");
            console2.log("  Address:", deployed);
        } else {
            console2.log("[SKIP] Guard already deployed");
            console2.log("  Address:", deployed);
        }
    }

    // ----------------- helpers -----------------

    /// @dev 读取字符串字段（字段不存在会 revert；外层 try/catch 捕获）
    /// @dev 将 "vETH_vUSDT" 拆成两个地址（从地址簿 tokens 节点读取）
    function _splitPairSymToAddrs(string memory key) internal returns (address a, address b) {
        (string memory sa, string memory sb) = _splitPairSym(key);
        a = _requireToken(sa);
        b = _requireToken(sb);
    }

    /// @dev 从 "vETH_vUSDT" 提取 ["vETH","vUSDT"]（纯 Solidity 实现，兼容性最好）
    function _splitPairSym(string memory key) internal pure returns (string memory sa, string memory sb) {
        bytes memory bs = bytes(key);
        uint256 idx;
        for (uint256 i = 0; i < bs.length; i++) {
            if (bs[i] == 0x5f) {
                // '_'
                idx = i;
                break;
            }
        }
        // 左半部分
        bytes memory ba = new bytes(idx);
        for (uint256 i = 0; i < idx; i++) {
            ba[i] = bs[i];
        }
        // 右半部分
        bytes memory bb = new bytes(bs.length - idx - 1);
        for (uint256 i = idx + 1; i < bs.length; i++) {
            bb[i - idx - 1] = bs[i];
        }
        sa = string(ba);
        sb = string(bb);
    }

    function _requireToken(string memory sym) internal returns (address token) {
        token = _tokenAddress(sym);
        require(token != address(0), string.concat("Token address missing: ", sym));
    }

    function _applyOverride(
        address guard,
        string memory cfg,
        string memory key,
        uint16 defaultHardBps,
        uint32 defaultStaleSec
    ) internal {
        string memory path = string.concat(".overrides.", key, ".");

        uint8 en = uint8(_readUintWithDefault(cfg, string.concat(path, "enabled"), 0));
        uint16 hb = uint16(_readUintWithDefault(cfg, string.concat(path, "hardBps"), defaultHardBps));
        uint32 ss = uint32(_readUintWithDefault(cfg, string.concat(path, "staleSec"), defaultStaleSec));

        (address tokenA, address tokenB) = _splitPairSymToAddrs(key);
        GuardedRouter.PairCfg memory cfgStruct = GuardedRouter.PairCfg(hb, ss, en);
        GuardedRouter(guard).setPairCfg(tokenA, tokenB, cfgStruct);

        console2.log(string.concat("[override] ", key));
        console2.log(string.concat("  enabled=", vm.toString(uint256(en))));
        console2.log(string.concat("  hardBps=", vm.toString(uint256(hb))));
        console2.log(string.concat("  staleSec=", vm.toString(uint256(ss))));
    }

    function _readUintWithDefault(string memory json, string memory pointer, uint256 fallbackValue)
        internal
        view
        returns (uint256 value)
    {
        if (!json.keyExists(pointer)) {
            return fallbackValue;
        }
        try vm.parseJsonUint(json, pointer) returns (uint256 parsed) {
            return parsed;
        } catch {
            return fallbackValue;
        }
    }

    function _guardPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "configs/local/guard.json";
        if (block.chainid == 11155111) return "configs/sepolia/guard.json";
        if (block.chainid == 534351) return "configs/scroll/guard.json";
        revert("DeployGuard: missing guard config");
    }
}
