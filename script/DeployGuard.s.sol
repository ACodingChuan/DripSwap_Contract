// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {GuardedRouter} from "src/guard/GuardedRouter.sol";

/// @notice 部署 Guard（软约束）并按可选配置写入默认值与 per-pair 覆盖
/// @dev    兼容旧版 forge-std：不使用 string.indexOf / readKeys，改为 try/catch 读取
contract DeployGuard is Script {
    using stdJson for string;

    address constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        
        console2.log("=== Deploying Guarded Router ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");
        
        // 验证ERC-2470存在
        require(ERC2470.code.length > 0, "ERC-2470 not found");

        string memory bookPath  = _bookPath();
        string memory guardPath = _guardPath();
        
        vm.startBroadcast(pk);

        // 1) 读取依赖地址
        string memory book = vm.readFile(bookPath);
        address factory = vm.parseAddress(book.readString(".v2.factory"));
        address oracle  = vm.parseAddress(book.readString(".oracle.router"));

        // 2) 默认阈值（若没有 guard 配置，则使用 .env）
        uint16 hardBps      = 300;
        uint16 hardBpsFixed = 500;
        uint32 staleSec     = 600;

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
        address guard = _deployGuard(factory, oracle, hardBps, hardBpsFixed, staleSec, owner);
        console2.log("GuardedRouter:", guard);

        // 5) per-pair overrides（可选）
        if (hasGuardCfg) {
            // 通过 overrideKeys 列出需要覆盖的键集合；没有该字段则跳过
            try vm.parseJsonKeys(cfg, ".overrides") returns (string[] memory keys) {
                for (uint i = 0; i < keys.length; i++) {
                    string memory key = keys[i];                   // e.g. "vETH_vUSDT"
                    string memory p   = string.concat(".overrides.", key, ".");

                    uint8  en = 0;
                    uint16 hb = hardBps;   // 缺省回退到 defaults
                    uint32 ss = staleSec;  // 缺省回退到 defaults

                    try vm.parseJsonUint(cfg, string.concat(p, "enabled")) returns (uint256 v) {
                        en = uint8(v);
                    } catch {}
                    try vm.parseJsonUint(cfg, string.concat(p, "hardBps")) returns (uint256 v) {
                        hb = uint16(v);
                    } catch {}
                    try vm.parseJsonUint(cfg, string.concat(p, "staleSec")) returns (uint256 v) {
                        ss = uint32(v);
                    } catch {}

                    (address a, address b) = _splitPairSymToAddrs(bookPath, key);
                    GuardedRouter.PairCfg memory pc = GuardedRouter.PairCfg(hb, ss, en);
                    GuardedRouter(guard).setPairCfg(a, b, pc);

                    // 稳定日志（避免多类型变参）
                    console2.log(string.concat("[override] ", key));
                    console2.log(string.concat("  enabled=", vm.toString(uint256(en))));
                    console2.log(string.concat("  hardBps=", vm.toString(uint256(hb))));
                    console2.log(string.concat("  staleSec=", vm.toString(uint256(ss))));
                }
            } catch {}
        }

        // 6) 地址簿写回（使用路径方式避免覆盖）
        vm.writeJson(vm.toString(guard), bookPath, ".guard.router");
        vm.writeJson(vm.toString(hardBps), bookPath, ".guard.defaults.hardBps");
        vm.writeJson(vm.toString(hardBpsFixed), bookPath, ".guard.defaults.hardBpsFixed");
        vm.writeJson(vm.toString(staleSec), bookPath, ".guard.defaults.staleSec");
        console2.log("AddressBook updated:", bookPath);

        vm.stopBroadcast();
        
        console2.log("");
        console2.log("[OK] Guarded Router deployed/configured");
    }

    /// @notice 部署Guard（带幂等性检查）
    function _deployGuard(
        address factory,
        address oracle,
        uint16 hardBps,
        uint16 hardBpsFixed,
        uint32 staleSec,
        address owner
    ) internal returns (address) {
        // 生成盐值
        bytes32 salt = keccak256(
            abi.encodePacked(
                "DripSwap",
                "Guard",
                "GuardedRouter",
                block.chainid
            )
        );
        
        // 准备字节码
        bytes memory creationCode = type(GuardedRouter).creationCode;
        bytes memory bytecode = abi.encodePacked(
            creationCode,
            abi.encode(factory, oracle, hardBps, hardBpsFixed, staleSec, owner)
        );
        
        // 计算预期地址
        address predicted = _computeCreate2Address(salt, bytecode);
        
        // 检查是否已部署
        if (predicted.code.length > 0) {
            console2.log("[OK] Guard already deployed");
            console2.log("  Address:", predicted);
            return predicted;
        }
        
        // 部署
        console2.log("Deploying Guard...");
        
        bytes memory payload = abi.encodePacked(salt, bytecode);
        (bool success, bytes memory result) = ERC2470.call(payload);
        require(success, "Guard deployment failed");
        
        // 解码返回地址（ERC-2470返回20字节）
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
            revert("Guard: invalid factory response");
        }
        
        require(deployed == predicted, "Guard address mismatch");
        
        console2.log("[OK] Guard deployed");
        console2.log("  Address:", deployed);
        
        return deployed;
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

    // ----------------- helpers -----------------

    /// @dev 读取字符串字段（字段不存在会 revert；外层 try/catch 捕获）
    function _readString(string memory json, string memory key)
        external
        pure
        returns (string memory)
    {
        return json.readString(key);
    }

    /// @dev 读取字符串数组字段（需要较新的 Foundry；不存在会 revert）
    function _readStringArray(string memory json, string memory key)
        external
        pure
        returns (string[] memory)
    {
        return vm.parseJsonStringArray(json, key);
    }

    /// @dev 将 "vETH_vUSDT" 拆成两个地址（从地址簿 tokens 节点读取）
    function _splitPairSymToAddrs(string memory bookPath, string memory key) internal view returns (address a, address b) {
        (string memory sa, string memory sb) = _splitPairSym(key);
        a = _symToAddr(bookPath, sa);
        b = _symToAddr(bookPath, sb);
    }

    /// @dev 从 "vETH_vUSDT" 提取 ["vETH","vUSDT"]（纯 Solidity 实现，兼容性最好）
    function _splitPairSym(string memory key) internal pure returns (string memory sa, string memory sb) {
        bytes memory bs = bytes(key);
        uint idx;
        for (uint i = 0; i < bs.length; i++) {
            if (bs[i] == 0x5f) { // '_'
                idx = i;
                break;
            }
        }
        // 左半部分
        bytes memory ba = new bytes(idx);
        for (uint i = 0; i < idx; i++) {
            ba[i] = bs[i];
        }
        // 右半部分
        bytes memory bb = new bytes(bs.length - idx - 1);
        for (uint i = idx + 1; i < bs.length; i++) {
            bb[i - idx - 1] = bs[i];
        }
        sa = string(ba);
        sb = string(bb);
    }

    /// @dev 从地址簿 tokens 映射读取 symbol 对应的地址
    function _symToAddr(string memory bookPath, string memory sym) internal view returns (address) {
        string memory book = vm.readFile(bookPath);
        string memory path = string.concat(".tokens.", sym, ".address");
        return vm.parseAddress(book.readString(path));
    }

    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "deployments/local.m1.json";
        if (block.chainid == 11155111) return "deployments/sepolia.m1.json";
        if (block.chainid == 534351) return "deployments/scroll-sepolia.m1.json";
        revert("DeployGuard: unsupported chain");
    }

    function _guardPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "configs/local/guard.json";
        if (block.chainid == 11155111) return "configs/sepolia/guard.json";
        if (block.chainid == 534351) return "configs/scroll/guard.json";
        revert("DeployGuard: missing guard config");
    }
}
