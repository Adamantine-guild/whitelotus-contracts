// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title RewardDistributor - Accumulator-based staking reward distribution
/// @notice Distributes a reward token to stakers of a staking token at a constant per-second rate,
///         proportional to each staker's share of the pool over time.
/// @dev Uses the accumulator ("reward per share") pattern rather than iterating stakers.
///
///      **Why an accumulator:**
///      A push model pays every staker inside one transaction, so its cost grows with the number
///      of stakers and eventually exceeds the block gas limit, permanently bricking distribution.
///      Here the contract stores a single running total, {accRewardPerShare}, defined as the
///      cumulative reward owed to one staked unit since deployment. Every entry point touches a
///      fixed number of slots, so cost is O(1) in the staker count.
///
///      **The accounting identity:**
///      For a user holding `amount` staked units, the reward they have ever been entitled to is
///      `amount * accRewardPerShare`. {UserInfo.rewardDebt} records the value that expression had
///      the last time their position was settled, so
///          pending = amount * accRewardPerShare - rewardDebt
///      is exactly what accrued since. Changing `amount` therefore requires only settling the
///      pending amount and rewriting `rewardDebt` — never a loop.
///
///      **Precision:**
///      {accRewardPerShare} is scaled by {ACC_PRECISION} (1e18) because per-share rewards are
///      almost always fractional. Three sources of truncation are addressed rather than tolerated:
///
///      1. Rate derivation (`budget / duration`) would discard up to `duration - 1` wei of every
///         funded budget. {rewardRateScaled} keeps the rate pre-scaled by {ACC_PRECISION}, cutting
///         that loss to below one wei per period.
///      2. Accrual (`scaledReward / totalStaked`) leaves a remainder each update. That remainder
///         is carried in {rewardRemainder} and folded into the next update's numerator, so
///         truncated units are deferred, never discarded.
///      3. Settlement (`amount * accRewardPerShare / ACC_PRECISION`) can overflow a naive
///         `uint256` product when {accRewardPerShare} has grown large after periods of very small
///         `totalStaked`. {Math.mulDiv} carries the full 512-bit intermediate, so the division
///         happens before any narrowing.
///
///      The residual precision floor is therefore `totalStaked / ACC_PRECISION` wei held back in
///      {rewardRemainder} at any instant — under one wei for pools smaller than 1e18 staked units,
///      and vanishing relative to the budget at every realistic scale above that.
///
///      Rewards that accrue while nothing is staked have no one to be credited to. They are
///      banked in {unallocatedRewards} and recoverable by the owner instead of being silently
///      stranded in the contract.
///
///      **Token assumptions:**
///      All accounting is internal; no path reads `balanceOf` to derive a balance. This keeps the
///      contract correct when the staking and reward tokens are the same address. Fee-on-transfer
///      and rebasing tokens are NOT supported — a transfer that delivers fewer units than
///      requested would leave {totalStaked} overstated.
contract RewardDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fixed-point scale applied to {accRewardPerShare}.
    uint256 public constant ACC_PRECISION = 1e18;

    /// @notice Per-staker position and settlement checkpoint.
    /// @param amount     Staked units currently held by the user.
    /// @param rewardDebt Value of `amount * accRewardPerShare / ACC_PRECISION` at last settlement.
    /// @param accrued    Settled rewards awaiting transfer via {claim}.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 accrued;
    }

    /// @notice Token users stake.
    IERC20 public immutable stakingToken;

    /// @notice Token distributed as reward.
    IERC20 public immutable rewardToken;

    /// @notice Cumulative reward owed per staked unit, scaled by {ACC_PRECISION}.
    uint256 public accRewardPerShare;

    /// @notice Total units currently staked across all users.
    uint256 public totalStaked;

    /// @notice Reward tokens released per second, scaled by {ACC_PRECISION}.
    /// @dev Held pre-scaled so that deriving a whole-token rate from a budget and a duration does
    ///      not truncate. A plain `budget / duration` discards up to `duration - 1` wei of the
    ///      budget outright; carrying the extra 1e18 factor pushes that error below one wei.
    uint256 public rewardRateScaled;

    /// @notice Timestamp the current reward period ends.
    uint256 public periodFinish;

    /// @notice Timestamp {accRewardPerShare} was last advanced to.
    uint256 public lastUpdateTime;

    /// @notice Undistributed numerator carried between accruals to avoid truncation loss.
    uint256 public rewardRemainder;

    /// @notice Reward tokens that accrued with nothing staked, plus funding-rate dust.
    uint256 public unallocatedRewards;

    mapping(address account => UserInfo info) public userInfo;

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error InsufficientStake(uint256 staked, uint256 requested);
    error NothingToClaim();
    error NoUnallocatedRewards();

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event EmergencyWithdrawn(address indexed account, uint256 amount, uint256 forfeited);
    event RewardsFunded(uint256 amount, uint256 duration, uint256 rewardPerSecond);
    event UnallocatedRewardsRecovered(address indexed to, uint256 amount);

    /// @param stakingToken_ Token accepted for staking.
    /// @param rewardToken_  Token paid out as reward. May equal `stakingToken_`.
    /// @param owner_        Address permitted to fund periods and recover unallocated rewards.
    constructor(IERC20 stakingToken_, IERC20 rewardToken_, address owner_) Ownable() {
        _transferOwnership(owner_);
        if (address(stakingToken_) == address(0)) revert ZeroAddress();
        if (address(rewardToken_) == address(0)) revert ZeroAddress();

        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        lastUpdateTime = block.timestamp;
    }

    /// @notice Whole reward tokens released per second during an active period.
    function rewardPerSecond() external view returns (uint256) {
        return rewardRateScaled / ACC_PRECISION;
    }

    /// @notice Rewards earned but not yet transferred to `account`.
    /// @dev Mirrors {_settle} against a projected accumulator so the value is correct without
    ///      requiring a prior {updatePool} call.
    function pendingRewards(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        uint256 projected = accRewardPerShare;
        uint256 supply = totalStaked;
        uint256 upTo = Math.min(block.timestamp, periodFinish);

        if (upTo > lastUpdateTime && supply > 0) {
            uint256 scaledReward = (upTo - lastUpdateTime) * rewardRateScaled;
            projected += (scaledReward + rewardRemainder) / supply;
        }

        uint256 entitled = Math.mulDiv(user.amount, projected, ACC_PRECISION);
        return user.accrued + entitled - user.rewardDebt;
    }

    /// @notice Advance {accRewardPerShare} to the present.
    /// @dev Permissionless; every state-changing entry point calls this first.
    function updatePool() public {
        uint256 upTo = Math.min(block.timestamp, periodFinish);
        if (upTo <= lastUpdateTime) return;

        uint256 elapsed = upTo - lastUpdateTime;
        uint256 scaledReward = elapsed * rewardRateScaled;
        uint256 supply = totalStaked;

        if (supply == 0) {
            unallocatedRewards += scaledReward / ACC_PRECISION;
        } else if (scaledReward > 0 || rewardRemainder > 0) {
            uint256 numerator = scaledReward + rewardRemainder;
            accRewardPerShare += numerator / supply;
            rewardRemainder = numerator % supply;
        }

        lastUpdateTime = upTo;
    }

    /// @notice Stake `amount` units of {stakingToken}.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        _settle(user);

        user.amount += amount;
        totalStaked += amount;
        _writeRewardDebt(user);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw `amount` staked units, keeping any rewards accrued so far claimable.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        if (user.amount < amount) revert InsufficientStake(user.amount, amount);
        _settle(user);

        unchecked {
            user.amount -= amount;
        }
        totalStaked -= amount;
        _writeRewardDebt(user);

        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Transfer all settled rewards to the caller.
    function claim() external nonReentrant returns (uint256 amount) {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        _settle(user);
        _writeRewardDebt(user);

        amount = user.accrued;
        if (amount == 0) revert NothingToClaim();
        user.accrued = 0;

        rewardToken.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Withdraw the caller's entire stake, forfeiting all unclaimed rewards.
    /// @dev Escape hatch that never touches {rewardToken}, so it stays callable even if reward
    ///      transfers would revert. Forfeited rewards return to {unallocatedRewards}.
    function emergencyWithdraw() external nonReentrant returns (uint256 amount) {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];

        amount = user.amount;
        if (amount == 0) revert ZeroAmount();

        uint256 forfeited = user.accrued + _pending(user);

        user.amount = 0;
        user.rewardDebt = 0;
        user.accrued = 0;
        totalStaked -= amount;
        unallocatedRewards += forfeited;

        stakingToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawn(msg.sender, amount, forfeited);
    }

    /// @notice Fund a reward period of `duration` seconds with `amount` reward tokens.
    /// @dev Rewards left over from an unfinished period are rolled into the new rate rather than
    ///      being stranded. All arithmetic stays in {ACC_PRECISION}-scaled units, so the only
    ///      truncation is the final `/ duration`, which discards strictly less than one wei of
    ///      budget across the entire period.
    function fund(uint256 amount, uint256 duration) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();

        updatePool();

        uint256 leftoverScaled;
        if (block.timestamp < periodFinish) {
            leftoverScaled = (periodFinish - block.timestamp) * rewardRateScaled;
        }

        rewardRateScaled = (amount * ACC_PRECISION + leftoverScaled) / duration;

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsFunded(amount, duration, rewardRateScaled / ACC_PRECISION);
    }

    /// @notice Sweep rewards that accrued with an empty pool, plus funding dust, to `to`.
    function recoverUnallocated(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();

        updatePool();

        amount = unallocatedRewards;
        if (amount == 0) revert NoUnallocatedRewards();
        unallocatedRewards = 0;

        rewardToken.safeTransfer(to, amount);
        emit UnallocatedRewardsRecovered(to, amount);
    }

    /// @dev Move everything earned since the last checkpoint into {UserInfo.accrued}.
    function _settle(UserInfo storage user) private {
        uint256 pending = _pending(user);
        if (pending > 0) user.accrued += pending;
    }

    /// @dev Rewards earned since `user.rewardDebt` was written.
    function _pending(UserInfo storage user) private view returns (uint256) {
        return Math.mulDiv(user.amount, accRewardPerShare, ACC_PRECISION) - user.rewardDebt;
    }

    /// @dev Re-anchor the user's checkpoint to the current accumulator and stake size.
    function _writeRewardDebt(UserInfo storage user) private {
        user.rewardDebt = Math.mulDiv(user.amount, accRewardPerShare, ACC_PRECISION);
    }
    /// @notice Claim rewards in batch for multiple token IDs / accounts.
    /// @param tokenIds Array of token IDs or staking identifiers to claim rewards for.
    /// @return totalClaimed The total amount of reward tokens disbursed to the caller.
    function batchClaimRewards(uint256[] calldata tokenIds) external nonReentrant returns (uint256 totalClaimed) {
        uint256 len = tokenIds.length;
        if (len == 0) revert ZeroAmount();

        updatePool();

        address account = msg.sender;
        IERC20 token = rewardToken;

        for (uint256 i = 0; i < len; ) {
            UserInfo storage user = userInfo[account];

            _settle(user);
            _writeRewardDebt(user);

            uint256 amount = user.accrued;
            if (amount > 0) {
                user.accrued = 0;
                totalClaimed += amount;
            }

            unchecked {
                ++i;
            }
        }

        if (totalClaimed == 0) revert NothingToClaim();

        token.safeTransfer(account, totalClaimed);
        emit Claimed(account, totalClaimed);
    }

    /// @notice Claim rewards in batch for multiple token IDs / accounts.
    /// @param tokenIds Array of token IDs or staking identifiers to claim rewards for.
    /// @return totalClaimed The total amount of reward tokens disbursed to the caller.
    function batchClaimRewards(uint256[] calldata tokenIds) external nonReentrant returns (uint256 totalClaimed) {
        uint256 len = tokenIds.length;
        if (len == 0) revert ZeroAmount();

        updatePool();

        address account = msg.sender;
        IERC20 token = rewardToken;

        for (uint256 i = 0; i < len; ) {
            UserInfo storage user = userInfo[account];

            _settle(user);
            _writeRewardDebt(user);

            uint256 amount = user.accrued;
            if (amount > 0) {
                user.accrued = 0;
                totalClaimed += amount;
            }

            unchecked {
                ++i;
            }
        }

        if (totalClaimed == 0) revert NothingToClaim();

        token.safeTransfer(account, totalClaimed);
        emit Claimed(account, totalClaimed);
    }

}
