// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {AppStorage} from "../../libraries/AppStorage.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";

/// @title PauseManagerFacet — Emergency circuit breaker for the diamond router (#90)
/// @notice A designated guardian can freeze swap / liquidity / flashloan operations
///         instantly. Unpausing is exclusively restricted to the multi-sig
///         governance timelock. Withdrawal paths are deliberately NOT gated.
contract PauseManagerFacet {
    error NotGuardianOrOwner();
    error NotTimelock();
    error ZeroAddress();

    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event PauseGuardianSet(address indexed previous, address indexed current);
    event GovernanceTimelockSet(address indexed timelock);

    AppStorage internal s;

    /// @notice True while the router is frozen.
    function paused() external view returns (bool) {
        return s.paused;
    }

    /// @notice The address allowed to freeze operations instantly.
    function pauseGuardian() external view returns (address) {
        return s.pauseGuardian;
    }

    /// @notice The multi-sig governance timelock (only address that may unpause).
    function governanceTimelock() external view returns (address) {
        return s.governanceTimelock;
    }

    /// @notice Designate the guardian that can freeze the router instantly.
    /// @dev Owner-only, via the diamond's contract owner.
    function setPauseGuardian(address newGuardian) external {
        LibDiamond.enforceIsContractOwner();
        if (newGuardian == address(0)) revert ZeroAddress();
        emit PauseGuardianSet(s.pauseGuardian, newGuardian);
        s.pauseGuardian = newGuardian;
    }

    /// @notice Point unpausing at the governance timelock. One-time, owner-only.
    function setGovernanceTimelock(address timelock) external {
        LibDiamond.enforceIsContractOwner();
        if (timelock == address(0)) revert ZeroAddress();
        if (s.governanceTimelock != address(0)) revert NotTimelock();
        s.governanceTimelock = timelock;
        emit GovernanceTimelockSet(timelock);
    }

    /// @notice Freeze restricted actions instantly. Guardian or diamond owner.
    function pause() external {
        if (msg.sender != s.pauseGuardian && msg.sender != LibDiamond.contractOwner()) {
            revert NotGuardianOrOwner();
        }
        s.paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume operations. EXCLUSIVELY restricted to the governance timelock.
    function unpause() external {
        if (msg.sender != s.governanceTimelock) revert NotTimelock();
        s.paused = false;
        emit Unpaused(msg.sender);
    }
}
