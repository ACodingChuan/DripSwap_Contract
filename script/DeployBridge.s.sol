// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Bridge} from "src/bridge/Bridge.sol"; // 指向你最新的 Bridge（调 Pool 的版本）

contract DeployBridge is DeployBase {
    using stdJson for string;

    struct BridgeCfg {
        address linkToken;
    }

    function run() external {
        console2.log("=== DeployBridge ===");
        _ensureERC2470();

        // 1) 读取配置
        BridgeCfg memory cfg = _loadConfig();

        vm.startBroadcast();

        // 2) 组合 initCode 并确定性部署
        bytes memory initCode = abi.encodePacked(
            type(Bridge).creationCode,
            abi.encode(msg.sender) // admin_ = 广播者
        );

        bytes32 salt = keccak256(abi.encodePacked("DripSwap::Bridge"));
        (address bridge, bool fresh) = _deployDeterministic(initCode, salt);

        if (fresh) {
            console2.log("[NEW] Bridge:", bridge);
        } else {
            console2.log("[SKIP] Bridge exists:", bridge);
        }

        // 3) 初始化：设置 LINK Token（可重复设置）
        if (cfg.linkToken != address(0)) {
            (bool ok, ) = bridge.call(abi.encodeWithSignature("setLinkToken(address)", cfg.linkToken));
            require(ok, "setLinkToken failed");
            console2.log("setLinkToken:", cfg.linkToken);
        }

        vm.stopBroadcast();

        // 4) 记录地址
        _bookSetAddress("bridge.address", bridge);
        console2.log("[DONE] DeployBridge");
    }

    function _loadConfig() internal returns (BridgeCfg memory c) {
        string memory path;
        if (block.chainid == 11155111) path = "configs/sepolia/bridge.json";
        else if (block.chainid == 534351) path = "configs/scroll/bridge.json";
        else if (block.chainid == 31337) path = "configs/local/bridge.json";
        else revert("Unsupported chain");

        string memory raw = vm.readFile(path);
        c.linkToken = raw.readAddress(".link_token");
        console2.log("config.link_token:", c.linkToken);
    }
}
