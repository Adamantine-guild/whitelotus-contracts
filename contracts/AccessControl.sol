// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AccessControl - Two-step admin role transfer
/// @notice Implements a pendingAdmin pattern to prevent admin role loss from typos.
///         The current admin proposes a new admin; the proposed admin must explicitly
///         claim the role before it takes effect.  Deriving contracts can override
///         `_checkAdmin()` to add meta-transaction support (e.g. via ERC-2771).
///
/// @dev Lifecycle:
///      1. Current admin calls `proposeAdmin(newAdmin)` — emits `AdminProposed`.
///      2. `pendingAdmin` calls `claimAdmin()` — emits `AdminClaimed`; role transfers.
///      3. Current admin can cancel anytime before claim via `cancelAdminTransfer()`.
///
///      Design goals:
///      - Typo-safe: a mistyped address cannot accidentally become admin because
///        the proposed address must explicitly claim.
///      - Reusable: lightweight abstract contract with no external dependencies.
///      - Extensible: `_checkAdmin()` is virtual so ERC-2771 contracts can override
///        to resolve the real sender via `_msgSender()`.
abstract contract AccessControl {
    /// @dev Current admin address.
    address public admin;

    /// @dev Proposed admin that must call `claimAdmin()` to accept the role.
    address public pendingAdmin;

    // ─── Events ─────────────────────────────────────────────────────────────

    /// @notice Emitted when the current admin proposes a new admin.
    /// @param currentAdmin The admin that initiated the proposal.
    /// @param proposedAdmin The address that must call `claimAdmin()` to accept.
    event AdminProposed(address indexed currentAdmin, address indexed proposedAdmin);

    /// @notice Emitted when the pending admin claims the admin role.
    /// @param previousAdmin The admin that proposed the transfer.
    /// @param newAdmin The address that claimed and now holds the admin role.
    event AdminClaimed(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Emitted when the current admin cancels a pending transfer.
    /// @param currentAdmin The admin that cancelled the transfer.
    /// @param cancelledAdmin The pending admin whose proposal was cancelled.
    event AdminTransferCancelled(address indexed currentAdmin, address indexed cancelledAdmin);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor() {
        admin = msg.sender;
    }

    // ─── Modifiers ──────────────────────────────────────────────────────────

    /// @notice Reverts if the caller is not the current admin.
    /// @dev    Deriving contracts can override `_checkAdmin()` to use
    ///         `_msgSender()` for ERC-2771 meta-transaction support.
    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    // ─── Admin transfer (two-step) ──────────────────────────────────────────

    /// @notice Propose a new admin. The proposed admin must call `claimAdmin()` to accept.
    /// @dev    Reverts if `newAdmin` is zero, equal to current admin, or already pending.
    /// @param  newAdmin Address to propose as the next admin.
    function proposeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        require(newAdmin != admin, "Same admin");
        require(newAdmin != pendingAdmin, "Already pending");
        pendingAdmin = newAdmin;
        emit AdminProposed(admin, newAdmin);
    }

    /// @notice Claim the admin role. Only callable by the pending admin.
    /// @dev    Reverts if no transfer has been proposed or the caller is not the
    ///         pending admin. After a successful claim `pendingAdmin` is reset to zero.
    function claimAdmin() external {
        require(pendingAdmin != address(0), "No pending");
        require(msg.sender == pendingAdmin, "Not pending");
        address previousAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminClaimed(previousAdmin, admin);
    }

    /// @notice Cancel a pending admin transfer. Only callable by the current admin.
    /// @dev    Reverts if no transfer is pending.
    function cancelAdminTransfer() external onlyAdmin {
        require(pendingAdmin != address(0), "No pending");
        emit AdminTransferCancelled(admin, pendingAdmin);
        pendingAdmin = address(0);
    }

    // ─── Hooks ──────────────────────────────────────────────────────────────

    /// @notice Check that the caller is the current admin.
    /// @dev    Override this to customize the sender resolution (e.g. for ERC-2771).
    ///         The default implementation uses raw `msg.sender`.
    function _checkAdmin() internal view virtual {
        require(msg.sender == admin, "Not admin");
    }
}
