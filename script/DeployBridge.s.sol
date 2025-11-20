// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Bridge} from "src/bridge/Bridge.sol";

/// @title DeployBridge
/// @notice 通过 ERC-2470 部署 Bridge 合约并完成基础配置
contract DeployBridge is DeployBase {
    using stdJson for string;

    struct BridgeCfg {
        address router;
        address linkToken;
        uint64 chainSelector;
        address permit2;
    }

    function run() external {
        console2.log("=== DeployBridge ===");
        console2.log("Chain ID:", block.chainid);

        _ensureERC2470();

        // 1) 读取配置
        BridgeCfg memory cfg = _loadConfig();
        console2.log("Router:", cfg.router);
        console2.log("LINK Token:", cfg.linkToken);
        console2.log("Chain Selector:", cfg.chainSelector);
        console2.log("Permit2:", cfg.permit2);

        vm.startBroadcast();
        address deployer = msg.sender;

        // 2) 部署 Bridge
        (address bridge, bool fresh) = _deployBridge(deployer, cfg.router, cfg.linkToken, cfg.permit2);

        // 3) 配置基础参数（如果是新部署）
        if (fresh) {
            _configureBridge(bridge, deployer);
        }

        vm.stopBroadcast();

        // 4) 记录地址
        _bookSetAddress("bridge.address", bridge);
        _bookSetAddress("bridge.router", cfg.router);
        _bookSetAddress("bridge.link", cfg.linkToken);
        _bookSetUint("bridge.chain_selector", cfg.chainSelector);
        _bookSetAddress("bridge.permit2", cfg.permit2);

        if (fresh) {
            string memory mdPath = _deploymentFile("bridge.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[bridge]");
            vm.writeLine(mdPath, string.concat("  address: ", vm.toString(bridge)));
            vm.writeLine(mdPath, string.concat("  router: ", vm.toString(cfg.router)));
            vm.writeLine(mdPath, string.concat("  link_token: ", vm.toString(cfg.linkToken)));
            vm.writeLine(mdPath, string.concat("  chain_selector: ", vm.toString(cfg.chainSelector)));
            vm.writeLine(mdPath, string.concat("  permit2: ", vm.toString(cfg.permit2)));
            vm.writeLine(mdPath, string.concat("  admin: ", vm.toString(deployer)));
        }

        console2.log("[DONE] DeployBridge completed");
    }

    function _deployBridge(address admin, address router, address linkToken, address permit2)
        internal
        returns (address deployed, bool freshly)
    {
        bytes memory initCode =
            abi.encodePacked(type(Bridge).creationCode, abi.encode(admin, router, linkToken, permit2));

        bytes32 salt = keccak256(abi.encodePacked("DripSwap::Bridge"));
        (deployed, freshly) = _deployDeterministic(initCode, salt);

        if (freshly) {
            console2.log("[NEW] Bridge deployed:", deployed);
        } else {
            console2.log("[SKIP] Bridge exists:", deployed);
        }
    }

    function _configureBridge(address bridge, address admin) internal {
        Bridge b = Bridge(bridge);

        // 设置默认参数
        b.setServiceFee(0.001 ether, admin);
        console2.log("Service fee set: 0.001 ether");

        b.setLimits(1, type(uint256).max);
        console2.log("Limits set: min=1, max=unlimited");

        b.setPayMethod(true, true);
        console2.log("Payment methods: native=true, link=true");
    }

    function _loadConfig() internal returns (BridgeCfg memory c) {
        string memory path;
        if (block.chainid == 11155111) path = "configs/sepolia/bridge.json";
        else if (block.chainid == 534351) path = "configs/scroll/bridge.json";
        else if (block.chainid == 31337) path = "configs/local/bridge.json";
        else revert("Unsupported chain");

        string memory raw = vm.readFile(path);
        c.router = raw.readAddress(".router");
        c.linkToken = raw.readAddress(".link_token");
        c.chainSelector = uint64(raw.readUint(".chain_selector"));
        c.permit2 = raw.readAddress(".permit2");
    }
}
