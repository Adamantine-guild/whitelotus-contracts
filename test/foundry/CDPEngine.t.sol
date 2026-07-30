// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";
import {CDPEngine, IMintableERC20} from "../../contracts/lending/CDPEngine.sol";
import {Liquidator} from "../../contracts/lending/Liquidator.sol";

contract CDPEngineTest is Test {
    MockERC20 internal wbtc;
    MockERC20 internal ethCollateral;
    MockERC20 internal link;
    MockERC20 internal stablecoin;

    MockAggregatorV3 internal wbtcFeed;
    MockAggregatorV3 internal ethFeed;
    MockAggregatorV3 internal linkFeed;

    CDPEngine internal engine;
    Liquidator internal liquidator;

    address internal admin = address(0x1111);
    address internal user = address(0x2222);
    address internal liquidatorUser = address(0x3333);

    function setUp() public {
        // Deploy tokens
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        ethCollateral = new MockERC20("Ether", "ETH", 18);
        link = new MockERC20("Chainlink", "LINK", 18);
        stablecoin = new MockERC20("Lotus Stablecoin", "LUSD", 18);

        // Deploy feeds
        wbtcFeed = new MockAggregatorV3(8, 30_000 * 10 ** 8); // $30k
        ethFeed = new MockAggregatorV3(8, 2000 * 10 ** 8); // $2k
        linkFeed = new MockAggregatorV3(18, 10 * 10 ** 18); // $10

        // Deploy lending contracts
        engine = new CDPEngine(IMintableERC20(address(stablecoin)), admin);
        liquidator = new Liquidator(engine, stablecoin);

        // Admin whitelists collaterals and sets price feeds
        vm.startPrank(admin);

        // WBTC: minCollateralRatio = 150%, penalty = 110%
        engine.whitelistCollateral(address(wbtc), 1.5 * 1e18, 1.1 * 1e18);
        engine.setPriceFeed(address(wbtc), address(wbtcFeed));

        // ETH: minCollateralRatio = 130%, penalty = 115%
        engine.whitelistCollateral(address(ethCollateral), 1.3 * 1e18, 1.15 * 1e18);
        engine.setPriceFeed(address(ethCollateral), address(ethFeed));

        // LINK: minCollateralRatio = 200%, penalty = 120%
        engine.whitelistCollateral(address(link), 2.0 * 1e18, 1.2 * 1e18);
        engine.setPriceFeed(address(link), address(linkFeed));

        vm.stopPrank();

        // Mint collateral to user
        wbtc.mint(user, 10 * 10 ** 8);
        ethCollateral.mint(user, 100 * 10 ** 18);
        link.mint(user, 1000 * 10 ** 18);

        // Approvals
        vm.startPrank(user);
        wbtc.approve(address(engine), type(uint256).max);
        ethCollateral.approve(address(engine), type(uint256).max);
        link.approve(address(engine), type(uint256).max);
        stablecoin.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    function testBorrowWithinLimits() public {
        // Deposit 1 WBTC (8 decimals)
        vm.startPrank(user);
        engine.depositCollateral(address(wbtc), 1 * 10 ** 8);

        // Price = $30,000. Ratio = 150%. Max borrow = 30000 / 1.5 = 20000 LUSD
        engine.borrow(address(wbtc), 15_000 * 1e18);

        // Verify balance
        assertEq(stablecoin.balanceOf(user), 15_000 * 1e18);
        vm.stopPrank();
    }

    function testRevertBorrowExceedsLtv() public {
        vm.startPrank(user);
        engine.depositCollateral(address(wbtc), 1 * 10 ** 8);

        // Price = $30k. Ratio = 150%. Max borrow = 20k.
        // Borrowing 20,001 LUSD should revert
        vm.expectRevert(CDPEngine.BorrowExceedsMaxLTV.selector);
        engine.borrow(address(wbtc), 20_001 * 1e18);
        vm.stopPrank();
    }

    function testWithdrawCollateralSafety() public {
        vm.startPrank(user);
        engine.depositCollateral(address(wbtc), 1 * 10 ** 8); // $30k
        engine.borrow(address(wbtc), 10_000 * 1e18); // $10k debt. Needs $15k collateral = 0.5 WBTC.

        // Withdraw 0.4 WBTC (leaves 0.6 WBTC = $18k collateral value). Safe.
        engine.withdrawCollateral(address(wbtc), 0.4 * 10 ** 8);

        // Withdraw another 0.2 WBTC (leaves 0.4 WBTC = $12k collateral value). Unsafe.
        vm.expectRevert(CDPEngine.PositionUnsafeAfterWithdrawal.selector);
        engine.withdrawCollateral(address(wbtc), 0.2 * 10 ** 8);
        vm.stopPrank();
    }

    function testLiquidationOfUnsafePosition() public {
        // Deposit 10 ETH. Price = $2,000. Value = $20,000.
        // Borrow 15,000 LUSD. Min ratio is 130%. Required value = $19,500. Safe.
        vm.startPrank(user);
        engine.depositCollateral(address(ethCollateral), 10 * 1e18);
        engine.borrow(address(ethCollateral), 15_000 * 1e18);
        vm.stopPrank();

        // Drop ETH price to $1,900. Total value = $19,000 < $19,500. Position is unsafe.
        ethFeed.setLatestAnswer(1900 * 10 ** 8);
        assertFalse(engine.isPositionSafe(address(ethCollateral), user));

        // Prepare liquidator with LUSD
        stablecoin.mint(liquidatorUser, 10_000 * 1e18);
        vm.startPrank(liquidatorUser);
        stablecoin.approve(address(liquidator), type(uint256).max);

        // Liquidator covers 5,000 LUSD debt via Liquidator helper
        // Seized value: 5000 * 1.15 (penalty) = 5750 USD.
        // Seized amount in ETH: 5750 * 1e18 / 1900 = 3.026315789473684210 ETH
        uint256 balanceBefore = ethCollateral.balanceOf(liquidatorUser);
        liquidator.liquidatePosition(address(ethCollateral), user, 5000 * 1e18);
        uint256 balanceAfter = ethCollateral.balanceOf(liquidatorUser);

        uint256 expectedSeized = (uint256(5750) * 1e18) / 1900;
        assertEq(balanceAfter - balanceBefore, expectedSeized);
        vm.stopPrank();

        // Position check
        (uint256 leftCollateral, uint256 leftDebt) = engine.positions(address(ethCollateral), user);
        assertEq(leftDebt, 10_000 * 1e18);
        assertEq(leftCollateral, 10 * 1e18 - expectedSeized);
    }

    function testRevertLiquidationOfSafePosition() public {
        vm.startPrank(user);
        engine.depositCollateral(address(ethCollateral), 10 * 1e18);
        engine.borrow(address(ethCollateral), 10_000 * 1e18);
        vm.stopPrank();

        stablecoin.mint(liquidatorUser, 10_000 * 1e18);
        vm.startPrank(liquidatorUser);
        stablecoin.approve(address(engine), type(uint256).max);

        vm.expectRevert(CDPEngine.PositionIsSafe.selector);
        engine.liquidate(address(ethCollateral), user, 1000 * 1e18);
        vm.stopPrank();
    }
}
