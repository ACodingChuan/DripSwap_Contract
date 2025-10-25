// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VToken} from "src/tokens/Vtoken.sol";
import {IVToken} from "src/interfaces/IVToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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

    function testConstructorSetsMetadataOwnerAndDecimals() public {
        assertEq(token.name(), "Virtual USDT");
        assertEq(token.symbol(), "vUSDT");
        assertEq(token.decimals(), 6);
        assertEq(token.owner(), OWNER);
        assertEq(token.totalSupply(), 0);

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), OWNER));
        assertTrue(token.hasRole(token.MINTER_ROLE(), OWNER));
        assertTrue(token.hasRole(token.BURNER_ROLE(), OWNER));
    }

    function testMintRequiresMinterRole(address caller) public {
        vm.assume(caller != OWNER);
        vm.assume(caller != address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                caller,
                token.MINTER_ROLE()
            )
        );
        vm.prank(caller);
        token.mint(ALICE, 1);
    }

    function testMintByMinterAccumulatesSupplyPerRecipient() public {
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

    function testBurnReducesCallerBalance() public {
        vm.prank(OWNER);
        token.mint(ALICE, 1_000_000);

        vm.prank(ALICE);
        token.burn(400_000);

        assertEq(token.balanceOf(ALICE), 600_000);
        assertEq(token.totalSupply(), 600_000);
    }

    function testBridgeBurnRequiresRole() public {
        vm.prank(OWNER);
        token.mint(ALICE, 1_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                BOB,
                token.BURNER_ROLE()
            )
        );
        vm.prank(BOB);
        token.bridgeBurn(ALICE, 500_000);
    }

    function testBridgeBurnByAuthorizedRole() public {
        vm.startPrank(OWNER);
        token.mint(ALICE, 1_000_000);
        token.grantRole(token.BURNER_ROLE(), CAROL);
        vm.stopPrank();

        vm.prank(CAROL);
        token.bridgeBurn(ALICE, 750_000);

        assertEq(token.balanceOf(ALICE), 250_000);
        assertEq(token.totalSupply(), 250_000);
    }

    function testGetCCIPAdminMatchesOwner() public {
        assertEq(token.getCCIPAdmin(), OWNER);

        vm.prank(OWNER);
        token.transferOwnership(CAROL);
        assertEq(token.getCCIPAdmin(), CAROL);
    }

    function testSupportsInterfaceCoversIVToken() public {
        bytes4 interfaceId = type(IVToken).interfaceId;
        assertTrue(token.supportsInterface(interfaceId));
    }

    function testTransferOwnershipMovesDefaultAdminRole() public {
        vm.prank(OWNER);
        token.transferOwnership(CAROL);
        assertEq(token.owner(), CAROL);

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), CAROL));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), OWNER));

        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                OWNER,
                adminRole
            )
        );
        vm.prank(OWNER);
        token.grantRole(minterRole, OWNER);

        vm.prank(CAROL);
        token.grantRole(minterRole, CAROL);

        vm.prank(CAROL);
        token.mint(ALICE, 5);
        assertEq(token.balanceOf(ALICE), 5);
    }
}
