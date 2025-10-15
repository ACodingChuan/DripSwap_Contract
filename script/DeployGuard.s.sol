// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {GuardedRouter} from "src/guard/GuardedRouter.sol";
import {IOracleRouter} from "src/interfaces/IOracleRouter.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";

/// @notice 部署 Guard（软约束）并按可选配置写入默认值与 per-pair 覆盖
/// @dev    兼容旧版 forge-std：不使用 string.indexOf / readKeys，改为 try/catch 读取
contract DeployGuard is Script {
    using stdJson for string;

    string internal constant BOOK   = "deployments/local.m1.json";
    string internal constant GUARDC = "configs/guard.sepolia.json";

    function run() external {
        uint256 pk    = vm.envUint("DEPLOYER_PK");
        address owner = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1) 读取 v2.factory / oracle.router
        string memory book = vm.readFile(BOOK);
        address factory = vm.parseAddress(book.readString(".v2.factory"));
        address oracle  = vm.parseAddress(book.readString(".oracle.router"));

        // 2) 默认阈值（若没有 guard 配置，则使用 .env）
        uint16 hardBps      = uint16(vm.envOr("HARD_BPS_DEFAULT", uint256(300)));
        uint16 hardBpsFixed = uint16(vm.envOr("HARD_BPS_FIXED",  uint256(500)));
        uint32 staleSec     = uint32(vm.envOr("STALE_SEC_DEFAULT", uint256(600)));

        // 3) 如存在 configs/guard.sepolia.json ，能读到就覆盖
        if (vm.exists(GUARDC)) {
            string memory cfg = vm.readFile(GUARDC);

            // defaults
            try this._readString(cfg, ".defaults.hardBps") returns (string memory v) {
                hardBps = uint16(vm.parseUint(v));
            } catch {}
            try this._readString(cfg, ".defaults.hardBpsFixed") returns (string memory v) {
                hardBpsFixed = uint16(vm.parseUint(v));
            } catch {}
            try this._readString(cfg, ".defaults.staleSec") returns (string memory v) {
                staleSec = uint32(vm.parseUint(v));
            } catch {}
        }

        // 4) 部署 Guard（注意传 owner）
        GuardedRouter guard = new GuardedRouter(
            factory,
            oracle,
            hardBps,
            hardBpsFixed,
            staleSec,
            owner
        );
        console2.log("GuardedRouter deployed at:", address(guard));

        // 5) per-pair overrides（可选）
        if (vm.exists(GUARDC)) {
            string memory cfg = vm.readFile(GUARDC);
            // 通过 overrideKeys 列出需要覆盖的键集合；没有该字段则跳过
            try this._readStringArray(cfg, ".overrideKeys") returns (string[] memory keys) {
                for (uint i = 0; i < keys.length; i++) {
                    string memory key = keys[i];                   // e.g. "vETH_vUSDT"
                    string memory p   = string.concat(".overrides.", key, ".");

                    uint8  en = 0;
                    uint16 hb = hardBps;   // 缺省回退到 defaults
                    uint32 ss = staleSec;  // 缺省回退到 defaults

                    try this._readString(cfg, string.concat(p, "enabled")) returns (string memory v) {
                        en = uint8(vm.parseUint(v));
                    } catch {}
                    try this._readString(cfg, string.concat(p, "hardBps")) returns (string memory v) {
                        hb = uint16(vm.parseUint(v));
                    } catch {}
                    try this._readString(cfg, string.concat(p, "staleSec")) returns (string memory v) {
                        ss = uint32(vm.parseUint(v));
                    } catch {}

                    (address a, address b) = _splitPairSymToAddrs(key);
                    GuardedRouter.PairCfg memory pc = GuardedRouter.PairCfg(hb, ss, en);
                    guard.setPairCfg(a, b, pc);

                    // 稳定日志（避免多类型变参）
                    console2.log(string.concat("[override] ", key));
                    console2.log(string.concat("  enabled=", vm.toString(uint256(en))));
                    console2.log(string.concat("  hardBps=", vm.toString(uint256(hb))));
                    console2.log(string.concat("  staleSec=", vm.toString(uint256(ss))));
                }
            } catch {}
        }

        // 6) 地址簿写回
        book = book.serialize("guard.address", address(guard));
        book = book.serialize("guard.defaults.hardBps",      hardBps);
        book = book.serialize("guard.defaults.hardBpsFixed", hardBpsFixed);
        book = book.serialize("guard.defaults.staleSec",     staleSec);
        vm.writeJson(book, BOOK);
        console2.log("AddressBook updated:", BOOK);

        vm.stopBroadcast();
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
    function _splitPairSymToAddrs(string memory key) internal view returns (address a, address b) {
        (string memory sa, string memory sb) = _splitPairSym(key);
        a = _symToAddr(sa);
        b = _symToAddr(sb);
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
    function _symToAddr(string memory sym) internal view returns (address) {
        string memory book = vm.readFile(BOOK);
        string memory path = string.concat(".tokens.", sym, ".address");
        return vm.parseAddress(book.readString(path));
    }
}
