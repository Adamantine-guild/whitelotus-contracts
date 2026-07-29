// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {LogPriceMath} from "../libraries/LogPriceMath.sol";

/// @title TWAPOracle - Manipulation-resistant time-weighted average price oracle
/// @notice Records cumulative log-price checkpoints on AMM pool interactions and serves geometric
///         mean prices over a caller-supplied lookback window.
/// @dev A registered pool calls {record} with its spot price at the end of every state-changing
///      interaction. Each checkpoint stores `sum(log2(price) * secondsHeld)`, so a price only
///      influences the average in proportion to the wall-clock time it actually persisted. A spike
///      created and unwound inside a single block is held for zero seconds and therefore carries
///      zero weight, which is what defeats block-local flash loan manipulation.
///
///      Queries interpolate between the two checkpoints surrounding the requested timestamp and
///      revert rather than degrade when the ring buffer cannot cover the window or when the data
///      around the target is too sparse to interpolate meaningfully.
contract TWAPOracle is Ownable {
    /// @notice A cumulative log-price checkpoint.
    /// @param blockTimestamp      Timestamp at which the checkpoint was taken.
    /// @param logPriceCumulative  Running sum of `log2(price) * secondsElapsed` in Q64.64.
    ///                            `log2` of any `uint256` price is below 2^72 in Q64.64, so even
    ///                            accumulating over the full `uint32` timestamp range stays under
    ///                            2^104 and cannot overflow.
    /// @param initialized         False for ring buffer slots that have never been written.
    struct Observation {
        uint32 blockTimestamp;
        uint128 logPriceCumulative;
        bool initialized;
    }

    /// @param token0            Base token of the pool; prices are quoted as token1 per token0.
    /// @param index             Ring buffer slot holding the most recent checkpoint.
    /// @param cardinality       Number of slots currently in use.
    /// @param cardinalityTarget Number of slots the buffer is growing towards.
    /// @param registered        Whether the pool may write checkpoints.
    /// @param token1            Quote token of the pool.
    /// @param logPriceLast      `log2` of the most recently reported spot price, in Q64.64. Used to
    ///                          extend the newest checkpoint up to the current block on read.
    struct PoolState {
        address token0;
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityTarget;
        bool registered;
        address token1;
        uint96 logPriceLast;
    }

    /// @notice Fixed-point scale used for spot prices and quotes.
    uint256 public constant PRECISION = 1e18;

    /// @notice Window the ring buffer is automatically grown to cover.
    uint32 public targetWindow;

    /// @notice Largest tolerated distance between two consecutive checkpoints. Queries whose target
    ///         falls inside a longer gap, and queries against a pool that has been idle for longer
    ///         than this, are rejected as unreliable.
    uint32 public maxObservationGap;

    mapping(address => PoolState) public pools;

    mapping(address => mapping(uint256 => Observation)) private _observations;

    event PoolRegistered(address indexed pool, address indexed token0, address indexed token1);
    event PriceRecorded(
        address indexed pool, uint32 blockTimestamp, uint256 price, uint256 logPriceCumulative
    );
    event ObservationCardinalityIncreased(address indexed pool, uint16 previous, uint16 next);
    event ConfigUpdated(uint32 targetWindow, uint32 maxObservationGap);

    error ZeroAddress();
    error IdenticalTokens();
    error InvalidConfig();
    error InvalidPrice();
    error InvalidWindow(uint32 window);
    error PoolAlreadyRegistered(address pool);
    error PoolNotRegistered(address pool);
    error OracleNotInitialized(address pool);
    error UnknownToken(address pool, address token);
    error InsufficientHistory(address pool, uint32 available, uint32 requested);
    error SparseObservations(address pool, uint32 gap, uint32 maxGap);

    /// @param _targetWindow      Lookback window the buffer should be able to serve, in seconds.
    /// @param _maxObservationGap Longest tolerated gap between consecutive checkpoints, in seconds.
    /// @param owner_             Address allowed to register pools and update configuration.
    constructor(uint32 _targetWindow, uint32 _maxObservationGap, address owner_) Ownable() {
        if (owner_ != msg.sender) _transferOwnership(owner_);
        _setConfig(_targetWindow, _maxObservationGap);
    }

    /// @notice Update the target window and the maximum tolerated checkpoint gap.
    function setConfig(uint32 _targetWindow, uint32 _maxObservationGap) external onlyOwner {
        _setConfig(_targetWindow, _maxObservationGap);
    }

    /// @notice Allow `pool` to record checkpoints and bind it to the pair it prices.
    /// @param pool   The AMM pool contract that will call {record}.
    /// @param token0 Base token; {record} reports the price of one `token0` in `token1`.
    /// @param token1 Quote token.
    function registerPool(address pool, address token0, address token1) external onlyOwner {
        if (pool == address(0) || token0 == address(0) || token1 == address(0)) {
            revert ZeroAddress();
        }
        if (token0 == token1) revert IdenticalTokens();
        if (pools[pool].registered) revert PoolAlreadyRegistered(pool);

        pools[pool] = PoolState({
            token0: token0,
            index: 0,
            cardinality: 0,
            cardinalityTarget: 0,
            registered: true,
            token1: token1,
            logPriceLast: 0
        });

        emit PoolRegistered(pool, token0, token1);
    }

    /// @notice Record the calling pool's spot price.
    /// @dev Must be called at the end of every interaction that moves the pool's price. The
    ///      previously reported price is what gets weighted by the elapsed time, so a price that
    ///      never survives a block boundary contributes nothing to the accumulator. Repeat calls
    ///      within one block refresh the price used for read-time extrapolation but do not create
    ///      a checkpoint, since no time has passed to weight.
    /// @param price Spot price of one `token0` in `token1`, scaled by {PRECISION}.
    function record(uint256 price) external {
        PoolState storage state = pools[msg.sender];
        if (!state.registered) revert PoolNotRegistered(msg.sender);
        if (price == 0) revert InvalidPrice();

        uint32 timestamp = uint32(block.timestamp);

        if (state.cardinality == 0) {
            _observations[msg.sender][0] =
                Observation({blockTimestamp: timestamp, logPriceCumulative: 0, initialized: true});
            state.cardinality = 1;
            state.cardinalityTarget = 1;
            emit PriceRecorded(msg.sender, timestamp, price, 0);
            _growCardinalityTarget(state, msg.sender, timestamp);
        } else {
            Observation memory last = _observations[msg.sender][state.index];
            if (timestamp > last.blockTimestamp) {
                _write(state, msg.sender, _extend(last, timestamp, state.logPriceLast), price);
            }
        }

        state.logPriceLast = uint96(LogPriceMath.log2(price));
    }

    /// @notice Geometric mean price of `token0` in `token1` over the trailing `window` seconds.
    /// @param pool   The registered pool to query.
    /// @param window Lookback window in seconds.
    /// @return price The time-weighted average price, scaled by {PRECISION}.
    function consult(address pool, uint32 window) public view returns (uint256 price) {
        PoolState storage state = pools[pool];
        if (!state.registered) revert PoolNotRegistered(pool);
        if (state.cardinality == 0) revert OracleNotInitialized(pool);
        if (window == 0) revert InvalidWindow(window);

        uint32 timestamp = uint32(block.timestamp);
        uint256 endCumulative = _observeSingle(pool, state, 0, timestamp);
        uint256 startCumulative = _observeSingle(pool, state, window, timestamp);

        price = LogPriceMath.exp2((endCumulative - startCumulative) / window);
    }

    /// @notice Value `amountIn` of `tokenIn` in the pool's other token at the TWAP.
    /// @param pool     The registered pool to query.
    /// @param tokenIn  Either side of the pool's pair.
    /// @param amountIn Amount of `tokenIn` to value.
    /// @param window   Lookback window in seconds.
    /// @return amountOut Equivalent amount of the opposite token.
    function quote(address pool, address tokenIn, uint256 amountIn, uint32 window)
        external
        view
        returns (uint256 amountOut)
    {
        uint256 price = consult(pool, window);
        PoolState storage state = pools[pool];

        if (tokenIn == state.token0) {
            amountOut = (amountIn * price) / PRECISION;
        } else if (tokenIn == state.token1) {
            amountOut = (amountIn * PRECISION) / price;
        } else {
            revert UnknownToken(pool, tokenIn);
        }
    }

    /// @notice Cumulative log-price at each of the requested points in the past.
    /// @param pool        The registered pool to query.
    /// @param secondsAgos How far back each returned value should be measured, in seconds.
    /// @return logPriceCumulatives Accumulator values in Q64.64 seconds.
    function observe(address pool, uint32[] calldata secondsAgos)
        external
        view
        returns (uint256[] memory logPriceCumulatives)
    {
        PoolState storage state = pools[pool];
        if (!state.registered) revert PoolNotRegistered(pool);
        if (state.cardinality == 0) revert OracleNotInitialized(pool);

        uint32 timestamp = uint32(block.timestamp);
        logPriceCumulatives = new uint256[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            logPriceCumulatives[i] = _observeSingle(pool, state, secondsAgos[i], timestamp);
        }
    }

    /// @notice Read a raw ring buffer slot.
    function getObservation(address pool, uint16 index) external view returns (Observation memory) {
        return _observations[pool][index];
    }

    /// @notice Seconds of price history the ring buffer currently holds.
    function observationSpan(address pool) external view returns (uint32) {
        PoolState storage state = pools[pool];
        uint16 cardinality = state.cardinality;
        if (cardinality == 0) return 0;

        Observation memory oldest = _oldestObservation(pool, state.index, cardinality);
        return _observations[pool][state.index].blockTimestamp - oldest.blockTimestamp;
    }

    function _setConfig(uint32 _targetWindow, uint32 _maxObservationGap) private {
        if (_targetWindow == 0 || _maxObservationGap == 0) revert InvalidConfig();
        targetWindow = _targetWindow;
        maxObservationGap = _maxObservationGap;
        emit ConfigUpdated(_targetWindow, _maxObservationGap);
    }

    /// @dev Append `observation` to the ring buffer, absorbing any pending cardinality growth.
    ///      Growth is only absorbed when the write wraps past the end of the buffer, which keeps
    ///      the slots in chronological order and lets a binary search treat the buffer as sorted.
    function _write(
        PoolState storage state,
        address pool,
        Observation memory observation,
        uint256 price
    ) private {
        uint16 cardinality = state.cardinality;
        uint16 index = state.index;
        uint16 target = state.cardinalityTarget;

        uint16 cardinalityUpdated =
            target > cardinality && index == cardinality - 1 ? target : cardinality;
        uint16 indexUpdated = uint16((uint256(index) + 1) % cardinalityUpdated);

        _observations[pool][indexUpdated] = observation;
        state.index = indexUpdated;
        if (cardinalityUpdated != cardinality) state.cardinality = cardinalityUpdated;

        emit PriceRecorded(pool, observation.blockTimestamp, price, observation.logPriceCumulative);

        _growCardinalityTarget(state, pool, observation.blockTimestamp);
    }

    /// @dev Raise the cardinality target whenever a saturated buffer no longer spans
    ///      {targetWindow}. Doubling keeps the number of growth steps logarithmic, and the check
    ///      stops firing as soon as the buffer covers the window, so the oracle sizes itself to
    ///      the pool's actual interaction frequency without any operator input.
    function _growCardinalityTarget(PoolState storage state, address pool, uint32 timestamp)
        private
    {
        uint16 cardinality = state.cardinality;
        if (cardinality != state.cardinalityTarget) return;
        if (cardinality == type(uint16).max) return;

        Observation memory oldest = _observations[pool][(uint256(state.index) + 1) % cardinality];
        if (!oldest.initialized) return;
        if (timestamp - oldest.blockTimestamp >= targetWindow) return;

        uint16 next = cardinality > type(uint16).max / 2 ? type(uint16).max : cardinality * 2;
        state.cardinalityTarget = next;

        emit ObservationCardinalityIncreased(pool, cardinality, next);
    }

    /// @dev Carry `last` forward to `timestamp` at the last reported price.
    function _extend(Observation memory last, uint32 timestamp, uint96 logPriceLast)
        private
        pure
        returns (Observation memory)
    {
        return Observation({
            blockTimestamp: timestamp,
            logPriceCumulative: last.logPriceCumulative
                + uint128(uint256(logPriceLast) * (timestamp - last.blockTimestamp)),
            initialized: true
        });
    }

    function _observeSingle(
        address pool,
        PoolState storage state,
        uint32 secondsAgo,
        uint32 timestamp
    ) private view returns (uint256) {
        Observation memory last = _observations[pool][state.index];

        if (secondsAgo == 0) {
            uint32 age = timestamp - last.blockTimestamp;
            if (age > maxObservationGap) revert SparseObservations(pool, age, maxObservationGap);
            return _extend(last, timestamp, state.logPriceLast).logPriceCumulative;
        }

        if (secondsAgo > timestamp) revert InvalidWindow(secondsAgo);

        uint32 target = timestamp - secondsAgo;
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            _surroundingObservations(pool, state, last, target, timestamp, secondsAgo);

        if (target == beforeOrAt.blockTimestamp) return beforeOrAt.logPriceCumulative;
        if (target == atOrAfter.blockTimestamp) return atOrAfter.logPriceCumulative;

        uint32 gap = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
        if (gap > maxObservationGap) revert SparseObservations(pool, gap, maxObservationGap);

        uint256 cumulativeDelta = atOrAfter.logPriceCumulative - beforeOrAt.logPriceCumulative;
        return beforeOrAt.logPriceCumulative
            + (cumulativeDelta * (target - beforeOrAt.blockTimestamp)) / gap;
    }

    /// @dev Locate the checkpoints bracketing `target`, reverting when the buffer starts after it.
    function _surroundingObservations(
        address pool,
        PoolState storage state,
        Observation memory last,
        uint32 target,
        uint32 timestamp,
        uint32 secondsAgo
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        if (last.blockTimestamp <= target) {
            return (last, _extend(last, timestamp, state.logPriceLast));
        }

        uint16 cardinality = state.cardinality;
        Observation memory oldest = _oldestObservation(pool, state.index, cardinality);
        if (oldest.blockTimestamp > target) {
            revert InsufficientHistory(pool, timestamp - oldest.blockTimestamp, secondsAgo);
        }

        return _binarySearch(pool, state.index, cardinality, target);
    }

    function _oldestObservation(address pool, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory oldest)
    {
        oldest = _observations[pool][(uint256(index) + 1) % cardinality];
        if (!oldest.initialized) oldest = _observations[pool][0];
    }

    /// @dev Binary search over the ring buffer, which is sorted by timestamp when traversed from
    ///      the slot after `index`. Slots that a cardinality increase has not reached yet read as
    ///      zero, sort before every real checkpoint, and are skipped.
    function _binarySearch(address pool, uint16 index, uint16 cardinality, uint32 target)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 low = uint256(index) + 1;
        uint256 high = low + cardinality - 1;

        while (true) {
            uint256 mid = (low + high) / 2;

            beforeOrAt = _observations[pool][mid % cardinality];
            if (!beforeOrAt.initialized) {
                low = mid + 1;
                continue;
            }

            atOrAfter = _observations[pool][(mid + 1) % cardinality];

            if (beforeOrAt.blockTimestamp <= target) {
                if (target <= atOrAfter.blockTimestamp) break;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
    }
}
