// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CDPEngine} from "./CDPEngine.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OracleReader} from "./OracleReader.sol";

/**
 * @title Liquidator
 * @notice Helper contract to execute liquidations on CDPEngine.
 *         Pulls stablecoins from caller, executes liquidation, and returns seized collateral.
 */
contract Liquidator {
    using SafeERC20 for IERC20;

    CDPEngine public immutable cdpEngine;
    IERC20 public immutable stablecoin;

    // Partial liquidation cap: Max 50% of the debt can be liquidated at once
    uint256 public constant MAX_LIQUIDATION_PORTION = 0.5e18; // 50%

    // Configurable penalty tiers
    uint256 public tier1Threshold = 0.95e18;
    uint256 public tier1Penalty = 1.05e18;

    uint256 public tier2Threshold = 0.90e18;
    uint256 public tier2Penalty = 1.10e18;

    uint256 public tier3Penalty = 1.15e18;

    event LiquidationExecuted(
        address indexed collateralType,
        address indexed user,
        uint256 debtCovered,
        uint256 collateralSeized,
        address indexed liquidator
    );

    constructor(CDPEngine cdpEngine_, IERC20 stablecoin_) {
        require(address(cdpEngine_) != address(0), "Liquidator: Zero CDP Engine");
        require(address(stablecoin_) != address(0), "Liquidator: Zero stablecoin");
        cdpEngine = cdpEngine_;
        stablecoin = stablecoin_;
    }

    /**
     * @notice Liquidates an unsafe position by covering their debt and receiving discounted collateral.
     * @param collateralType The collateral token of the position.
     * @param user The user whose position is being liquidated.
     * @param debtToCover The amount of debt to cover.
     */
    function liquidatePosition(address collateralType, address user, uint256 debtToCover) external {
        // Enforce partial liquidation cap
        (, uint256 debt) = cdpEngine.positions(collateralType, user);
        uint256 maxLiquidatable = (debt * MAX_LIQUIDATION_PORTION) / 1e18;
        require(debtToCover <= maxLiquidatable, "Liquidator: Exceeds partial liquidation cap");

        // Validate borrower health factor via OracleReader
        uint256 healthFactor = OracleReader.getHealthFactor(cdpEngine, collateralType, user);
        require(healthFactor < 1e18, "Liquidator: Position is safe");

        // Calculate liquidator reward bonus accurately based on configurable liquidation penalty tiers
        uint256 appliedPenalty;
        if (healthFactor >= tier1Threshold) {
            appliedPenalty = tier1Penalty;
        } else if (healthFactor >= tier2Threshold) {
            appliedPenalty = tier2Penalty;
        } else {
            appliedPenalty = tier3Penalty;
        }

        // Transfer stablecoin from caller to this contract
        stablecoin.safeTransferFrom(msg.sender, address(this), debtToCover);

        // Approve CDPEngine to spend stablecoin
        stablecoin.approve(address(cdpEngine), debtToCover);

        // Get collateral balance before
        uint256 balanceBefore = IERC20(collateralType).balanceOf(address(this));

        // Call liquidate on CDPEngine (now accepts penalty)
        cdpEngine.liquidate(collateralType, user, debtToCover, appliedPenalty);

        // Calculate collateral seized
        uint256 balanceAfter = IERC20(collateralType).balanceOf(address(this));
        uint256 collateralSeized = balanceAfter - balanceBefore;

        // Transfer seized collateral to caller
        IERC20(collateralType).safeTransfer(msg.sender, collateralSeized);

        emit LiquidationExecuted(collateralType, user, debtToCover, collateralSeized, msg.sender);
    }
}
