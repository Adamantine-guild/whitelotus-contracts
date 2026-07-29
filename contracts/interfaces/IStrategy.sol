// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy - Contract every yield strategy plugged into a WhiteLotus vault implements
/// @notice A strategy custodies capital handed to it by exactly one vault and reports what that
///         capital is currently worth. Every amount is denominated in the vault's underlying asset,
///         so the vault never needs to understand the external protocol's own accounting units.
interface IStrategy {
    /// @notice The ERC-20 this strategy accepts and reports in.
    function asset() external view returns (address);

    /// @notice The only address allowed to move capital in or out of this strategy.
    function vault() external view returns (address);

    /// @notice Value of everything the strategy controls, including yield not yet realised.
    function totalAssets() external view returns (uint256);

    /// @notice Portion of {totalAssets} that could be returned to the vault in this block.
    /// @dev External markets go illiquid, so this may be below {totalAssets}. The vault uses it to
    ///      keep `maxWithdraw` honest rather than letting a withdrawal revert on the user.
    function availableLiquidity() external view returns (uint256);

    /// @notice Deploy `assets`, which the vault has already transferred to this contract.
    function deposit(uint256 assets) external;

    /// @notice Return up to `assets` to the vault.
    /// @return withdrawn Amount actually transferred back, which may be less than requested.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Unwind the whole position and return everything to the vault.
    /// @return withdrawn Amount transferred back.
    function withdrawAll() external returns (uint256 withdrawn);

    /// @notice Realise pending yield and fold it back into the strategy's principal.
    function harvest() external;
}
