// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CDPEngine} from "./CDPEngine.sol";

library OracleReader {
    /**
     * @notice Calculates the health factor of a user's position.
     * @param engine The CDPEngine contract instance
     * @param collateralType The collateral token address
     * @param user The address of the borrower
     * @return healthFactor The health factor (18 decimals). A value < 1e18 means undercollateralized.
     */
    function getHealthFactor(
        CDPEngine engine,
        address collateralType,
        address user
    ) internal view returns (uint256 healthFactor) {
        (uint256 collateral, uint256 debt) = engine.positions(collateralType, user);
        if (debt == 0) return type(uint256).max;

        uint256 price = engine.getNormalizedPrice(collateralType);
        uint256 normalizedCollateral = engine.getNormalizedCollateralAmount(collateralType, collateral);

        // Fetch minCollateralRatio from collateralConfigs
        // slither-disable-next-line unused-return
        (, uint256 minCollateralRatio,) = engine.collateralConfigs(collateralType);
        require(minCollateralRatio > 0, "OracleReader: Invalid collateral ratio");

        // healthFactor = (collateralValue * 1e18) / requiredCollateralValue
        // with collateralValue = collateral * price / 1e18 and required = debt * ratio / 1e18
        // => (normalizedCollateral * price * 1e18) / (debt * minCollateralRatio)
        healthFactor = (normalizedCollateral * price * 1e18) / (debt * minCollateralRatio);
    }
}
