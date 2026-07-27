// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BitMath.sol";

/// @title TickBitmap - O(1) bitwise tick lookup for concentrated liquidity
/// @notice Stores initialized ticks as bits in a packed bitmap. Each uint256 word covers
///         256 compressed ticks; a `mapping(int16 => uint256)` keyed by word index holds the bits.
/// @dev Replaces linear O(N) tick iteration with constant-time bitwise search.
///      Supports tick spacing: only ticks divisible by tickSpacing are stored. The bitmap
///      stores *compressed* tick indices (`tick / tickSpacing`), so each word actually covers
///      `256 * tickSpacing` real ticks.
///
///      Storage layout:
///      ┌─────────────────────────────────────────────────────────────────┐
///      │ mapping(int16 wordPos => uint256 word)                         │
///      │   wordPos = compressed >> 8                                    │
///      │   bitPos  = compressed & 0xFF  (i.e. compressed % 256)        │
///      │   compressed = tick / tickSpacing                              │
///      └─────────────────────────────────────────────────────────────────┘
library TickBitmap {
    /// @notice Position of a tick in the bitmap: word index and bit position within word
    struct Position {
        int16 wordPos;
        uint8 bitPos;
    }

    // ─── Core helpers ──────────────────────────────────────────────────────

    /// @notice Compute the word position and bit position for a given tick
    /// @param tick The tick index (int24)
    /// @return pos A Position struct with wordPos and bitPos
    function position(int24 tick) internal pure returns (Position memory pos) {
        // Word index: ticks are packed 256 per word
        // For negative ticks: tick >> 8 rounds toward negative infinity (arithmetic shift)
        pos.wordPos = int16(tick >> 8);
        // Bit position within word: 0-255
        // bitPos = tick - (wordPos * 256), which gives the correct offset for all ticks
        // e.g., tick=-1 => wordPos=-1, bitPos = -1 - (-256) = 255
        // e.g., tick=-256 => wordPos=-1, bitPos = -256 - (-256) = 0
        // Cast chain: 255 overflows int8 to -1, then uint8(-1) = 255 (two's complement)
        pos.bitPos = uint8(int8(tick - int24(pos.wordPos) * 256));
    }

    // ─── State-changing operations ─────────────────────────────────────────

    /// @notice Flip the initialization state of a tick in the bitmap
    /// @dev Used when liquidity is added or removed at a tick. The tick MUST be divisible
    ///      by tickSpacing; this is the caller's responsibility to enforce.
    /// @param self The bitmap storage mapping
    /// @param tick The tick to flip (must be aligned to tickSpacing)
    /// @param tickSpacing The spacing between usable ticks (e.g. 1, 10, 60, 200)
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0, "TickBitmap: tick not aligned");
        int24 compressed = tick / tickSpacing;
        Position memory pos = position(compressed);
        uint256 mask = 1 << pos.bitPos;
        self[pos.wordPos] ^= mask;
    }

    /// @notice Check whether a tick is currently initialized in the bitmap
    /// @param self The bitmap storage mapping
    /// @param tick The tick to check (must be aligned to tickSpacing)
    /// @param tickSpacing The spacing between usable ticks
    /// @return Whether the tick is initialized
    function isInitialized(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal view returns (bool) {
        require(tick % tickSpacing == 0, "TickBitmap: tick not aligned");
        int24 compressed = tick / tickSpacing;
        Position memory pos = position(compressed);
        return (self[pos.wordPos] & (1 << pos.bitPos)) != 0;
    }

    // ─── Single-word search ────────────────────────────────────────────────

    /// @notice Get the next initialized tick within one word (256 compressed ticks)
    /// @dev Uses bitwise operations for O(1) gas cost regardless of liquidity gaps.
    ///      The search is bounded to a single 256-bit word. If no initialized tick is found,
    ///      the returned `next` is the compressed tick at the word boundary and `initialized`
    ///      is false. The caller should then move to the adjacent word and retry.
    /// @param self The bitmap storage mapping
    /// @param tick The current tick to start searching from
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte If true, search left (lower ticks); if false, search right (higher ticks)
    /// @return next The next initialized tick (or the word boundary if none found),
    ///              already decompressed back to real tick space
    /// @return initialized Whether the returned tick is initialized
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        // Solidity's division rounds toward zero. We need floor division for correct mapping.
        // Apply floor correction for all negative non-aligned ticks first.
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }
        // For rightward search (lte=false), if the tick is not aligned to tickSpacing,
        // round UP (ceil) so we start searching from the next compressed position.
        // This ensures we only return ticks that are >= the input tick.
        // For aligned ticks, the current compressed position is the tick itself, so no adjustment needed.
        if (!lte && tick % tickSpacing != 0) {
            compressed++;
        }

        Position memory pos = position(compressed);

        if (lte) {
            // ─── Search LEFT (lower ticks) ───────────────────────────────
            // Mask: all bits at or below current bit position
            // Mask: bits 0 through bitPos (inclusive) for searching left/down
            uint256 mask = ((1 << pos.bitPos) - 1) | (1 << pos.bitPos);
            uint256 masked = self[pos.wordPos] & mask;

            // If any initialized tick exists at or below current position
            initialized = masked != 0;
            if (initialized) {
                // Find the most significant bit (highest tick <= current)
                uint256 msb = BitMath.mostSignificantBit(masked);
                // Convert back to real tick: (wordPos * 256 + bitPos) * tickSpacing
                next = (int24(int16(pos.wordPos)) * 256 + int24(uint24(msb))) * tickSpacing;
            } else {
                // No initialized tick in this word; jump to the word boundary
                // The lowest compressed tick in this word minus 1
                next = (int24(int16(pos.wordPos)) * 256 - 1) * tickSpacing;
            }
        } else {
            // ─── Search RIGHT (higher ticks) ─────────────────────────────
            // Mask: all bits at and above current bit position
            uint256 maskRight = ~((1 << pos.bitPos) - 1);
            uint256 masked = self[pos.wordPos] & maskRight;

            // If any initialized tick exists at or above current position
            initialized = masked != 0;
            if (initialized) {
                // Find the least significant bit (lowest tick >= current)
                uint256 lsb = BitMath.leastSignificantBit(masked);
                // Convert back to real tick
                next = (int24(int16(pos.wordPos)) * 256 + int24(uint24(lsb))) * tickSpacing;
            } else {
                // No initialized tick in this word; jump to the next word boundary
                // Note: overflow possible if pos.wordPos == 32767, but practical tick ranges
                // (e.g., -887272..887272) are well within bounds
                next = (int24(int16(pos.wordPos + 1)) * 256) * tickSpacing;
            }
        }
    }

    // ─── Multi-word search ─────────────────────────────────────────────────

    /// @notice Find the next initialized tick across multiple words, up to a maximum distance
    /// @dev Iterates word-by-word using nextInitializedTickWithinOneWord. Each iteration is
    ///      still O(1) bitwise work; total cost is O(distance / (256 * tickSpacing)).
    ///      For typical AMM tick ranges and tick spacings this is a small constant.
    /// @param self The bitmap storage mapping
    /// @param tick The current tick to start searching from
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte If true, search left (lower ticks); if false, search right (higher ticks)
    /// @param maxDistance Maximum distance in real tick space to search before giving up
    /// @return next The next initialized tick found
    /// @return initialized Whether an initialized tick was found within maxDistance
    function nextInitializedTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte,
        int24 maxDistance
    ) internal view returns (int24 next, bool initialized) {
        int24 startTick = tick;

        while (true) {
            (next, initialized) = nextInitializedTickWithinOneWord(self, tick, tickSpacing, lte);

            if (initialized) {
                return (next, true);
            }

            // Check distance bound
            int24 distance = lte ? (startTick - next) : (next - startTick);
            if (distance >= maxDistance) {
                return (next, false);
            }

            // Move to the next word boundary
            tick = next;
        }
    }

    // ─── Legacy API (tickSpacing = 1) ──────────────────────────────────────

    /// @notice Flip a tick with implicit tickSpacing=1 (backward compatible)
    /// @param self The bitmap storage mapping
    /// @param tick The tick to flip
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick
    ) internal {
        Position memory pos = position(tick);
        uint256 mask = 1 << pos.bitPos;
        self[pos.wordPos] ^= mask;
    }

    /// @notice Search with implicit tickSpacing=1 (backward compatible)
    /// @param self The bitmap storage mapping
    /// @param tick The current tick
    /// @param lte Search direction
    /// @return next Next initialized tick or word boundary
    /// @return initialized Whether the tick is initialized
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        return nextInitializedTickWithinOneWord(self, tick, 1, lte);
    }
}
