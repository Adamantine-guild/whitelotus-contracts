// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {BaseStrategy} from "../strategies/BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockYieldStrategy - Strategy that simply holds the asset, for use in tests only
/// @dev Never deploy this to production. Yield and losses are conjured rather than earned, and the
///      failure toggles exist so the vault can be exercised against a strategy that cannot return
///      everything it holds or that overstates how much it can release.
contract MockYieldStrategy is BaseStrategy {
    /// @notice Assets the strategy refuses to release, modelling a position stuck in a protocol.
    uint256 public lockedAssets;

    /// @notice When set, {availableLiquidity} ignores {lockedAssets} and over-promises.
    bool public overstatesLiquidity;

    constructor(IERC20 asset_, address vault_) BaseStrategy(asset_, vault_) {}

    /// @inheritdoc IStrategy
    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @inheritdoc IStrategy
    function availableLiquidity() external view returns (uint256) {
        uint256 balance = _asset.balanceOf(address(this));
        if (overstatesLiquidity) return balance;
        return balance > lockedAssets ? balance - lockedAssets : 0;
    }

    function setLockedAssets(uint256 amount) external {
        lockedAssets = amount;
    }

    function setOverstatesLiquidity(bool value) external {
        overstatesLiquidity = value;
    }

    function simulateYield(uint256 amount) external {
        MockERC20(address(_asset)).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external {
        MockERC20(address(_asset)).burn(address(this), amount);
    }

    function _invest(uint256) internal override {}

    function _divest(uint256) internal view override returns (uint256 freed) {
        uint256 balance = _asset.balanceOf(address(this));
        return balance > lockedAssets ? balance - lockedAssets : 0;
    }

    function _divestAll() internal view override returns (uint256 freed) {
        return _divest(type(uint256).max);
    }

    function _harvest() internal override {}
}
