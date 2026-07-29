// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinimalForwarder} from "../../contracts/MinimalForwarder.sol";
import {Governance} from "../../contracts/Governance.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

// ─── Minimal ERC-20 token for voting-power tests ─────────────────────────────

contract GovernanceTimelockMockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ─── Main test contract ───────────────────────────────────────────────────────

/// @title GovernanceTimelockTest
/// @notice Tests for the Governance admin timelock integration.
///
/// Coverage:
///   1.  updateAdmin – admin can transfer admin role
///   2.  updateAdmin – non-admin cannot transfer admin role
///   3.  updateAdmin – reverts on zero address
///   4.  updateAdmin – reverts on same address
///   5.  updateAdmin – emits AdminUpdated event
///   6.  Timelock flow – schedule → wait → execute → proposal created
///   7.  Timelock flow – non-admin cannot createProposal after admin is timelock
///   8.  Timelock flow – direct createProposal from original admin reverts after transfer
///   9.  Timelock flow – schedule with insufficient delay reverts
///  10.  Timelock flow – execute before delay expires reverts
///  11.  Timelock flow – cancel a scheduled operation
///  12.  Timelock flow – minDelay is at least 48 hours
///  13.  Timelock flow – cannot re-execute an already executed operation
///  14.  Timelock flow – admin can schedule multiple proposals
contract GovernanceTimelockTest is Test {
    // ─── Constants ──────────────────────────────────────────────────────────

    /// @dev 48 hours in seconds – the minimum delay required by acceptance criteria.
    uint256 internal constant MIN_DELAY = 48 hours;

    /// @dev Proposal parameters used across tests.
    string internal constant PROPOSAL_DESC = "Timelocked Proposal";
    uint256 internal constant COMMIT_DURATION = 1 days;
    uint256 internal constant REVEAL_DURATION = 1 days;

    // ─── Actors ─────────────────────────────────────────────────────────────

    address internal admin = address(0xA);
    address internal voter = address(0xB);
    address internal stranger = address(0xC);

    // ─── Contracts ──────────────────────────────────────────────────────────

    GovernanceTimelockMockERC20 internal token;
    MinimalForwarder internal forwarder;
    Governance internal gov;
    TimelockController internal timelock;

    // ─── Setup ──────────────────────────────────────────────────────────────

    function setUp() public {
        vm.label(admin, "admin");
        vm.label(voter, "voter");
        vm.label(stranger, "stranger");

        // Deploy token and mint voting power to voter.
        token = new GovernanceTimelockMockERC20();
        token.mint(voter, 100 ether);

        // Deploy a MinimalForwarder (required by ERC2771Context – cannot be zero).
        forwarder = new MinimalForwarder();

        // Deploy Governance with admin = this test contract's admin address.
        vm.prank(admin);
        gov = new Governance(address(token), address(forwarder));

        // Deploy TimelockController with 48-hour minDelay.
        // admin is the sole proposer and executor.
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        vm.prank(admin);
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));
        vm.label(address(timelock), "timelock");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @dev Build the calldata for Governance.createProposal().
    function _createProposalCalldata()
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            Governance.createProposal.selector, PROPOSAL_DESC, COMMIT_DURATION, REVEAL_DURATION
        );
    }

    /// @dev Schedule a createProposal call through the timelock and return the operation ID.
    function _scheduleCreateProposal() internal returns (bytes32) {
        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");
        vm.prank(admin);
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, MIN_DELAY);
        return timelock.hashOperation(address(gov), 0, data, bytes32(0), salt);
    }

    /// @dev Execute a scheduled createProposal call and return the proposal ID.
    function _executeCreateProposal(bytes32 opId) internal returns (uint256) {
        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");
        uint256 countBefore = gov.proposalCount();

        vm.prank(admin);
        timelock.execute(address(gov), 0, data, bytes32(0), salt);

        uint256 proposalId = gov.proposalCount();
        assertEq(proposalId, countBefore + 1, "proposal should be created");
        return proposalId;
    }

    // ─── 1. updateAdmin – admin can transfer admin role ───────────────────────

    function testUpdateAdminSucceeds() public {
        address newAdmin = address(0xDA);
        vm.prank(admin);
        gov.updateAdmin(newAdmin);
        assertEq(gov.admin(), newAdmin);
    }

    // ─── 2. updateAdmin – non-admin cannot transfer ───────────────────────────

    function testUpdateAdminRevertsNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert("Not admin");
        gov.updateAdmin(address(0xDA));
    }

    // ─── 3. updateAdmin – reverts on zero address ─────────────────────────────

    function testUpdateAdminRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("Zero admin");
        gov.updateAdmin(address(0));
    }

    // ─── 4. updateAdmin – reverts on same address ─────────────────────────────

    function testUpdateAdminRevertsSameAddress() public {
        vm.prank(admin);
        vm.expectRevert("Same admin");
        gov.updateAdmin(admin);
    }

    // ─── 5. updateAdmin – emits AdminUpdated event ────────────────────────────

    function testUpdateAdminEmitsEvent() public {
        address newAdmin = address(0xDA);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit Governance.AdminUpdated(admin, newAdmin);
        gov.updateAdmin(newAdmin);
    }

    // ─── 6. Timelock flow – schedule → wait → execute → proposal created ──────

    function testTimelockFullFlow() public {
        // Step 1: Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));
        assertEq(gov.admin(), address(timelock));

        // Step 2: Admin schedules a proposal through the timelock.
        bytes32 opId = _scheduleCreateProposal();

        // Step 3: Verify operation is Waiting (not yet ready).
        assertTrue(timelock.isOperationPending(opId));
        assertFalse(timelock.isOperationReady(opId));

        // Step 4: Warp past the delay period.
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Step 5: Operation is now ready.
        assertTrue(timelock.isOperationReady(opId));

        // Step 6: Execute the scheduled call.
        uint256 proposalId = _executeCreateProposal(opId);

        // Step 7: Verify the proposal was created correctly.
        (
            string memory description,
            bool tallied,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes
        ) = gov.getProposalResult(proposalId);
        assertEq(description, PROPOSAL_DESC);
        assertFalse(tallied);
        assertEq(forVotes, 0);
        assertEq(againstVotes, 0);
        assertEq(abstainVotes, 0);

        // Step 8: Operation is now marked Done.
        assertTrue(timelock.isOperationDone(opId));
    }

    // ─── 7. Timelock flow – non-admin cannot createProposal after admin is timelock

    function testTimelockStrangerCannotCreateProposal() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        // A stranger calling createProposal directly must revert.
        vm.prank(stranger);
        vm.expectRevert("Not admin");
        gov.createProposal("Evil Proposal", 1 days, 1 days);
    }

    // ─── 8. Timelock flow – original admin cannot bypass timelock ─────────────

    function testTimelockOriginalAdminCannotBypass() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        // The original admin is no longer the Governance admin; direct call reverts.
        vm.prank(admin);
        vm.expectRevert("Not admin");
        gov.createProposal("Bypass Attempt", 1 days, 1 days);
    }

    // ─── 9. Timelock flow – schedule with insufficient delay reverts ──────────

    function testTimelockInsufficientDelayReverts() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");

        // Schedule with delay below 48 hours.
        vm.prank(admin);
        vm.expectRevert("TimelockController: insufficient delay");
        timelock.schedule(address(gov), 0, data, bytes32(0), salt, MIN_DELAY - 1);
    }

    // ─── 10. Timelock flow – execute before delay reverts ─────────────────────

    function testTimelockExecuteBeforeDelayReverts() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        bytes32 opId = _scheduleCreateProposal();

        // Try to execute immediately (before delay).
        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");

        vm.prank(admin);
        vm.expectRevert("TimelockController: operation is not ready");
        timelock.execute(address(gov), 0, data, bytes32(0), salt);
    }

    // ─── 11. Timelock flow – cancel a scheduled operation ─────────────────────

    function testTimelockCancelOperation() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        bytes32 opId = _scheduleCreateProposal();
        assertTrue(timelock.isOperationPending(opId));

        // Admin (who has CANCELLER_ROLE) cancels the operation.
        vm.prank(admin);
        timelock.cancel(opId);

        // Operation is no longer pending.
        assertFalse(timelock.isOperationPending(opId));
        assertFalse(timelock.isOperation(opId));

        // Execute after cancel must revert (operation is Unset).
        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.prank(admin);
        vm.expectRevert("TimelockController: operation is not ready");
        timelock.execute(address(gov), 0, data, bytes32(0), salt);
    }

    // ─── 12. Timelock flow – minDelay is at least 48 hours ─────────────────────

    function testTimelockMinDelayIs48Hours() public view {
        assertGe(timelock.getMinDelay(), 48 hours, "minDelay must be >= 48 hours");
    }

    // ─── 13. Timelock flow – cannot re-execute an already executed operation ──

    function testTimelockCannotReExecute() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        bytes32 opId = _scheduleCreateProposal();

        // Warp past delay and execute.
        vm.warp(block.timestamp + MIN_DELAY + 1);
        _executeCreateProposal(opId);

        // Re-execution must revert (operation already Done).
        bytes memory data = _createProposalCalldata();
        bytes32 salt = keccak256("salt");

        vm.prank(admin);
        vm.expectRevert("TimelockController: operation is not ready");
        timelock.execute(address(gov), 0, data, bytes32(0), salt);
    }

    // ─── 14. Timelock flow – admin can schedule multiple proposals ─────────────

    function testTimelockMultipleProposals() public {
        // Transfer admin to timelock.
        vm.prank(admin);
        gov.updateAdmin(address(timelock));

        // Schedule two distinct proposals.
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");
        bytes memory data1 =
            abi.encodeWithSelector(Governance.createProposal.selector, "Prop 1", 1 days, 1 days);
        bytes memory data2 =
            abi.encodeWithSelector(Governance.createProposal.selector, "Prop 2", 2 days, 2 days);

        vm.prank(admin);
        timelock.schedule(address(gov), 0, data1, bytes32(0), salt1, MIN_DELAY);
        vm.prank(admin);
        timelock.schedule(address(gov), 0, data2, bytes32(0), salt2, MIN_DELAY);

        bytes32 opId1 = timelock.hashOperation(address(gov), 0, data1, bytes32(0), salt1);
        bytes32 opId2 = timelock.hashOperation(address(gov), 0, data2, bytes32(0), salt2);

        assertTrue(timelock.isOperationPending(opId1));
        assertTrue(timelock.isOperationPending(opId2));

        // Warp past delay.
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Execute both.
        vm.prank(admin);
        timelock.execute(address(gov), 0, data1, bytes32(0), salt1);
        vm.prank(admin);
        timelock.execute(address(gov), 0, data2, bytes32(0), salt2);

        assertEq(gov.proposalCount(), 2);

        // Verify proposal descriptions.
        (string memory desc1,,,,) = gov.getProposalResult(1);
        (string memory desc2,,,,) = gov.getProposalResult(2);
        assertEq(desc1, "Prop 1");
        assertEq(desc2, "Prop 2");
    }
}
