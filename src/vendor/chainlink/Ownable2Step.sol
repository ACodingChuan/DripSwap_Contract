// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IOwnable} from "@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol";

/// @notice Minimal 2-step ownership helper used by multiple Chainlink contracts.
contract Ownable2Step is IOwnable {
  address private s_pendingOwner;
  address private s_owner;

  error OwnerCannotBeZero();
  error MustBeProposedOwner();
  error CannotTransferToSelf();
  error OnlyCallableByOwner();

  event OwnershipTransferRequested(address indexed from, address indexed to);
  event OwnershipTransferred(address indexed from, address indexed to);

  constructor(address newOwner, address pendingOwner) {
    if (newOwner == address(0)) revert OwnerCannotBeZero();
    s_owner = newOwner;
    if (pendingOwner != address(0)) {
      _transferOwnership(pendingOwner);
    }
  }

  function owner() public view override returns (address) {
    return s_owner;
  }

  function transferOwnership(address to) public override onlyOwner {
    _transferOwnership(to);
  }

  function acceptOwnership() external override {
    if (msg.sender != s_pendingOwner) revert MustBeProposedOwner();

    address oldOwner = s_owner;
    s_owner = msg.sender;
    s_pendingOwner = address(0);

    emit OwnershipTransferred(oldOwner, msg.sender);
  }

  function _transferOwnership(address to) private {
    if (to == msg.sender) revert CannotTransferToSelf();

    s_pendingOwner = to;
    emit OwnershipTransferRequested(s_owner, to);
  }

  function _validateOwnership() internal view {
    if (msg.sender != s_owner) revert OnlyCallableByOwner();
  }

  modifier onlyOwner() {
    _validateOwnership();
    _;
  }
}
