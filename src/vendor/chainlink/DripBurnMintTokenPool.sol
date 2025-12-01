// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {IBurnMintERC20} from "@chainlink/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";

import {BurnMintTokenPoolAbstract} from "@chainlink/contracts-ccip/pools/BurnMintTokenPoolAbstract.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";

/// @notice Customized Burn/Mint pool that wraps the Chainlink implementation but
/// ensures the base TokenPool receives a standard IERC20 instance.
contract DripBurnMintTokenPool is BurnMintTokenPoolAbstract, ITypeAndVersion {
  string public constant override typeAndVersion = "DripBurnMintTokenPool 1.0.0";

  constructor(
    IBurnMintERC20 token,
    uint8 localTokenDecimals,
    address[] memory allowlist,
    address rmnProxy,
    address router
  ) TokenPool(IERC20(address(token)), localTokenDecimals, allowlist, rmnProxy, router) {}

  /// @inheritdoc TokenPool
  function _lockOrBurn(uint256 amount) internal virtual override {
    IBurnMintERC20(address(i_token)).burn(amount);
  }
}
