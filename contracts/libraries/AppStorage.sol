// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct AppStorage {
    mapping(address => uint256) balances;
    uint256 totalSwaps;
    uint256 totalLiquidityAdded;
    uint256 totalFlashLoans;
}
