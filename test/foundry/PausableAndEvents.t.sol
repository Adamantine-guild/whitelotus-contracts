// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GrantRound} from "../../contracts/GrantRound.sol";

/// @dev Covers issue #1 (emergency pause on deposit()) and issue #5
/// (event emitted when admin withdraws unspent funds).
contract PausableAndEventsTest is Test {
    GrantRound internal round;
    address internal admin = address(0xA11CE);
    address internal grantee = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event FundsClawedBack(address indexed to, uint256 amount);

    function setUp() public {
        vm.deal(admin, 100 ether);
        vm.deal(stranger, 1 ether);

        vm.prank(admin);
        round = new GrantRound("Round 1", "ipfs://round1", 10 ether, admin, address(1));
    }

    function testDepositRevertsWhenPaused() public {
        vm.prank(admin);
        round.pause();
        assertTrue(round.paused());

        vm.prank(admin);
        vm.expectRevert(GrantRound.ContractPaused.selector);
        round.deposit{value: 1 ether}();
    }

    function testDepositSucceedsAfterUnpause() public {
        vm.prank(admin);
        round.pause();

        vm.prank(admin);
        round.unpause();
        assertFalse(round.paused());

        vm.prank(admin);
        round.deposit{value: 1 ether}();
        assertEq(address(round).balance, 1 ether);
    }

    function testOnlyAdminCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(GrantRound.NotAdmin.selector);
        round.pause();
    }

    function testPauseEmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(round));
        emit Paused(admin);
        vm.prank(admin);
        round.pause();
    }

    function testUnpauseEmitsEvent() public {
        vm.prank(admin);
        round.pause();

        vm.expectEmit(true, false, false, true, address(round));
        emit Unpaused(admin);
        vm.prank(admin);
        round.unpause();
    }

    function testCannotPauseTwice() public {
        vm.prank(admin);
        round.pause();

        vm.prank(admin);
        vm.expectRevert(GrantRound.AlreadyPaused.selector);
        round.pause();
    }

    function testClawbackEmitsFundsClawedBackEvent() public {
        vm.prank(admin);
        round.deposit{value: 2 ether}();

        vm.expectEmit(true, false, false, true, address(round));
        emit FundsClawedBack(admin, 2 ether);
        vm.prank(admin);
        round.clawbackUnspentFunds(admin);
    }
}
