// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TWAPOracle} from "../oracles/TWAPOracle.sol";

/// @title MockAMMPool - Constant-product pool that checkpoints its price for use in tests only
/// @dev Never deploy this to production. Reserves can be set arbitrarily by any caller.
contract MockAMMPool {
    TWAPOracle public immutable oracle;
    address public immutable token0;
    address public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    constructor(TWAPOracle oracle_, address token0_, address token1_) {
        oracle = oracle_;
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Price of one token0 in token1, scaled by 1e18.
    function spotPrice() public view returns (uint256) {
        return (reserve1 * 1e18) / reserve0;
    }

    /// @notice Set the reserves outright and checkpoint the resulting price.
    function sync(uint256 reserve0_, uint256 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        oracle.record(spotPrice());
    }

    /// @notice Trade token0 in for token1 along the constant-product curve.
    function swap0For1(uint256 amountIn) external {
        uint256 amountOut = (reserve1 * amountIn) / (reserve0 + amountIn);
        reserve0 += amountIn;
        reserve1 -= amountOut;
        oracle.record(spotPrice());
    }

    /// @notice Trade token1 in for token0 along the constant-product curve.
    function swap1For0(uint256 amountIn) external {
        uint256 amountOut = (reserve0 * amountIn) / (reserve1 + amountIn);
        reserve1 += amountIn;
        reserve0 -= amountOut;
        oracle.record(spotPrice());
    }

    /// @notice Checkpoint the current price without trading.
    function poke() external {
        oracle.record(spotPrice());
    }

    /// @notice Move the price and restore it within a single transaction, the way a flash loan
    ///         funded manipulation does.
    function flashManipulate(uint256 reserve0_, uint256 reserve1_) external {
        (uint256 cached0, uint256 cached1) = (reserve0, reserve1);

        reserve0 = reserve0_;
        reserve1 = reserve1_;
        oracle.record(spotPrice());

        reserve0 = cached0;
        reserve1 = cached1;
        oracle.record(spotPrice());
    }
}
