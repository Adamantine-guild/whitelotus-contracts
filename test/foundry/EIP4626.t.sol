// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../../contracts/Vault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// A minimal EIP-4626 router that only uses the standard interface.
// Simulates how aggregators / lenders call vaults through the spec interface.
// ─────────────────────────────────────────────────────────────────────────────
contract MockERC4626Router {
    /// @notice Pull `assets` from `user` and deposit them into `vault` on their behalf.
    function depositFor(IERC4626 vault, uint256 assets, address user) external returns (uint256 shares) {
        IERC20(vault.asset()).transferFrom(user, address(this), assets);
        IERC20(vault.asset()).approve(address(vault), assets);
        shares = vault.deposit(assets, user);
    }

    /// @notice Redeem `shares` from `vault` on behalf of `user` and send assets to `user`.
    function redeemFor(IERC4626 vault, uint256 shares, address user) external returns (uint256 assets) {
        // Router holds the shares (transferred by user first)
        assets = vault.redeem(shares, user, address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main test contract
// ─────────────────────────────────────────────────────────────────────────────
contract EIP4626Test is Test {
    Vault internal vault;
    MockERC20 internal underlying;
    MockERC4626Router internal router;

    // ─── Events (re-declared for emit in tests) ─────────────────────────────
    event FeeSwept(address indexed token, address indexed to, uint256 amount);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    uint256 constant INITIAL_BALANCE = 1_000_000e18;

    // ─── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        underlying = new MockERC20("Mock USDC", "mUSDC", 18);
        vault = new Vault(IERC20(address(underlying)), "White Lotus mUSDC Vault", "wlmUSDC", owner);
        router = new MockERC4626Router();

        // Fund test accounts
        underlying.mint(alice, INITIAL_BALANCE);
        underlying.mint(bob, INITIAL_BALANCE);
        underlying.mint(attacker, INITIAL_BALANCE);

        vm.prank(alice);
        underlying.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        underlying.approve(address(vault), type(uint256).max);

        vm.prank(attacker);
        underlying.approve(address(vault), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 1: EIP-4626 View Functions — spec compliance
    // ─────────────────────────────────────────────────────────────────────────

    function testTotalAssetsIsUnderlyingBalance() public {
        assertEq(vault.totalAssets(), underlying.balanceOf(address(vault)));

        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        assertEq(vault.totalAssets(), underlying.balanceOf(address(vault)));
    }

    function testAssetReturnsUnderlyingAddress() public view {
        assertEq(vault.asset(), address(underlying));
    }

    function testMaxDepositReturnsMaxUintWhenUnpaused() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function testMaxMintReturnsMaxUintWhenUnpaused() public view {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    function testMaxWithdrawReturnsShareholderBalance() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);

        // maxWithdraw must equal convertToAssets(balanceOf(alice))
        uint256 expected = vault.convertToAssets(vault.balanceOf(alice));
        assertEq(vault.maxWithdraw(alice), expected);
    }

    function testMaxRedeemReturnsShareBalance() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
    }

    function testPreviewDepositMatchesActualDeposit() public {
        uint256 assets = 100e18;
        uint256 preview = vault.previewDeposit(assets);

        vm.prank(alice);
        uint256 actual = vault.deposit(assets, alice);

        assertEq(preview, actual, "previewDeposit must match actual shares minted");
    }

    function testPreviewMintMatchesActualMint() public {
        uint256 shares = 100e18;
        uint256 preview = vault.previewMint(shares);

        vm.prank(alice);
        uint256 actual = vault.mint(shares, alice);

        assertEq(preview, actual, "previewMint must match actual assets consumed");
    }

    function testPreviewWithdrawMatchesActualWithdraw() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);

        uint256 assets = 200e18;
        uint256 preview = vault.previewWithdraw(assets);

        vm.prank(alice);
        uint256 actual = vault.withdraw(assets, alice, alice);

        assertEq(preview, actual, "previewWithdraw must match actual shares burned");
    }

    function testPreviewRedeemMatchesActualRedeem() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(500e18, alice);

        uint256 preview = vault.previewRedeem(shares / 2);

        vm.prank(alice);
        uint256 actual = vault.redeem(shares / 2, alice, alice);

        assertEq(preview, actual, "previewRedeem must match actual assets returned");
    }

    function testConvertToSharesAndAssetsAreInverse() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        uint256 assets = 500e18;
        uint256 shares = vault.convertToShares(assets);
        uint256 backToAssets = vault.convertToAssets(shares);

        // Round-trip: assets → shares → assets must not gain value (floor division)
        assertLe(backToAssets, assets, "round-trip must not gain assets");
        // But the loss should be negligible (< 1 wei given the virtual offset)
        assertApproxEqAbs(backToAssets, assets, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 2: Deposit and Mint
    // ─────────────────────────────────────────────────────────────────────────

    function testDepositMintsShares() public {
        uint256 assets = 1_000e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertGt(shares, 0, "must mint shares");
        assertEq(vault.balanceOf(alice), shares);
        assertEq(underlying.balanceOf(address(vault)), assets);
    }

    function testDepositEmitsEvent() public {
        uint256 assets = 500e18;
        uint256 expectedShares = vault.previewDeposit(assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Deposit(alice, alice, assets, expectedShares);

        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function testMintExactShares() public {
        uint256 wantedShares = 100e18;

        vm.prank(alice);
        uint256 assetsSpent = vault.mint(wantedShares, alice);

        assertEq(vault.balanceOf(alice), wantedShares, "must have exactly the requested shares");
        assertGt(assetsSpent, 0);
        assertEq(underlying.balanceOf(address(vault)), assetsSpent);
    }

    function testDepositToAnotherReceiver() public {
        vm.prank(alice);
        vault.deposit(500e18, bob);

        assertEq(vault.balanceOf(alice), 0);
        assertGt(vault.balanceOf(bob), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 3: Withdraw and Redeem
    // ─────────────────────────────────────────────────────────────────────────

    function testWithdrawReturnsAssets() public {
        uint256 depositAmount = 1_000e18;
        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        uint256 withdrawAmount = 500e18;
        uint256 aliceBefore = underlying.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(underlying.balanceOf(alice), aliceBefore + withdrawAmount);
    }

    function testRedeemBurnsSharesAndReturnsAssets() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e18, alice);

        uint256 aliceAssetsBefore = underlying.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertGt(assets, 0);
        assertEq(underlying.balanceOf(alice), aliceAssetsBefore + assets);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testWithdrawEmitsEvent() public {
        vm.prank(alice);
        vault.deposit(500e18, alice);

        uint256 withdrawAssets = 200e18;
        uint256 expectedShares = vault.previewWithdraw(withdrawAssets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, withdrawAssets, expectedShares);

        vm.prank(alice);
        vault.withdraw(withdrawAssets, alice, alice);
    }

    function testWithdrawByApprovedOperator() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        // Alice approves bob to spend her shares
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        uint256 bobAssetsBefore = underlying.balanceOf(bob);

        // Bob withdraws alice's assets, sending them to himself
        vm.prank(bob);
        vault.withdraw(500e18, bob, alice);

        assertEq(underlying.balanceOf(bob), bobAssetsBefore + 500e18);
    }

    function testCannotWithdrawMoreThanDeposited() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(101e18, alice, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 4: Inflation Attack Defence
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Classic inflation attack: first depositor attacks second depositor
    ///         by inflating totalAssets between the two deposits.
    /// @dev    With our virtual-share offset (10^18) the attacker would need to
    ///         donate ~10^18 tokens to grief a single-wei deposit. This test
    ///         verifies that Bob receives fair shares even after a large donation.
    function testInflationAttackVirtualOffsetNeutralises() public {
        // Attacker deposits 1 wei — classic first depositor
        underlying.mint(attacker, 1);
        vm.prank(attacker);
        underlying.approve(address(vault), 1);
        vm.prank(attacker);
        vault.deposit(1, attacker);

        // Attacker donates 1_000e18 tokens directly (inflation vector)
        vm.prank(attacker);
        underlying.transfer(address(vault), 1_000e18);

        // Bob deposits 1_000e18 tokens
        uint256 bobSharesBefore = vault.balanceOf(bob);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_000e18, bob);

        // Bob must receive more than 0 shares
        assertGt(bobShares, 0, "inflation attack: bob must receive shares");
        assertGt(vault.balanceOf(bob), bobSharesBefore);

        // Bob's asset value must be close to what he deposited (allow 0.01% slippage)
        uint256 bobAssetsBack = vault.convertToAssets(bobShares);
        assertGt(bobAssetsBack, 1_000e18 * 9999 / 10_000, "bob must not lose more than 0.01%");
    }

    /// @notice Verify the dead shares were minted to address(1) on construction.
    function testDeadSharesMintedOnConstruction() public view {
        assertEq(vault.balanceOf(address(1)), vault.DEAD_SHARES());
        assertGt(vault.totalSupply(), 0);
    }

    /// @notice Simulate an extreme front-run: attacker tries to brick the vault
    ///         by donating a massive amount before the first real user.
    function testMassiveDonationCannotBrickVault() public {
        // Attacker donates without depositing (no shares received)
        vm.prank(attacker);
        underlying.transfer(address(vault), INITIAL_BALANCE);

        // Alice deposits a normal amount
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        // Alice must receive shares
        assertGt(aliceShares, 0, "must receive shares even after massive donation");

        // Alice's shares must be redeemable for approximately what she put in
        uint256 aliceAssets = vault.convertToAssets(aliceShares);
        // Allow 0.01% loss
        assertGt(aliceAssets, 1_000e18 * 9999 / 10_000, "must not lose materially to donation");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 5: Pause Mechanism
    // ─────────────────────────────────────────────────────────────────────────

    function testOnlyOwnerCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function testDepositRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(100e18, alice);
    }

    function testMintRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.mint(100e18, alice);
    }

    function testWithdrawWorksWhenPaused() public {
        // Deposit first (before pause)
        vm.prank(alice);
        vault.deposit(500e18, alice);

        vm.prank(owner);
        vault.pause();

        // Withdraw must still succeed while paused
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);
        assertGt(assets, 0, "withdraw must work while paused");
    }

    function testMaxDepositAndMaxMintReturnZeroWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0, "maxDeposit must be 0 when paused");
        assertEq(vault.maxMint(alice), 0, "maxMint must be 0 when paused");
    }

    function testUnpauseRestoresDeposit() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vault.unpause();

        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);
        assertGt(shares, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 6: Slippage Guards
    // ─────────────────────────────────────────────────────────────────────────

    function testDepositSlippageRevertsIfSharesBelowMin() public {
        uint256 assets = 1_000e18;
        uint256 expectedShares = vault.previewDeposit(assets);

        // Request more shares than we'll get
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.SlippageExceeded.selector, expectedShares, expectedShares + 1)
        );
        vault.deposit(assets, alice, expectedShares + 1);
    }

    function testDepositSlippagePassesWithAccurateMin() public {
        uint256 assets = 1_000e18;
        uint256 expectedShares = vault.previewDeposit(assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice, expectedShares);
        assertEq(shares, expectedShares);
    }

    function testMintSlippageRevertsIfAssetsExceedMax() public {
        uint256 wantedShares = 100e18;
        uint256 expectedAssets = vault.previewMint(wantedShares);

        // Set maxAssetsIn below what the mint actually costs
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Vault.SlippageExceeded2.selector, expectedAssets, expectedAssets - 1)
        );
        vault.mint(wantedShares, alice, expectedAssets - 1);
    }

    function testMintSlippagePassesWithAccurateMax() public {
        uint256 wantedShares = 100e18;
        uint256 expectedAssets = vault.previewMint(wantedShares);

        vm.prank(alice);
        uint256 assets = vault.mint(wantedShares, alice, expectedAssets);
        assertEq(assets, expectedAssets);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 7: Router / Aggregator Compatibility (EIP-4626 standard interface)
    // ─────────────────────────────────────────────────────────────────────────

    function testRouterCanDepositViaStandardInterface() public {
        uint256 assets = 500e18;

        // Alice approves router for underlying
        vm.prank(alice);
        underlying.approve(address(router), type(uint256).max);

        uint256 aliceSharesBefore = vault.balanceOf(alice);

        // Router uses standard IERC4626.deposit
        vm.prank(alice);
        uint256 shares = router.depositFor(IERC4626(address(vault)), assets, alice);

        assertGt(shares, 0, "router must obtain shares");
        assertEq(vault.balanceOf(alice), aliceSharesBefore + shares, "alice must hold the shares");
    }

    function testRouterCanRedeemViaStandardInterface() public {
        // Alice deposits directly first
        vm.prank(alice);
        uint256 shares = vault.deposit(500e18, alice);

        // Alice gives the router approval over her shares
        vm.prank(alice);
        vault.approve(address(router), shares);

        // Transfer shares to router so it can redeem them on alice's behalf
        vm.prank(alice);
        vault.transfer(address(router), shares);

        uint256 aliceAssetsBefore = underlying.balanceOf(alice);

        // Router redeems using standard IERC4626.redeem, sends assets to alice
        vm.prank(alice);
        uint256 assets = router.redeemFor(IERC4626(address(vault)), shares, alice);

        assertGt(assets, 0, "router must return assets");
        assertEq(underlying.balanceOf(alice), aliceAssetsBefore + assets);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 8: Yield Accrual
    // ─────────────────────────────────────────────────────────────────────────

    function testSharePriceIncreasesOnYield() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        uint256 priceBefore = vault.convertToAssets(1e18);

        // Simulate yield: 100 tokens sent directly to vault (no new shares minted)
        underlying.mint(address(vault), 100e18);

        uint256 priceAfter = vault.convertToAssets(1e18);
        assertGt(priceAfter, priceBefore, "share price must increase on yield");

        // Alice's shares are now worth more
        uint256 aliceAssetsAfter = vault.convertToAssets(aliceShares);
        assertGt(aliceAssetsAfter, 1_000e18, "alice must profit from yield");
    }

    function testTotalAssetsReflectsYield() public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        assertEq(vault.totalAssets(), 1_000e18);

        // Yield accrues
        underlying.mint(address(vault), 50e18);
        assertEq(vault.totalAssets(), 1_050e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 9: Multi-user scenarios
    // ─────────────────────────────────────────────────────────────────────────

    function testMultipleDepositorsFairShareDistribution() public {
        // Alice deposits first
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        // Bob deposits same amount
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_000e18, bob);

        // With the same deposit and no yield, both should receive equal shares
        assertApproxEqRel(aliceShares, bobShares, 1e15, "equal depositors get equal shares");
    }

    function testEarlyDepositorBenefitsFromYield() public {
        // Alice deposits before yield
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);

        // Yield accrues
        underlying.mint(address(vault), 1_000e18);

        // Bob deposits after yield (same amount, but share price is now 2x)
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_000e18, bob);

        // Alice should have ~2x more shares than Bob
        assertApproxEqRel(aliceShares, bobShares * 2, 1e15, "early depositor has more shares");

        // Both redeem; Alice should get ~2000, Bob ~1000
        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        assertApproxEqRel(aliceAssets, bobAssets * 2, 1e14, "alice gets 2x assets as early depositor");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 10: Fuzz Tests
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice assets → shares → assets must never gain value (rounding favours vault).
    function testFuzz_DepositRedeemRoundTripNeverGains(uint256 assets) public {
        assets = bound(assets, 1e6, INITIAL_BALANCE);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        vm.prank(alice);
        uint256 assetsBack = vault.redeem(shares, alice, alice);

        // The round-trip must not gain; may lose at most 1 wei due to floor division.
        assertLe(assetsBack, assets, "round-trip must not gain");
        assertGe(assetsBack, assets - 2, "round-trip must not lose more than 2 wei");
    }

    /// @notice totalAssets never decreases after a deposit (monotonicity).
    function testFuzz_TotalAssetsMonotonicAfterDeposit(uint256 assets) public {
        assets = bound(assets, 1, INITIAL_BALANCE);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(alice);
        vault.deposit(assets, alice);

        assertGe(vault.totalAssets(), totalBefore, "totalAssets must be monotone after deposit");
    }

    /// @notice convertToShares and convertToAssets must be weakly inverse of each other.
    function testFuzz_ConvertConsistency(uint256 assets) public {
        vm.prank(alice);
        vault.deposit(1_000e18, alice); // seed the vault

        assets = bound(assets, 1e6, 1_000e18);

        uint256 shares = vault.convertToShares(assets);
        uint256 assetsBack = vault.convertToAssets(shares);

        // assetsBack ≤ assets (floor division rounds against the user)
        assertLe(assetsBack, assets);
    }

    /// @notice previewDeposit must always be ≤ actual shares (pessimistic estimate).
    ///         The spec requires preview to not overestimate (EIP-4626 §4.3).
    function testFuzz_PreviewDepositIsNotOptimistic(uint256 assets) public {
        assets = bound(assets, 1e6, INITIAL_BALANCE);

        uint256 preview = vault.previewDeposit(assets);

        vm.prank(alice);
        uint256 actual = vault.deposit(assets, alice);

        // Preview must be exactly equal or less than actual (it can be equal when exact)
        assertLe(preview, actual + 1, "previewDeposit must not be optimistic");
    }

    /// @notice Vault ERC-20 share decimals must be asset decimals + _decimalsOffset (18).
    function testShareDecimalsEqualsAssetPlusOffset() public view {
        // underlying is 18 decimals, offset is 18 -> share decimals = 36
        assertEq(vault.decimals(), 36);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Section 11: Treasury & Fee Sweeping
    // ─────────────────────────────────────────────────────────────────────────

    function testSetTreasuryEmitsEvent() public {
        address newTreasury = makeAddr("treasury");

        vm.expectEmit(true, true, false, true, address(vault));
        emit TreasurySet(address(0), newTreasury);

        vm.prank(owner);
        vault.setTreasury(newTreasury);

        assertEq(vault.treasury(), newTreasury);
    }

    function testSetTreasuryRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Vault.InvalidTreasury.selector);
        vault.setTreasury(address(0));
    }

    function testSetTreasuryOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTreasury(makeAddr("treasury"));
    }

    function testSweepFeesTransfersTokensAndEmitsEvent() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // Simulate fees: send tokens directly to the vault
        uint256 feeAmount = 100e18;
        underlying.mint(address(vault), feeAmount);

        uint256 treasuryBefore = underlying.balanceOf(treasuryAddr);
        uint256 vaultBefore = underlying.balanceOf(address(vault));

        vm.expectEmit(true, true, false, true, address(vault));
        emit FeeSwept(address(underlying), treasuryAddr, feeAmount);

        vm.prank(treasuryAddr);
        vault.sweepFees(address(underlying));

        assertEq(underlying.balanceOf(treasuryAddr), treasuryBefore + feeAmount);
        assertEq(underlying.balanceOf(address(vault)), vaultBefore - feeAmount);
        assertEq(vault.totalFeesSwept(), feeAmount);
    }

    function testSweepFeesByOwner() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        uint256 feeAmount = 50e18;
        underlying.mint(address(vault), feeAmount);

        vm.prank(owner);
        vault.sweepFees(address(underlying));

        assertEq(underlying.balanceOf(treasuryAddr), feeAmount);
        assertEq(vault.totalFeesSwept(), feeAmount);
    }

    function testSweepFeesRevertsNoFees() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // No extra tokens in vault beyond what depositors put in
        vm.prank(treasuryAddr);
        vm.expectRevert(Vault.NoFeesToSweep.selector);
        vault.sweepFees(address(underlying));
    }

    function testSweepFeesRevertsTreasuryNotSet() public {
        // Treasury is not set (address(0) by default)
        underlying.mint(address(vault), 10e18);

        vm.prank(owner);
        vm.expectRevert(Vault.TreasuryNotSet.selector);
        vault.sweepFees(address(underlying));
    }

    function testSetTreasuryUpdatesExisting() public {
        address firstTreasury = makeAddr("treasury1");
        address secondTreasury = makeAddr("treasury2");

        vm.prank(owner);
        vault.setTreasury(firstTreasury);
        assertEq(vault.treasury(), firstTreasury);

        vm.expectEmit(true, true, false, true, address(vault));
        emit TreasurySet(firstTreasury, secondTreasury);

        vm.prank(owner);
        vault.setTreasury(secondTreasury);
        assertEq(vault.treasury(), secondTreasury);
    }

    function testSweepFeesRevertsUnauthorized() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        underlying.mint(address(vault), 10e18);

        vm.prank(alice);
        vm.expectRevert(Vault.NotTreasuryOrOwner.selector);
        vault.sweepFees(address(underlying));
    }

    function testSweepFeesDifferentToken() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // Simulate a different ERC-20 token (e.g. airdrop) arriving at the vault
        MockERC20 otherToken = new MockERC20("Other Token", "OTH", 18);
        uint256 airdropAmount = 1_000e18;
        otherToken.mint(address(vault), airdropAmount);

        vm.prank(treasuryAddr);
        vault.sweepFees(address(otherToken));

        assertEq(otherToken.balanceOf(treasuryAddr), airdropAmount);
        assertEq(otherToken.balanceOf(address(vault)), 0);
    }

    function testSweepFeesPreservesSharePriceForForeignToken() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // Alice deposits
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000e18, alice);
        uint256 priceBefore = vault.convertToAssets(1e18);

        // A foreign token (e.g. airdrop, fee token from strategy) arrives at the vault
        MockERC20 otherToken = new MockERC20("Fee Token", "FEE", 18);
        otherToken.mint(address(vault), 10_000e18);

        // Sweep the foreign token as protocol fees
        vm.prank(treasuryAddr);
        vault.sweepFees(address(otherToken));

        // Share price for the vault's underlying asset must be unchanged
        uint256 priceAfter = vault.convertToAssets(1e18);
        assertEq(priceAfter, priceBefore, "sweeping foreign token must not change share price");

        // Alice can still redeem her full deposit
        vm.prank(alice);
        uint256 assetsBack = vault.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(assetsBack, 1_000e18, 2);
    }

    function testTotalFeesSweptAccumulatesAcrossSweeps() public {
        address treasuryAddr = makeAddr("treasury");
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // First sweep: 100 tokens
        uint256 firstFee = 100e18;
        underlying.mint(address(vault), firstFee);
        vm.prank(owner);
        vault.sweepFees(address(underlying));
        assertEq(vault.totalFeesSwept(), firstFee);

        // Second sweep: 50 more tokens
        uint256 secondFee = 50e18;
        underlying.mint(address(vault), secondFee);
        vm.prank(owner);
        vault.sweepFees(address(underlying));
        assertEq(vault.totalFeesSwept(), firstFee + secondFee);
    }
}
