// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WhiteLotusERC4626} from "../../contracts/vaults/WhiteLotusERC4626.sol";
import {VaultProxy} from "../../contracts/vaults/VaultProxy.sol";
import {StakingLogic} from "../../contracts/core/StakingLogic.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {IStrategy} from "../../contracts/interfaces/IStrategy.sol";

/// @dev Strategy that reenters the vault mid-call when armed. Implements {IStrategy} directly
///      (rather than extending BaseStrategy) so the attack can be wired into any hook.
contract MaliciousStrategy is IStrategy {
    IERC20 private immutable _asset;
    address private immutable _vault;

    /// @notice When true, {harvest} calls back into `vault.harvest(address(this))`.
    bool public reenterOnHarvest;
    /// @notice When true, {withdraw} calls back into `vault.rebalance()`.
    bool public reenterOnWithdraw;

    constructor(IERC20 asset_, address vault_) {
        _asset = asset_;
        _vault = vault_;
    }

    function arm(bool onHarvest, bool onWithdraw) external {
        reenterOnHarvest = onHarvest;
        reenterOnWithdraw = onWithdraw;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function vault() external view returns (address) {
        return _vault;
    }

    function totalAssets() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function availableLiquidity() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function deposit(uint256) external {}

    function withdraw(uint256) external returns (uint256 withdrawn) {
        if (reenterOnWithdraw) {
            WhiteLotusERC4626(_vault).rebalance();
        }
        return 0;
    }

    function withdrawAll() external pure returns (uint256) {
        return 0;
    }

    function harvest() external {
        if (reenterOnHarvest) {
            WhiteLotusERC4626(_vault).harvest(address(this));
        }
    }
}

/// @dev Covers issue #84 — reentrancy guards on WhiteLotusERC4626's harvest/harvestAll/rebalance
///      (the only entry points here with unguarded external calls) and StakingLogic's stake/unstake
///      (defense-in-depth; see the note on {testStakeGuardBlocksForcedReentry} for why that one
///      cannot be exercised via an actual attack).
contract VaultStakingReentrancyTest is Test {
    using stdStorage for StdStorage;

    MockERC20 internal asset;
    WhiteLotusERC4626 internal vault;
    MaliciousStrategy internal strategy;

    StakingLogic internal staking;

    address internal governor = makeAddr("governor");
    address internal keeper = makeAddr("keeper");
    address internal user = makeAddr("user");

    // OZ v4.9.6 ReentrancyGuard(Upgradeable) revert reason (string-based, not a custom error).
    bytes internal constant REENTRANT_REVERT = "ReentrancyGuard: reentrant call";

    function setUp() public {
        // ── Vault behind its UUPS proxy ──────────────────────────────────────
        asset = new MockERC20("Mock Asset", "MASSET", 18);

        WhiteLotusERC4626 impl = new WhiteLotusERC4626();
        bytes memory initData = abi.encodeWithSelector(
            WhiteLotusERC4626.initialize.selector,
            IERC20(address(asset)),
            "White Lotus Vault",
            "wlMASSET",
            governor
        );
        vault = WhiteLotusERC4626(address(new VaultProxy(address(impl), initData)));

        // NOTE: initialize() has a separate, pre-existing bug (out of scope for #84, and already
        // being fixed elsewhere per PR #157's own description) where it never grants `governance_`
        // any role, including DEFAULT_ADMIN_ROLE — so grantRole() has no caller who could use it.
        // Force the roles directly via storage so this suite can exercise the guarded functions.
        stdstore.target(address(vault)).sig("hasRole(bytes32,address)")
            .with_key(vault.GOVERNOR_ROLE()).with_key(governor).checked_write(true);
        stdstore.target(address(vault)).sig("hasRole(bytes32,address)")
            .with_key(vault.KEEPER_ROLE()).with_key(keeper).checked_write(true);

        strategy = new MaliciousStrategy(IERC20(address(asset)), address(vault));
        vm.prank(governor);
        vault.addStrategy(address(strategy), 5_000); // 50% target

        // ── StakingLogic behind its own UUPS proxy ───────────────────────────
        StakingLogic stakingImpl = new StakingLogic();
        bytes memory stakingInit =
            abi.encodeWithSelector(StakingLogic.initialize.selector, governor);
        staking = StakingLogic(address(new ERC1967Proxy(address(stakingImpl), stakingInit)));
    }

    // ── WhiteLotusERC4626: reentrant calls blocked ──────────────────────────

    function test_ReentrantHarvestReverts() public {
        strategy.arm(true, false);

        vm.prank(keeper);
        vm.expectRevert(REENTRANT_REVERT);
        vault.harvest(address(strategy));
    }

    function test_ReentrantHarvestAllReverts() public {
        // harvestAll() loops _harvest() (which triggers the reentry) before it ever reaches
        // _rebalance(), so arming the same hook as the single-strategy harvest test is sufficient.
        strategy.arm(true, false);

        vm.prank(keeper);
        vm.expectRevert(REENTRANT_REVERT);
        vault.harvestAll();
    }

    function test_ReentrantRebalanceReverts() public {
        // Fund the strategy above its 50% target so _rebalance() actually calls
        // strategy.withdraw(), which is where the reentry is armed.
        asset.mint(address(strategy), 1_000e18);
        strategy.arm(false, true);

        vm.prank(keeper);
        vm.expectRevert(REENTRANT_REVERT);
        vault.rebalance();
    }

    // ── WhiteLotusERC4626: normal flows unaffected ──────────────────────────

    function test_HarvestNormalFlowWorks() public {
        asset.mint(address(strategy), 100e18);

        vm.prank(keeper);
        vault.harvest(address(strategy)); // must not revert
    }

    function test_HarvestAllNormalFlowWorks() public {
        asset.mint(address(strategy), 100e18);

        vm.prank(keeper);
        vault.harvestAll(); // must not revert
    }

    function test_RebalanceNormalFlowWorks() public {
        asset.mint(user, 1_000e18);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18, user);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance(); // must not revert

        // 50% target actually moved into the strategy.
        assertEq(strategy.totalAssets(), 500e18);
    }

    function test_DepositMintWithdrawRedeemStillWork() public {
        asset.mint(user, 1_000e18);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);

        uint256 shares = vault.deposit(100e18, user);
        assertGt(shares, 0);

        uint256 moreShares = vault.mint(50e18, user);
        assertGt(moreShares, 0);

        uint256 assetsOut = vault.withdraw(50e18, user, user);
        assertGt(assetsOut, 0);

        uint256 redeemed = vault.redeem(vault.balanceOf(user), user, user);
        assertGt(redeemed, 0);
        vm.stopPrank();
    }

    // ── StakingLogic: normal flow unaffected ────────────────────────────────

    function test_StakeUnstakeNormalFlowWorks() public {
        vm.startPrank(user);
        staking.stake(100e18);
        assertEq(staking.balances(user), 100e18);

        staking.unstake(40e18);
        assertEq(staking.balances(user), 60e18);
        vm.stopPrank();
    }

    // ── StakingLogic: guard is mechanically live, despite no exploitable path ──

    /// @dev stake()/unstake() make no external calls, so nothing in this codebase can drive a
    ///      real reentrant call into them — there is no callback for an attacker to hook. Rather
    ///      than fabricate an "attack" that cannot actually trigger reentrancy (which would prove
    ///      nothing), this forces the guard's own storage slot into the `_ENTERED` state directly
    ///      and confirms `nonReentrant` still rejects the call, then confirms it clears correctly
    ///      afterwards. Slot 251 is StakingLogic's `_status` slot, from
    ///      `forge inspect StakingLogic storage-layout`.
    function test_StakeGuardBlocksForcedReentry() public {
        uint256 statusSlot = 251;
        bytes32 ENTERED = bytes32(uint256(2));
        bytes32 NOT_ENTERED = bytes32(uint256(1));

        vm.store(address(staking), bytes32(statusSlot), ENTERED);

        vm.expectRevert(REENTRANT_REVERT);
        staking.stake(1e18);

        // Guard must not be left stuck — restoring NOT_ENTERED lets calls through again.
        vm.store(address(staking), bytes32(statusSlot), NOT_ENTERED);
        staking.stake(1e18);
        assertEq(staking.balances(address(this)), 1e18);
    }
}
