// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/// @title ERC2771Context
/// @notice Provides meta-transaction support following ERC-2771.
/// @dev Inheriting contracts should use `_msgSender()` instead of `msg.sender`
///      to be compatible with sponsored/gasless transactions executed via a trusted forwarder.
///
///      When a call originates from the trusted forwarder, the forwarder appends the original
///      signer's address (20 bytes) to the calldata.  This contract peels those bytes off to
///      recover the true sender; for all other callers it falls back to the raw `msg.sender`.
abstract contract ERC2771Context {
    error ZeroForwarder();

    // ─── State ──────────────────────────────────────────────────────────────

    /// @dev The one forwarder contract that is allowed to relay meta-transactions.
    address private immutable _trustedForwarder;

    // ─── Constructor ────────────────────────────────────────────────────────

    /// @param trustedForwarder_ Address of the EIP-712 forwarder contract.
    constructor(address trustedForwarder_) {
        if (!(trustedForwarder_ != address(0))) revert ZeroForwarder();
        _trustedForwarder = trustedForwarder_;
    }

    // ─── Public helpers ─────────────────────────────────────────────────────

    /// @notice Returns the address of the trusted forwarder.
    function trustedForwarder() public view virtual returns (address) {
        return _trustedForwarder;
    }

    /// @notice Returns true if `forwarder` is the trusted forwarder.
    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder == _trustedForwarder;
    }

    // ─── Internal helpers ───────────────────────────────────────────────────

    /// @notice Returns the true sender of the call.
    /// @dev If called by the trusted forwarder, the last 20 bytes of calldata are the
    ///      original signer address appended by the forwarder (per ERC-2771 §7).
    ///      Otherwise returns the raw `msg.sender`.
    function _msgSender() internal view virtual returns (address sender) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            // The forwarder appends: calldata || signer_address (20 bytes).
            // solhint-disable-next-line no-inline-assembly
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /// @notice Returns the call data without the appended sender suffix.
    /// @dev Mirrors `_msgSender()` stripping logic; useful for downstream calldata consumers.
    function _msgData() internal view virtual returns (bytes calldata) {
        if (isTrustedForwarder(msg.sender) && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        } else {
            return msg.data;
        }
    }
}
