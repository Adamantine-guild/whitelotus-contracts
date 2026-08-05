// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {AppStorage} from "../../libraries/AppStorage.sol";

contract SwapFacet {
    error InsufficientOutputAmount();
    error RouterPaused();

    AppStorage internal s;

    event TokensSwapped(
        address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @dev Restricted while paused (#90) — swaps are frozen during an emergency.
    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        if (s.paused) revert RouterPaused();
        // Simple mock router logic
        amountOut = amountIn; // 1:1 mock swap
        if (!(amountOut >= minAmountOut)) revert InsufficientOutputAmount();

        s.balances[msg.sender] += amountOut;
        s.totalSwaps += 1;

        emit TokensSwapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        // Simple mock price check
        return amountIn;
    }

    function getTotalSwaps() external view returns (uint256) {
        return s.totalSwaps;
    }

    function getBalance(address user) external view returns (uint256) {
        return s.balances[user];
    }
}
