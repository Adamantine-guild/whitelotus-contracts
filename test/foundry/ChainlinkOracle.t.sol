// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";
import {ChainlinkOracle} from "../../contracts/oracles/ChainlinkOracle.sol";
import {CDPEngine, IMintableERC20} from "../../contracts/lending/CDPEngine.sol";

/// @notice Malicious aggregator for the incomplete-round case: reports the latest round but
///         claims it was answered in an earlier round (simulates an unfinished round).
contract IncompleteRoundAggregator {
    uint8 public immutable decimals;
    uint80 public roundId = 100;
    int256 public answer = 1_000 * 1e8;
    uint256 public updatedAt;
    uint80 public answeredInRound = 99; // one round behind → incomplete

    constructor(uint8 decimals_) {
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

contract ChainlinkOracleTest is Test {
    MockERC20 internal wbtc; // 8 decimals
    MockERC20 internal stablecoin;
    MockAggregatorV3 internal wbtcFeed; // 8 decimals, $30k
    MockAggregatorV3 internal linkFeed; // 18 decimals, $10

    CDPEngine internal engine;
    address internal admin = address(0x1111);
    address internal user = address(0x2222);

    function setUp() public {
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        stablecoin = new MockERC20("Lotus Stablecoin", "LUSD", 18);
        wbtcFeed = new MockAggregatorV3(8, 30_000 * 10 ** 8);
        linkFeed = new MockAggregatorV3(18, 10 * 10 ** 18);

        engine = new CDPEngine(IMintableERC20(address(stablecoin)), admin);

        vm.startPrank(admin);
        engine.whitelistCollateral(address(wbtc), 1.5 * 1e18, 1.1 * 1e18);
        engine.setPriceFeed(address(wbtc), address(wbtcFeed));
        vm.stopPrank();
    }

    // ─── Fresh price reads ──────────────────────────────────────────────────

    function testReadsFreshPrice8Decimals() public view {
        // 30_000 * 1e8 with 8 decimals → normalized 30_000e18
        assertEq(engine.getNormalizedPrice(address(wbtc)), 30_000 * 1e18);
    }

    function testReadsFreshPrice18Decimals() public view {
        // 18-decimal feed (LINK-style): $10 → normalized 10e18, unchanged.
        assertEq(ChainlinkOracle.readPrice(address(linkFeed), 3600), 10 * 1e18);
    }

    function testDefaultHeartbeatIs3600() public view {
        assertEq(engine.getHeartbeat(address(wbtc)), 3600);
    }

    // ─── Staleness (acceptance criterion 1: out-of-date → immediate revert) ─

    function testRevertsStalePrice() public {
        vm.warp(block.timestamp + 3601); // 1s past the default heartbeat
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.StalePrice.selector, block.timestamp - 3601, 3600)
        );
        engine.getNormalizedPrice(address(wbtc));
    }

    function testRevertsStaleCustomHeartbeat() public {
        vm.startPrank(admin);
        engine.setHeartbeat(address(wbtc), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + 100); // exactly at custom heartbeat → fresh
        assertEq(engine.getNormalizedPrice(address(wbtc)), 30_000 * 1e18);

        vm.warp(block.timestamp + 1); // 1s past → stale
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.StalePrice.selector, block.timestamp - 101, 100)
        );
        engine.getNormalizedPrice(address(wbtc));
    }

    function testStalePriceRevertsOnBorrow() public {
        // Integration: a stale feed must make the whole borrow transaction revert.
        wbtc.mint(user, 10 * 10 ** 8);
        vm.startPrank(user);
        wbtc.approve(address(engine), type(uint256).max);
        engine.depositCollateral(address(wbtc), 10 * 10 ** 8);
        vm.stopPrank();

        vm.warp(block.timestamp + 3601); // feed now stale
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.StalePrice.selector, block.timestamp - 3601, 3600)
        );
        engine.borrow(address(wbtc), 100 * 1e18);
        vm.stopPrank();
    }

    // ─── Round completeness ─────────────────────────────────────────────────

    function testRevertsIncompleteRound() public {
        IncompleteRoundAggregator aggregator = new IncompleteRoundAggregator(8);
        vm.startPrank(admin);
        engine.setPriceFeed(address(wbtc), address(aggregator));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracle.IncompleteRound.selector, uint80(100), uint80(99)
            )
        );
        engine.getNormalizedPrice(address(wbtc));
    }

    // ─── Price bounds (zero / negative) ─────────────────────────────────────

    function testRevertsZeroPrice() public {
        wbtcFeed.setLatestAnswer(0);
        vm.expectRevert(ChainlinkOracle.NonPositivePrice.selector);
        engine.getNormalizedPrice(address(wbtc));
    }

    function testRevertsNegativePrice() public {
        wbtcFeed.setLatestAnswer(-1);
        vm.expectRevert(ChainlinkOracle.NonPositivePrice.selector);
        engine.getNormalizedPrice(address(wbtc));
    }

    function testFeedWithNoUpdatesReverts() public {
        // A feed that has never recorded an update (updatedAt == 0) must revert.
        NeverUpdatedAggregator aggregator = new NeverUpdatedAggregator(8);
        vm.startPrank(admin);
        engine.setPriceFeed(address(wbtc), address(aggregator));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.StalePrice.selector, uint256(0), uint256(3600))
        );
        engine.getNormalizedPrice(address(wbtc));
    }

    // ─── Governance / heartbeat configuration ───────────────────────────────

    function testSetHeartbeatOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        engine.setHeartbeat(address(wbtc), 100);
    }

    function testSetHeartbeatRejectsZero() public {
        vm.startPrank(admin);
        vm.expectRevert(CDPEngine.InvalidHeartbeat.selector);
        engine.setHeartbeat(address(wbtc), 0);
        vm.stopPrank();
    }

    function testSetHeartbeatEmitsEvent() public {
        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true);
        emit CDPEngine.HeartbeatSet(address(wbtc), 120);
        engine.setHeartbeat(address(wbtc), 120);
        vm.stopPrank();
        assertEq(engine.heartbeats(address(wbtc)), 120);
        assertEq(engine.getHeartbeat(address(wbtc)), 120);
    }
}

/// @notice Aggregator whose `updatedAt` is never set (flatlined feed from deployment).
contract NeverUpdatedAggregator {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80)
    {
        return (1, 1_000 * 1e8, 0, 0, 1);
    }
}
