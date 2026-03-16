// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GrantRound.sol";

contract GrantRoundTest is Test {
    GrantRound round;
    address admin = address(0xA11CE);
    address grantee = address(0xBEEF);
    address stranger = address(0xCAFE);

    function setUp() public {
        vm.deal(admin, 100 ether);
        vm.deal(grantee, 1 ether);
        vm.deal(stranger, 1 ether);
        vm.prank(admin);
        round = new GrantRound("Round 1", "ipfs://round1", 10 ether, admin);
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
        (, , status) = round.applications(appId);
        assertEq(uint256(status), uint256(GrantRound.AppStatus.Approved));
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

        // submit evidence for milestone 0
        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://evidence0");

        GrantRound.Milestone[] memory ms = round.getMilestones(appId);
        assertEq(ms.length, 2);
        assertTrue(ms[0].submitted);
        assertEq(ms[0].amount, 1 ether);
        assertEq(ms[1].amount, 2 ether);
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

        uint256 balBefore = grantee.balance;
        vm.prank(admin);
        round.releasePayout(appId, 0);
        assertEq(grantee.balance, balBefore + 1 ether);
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
}

