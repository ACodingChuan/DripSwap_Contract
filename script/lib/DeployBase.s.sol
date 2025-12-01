// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice 通用部署基类：封装 ERC-2470 操作、CREATE2 地址计算、JSON 写入等通用能力。
abstract contract DeployBase is Script {
    using stdJson for string;

    /// @dev ERC-2470 Singleton Factory 固定地址
    address internal constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    /// @dev ERC-2470 在本地链上缺失时注入的 runtime
    bytes internal constant ERC2470_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// @dev 确保 ERC-2470 在当前链上可用（Anvil 自动写入 runtime）
    function _ensureERC2470() internal {
        if (ERC2470.code.length > 0) {
            return;
        }

        if (block.chainid == 31337) {
            // Foundry 本地链：直接写入 runtime
            vm.etch(ERC2470, ERC2470_RUNTIME);
            console2.log("[ERC2470] injected runtime on Anvil");
        } else {
            revert("_ensureERC2470: ERC-2470 missing on this network");
        }
    }

    /// @dev 兼容 Foundry 广播缓存：每次部署前可选删除历史记录
    function _clearBroadcast(string memory scriptName) internal {
        string memory path = string.concat("broadcast/", scriptName);
        if (vm.exists(path)) {
            vm.removeDir(path, true);
        }
        path = string.concat("cache/", scriptName);
        if (vm.exists(path)) {
            vm.removeDir(path, true);
        }
    }

    /// @dev 通过 ERC-2470 + CREATE2 部署任意 bytecode（若已存在则跳过）
    /// @param initCode 合约 creation bytecode
    /// @param salt CREATE2 盐值
    /// @return deployed 部署后的地址
    /// @return freshly 表示是否本次新部署（false 表示地址已有代码）
    function _deployDeterministic(bytes memory initCode, bytes32 salt)
        internal
        returns (address deployed, bool freshly)
    {
        deployed = _predictCreate2Address(initCode, salt);
        if (deployed.code.length > 0) {
            return (deployed, false);
        }

        _ensureERC2470();

        // 调用工厂合约的 deploy(bytes initCode, bytes32 salt) 函数
        // 函数选择器: 0x4af63f02
        bytes memory payload = abi.encodeWithSelector(bytes4(0x4af63f02), initCode, salt);

        (bool success, bytes memory result) = ERC2470.call(payload);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            revert("_deployDeterministic: factory call failed");
        }

        deployed = _parseFactoryReturn(result);
        freshly = true;
    }

    /// @dev 使用 ERC-2470 部署最小代理（EIP-1167）
    /// @param implementation 被代理的逻辑合约
    /// @param salt CREATE2 盐值
    /// @return proxy 代理地址
    /// @return freshly 是否新部署
    function _deployMinimalProxy(address implementation, bytes32 salt) internal returns (address proxy, bool freshly) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        return _deployDeterministic(initCode, salt);
    }

    /// @dev 根据 initCode + salt 预测 CREATE2 地址
    function _predictCreate2Address(bytes memory initCode, bytes32 salt) internal pure returns (address addr) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), ERC2470, salt, keccak256(initCode)));
        addr = address(uint160(uint256(hash)));
    }

    /// @dev 解析 ERC-2470 返回值（兼容 20/32 字节）
    function _parseFactoryReturn(bytes memory result) internal pure returns (address deployed) {
        if (result.length == 20) {
            uint256 word;
            assembly {
                word := mload(add(result, 0x20))
            }
            deployed = address(uint160(word >> 96));
        } else if (result.length == 32) {
            deployed = abi.decode(result, (address));
        } else {
            revert("_parseFactoryReturn: invalid factory response");
        }
    }

    /// @dev 获取地址簿文件路径
    /// @dev 返回当前网络的部署目录（用于 .md 记录）；自动创建
    function _deploymentDir() internal returns (string memory dir) {
        if (block.chainid == 31337) dir = "deployments/local";
        else if (block.chainid == 11155111) dir = "deployments/sepolia";
        else if (block.chainid == 534351) dir = "deployments/scroll";
        else revert("_deploymentDir: unsupported chain id");

        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }
    }

    /// @dev 获取指定部署日志文件路径（位于部署目录下）
    function _deploymentFile(string memory name) internal returns (string memory) {
        string memory dir = _deploymentDir();
        return string.concat(dir, "/", name);
    }

    /// @dev 地址簿路径（key:value 格式 md 文件）
    function _addressBookPath() internal returns (string memory path) {
        path = string.concat(_deploymentDir(), "/address_book.md");
        if (!vm.exists(path)) {
            vm.writeFile(path, "");
        }
    }

    // TODO: 临时兼容旧脚本逻辑，后续统一改写为 md 读取
    function _bookPath() internal returns (string memory) {
        return _addressBookPath();
    }

    function _logicBookPath() internal returns (string memory path) {
        path = string.concat(_deploymentDir(), "/logic.json");
        if (!vm.exists(path)) {
            vm.writeFile(path, "{}");
        }
    }

    /// @dev 从地址簿读取字符串值（不存在返回空）
    function _bookGet(string memory key) internal returns (string memory) {
        bytes memory data = bytes(vm.readFile(_addressBookPath()));
        bytes memory target = bytes(key);
        uint256 pos = data.length;

        while (pos > 0) {
            uint256 lineEnd = pos;
            uint256 lineStart = lineEnd;
            while (lineStart > 0 && data[lineStart - 1] != "\n") {
                unchecked {
                    lineStart--;
                }
            }

            if (lineEnd > lineStart) {
                uint256 colon = lineStart;
                while (colon < lineEnd && data[colon] != ":") {
                    unchecked {
                        colon++;
                    }
                }
                if (colon < lineEnd) {
                    string memory foundKey = _trim(_slice(data, lineStart, colon));
                    if (keccak256(bytes(foundKey)) == keccak256(target)) {
                        return _trim(_slice(data, colon + 1, lineEnd));
                    }
                }
            }

            if (lineStart == 0) break;
            unchecked {
                pos = lineStart - 1;
            }
        }

        return "";
    }

    function _bookGetAddress(string memory key) internal returns (address) {
        string memory val = _bookGet(key);
        if (bytes(val).length == 0) return address(0);
        return vm.parseAddress(val);
    }

    function _bookGetUint(string memory key) internal returns (uint256) {
        string memory val = _bookGet(key);
        if (bytes(val).length == 0) return 0;
        return vm.parseUint(val);
    }

    function _bookSet(string memory key, string memory value) internal {
        vm.writeLine(_addressBookPath(), string.concat(key, ": ", value));
    }

    function _bookSetAddress(string memory key, address value) internal {
        _bookSet(key, vm.toString(value));
    }

    function _bookSetUint(string memory key, uint256 value) internal {
        _bookSet(key, vm.toString(value));
    }

    function _tokenAddress(string memory symbol) internal returns (address) {
        return _bookGetAddress(string.concat("tokens.", symbol, ".address"));
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        if (end <= start) return "";
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; ++i) {
            out[i - start] = data[i];
        }
        return string(out);
    }

    function _trim(string memory str) internal pure returns (string memory) {
        bytes memory data = bytes(str);
        uint256 start;
        uint256 end = data.length;
        while (start < data.length && _isWhitespace(data[start])) start++;
        while (end > start && _isWhitespace(data[end - 1])) end--;
        if (start == 0 && end == data.length) return str;
        return _slice(data, start, end);
    }

    function _isWhitespace(bytes1 ch) private pure returns (bool) {
        return ch == 0x20 || ch == 0x09 || ch == 0x0a || ch == 0x0d;
    }
}
