// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployBase} from "script/lib/DeployBase.s.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {DripBurnMintTokenPool} from "src/vendor/chainlink/DripBurnMintTokenPool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeployBurnMintPools (address_book 驱动版)
/// @notice 从 deployments/<chain>/address_book.md 读取 tokens 列表与地址，
///         allowlist 使用已部署的 Bridge 地址；按 Token 部署 BurnMintTokenPool。
contract DeployBurnMintPools is DeployBase {
    using stdJson for string;

    struct BurnMintConfig {
        address rmnProxy;
        address router;
        uint64 chainSelector; // 仅用于日志
        address linkToken; // 仅用于日志/核对
    }

    function run() external {
        console2.log("=== Deploying BurnMintTokenPools (allowlist = Bridge) ===");

        // 0) 读取 Bridge 地址（allowlist 需要）
        address bridge = _bookGetAddress("bridge.address");
        require(bridge != address(0), "bridge.address missing  deploy Bridge first");
        console2.log("bridge.address:", bridge);

        // 1) 读取 Burn-Mint config（容错键名）
        BurnMintConfig memory cfg = _loadConfig();
        console2.log("cfg.router:", cfg.router);
        console2.log("cfg.rmnProxy:", cfg.rmnProxy);
        console2.log("cfg.selector:", cfg.chainSelector);
        if (cfg.linkToken != address(0)) {
            console2.log("cfg.LINK:", cfg.linkToken);
        }

        // 2) 从 address_book.md 提取所有 token 符号（tokens.<SYM>.address）
        string[] memory symbols = _listTokenSymbolsFromAddressBook();
        console2.log("Found", symbols.length, "tokens in address_book");

        vm.startBroadcast();

        for (uint256 i = 0; i < symbols.length; i++) {
            string memory sym = symbols[i];
            address tokenAddr = _bookGetAddress(string.concat("tokens.", sym, ".address"));
            require(tokenAddr != address(0), string.concat("Missing token address for symbol ", sym));

            // allowlist 只包含 Bridge（作为 originalSender）
            address[] memory allowlist = new address[](1);
            allowlist[0] = bridge;

            string memory bookKey = string.concat("burnmint.", sym, ".address");
            address recorded = _bookGetAddress(bookKey);
            if (recorded != address(0) && recorded.code.length > 0) {
                console2.log("[-] Existing BurnMintPool for", sym, ":", recorded);
                continue;
            }

            DripBurnMintTokenPool pool = new DripBurnMintTokenPool(
                IBurnMintERC20(tokenAddr), IERC20Metadata(tokenAddr).decimals(), allowlist, cfg.rmnProxy, cfg.router
            );
            address poolAddr = address(pool);

            console2.log("[+] Deployed BurnMintPool for", sym, ":", poolAddr);
            console2.log("    owner:", pool.owner());

            _bookSetAddress(bookKey, poolAddr);
        }

        vm.stopBroadcast();
        console2.log("=== All BurnMintTokenPools deployed (allowlist=Bridge) ===");
    }

    /// @dev 读取 configs/{chain}/burnmint.json，并容错不同写法的键名
    function _loadConfig() internal returns (BurnMintConfig memory cfg) {
        string memory path;
        if (block.chainid == 11155111) path = "configs/sepolia/burnmint.json";
        else if (block.chainid == 534351) path = "configs/scroll/burnmint.json";
        else if (block.chainid == 31337) path = "configs/local/burnmint.json";
        else revert("Unsupported chain");

        string memory raw = vm.readFile(path);

        // 必填
        cfg.rmnProxy = _readAddrLoose(raw, ".rmnProxy");
        cfg.router = _readAddrLoose(raw, ".router");

        // 可选：不同文件里可能是 "chainSelector" 或 "Chain selector"
        (bool has, uint256 sel) = _tryReadUint(raw, ".chainSelector");
        if (!has) {
            (has, sel) = _tryReadUint(raw, ".Chain selector");
        }
        if (has) cfg.chainSelector = uint64(sel);

        // 可选：LINK
        (has, sel) = _tryReadUint(raw, ".LINK"); // 允许误写成 uint（不会用）
        if (!has) {
            address link = _readAddrLooseOrZero(raw, ".LINK");
            if (link != address(0)) cfg.linkToken = link;
        } else {
            // 忽略 uint 形式
        }
    }

    /// @dev 从 address_book.md 扫描 tokens.<SYM>.address 行，抽取 SYM 去重返回
    function _listTokenSymbolsFromAddressBook() internal returns (string[] memory symbols) {
        string memory book = vm.readFile(_addressBookPath());
        bytes memory data = bytes(book);

        // 先粗略计数
        uint256 count;
        for (uint256 i; i + 8 < data.length; i++) {
            // "tokens." 的快速匹配
            if (
                data[i] == "t" && data[i + 1] == "o" && data[i + 2] == "k" && data[i + 3] == "e" && data[i + 4] == "n"
                    && data[i + 5] == "s" && data[i + 6] == "."
            ) {
                // 找 ".address:" 结尾
                uint256 j = i + 7;
                while (j < data.length && data[j] != ":") {
                    if (data[j] == "." && j + 8 < data.length) {
                        // 可能到 ".address"
                        if (
                            data[j + 1] == "a" && data[j + 2] == "d" && data[j + 3] == "d" && data[j + 4] == "r"
                                && data[j + 5] == "e" && data[j + 6] == "s" && data[j + 7] == "s"
                        ) {
                            count++;
                            break;
                        }
                    }
                    j++;
                }
            }
        }

        // 收集并去重
        string[] memory tmp = new string[](count);
        uint256 idx;
        for (uint256 i; i + 8 < data.length; i++) {
            if (
                data[i] == "t" && data[i + 1] == "o" && data[i + 2] == "k" && data[i + 3] == "e" && data[i + 4] == "n"
                    && data[i + 5] == "s" && data[i + 6] == "."
            ) {
                uint256 start = i + 7;
                uint256 end = start;
                // 读到下一个 '.'（即 ".address" 之前）
                while (end < data.length && data[end] != ".") end++;
                if (end >= data.length) break;

                // 确认后缀是 ".address"
                if (
                    end + 8 < data.length && data[end + 1] == "a" && data[end + 2] == "d" && data[end + 3] == "d"
                        && data[end + 4] == "r" && data[end + 5] == "e" && data[end + 6] == "s" && data[end + 7] == "s"
                ) {
                    string memory sym = _slice(data, start, end);
                    bool exists;
                    for (uint256 k; k < idx; k++) {
                        if (keccak256(bytes(tmp[k])) == keccak256(bytes(sym))) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        tmp[idx++] = sym;
                    }
                }
            }
        }

        // 收缩
        symbols = new string[](idx);
        for (uint256 k; k < idx; k++) {
            symbols[k] = tmp[k];
        }
    }

    // -------------------- 小工具：松散读取 JSON --------------------

    function _readAddrLoose(string memory raw, string memory key) internal view returns (address a) {
        a = raw.readAddress(key);
        require(a != address(0), string.concat("missing ", key));
    }

    function _readAddrLooseOrZero(string memory raw, string memory key) internal view returns (address a) {
        if (raw.keyExists(key)) {
            a = raw.readAddress(key);
        } else {
            a = address(0);
        }
    }

    function _tryReadUint(string memory raw, string memory key) internal view returns (bool ok, uint256 v) {
        if (raw.keyExists(key)) {
            v = raw.readUint(key);
            ok = true;
        } else {
            ok = false;
            v = 0;
        }
    }
}
