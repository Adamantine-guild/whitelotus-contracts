// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../../contracts/mocks/MockAggregatorV3.sol";
import {CDPEngine, IMintableERC20} from "../../contracts/lending/CDPEngine.sol";
import {PauserModule} from "../../contracts/security/PauserModule.sol";
import {LibDiamond} from "../../contracts/libraries/LibDiamond.sol";
import {Diamond} from "../../contracts/router/Diamond.sol";
import {DiamondCutFacet} from "../../contracts/router/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/router/facets/DiamondLoupeFacet.sol";
import {SwapFacet} from "../../contracts/router/facets/SwapFacet.sol";
import {PauseManagerFacet} from "../../contracts/router/facets/PauseManagerFacet.sol";
import {IDiamondCut} from "../../contracts/interfaces/IDiamondCut.sol";
import {MockSafe} from "./MockSafe.sol";

/// @dev Covers issue #90 — Emergency Circuit Breaker (Pause) Mechanism:
///      guardian role freezes instantly; unpausing restricted to the multi-sig
///      governance timelock; withdrawal / exit paths remain functional.
contract CircuitBreakerTest is Test {
    // ── CDPEngine fixtures ─────────────────────────────────────────────────
    MockERC20 internal wbtc;
    MockERC20 internal stablecoin;
    MockAggregatorV3 internal wbtcFeed;
    CDPEngine internal engine;

    address internal admin = address(0x1111);
    address internal user = address(0x2222);
    address internal guardian = address(0x3333);
    address internal timelock = address(0x4444);
    address internal stranger = address(0x5555);

    // ── Diamond fixtures ───────────────────────────────────────────────────
    Diamond internal diamond;
    DiamondCutFacet internal cutFacet;
    SwapFacet internal swapFacet;
    PauseManagerFacet internal pauseManager;
    MockSafe internal mockSafe;

    function setUp() public {
        // CDPEngine
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        stablecoin = new MockERC20("Lotus Stablecoin", "LUSD", 18);
        wbtcFeed = new MockAggregatorV3(8, 30_000 * 10 ** 8);

        engine = new CDPEngine(IMintableERC20(address(stablecoin)), admin, timelock);
        vm.prank(admin);
        engine.setPauseGuardian(guardian);
        vm.prank(admin);
        engine.whitelistCollateral(address(wbtc), 1.5e18, 1.1e18);
        vm.prank(admin);
        engine.setPriceFeed(address(wbtc), address(wbtcFeed));

        // Diamond
        cutFacet = new DiamondCutFacet();
        swapFacet = new SwapFacet();
        pauseManager = new PauseManagerFacet();
        mockSafe = new MockSafe();
        diamond = new Diamond(address(mockSafe), address(cutFacet));

        // Cut Swap + PauseManager facets into the diamond
        bytes4[] memory swapSel = new bytes4[](4);
        swapSel[0] = SwapFacet.swapExactTokensForTokens.selector;
        swapSel[1] = SwapFacet.getAmountOut.selector;
        swapSel[2] = SwapFacet.getTotalSwaps.selector;
        swapSel[3] = SwapFacet.getBalance.selector;

        bytes4[] memory pauseSel = new bytes4[](5);
        pauseSel[0] = PauseManagerFacet.pause.selector;
        pauseSel[1] = PauseManagerFacet.unpause.selector;
        pauseSel[2] = PauseManagerFacet.setPauseGuardian.selector;
        pauseSel[3] = PauseManagerFacet.setGovernanceTimelock.selector;
        pauseSel[4] = PauseManagerFacet.paused.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(swapFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: swapSel
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(pauseManager),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: pauseSel
        });
        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");

        vm.startPrank(address(mockSafe));
        PauseManagerFacet(address(diamond)).setPauseGuardian(guardian);
        PauseManagerFacet(address(diamond)).setGovernanceTimelock(timelock);
        vm.stopPrank();
    }

    // ── CDPEngine: guardian + timelock ─────────────────────────────────────

    function testOnlyOwnerOrGuardianCanPauseCDPEngine() public {
        vm.prank(stranger);
        vm.expectRevert(PauserModule.NotGuardianOrOwner.selector);
        engine.pause();

        vm.prank(guardian);
        engine.pause();
        assertTrue(engine.paused());
    }

    function testOnlyTimelockCanUnpauseCDPEngine() public {
        vm.prank(guardian);
        engine.pause();

        // Guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert(PauserModule.NotTimelock.selector);
        engine.unpause();

        // Admin owner cannot unpause either — timelock only
        vm.prank(admin);
        vm.expectRevert(PauserModule.NotTimelock.selector);
        engine.unpause();

        vm.prank(timelock);
        engine.unpause();
        assertFalse(engine.paused());
    }

    function testBorrowAndDepositFrozenWhilePausedButWithdrawOpen() public {
        // Set up a position first
        wbtc.mint(user, 10e8);
        vm.startPrank(user);
        wbtc.approve(address(engine), 10e8);
        engine.depositCollateral(address(wbtc), 5e8);
        engine.borrow(address(wbtc), 1000e18);
        vm.stopPrank();

        // Freeze via guardian
        vm.prank(guardian);
        engine.pause();

        // Restricted: new deposit + borrow revert (OZ 4.9.6 string revert)
        vm.prank(user);
        vm.expectRevert(bytes("Pausable: paused"));
        engine.depositCollateral(address(wbtc), 1e8);

        vm.prank(user);
        vm.expectRevert(bytes("Pausable: paused"));
        engine.borrow(address(wbtc), 1e18);

        // Exit paths remain functional: withdraw collateral + repay
        vm.prank(user);
        engine.withdrawCollateral(address(wbtc), 1e8);
        (uint256 collateralAfter,) = engine.positions(address(wbtc), user);
        assertEq(collateralAfter, 4e8);

        // Unpause via timelock, borrow works again
        vm.prank(timelock);
        engine.unpause();

        vm.prank(user);
        engine.borrow(address(wbtc), 1e18);
        (, uint256 debtAfter) = engine.positions(address(wbtc), user);
        assertEq(debtAfter, 1001e18);
    }

    // ── Diamond PauseManagerFacet ──────────────────────────────────────────

    function testGuardianFreezesRouterInstantly() public {
        vm.prank(user);
        SwapFacet(address(diamond)).swapExactTokensForTokens(address(0xAAAA), address(0xBBBB), 100, 0);

        vm.prank(guardian);
        PauseManagerFacet(address(diamond)).pause();
        assertTrue(PauseManagerFacet(address(diamond)).paused());

        // Swap frozen while paused
        vm.prank(user);
        vm.expectRevert(SwapFacet.RouterPaused.selector);
        SwapFacet(address(diamond)).swapExactTokensForTokens(address(0xAAAA), address(0xBBBB), 100, 0);

        // Unpause only via timelock
        vm.prank(guardian);
        vm.expectRevert(PauseManagerFacet.NotTimelock.selector);
        PauseManagerFacet(address(diamond)).unpause();

        vm.prank(timelock);
        PauseManagerFacet(address(diamond)).unpause();
        assertFalse(PauseManagerFacet(address(diamond)).paused());

        vm.prank(user);
        SwapFacet(address(diamond)).swapExactTokensForTokens(address(0xAAAA), address(0xBBBB), 100, 0);
        assertEq(SwapFacet(address(diamond)).getTotalSwaps(), 2);
    }

    function testOnlyOwnerSetsGuardianAndTimelockOnRouter() public {
        vm.prank(stranger);
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        PauseManagerFacet(address(diamond)).setPauseGuardian(stranger);

        vm.prank(stranger);
        vm.expectRevert(LibDiamond.MustBeContractOwner.selector);
        PauseManagerFacet(address(diamond)).setGovernanceTimelock(stranger);
    }
}
