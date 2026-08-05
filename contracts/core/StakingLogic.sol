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

    /// @dev nonReentrant (#84): stake/unstake mutate global accounting state.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        totalStaked += amount;
        balances[msg.sender] += amount;
        emit Staked(msg.sender, amount);
    }

    /// @dev nonReentrant (#84): unstake mutates global accounting state.
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
