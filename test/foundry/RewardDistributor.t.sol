// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {RewardDistributor} from "../../contracts/staking/RewardDistributor.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract RewardDistributorTest is Test {
    RewardDistributor internal distributor;
    MockERC20 internal stakingToken;
    MockERC20 internal rewardToken;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);
    address internal bob = address(0xCA11);
    address internal carol = address(0xDECAF);

    uint256 internal constant DURATION = 30 days;
    uint256 internal constant REWARD_BUDGET = 1_000_000e18;

    function setUp() public {
        stakingToken = new MockERC20("Stake", "STK", 18);
        rewardToken = new MockERC20("Reward", "RWD", 18);
        distributor = new RewardDistributor(IERC20(stakingToken), IERC20(rewardToken), owner);

        _fund(REWARD_BUDGET, DURATION);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _fund(uint256 amount, uint256 duration) internal {
        rewardToken.mint(owner, amount);
        vm.startPrank(owner);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(amount, duration);
        vm.stopPrank();
    }

    function _stake(address account, uint256 amount) internal {
        stakingToken.mint(account, amount);
        vm.startPrank(account);
        stakingToken.approve(address(distributor), amount);
        distributor.stake(amount);
        vm.stopPrank();
    }

    /// @dev Largest shortfall the accumulator design can hold back, in wei of reward token.
    ///      {RewardDistributor.rewardRemainder} retains a numerator strictly below `totalStaked`,
    ///      which is worth `totalStaked / ACC_PRECISION` wei of undistributed reward. `settlements`
    ///      covers the per-settlement floor division in {RewardDistributor.pendingRewards}.
    function _precisionFloor(uint256 settlements) internal view returns (uint256) {
        return distributor.totalStaked() / distributor.ACC_PRECISION() + settlements + 1;
    }

    // ─── Proportionality and time weighting ─────────────────────────────────

    function testEqualStakesSplitRewardsEvenly() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);

        vm.warp(block.timestamp + DURATION);

        uint256 alicePending = distributor.pendingRewards(alice);
        uint256 bobPending = distributor.pendingRewards(bob);

        assertEq(alicePending, bobPending, "equal stakes must earn equally");
        assertApproxEqAbs(
            alicePending + bobPending, REWARD_BUDGET, _precisionFloor(2), "full budget distributed"
        );
    }

    function testUnequalStakesSplitProportionally() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18);

        vm.warp(block.timestamp + DURATION);

        uint256 alicePending = distributor.pendingRewards(alice);
        uint256 bobPending = distributor.pendingRewards(bob);

        assertApproxEqRel(alicePending, bobPending * 3, 1e12, "3:1 stake yields 3:1 rewards");
        assertApproxEqAbs(
            alicePending + bobPending, REWARD_BUDGET, _precisionFloor(2), "full budget distributed"
        );
    }

    function testRewardsAreTimeWeighted() public {
        _stake(alice, 100e18);

        vm.warp(block.timestamp + DURATION / 2);
        _stake(bob, 100e18);

        vm.warp(block.timestamp + DURATION / 2);

        uint256 alicePending = distributor.pendingRewards(alice);
        uint256 bobPending = distributor.pendingRewards(bob);

        // Alice earns the whole first half plus half the second; Bob only half the second.
        assertApproxEqRel(alicePending, (REWARD_BUDGET * 3) / 4, 1e12, "alice earns 3/4");
        assertApproxEqRel(bobPending, REWARD_BUDGET / 4, 1e12, "bob earns 1/4");
    }

    function testLateStakerEarnsNothingForEarlierPeriod() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        _stake(bob, 100e18);
        assertEq(distributor.pendingRewards(bob), 0, "no retroactive rewards");
    }

    function testStakingDoesNotDiluteAlreadyEarnedRewards() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        uint256 earnedBefore = distributor.pendingRewards(alice);
        _stake(bob, 10_000e18);

        assertEq(distributor.pendingRewards(alice), earnedBefore, "past earnings are settled");
    }

    // ─── Claiming and unstaking ─────────────────────────────────────────────

    function testClaimTransfersPendingRewards() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION);

        uint256 expected = distributor.pendingRewards(alice);

        vm.prank(alice);
        uint256 claimed = distributor.claim();

        assertEq(claimed, expected, "claim returns pending amount");
        assertEq(rewardToken.balanceOf(alice), expected, "rewards received");
        assertEq(distributor.pendingRewards(alice), 0, "pending cleared");
    }

    function testClaimTwiceYieldsNothingTheSecondTime() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        distributor.claim();

        vm.prank(alice);
        vm.expectRevert(RewardDistributor.NothingToClaim.selector);
        distributor.claim();
    }

    function testUnstakePreservesAccruedRewards() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION);

        uint256 expected = distributor.pendingRewards(alice);

        vm.prank(alice);
        distributor.unstake(100e18);

        assertEq(stakingToken.balanceOf(alice), 100e18, "stake returned");
        assertEq(distributor.pendingRewards(alice), expected, "rewards survive unstaking");

        vm.prank(alice);
        assertEq(distributor.claim(), expected, "rewards still claimable");
    }

    function testUnstakeStopsFurtherAccrual() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        vm.prank(alice);
        distributor.unstake(100e18);
        uint256 atExit = distributor.pendingRewards(alice);

        vm.warp(block.timestamp + DURATION / 2);
        assertEq(distributor.pendingRewards(alice), atExit, "no accrual after full exit");
    }

    function testPartialUnstakeReducesFutureShare() public {
        _stake(alice, 200e18);
        _stake(bob, 200e18);

        vm.prank(alice);
        distributor.unstake(100e18);

        vm.warp(block.timestamp + DURATION);

        assertApproxEqRel(
            distributor.pendingRewards(bob),
            distributor.pendingRewards(alice) * 2,
            1e12,
            "bob holds twice alice's stake"
        );
    }

    function testUnstakeMoreThanStakedReverts() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InsufficientStake.selector, 100e18, 101e18)
        );
        distributor.unstake(101e18);
    }

    function testEmergencyWithdrawForfeitsRewards() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION);

        uint256 forfeited = distributor.pendingRewards(alice);
        uint256 unallocatedBefore = distributor.unallocatedRewards();
        assertGt(forfeited, 0, "there were rewards to forfeit");

        vm.prank(alice);
        distributor.emergencyWithdraw();

        assertEq(stakingToken.balanceOf(alice), 100e18, "stake returned");
        assertEq(rewardToken.balanceOf(alice), 0, "no rewards paid");
        assertEq(distributor.pendingRewards(alice), 0, "position cleared");
        assertEq(
            distributor.unallocatedRewards() - unallocatedBefore,
            forfeited,
            "forfeited rewards recoverable"
        );
    }

    // ─── Funding behaviour ──────────────────────────────────────────────────

    function testRewardsAccruedWhileEmptyBecomeUnallocated() public {
        vm.warp(block.timestamp + DURATION / 2);
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        assertApproxEqRel(
            distributor.unallocatedRewards(), REWARD_BUDGET / 2, 1e12, "empty half banked"
        );
        assertApproxEqRel(
            distributor.pendingRewards(alice), REWARD_BUDGET / 2, 1e12, "staked half earned"
        );
    }

    function testRefundRollsOverLeftover() public {
        _stake(alice, 100e18);
        vm.warp(block.timestamp + DURATION / 2);

        _fund(REWARD_BUDGET, DURATION);
        vm.warp(block.timestamp + DURATION);

        // Half of budget one, plus all of budget two, plus the rolled-over half.
        assertApproxEqRel(
            distributor.pendingRewards(alice), REWARD_BUDGET * 2, 1e12, "nothing lost on refund"
        );
    }

    function testRecoverUnallocated() public {
        vm.warp(block.timestamp + DURATION);
        distributor.updatePool();

        uint256 banked = distributor.unallocatedRewards();
        assertApproxEqAbs(banked, REWARD_BUDGET, 1, "entire budget unallocated");

        vm.prank(owner);
        distributor.recoverUnallocated(owner);

        assertEq(rewardToken.balanceOf(owner), banked, "owner recovered budget");
        assertEq(distributor.unallocatedRewards(), 0, "bank cleared");
    }

    // ─── Access control and input validation ────────────────────────────────

    function testOnlyOwnerCanFund() public {
        rewardToken.mint(alice, 1e18);
        vm.startPrank(alice);
        rewardToken.approve(address(distributor), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.fund(1e18, DURATION);
        vm.stopPrank();
    }

    function testOnlyOwnerCanRecoverUnallocated() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.recoverUnallocated(alice);
    }

    function testZeroAmountActionsRevert() public {
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.stake(0);

        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.unstake(0);

        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        distributor.emergencyWithdraw();
    }

    function testConstructorRejectsZeroTokens() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(IERC20(address(0)), IERC20(rewardToken), owner);

        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(IERC20(stakingToken), IERC20(address(0)), owner);
    }

    function testFundRejectsZeroDuration() public {
        rewardToken.mint(owner, 1e18);
        vm.startPrank(owner);
        rewardToken.approve(address(distributor), 1e18);
        vm.expectRevert(RewardDistributor.ZeroDuration.selector);
        distributor.fund(1e18, 0);
        vm.stopPrank();
    }

    // ─── Acceptance criterion: O(1) gas in staker count ─────────────────────

    /// @dev Builds a fresh distributor with `stakerCount` existing stakers and returns the gas a
    ///      brand-new staker spends on {RewardDistributor.stake}. A fresh deployment per
    ///      measurement keeps storage warmth identical across the two sample points, so any
    ///      difference in the result would be genuine per-staker cost.
    function _measureStakeGas(uint256 stakerCount) internal returns (uint256) {
        RewardDistributor pool =
            new RewardDistributor(IERC20(stakingToken), IERC20(rewardToken), owner);

        rewardToken.mint(owner, REWARD_BUDGET);
        vm.startPrank(owner);
        rewardToken.approve(address(pool), REWARD_BUDGET);
        pool.fund(REWARD_BUDGET, DURATION);
        vm.stopPrank();

        for (uint256 i = 0; i < stakerCount; ++i) {
            address staker = address(uint160(0x10000 + i));
            stakingToken.mint(staker, 100e18);
            vm.startPrank(staker);
            stakingToken.approve(address(pool), 100e18);
            pool.stake(100e18);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 1 days);

        address newcomer = address(uint160(0x900000));
        stakingToken.mint(newcomer, 100e18);
        vm.startPrank(newcomer);
        stakingToken.approve(address(pool), 100e18);

        uint256 before = gasleft();
        pool.stake(100e18);
        uint256 used = before - gasleft();
        vm.stopPrank();

        return used;
    }

    /// @dev Same shape as {_measureStakeGas}, but measures a claim by an established staker.
    function _measureClaimGas(uint256 stakerCount) internal returns (uint256) {
        RewardDistributor pool =
            new RewardDistributor(IERC20(stakingToken), IERC20(rewardToken), owner);

        rewardToken.mint(owner, REWARD_BUDGET);
        vm.startPrank(owner);
        rewardToken.approve(address(pool), REWARD_BUDGET);
        pool.fund(REWARD_BUDGET, DURATION);
        vm.stopPrank();

        for (uint256 i = 0; i < stakerCount; ++i) {
            address staker = address(uint160(0x10000 + i));
            stakingToken.mint(staker, 100e18);
            vm.startPrank(staker);
            stakingToken.approve(address(pool), 100e18);
            pool.stake(100e18);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + 1 days);

        address claimant = address(uint160(0x10000));
        vm.startPrank(claimant);
        uint256 before = gasleft();
        pool.claim();
        uint256 used = before - gasleft();
        vm.stopPrank();

        return used;
    }

    /// @dev A push-based distributor would spend at least one `SSTORE` and one balance read per
    ///      staker here, so a 5x larger staker set would cost tens of thousands of gas more. The
    ///      assertion that matters is the second one: growing the set from 200 to 1000 stakers must
    ///      add exactly zero gas. The first assertion allows one cold slot transition, because
    ///      whether {RewardDistributor.rewardRemainder} moves from zero to non-zero depends on
    ///      whether the accrual division happened to be exact, which varies with pool size but is
    ///      a one-off 20k, not a per-staker cost.
    uint256 internal constant COLD_SLOT_ALLOWANCE = 25_000;

    function testStakeGasIsConstantInStakerCount() public {
        uint256 gasSmall = _measureStakeGas(10);
        uint256 gasMedium = _measureStakeGas(200);
        uint256 gasLarge = _measureStakeGas(1000);

        emit log_named_uint("stake gas @ 10 stakers  ", gasSmall);
        emit log_named_uint("stake gas @ 200 stakers ", gasMedium);
        emit log_named_uint("stake gas @ 1000 stakers", gasLarge);

        assertEq(gasLarge, gasMedium, "5x more stakers must add no gas");
        assertApproxEqAbs(
            gasMedium, gasSmall, COLD_SLOT_ALLOWANCE, "stake cost is bounded by a constant"
        );
    }

    function testClaimGasIsConstantInStakerCount() public {
        uint256 gasSmall = _measureClaimGas(10);
        uint256 gasMedium = _measureClaimGas(200);
        uint256 gasLarge = _measureClaimGas(1000);

        emit log_named_uint("claim gas @ 10 stakers  ", gasSmall);
        emit log_named_uint("claim gas @ 200 stakers ", gasMedium);
        emit log_named_uint("claim gas @ 1000 stakers", gasLarge);

        assertEq(gasLarge, gasMedium, "5x more stakers must add no gas");
        assertApproxEqAbs(
            gasMedium, gasSmall, COLD_SLOT_ALLOWANCE, "claim cost is bounded by a constant"
        );
    }

    function testDistributionSurvivesLargeStakerSet() public {
        uint256 count = 1000;
        for (uint256 i = 0; i < count; ++i) {
            _stake(address(uint160(0x20000 + i)), 100e18);
        }

        vm.warp(block.timestamp + DURATION);

        uint256 total;
        for (uint256 i = 0; i < count; ++i) {
            address staker = address(uint160(0x20000 + i));
            vm.prank(staker);
            total += distributor.claim();
        }

        assertApproxEqAbs(
            total, REWARD_BUDGET, _precisionFloor(count), "budget conserved across 1000 stakers"
        );
    }

    // ─── Acceptance criterion: precision at 1e18 scaling ────────────────────

    function testNoValueCreatedOrLostAcrossManyClaims() public {
        _stake(alice, 1e18);
        _stake(bob, 333e18);
        _stake(carol, 7_777_777e18);

        // Repeated interleaved claims maximise exposure to per-operation truncation.
        for (uint256 i = 0; i < 50; ++i) {
            vm.warp(block.timestamp + DURATION / 100);
            vm.prank(alice);
            distributor.claim();
            vm.prank(bob);
            distributor.claim();
        }

        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        distributor.claim();
        vm.prank(bob);
        distributor.claim();
        vm.prank(carol);
        distributor.claim();

        uint256 paid = rewardToken.balanceOf(alice) + rewardToken.balanceOf(bob)
            + rewardToken.balanceOf(carol);

        assertLe(paid, REWARD_BUDGET, "must never pay out more than was funded");
        assertApproxEqAbs(
            paid, REWARD_BUDGET, _precisionFloor(103), "truncation loss stays within the floor"
        );
    }

    function testSingleStakerRecoversEssentiallyTheWholeBudget() public {
        _stake(alice, 1e18);
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        uint256 claimed = distributor.claim();

        assertApproxEqAbs(claimed, REWARD_BUDGET, _precisionFloor(1), "lone staker earns budget");
    }

    function testPrecisionHoldsWithExtremeStakeRatio() public {
        // A 1 wei position beside a 1e24 position: the small holder must still be paid its
        // proportional share rather than being rounded to zero.
        _stake(alice, 1);
        _stake(bob, 1e24);

        vm.warp(block.timestamp + DURATION);

        uint256 alicePending = distributor.pendingRewards(alice);
        uint256 expected = REWARD_BUDGET / (1e24 + 1);

        assertApproxEqAbs(alicePending, expected, 1, "dust position paid proportionally");
    }

    function testAccumulatorSurvivesTinySupplyThenLargeSupply() public {
        // Staking 1 wei drives accRewardPerShare extremely high; a later large stake then
        // multiplies against it. This is the product that overflows a naive uint256 mul,
        // and is why settlement goes through Math.mulDiv.
        _stake(alice, 1);
        vm.warp(block.timestamp + DURATION / 2);

        _stake(bob, 1e30);
        vm.warp(block.timestamp + DURATION / 2);

        assertGt(distributor.accRewardPerShare(), 1e40, "accumulator grew as expected");

        vm.prank(alice);
        uint256 aliceClaimed = distributor.claim();
        vm.prank(bob);
        uint256 bobClaimed = distributor.claim();

        assertApproxEqRel(aliceClaimed, REWARD_BUDGET / 2, 1e12, "alice keeps her first half");
        assertLe(aliceClaimed + bobClaimed, REWARD_BUDGET, "budget never exceeded");
    }

    function testFuzzTwoStakersSplitProportionally(uint128 aliceStake, uint128 bobStake) public {
        aliceStake = uint128(bound(aliceStake, 1e6, type(uint96).max));
        bobStake = uint128(bound(bobStake, 1e6, type(uint96).max));

        _stake(alice, aliceStake);
        _stake(bob, bobStake);

        vm.warp(block.timestamp + DURATION);

        uint256 alicePending = distributor.pendingRewards(alice);
        uint256 bobPending = distributor.pendingRewards(bob);

        assertLe(alicePending + bobPending, REWARD_BUDGET, "never overpays");
        assertApproxEqAbs(
            alicePending + bobPending, REWARD_BUDGET, _precisionFloor(2), "never meaningfully loses"
        );

        uint256 total = uint256(aliceStake) + uint256(bobStake);
        assertApproxEqRel(
            alicePending,
            (REWARD_BUDGET * uint256(aliceStake)) / total,
            1e12,
            "alice paid in proportion to stake"
        );
    }

    function testFuzzClaimNeverExceedsFunding(uint96 stakeAmount, uint32 elapsed) public {
        stakeAmount = uint96(bound(stakeAmount, 1, type(uint96).max));
        uint256 warpBy = bound(elapsed, 0, DURATION * 2);

        _stake(alice, stakeAmount);
        vm.warp(block.timestamp + warpBy);

        uint256 pending = distributor.pendingRewards(alice);
        assertLe(pending, REWARD_BUDGET, "cannot earn beyond the funded budget");

        uint256 capped = warpBy < DURATION ? warpBy : DURATION;
        uint256 expected = (REWARD_BUDGET * capped) / DURATION;
        assertApproxEqAbs(pending, expected, _precisionFloor(2), "earnings track elapsed linearly");
    }
}
