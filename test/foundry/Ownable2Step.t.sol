// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Vault} from "../../contracts/Vault.sol";
import {StakingLogic} from "../../contracts/core/StakingLogic.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal harness that inherits Ownable2Step to exercise the two-step flow.
contract Ownable2StepHarness is Ownable2Step {
    constructor(address initialOwner) {
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
}

/// @dev Coverage for issue #139 - strict two-step ownership transfer.
///      Acceptance: (1) ownership cannot be transferred in a single transaction,
///      (2) an incorrect address cannot claim ownership.
contract Ownable2StepTest is Test {
    address internal owner = address(0x0A11CE);
    address internal newOwner = address(0xBEEF);
    address internal attacker = address(0xBAD);

    // ── Acceptance: ownership cannot be transferred in a single transaction ──

    function test_TransferOwnershipDoesNotChangeOwnerImmediately() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(owner);
        c.transferOwnership(newOwner);
        assertEq(c.owner(), owner); // still the old owner
        assertEq(c.pendingOwner(), newOwner); // new owner is only pending
    }

    function test_TransferOwnershipEmitsOwnershipTransferStarted() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.expectEmit(true, true, false, false);
        emit Ownable2Step.OwnershipTransferStarted(owner, newOwner);
        vm.prank(owner);
        c.transferOwnership(newOwner);
    }

    // ── Acceptance: an incorrect address cannot claim ownership ──

    function test_OnlyPendingOwnerCanAccept() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(owner);
        c.transferOwnership(newOwner);
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        c.acceptOwnership();
        assertEq(c.owner(), owner);
        assertEq(c.pendingOwner(), newOwner); // still pending, not stolen
    }

    function test_AcceptOwnershipFinalizesTransfer() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(owner);
        c.transferOwnership(newOwner);
        vm.prank(newOwner);
        c.acceptOwnership();
        assertEq(c.owner(), newOwner);
        assertEq(c.pendingOwner(), address(0));
    }

    function test_AcceptOwnershipWithoutPendingReverts() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(newOwner);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        c.acceptOwnership();
    }

    function test_OnlyOwnerCanInitiateTransfer() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(attacker);
        vm.expectRevert(); // Ownable: caller is not the owner
        c.transferOwnership(newOwner);
    }

    // ── Issue requirement: existing admin privileges must be maintained ──

    function test_OwnerRetainsPrivilegesWhileTransferPending() public {
        Ownable2StepHarness c = new Ownable2StepHarness(owner);
        vm.prank(owner);
        c.transferOwnership(newOwner);

        // The current owner can still exercise onlyOwner functions while a
        // transfer is pending.
        vm.prank(owner);
        c.transferOwnership(attacker);
        assertEq(c.pendingOwner(), attacker);

        // The pending owner cannot exercise onlyOwner functions until they accept.
        vm.prank(newOwner);
        vm.expectRevert();
        c.transferOwnership(address(0));
        assertEq(c.owner(), owner); // still the original owner throughout
    }

    // ── Real contract: Vault (non-upgradeable Ownable2Step) ──

    function test_VaultUsesTwoStepOwnership() public {
        MockERC20 asset = new MockERC20();
        Vault vault = new Vault(IERC20(address(asset)), "wVault", "wVLT", owner);
        assertEq(vault.owner(), owner);

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), owner); // unchanged
        assertEq(vault.pendingOwner(), newOwner); // pending only

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    function test_VaultWrongAddressCannotAccept() public {
        MockERC20 asset = new MockERC20();
        Vault vault = new Vault(IERC20(address(asset)), "wVault", "wVLT", owner);
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        vm.prank(attacker);
        vm.expectRevert();
        vault.acceptOwnership();
        assertEq(vault.owner(), owner);
    }

    // ── Real contract: StakingLogic (upgradeable Ownable2Step base) ──

    function _deployStaking() internal returns (StakingLogic) {
        StakingLogic impl = new StakingLogic();
        bytes memory initData = abi.encodeWithSelector(StakingLogic.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return StakingLogic(address(proxy));
    }

    function test_StakingLogicUsesTwoStepOwnership() public {
        StakingLogic staking = _deployStaking();
        assertEq(staking.owner(), owner);

        vm.prank(owner);
        staking.transferOwnership(newOwner);
        assertEq(staking.owner(), owner); // unchanged
        assertEq(staking.pendingOwner(), newOwner); // pending only

        vm.prank(newOwner);
        staking.acceptOwnership();
        assertEq(staking.owner(), newOwner);
    }

    function test_StakingLogicWrongAddressCannotAccept() public {
        StakingLogic staking = _deployStaking();
        vm.prank(owner);
        staking.transferOwnership(newOwner);

        vm.prank(attacker);
        vm.expectRevert();
        staking.acceptOwnership();
        assertEq(staking.owner(), owner);
    }
}
