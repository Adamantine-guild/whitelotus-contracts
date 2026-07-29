// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/// @title BitMath - Gas-efficient binary search for most/least significant bit
/// @notice Finds MSB/LSB in O(log2(256)) = O(1) via de Bruijn-style bit tricks
/// @dev Used by TickBitmap to locate the next initialized tick
library BitMath {
    error ZeroInput();

    /// @notice Returns the position of the most significant bit (MSB) of x
    /// @dev If x is 0, reverts. The MSB is the highest set bit.
    /// @param x The value to search
    /// @return msb The 0-indexed position of the most significant bit
    function mostSignificantBit(uint256 x) internal pure returns (uint8 msb) {
        if (!(x > 0)) revert ZeroInput();

        // Binary search using repeated halving - O(1) time
        if (x >= 1 << 128) { x >>= 128; msb += 128; }
        if (x >= 1 << 64) { x >>= 64; msb += 64; }
        if (x >= 1 << 32) { x >>= 32; msb += 32; }
        if (x >= 1 << 16) { x >>= 16; msb += 16; }
        if (x >= 1 << 8) { x >>= 8; msb += 8; }
        if (x >= 1 << 4) { x >>= 4; msb += 4; }
        if (x >= 1 << 2) { x >>= 2; msb += 2; }
        if (x >= 1 << 1) { msb += 1; }
    }

    /// @notice Returns the position of the least significant bit (LSB) of x
    /// @dev If x is 0, reverts. The LSB is the lowest set bit.
    /// @param x The value to search
    /// @return lsb The 0-indexed position of the least significant bit
    function leastSignificantBit(uint256 x) internal pure returns (uint8 lsb) {
        if (!(x > 0)) revert ZeroInput();

        // Binary search using repeated halving - O(1) time
        // If lower bits are zero, the LSB must be higher; shift right and accumulate offset
        if ((x & ((1 << 128) - 1)) == 0) { x >>= 128; lsb += 128; }
        if ((x & ((1 << 64) - 1)) == 0) { x >>= 64; lsb += 64; }
        if ((x & ((1 << 32) - 1)) == 0) { x >>= 32; lsb += 32; }
        if ((x & ((1 << 16) - 1)) == 0) { x >>= 16; lsb += 16; }
        if ((x & ((1 << 8) - 1)) == 0) { x >>= 8; lsb += 8; }
        if ((x & ((1 << 4) - 1)) == 0) { x >>= 4; lsb += 4; }
        if ((x & ((1 << 2) - 1)) == 0) { x >>= 2; lsb += 2; }
        if ((x & 1) == 0) { lsb += 1; }
    }
}
