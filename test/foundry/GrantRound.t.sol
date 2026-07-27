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
        vm.expectRevert("Not admin");
        round.approveMilestone(appId, 0);

        vm.prank(admin);
        round.approveMilestone(appId, 0);

        vm.prank(stranger);
        vm.expectRevert("Not admin");
        round.releasePayout(appId, 0);
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
