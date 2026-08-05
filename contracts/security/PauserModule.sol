// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title PauserModule — Emergency circuit breaker with a distinct guardian role
/// @notice Reusable emergency-pause module (issue #90). A designated `pauseGuardian`
///         can freeze protocol operations instantly without holding any admin powers.
///         Unpausing is exclusively restricted to the multi-sig governance timelock.
///
///         Withdrawal / safety paths deliberately do NOT carry `whenNotPaused`:
///         users must always be able to exit even during an emergency.
abstract contract PauserModule is Ownable, Pausable {
    /// @dev Address that can freeze operations instantly (distinct from owner/admin).
    address public pauseGuardian;

    /// @dev Multi-sig governance timelock. The ONLY address allowed to unpause.
    address public immutable governanceTimelock;

    error NotGuardianOrOwner();
    error NotTimelock();
    error ZeroAddress();

    event PauseGuardianSet(address indexed previous, address indexed current);

    modifier onlyGuardianOrOwner() {
        if (msg.sender != pauseGuardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != governanceTimelock) revert NotTimelock();
        _;
    }

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        governanceTimelock = timelock_;
    }

    /// @notice Designate the guardian that can freeze protocol state instantly.
    /// @dev Owner-only. Guardian has no other admin capabilities.
    function setPauseGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        emit PauseGuardianSet(pauseGuardian, newGuardian);
        pauseGuardian = newGuardian;
    }

    /// @notice Freeze restricted financial actions instantly. Callable by the
    ///         guardian OR the owner (guardian is the fast path; owner as fallback).
    function pause() external onlyGuardianOrOwner {
        _pause();
    }

    /// @notice Resume operations. EXCLUSIVELY restricted to the governance timelock.
    function unpause() external onlyTimelock {
        _unpause();
    }
}
