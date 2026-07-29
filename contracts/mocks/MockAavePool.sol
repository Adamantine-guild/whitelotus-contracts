// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {MockAToken} from "./MockAToken.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockAavePool - Minimal Aave V3 lending market for use in tests only
/// @dev Never deploy this to production. Interest and shortfalls are conjured by test hooks rather
///      than earned, and liquidity is whatever the aToken happens to hold.
contract MockAavePool is IAavePool {
    using SafeERC20 for IERC20;

    mapping(address => MockAToken) public aTokens;

    error UnsupportedAsset(address asset);

    function setAToken(address asset, MockAToken aToken) external {
        aTokens[asset] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        MockAToken aToken = _aToken(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken aToken = _aToken(asset);

        uint256 balance = aToken.balanceOf(msg.sender);
        uint256 requested = amount == type(uint256).max ? balance : Math.min(amount, balance);
        uint256 withdrawn = Math.min(requested, IERC20(asset).balanceOf(address(aToken)));

        if (withdrawn > 0) aToken.burnAndRelease(msg.sender, to, withdrawn);
        return withdrawn;
    }

    /// @notice Credit `account` with `amount` of accrued interest, backed by fresh underlying.
    function simulateYield(address asset, address account, uint256 amount) external {
        MockAToken aToken = _aToken(asset);
        MockERC20(asset).mint(address(aToken), amount);
        aToken.mint(account, amount);
    }

    /// @notice Write `amount` off `account`'s position, modelling a bad debt loss.
    function simulateLoss(address asset, address account, uint256 amount) external {
        MockAToken aToken = _aToken(asset);
        aToken.burn(account, amount);
        MockERC20(asset).burn(address(aToken), amount);
    }

    /// @notice Drain `amount` of underlying out of the market so withdrawals cannot be honoured.
    function drainLiquidity(address asset, uint256 amount) external {
        MockERC20(asset).burn(address(_aToken(asset)), amount);
    }

    function _aToken(address asset) private view returns (MockAToken aToken) {
        aToken = aTokens[asset];
        if (address(aToken) == address(0)) revert UnsupportedAsset(asset);
    }
}
