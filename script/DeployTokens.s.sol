// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdJson.sol";

// 一个最小可用的可铸造 ERC20（仅用于测试/演示）
interface IMintableERC20 {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function mint(address to, uint256 amount) external;
}

/// @dev 如果你仓库已有 vToken 实现，可替换为你的合约；这里用最简实现占位
contract SimpleMintableERC20 {
    string public name;
    string public symbol;
    uint8  public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address=>uint256)) public allowance;

    constructor(string memory _n, string memory _s, uint8 _d) {
        name = _n; symbol = _s; decimals = _d;
    }
    function approve(address s, uint256 a) external returns(bool){ allowance[msg.sender][s]=a; return true; }
    function transfer(address to, uint256 a) external returns(bool){ _move(msg.sender,to,a); return true; }
    function transferFrom(address f,address t,uint256 a) external returns(bool){
        uint256 al=allowance[f][msg.sender]; require(al>=a,"allow"); if(al!=type(uint256).max) allowance[f][msg.sender]=al-a; _move(f,t,a); return true;
    }
    function mint(address to, uint256 a) external { totalSupply+=a; balanceOf[to]+=a; }
    function _move(address f,address t,uint256 a) internal { require(balanceOf[f]>=a,"bal"); balanceOf[f]-=a; balanceOf[t]+=a; }
}

contract DeployTokens is Script {
    using stdJson for string;

    string internal constant BOOK = "deployments/local.m1.json";

    struct Tok { string sym; uint8 dec; uint256 mintAmt; }

    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));

        // 1) 定义六个 vToken 的元数据（decimals）
        Tok[6] memory info = [
            Tok("vETH",  18, 1_000_000 ether),
            Tok("vUSDT",  6, 1_000_000 * 1e6),
            Tok("vUSDC",  6, 1_000_000 * 1e6),
            Tok("vDAI",  18, 1_000_000 ether),
            Tok("vBTC",   8, 1_000_000 * 1e8),
            Tok("vLINK", 18, 1_000_000 ether)
        ];

        address deployer = vm.addr(vm.envUint("DEPLOYER_PK"));
        string memory root = vm.readFile(BOOK);

        for (uint i=0; i<info.length; i++) {
            string memory sym = info[i].sym;
            uint8  dec  = info[i].dec;
            // CREATE2 可选：这里直接 new，若要确定性可像前一脚本用 DeterministicDeployer
            SimpleMintableERC20 tok = new SimpleMintableERC20(sym, sym, dec);
            tok.mint(deployer, info[i].mintAmt);

            // 写 tokens{} 节点
            string memory node = string.concat("tokens.", sym);
            root = root.serialize(string.concat(node, ".address"), address(tok));
            root = root.serialize(string.concat(node, ".decimals"), dec);

            console2.log("Deployed", sym, address(tok));
        }

        vm.writeJson(root, BOOK);
        console2.log("AddressBook updated:", BOOK);

        vm.stopBroadcast();
    }
}
