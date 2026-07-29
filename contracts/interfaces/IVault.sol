// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

/// @title IVault
/// @notice Interface for the WhiteLotus ERC-4626 vault and its slippage and treasury extensions.
/// @dev Standard vault and share-token functions are inherited from IERC4626. Deposits and mints
///      are disabled while paused, but withdrawals and redemptions remain available.
interface IVault is IERC4626 {
    /// @notice Deposits assets and requires a minimum number of shares in return.
    /// @dev Reverts while paused, when the caller has not approved enough assets, or when the
    ///      resulting shares are less than `minSharesOut`.
    /// @param assets The amount of the underlying asset to deposit.
    /// @param receiver The account that receives the newly minted vault shares.
    /// @param minSharesOut The minimum acceptable shares; use zero to disable the slippage check.
    /// @return shares The number of vault shares minted to `receiver`.
    function deposit(uint256 assets, address receiver, uint256 minSharesOut)
        external
        returns (uint256 shares);

    /// @notice Mints an exact number of shares while limiting the assets spent.
    /// @dev Reverts while paused, when the caller has not approved enough assets, or when the
    ///      required assets exceed `maxAssetsIn`.
    /// @param shares The number of vault shares to mint.
    /// @param receiver The account that receives the newly minted vault shares.
    /// @param maxAssetsIn The maximum assets to spend; use type(uint256).max to disable the limit.
    /// @return assets The amount of the underlying asset transferred into the vault.
    function mint(uint256 shares, address receiver, uint256 maxAssetsIn)
        external
        returns (uint256 assets);

    /// @notice Returns the address that receives swept protocol fees.
    /// @dev Returns the zero address until the owner configures a treasury.
    /// @return treasuryAddress The current protocol treasury address.
    function treasury() external view returns (address treasuryAddress);

    /// @notice Returns the cumulative amount recorded by all fee sweeps.
    /// @dev The value aggregates raw token amounts and may include tokens with different decimals.
    /// @return amount The cumulative raw amount transferred by `sweepFees`.
    function totalFeesSwept() external view returns (uint256 amount);

    /// @notice Updates the protocol treasury address.
    /// @dev Only the vault owner may call this function. Reverts when `newTreasury` is zero.
    /// @param newTreasury The non-zero address that will receive future fee sweeps.
    function setTreasury(address newTreasury) external;

    /// @notice Transfers the vault's entire balance of a token to the configured treasury.
    /// @dev Only the owner or treasury may call this function. Sweeping the underlying asset can
    ///      remove depositor funds, so callers must ensure the balance represents protocol fees.
    ///      Reverts if the treasury is unset or the token balance is zero.
    /// @param token The ERC-20 token whose full vault balance will be transferred.
    function sweepFees(address token) external;

    /// @notice Pauses deposits and mints.
    /// @dev Only the vault owner may call this function. Withdrawals and redemptions are unaffected.
    function pause() external;

    /// @notice Resumes deposits and mints.
    /// @dev Only the vault owner may call this function and the vault must currently be paused.
    function unpause() external;
}
