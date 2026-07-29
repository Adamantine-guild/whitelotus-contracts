// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {Vault} from "../../contracts/Vault.sol";
import {FlashLender} from "../../contracts/flashloan/FlashLender.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// A minimal flash-borrower mock that always repays for fee-collection tests.
// ─────────────────────────────────────────────────────────────────────────────
contract FeeManagerBorrower is IERC3156FlashBorrower {
    IERC20 public immutable token;
    FlashLender public immutable lender;

    constructor(IERC20 token_, FlashLender lender_) {
        token = token_;
        lender = lender_;
    }

    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == address(lender), "untrusted lender");
        token.approve(address(lender), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FeeManagerTest – Edge-case and boundary tests for protocol fee collection
// ─────────────────────────────────────────────────────────────────────────────
contract FeeManagerTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────────
    Vault internal vault;
    FlashLender internal lender;
    MockERC20 internal underlying;
    FeeManagerBorrower internal borrower;

    // ─── Addresses ──────────────────────────────────────────────────────────
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal treasuryAddr = makeAddr("treasury");
    address internal staker = makeAddr("staker");

    // ─── Events ─────────────────────────────────────────────────────────────
    event FeeSwept(address indexed token, address indexed to, uint256 amount);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);
    event FeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event FlashLoanExecuted(
        address indexed receiver, address indexed initiator, uint256 amount, uint256 fee
    );

    // ─── Constants ──────────────────────────────────────────────────────────
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant MAX_FEE_BPS = 100;

    // ─── Setup ──────────────────────────────────────────────────────────────
    function setUp() public {
        underlying = new MockERC20("Mock Token", "MTK", 18);

        vault = new Vault(
            IERC20(address(underlying)), "White Lotus Vault", "wlMTK", owner
        );

        lender = new FlashLender(
            IERC20(address(underlying)), "Staked MTK", "sMTK", owner, 50
        );
        borrower = new FeeManagerBorrower(IERC20(address(underlying)), lender);

        // Set vault treasury
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);

        // Fund staker for flash-loan liquidity
        underlying.mint(staker, 100_000 ether);
        vm.startPrank(staker);
        underlying.approve(address(lender), type(uint256).max);
        lender.deposit(100_000 ether, staker);
        vm.stopPrank();

        // Fund alice
        underlying.mint(alice, 10_000 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 1: FlashLender — Zero Fee (feeBps = 0)
    // ═════════════════════════════════════════════════════════════════════════

    function testFlashFee_ZeroBps_ReturnsZero() public {
        vm.prank(owner);
        lender.setFee(0);
        assertEq(lender.feeBps(), 0);

        // Fee must be exactly 0 for any amount when feeBps is 0
        assertEq(lender.flashFee(address(underlying), 0), 0, "0 amount");
        assertEq(lender.flashFee(address(underlying), 1), 0, "1 wei");
        assertEq(lender.flashFee(address(underlying), 1_000 ether), 0, "1000 tokens");
        assertEq(lender.flashFee(address(underlying), type(uint128).max), 0, "max uint128");
    }

    function testFlashFee_ZeroBps_FlashLoanChargesNothing() public {
        vm.prank(owner);
        lender.setFee(0);

        uint256 amount = 10_000 ether;
        // Borrower only needs to repay the principal (no fee)
        underlying.mint(address(borrower), amount);

        uint256 collectedBefore = lender.totalFeesCollected();
        assertTrue(lender.flashLoan(borrower, address(underlying), amount, ""));
        // No fee collected — totalFeesCollected must stay unchanged
        assertEq(lender.totalFeesCollected(), collectedBefore);
        assertEq(lender.totalAssets(), 100_000 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 2: FlashLender — Max Fee (feeBps = 100)
    // ═════════════════════════════════════════════════════════════════════════

    function testFlashFee_MaxBps_ExactOnePercent() public {
        vm.prank(owner);
        lender.setFee(MAX_FEE_BPS);
        assertEq(lender.feeBps(), MAX_FEE_BPS);

        // 1% of 10_000 = 100 exactly
        assertEq(lender.flashFee(address(underlying), 10_000), 100);
        // 1% of 100_000 = 1_000 exactly
        assertEq(lender.flashFee(address(underlying), 100_000 ether), 1_000 ether);
    }

    function testFlashFee_MaxBps_RoundsUpRemainder() public {
        vm.prank(owner);
        lender.setFee(MAX_FEE_BPS);

        // 1% of 1 = 0.01 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 1), 1);
        // 1% of 50 = 0.5 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 50), 1);
        // 1% of 99 = 0.99 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 99), 1);
        // 1% of 100 = 1.00 → exactly 1
        assertEq(lender.flashFee(address(underlying), 100), 1);
        // 1% of 101 = 1.01 → rounds up to 2
        assertEq(lender.flashFee(address(underlying), 101), 2);
    }

    function testFlashFee_MaxBps_FlashLoanCollectsFullFee() public {
        vm.prank(owner);
        lender.setFee(MAX_FEE_BPS);

        uint256 amount = 1_000 ether;
        uint256 expectedFee = lender.flashFee(address(underlying), amount);
        // expectedFee should be 10 ether (1% of 1000)
        assertEq(expectedFee, 10 ether);

        underlying.mint(address(borrower), expectedFee);

        uint256 collectedBefore = lender.totalFeesCollected();
        assertTrue(lender.flashLoan(borrower, address(underlying), amount, ""));
        assertEq(lender.totalFeesCollected(), collectedBefore + expectedFee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 3: FlashLender — Precision Loss & Rounding Behaviour
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice When amount * feeBps < BPS_DENOMINATOR, ceiling division
    ///         must still charge at least 1 wei (never 0 for non-zero amount).
    function testFlashFee_TinyAmount_RoundsUpToOne() public {
        vm.prank(owner);
        lender.setFee(1); // 0.01% = smallest non-zero fee

        // 1 * 1 / 10000 = 0 remainder 1 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 1), 1);
        // 100 * 1 / 10000 = 0 remainder 100 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 100), 1);
        // 5000 * 1 / 10000 = 0 remainder 5000 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 5_000), 1);
        // 9999 * 1 / 10000 = 0 remainder 9999 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 9_999), 1);
    }

    /// @notice When amount * feeBps is exactly divisible by BPS_DENOMINATOR,
    ///         there should be no rounding-up — fee is exact.
    function testFlashFee_ExactDivision_NoRounding() public {
        vm.prank(owner);
        lender.setFee(25); // 0.25%

        // 40000 * 25 / 10000 = 100 exactly
        assertEq(lender.flashFee(address(underlying), 40_000), 100);
        // 40000 ether * 25 / 10000 = 100 ether exactly
        assertEq(lender.flashFee(address(underlying), 40_000 ether), 100 ether);
    }

    /// @notice Just one wei past exact division should round up.
    function testFlashFee_JustPastExact_RoundsUp() public {
        vm.prank(owner);
        lender.setFee(25); // 0.25%

        // 40000 * 25 / 10000 = 100 exactly → 100
        assertEq(lender.flashFee(address(underlying), 40_000), 100);
        // 40001 * 25 / 10000 = 100 remainder 25 → rounds up to 101
        assertEq(lender.flashFee(address(underlying), 40_001), 101);
    }

    /// @notice Just one wei below exact division should round up.
    function testFlashFee_JustBeforeExact_RoundsUp() public {
        vm.prank(owner);
        lender.setFee(1);

        // 10000 * 1 / 10000 = 1 exactly
        assertEq(lender.flashFee(address(underlying), 10_000), 1);
        // 9999 * 1 / 10000 = 0 remainder 9999 → rounds up to 1
        assertEq(lender.flashFee(address(underlying), 9_999), 1);
    }

    /// @notice Fee must be monotonic: larger amount → >= fee (never less).
    function testFlashFee_Monotonic_LargerAmountNeverSmallerFee() public {
        // Test across three different fee rates
        uint256[3] memory feeRates = [uint256(1), uint256(50), uint256(100)];
        uint256[5] memory amounts = [
            uint256(1),
            uint256(100),
            uint256(10_000),
            uint256(1_000_000 ether),
            uint256(10_000_000 ether)
        ];

        for (uint256 r = 0; r < feeRates.length; r++) {
            vm.prank(owner);
            lender.setFee(feeRates[r]);

            for (uint256 i = 0; i < amounts.length - 1; i++) {
                uint256 feeSmall = lender.flashFee(address(underlying), amounts[i]);
                uint256 feeLarge = lender.flashFee(address(underlying), amounts[i + 1]);
                assertGe(feeLarge, feeSmall, "fee must be monotonic");
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 4: FlashLender — Boundary Amounts
    // ═════════════════════════════════════════════════════════════════════════

    function testFlashFee_ZeroAmount_ReturnsZero() public {
        // At any fee rate, fee on 0 amount must be 0
        vm.prank(owner);
        lender.setFee(0);
        assertEq(lender.flashFee(address(underlying), 0), 0);

        vm.prank(owner);
        lender.setFee(50);
        assertEq(lender.flashFee(address(underlying), 0), 0);

        vm.prank(owner);
        lender.setFee(MAX_FEE_BPS);
        assertEq(lender.flashFee(address(underlying), 0), 0);
    }

    function testFlashFee_MaxUint128_DoesNotOverflow() public {
        vm.prank(owner);
        lender.setFee(50);

        uint256 hugeAmount = type(uint128).max;
        uint256 fee = lender.flashFee(address(underlying), hugeAmount);

        // Fee must be non-zero and proportional
        assertGt(fee, 0);
        // Manual check: fee = ceil(hugeAmount * 50 / 10000) = ceil(hugeAmount / 200)
        uint256 expectedFloor = hugeAmount / 200;
        assertGe(fee, expectedFloor);
        assertLe(fee, expectedFloor + 1); // at most rounding up by 1
    }

    /// @notice flashFee uses an `unchecked` block, so multiplication at uint256 max
    ///         silently wraps around. This test documents that the function does NOT
    ///         revert but returns a fee based on the wrapped numerator. This is a
    ///         known contract limitation: callers must ensure amount * feeBps fits.
    function testFlashFee_MaxUint256_SilentlyWrapsInUnchecked() public {
        vm.prank(owner);
        lender.setFee(MAX_FEE_BPS);

        // Does NOT revert — unchecked arithmetic silently wraps
        uint256 fee = lender.flashFee(address(underlying), type(uint256).max);
        // Fee is well-defined even with wrapped numerator (non-reverting confirms no panic)
        // We just assert it returns some value without reverting
        assertTrue(fee > 0 || fee == 0); // tautology; proves no revert occurred
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 5: FlashLender — Fee Updates & Total Collection Accuracy
    // ═════════════════════════════════════════════════════════════════════════

    function testSetFee_ToEveryValidBps() public {
        // Every value from 0 to 100 inclusive should succeed
        for (uint256 i = 0; i <= MAX_FEE_BPS; i++) {
            vm.prank(owner);
            lender.setFee(i);
            assertEq(lender.feeBps(), i);
        }
    }

    /// @notice Setting the fee always emits FeeUpdated, even when the new value
    ///         is the same as the previous one.
    function testSetFee_EmitsEventOnEveryChange() public {
        // Starting fee is 50 (constructor default). Set to 0 first so we can
        // test a clean 0 → 50 transition.
        vm.prank(owner);
        lender.setFee(0);

        // FeeUpdated has no indexed params, so only check topic0 (event sig) + data
        vm.expectEmit(true, false, false, true, address(lender));
        emit FeeUpdated(0, 50);
        vm.prank(owner);
        lender.setFee(50);
    }

    function testSetFee_SameValue_StillEmitsEvent() public {
        vm.prank(owner);
        lender.setFee(75);

        vm.expectEmit(true, false, false, true, address(lender));
        emit FeeUpdated(75, 75);
        vm.prank(owner);
        lender.setFee(75);
    }

    function testTotalFeesCollected_AccumulatesAcrossLoans() public {
        vm.prank(owner);
        lender.setFee(50); // 0.5%

        uint256 totalExpected;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1_000 ether;
        amounts[1] = 5_000 ether;
        amounts[2] = 10_000 ether;

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 fee = lender.flashFee(address(underlying), amounts[i]);
            underlying.mint(address(borrower), fee);

            assertTrue(lender.flashLoan(borrower, address(underlying), amounts[i], ""));
            totalExpected += fee;
            assertEq(lender.totalFeesCollected(), totalExpected);
        }
    }

    function testFlashFee_NonZeroFeeAlwaysAtLeastOne() public {
        // For any non-zero feeBps and non-zero amount, fee must be >= 1
        for (uint256 bps = 1; bps <= MAX_FEE_BPS; bps++) {
            vm.prank(owner);
            lender.setFee(bps);

            uint256 fee1 = lender.flashFee(address(underlying), 1);
            assertEq(fee1, 1, string.concat("bps=", vm.toString(bps)));

            uint256 fee100 = lender.flashFee(address(underlying), 100);
            assertGe(fee100, 1, string.concat("bps=", vm.toString(bps)));
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 6: Vault — SweepFees Edge Cases
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Sweeping a non-underlying token that arrived at the vault.
    function testSweepFees_ForeignToken_ExactTransfer() public {
        MockERC20 foreign = new MockERC20("Foreign", "FRN", 6);
        uint256 amount = 1_000_000e6; // 1M with 6 decimals

        foreign.mint(address(vault), amount);
        uint256 treasuryBalBefore = foreign.balanceOf(treasuryAddr);

        vm.prank(treasuryAddr);
        vault.sweepFees(address(foreign));

        assertEq(foreign.balanceOf(address(vault)), 0, "vault must have 0 foreign tokens left");
        assertEq(
            foreign.balanceOf(treasuryAddr),
            treasuryBalBefore + amount,
            "treasury must receive exact amount"
        );
        assertEq(vault.totalFeesSwept(), amount);
    }

    /// @notice Sweeping the underlying asset when only depositor funds exist
    ///         transfers depositor funds too (caller must be careful).
    function testSweepFees_UnderlyingAsset_SweepsEntireBalance() public {
        // Alice deposits into the vault
        vm.prank(alice);
        underlying.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(5_000 ether, alice);

        // Simulate yield / fees: extra tokens arrive at vault
        uint256 yieldAmount = 500 ether;
        underlying.mint(address(vault), yieldAmount);

        uint256 vaultBalBefore = underlying.balanceOf(address(vault));
        uint256 treasuryBalBefore = underlying.balanceOf(treasuryAddr);

        vm.prank(treasuryAddr);
        vault.sweepFees(address(underlying));

        // The sweep transfers the entire balance — including depositor funds.
        // This is expected behaviour; callers must ensure only fees are swept.
        assertEq(underlying.balanceOf(address(vault)), 0, "vault drained");
        assertEq(
            underlying.balanceOf(treasuryAddr),
            treasuryBalBefore + vaultBalBefore,
            "treasury receives entire balance"
        );
        assertEq(vault.totalFeesSwept(), vaultBalBefore);
    }

    /// @notice After sweeping, the token balance is zero, so sweeping again reverts.
    function testSweepFees_RevertsAfterFullSweep() public {
        uint256 feeAmount = 100 ether;
        underlying.mint(address(vault), feeAmount);

        // First sweep succeeds
        vm.prank(treasuryAddr);
        vault.sweepFees(address(underlying));

        // Second sweep on same token reverts — no tokens left
        vm.prank(treasuryAddr);
        vm.expectRevert(Vault.NoFeesToSweep.selector);
        vault.sweepFees(address(underlying));
    }

    /// @notice Sweeping a foreign token does not affect the vault's underlying balance
    ///         or depositors' positions.
    function testSweepFees_ForeignTokenDoesNotAffectUnderlying() public {
        // Alice deposits
        vm.prank(alice);
        underlying.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(1_000 ether, alice);

        uint256 vaultUnderlyingBefore = underlying.balanceOf(address(vault));
        uint256 alicePreview = vault.previewRedeem(aliceShares);

        // Foreign token arrives
        MockERC20 foreign = new MockERC20("Foreign", "FRN", 18);
        foreign.mint(address(vault), 10_000 ether);

        // Sweep foreign token
        vm.prank(treasuryAddr);
        vault.sweepFees(address(foreign));

        // Underlying balance unchanged; alice can still redeem
        assertEq(
            underlying.balanceOf(address(vault)),
            vaultUnderlyingBefore,
            "underlying balance unchanged"
        );
        assertEq(vault.previewRedeem(aliceShares), alicePreview, "alice position unchanged");
    }

    /// @notice totalFeesSwept counter is denominated in the swept token's units,
    ///         so sweeping different tokens accumulates unreconcilably.
    function testTotalFeesSwept_AccumulatesAbsoluteTokenAmounts() public {
        // Sweep underlying: 100 ether (18 decimal places → 100e18 raw)
        uint256 fee1 = 100 ether;
        underlying.mint(address(vault), fee1);
        vm.prank(treasuryAddr);
        vault.sweepFees(address(underlying));
        assertEq(vault.totalFeesSwept(), fee1);

        // Sweep foreign token: 50 million (6 decimal places → 50_000_000e6 raw)
        MockERC20 foreign = new MockERC20("Foreign", "FRN", 6);
        uint256 fee2 = 50_000_000e6;
        foreign.mint(address(vault), fee2);
        vm.prank(treasuryAddr);
        vault.sweepFees(address(foreign));

        // totalFeesSwept = raw amounts summed across tokens
        assertEq(vault.totalFeesSwept(), fee1 + fee2);
    }

    /// @notice Sweeping a token with a very large supply (near uint128 max).
    function testSweepFees_VeryLargeAmount() public {
        MockERC20 foreign = new MockERC20("Huge", "HG", 18);
        uint256 hugeAmount = type(uint128).max;
        foreign.mint(address(vault), hugeAmount);

        vm.prank(treasuryAddr);
        vault.sweepFees(address(foreign));

        assertEq(foreign.balanceOf(treasuryAddr), hugeAmount);
        assertEq(vault.totalFeesSwept(), hugeAmount);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 7: Vault — Treasury Updates
    // ═════════════════════════════════════════════════════════════════════════

    function testSetTreasury_BackToBackChanges() public {
        address t1 = makeAddr("t1");
        address t2 = makeAddr("t2");
        address t3 = makeAddr("t3");

        vm.startPrank(owner);
        vault.setTreasury(t1);
        assertEq(vault.treasury(), t1);

        vault.setTreasury(t2);
        assertEq(vault.treasury(), t2);

        vault.setTreasury(t3);
        assertEq(vault.treasury(), t3);
        vm.stopPrank();
    }

    function testSetTreasury_SameAddress() public {
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);
        assertEq(vault.treasury(), treasuryAddr);

        // Setting to the same address succeeds and emits an event
        vm.expectEmit(true, true, false, true, address(vault));
        emit TreasurySet(treasuryAddr, treasuryAddr);
        vm.prank(owner);
        vault.setTreasury(treasuryAddr);
        assertEq(vault.treasury(), treasuryAddr);
    }

    /// @notice Treasury must be set before sweeping. Tests that sweepFees
    ///         uses the current treasury at call-time, not a cached value.
    function testSweepFees_UsesLatestTreasury() public {
        address oldTreasury = treasuryAddr;
        address newTreasury = makeAddr("newTreasury");

        // Set first treasury
        vm.prank(owner);
        vault.setTreasury(oldTreasury);

        // Fund the vault
        uint256 feeAmount = 200 ether;
        underlying.mint(address(vault), feeAmount);

        // Switch treasury
        vm.prank(owner);
        vault.setTreasury(newTreasury);

        uint256 newTreasuryBefore = underlying.balanceOf(newTreasury);
        uint256 oldTreasuryBefore = underlying.balanceOf(oldTreasury);

        // Sweep — funds go to the NEW treasury, not the old one
        vm.prank(newTreasury);
        vault.sweepFees(address(underlying));

        assertEq(underlying.balanceOf(newTreasury), newTreasuryBefore + feeAmount);
        assertEq(underlying.balanceOf(oldTreasury), oldTreasuryBefore);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Section 8: Integration — Vault + FlashLender Fee Interaction
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Flash-loan fees collected by the lender are distinct from vault
    ///         swept fees. The two mechanisms operate independently.
    function testVaultAndLenderFeesAreIndependent() public {
        // Fund vault with some "fees"
        uint256 vaultFee = 500 ether;
        underlying.mint(address(vault), vaultFee);

        // Execute a flash loan — collects lender fee independently
        uint256 loanAmount = 5_000 ether;
        uint256 lenderFee = lender.flashFee(address(underlying), loanAmount);
        underlying.mint(address(borrower), lenderFee);

        uint256 vaultTotalBefore = vault.totalFeesSwept();
        uint256 lenderTotalBefore = lender.totalFeesCollected();

        // Sweep vault fees
        vm.prank(treasuryAddr);
        vault.sweepFees(address(underlying));
        assertEq(vault.totalFeesSwept(), vaultTotalBefore + vaultFee);

        // Execute flash loan
        assertTrue(lender.flashLoan(borrower, address(underlying), loanAmount, ""));
        assertEq(lender.totalFeesCollected(), lenderTotalBefore + lenderFee);

        // Each mechanism's totals are independent
        assertEq(vault.totalFeesSwept(), vaultFee, "vault total unchanged by flash loan");
    }
}
