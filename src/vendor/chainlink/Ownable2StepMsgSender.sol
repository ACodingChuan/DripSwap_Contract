// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Ownable2Step} from "./Ownable2Step.sol";

/// @notice Convenience wrapper that sets msg.sender as owner without pending owner.
contract Ownable2StepMsgSender is Ownable2Step {
  constructor() Ownable2Step(msg.sender, address(0)) {}
}
