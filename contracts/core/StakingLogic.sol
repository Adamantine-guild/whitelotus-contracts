// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseLogic} from "./BaseLogic.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract StakingLogic is BaseLogic, ReentrancyGuardUpgradeable {
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
        __ReentrancyGuard_init();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialOwner == msg.sender) revert AlreadyInitialOwner();
        _transferOwnership(initialOwner);
    }

    /// @dev nonReentrant: no external call exists on this path today, but stake/unstake
    ///      mutate global accounting state and are guarded defensively against any
    ///      future external call (e.g. a reward-token transfer) introduced on this path.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        totalStaked += amount;
        balances[msg.sender] += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = balances[msg.sender];
        if (staked < amount) revert InsufficientStake(staked, amount);
        unchecked {
            balances[msg.sender] = staked - amount;
        }
        totalStaked -= amount;
        emit Unstaked(msg.sender, amount);
    }
}
