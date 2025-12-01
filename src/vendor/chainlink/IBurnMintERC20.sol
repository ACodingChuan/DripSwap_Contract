// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";

interface IBurnMintERC20 is IERC20 {
  function mint(address account, uint256 amount) external;

  function burn(uint256 amount) external;

  function burn(address account, uint256 amount) external;

  function burnFrom(address account, uint256 amount) external;
}
