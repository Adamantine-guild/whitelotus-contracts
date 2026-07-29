// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";

/// @title AaveYieldStrategy - Routes vault capital into an Aave V3 lending market
/// @notice Aave's aTokens rebase one-for-one with the underlying, so interest shows up as a growing
///         aToken balance and needs no claiming. {harvest} therefore only sweeps loose asset back
///         into the market, which is what compounds anything that arrived outside a deposit.
contract AaveYieldStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IAavePool public immutable pool;
    IERC20 public immutable aToken;

    constructor(IERC20 asset_, address vault_, IAavePool pool_, IERC20 aToken_)
        BaseStrategy(asset_, vault_)
    {
        if (address(pool_) == address(0) || address(aToken_) == address(0)) revert ZeroAddress();
        pool = pool_;
        aToken = aToken_;
    }

    /// @inheritdoc IStrategy
    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this)) + aToken.balanceOf(address(this));
    }

    /// @dev Aave holds the supplied underlying on the aToken contract, so the market can only
    ///      honour a withdrawal up to that balance no matter how many aTokens are held.
    function availableLiquidity() external view returns (uint256) {
        uint256 supplied = aToken.balanceOf(address(this));
        uint256 marketLiquidity = _asset.balanceOf(address(aToken));
        return _asset.balanceOf(address(this)) + Math.min(supplied, marketLiquidity);
    }

    function _invest(uint256 assets) internal override {
        _asset.forceApprove(address(pool), assets);
        pool.supply(address(_asset), assets, address(this), 0);
    }

    function _divest(uint256 assets) internal override returns (uint256 freed) {
        uint256 loose = _asset.balanceOf(address(this));

        if (loose < assets) {
            uint256 redeemable = Math.min(assets - loose, aToken.balanceOf(address(this)));
            if (redeemable > 0) {
                // Return value is ignored: freed amount is measured via balanceOf below.
                // slither-disable-next-line unused-return
                pool.withdraw(address(_asset), redeemable, address(this));
            }
        }

        freed = _asset.balanceOf(address(this));
    }

    function _divestAll() internal override returns (uint256 freed) {
        if (aToken.balanceOf(address(this)) > 0) {
            // Return value is ignored: freed amount is measured via balanceOf below.
            // slither-disable-next-line unused-return
            pool.withdraw(address(_asset), type(uint256).max, address(this));
        }

        freed = _asset.balanceOf(address(this));
    }

    function _harvest() internal override {
        uint256 loose = _asset.balanceOf(address(this));
        if (loose > 0) _invest(loose);
    }
}
