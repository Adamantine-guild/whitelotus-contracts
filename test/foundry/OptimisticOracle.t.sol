// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {OptimisticOracle} from "../../contracts/oracle/OptimisticOracle.sol";

contract OptimisticOracleTest is Test {
    MockERC20 internal bondToken;
    OptimisticOracle internal oracle;

    address internal arbitrator = address(0x1111);
    address internal proposer = address(0x2222);
    address internal disputer = address(0x3333);
    address internal asset = address(0x4444);

    uint256 internal bondAmount = 100 * 10 ** 18;
    uint256 internal challengeWindow = 2 hours;

    function setUp() public {
        bondToken = new MockERC20("Oracle Bond Token", "OBT", 18);
        oracle = new OptimisticOracle(bondToken, bondAmount, challengeWindow, arbitrator);

        // Fund proposer and disputer
        bondToken.mint(proposer, 1000 * 10 ** 18);
        bondToken.mint(disputer, 1000 * 10 ** 18);

        vm.prank(proposer);
        bondToken.approve(address(oracle), type(uint256).max);

        vm.prank(disputer);
        bondToken.approve(address(oracle), type(uint256).max);
    }

    function testProposeAndSettleUndisputed() public {
        uint256 targetPrice = 500;

        uint256 balanceBefore = bondToken.balanceOf(proposer);

        vm.prank(proposer);
        uint256 proposalId = oracle.proposePrice(asset, targetPrice);

        assertEq(bondToken.balanceOf(proposer), balanceBefore - bondAmount);

        // Warp time past challenge window
        skip(challengeWindow + 1);

        oracle.settle(proposalId);

        // Stored price check
        assertEq(oracle.prices(asset), targetPrice);
        assertEq(oracle.priceTimestamps(asset), block.timestamp - (challengeWindow + 1));

        // Proposer got bond back
        assertEq(bondToken.balanceOf(proposer), balanceBefore);
    }

    function testProposeDisputeAndProposerWins() public {
        uint256 targetPrice = 500;

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);
        uint256 disputerBalanceBefore = bondToken.balanceOf(disputer);

        // Propose
        vm.prank(proposer);
        uint256 proposalId = oracle.proposePrice(asset, targetPrice);

        // Dispute
        vm.prank(disputer);
        oracle.disputePrice(asset, proposalId);

        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore - bondAmount);
        assertEq(bondToken.balanceOf(disputer), disputerBalanceBefore - bondAmount);

        // Arbitrate in favor of proposer
        vm.prank(arbitrator);
        oracle.resolveDispute(proposalId, true);

        // Proposer gets their bond back + disputer's bond (2x bond)
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore + bondAmount);
        // Disputer loses their bond
        assertEq(bondToken.balanceOf(disputer), disputerBalanceBefore - bondAmount);

        // Price is updated
        assertEq(oracle.prices(asset), targetPrice);
    }

    function testProposeDisputeAndDisputerWins() public {
        uint256 targetPrice = 500;

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);
        uint256 disputerBalanceBefore = bondToken.balanceOf(disputer);

        // Propose
        vm.prank(proposer);
        uint256 proposalId = oracle.proposePrice(asset, targetPrice);

        // Dispute
        vm.prank(disputer);
        oracle.disputePrice(asset, proposalId);

        // Arbitrate in favor of disputer
        vm.prank(arbitrator);
        oracle.resolveDispute(proposalId, false);

        // Disputer gets their bond back + proposer's bond (2x bond)
        assertEq(bondToken.balanceOf(disputer), disputerBalanceBefore + bondAmount);
        // Proposer loses their bond
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore - bondAmount);

        // Price is NOT updated
        assertEq(oracle.prices(asset), 0);
    }

    function testRevertDisputeAfterWindow() public {
        vm.prank(proposer);
        uint256 proposalId = oracle.proposePrice(asset, 500);

        // Warp time past challenge window
        skip(challengeWindow + 1);

        vm.prank(disputer);
        vm.expectRevert("OptimisticOracle: Challenge window passed");
        oracle.disputePrice(asset, proposalId);
    }

    function testRevertOnlyArbitratorResolveDispute() public {
        vm.prank(proposer);
        uint256 proposalId = oracle.proposePrice(asset, 500);

        vm.prank(disputer);
        oracle.disputePrice(asset, proposalId);

        // Standard user attempts to resolve
        vm.prank(proposer);
        vm.expectRevert("OptimisticOracle: Only arbitrator can resolve");
        oracle.resolveDispute(proposalId, true);
    }

    function testOverlappingProposals() public {
        // Proposal A at t = 0
        vm.prank(proposer);
        uint256 proposalIdA = oracle.proposePrice(asset, 500);

        // Warp time to t = 1 hour (simultaneous/overlapping period)
        skip(1 hours);

        // Proposal B at t = 1 hour
        vm.prank(proposer);
        uint256 proposalIdB = oracle.proposePrice(asset, 600);

        // Warp past proposal B challenge window (B's window closes at t = 3 hours)
        skip(2 hours + 1); // current time = 3 hours + 1 second

        // Settle proposal B first (B's price = 600 should become truth)
        oracle.settle(proposalIdB);
        assertEq(oracle.prices(asset), 600);

        // Now settle proposal A (A's price = 500 was proposed earlier at t = 0)
        oracle.settle(proposalIdA);

        // Crucial Check: Proposal A's price must NOT overwrite Proposal B's price
        // because A is older than the current truth timestamp.
        assertEq(oracle.prices(asset), 600);
    }
}
