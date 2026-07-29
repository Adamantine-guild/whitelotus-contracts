// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockOracle} from "../../test/mocks/MockOracle.sol";
import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";

contract MockOracleTest is Test {
    MockOracle internal oracle;

    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    bytes32 internal constant BTC_USD = keccak256("BTC/USD");
    bytes32 internal constant LINK_USD = keccak256("LINK/USD");

    function setUp() public {
        oracle = new MockOracle();
    }

    // ─── Feed Creation ──────────────────────────────────────────────────────

    function test_CreateFeed_EmitsEventAndStoresFeed() public {
        // Can't predict feed address (create2 is not used), so skip checking the feed topic
        vm.expectEmit(true, false, true, true);
        emit MockOracle.FeedCreated(ETH_USD, address(0), 8, 2_000e8);

        address feed = oracle.createFeed(ETH_USD, 8, 2_000e8);

        assertTrue(feed != address(0));
        assertEq(oracle.getFeed(ETH_USD), feed);
        assertEq(oracle.getFeedCount(), 1);
    }

    function test_CreateFeed_RevertsForDuplicate() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        vm.expectRevert(MockOracle.FeedAlreadyExists.selector);
        oracle.createFeed(ETH_USD, 8, 1_500e8);
    }

    function test_CreateFeed_18Decimals() public {
        address feed = oracle.createFeed(LINK_USD, 18, 10e18);
        assertEq(oracle.getDecimals(LINK_USD), 18);
        assertTrue(feed != address(0));
    }

    function test_GetOrCreateFeed_Idempotent() public {
        // First call creates
        address feed1 = oracle.getOrCreateFeed(ETH_USD, 8, 2_000e8);
        assertEq(oracle.getFeedCount(), 1);

        // Second call returns existing (decimals / initialPrice ignored)
        address feed2 = oracle.getOrCreateFeed(ETH_USD, 18, 999e18);
        assertEq(feed1, feed2);
        assertEq(oracle.getFeedCount(), 1);
        assertEq(oracle.getDecimals(ETH_USD), 8);
    }

    // ─── Price Setting ──────────────────────────────────────────────────────

    function test_SetPrice_UpdatesPriceAndEmitsEvent() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        vm.expectEmit(true, true, true, true);
        emit MockOracle.PriceUpdated(ETH_USD, 2_500e8, oracle.getFeed(ETH_USD));

        oracle.setPrice(ETH_USD, 2_500e8);
        assertEq(oracle.getLatestPrice(ETH_USD), 2_500e8);
    }

    function test_SetPrice_RevertsForUnknownFeed() public {
        vm.expectRevert(MockOracle.FeedNotFound.selector);
        oracle.setPrice(keccak256("UNKNOWN"), 1e8);
    }

    function test_MultiplePriceUpdatesForSameFeed() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        oracle.setPrice(ETH_USD, 1_900e8);
        assertEq(oracle.getLatestPrice(ETH_USD), 1_900e8);

        oracle.setPrice(ETH_USD, 2_100e8);
        assertEq(oracle.getLatestPrice(ETH_USD), 2_100e8);

        oracle.setPrice(ETH_USD, 1_500e8);
        assertEq(oracle.getLatestPrice(ETH_USD), 1_500e8);
    }

    // ─── Batch Price Setting ────────────────────────────────────────────────

    function test_BatchSetPrices_UpdatesAll() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        oracle.createFeed(BTC_USD, 8, 30_000e8);
        oracle.createFeed(LINK_USD, 18, 10e18);

        bytes32[] memory names = new bytes32[](3);
        names[0] = ETH_USD;
        names[1] = BTC_USD;
        names[2] = LINK_USD;

        int256[] memory prices = new int256[](3);
        prices[0] = 2_500e8;
        prices[1] = 35_000e8;
        prices[2] = 15e18;

        vm.expectEmit(false, false, false, true);
        emit MockOracle.BatchPricesUpdated(3);

        oracle.batchSetPrices(names, prices);

        assertEq(oracle.getLatestPrice(ETH_USD), 2_500e8);
        assertEq(oracle.getLatestPrice(BTC_USD), 35_000e8);
        assertEq(oracle.getLatestPrice(LINK_USD), 15e18);
    }

    function test_BatchSetPrices_RevertsLengthMismatch() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        bytes32[] memory names = new bytes32[](2);
        names[0] = ETH_USD;
        names[1] = BTC_USD;

        int256[] memory prices = new int256[](1);
        prices[0] = 2_500e8;

        vm.expectRevert(MockOracle.LengthMismatch.selector);
        oracle.batchSetPrices(names, prices);
    }

    function test_BatchSetPrices_RevertsUnknownFeed() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        bytes32[] memory names = new bytes32[](2);
        names[0] = ETH_USD;
        names[1] = keccak256("UNKNOWN");

        int256[] memory prices = new int256[](2);
        prices[0] = 2_500e8;
        prices[1] = 100e8;

        vm.expectRevert(MockOracle.FeedNotFound.selector);
        oracle.batchSetPrices(names, prices);
    }

    // ─── Round Data ─────────────────────────────────────────────────────────

    function test_GetLatestRoundData_ReturnsFullStruct() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.getLatestRoundData(ETH_USD);

        assertEq(roundId, 1);
        assertEq(answer, 2_000e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 1);
    }

    function test_GetLatestRoundData_UpdatesAfterSetPrice() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        vm.warp(block.timestamp + 12);
        oracle.setPrice(ETH_USD, 3_000e8);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.getLatestRoundData(ETH_USD);

        assertEq(roundId, 2);
        assertEq(answer, 3_000e8);
        assertEq(startedAt, block.timestamp);
        assertEq(answeredInRound, 2);
    }

    // ─── Read Helpers ───────────────────────────────────────────────────────

    function test_HasFeed_TrueWhenExists() public {
        assertFalse(oracle.hasFeed(ETH_USD));
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        assertTrue(oracle.hasFeed(ETH_USD));
    }

    function test_HasFeed_FalseWhenNotExists() public {
        assertFalse(oracle.hasFeed(keccak256("NONEXISTENT")));
    }

    function test_GetFeed_RevertsUnknown() public {
        vm.expectRevert(MockOracle.FeedNotFound.selector);
        oracle.getFeed(keccak256("MISSING"));
    }

    function test_GetLatestPrice_RevertsUnknown() public {
        vm.expectRevert(MockOracle.FeedNotFound.selector);
        oracle.getLatestPrice(keccak256("MISSING"));
    }

    function test_GetDecimals_ReturnsCorrectValue() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        oracle.createFeed(LINK_USD, 18, 10e18);

        assertEq(oracle.getDecimals(ETH_USD), 8);
        assertEq(oracle.getDecimals(LINK_USD), 18);
    }

    // ─── Enumeration ────────────────────────────────────────────────────────

    function test_GetAllFeeds_EmptyWhenNoFeeds() public {
        (bytes32[] memory names, address[] memory feeds) = oracle.getAllFeeds();
        assertEq(names.length, 0);
        assertEq(feeds.length, 0);
    }

    function test_GetAllFeeds_ReturnsAllFeeds() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        oracle.createFeed(BTC_USD, 8, 30_000e8);
        oracle.createFeed(LINK_USD, 18, 10e18);

        (bytes32[] memory names, address[] memory feeds) = oracle.getAllFeeds();
        assertEq(names.length, 3);
        assertEq(feeds.length, 3);

        assertEq(names[0], ETH_USD);
        assertEq(names[1], BTC_USD);
        assertEq(names[2], LINK_USD);

        for (uint256 i = 0; i < names.length; i++) {
            assertEq(feeds[i], oracle.getFeed(names[i]));
        }
    }

    function test_GetFeedCount_Increments() public {
        assertEq(oracle.getFeedCount(), 0);
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        assertEq(oracle.getFeedCount(), 1);
        oracle.createFeed(BTC_USD, 8, 30_000e8);
        assertEq(oracle.getFeedCount(), 2);
    }

    // ─── Integration: Scenario Tests ────────────────────────────────────────

    /// @dev Simulate a typical market crash scenario
    function test_Scenario_MarketCrash() public {
        // Setup feeds at normal prices
        oracle.createFeed(ETH_USD, 8, 2_000e8);
        oracle.createFeed(BTC_USD, 8, 30_000e8);
        oracle.createFeed(LINK_USD, 18, 10e18);

        // Market crashes: everything drops 50%
        bytes32[] memory names = new bytes32[](3);
        names[0] = ETH_USD;
        names[1] = BTC_USD;
        names[2] = LINK_USD;

        int256[] memory prices = new int256[](3);
        prices[0] = 1_000e8;
        prices[1] = 15_000e8;
        prices[2] = 5e18;

        oracle.batchSetPrices(names, prices);

        assertEq(oracle.getLatestPrice(ETH_USD), 1_000e8);
        assertEq(oracle.getLatestPrice(BTC_USD), 15_000e8);
        assertEq(oracle.getLatestPrice(LINK_USD), 5e18);
    }

    /// @dev Simulate a gradual price pump across multiple blocks
    function test_Scenario_GradualPump() public {
        oracle.createFeed(ETH_USD, 8, 2_000e8);

        int256[] memory steps = new int256[](5);
        steps[0] = 2_100e8;
        steps[1] = 2_200e8;
        steps[2] = 2_300e8;
        steps[3] = 2_400e8;
        steps[4] = 2_500e8;

        for (uint256 i = 0; i < steps.length; i++) {
            vm.warp(block.timestamp + 12);
            oracle.setPrice(ETH_USD, steps[i]);
        }

        (uint80 roundId,,,,) = oracle.getLatestRoundData(ETH_USD);
        // 1 initial + 5 updates = 6 rounds
        assertEq(roundId, 6);
        assertEq(oracle.getLatestPrice(ETH_USD), 2_500e8);
    }

    /// @dev Verify MockOracle works seamlessly with external contracts expecting AggregatorV3Interface
    function test_Integration_UnderlyingFeedIsValidAggregatorV3() public {
        address feedAddr = oracle.createFeed(ETH_USD, 8, 2_000e8);
        MockAggregatorV3 feed = MockAggregatorV3(feedAddr);

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 2_000e8);

        oracle.setPrice(ETH_USD, 3_000e8);

        (, answer,,,) = feed.latestRoundData();
        assertEq(answer, 3_000e8);
    }
}
