// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {AppStorage} from "../../libraries/AppStorage.sol";

contract LiquidityFacet {
    error InsufficientLiquidityBalance();

    AppStorage internal s;

    event LiquidityAdded(
        address indexed user,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event LiquidityRemoved(
        address indexed user,
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        external
        returns (uint256 liquidity)
    {
        // Simple mock liquidity addition
        liquidity = amountA + amountB;
        s.balances[msg.sender] += liquidity;
        s.totalLiquidityAdded += 1;

        emit LiquidityAdded(msg.sender, tokenA, tokenB, amountA, amountB, liquidity);
    }

    function removeLiquidity(address tokenA, address tokenB, uint256 liquidity)
        external
        returns (uint256 amountA, uint256 amountB)
    {
        if (!(s.balances[msg.sender] >= liquidity)) revert InsufficientLiquidityBalance();

        amountA = liquidity / 2;
        amountB = liquidity - amountA;
        s.balances[msg.sender] -= liquidity;

        emit LiquidityRemoved(msg.sender, tokenA, tokenB, liquidity, amountA, amountB);
    }

    function getTotalLiquidityAdded() external view returns (uint256) {
        return s.totalLiquidityAdded;
    }
}
