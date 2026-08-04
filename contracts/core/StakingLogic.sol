// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseLogic} from "./BaseLogic.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title StakingLogic - Core staking with an emergency circuit breaker
/// @notice Upgradeable staking ledger. An owner-controlled pause halts new stakes
///         while leaving unstakes open, so a halt can never trap user funds.
contract StakingLogic is BaseLogic, PausableUpgradeable {
    uint256 public totalStaked;
    mapping(address => uint256) public balances;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientStake(uint256 staked, uint256 requested);
    error AlreadyInitialOwner();

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) initializer public {
        __Ownable_init();
        __Pausable_init();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialOwner == msg.sender) revert AlreadyInitialOwner();
        _transferOwnership(initialOwner);
    }

    /// @notice Stake tokens into the pool.
    /// @dev Reverts while paused. New capital is gated by the circuit breaker so
    ///      an emergency halt freezes the pool's inflow.
    function stake(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        totalStaked += amount;
        balances[msg.sender] += amount;
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw staked tokens.
    /// @dev Intentionally NOT gated by {whenNotPaused}: users can always exit.
    ///      Blocking unstake while paused would trap depositor funds, the exact
    ///      failure mode a circuit breaker exists to prevent (matches Vault.sol).
    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = balances[msg.sender];
        if (staked < amount) revert InsufficientStake(staked, amount);
        unchecked {
            balances[msg.sender] = staked - amount;
        }
        totalStaked -= amount;
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Emergency pause. Halts new stakes; unstakes stay available.
    /// @dev Restricted to the owner. Emits the standard {Paused} event.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operations.
    /// @dev Restricted to the owner. Emits the standard {Unpaused} event.
    function unpause() external onlyOwner {
        _unpause();
    }
}
