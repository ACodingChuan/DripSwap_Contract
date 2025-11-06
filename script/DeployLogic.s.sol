// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {VToken} from "src/tokens/Vtoken.sol";

/// @title DeployLogic
/// @notice 通过 ERC-2470 部署可复用的逻辑合约（目前仅包含 VToken 逻辑）
contract DeployLogic is DeployBase {
    function run() external {
        console2.log("=== DeployLogic (ERC2470) ===");
        console2.log("Chain ID:", block.chainid);

        _ensureERC2470();

        vm.startBroadcast();

        (address vtokenLogic, bool fresh) = _deployVTokenLogic();

        vm.stopBroadcast();

        if (fresh) {
            string memory mdPath = _deploymentFile("logic.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[logic]");
            vm.writeLine(mdPath, "  component: vtoken");
            vm.writeLine(mdPath, string.concat("  address: ", vm.toString(vtokenLogic)));
        }

        console2.log("[DONE] DeployLogic completed");
    }

    function _deployVTokenLogic() internal returns (address implementation, bool fresh) {
        bytes memory initCode = type(VToken).creationCode;
        bytes32 salt = keccak256(abi.encodePacked("DripSwap::Logic::VToken"));

        (implementation, fresh) = _deployDeterministic(initCode, salt);
        if (fresh) {
            console2.log("[NEW] VToken logic deployed:", implementation);
        } else {
            console2.log("[SKIP] VToken logic exists:", implementation);
        }

        _bookSetAddress("logic.vtoken", implementation);
    }
}
