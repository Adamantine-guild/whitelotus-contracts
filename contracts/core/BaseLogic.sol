// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title BaseLogic - Base contract for all upgradeable logic contracts
/// @notice Implements the __gap pattern to prevent storage collisions during upgrades.
abstract contract BaseLogic is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Restricts the upgrade function to the owner of the contract.
     */
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * 
     * To add new variables:
     * 1. Add your variables BEFORE the __gap declaration.
     * 2. Subtract the number of storage slots consumed by your new variables from the __gap size.
     *    For example, if you add a `uint256` (1 slot) and an `address` (1 slot), change `50` to `48`.
     *    `uint256[48] private __gap;`
     * 
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
