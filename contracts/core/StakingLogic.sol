// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseLogic} from "./BaseLogic.sol";

contract StakingLogic is BaseLogic {
    // Example staking logic state variable
    uint256 public totalStaked;
    mapping(address => uint256) public balances;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init();
        if (initialOwner != msg.sender) _transferOwnership(initialOwner);
    }

    function stake(uint256 amount) external {
        totalStaked += amount;
        balances[msg.sender] += amount;
    }
}
