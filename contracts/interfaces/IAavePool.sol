// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAavePool - Subset of the Aave V3 Pool used by {AaveYieldStrategy}
interface IAavePool {
    /// @notice Supply `amount` of `asset` and receive the matching aToken.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Redeem aTokens for `asset`. Pass `type(uint256).max` to exit the full position.
    /// @return The amount of `asset` actually sent to `to`.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
