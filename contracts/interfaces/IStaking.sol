// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStaking
/// @notice Interface for initializing the WhiteLotus staking module and recording user stakes.
/// @dev The current staking module records accounting values only and does not transfer or custody tokens.
interface IStaking {
    /// @notice Initializes the staking module and assigns its owner.
    /// @dev Intended for a proxy deployment and callable only once. Calling the implementation contract
    ///      directly or initializing an already initialized proxy reverts.
    /// @param initialOwner The account that receives ownership of the staking module.
    function initialize(address initialOwner) external;

    /// @notice Increases the caller's recorded stake and the aggregate stake.
    /// @dev This function performs accounting only: it does not transfer tokens, reject zero amounts,
    ///      or provide an unstaking path in the current implementation.
    /// @param amount The amount to add to the caller's recorded staking balance.
    function stake(uint256 amount) external;

    /// @notice Returns the aggregate amount recorded as staked by all accounts.
    /// @dev This value is accounting state and does not represent token custody.
    /// @return amount The total recorded stake.
    function totalStaked() external view returns (uint256 amount);

    /// @notice Returns the amount recorded as staked by an account.
    /// @dev This value is accounting state and does not represent a claim on custodied tokens.
    /// @param account The account whose recorded staking balance is queried.
    /// @return amount The account's recorded stake.
    function balances(address account) external view returns (uint256 amount);
}
