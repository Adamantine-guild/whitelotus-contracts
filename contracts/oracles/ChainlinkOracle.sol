// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink AggregatorV3Interface consumed by {ChainlinkOracle}.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title ChainlinkOracle - Secure Chainlink price feed wrapper with staleness validation
/// @notice Reads a Chainlink aggregator and reverts unless the round is complete, the price is
///         fresh (within the per-asset heartbeat window) and strictly positive, and the reported
///         answer is not zero or negative.
/// @dev All validation happens here so every consumer (CDPEngine, Liquidator, ...) inherits the
///      same guarantees. Feed addresses and heartbeat windows are configuration owned by the
///      consumer contract; the heartbeat is governance-adjustable per asset.
///
///      Validation follows the standard Chainlink consumer pattern:
///      - `answeredInRound >= roundId`  → the round the answer was computed in is complete
///      - `updatedAt > 0` and `block.timestamp - updatedAt <= heartbeat` → not stale / not flatlined
///      - `answer > 0`                  → strictly positive price bound (rejects 0 and negatives)
library ChainlinkOracle {
    error InvalidFeed();
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error StalePrice(uint256 updatedAt, uint256 heartbeat);
    error NonPositivePrice();

    /// @notice Read the latest validated price from `feed`, normalized to 18 decimals.
    /// @param feed      The Chainlink aggregator to read.
    /// @param heartbeat Maximum acceptable age of the last update, in seconds.
    /// @return price    The validated price, scaled to 18 decimals.
    function readPrice(address feed, uint256 heartbeat) internal view returns (uint256 price) {
        if (feed == address(0)) revert InvalidFeed();
        if (heartbeat == 0) revert InvalidFeed();

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();

        // Round completeness: the answer must have been computed in the same round it was
        // reported from (or a later one). A lower `answeredInRound` means the round is still
        // open and the answer is provisional.
        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);

        // Freshness: reject feeds that have never updated, or whose last update is older than
        // the per-asset heartbeat window. This is the primary defense against stale/flatlined
        // prices being used to sandwich the protocol during volatility or outages.
        if (updatedAt == 0 || updatedAt + heartbeat < block.timestamp) {
            revert StalePrice(updatedAt, heartbeat);
        }

        // Strictly positive bound: zero or negative answers (e.g. a broken feed, or a
        // malformed aggregator) must never reach a pricing decision.
        if (answer <= 0) revert NonPositivePrice();

        uint8 decimals = AggregatorV3Interface(feed).decimals();
        if (decimals == 18) {
            price = uint256(answer);
        } else if (decimals < 18) {
            price = uint256(answer) * 10 ** (18 - decimals);
        } else {
            price = uint256(answer) / 10 ** (decimals - 18);
        }
    }
}
