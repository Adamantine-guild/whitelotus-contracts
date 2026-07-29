// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";

contract MockAggregatorV3Test is Test {
    function test_ConstructorSetsDecimalsAndInitialAnswer_8Decimals() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 2_000e8);

        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "MockAggregatorV3");
        assertEq(feed.version(), 1);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answer, 2_000e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);
    }

    function test_ConstructorSupports18Decimals() public {
        MockAggregatorV3 feed = new MockAggregatorV3(18, 1e18);
        assertEq(feed.decimals(), 18);

        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 1e18);
    }

    function test_SetLatestAnswerUpdatesRoundAndTimestamp() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1_000e8);

        vm.warp(block.timestamp + 100);
        feed.setLatestAnswer(1_500e8);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(roundId, 2);
        assertEq(answer, 1_500e8);
        assertEq(startedAt, block.timestamp);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, 2);

        (uint80 storedRound, int256 storedAnswer,,,) = feed.getRoundData(2);
        assertEq(storedRound, 2);
        assertEq(storedAnswer, 1_500e8);
    }

    function test_MultiplePriceUpdatesAcrossBlocks() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1_000e8);

        vm.warp(block.timestamp + 12);
        feed.setLatestAnswer(900e8);

        vm.warp(block.timestamp + 12);
        feed.setLatestAnswer(1_100e8);

        (uint80 roundId, int256 answer,,,) = feed.latestRoundData();
        assertEq(roundId, 3);
        assertEq(answer, 1_100e8);
    }

    function test_GetRoundDataRevertsForUnknownRound() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1_000e8);
        vm.expectRevert(MockAggregatorV3.RoundNotFound.selector);
        feed.getRoundData(99);
    }
}
