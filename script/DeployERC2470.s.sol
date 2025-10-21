// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployERC2470
/// @notice 在Anvil上部署ERC-2470到标准地址，测试网跳过（已存在）
/// @dev 使用vm.etch在Anvil上部署，确保所有网络使用相同的工厂地址
contract DeployERC2470 is Script {
    // ERC-2470标准地址（所有链统一）
    address constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    // ERC-2470运行时字节码
    // 来源: https://eips.ethereum.org/EIPS/eip-2470
    bytes constant RUNTIME_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function run() external returns (address) {
        console2.log("=== ERC-2470 Singleton Factory Setup ===");
        console2.log("Standard address:", ERC2470);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // 检查是否已部署
        if (_isDeployed(ERC2470)) {
            console2.log("[OK] ERC-2470 already deployed");
            _printInfo();
            return ERC2470;
        }

        // 只在Anvil上部署
        if (block.chainid == 31337) {
            console2.log("Deploying ERC-2470 to Anvil using vm.etch...");
            vm.etch(ERC2470, RUNTIME_CODE);
            string memory addr = vm.toString(ERC2470);
            string memory code = vm.toString(RUNTIME_CODE);
            string memory params = string.concat("[\"", addr, "\",\"", code, "\"]");
            vm.rpc("anvil_setCode", params);
            require(_isDeployed(ERC2470), "ERC-2470 injection failed");
            console2.log("[OK] ERC-2470 deployed to Anvil");
            console2.log("");
            _printInfo();
            return ERC2470;
        }

        // 其他网络应该已存在
        console2.log("[ERROR] ERC-2470 not found on this network");
        console2.log("");
        console2.log("Expected networks:");
        console2.log("  - Sepolia (11155111): Should exist");
        console2.log("  - Scroll Sepolia (534351): Should exist");
        console2.log("  - Anvil (31337): Will be deployed");
        console2.log("");
        console2.log("Current chain:", block.chainid);

        revert("ERC-2470 not found and cannot deploy on this network");
    }

    /// @notice 检查地址是否已部署合约
    function _isDeployed(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }

    /// @notice 打印ERC-2470信息
    function _printInfo() internal view {
        console2.log("=== ERC-2470 Information ===");
        console2.log("Address:", ERC2470);
        console2.log("Code size:", ERC2470.code.length, "bytes");
        console2.log("Standard: EIP-2470");
        console2.log("Reference: https://eips.ethereum.org/EIPS/eip-2470");
        console2.log("");
        console2.log("[OK] Ready for deterministic deployments");
        console2.log("   All contracts deployed via ERC-2470 will have");
        console2.log(
            "   the same address across Anvil, Sepolia, and Scroll Sepolia"
        );
        console2.log("");
    }
}
