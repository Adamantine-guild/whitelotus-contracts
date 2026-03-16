// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GrantRoundFactory.sol";
import "../src/GrantRound.sol";

contract IntegrationTest is Test {
    GrantRoundFactory factory;
    GrantRound round;
    address admin = address(0xA11CE);
    address grantee = address(0xBEEF);

    function setUp() public {
        vm.deal(admin, 100 ether);
        vm.deal(grantee, 1 ether);
        factory = new GrantRoundFactory();
        vm.prank(admin);
        address r = factory.createRound("Round X", "ipfs://roundX", 10 ether, admin);
        round = GrantRound(payable(r));
        vm.prank(admin);
        round.deposit{value: 3 ether}();
    }

    function testLifecycleEndToEnd() public {
        // applicant submits
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://prop");
        // admin approves app
        vm.prank(admin);
        round.approveApplication(appId);
        // admin defines milestones [1,2] ether
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        vm.prank(admin);
        round.createMilestones(appId, amounts);
        // grantee submits evidence for m0
        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://e0");
        // admin approves m0 and releases payout
        vm.prank(admin);
        round.approveMilestone(appId, 0);
        uint256 before = grantee.balance;
        vm.prank(admin);
        round.releasePayout(appId, 0);
        assertEq(grantee.balance, before + 1 ether);
    }
}

