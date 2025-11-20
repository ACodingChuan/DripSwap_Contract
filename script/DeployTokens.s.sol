// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployBase} from "script/lib/DeployBase.s.sol";
import {console2} from "forge-std/console2.sol";
import {VToken} from "src/tokens/Vtoken.sol";

/// @title DeployTokens
/// @notice 通过 ERC-2470 + ERC1167 部署 VToken 克隆，并完成初始化与首笔铸造
contract DeployTokens is DeployBase {
    struct TokenInfo {
        string name;
        string symbol;
        uint8 decimals;
        uint256 mintAmount;
    }

    function run() external {
        console2.log("=== DeployTokens (ERC1167 clones) ===");
        console2.log("Chain ID:", block.chainid);

        _ensureERC2470();

        address logic = _bookGetAddress("logic.vtoken");
        require(logic != address(0), "VToken logic missing, run make deploy-logic");

        TokenInfo[] memory list = _tokenList();
        console2.log("Tokens to deploy:", list.length);

        vm.startBroadcast();
        address deployer = msg.sender;

        for (uint256 i = 0; i < list.length; ++i) {
            _deployOne(list[i], logic, deployer);
        }

        vm.stopBroadcast();
        console2.log("[DONE] DeployTokens completed");
    }

    function _deployOne(TokenInfo memory info, address logic, address deployer) internal {
        bytes32 salt = keccak256(abi.encodePacked("DripSwap::VToken", info.symbol));
        (address proxy, bool fresh) = _deployMinimalProxy(logic, salt);

        if (fresh) {
            console2.log(string.concat("[NEW] ", info.symbol, " deployed at ", vm.toString(proxy)));
            VToken token = VToken(proxy);
            token.initialize(info.name, info.symbol, info.decimals, deployer);
            token.setBridgeRole(deployer);
            if (info.mintAmount > 0) {
                token.mint(deployer, info.mintAmount);
                console2.log(string.concat("  minted ", vm.toString(info.mintAmount), " to ", vm.toString(deployer)));
            }

            string memory mdPath = _deploymentFile("tokens.md");
            vm.writeLine(mdPath, "");
            vm.writeLine(mdPath, "[token]");
            vm.writeLine(mdPath, string.concat("  symbol: ", info.symbol));
            vm.writeLine(mdPath, string.concat("  address: ", vm.toString(proxy)));
            vm.writeLine(mdPath, string.concat("  decimals: ", vm.toString(uint256(info.decimals))));
            vm.writeLine(mdPath, string.concat("  owner: ", vm.toString(deployer)));
            if (info.mintAmount > 0) {
                vm.writeLine(mdPath, string.concat("  initial_mint: ", vm.toString(info.mintAmount)));
            }
        } else {
            console2.log(string.concat("[SKIP] ", info.symbol, " already deployed at ", vm.toString(proxy)));
        }

        _bookSetAddress(string.concat("tokens.", info.symbol, ".address"), proxy);
        _bookSetUint(string.concat("tokens.", info.symbol, ".decimals"), info.decimals);
    }

    function _tokenList() internal pure returns (TokenInfo[] memory tokens) {
        tokens = new TokenInfo[](7);
        tokens[0] = TokenInfo("Virtual Ether", "vETH", 18, 10_000 ether);
        tokens[1] = TokenInfo("Virtual Tether", "vUSDT", 6, 1_000_000 * 1e6);
        tokens[2] = TokenInfo("Virtual USD Coin", "vUSDC", 6, 1_000_000 * 1e6);
        tokens[3] = TokenInfo("Virtual DAI", "vDAI", 18, 1_000_000 ether);
        tokens[4] = TokenInfo("Virtual Bitcoin", "vBTC", 8, 10_000 * 1e8);
        tokens[5] = TokenInfo("Virtual Chainlink", "vLINK", 18, 1_000_000 ether);
        tokens[6] = TokenInfo("Virtual Scroll", "vSCR", 18, 2_000_000 ether);
    }
}
