// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BitMath} from "../../contracts/libraries/BitMath.sol";
import {TickBitmap} from "../../contracts/libraries/TickBitmap.sol";

/// @dev Helper contract to expose BitMath library functions for testing
contract BitMathWrapper {
    function mostSignificantBit(uint256 x) external pure returns (uint8) {
        return BitMath.mostSignificantBit(x);
    }

    function leastSignificantBit(uint256 x) external pure returns (uint8) {
        return BitMath.leastSignificantBit(x);
    }
}

/// @dev Helper contract to expose TickBitmap library for testing
contract TickBitmapWrapper {
    using TickBitmap for mapping(int16 => uint256);

    mapping(int16 => uint256) public bitmap;

    function flipTick(int24 tick) external {
        bitmap.flipTick(tick);
    }

    function flipTick(int24 tick, int24 tickSpacing) external {
        bitmap.flipTick(tick, tickSpacing);
    }

    function isInitialized(int24 tick, int24 tickSpacing) external view returns (bool) {
        return bitmap.isInitialized(tick, tickSpacing);
    }

    function nextInitializedTickWithinOneWord(int24 tick, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return bitmap.nextInitializedTickWithinOneWord(tick, lte);
    }

    function nextInitializedTickWithinOneWord(int24 tick, int24 tickSpacing, bool lte)
        external
        view
        returns (int24 next, bool initialized)
    {
        return bitmap.nextInitializedTickWithinOneWord(tick, tickSpacing, lte);
    }

    function nextInitializedTick(int24 tick, int24 tickSpacing, bool lte, int24 maxDistance)
        external
        view
        returns (int24 next, bool initialized)
    {
        return bitmap.nextInitializedTick(tick, tickSpacing, lte, maxDistance);
    }

    function getBitmapWord(int16 wordPos) external view returns (uint256) {
        return bitmap[wordPos];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// BitMath Tests
// ═══════════════════════════════════════════════════════════════════════════════

/// @title BitMathTest - Thorough tests for BitMath MSB/LSB
contract BitMathTest is Test {
    BitMathWrapper wrapper;

    function setUp() public {
        wrapper = new BitMathWrapper();
    }

    // ─── mostSignificantBit tests ──────────────────────────────────────────

    function test_msb_1() public view {
        assertEq(wrapper.mostSignificantBit(1), 0);
    }

    function test_msb_2() public view {
        assertEq(wrapper.mostSignificantBit(2), 1);
    }

    function test_msb_all_powers_of_2() public view {
        for (uint8 i = 0; i < 255; i++) {
            uint256 val = uint256(1) << i;
            assertEq(wrapper.mostSignificantBit(val), i);
        }
    }

    function test_msb_max_uint256() public view {
        assertEq(wrapper.mostSignificantBit(type(uint256).max), 255);
    }

    function test_msb_non_power_of_2() public view {
        assertEq(wrapper.mostSignificantBit(11), 3); // 0b1011 -> bit 3
        assertEq(wrapper.mostSignificantBit(255), 7);    // 0xFF -> bit 7
        assertEq(wrapper.mostSignificantBit(0xFF00), 15); // 65280 -> bit 15
    }

    function test_msb_reverts_on_zero() public {
        vm.expectRevert(BitMath.ZeroInput.selector);
        wrapper.mostSignificantBit(0);
    }

    function test_msb_consecutive_values() public view {
        // MSB of consecutive values around boundaries
        assertEq(wrapper.mostSignificantBit(127), 6);   // 0111_1111
        assertEq(wrapper.mostSignificantBit(128), 7);   // 1000_0000
        assertEq(wrapper.mostSignificantBit(129), 7);   // 1000_0001
        assertEq(wrapper.mostSignificantBit(65535), 15); // 0xFFFF
        assertEq(wrapper.mostSignificantBit(65536), 16); // 0x10000
    }

    function test_msb_high_bits() public view {
        // Test MSB for values in the upper half of uint256 range
        uint256 val = uint256(1) << 200;
        assertEq(wrapper.mostSignificantBit(val), 200);

        val = (uint256(1) << 254) | 1; // bit 254 and bit 0 set
        assertEq(wrapper.mostSignificantBit(val), 254);
    }

    // ─── leastSignificantBit tests ─────────────────────────────────────────

    function test_lsb_1() public view {
        assertEq(wrapper.leastSignificantBit(1), 0);
    }

    function test_lsb_2() public view {
        assertEq(wrapper.leastSignificantBit(2), 1);
    }

    function test_lsb_all_powers_of_2() public view {
        for (uint8 i = 0; i < 255; i++) {
            uint256 val = uint256(1) << i;
            assertEq(wrapper.leastSignificantBit(val), i);
        }
    }

    function test_lsb_max_uint256() public view {
        assertEq(wrapper.leastSignificantBit(type(uint256).max), 0);
    }

    function test_lsb_non_power_of_2() public view {
        assertEq(wrapper.leastSignificantBit(10), 1);  // 0b1010 -> bit 1
        assertEq(wrapper.leastSignificantBit(8), 3);  // 0b1000 -> bit 3
        assertEq(wrapper.leastSignificantBit(0xFF00), 8);  // 65280 -> bit 8
    }

    function test_lsb_reverts_on_zero() public {
        vm.expectRevert(BitMath.ZeroInput.selector);
        wrapper.leastSignificantBit(0);
    }

    function test_lsb_high_bits() public view {
        uint256 val = uint256(1) << 200;
        assertEq(wrapper.leastSignificantBit(val), 200);

        val = uint256(1) << 255;
        assertEq(wrapper.leastSignificantBit(val), 255);
    }

    // ─── Cross-checks ──────────────────────────────────────────────────────

    function test_msb_lsb_complement() public view {
        // For any power of 2, MSB == LSB
        for (uint8 i = 0; i < 255; i++) {
            uint256 val = uint256(1) << i;
            assertEq(wrapper.mostSignificantBit(val), wrapper.leastSignificantBit(val));
        }
    }

    function test_msb_gte_lsb_always() public view {
        // MSB is always >= LSB for any non-zero value
        uint256[] memory vals = new uint256[](6);
        vals[0] = 1;
        vals[1] = 7;
        vals[2] = 0xFF;
        vals[3] = 0xFFFF;
        vals[4] = type(uint256).max;
        vals[5] = (uint256(1) << 200) | (uint256(1) << 50);

        for (uint256 i = 0; i < vals.length; i++) {
            assertTrue(wrapper.mostSignificantBit(vals[i]) >= wrapper.leastSignificantBit(vals[i]));
        }
    }

    // ─── Fuzz tests ────────────────────────────────────────────────────────

    function testFuzz_msb_is_set(uint256 x) public view {
        vm.assume(x > 0);
        uint8 msb = wrapper.mostSignificantBit(x);
        // The MSB bit must be set
        assertTrue(x & (uint256(1) << msb) != 0);
        // No higher bit should be set
        if (msb < 255) {
            uint256 higherMask = ~((uint256(1) << (msb + 1)) - 1);
            assertEq(x & higherMask, 0);
        }
    }

    function testFuzz_lsb_is_set(uint256 x) public view {
        vm.assume(x > 0);
        uint8 lsb = wrapper.leastSignificantBit(x);
        // The LSB bit must be set
        assertTrue(x & (uint256(1) << lsb) != 0);
        // No lower bit should be set
        if (lsb > 0) {
            uint256 lowerMask = (uint256(1) << lsb) - 1;
            assertEq(x & lowerMask, 0);
        }
    }

    function testFuzz_msb_gte_lsb(uint256 x) public view {
        vm.assume(x > 0);
        assertTrue(wrapper.mostSignificantBit(x) >= wrapper.leastSignificantBit(x));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TickBitmap Tests
// ═══════════════════════════════════════════════════════════════════════════════

/// @title TickBitmapTest - Thorough tests for TickBitmap bitwise operations
contract TickBitmapTest is Test {
    TickBitmapWrapper wrapper;

    function setUp() public {
        wrapper = new TickBitmapWrapper();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Position calculation tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_position_tick_0() public view {
        TickBitmap.Position memory pos = TickBitmap.position(0);
        assertEq(pos.wordPos, 0);
        assertEq(pos.bitPos, 0);
    }

    function test_position_tick_1() public view {
        TickBitmap.Position memory pos = TickBitmap.position(1);
        assertEq(pos.wordPos, 0);
        assertEq(pos.bitPos, 1);
    }

    function test_position_tick_255() public view {
        TickBitmap.Position memory pos = TickBitmap.position(255);
        assertEq(pos.wordPos, 0);
        assertEq(pos.bitPos, 255);
    }

    function test_position_tick_256() public view {
        TickBitmap.Position memory pos = TickBitmap.position(256);
        assertEq(pos.wordPos, 1);
        assertEq(pos.bitPos, 0);
    }

    function test_position_tick_negative_1() public view {
        // tick -1 => word -1, bit 255
        TickBitmap.Position memory pos = TickBitmap.position(-1);
        assertEq(pos.wordPos, -1);
        assertEq(pos.bitPos, 255);
    }

    function test_position_tick_negative_256() public view {
        // tick -256 => word -1, bit 0
        TickBitmap.Position memory pos = TickBitmap.position(-256);
        assertEq(pos.wordPos, -1);
        assertEq(pos.bitPos, 0);
    }

    function test_position_tick_negative_257() public view {
        // tick -257 => word -2, bit 255
        TickBitmap.Position memory pos = TickBitmap.position(-257);
        assertEq(pos.wordPos, -2);
        assertEq(pos.bitPos, 255);
    }

    function test_position_tick_512() public view {
        TickBitmap.Position memory pos = TickBitmap.position(512);
        assertEq(pos.wordPos, 2);
        assertEq(pos.bitPos, 0);
    }

    function test_position_tick_negative_512() public view {
        TickBitmap.Position memory pos = TickBitmap.position(-512);
        assertEq(pos.wordPos, -2);
        assertEq(pos.bitPos, 0);
    }

    // ─── Fuzz position ─────────────────────────────────────────────────────

    function testFuzz_position_round_trip(int24 tick) public view {
        TickBitmap.Position memory pos = TickBitmap.position(tick);
        // Reconstruct the tick from position
        int24 reconstructed = int24(pos.wordPos) * 256 + int24(uint24(pos.bitPos));
        assertEq(reconstructed, tick);
    }

    function testFuzz_position_bitPos_range(int24 tick) public view {
        TickBitmap.Position memory pos = TickBitmap.position(tick);
        assertTrue(pos.bitPos <= 255);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // flipTick tests (tickSpacing=1, legacy API)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_flipTick_sets_bit() public {
        wrapper.flipTick(0);
        assertEq(wrapper.getBitmapWord(0), 1 << 0);
    }

    function test_flipTick_positive_ticks() public {
        wrapper.flipTick(1);
        assertEq(wrapper.getBitmapWord(0), 1 << 1);

        wrapper.flipTick(255);
        assertEq(wrapper.getBitmapWord(0), (1 << 1) | (1 << 255));
    }

    function test_flipTick_negative_ticks() public {
        // Tick -1 => word -1, bit 255
        wrapper.flipTick(-1);
        assertEq(wrapper.getBitmapWord(-1), 1 << 255);

        // Tick -256 => word -1, bit 0
        wrapper.flipTick(-256);
        assertEq(wrapper.getBitmapWord(-1), (1 << 255) | (1 << 0));
    }

    function test_flipTick_crosses_word_boundary() public {
        wrapper.flipTick(256);
        assertEq(wrapper.getBitmapWord(0), 0);
        assertEq(wrapper.getBitmapWord(1), 1 << 0);
    }

    function test_flipTick_toggles_off() public {
        wrapper.flipTick(42);
        assertTrue(wrapper.getBitmapWord(0) & (1 << 42) != 0);

        wrapper.flipTick(42);
        assertEq(wrapper.getBitmapWord(0) & (1 << 42), 0);
    }

    function test_flipTick_multiple_in_same_word() public {
        wrapper.flipTick(0);
        wrapper.flipTick(1);
        wrapper.flipTick(2);
        wrapper.flipTick(3);

        uint256 expected = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);
        assertEq(wrapper.getBitmapWord(0), expected);
    }

    function test_flipTick_various_positions() public {
        TickBitmapWrapper w = new TickBitmapWrapper();
        w.flipTick(0);
        w.flipTick(63);
        w.flipTick(127);
        w.flipTick(128);
        w.flipTick(191);
        w.flipTick(254);
        w.flipTick(255);
        w.flipTick(256);

        uint256 word0 = (1 << 0) | (1 << 63) | (1 << 127) | (1 << 128) | (1 << 191) | (1 << 254) | (1 << 255);
        assertEq(w.getBitmapWord(0), word0);
        assertEq(w.getBitmapWord(1), 1 << 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // flipTick tests with tickSpacing
    // ═══════════════════════════════════════════════════════════════════════════

    function test_flipTick_spacing10() public {
        wrapper.flipTick(0, 10);
        // compressed = 0/10 = 0; word 0, bit 0
        assertEq(wrapper.getBitmapWord(0), 1 << 0);

        wrapper.flipTick(10, 10);
        // compressed = 10/10 = 1; word 0, bit 1
        assertEq(wrapper.getBitmapWord(0), (1 << 0) | (1 << 1));

        wrapper.flipTick(200, 10);
        // compressed = 200/10 = 20; word 0, bit 20
        assertEq(wrapper.getBitmapWord(0), (1 << 0) | (1 << 1) | (1 << 20));
    }

    function test_flipTick_spacing60() public {
        wrapper.flipTick(0, 60);
        // compressed = 0
        assertEq(wrapper.getBitmapWord(0), 1 << 0);

        wrapper.flipTick(60, 60);
        // compressed = 1
        assertEq(wrapper.getBitmapWord(0), (1 << 0) | (1 << 1));

        wrapper.flipTick(-60, 60);
        // compressed = -60/60 = -1; word -1, bit 255
        assertEq(wrapper.getBitmapWord(-1), 1 << 255);
    }

    function test_flipTick_spacing200() public {
        wrapper.flipTick(0, 200);
        wrapper.flipTick(200, 200);
        wrapper.flipTick(400, 200);
        // compressed = 0, 1, 2
        assertEq(wrapper.getBitmapWord(0), (1 << 0) | (1 << 1) | (1 << 2));
    }

    function test_flipTick_spacing_reverts_unaligned() public {
        vm.expectRevert(TickBitmap.TickNotAligned.selector);
        wrapper.flipTick(5, 10);
    }

    function test_flipTick_spacing_reverts_unaligned_negative() public {
        vm.expectRevert(TickBitmap.TickNotAligned.selector);
        wrapper.flipTick(-3, 10);
    }

    function test_flipTick_spacing_negative_ticks() public {
        wrapper.flipTick(-10, 10);
        // compressed = -10/10 = -1; word -1, bit 255
        assertEq(wrapper.getBitmapWord(-1), 1 << 255);

        wrapper.flipTick(-20, 10);
        // compressed = -20/10 = -2; word -1, bit 254
        assertEq(wrapper.getBitmapWord(-1), (1 << 255) | (1 << 254));
    }

    function test_flipTick_spacing_toggles_off() public {
        wrapper.flipTick(60, 60);
        assertTrue(wrapper.getBitmapWord(0) & (1 << 1) != 0);

        wrapper.flipTick(60, 60);
        assertEq(wrapper.getBitmapWord(0) & (1 << 1), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // isInitialized tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_isInitialized_not_set() public view {
        assertFalse(wrapper.isInitialized(0, 1));
        assertFalse(wrapper.isInitialized(10, 10));
    }

    function test_isInitialized_after_flip() public {
        wrapper.flipTick(0, 1);
        assertTrue(wrapper.isInitialized(0, 1));
        assertFalse(wrapper.isInitialized(1, 1));
    }

    function test_isInitialized_after_double_flip() public {
        wrapper.flipTick(42, 1);
        assertTrue(wrapper.isInitialized(42, 1));

        wrapper.flipTick(42, 1);
        assertFalse(wrapper.isInitialized(42, 1));
    }

    function test_isInitialized_with_spacing() public {
        wrapper.flipTick(60, 60);
        assertTrue(wrapper.isInitialized(60, 60));
        assertFalse(wrapper.isInitialized(0, 60));
    }

    function test_isInitialized_negative_tick() public {
        wrapper.flipTick(-10, 10);
        assertTrue(wrapper.isInitialized(-10, 10));
        assertFalse(wrapper.isInitialized(-20, 10));
    }

    function test_isInitialized_reverts_unaligned() public {
        vm.expectRevert(TickBitmap.TickNotAligned.selector);
        wrapper.isInitialized(5, 10);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // nextInitializedTickWithinOneWord - search RIGHT (lte=false)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTick_searchRight_basic() public {
        wrapper.flipTick(5);
        wrapper.flipTick(10);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 5);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchRight_from_exact_tick() public {
        wrapper.flipTick(10);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(10, false);
        assertEq(next, 10);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchRight_no_tick_in_word() public {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 256);
        assertFalse(initialized);
    }

    function test_nextInitializedTick_searchRight_word_boundary() public {
        wrapper.flipTick(256);

        // From tick 0, no ticks in current word => jumps to word boundary
        // Note: initialized=false because tick 256 is in the NEXT word, not the current one
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 256);
        assertFalse(initialized);
    }

    function test_nextInitializedTick_searchRight_many_ticks() public {
        wrapper.flipTick(0);
        wrapper.flipTick(64);
        wrapper.flipTick(128);
        wrapper.flipTick(192);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 0);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(1, false);
        assertEq(next, 64);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(65, false);
        assertEq(next, 128);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(129, false);
        assertEq(next, 192);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchRight_word_crossing() public {
        wrapper.flipTick(255);
        wrapper.flipTick(256);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(255, false);
        assertEq(next, 255);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(256, false);
        assertEq(next, 256);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchRight_last_bit_in_word() public {
        wrapper.flipTick(255);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(100, false);
        assertEq(next, 255);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // nextInitializedTickWithinOneWord - search LEFT (lte=true)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTick_searchLeft_basic() public {
        wrapper.flipTick(5);
        wrapper.flipTick(10);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(8, true);
        assertEq(next, 5);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_from_exact_tick() public {
        wrapper.flipTick(10);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(10, true);
        assertEq(next, 10);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_no_tick_in_word() public {
        // From tick 100, no ticks initialized => returns word boundary
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(100, true);
        assertEq(next, -1); // 0 * 256 - 1
        assertFalse(initialized);
    }

    function test_nextInitializedTick_searchLeft_word_boundary() public {
        // Tick -1 is in word -1 at bit 255
        wrapper.flipTick(-1);

        // From tick 0 (word 0, bit 0), search left => ticks in word 0 only at bit <= 0
        // tick -1 is NOT in word 0, so no tick found, returns boundary -1
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, true);
        assertEq(next, -1); // word boundary: 0 * 256 - 1 = -1
        assertFalse(initialized);
    }

    function test_nextInitializedTick_searchLeft_in_same_word() public {
        // Tick -1 is in word -1, bit 255
        wrapper.flipTick(-1);

        // From tick -1 (word -1, bit 255), search left => finds tick -1
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-1, true);
        assertEq(next, -1);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_negative_ticks() public {
        wrapper.flipTick(-10);
        wrapper.flipTick(-5);

        // From tick -3 (word -1, bit 253), search left => finds tick -5 (word -1, bit 251)
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-3, true);
        assertEq(next, -5);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_many_ticks() public {
        wrapper.flipTick(0);
        wrapper.flipTick(64);
        wrapper.flipTick(128);
        wrapper.flipTick(192);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(255, true);
        assertEq(next, 192);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(191, true);
        assertEq(next, 128);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(127, true);
        assertEq(next, 64);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(63, true);
        assertEq(next, 0);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_word_crossing() public {
        wrapper.flipTick(-1);
        wrapper.flipTick(0);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, true);
        assertEq(next, 0);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(-1, true);
        assertEq(next, -1);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_searchLeft_first_bit_in_word() public {
        wrapper.flipTick(0);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(200, true);
        assertEq(next, 0);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Negative tick search tests
    // ═══════════════════════════════════════════════════════════════════════════

    function test_nextInitializedTick_negative_ticks_searchRight() public {
        wrapper.flipTick(-10);
        wrapper.flipTick(-5);

        // From tick -15, search right => finds tick -10
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-15, false);
        assertEq(next, -10);
        assertTrue(initialized);
    }

    function test_nextInitializedTick_negative_ticks_searchLeft() public {
        wrapper.flipTick(-10);
        wrapper.flipTick(-5);

        // From tick -3, search left => finds tick -5
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-3, true);
        assertEq(next, -5);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // nextInitializedTickWithinOneWord with tickSpacing
    // ═══════════════════════════════════════════════════════════════════════════

    function test_searchRight_spacing10() public {
        wrapper.flipTick(50, 10);
        wrapper.flipTick(100, 10);

        // From tick 0, spacing 10, search right => finds 50
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, 10, false);
        assertEq(next, 50);
        assertTrue(initialized);
    }

    function test_searchRight_spacing10_from_between() public {
        wrapper.flipTick(50, 10);
        wrapper.flipTick(100, 10);

        // From tick 55 (between 50 and 100), spacing 10
        // compressed = ceil(55/10) = 6, search right from compressed 6
        // The tick at compressed 5 (=50) is skipped because 50 < 55.
        // Finds compressed 10 (tick 100), which is the smallest initialized tick >= 55
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(55, 10, false);
        assertEq(next, 100);
        assertTrue(initialized);
    }

    function test_searchRight_spacing10_from_exact() public {
        wrapper.flipTick(100, 10);

        // From tick 100, spacing 10 => finds 100 at compressed 10
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(100, 10, false);
        assertEq(next, 100);
        assertTrue(initialized);
    }

    function test_searchLeft_spacing10() public {
        wrapper.flipTick(50, 10);
        wrapper.flipTick(100, 10);

        // From tick 80, spacing 10, search left
        // compressed = 80/10 = 8, search left from compressed 8
        // Finds compressed 5 (tick 50)
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(80, 10, true);
        assertEq(next, 50);
        assertTrue(initialized);
    }

    function test_searchLeft_spacing10_from_exact() public {
        wrapper.flipTick(100, 10);

        // From tick 100, spacing 10, search left => finds 100
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(100, 10, true);
        assertEq(next, 100);
        assertTrue(initialized);
    }

    function test_searchRight_spacing60_no_tick() public {
        // No ticks initialized, spacing 60
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, 60, false);
        // Compressed boundary: word 1, compressed = 256 => tick = 256 * 60 = 15360
        assertEq(next, 15360);
        assertFalse(initialized);
    }

    function test_searchLeft_spacing60_no_tick() public {
        // No ticks, from tick 1000, spacing 60
        // compressed = 1000/60 = 16 (Solidity floor). Position in word 0, bit 16.
        // No tick found => boundary = (0 * 256 - 1) * 60 = -60
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(1000, 60, true);
        assertEq(next, -60);
        assertFalse(initialized);
    }

    function test_searchRight_spacing_negative_range() public {
        wrapper.flipTick(-600, 60);
        wrapper.flipTick(-120, 60);

        // From tick -700, spacing 60, search right
        // compressed = -700/60 = -11 (Solidity rounds toward zero) - but -700 % 60 != 0
        // so the search function handles this via floor division internally
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-700, 60, false);
        assertEq(next, -600);
        assertTrue(initialized);
    }

    function test_searchLeft_spacing_negative_range() public {
        wrapper.flipTick(-600, 60);
        wrapper.flipTick(-120, 60);

        // From tick -200, spacing 60, search left
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-200, 60, true);
        assertEq(next, -600);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // nextInitializedTick - multi-word search
    // ═══════════════════════════════════════════════════════════════════════════

    function test_multiWord_searchRight_in_current_word() public {
        wrapper.flipTick(50, 1);

        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, false, 1000);
        assertEq(next, 50);
        assertTrue(initialized);
    }

    function test_multiWord_searchRight_across_words() public {
        // Tick 300 is in word 1 (300 >> 8 = 1, bit 44)
        wrapper.flipTick(300, 1);

        // From tick 0, search right across words
        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, false, 500);
        assertEq(next, 300);
        assertTrue(initialized);
    }

    function test_multiWord_searchLeft_across_words() public {
        // Tick -300 is in word -2 (-300 >> 8 = -2, bit 212)
        wrapper.flipTick(-300, 1);

        // From tick 0, search left across words
        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, true, 500);
        assertEq(next, -300);
        assertTrue(initialized);
    }

    function test_multiWord_searchRight_not_found_within_distance() public {
        // Tick 1000 is far away
        wrapper.flipTick(1000, 1);

        // Search with maxDistance = 100 => won't find it
        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, false, 100);
        assertFalse(initialized);
    }

    function test_multiWord_searchLeft_not_found_within_distance() public {
        wrapper.flipTick(-1000, 1);

        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, true, 100);
        assertFalse(initialized);
    }

    function test_multiWord_with_spacing() public {
        // With spacing 10, tick 3000 => compressed 300 => word 1, bit 44
        wrapper.flipTick(3000, 10);

        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 10, false, 5000);
        assertEq(next, 3000);
        assertTrue(initialized);
    }

    function test_multiWord_searchLeft_with_spacing() public {
        wrapper.flipTick(-3000, 10);

        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 10, true, 5000);
        assertEq(next, -3000);
        assertTrue(initialized);
    }

    function test_multiWord_finds_nearest() public {
        wrapper.flipTick(300, 1);
        wrapper.flipTick(600, 1);
        wrapper.flipTick(900, 1);

        // Should find 300 first
        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, false, 1000);
        assertEq(next, 300);
        assertTrue(initialized);
    }

    function test_multiWord_searchLeft_finds_nearest() public {
        wrapper.flipTick(-300, 1);
        wrapper.flipTick(-600, 1);
        wrapper.flipTick(-900, 1);

        // Should find -300 first (nearest)
        (int24 next, bool initialized) = wrapper.nextInitializedTick(0, 1, true, 1000);
        assertEq(next, -300);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Integration: realistic concentrated liquidity scenarios
    // ═══════════════════════════════════════════════════════════════════════════

    function test_realistic_single_position() public {
        wrapper.flipTick(-887220);
        wrapper.flipTick(887220);

        // From tick 0, search right => no tick in word 0, jumps to boundary
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 256);
        assertFalse(initialized);
    }

    function test_realistic_multiple_positions() public {
        wrapper.flipTick(-200);
        wrapper.flipTick(-100);
        wrapper.flipTick(-50);
        wrapper.flipTick(50);
        wrapper.flipTick(100);
        wrapper.flipTick(200);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 50);
        assertTrue(initialized);

        // From tick 0 (word 0, bit 0), search left: tick -50 is in word -1, not word 0.
        // No initialized ticks at or below bit 0 in word 0, so returns word boundary.
        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(0, true);
        assertEq(next, -1); // word boundary: wordPos * 256 - 1 = -1
        assertFalse(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(60, false);
        assertEq(next, 100);
        assertTrue(initialized);

        // From tick -60 (word -1, bit 196), search left: tick -100 is in word -1 at bit 156
        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(-60, true);
        assertEq(next, -100);
        assertTrue(initialized);
    }

    function test_realistic_uniswap_v3_pool_spacing60() public {
        // Simulating a typical USDC/ETH pool with tickSpacing=60
        // Position 1: ticks -887220 to 887220 (full range)
        // Position 2: ticks -6000 to 6000 (concentrated)
        // Position 3: ticks -120 to 120 (very concentrated)
        wrapper.flipTick(-6000, 60);
        wrapper.flipTick(6000, 60);
        wrapper.flipTick(-120, 60);
        wrapper.flipTick(120, 60);

        // Search right from current tick 0
        // compressed(0, 60) = 0. Tick 120 => compressed 2, word 0, bit 2. Found in same word.
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, 60, false);
        assertEq(next, 120);
        assertTrue(initialized);

        // Search left from current tick 0
        // compressed(0, 60) = 0. Tick -120 => compressed -2, word -1, bit 254. Different word!
        // No ticks at or below bit 0 in word 0 => boundary = (0 * 256 - 1) * 60 = -60
        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(0, 60, true);
        assertEq(next, -60);
        assertFalse(initialized);

        // Use multi-word search to find tick -120 from tick 0
        (next, initialized) = wrapper.nextInitializedTick(0, 60, true, 10000);
        assertEq(next, -120);
        assertTrue(initialized);
    }

    function test_realistic_multiword_swap_route() public {
        // Simulate finding next tick during a large swap that crosses multiple words
        wrapper.flipTick(-5000, 10);
        wrapper.flipTick(-1000, 10);
        wrapper.flipTick(1000, 10);
        wrapper.flipTick(5000, 10);

        // Large swap moving left: from tick 500, find nearest initialized tick to the left
        (int24 next, bool initialized) = wrapper.nextInitializedTick(500, 10, true, 10000);
        assertEq(next, -1000);
        assertTrue(initialized);

        // Large swap moving right: from tick -500, find nearest initialized tick to the right
        (next, initialized) = wrapper.nextInitializedTick(-500, 10, false, 10000);
        assertEq(next, 1000);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Gas efficiency
    // ═══════════════════════════════════════════════════════════════════════════

    function test_gas_constant_regardless_of_gap() public {
        wrapper.flipTick(0);
        wrapper.flipTick(255);

        uint256 gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(0, false);
        uint256 used1 = gas1 - gasleft();

        for (int24 i = 1; i < 255; i++) {
            wrapper.flipTick(i);
        }

        gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(0, false);
        uint256 used2 = gas1 - gasleft();

        assertApproxEqAbs(used1, used2, used1 * 2 / 10);
    }

    function test_gas_constant_searchLeft() public {
        wrapper.flipTick(0);
        wrapper.flipTick(255);

        // Search left from 255, gap = 255
        uint256 gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(255, true);
        uint256 usedLargeGap = gas1 - gasleft();

        // Fill in all ticks so gap = 0
        for (int24 i = 1; i < 255; i++) {
            wrapper.flipTick(i);
        }

        gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(255, true);
        uint256 usedNoGap = gas1 - gasleft();

        // Gas should be approximately the same regardless of gap
        assertApproxEqAbs(usedLargeGap, usedNoGap, usedLargeGap * 2 / 10);
    }

    function test_gas_with_spacing() public {
        wrapper.flipTick(0, 10);
        wrapper.flipTick(2550, 10);  // compressed 255, same word

        uint256 gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(0, 10, false);
        uint256 used1 = gas1 - gasleft();

        // Fill in many ticks
        for (int24 i = 1; i < 255; i++) {
            wrapper.flipTick(i * 10, 10);
        }

        gas1 = gasleft();
        wrapper.nextInitializedTickWithinOneWord(0, 10, false);
        uint256 used2 = gas1 - gasleft();

        assertApproxEqAbs(used1, used2, used1 * 2 / 10);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Extreme values
    // ═══════════════════════════════════════════════════════════════════════════

    function test_extreme_positive_tick() public {
        int24 maxTick = int24(type(int24).max);
        wrapper.flipTick(maxTick);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(maxTick - 1, false);
        assertEq(next, maxTick);
        assertTrue(initialized);
    }

    function test_extreme_negative_tick() public {
        int24 minTick = int24(type(int24).min);
        wrapper.flipTick(minTick);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(minTick + 1, true);
        assertEq(next, minTick);
        assertTrue(initialized);
    }

    function test_extreme_tick_spacing_1() public {
        // Tick spacing 1 means every tick can be initialized
        wrapper.flipTick(887272, 1);
        assertTrue(wrapper.isInitialized(887272, 1));
    }

    function test_tick_at_word_boundary_zero() public {
        // Tick 0 is at the exact word boundary (word 0, bit 0)
        wrapper.flipTick(0);
        assertTrue(wrapper.isInitialized(0, 1));

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 0);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(0, true);
        assertEq(next, 0);
        assertTrue(initialized);
    }

    function test_tick_at_negative_word_boundary() public {
        // Tick -256 is at word -1, bit 0
        wrapper.flipTick(-256);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-256, false);
        assertEq(next, -256);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(-256, true);
        assertEq(next, -256);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fuzz tests for TickBitmap
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_flipTick_sets_correct_bit(int24 tick) public {
        // Bound to reasonable range to avoid overflow in int16 wordPos
        tick = int24(bound(int256(tick), -887272, 887272));

        wrapper.flipTick(tick);

        TickBitmap.Position memory pos = TickBitmap.position(tick);
        uint256 word = wrapper.getBitmapWord(pos.wordPos);
        assertTrue(word & (uint256(1) << pos.bitPos) != 0, "Bit not set after flip");
    }

    function testFuzz_flipTick_double_flip_clears(int24 tick) public {
        tick = int24(bound(int256(tick), -887272, 887272));

        wrapper.flipTick(tick);
        wrapper.flipTick(tick);

        TickBitmap.Position memory pos = TickBitmap.position(tick);
        uint256 word = wrapper.getBitmapWord(pos.wordPos);
        assertEq(word & (uint256(1) << pos.bitPos), 0, "Bit not cleared after double flip");
    }

    function testFuzz_searchRight_finds_self(int24 tick) public {
        tick = int24(bound(int256(tick), -887272, 887272));

        wrapper.flipTick(tick);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(tick, false);
        assertEq(next, tick);
        assertTrue(initialized);
    }

    function testFuzz_searchLeft_finds_self(int24 tick) public {
        tick = int24(bound(int256(tick), -887272, 887272));

        wrapper.flipTick(tick);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(tick, true);
        assertEq(next, tick);
        assertTrue(initialized);
    }

    function testFuzz_isInitialized_matches_flip(int24 tick) public {
        tick = int24(bound(int256(tick), -887272, 887272));

        assertFalse(wrapper.isInitialized(tick, 1));
        wrapper.flipTick(tick, 1);
        assertTrue(wrapper.isInitialized(tick, 1));
        wrapper.flipTick(tick, 1);
        assertFalse(wrapper.isInitialized(tick, 1));
    }

    function testFuzz_spacing_alignment(int24 tick, int24 spacing) public {
        spacing = int24(bound(int256(spacing), 1, 200));
        tick = int24(bound(int256(tick), -887272, 887272));
        // Align tick to spacing
        tick = (tick / spacing) * spacing;

        wrapper.flipTick(tick, spacing);
        assertTrue(wrapper.isInitialized(tick, spacing));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Edge case: empty bitmap search behavior
    // ═══════════════════════════════════════════════════════════════════════════

    function test_empty_bitmap_searchRight_from_zero() public view {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, false);
        assertEq(next, 256);
        assertFalse(initialized);
    }

    function test_empty_bitmap_searchLeft_from_zero() public view {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(0, true);
        assertEq(next, -1);
        assertFalse(initialized);
    }

    function test_empty_bitmap_searchRight_from_negative() public view {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-100, false);
        assertEq(next, -256 + 256);
        assertFalse(initialized);
    }

    function test_empty_bitmap_searchLeft_from_negative() public view {
        // tick -100 is in word -1 (bit 156). No ticks => word boundary = -1 * 256 - 1 = -257
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(-100, true);
        assertEq(next, -257);
        assertFalse(initialized);
    }

    function test_empty_bitmap_searchRight_from_255() public view {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(255, false);
        assertEq(next, 256);
        assertFalse(initialized);
    }

    function test_empty_bitmap_searchLeft_from_255() public view {
        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(255, true);
        assertEq(next, -1);
        assertFalse(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Adjacent ticks test
    // ═══════════════════════════════════════════════════════════════════════════

    function test_adjacent_ticks_searchRight() public {
        wrapper.flipTick(5);
        wrapper.flipTick(6);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(5, false);
        assertEq(next, 5);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(6, false);
        assertEq(next, 6);
        assertTrue(initialized);
    }

    function test_adjacent_ticks_searchLeft() public {
        wrapper.flipTick(5);
        wrapper.flipTick(6);

        (int24 next, bool initialized) = wrapper.nextInitializedTickWithinOneWord(6, true);
        assertEq(next, 6);
        assertTrue(initialized);

        (next, initialized) = wrapper.nextInitializedTickWithinOneWord(5, true);
        assertEq(next, 5);
        assertTrue(initialized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Isolated word tests (no cross-contamination)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_different_words_isolated() public {
        wrapper.flipTick(0);    // word 0, bit 0
        wrapper.flipTick(256);  // word 1, bit 0
        wrapper.flipTick(-256); // word -1, bit 0

        // Each word should have exactly 1 bit set
        assertEq(wrapper.getBitmapWord(0), 1);
        assertEq(wrapper.getBitmapWord(1), 1);
        assertEq(wrapper.getBitmapWord(-1), 1);

        // No cross-contamination
        assertEq(wrapper.getBitmapWord(2), 0);
        assertEq(wrapper.getBitmapWord(-2), 0);
    }
}
