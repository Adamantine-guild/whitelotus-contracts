// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GrantRoundFactory} from "../../contracts/GrantRoundFactory.sol";
import {GrantRound} from "../../contracts/GrantRound.sol";

contract IntegrationTest is Test {
    GrantRoundFactory internal factory;
    GrantRound internal round;
    address internal admin = address(0xA11CE);
    address internal grantee = address(0xBEEF);

    function setUp() public {
        vm.deal(admin, 100 ether);
        vm.deal(grantee, 1 ether);

        factory = new GrantRoundFactory(address(1));

        vm.prank(admin);
        address roundAddress = factory.createRound("Round X", "ipfs://roundX", 10 ether, admin);
        round = GrantRound(payable(roundAddress));

        vm.prank(admin);
        round.deposit{value: 3 ether}();
    }

    function testLifecycleEndToEnd() public {
        vm.prank(grantee);
        uint256 appId = round.submitApplication("ipfs://prop");

        vm.prank(admin);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vm.prank(admin);
        round.createMilestones(appId, amounts);

        vm.prank(grantee);
        round.submitMilestoneEvidence(appId, 0, "ipfs://e0");

        vm.prank(admin);
        round.approveMilestone(appId, 0);

        uint256 balanceBefore = grantee.balance;

        vm.prank(admin);
        round.releasePayout(appId, 0);

        assertEq(grantee.balance, balanceBefore + 1 ether);
    }

    function testFactoryCreatesRoundWithFunding() public {
        vm.deal(admin, 10 ether);

        vm.prank(admin);
        address roundAddress =
            factory.createRound{value: 2 ether}("Funded Round", "ipfs://funded", 5 ether, admin);

        assertEq(roundAddress.balance, 2 ether);
        assertEq(factory.roundsCount(), 2);
    }
}
