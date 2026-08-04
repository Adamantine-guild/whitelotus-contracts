// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TWAP} from "../../contracts/oracle/TWAP.sol";

/// @title TWAPTest - Comprehensive tests for the TWAP oracle
/// @notice Covers: initialization, update mechanics, ring buffer wrapping,
///         binary search correctness, TWAP computation across varying windows,
///         manipulation resistance, authorization, edge cases, and fuzz testing.
contract TWAPTest is Test {
    TWAP internal twap;

    address internal owner = address(0xAAAA);
    address internal pool = address(0xBBBB); // authorized AMM caller
    address internal token0 = address(0xA000);
    address internal token1 = address(0xB000);

    uint32 internal constant MIN_INTERVAL = 30 seconds;
    uint32 internal constant DEFAULT_WINDOW = 30 minutes;

    uint256 internal constant PRECISION = 1e18;

    // ─── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        twap = new TWAP(MIN_INTERVAL, DEFAULT_WINDOW, owner);

        // Authorize the pool address to call update()
        vm.prank(owner);
        twap.setAuthorized(pool, true);
    }

    /// @notice Helper: update via the authorized pool address.
    function _update(address t0, address t1, uint256 price, uint256 priceInv) internal {
        vm.prank(pool);
        twap.update(t0, t1, price, priceInv);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 1: Construction & Configuration
    // ═══════════════════════════════════════════════════════════════════════════

    function testConstructorSetsConfig() public view {
        assertEq(twap.minUpdateInterval(), MIN_INTERVAL);
        assertEq(twap.defaultWindow(), DEFAULT_WINDOW);
        assertEq(twap.owner(), owner);
    }

    function testSetConfigUpdatesParams() public {
        vm.prank(owner);
        twap.setConfig(60 seconds, 1 hours);
        assertEq(twap.minUpdateInterval(), 60 seconds);
        assertEq(twap.defaultWindow(), 1 hours);
    }

    function testRevertSetConfigNotOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        twap.setConfig(60 seconds, 1 hours);
    }

    function testRevertSetConfigZeroInterval() public {
        vm.prank(owner);
        vm.expectRevert("TWAP: zero min update interval");
        twap.setConfig(0, 1 hours);
    }

    function testRevertSetConfigWindowLessThanInterval() public {
        vm.prank(owner);
        vm.expectRevert("TWAP: window < interval");
        twap.setConfig(1 hours, 30 minutes);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 2: Authorization
    // ═══════════════════════════════════════════════════════════════════════════

    function testAuthorizedCallerCanUpdate() public {
        assertTrue(twap.isAuthorized(pool));
        _update(token0, token1, PRECISION, PRECISION);
        assertEq(twap.observationCount(token0, token1), 1);
    }

    function testRevertUnauthorizedUpdate() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(TWAP.NotAuthorized.selector, address(0xBAD)));
        twap.update(token0, token1, PRECISION, PRECISION);
    }

    function testSetAuthorizedAddsAndRemoves() public {
        address newPool = address(0xCCCC);

        vm.prank(owner);
        twap.setAuthorized(newPool, true);
        assertTrue(twap.isAuthorized(newPool));

        vm.prank(owner);
        twap.setAuthorized(newPool, false);
        assertFalse(twap.isAuthorized(newPool));
    }

    function testRevertSetAuthorizedNotOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        twap.setAuthorized(address(0xCCCC), true);
    }

    function testRevertSetAuthorizedZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("TWAP: zero address");
        twap.setAuthorized(address(0), true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 3: Update — Basic Mechanics
    // ═══════════════════════════════════════════════════════════════════════════

    function testUpdateInitializesPair() public {
        uint256 price = 2 * PRECISION;
        _update(token0, token1, price, PRECISION / 2);
        assertEq(twap.observationCount(token0, token1), 1);
    }

    function testUpdateEmitsPairInitialized() public {
        bytes32 pairId = keccak256(abi.encodePacked(token0, token1));

        vm.expectEmit(true, true, true, true);
        emit TWAP.PairInitialized(pairId, token0, token1);

        _update(token0, token1, PRECISION, PRECISION);
    }

    function testUpdateRecordsObservationsAtInterval() public {
        uint256 price = 2 * PRECISION;

        _update(token0, token1, price, PRECISION / 2);

        // Second update within interval — cumulative advances but no new observation
        skip(MIN_INTERVAL / 2);
        _update(token0, token1, price, PRECISION / 2);
        assertEq(twap.observationCount(token0, token1), 1, "no new obs within interval");

        // Third update after interval — new observation
        skip(MIN_INTERVAL);
        _update(token0, token1, price, PRECISION / 2);
        assertEq(twap.observationCount(token0, token1), 2, "new obs after interval");
    }

    function testUpdateAdvancesCumulativePrice() public {
        uint256 price = 2 * PRECISION;

        _update(token0, token1, price, PRECISION / 2);

        skip(100);
        _update(token0, token1, price, PRECISION / 2);

        (uint256 cumPrice, uint32 lastTs) = twap.currentCumulativePrice(token0, token1);
        assertEq(cumPrice, price * 100, "cumulative price = price * timeElapsed");
        assertEq(lastTs, block.timestamp);
    }

    function testUpdateMultipleIntervals() public {
        uint256 price = 1 * PRECISION;

        _update(token0, token1, price, price);

        for (uint256 i = 0; i < 4; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        assertEq(twap.observationCount(token0, token1), 5, "initial + 4 updates = 5 obs");
        (uint256 cumPrice,) = twap.currentCumulativePrice(token0, token1);
        assertEq(cumPrice, price * 4 * MIN_INTERVAL, "cumulative = price * total elapsed");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 4: TWAP Computation
    // ═══════════════════════════════════════════════════════════════════════════

    function testConsultReturnsTWAP() public {
        uint256 price = 2 * PRECISION;
        uint256 priceInv = PRECISION / 2;

        _update(token0, token1, price, priceInv);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, priceInv);
        }

        uint256 amountOut = twap.consult(token0, PRECISION, token1);
        assertApproxEqRel(amountOut, 2 * PRECISION, 2e15, "1 token0 => ~2 token1 via TWAP");
    }

    function testConsultInverseDirection() public {
        uint256 price = 2 * PRECISION;
        uint256 priceInv = PRECISION / 2;

        _update(token0, token1, price, priceInv);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, priceInv);
        }

        uint256 amountOut = twap.consult(token1, PRECISION, token0);
        assertApproxEqRel(amountOut, PRECISION / 2, 2e15, "1 token1 => ~0.5 token0 via TWAP");
    }

    function testConsultWithExplicitWindow() public {
        uint256 price = 2 * PRECISION;

        _update(token0, token1, price, PRECISION / 2);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, PRECISION / 2);
        }

        uint256 amountOut = twap.consult(token0, PRECISION, token1, 15 minutes);
        assertApproxEqRel(amountOut, 2 * PRECISION, 2e15, "15 min TWAP matches constant price");
    }

    function testConsultRevertsWindowTooSmall() public {
        _update(token0, token1, PRECISION, PRECISION);
        skip(MIN_INTERVAL);
        _update(token0, token1, PRECISION, PRECISION);

        vm.expectRevert(abi.encodeWithSelector(TWAP.InvalidWindow.selector, MIN_INTERVAL / 2));
        twap.consult(token0, PRECISION, token1, MIN_INTERVAL / 2);
    }

    function testConsultRevertsUninitializedPair() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                TWAP.PairNotInitialized.selector, keccak256(abi.encodePacked(token0, token1))
            )
        );
        twap.consult(token0, PRECISION, token1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 5: Ring Buffer Wrapping
    // ═══════════════════════════════════════════════════════════════════════════

    function testRingBufferWrapsCorrectly() public {
        uint256 price = 1 * PRECISION;

        _update(token0, token1, price, price);

        for (uint256 i = 0; i < 255; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        assertEq(twap.observationCount(token0, token1), 256, "buffer full at 256");

        skip(MIN_INTERVAL);
        _update(token0, token1, price, price);
        assertEq(twap.observationCount(token0, token1), 256, "cardinality capped at 256");

        uint256 amountOut = twap.consult(token0, PRECISION, token1, DEFAULT_WINDOW);
        assertApproxEqRel(amountOut, PRECISION, 2e15, "TWAP works after buffer wrap");
    }

    function testRingBufferFullyWrapsMultipleTimes() public {
        uint256 price = 1 * PRECISION;

        _update(token0, token1, price, price);

        for (uint256 i = 0; i < 767; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        assertEq(twap.observationCount(token0, token1), 256, "cardinality stays 256 after wraps");
        uint256 amountOut = twap.consult(token0, PRECISION, token1, DEFAULT_WINDOW);
        assertApproxEqRel(amountOut, PRECISION, 2e15, "TWAP works after multiple wraps");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 6: Ring Buffer Indexing & Binary Search
    // ═══════════════════════════════════════════════════════════════════════════

    function testGetObservationLogicalOrdering() public {
        uint256 price = 100 * PRECISION;

        _update(token0, token1, price, PRECISION / 100);

        uint32 t0 = uint32(block.timestamp);
        for (uint256 i = 1; i < 10; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, PRECISION / 100);
        }

        TWAP.Observation memory obs0 = twap.getObservation(token0, token1, 0);
        assertEq(obs0.timestamp, t0, "oldest matches first timestamp");

        TWAP.Observation memory obs9 = twap.getObservation(token0, token1, 9);
        assertEq(obs9.timestamp, uint32(block.timestamp), "newest matches current timestamp");
    }

    function testGetObservationAfterWrap() public {
        uint256 price = 1 * PRECISION;

        _update(token0, token1, price, price);

        for (uint256 i = 0; i < 255; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        TWAP.Observation memory oldestBeforeWrap = twap.getObservation(token0, token1, 0);

        skip(MIN_INTERVAL);
        _update(token0, token1, price, price);

        TWAP.Observation memory oldestAfterWrap = twap.getObservation(token0, token1, 0);
        assertGt(oldestAfterWrap.timestamp, oldestBeforeWrap.timestamp, "oldest shifts after wrap");
    }

    function testRevertGetObservationOutOfBounds() public {
        _update(token0, token1, PRECISION, PRECISION);

        bytes32 pairId = keccak256(abi.encodePacked(token0, token1));
        // Index 5 requires 6 observations; only the seed exists -> available=1, required=6.
        vm.expectRevert(
            abi.encodeWithSelector(TWAP.InsufficientObservations.selector, pairId, 1, 6)
        );
        twap.getObservation(token0, token1, 5);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 7: Price Changes Over Time
    // ═══════════════════════════════════════════════════════════════════════════

    function testTWAPReflectsVaryingPrice() public {
        uint256 price1 = 2 * PRECISION;
        uint256 price2 = 3 * PRECISION;

        _update(token0, token1, price1, PRECISION / 2);

        for (uint256 i = 0; i < 30; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price1, PRECISION / 2);
        }

        for (uint256 i = 0; i < 30; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price2, PRECISION / 3);
        }

        uint256 amountOut = twap.consult(token0, PRECISION, token1, 30 minutes);
        assertApproxEqRel(amountOut, (5 * PRECISION) / 2, 2e16, "TWAP averages price change");
    }

    function testTWAPSpikeInsensitive() public {
        uint256 normalPrice = PRECISION;
        _update(token0, token1, normalPrice, normalPrice);
        for (uint256 i = 0; i < 60; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, normalPrice, normalPrice);
        }

        // Spike to 100x for one observation
        uint256 spikePrice = 100 * PRECISION;
        skip(MIN_INTERVAL);
        _update(token0, token1, spikePrice, PRECISION / 100);

        // TWAP should barely be affected by a single spike
        uint256 amountOut = twap.consult(token0, PRECISION, token1, DEFAULT_WINDOW);
        assertLt(amountOut, 3 * PRECISION, "TWAP resists single spike");
        assertGt(amountOut, PRECISION, "TWAP near normal price");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 8: Multiple Pairs
    // ═══════════════════════════════════════════════════════════════════════════

    function testMultiplePairsIndependent() public {
        address token2 = address(0xC000);

        _update(token0, token1, 2 * PRECISION, PRECISION / 2);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, 2 * PRECISION, PRECISION / 2);
        }

        _update(token0, token2, 5 * PRECISION, PRECISION / 5);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token2, 5 * PRECISION, PRECISION / 5);
        }

        uint256 outAB = twap.consult(token0, PRECISION, token1);
        uint256 outAC = twap.consult(token0, PRECISION, token2);

        assertApproxEqRel(outAB, 2 * PRECISION, 2e15, "pair A: price ~2.0");
        assertApproxEqRel(outAC, 5 * PRECISION, 2e15, "pair B: price ~5.0");
    }

    function testPairIdTokenOrderIndependent() public {
        _update(token0, token1, PRECISION, PRECISION);
        skip(MIN_INTERVAL);
        _update(token1, token0, PRECISION, PRECISION);
        assertEq(twap.observationCount(token0, token1), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 9: Insufficient Data & Edge Cases
    // ═══════════════════════════════════════════════════════════════════════════

    function testConsultRevertsInsufficientWindow() public {
        _update(token0, token1, PRECISION, PRECISION);
        // Only 1 observation (~0 seconds of history), requesting 60 seconds
        bytes32 pairId = keccak256(abi.encodePacked(token0, token1));
        vm.expectRevert(
            abi.encodeWithSelector(TWAP.InsufficientWindow.selector, pairId, uint32(0), uint32(60))
        );
        twap.consult(token0, PRECISION, token1, 60 seconds);
    }

    function testConsultRevertsWindowTooLarge() public {
        uint256 price = PRECISION;

        // Start at a round timestamp so the built history is exactly 15 minutes:
        // 1 seed + 29 writes at 30s intervals = 900s of history.
        vm.warp(1000);
        _update(token0, token1, price, price);
        // Build only ~15 minutes of history
        for (uint256 i = 0; i < 30; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        // Request 30 minutes — should revert (only ~15 min available)
        bytes32 pairId = keccak256(abi.encodePacked(token0, token1));
        vm.expectRevert(
            abi.encodeWithSelector(
                TWAP.InsufficientWindow.selector, pairId, uint32(15 minutes), uint32(30 minutes)
            )
        );
        twap.consult(token0, PRECISION, token1, 30 minutes);
    }

    function testCurrentCumulativePriceReturnsData() public {
        uint256 price = 3 * PRECISION;
        _update(token0, token1, price, PRECISION / 3);

        skip(60);
        _update(token0, token1, price, PRECISION / 3);

        (uint256 cumPrice, uint32 ts) = twap.currentCumulativePrice(token0, token1);
        assertEq(cumPrice, price * 60);
        assertEq(ts, block.timestamp);
    }

    function testCurrentCumulativePriceRevertsUninitialized() public {
        bytes32 pairId = keccak256(abi.encodePacked(token0, token1));
        vm.expectRevert(abi.encodeWithSelector(TWAP.PairNotInitialized.selector, pairId));
        twap.currentCumulativePrice(token0, token1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 10: Reverts for Invalid Inputs
    // ═══════════════════════════════════════════════════════════════════════════

    function testRevertIdenticalTokens() public {
        vm.expectRevert(TWAP.IdenticalTokens.selector);
        _update(token0, token0, PRECISION, PRECISION);
    }

    function testRevertZeroAddressToken() public {
        vm.expectRevert(TWAP.ZeroAddress.selector);
        _update(address(0), token1, PRECISION, PRECISION);
    }

    function testRevertZeroPrice() public {
        vm.expectRevert(TWAP.InvalidPrice.selector);
        _update(token0, token1, 0, PRECISION);
    }

    function testRevertZeroPriceInv() public {
        vm.expectRevert(TWAP.InvalidPrice.selector);
        _update(token0, token1, PRECISION, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Section 11: Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_ConstantPriceTWAP(uint256 price) public {
        price = bound(price, 1e6, 1_000_000 * PRECISION);
        uint256 priceInv = (PRECISION * PRECISION) / price;

        _update(token0, token1, price, priceInv);
        for (uint256 i = 0; i < 61; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, priceInv);
        }

        uint256 amountOut = twap.consult(token0, PRECISION, token1);
        assertApproxEqRel(amountOut, price, 2e15, "TWAP matches constant price");
    }

    function testFuzz_CumulativeAdvancement(uint256 secondsElapsed) public {
        secondsElapsed = bound(secondsElapsed, 1, 1 hours);
        uint256 price = 1 * PRECISION;

        _update(token0, token1, price, price);
        skip(secondsElapsed);
        _update(token0, token1, price, price);

        (uint256 cumPrice,) = twap.currentCumulativePrice(token0, token1);
        assertEq(cumPrice, price * secondsElapsed, "cumulative = price * time");
    }

    function testFuzz_ObservationCountAfterUpdates(uint256 numUpdates) public {
        numUpdates = bound(numUpdates, 1, 500);
        uint256 price = PRECISION;

        _update(token0, token1, price, price);
        for (uint256 i = 0; i < numUpdates; i++) {
            skip(MIN_INTERVAL);
            _update(token0, token1, price, price);
        }

        uint256 expected = numUpdates + 1 > 256 ? 256 : numUpdates + 1;
        assertEq(twap.observationCount(token0, token1), expected, "cardinality bound correct");
    }
}
