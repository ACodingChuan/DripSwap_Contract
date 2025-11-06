// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";

/// @notice 简单脚本：在当前网络确保 ERC-2470 存在
/// @dev 对于 Anvil，使用 vm.etch 注入代码（在模拟阶段生效，足够后续脚本使用）
contract EnsureERC2470 is DeployBase {
    function run() external {
        console2.log("=== Ensure ERC-2470 Singleton Factory ===");
        console2.log("Chain ID:", block.chainid);
        
        if (ERC2470.code.length > 0) {
            console2.log("[OK] ERC-2470 already exists at", ERC2470);
            return;
        }
        
        if (block.chainid == 31337) {
            // Anvil: 使用 vm.etch 注入代码
            // 注意：vm.etch 只在 Foundry 模拟环境中生效，不会生成真实交易
            // 但这足够了，因为后续脚本在执行时也会调用 _ensureERC2470()
            vm.etch(ERC2470, ERC2470_RUNTIME);
            console2.log("[ERC2470] injected runtime on Anvil (simulation only)");
            console2.log("[INFO] Subsequent scripts will also inject ERC-2470 in their simulation phase");
        } else {
            revert("ERC-2470 not deployed on this network. Please deploy it first.");
        }
        
        console2.log("[OK] ERC-2470 ready at", ERC2470);
    }
}
