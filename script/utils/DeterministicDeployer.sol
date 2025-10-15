// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DeterministicDeployer (CREATE2 工具)
/// @notice 使用 CREATE2 以确定性地址部署任意合约字节码。
///         注意：地址 = keccak256(0xff, deployer, salt, keccak256(init_code)) 的标准公式。
///         相同部署者 + 相同 salt + 相同 init_code → 地址恒定。
contract DeterministicDeployer {
    error DeployFailed();

    /// @dev 用 CREATE2 部署
    /// @param salt     用户自定义盐（建议包含：命名空间/chainId/名字/版本）
    /// @param initCode 完整 init code（含构造参数编码）
    function deploy(bytes32 salt, bytes memory initCode) external payable returns (address addr) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            addr := create2(callvalue(), add(initCode, 0x20), mload(initCode), salt)
        }
        if (addr == address(0)) revert DeployFailed();
    }

    /// @dev 预计算地址（链下/链上均可）
    function compute(bytes32 salt, bytes memory initCode) external view returns (address predicted) {
        bytes32 codeHash = keccak256(initCode);
        // EIP-1014: keccak256(0xff, this, salt, keccak256(init_code))[12:]
        predicted = address(uint160(uint(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            codeHash
        )))));
    }
}
