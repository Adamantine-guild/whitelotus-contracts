// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title TWAP - Time-Weighted Average Price Oracle
/// @notice Manipulation-resistant on-chain price oracle derived from AMM pair observations.
///         Stores cumulative prices in a ring buffer and queries at intervals to calculate
///         time-weighted averages.
/// @dev Inspired by Uniswap V2's cumulative price mechanism.
///
///      **Cumulative price tracking:**
///      On each `update()`, the cumulative price is advanced:
///          cumulativePrice += spotPrice * timeElapsed
///
///      **Ring buffer:**
///      Observations (timestamp, cumulativePrice) are stored in a fixed-size ring buffer
///      (256 entries) per pair. When the buffer is full, the oldest entry is overwritten.
///
///      **TWAP computation:**
///      To compute TWAP over a window W, the oracle finds the observation at or just
///      before (now - W) and computes:
///          TWAP = (cumulativePrice_now - cumulativePrice_old) / (now - oldTimestamp)
///
///      **Security model:**
///      - `update()` is restricted to authorized callers (typically the AMM/pool contract).
///        The AMM MUST call `update()` at the *beginning* of each state-changing operation
///        (swap, mint, burn), BEFORE the spot price changes. This ensures the pre-trade
///        price is accumulated, providing flash-loan manipulation resistance.
///      - `setConfig()` and `setAuthorized()` are owner-only.
///      - If no observation is old enough for the requested window, the query reverts
///        rather than silently falling back to a shorter (more manipulable) window.
contract TWAP is Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A single observation snapshot recording the cumulative price at a point in time.
    /// @dev Packed into a single storage slot for gas efficiency.
    ///      `uint224` safely holds cumulative price for all practical scenarios:
    ///      2^224 ≈ 2.69e67. Even at a price of 1e36 (1e18 * 1e18), accumulating over
    ///      2^32 seconds (~136 years), the cumulative would be ~4.3e45 — well within bounds.
    /// @param timestamp       Block timestamp when this observation was recorded.
    /// @param priceCumulative Cumulative price of token0 in terms of token1,
    ///                        scaled by 1e18, accumulated up to this timestamp.
    struct Observation {
        uint32 timestamp;
        uint224 priceCumulative;
    }

    /// @notice Tracks the state of a single token pair's oracle.
    /// @param observations        Fixed-size ring buffer of observations.
    /// @param index               Position in the ring buffer where the *next* observation
    ///                            will be written. When the buffer is full, this also points
    ///                            to the oldest observation.
    /// @param cardinality         Number of observations currently stored (≤ BUFFER_SIZE).
    /// @param priceCumulativeLast Most recent cumulative price value (updated continuously).
    /// @param lastUpdateTime      Timestamp of the last call to update().
    struct PairState {
        // slot 0
        uint256 priceCumulativeLast;
        // slot 1
        uint32 lastUpdateTime;
        uint16 index;
        uint16 cardinality;
        // slot 2
        uint256 lastPrice;
        // slot 3+
        Observation[256] observations;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Maximum number of observations stored per pair.
    uint256 public constant BUFFER_SIZE = 256;

    /// @notice Price scaling factor — all prices are stored with 18 decimals of precision.
    uint256 public constant PRECISION = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Minimum time (in seconds) that must elapse between consecutive observations.
    ///         Prevents the buffer from being spammed with high-frequency updates.
    uint32 public minUpdateInterval;

    /// @notice Default time window (in seconds) used when consult() is called without
    ///         an explicit window parameter.
    uint32 public defaultWindow;

    /// @notice Addresses authorized to call update(). Typically the AMM/pool contracts.
    mapping(address => bool) public isAuthorized;

    /// @notice Per-pair oracle state, keyed by keccak256(abi.encodePacked(token0, token1)).
    ///         token0 and token1 are sorted to ensure the same key regardless of order.
    mapping(bytes32 => PairState) public pairs;

    // ═══════════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════════

    event ObservationUpdated(
        bytes32 indexed pairId,
        address indexed token0,
        address indexed token1,
        uint256 price,
        uint256 cumulativePrice,
        uint32 timestamp
    );

    event PairInitialized(bytes32 indexed pairId, address indexed token0, address indexed token1);

    event ConfigUpdated(uint32 minUpdateInterval, uint32 defaultWindow);

    event AuthorizedUpdated(address indexed caller, bool authorized);

    // ═══════════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════════

    error IdenticalTokens();
    error ZeroAddress();
    error NotAuthorized(address caller);
    error PairNotInitialized(bytes32 pairId);
    error InsufficientObservations(bytes32 pairId, uint256 available, uint256 required);
    error StaleObservation(bytes32 pairId, uint32 timestamp, uint32 oldestTimestamp);
    error InvalidWindow(uint32 window);
    error InvalidPrice();
    error InsufficientWindow(bytes32 pairId, uint32 availableWindow, uint32 requestedWindow);

    // ═══════════════════════════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════════════════════════

    modifier onlyAuthorized() {
        if (!isAuthorized[msg.sender]) revert NotAuthorized(msg.sender);
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _minUpdateInterval Minimum seconds between consecutive observation writes.
    /// @param _defaultWindow     Default TWAP lookback window in seconds (e.g., 1800 for 30 min).
    /// @param _owner             Address that can manage config and authorizations.
    constructor(uint32 _minUpdateInterval, uint32 _defaultWindow, address _owner) Ownable2Step() {
        if (_owner != msg.sender) _transferOwnership(_owner);
        require(_minUpdateInterval > 0, "TWAP: zero min update interval");
        require(_defaultWindow >= _minUpdateInterval, "TWAP: window < interval");
        minUpdateInterval = _minUpdateInterval;
        defaultWindow = _defaultWindow;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Admin
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update the minimum observation interval and default TWAP window.
    function setConfig(uint32 _minUpdateInterval, uint32 _defaultWindow) external onlyOwner {
        require(_minUpdateInterval > 0, "TWAP: zero min update interval");
        require(_defaultWindow >= _minUpdateInterval, "TWAP: window < interval");
        minUpdateInterval = _minUpdateInterval;
        defaultWindow = _defaultWindow;
        emit ConfigUpdated(_minUpdateInterval, _defaultWindow);
    }

    /// @notice Authorize or deauthorize a caller (typically an AMM/pool) to call update().
    function setAuthorized(address caller, bool authorized) external onlyOwner {
        require(caller != address(0), "TWAP: zero address");
        isAuthorized[caller] = authorized;
        emit AuthorizedUpdated(caller, authorized);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Core: Update
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Update the cumulative price for a token pair.
    /// @dev Restricted to authorized callers (AMM/pool contracts).
    ///      MUST be called at the *beginning* of every state-changing AMM operation
    ///      (swap, mint, burn), BEFORE the spot price changes. This is critical for
    ///      manipulation resistance — the pre-trade price is what gets accumulated.
    ///      If called twice within `minUpdateInterval`, the cumulative price is still
    ///      advanced but no new observation is recorded.
    /// @param token0 The first token of the pair (order-independent).
    /// @param token1 The second token of the pair (order-independent).
    /// @param price  The current spot price of token0 in terms of token1, scaled by 1e18.
    /// @param priceInv The inverse spot price (token1 in terms of token0), scaled by 1e18.
    function update(address token0, address token1, uint256 price, uint256 priceInv)
        external
        onlyAuthorized
    {
        if (price == 0 || priceInv == 0) revert InvalidPrice();
        bytes32 pairId = _pairId(token0, token1);
        PairState storage pair = pairs[pairId];

        // Track the latest spot price so consult() can extend the cumulative
        // price to the current timestamp even when the pair has gone stale.
        pair.lastPrice = price;

        // ── Initialize the buffer on first call ───────────────────────────
        if (pair.lastUpdateTime == 0) {
            _initializePair(pair, pairId, token0, token1);
        }

        // ── Accumulate cumulative price ───────────────────────────────────
        uint32 timeElapsed = uint32(block.timestamp) - pair.lastUpdateTime;
        if (timeElapsed > 0) {
            pair.priceCumulativeLast += price * timeElapsed;
            pair.lastUpdateTime = uint32(block.timestamp);
        }

        // ── Write a new observation if enough time has passed ─────────────
        // Respects minUpdateInterval uniformly — the seed observation from
        // _initializePair counts as the baseline.
        Observation storage lastObs = pair.observations[_prevIndex(pair.index)];
        if (uint32(block.timestamp) - lastObs.timestamp >= minUpdateInterval) {
            _writeObservation(pair, pairId, token0, token1, price);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Core: Consult
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Consult the TWAP oracle to compute the time-weighted average price.
    /// @dev Uses the default TWAP window configured at construction or via setConfig().
    /// @param tokenIn  The input token address.
    /// @param amountIn The amount of `tokenIn` being swapped (in token's native decimals).
    /// @param tokenOut The output token address.
    /// @return amountOut The estimated amount of `tokenOut` to receive, based on TWAP.
    function consult(address tokenIn, uint256 amountIn, address tokenOut)
        external
        view
        returns (uint256 amountOut)
    {
        return _consult(tokenIn, amountIn, tokenOut, defaultWindow);
    }

    /// @notice Consult the TWAP oracle with an explicit time window.
    /// @param tokenIn  The input token address.
    /// @param amountIn The amount of `tokenIn` being swapped.
    /// @param tokenOut The output token address.
    /// @param window   The lookback window in seconds (e.g., 1800 for 30 minutes).
    /// @return amountOut The estimated amount of `tokenOut` to receive.
    function consult(address tokenIn, uint256 amountIn, address tokenOut, uint32 window)
        external
        view
        returns (uint256 amountOut)
    {
        return _consult(tokenIn, amountIn, tokenOut, window);
    }

    /// @notice Internal consult logic.
    function _consult(address tokenIn, uint256 amountIn, address tokenOut, uint32 window)
        internal
        view
        returns (uint256 amountOut)
    {
        if (window < minUpdateInterval) revert InvalidWindow(window);

        bytes32 pairId = _pairId(tokenIn, tokenOut);
        PairState storage pair = pairs[pairId];

        if (pair.lastUpdateTime == 0) revert PairNotInitialized(pairId);

        uint256 priceAverage = _computeTwap(pair, pairId, window);

        // Determine direction: is tokenIn the token0 or token1 of this pair?
        (address t0,) = _sortTokens(tokenIn, tokenOut);
        if (tokenIn == t0) {
            // tokenIn is token0, priceAverage is token0/token1
            amountOut = (amountIn * priceAverage) / PRECISION;
        } else {
            // tokenIn is token1, we need token1/token0 = PRECISION / priceAverage
            // amountOut = amountIn * (1 / priceAverage) = amountIn * PRECISION / priceAverage
            amountOut = (amountIn * PRECISION) / priceAverage;
        }
    }

    /// @notice Compute the time-weighted average price over the given window.
    /// @dev Uses the continuously-tracked `priceCumulativeLast` (with current timestamp)
    ///      as the newest data point — matching Uniswap V2's behavior of including all
    ///      accumulated price data up to the query moment.
    /// @param pair   The pair state to query.
    /// @param pairId The pair identifier (for error messages).
    /// @param window The lookback window in seconds.
    /// @return priceAverage The TWAP of token0/token1, scaled by 1e18.
    function _computeTwap(PairState storage pair, bytes32 pairId, uint32 window)
        internal
        view
        returns (uint256 priceAverage)
    {
        uint32 nowTs = uint32(block.timestamp);

        // Clamp the search target to 0 when the requested window exceeds the history
        // available on-chain (e.g. block.timestamp < window). This avoids the uint32
        // arithmetic underflow that previously produced a bare panic instead of the
        // documented InsufficientWindow revert.
        uint32 targetTimestamp = window >= nowTs ? 0 : nowTs - window;

        // Find the observation at or just before targetTimestamp using binary search.
        (Observation memory oldestObs, bool found) = _binarySearch(pair, targetTimestamp);

        if (!found) {
            // The oldest available observation (returned by _binarySearch) is newer than
            // targetTimestamp. Revert — silently falling back to a shorter window would
            // compromise manipulation resistance.
            uint32 availableWindow = nowTs - oldestObs.timestamp;
            revert InsufficientWindow(pairId, availableWindow, window);
        }

        // Extend the continuously-tracked cumulative price to the current moment using
        // the last observed spot price. Without this, a pair that has not been updated
        // recently would report a TWAP of zero (timestamp/cumulative mismatch) even
        // though real price history exists — an oracle correctness bug.
        uint256 newestCumulative = pair.priceCumulativeLast
            + pair.lastPrice * uint256(nowTs - pair.lastUpdateTime);

        uint32 timeDelta = nowTs - oldestObs.timestamp;
        if (timeDelta == 0) revert InsufficientObservations(pairId, 0, 1);

        uint256 cumulativeDelta = newestCumulative - oldestObs.priceCumulative;
        priceAverage = cumulativeDelta / timeDelta;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  View: Observe
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Retrieve the cumulative price at the current block timestamp.
    /// @param token0 First token of the pair.
    /// @param token1 Second token of the pair.
    /// @return cumulativePrice The latest cumulative price (token0/token1, scaled by 1e18).
    /// @return lastTimestamp    The timestamp of the last update.
    function currentCumulativePrice(address token0, address token1)
        external
        view
        returns (uint256 cumulativePrice, uint32 lastTimestamp)
    {
        bytes32 pairId = _pairId(token0, token1);
        PairState storage pair = pairs[pairId];
        if (pair.lastUpdateTime == 0) revert PairNotInitialized(pairId);
        return (pair.priceCumulativeLast, pair.lastUpdateTime);
    }

    /// @notice Retrieve a specific observation from the ring buffer by its logical index.
    /// @dev Logical index 0 is the oldest observation; (cardinality-1) is the newest.
    /// @param token0     First token of the pair.
    /// @param token1     Second token of the pair.
    /// @param logicalIdx Logical observation index (0 = oldest).
    /// @return observation The observation at that logical position.
    function getObservation(address token0, address token1, uint256 logicalIdx)
        external
        view
        returns (Observation memory observation)
    {
        bytes32 pairId = _pairId(token0, token1);
        PairState storage pair = pairs[pairId];
        if (pair.lastUpdateTime == 0) revert PairNotInitialized(pairId);
        if (logicalIdx >= pair.cardinality) {
            revert InsufficientObservations(pairId, pair.cardinality, logicalIdx + 1);
        }

        uint256 physicalIdx = _logicalToPhysical(pair, logicalIdx);
        observation = pair.observations[physicalIdx];
    }

    /// @notice Get the number of observations stored for a pair.
    function observationCount(address token0, address token1) external view returns (uint16) {
        bytes32 pairId = _pairId(token0, token1);
        return pairs[pairId].cardinality;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Internal: Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a pair's ring buffer with the first observation.
    function _initializePair(
        PairState storage pair,
        bytes32 pairId,
        address token0,
        address token1
    ) internal {
        pair.observations[0] = Observation({timestamp: uint32(block.timestamp), priceCumulative: 0});
        pair.index = 1;
        pair.cardinality = 1;
        pair.priceCumulativeLast = 0;
        pair.lastUpdateTime = uint32(block.timestamp);

        emit PairInitialized(pairId, token0, token1);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Internal: Observation Buffer Management
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Write a new observation to the ring buffer.
    function _writeObservation(
        PairState storage pair,
        bytes32 pairId,
        address token0,
        address token1,
        uint256 price
    ) internal {
        pair.observations[pair.index] = Observation({
            timestamp: uint32(block.timestamp),
            priceCumulative: uint224(pair.priceCumulativeLast)
        });

        emit ObservationUpdated(
            pairId, token0, token1, price, pair.priceCumulativeLast, uint32(block.timestamp)
        );

        pair.index = uint16((pair.index + 1) % BUFFER_SIZE);
        if (pair.cardinality < BUFFER_SIZE) {
            pair.cardinality++;
        }
    }

    /// @notice Find the observation at or immediately before `targetTimestamp` using binary search.
    /// @param pair            The pair state to search.
    /// @param targetTimestamp The timestamp to search for.
    /// @return obs  The observation at or just before targetTimestamp.
    /// @return found True if an observation at or before targetTimestamp was found.
    function _binarySearch(PairState storage pair, uint32 targetTimestamp)
        internal
        view
        returns (Observation memory obs, bool found)
    {
        uint256 oldestLogical = 0;
        uint256 newestLogical = pair.cardinality - 1;
        uint256 oldestPhysical = _logicalToPhysical(pair, oldestLogical);

        // If the oldest observation is already newer than target, window can't be satisfied.
        if (pair.observations[oldestPhysical].timestamp > targetTimestamp) {
            return (pair.observations[oldestPhysical], false);
        }

        // Standard binary search on the logical (chronological) index space
        // to find the rightmost observation with timestamp <= targetTimestamp.
        uint256 low = oldestLogical;
        uint256 high = newestLogical;

        while (low < high) {
            uint256 mid = (low + high + 1) / 2; // ceiling division for upper-bound search
            uint256 midPhysical = _logicalToPhysical(pair, mid);
            if (pair.observations[midPhysical].timestamp <= targetTimestamp) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        uint256 resultPhysical = _logicalToPhysical(pair, low);
        return (pair.observations[resultPhysical], true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Internal: Ring Buffer Indexing Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get the physical index of the oldest observation in the ring buffer.
    function _oldestIndex(PairState storage pair) internal view returns (uint256) {
        if (pair.cardinality < BUFFER_SIZE) {
            return 0;
        }
        // When full, the oldest is at `index` (which points to the next write slot,
        // i.e., the slot that was written earliest and will be overwritten next).
        return pair.index;
    }

    /// @notice Convert a logical (chronological) observation index to a physical buffer index.
    /// @param logicalIdx 0 = oldest, (cardinality - 1) = newest.
    function _logicalToPhysical(PairState storage pair, uint256 logicalIdx)
        internal
        view
        returns (uint256)
    {
        return (_oldestIndex(pair) + logicalIdx) % BUFFER_SIZE;
    }

    /// @notice Get the physical index of the previous observation (one before `idx`).
    function _prevIndex(uint256 idx) internal pure returns (uint256) {
        return (idx + BUFFER_SIZE - 1) % BUFFER_SIZE;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Internal: Pair ID
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Compute a deterministic pair ID from two token addresses.
    ///         Tokens are sorted so that (A,B) and (B,A) produce the same key.
    function _pairId(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address t0, address t1) = _sortTokens(tokenA, tokenB);
        return keccak256(abi.encodePacked(t0, t1));
    }

    /// @notice Sort two token addresses in ascending order.
    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA == tokenB) revert IdenticalTokens();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
