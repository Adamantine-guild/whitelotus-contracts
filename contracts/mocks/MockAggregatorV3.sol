// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Chainlink AggregatorV3Interface for local testing.
/// @dev Inline interface so tests do not require a Chainlink package dependency.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

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

/// @title MockAggregatorV3 - Controllable price feed for local test suites
/// @dev Never deploy this to production. Any caller can overwrite the latest answer.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private immutable _decimals;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _setAnswer(initialAnswer);
    }

    /// @notice Force-update the latest answer (tests only).
    function setLatestAnswer(int256 answer_) external {
        _setAnswer(answer_);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockAggregatorV3";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId_)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Minimal mock: only the latest round is retained.
        require(roundId_ == _roundId, "MockAggregatorV3: round not found");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function _setAnswer(int256 answer_) private {
        unchecked {
            _roundId += 1;
        }
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }
}
