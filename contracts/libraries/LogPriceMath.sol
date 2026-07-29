// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BitMath} from "./BitMath.sol";

/// @title LogPriceMath - Fixed-point binary logarithm and exponential for price accumulators
/// @notice Converts prices to and from base-2 logarithms in unsigned Q64.64 fixed point.
/// @dev Accumulating `log2(price)` instead of `price` turns a time-weighted arithmetic mean into
///      a time-weighted geometric mean, which is invariant to the direction the pair is quoted in
///      and is the standard basis for manipulation-resistant AMM oracles.
library LogPriceMath {
    /// @dev ln(2) in Q128.128.
    uint256 private constant LN2_Q128 = 0xb17217f7d1cf79abc9e3b39803f2f6af;

    /// @dev Number of Taylor terms used by {exp2}. The remainder after 32 terms is below one
    ///      Q128 unit for every admissible input, so the series is exact at this precision.
    uint256 private constant EXP2_TERMS = 32;

    /// @dev Largest integer exponent {exp2} accepts before the final shift would overflow.
    uint256 private constant MAX_EXP2_INTEGER_PART = 254;

    error ZeroInput();
    error ExponentTooLarge(uint256 exponent);

    /// @notice Computes `log2(x)` as an unsigned Q64.64 value.
    /// @dev Only defined for `x >= 1`; prices are always passed in as 18-decimal fixed point, so
    ///      the smallest representable input is one wei of price and the result is non-negative.
    ///      The integer part comes from the position of the most significant bit; the 64 fractional
    ///      bits are extracted one at a time by repeatedly squaring the mantissa normalised to
    ///      [1, 2) in Q1.126, which keeps every intermediate product below 2^254.
    /// @param x The value to take the logarithm of.
    /// @return result `log2(x)` scaled by 2^64.
    function log2(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) revert ZeroInput();

        uint256 msb = BitMath.mostSignificantBit(x);
        result = msb << 64;

        uint256 mantissa = msb >= 126 ? x >> (msb - 126) : x << (126 - msb);
        for (uint256 bit = 1 << 63; bit != 0; bit >>= 1) {
            mantissa = (mantissa * mantissa) >> 126;
            if (mantissa >= 1 << 127) {
                mantissa >>= 1;
                result |= bit;
            }
        }
    }

    /// @notice Computes `2^y`, where `y` is an unsigned Q64.64 value, rounded down.
    /// @dev The integer and fractional parts are handled separately: `2^y = 2^i * 2^f`. The
    ///      fractional factor is evaluated as `e^(f * ln2)` with a Taylor series in Q128.128,
    ///      where the argument is bounded by ln(2) and the series therefore converges rapidly.
    /// @param y The exponent scaled by 2^64.
    /// @return The value of `2^y` as an integer.
    function exp2(uint256 y) internal pure returns (uint256) {
        uint256 integerPart = y >> 64;
        if (integerPart > MAX_EXP2_INTEGER_PART) revert ExponentTooLarge(integerPart);

        uint256 z = ((y & type(uint64).max) * LN2_Q128) >> 64;

        uint256 total = 1 << 128;
        uint256 term = 1 << 128;
        for (uint256 n = 1; n <= EXP2_TERMS; ++n) {
            term = ((term * z) >> 128) / n;
            if (term == 0) break;
            total += term;
        }

        return integerPart >= 128 ? total << (integerPart - 128) : total >> (128 - integerPart);
    }
}
