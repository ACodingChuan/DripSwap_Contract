// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

import {DeterministicDeployer} from "./utils/DeterministicDeployer.sol";

// Uniswap v2
import {UniswapV2Factory}  from "@uniswap/v2-core/contracts/UniswapV2Factory.sol";
import {UniswapV2Router02} from "@uniswap/v2-periphery/contracts/UniswapV2Router02.sol";

/// @notice 自建 V2 基建：Factory + Router（不部署 WETH；Router 用占位地址）
/// @dev    - 默认使用 CREATE2 确定性部署（deployIfNeeded）
///         - 校验：router.factory()/router.WETH() 回读一致；extcodesize 非零
///         - 地址簿写入：deployments/local.m1.json.v2{factory,router,weth,initCodeHash}
contract UseOrDeployV2Infra is Script {
    using stdJson for string;

    // ========== 配置 ==========
    string internal constant BOOK = "deployments/local.m1.json";
    // 占位 WETH（绝不使用 ETH 路径）
    address internal constant PLACEHOLDER_WETH = address(1);

    // CREATE2 工具部署（第一次脚本会 new 一个）
    DeterministicDeployer internal dd;

    function run() external {
        vm.startBroadcast(_pk());

        // 1) 如果没有 CREATE2 工具，就先部署一个
        dd = DeterministicDeployer(_deployIfNeeded(
            "CREATE2:DeterministicDeployer",
            type(DeterministicDeployer).creationCode,
            abi.encode()
        ));
        console2.log("CREATE2 Deployer:", address(dd));

        // 2) 部署 Factory（owner 先给 deployer，自建即可）
        address factory = _deployIfNeeded(
            "V2:Factory",
            type(UniswapV2Factory).creationCode,
            abi.encode(msg.sender) // feeToSetter
        );
        console2.log("V2 Factory:", factory);

        // 3) 部署 Router（WETH 用占位地址 address(1)）
        address router = _deployIfNeeded(
            "V2:Router02",
            type(UniswapV2Router02).creationCode,
            abi.encode(factory, PLACEHOLDER_WETH)
        );
        console2.log("V2 Router02:", router);

        // 4) 在线校验
        require(UniswapV2Router02(router).factory() == factory, "router.factory mismatch");
        require(UniswapV2Router02(router).WETH() == PLACEHOLDER_WETH, "router.WETH mismatch");

        // 5) 记录 INIT_CODE_PAIR_HASH（方便 offchain 计算 Pair 地址）
        bytes32 initCodeHash = UniswapV2Factory(factory).INIT_CODE_PAIR_HASH();

        // 6) 写地址簿
        string memory root = vm.readFile(BOOK);
        root = root.serialize("v2.factory", factory);
        root = root.serialize("v2.router", router);
        root = root.serialize("v2.weth", PLACEHOLDER_WETH);
        root = root.serialize("v2.initCodeHash", initCodeHash);
        vm.writeJson(root, BOOK);
        console2.log("AddressBook updated:", BOOK);

        vm.stopBroadcast();
    }

    // ========== 内部：CREATE2 确定性部署（若已存在则复用） ==========
    function _deployIfNeeded(string memory tag, bytes memory creationCode, bytes memory ctorArgs)
        internal
        returns (address deployed)
    {
        bytes memory init = abi.encodePacked(creationCode, ctorArgs);
        bytes32 salt = _salt(tag);
        address predicted = dd.compute(salt, init);
        if (predicted.code.length == 0) {
            deployed = dd.deploy(salt, init);
            require(deployed == predicted, "CREATE2: unexpected address");
            console2.log("[CREATE2] deployed:", tag, deployed);
        } else {
            deployed = predicted;
            console2.log("[CREATE2] exists:", tag, deployed);
        }
    }

    function _salt(string memory tag) internal view returns (bytes32) {
        // 统一盐规则：keccak256(namespace, chainid, tag)
        string memory ns = vm.envOr("SALT_NAMESPACE", string("dex-mvp1"));
        uint256 chainid = block.chainid;
        return keccak256(abi.encodePacked(ns, chainid, tag));
    }

    function _pk() internal view returns (uint256) {
        return vm.envUint("DEPLOYER_PK");
    }
}
