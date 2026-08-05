// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GrantRound} from "../../contracts/GrantRound.sol";

contract GrantRoundTest is Test {
    GrantRound internal round;
    address internal admin = address(0xA11CE);
    address internal grantee = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        vm.deal(admin, 100 ether);
        vm.deal(grantee, 1 ether);
        vm.deal(stranger, 1 ether);

        vm.prank(admin);
        round = new GrantRound("Round 1", "ipfs://round1", 10 ether, admin, address(1));

        vm.prank(admin);
        round.deposit{value: 5 ether}();
    }

    function testSubmitAndApproveApplication() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        (address applicant,, GrantRound.AppStatus status) = round.applications(appId);
        assertEq(applicant, grantee);
        assertEq(uint256(status), uint256(GrantRound.AppStatus.Pending));

        vm.prank(admin);
        round.approveApplication(appId);

        (,, status) = round.applications(appId);
        assertEq(uint256(status), uint256(GrantRound.AppStatus.Approved));
    }

    function testRejectApplication() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        vm.prank(admin);
        round.rejectApplication(appId);

        (,, GrantRound.AppStatus status) = round.applications(appId);
        assertEq(uint256(status), uint256(GrantRound.AppStatus.Rejected));
    }

    function testCreateMilestonesAndSubmitEvidence() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        vm.prank(admin);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vm.prank(admin);
        round.createMilestones(appId, amounts);

        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://evidence0");

        GrantRound.Milestone[] memory milestones = round.getMilestones(appId);
        assertEq(milestones.length, 2);
        assertTrue(milestones[0].submitted);
        assertEq(milestones[0].amount, 1 ether);
        assertEq(milestones[1].amount, 2 ether);
    }

    function testApproveAndReleasePayout() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        vm.prank(admin);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(admin);
        round.createMilestones(appId, amounts);

        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://evidence0");

        vm.prank(admin);
        round.approveMilestone(appId, 0);

        uint256 balanceBefore = grantee.balance;

        vm.prank(admin);
        round.releasePayout(appId, 0);

        assertEq(grantee.balance, balanceBefore + 1 ether);
    }

    function testOnlyAdminCanApproveAndRelease() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        vm.prank(admin);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(admin);
        round.createMilestones(appId, amounts);

        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://evidence0");

        vm.prank(stranger);
        vm.expectRevert(GrantRound.NotAdmin.selector);
        round.approveMilestone(appId, 0);

        vm.prank(admin);
        round.approveMilestone(appId, 0);

        vm.prank(stranger);
        vm.expectRevert(GrantRound.NotAdmin.selector);
        round.releasePayout(appId, 0);
    }

    function testReceiveAcceptsFundingWhenActive() public {
        vm.deal(stranger, 10 ether);
        uint256 balanceBefore = address(round).balance;

        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit GrantRound.DepositReceived(stranger, 2 ether);
        (bool ok,) = payable(address(round)).call{value: 2 ether}("");
        assertTrue(ok, "transfer must succeed while unpaused");

        assertEq(address(round).balance, balanceBefore + 2 ether);
    }

    function testReceiveRejectsFundingWhenPaused() public {
        vm.prank(admin);
        round.pause();

        // Plain native token transfer must revert while paused — the documented
        // "fund-in operations revert" guarantee (#1) now covers receive() too.
        vm.prank(stranger);
        vm.expectRevert(GrantRound.ContractPaused.selector);
        payable(address(round)).call{value: 1 ether}("");

        // Balance unchanged — no funds absorbed during pause.
        assertEq(address(round).balance, 5 ether);
    }

    function testReceiveRespectsPauseForEveryoneIncludingAdmin() public {
        vm.prank(admin);
        round.pause();

        // Even the admin's plain transfer is rejected while paused (deposit()
        // already enforced this; receive() now matches).
        vm.prank(admin);
        vm.expectRevert(GrantRound.ContractPaused.selector);
        payable(address(round)).call{value: 1 ether}("");
    }

    function testClawbackUnspentFunds() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://app1");

        vm.prank(admin);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(admin);
        round.createMilestones(appId, amounts);

        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://evidence0");

        vm.prank(admin);
        round.approveMilestone(appId, 0);

        vm.prank(admin);
        round.releasePayout(appId, 0);

        uint256 adminBalanceBefore = admin.balance;

        vm.prank(admin);
        round.clawbackUnspentFunds(admin);

        assertEq(address(round).balance, 0);
        assertEq(admin.balance, adminBalanceBefore + 4 ether);
    }
}
