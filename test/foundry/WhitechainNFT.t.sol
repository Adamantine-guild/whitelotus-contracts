// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WhitechainNFT} from "../../contracts/WhitechainNFT.sol";
import {
    IERC721Enumerable
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

contract WhitechainNFTTest is Test {
    WhitechainNFT internal nft;

    address internal owner = address(0x1111);
    address internal user1 = address(0x2222);
    address internal user2 = address(0x3333);

    function setUp() public {
        nft = new WhitechainNFT("Whitechain NFT", "WCNFT", owner);
    }

    function testInitialization() public {
        assertEq(nft.name(), "Whitechain NFT");
        assertEq(nft.symbol(), "WCNFT");
        assertEq(nft.owner(), owner);
        assertEq(nft.totalSupply(), 0);
    }

    function testMintAndEnumeration() public {
        vm.startPrank(owner);
        uint256 id0 = nft.mint(user1);
        uint256 id1 = nft.mint(user1);
        uint256 id2 = nft.mint(user2);
        vm.stopPrank();

        // Check totalSupply
        assertEq(nft.totalSupply(), 3);

        // Check user1 balance and token indices
        assertEq(nft.balanceOf(user1), 2);
        assertEq(nft.tokenOfOwnerByIndex(user1, 0), id0);
        assertEq(nft.tokenOfOwnerByIndex(user1, 1), id1);

        // Check user2 balance and token indices
        assertEq(nft.balanceOf(user2), 1);
        assertEq(nft.tokenOfOwnerByIndex(user2, 0), id2);

        // Check global token indices
        assertEq(nft.tokenByIndex(0), id0);
        assertEq(nft.tokenByIndex(1), id1);
        assertEq(nft.tokenByIndex(2), id2);
    }

    function testTransferUpdatesEnumeration() public {
        vm.prank(owner);
        uint256 id0 = nft.mint(user1);

        vm.prank(owner);
        uint256 id1 = nft.mint(user1);

        // Transfer id0 from user1 to user2
        vm.prank(user1);
        nft.safeTransferFrom(user1, user2, id0);

        // user1 should only have id1 now
        assertEq(nft.balanceOf(user1), 1);
        assertEq(nft.tokenOfOwnerByIndex(user1, 0), id1);

        // user2 should have id0
        assertEq(nft.balanceOf(user2), 1);
        assertEq(nft.tokenOfOwnerByIndex(user2, 0), id0);
    }

    function testBurnUpdatesEnumeration() public {
        vm.prank(owner);
        uint256 id0 = nft.mint(user1);

        vm.prank(owner);
        uint256 id1 = nft.mint(user1);

        // Burn id0
        nft.burn(id0);

        // totalSupply should decrease to 1
        assertEq(nft.totalSupply(), 1);

        // user1 should only have id1 at index 0
        assertEq(nft.balanceOf(user1), 1);
        assertEq(nft.tokenOfOwnerByIndex(user1, 0), id1);

        // Global list should only have id1
        assertEq(nft.tokenByIndex(0), id1);
    }

    function testRevertOutOfBoundsIndex() public {
        vm.prank(owner);
        nft.mint(user1);

        // Index out of bounds for owner
        vm.expectRevert();
        nft.tokenOfOwnerByIndex(user1, 1);

        // Index out of bounds globally
        vm.expectRevert();
        nft.tokenByIndex(1);
    }

    function testSupportsInterface() public view {
        assertTrue(nft.supportsInterface(type(IERC721Enumerable).interfaceId));
    }
}
