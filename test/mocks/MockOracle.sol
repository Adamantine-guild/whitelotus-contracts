// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";

/// @title MockOracle - Multi-feed price oracle for local testing
/// @notice Wraps MockAggregatorV3 to manage multiple named price feeds and
///         enable seamless price scenario configuration in test suites.
/// @dev Never deploy this to production.
contract MockOracle {
    error FeedAlreadyExists();
    error FeedNotFound();
    error LengthMismatch();

    // ─── State ──────────────────────────────────────────────────────────────

    /// @notice Named feeds: bytes32 key → MockAggregatorV3 address
    mapping(bytes32 => address) private _feeds;

    /// @notice Ordered list of feed names for enumeration
    bytes32[] private _feedNames;

    // ─── Events ─────────────────────────────────────────────────────────────

    event FeedCreated(bytes32 indexed name, address indexed feed, uint8 decimals, int256 initialPrice);
    event PriceUpdated(bytes32 indexed name, int256 newPrice, address indexed feed);
    event BatchPricesUpdated(uint256 count);

    // ─── Feed Management ────────────────────────────────────────────────────

    /// @notice Create a named price feed with the given decimals and initial price.
    /// @param name  bytes32 identifier for the feed (e.g. keccak256("ETH/USD")).
    /// @param decimals  Number of decimals for the price feed (e.g. 8 or 18).
    /// @param initialPrice  Starting price in the feed's native decimals.
    /// @return feed  Address of the deployed MockAggregatorV3.
    function createFeed(bytes32 name, uint8 decimals, int256 initialPrice) external returns (address feed) {
        if (_feeds[name] != address(0)) revert FeedAlreadyExists();

        feed = address(new MockAggregatorV3(decimals, initialPrice));
        _feeds[name] = feed;
        _feedNames.push(name);

        emit FeedCreated(name, feed, decimals, initialPrice);
    }

    /// @notice Ensure a feed exists, creating it if not. Useful for idempotent setup.
    /// @return feed  Address of the (possibly newly created) MockAggregatorV3.
    function getOrCreateFeed(bytes32 name, uint8 decimals, int256 initialPrice)
        external
        returns (address feed)
    {
        feed = _feeds[name];
        if (feed == address(0)) {
            feed = address(new MockAggregatorV3(decimals, initialPrice));
            _feeds[name] = feed;
            _feedNames.push(name);
            emit FeedCreated(name, feed, decimals, initialPrice);
        }
    }

    // ─── Price Operations ───────────────────────────────────────────────────

    /// @notice Update the price of a single named feed.
    function setPrice(bytes32 name, int256 price) external {
        address feed = _feeds[name];
        if (feed == address(0)) revert FeedNotFound();

        MockAggregatorV3(feed).setLatestAnswer(price);
        emit PriceUpdated(name, price, feed);
    }

    /// @notice Batch-update multiple feed prices in a single transaction.
    function batchSetPrices(bytes32[] calldata names, int256[] calldata prices) external {
        uint256 len = names.length;
        if (len != prices.length) revert LengthMismatch();

        for (uint256 i = 0; i < len; i++) {
            address feed = _feeds[names[i]];
            if (feed == address(0)) revert FeedNotFound();
            MockAggregatorV3(feed).setLatestAnswer(prices[i]);
        }

        emit BatchPricesUpdated(len);
    }

    // ─── Read Helpers ───────────────────────────────────────────────────────

    /// @notice Get the address of a named feed. Reverts if not found.
    function getFeed(bytes32 name) external view returns (address) {
        address feed = _feeds[name];
        if (feed == address(0)) revert FeedNotFound();
        return feed;
    }

    /// @notice Get the latest price from a named feed as an int256. Reverts if not found.
    function getLatestPrice(bytes32 name) external view returns (int256) {
        address feed = _feeds[name];
        if (feed == address(0)) revert FeedNotFound();
        (, int256 answer,,,) = MockAggregatorV3(feed).latestRoundData();
        return answer;
    }

    /// @notice Get the latest round data from a named feed. Reverts if not found.
    function getLatestRoundData(bytes32 name)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        address feed = _feeds[name];
        if (feed == address(0)) revert FeedNotFound();
        return MockAggregatorV3(feed).latestRoundData();
    }

    /// @notice Get the AggregatorV3Interface-compliant decimals of a named feed.
    function getDecimals(bytes32 name) external view returns (uint8) {
        address feed = _feeds[name];
        if (feed == address(0)) revert FeedNotFound();
        return MockAggregatorV3(feed).decimals();
    }

    /// @notice Check whether a named feed exists.
    function hasFeed(bytes32 name) external view returns (bool) {
        return _feeds[name] != address(0);
    }

    /// @notice Enumerate all registered feed names and their addresses.
    function getAllFeeds() external view returns (bytes32[] memory names, address[] memory feeds) {
        uint256 len = _feedNames.length;
        names = new bytes32[](len);
        feeds = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 n = _feedNames[i];
            names[i] = n;
            feeds[i] = _feeds[n];
        }
    }

    /// @notice Return the total number of registered feeds.
    function getFeedCount() external view returns (uint256) {
        return _feedNames.length;
    }
}
