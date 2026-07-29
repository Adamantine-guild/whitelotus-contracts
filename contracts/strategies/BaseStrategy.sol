// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title BaseStrategy - Shared plumbing for vault yield strategies
/// @notice Handles the vault-facing half of {IStrategy}: access control, settling balances back to
///         the vault, and the convention that a strategy always ends a call holding no loose asset
///         it was asked to release. Concrete strategies only implement the four protocol hooks.
abstract contract BaseStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IERC20 internal immutable _asset;

    /// @inheritdoc IStrategy
    address public immutable vault;

    error ZeroAddress();
    error NotVault(address caller);

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    constructor(IERC20 asset_, address vault_) {
        if (address(asset_) == address(0) || vault_ == address(0)) revert ZeroAddress();
        _asset = asset_;
        vault = vault_;
    }

    /// @inheritdoc IStrategy
    function asset() external view returns (address) {
        return address(_asset);
    }

    /// @inheritdoc IStrategy
    function deposit(uint256 assets) external onlyVault {
        if (assets > 0) _invest(assets);
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 assets) external onlyVault returns (uint256 withdrawn) {
        withdrawn = Math.min(assets, _divest(assets));
        if (withdrawn > 0) _asset.safeTransfer(vault, withdrawn);
    }

    /// @inheritdoc IStrategy
    function withdrawAll() external onlyVault returns (uint256 withdrawn) {
        withdrawn = _divestAll();
        if (withdrawn > 0) _asset.safeTransfer(vault, withdrawn);
    }

    /// @inheritdoc IStrategy
    function harvest() external onlyVault {
        _harvest();
    }

    /// @dev Put `assets`, already sitting in this contract, to work in the external protocol.
    function _invest(uint256 assets) internal virtual;

    /// @dev Draw on the external position to cover `assets`.
    /// @return freed Loose balance now available to send back, which may fall short of `assets`.
    function _divest(uint256 assets) internal virtual returns (uint256 freed);

    /// @dev Unwind as much of the external position as the protocol currently allows.
    /// @return freed Loose balance now available to send back.
    function _divestAll() internal virtual returns (uint256 freed);

    /// @dev Realise rewards and compound them back into the external position.
    function _harvest() internal virtual;
}
