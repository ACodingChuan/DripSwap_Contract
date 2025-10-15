// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VToken} from "src/tokens/Vtoken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VTokenTest is Test {
    VToken private token;

    address private constant OWNER = address(uint160(uint256(keccak256("owner"))));
    address private constant ALICE = address(uint160(uint256(keccak256("alice"))));
    address private constant BOB = address(uint160(uint256(keccak256("bob"))));
    address private constant CAROL = address(uint160(uint256(keccak256("carol"))));

    function setUp() public {
        token = new VToken("Virtual USDT", "vUSDT", 6, OWNER);
    }

    function testConstructorSetsMetadataOwnerAndDecimals() view public {
        assertEq(token.name(), "Virtual USDT");
        assertEq(token.symbol(), "vUSDT");
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), OWNER);
        assertEq(token.totalSupply(), 0);
    }

    function testDecimalsReturnsImmutableValue() public {
        assertEq(token.decimals(), 6);
        vm.prank(OWNER);
        token.mint(ALICE, 1_000_000);
        assertEq(token.decimals(), 6, "minting must not alter decimals");
    }

    function testMintByOwnerAccumulatesSupplyPerRecipient() public {
        vm.startPrank(OWNER);
        token.mint(ALICE, 2_500_000);
        token.mint(BOB, 7_500_000);
        vm.stopPrank();

        assertEq(token.balanceOf(ALICE), 2_500_000);
        assertEq(token.balanceOf(BOB), 7_500_000);
        assertEq(token.totalSupply(), 10_000_000);
    }

    function testMintRevertsWhenToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(OWNER);
        token.mint(address(0), 1);
    }

    function testMintRevertsForNonOwner(address caller) public {
        vm.assume(caller != OWNER);
        vm.assume(caller != address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        token.mint(ALICE, 1);
    }

    function testTransferOwnershipUpdatesRolesAndPermissions() public {
        vm.prank(OWNER);
        token.transferOwnership(CAROL);
        assertEq(token.owner(), CAROL);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vm.prank(OWNER);
        token.mint(ALICE, 1);

        vm.prank(CAROL);
        token.mint(ALICE, 5);
        assertEq(token.balanceOf(ALICE), 5);
    }
}
