// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @dev 简单的可铸造ERC20（仅用于测试）
contract SimpleMintableERC20 {
    string public name;
    string public symbol;
    uint8  public immutable DECIMALS;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address=>uint256)) public allowance;

    constructor(string memory _n, string memory _s, uint8 _d) {
        name = _n; symbol = _s; DECIMALS = _d;
    }
    function decimals() external view returns (uint8) { return DECIMALS; }
    function approve(address s, uint256 a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function transfer(address to, uint256 a) external returns(bool){ _move(msg.sender,to,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){
        uint256 al=allowance[f][msg.sender]; require(al>=a,"allow"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; _move(f,t,a); return true;
    }
    function mint(address to, uint256 a) external { totalSupply+=a; balanceOf[to]+=a; }
    function _move(address f,address t,uint256 a) internal { require(balanceOf[f]>=a,"bal"); balanceOf[f]-=a; balanceOf[t]+=a; }
}

/// @title DeployTokens
/// @notice 部署测试代币（带幂等性检查）
contract DeployTokens is Script {
    using stdJson for string;

    address constant ERC2470 = 0xce0042B868300000d44A59004Da54A005ffdcf9f;
    bytes constant ERC2470_RUNTIME = hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    struct TokenInfo { 
        string sym; 
        uint8 dec; 
        uint256 mintAmt; 
    }

    function run() external {
        console2.log("=== Deploying Test Tokens ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("");
        
        // 确保ERC-2470存在
        _ensureERC2470();
        
        vm.startBroadcast();

        address deployer = msg.sender;

        // 定义测试代币（增加mint数量以确保流动性充足）
        TokenInfo[] memory tokens = new TokenInfo[](7);
        tokens[0] = TokenInfo("vETH",  18, 10_000 ether);             // 1 万枚 vETH
        tokens[1] = TokenInfo("vUSDT",  6, 1_000_000 * 1e6);          // 100 万枚 vUSDT
        tokens[2] = TokenInfo("vUSDC",  6, 1_000_000 * 1e6);          // 100 万枚 vUSDC
        tokens[3] = TokenInfo("vDAI",  18, 1_000_000 ether);          // 100 万枚 vDAI
        tokens[4] = TokenInfo("vBTC",   8, 10_000 * 1e8);             // 1 万枚 vBTC
        tokens[5] = TokenInfo("vLINK", 18, 1_000_000 ether);          // 100 万枚 vLINK
        tokens[6] = TokenInfo("vSCR",  18, 2_000_000 ether);          // 200 万枚 vSCR，覆盖多交易对初次注入

        string memory bookPath = _bookPath();

        address[] memory deployedAddrs = new address[](tokens.length);
        for (uint i = 0; i < tokens.length; i++) {
            deployedAddrs[i] = _deployToken(tokens[i], deployer);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("[OK] All tokens deployed/verified");
        
        // 在stopBroadcast之后写入配置
        _writeTokensConfig(bookPath, tokens, deployedAddrs);
        console2.log("   Config updated:", bookPath);
    }

    /// @notice 部署单个代币（带幂等性检查）
    function _deployToken(TokenInfo memory info, address deployer) internal returns (address token) {
        // 1. 生成盐值
        bytes32 salt = keccak256(
            abi.encodePacked(
                "DripSwap",
                "Token",
                info.sym,
                block.chainid
            )
        );
        
        // 2. 准备字节码
        bytes memory creationCode = type(SimpleMintableERC20).creationCode;
        bytes memory bytecode = abi.encodePacked(
            creationCode,
            abi.encode(info.sym, info.sym, info.dec)
        );
        
        // 3. 计算预期地址
        address predicted = _computeCreate2Address(salt, bytecode);
        
        // 4. 检查是否已部署
        if (predicted.code.length > 0) {
            console2.log(string.concat("[OK] ", info.sym, " already deployed"));
            console2.log("  Address:", predicted);
            return predicted;
        }
        
        // 5. 部署
        console2.log(string.concat("Deploying ", info.sym, "..."));
        
        token = _deployViaERC2470(info.sym, bytecode, salt, predicted);
        
        // 6. 铸造代币
        SimpleMintableERC20(token).mint(deployer, info.mintAmt);
        
        console2.log(string.concat("[OK] ", info.sym, " deployed and minted"));
        console2.log("  Address:", token);
    }

    /// @notice 计算CREATE2地址
    function _computeCreate2Address(
        bytes32 salt,
        bytes memory bytecode
    ) internal pure returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                ERC2470,
                salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice 确保ERC-2470存在
    function _ensureERC2470() internal {
        if (ERC2470.code.length > 0) return;
        if (block.chainid == 31337) {
            vm.etch(ERC2470, ERC2470_RUNTIME);
        } else {
            revert("ERC-2470 not found");
        }
    }

    function _writeTokensConfig(
        string memory bookPath,
        TokenInfo[] memory infos,
        address[] memory tokens
    ) internal {
        console2.log("Writing tokens config...");
        
        // 使用路径方式写入每个token，避免覆盖其他配置
        for (uint i = 0; i < infos.length; i++) {
            string memory basePath = string.concat(".tokens.", infos[i].sym);
            vm.writeJson(vm.toString(tokens[i]), bookPath, string.concat(basePath, ".address"));
            vm.writeJson(vm.toString(infos[i].dec), bookPath, string.concat(basePath, ".decimals"));
            console2.log("  Added token:", infos[i].sym);
        }
        
        console2.log("Tokens config written to:", bookPath);
    }

    function _deployViaERC2470(
        string memory sym,
        bytes memory initCode,
        bytes32 salt,
        address predicted
    ) internal returns (address deployed) {
        console2.log("  init code length:", initCode.length);
        console2.logBytes32(keccak256(initCode));

        bytes memory payload = abi.encodePacked(salt, initCode);
        console2.log("  payload length:", payload.length);
        console2.logBytes32(keccak256(payload));

        (bool success, bytes memory result) = ERC2470.call(payload);
        if (!success) {
            console2.log(string.concat(sym, ": deployment call reverted"));
            if (result.length > 0) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            } else {
                revert(string.concat(sym, ": deployment failed"));
            }
        }

        console2.log("  raw result length:", result.length);
        console2.logBytes(result);

        if (result.length == 20) {
            uint256 word;
            assembly {
                word := mload(add(result, 0x20))
            }
            deployed = address(uint160(word >> 96));
        } else if (result.length == 32) {
            deployed = abi.decode(result, (address));
        } else {
            revert(string.concat(sym, ": invalid factory response"));
        }

        require(deployed == predicted, string.concat(sym, ": address mismatch"));
        console2.log("  deployed address:", deployed);
    }

    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 31337) return "deployments/local.m1.json";
        if (block.chainid == 11155111) return "deployments/sepolia.m1.json";
        if (block.chainid == 534351) return "deployments/scroll-sepolia.m1.json";
        revert("DeployTokens: unsupported chain");
    }
}
