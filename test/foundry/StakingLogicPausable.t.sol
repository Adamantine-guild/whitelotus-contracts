// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingLogic} from "../../contracts/core/StakingLogic.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Coverage for the emergency circuit breaker added in issue #43.
///      Contract: new stakes halt while paused, unstakes remain available so a
///      halt can never trap user funds, and only the owner can toggle pause.
contract StakingLogicPausableTest is Test {
    StakingLogic internal staking;
    address internal owner = address(0x0A11CE);
    address internal alice = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        StakingLogic impl = new StakingLogic();
        bytes memory initData = abi.encodeWithSelector(StakingLogic.initialize.selector, owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        staking = StakingLogic(address(proxy));
    }

    function test_StartsUnpaused() public view {
        assertFalse(staking.paused());
    }

    function test_OwnerCanPauseAndUnpause() public {
        vm.prank(owner);
        staking.pause();
        assertTrue(staking.paused());

        vm.prank(owner);
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_PauseBlocksNewStakes() public {
        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        staking.stake(100e18);

        assertEq(staking.balances(alice), 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_PauseBlocksStakeWithZeroAmountToo() public {
        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause takes precedence over ZeroAmount
        staking.stake(0);
    }

    function test_UnstakeRemainsAvailableWhilePaused() public {
        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        staking.unstake(40e18);

        assertEq(staking.balances(alice), 60e18);
        assertEq(staking.totalStaked(), 60e18);
    }

    function test_FullExitRemainsAvailableWhilePaused() public {
        vm.prank(alice);
        staking.stake(50e18);

        vm.prank(owner);
        staking.pause();

        vm.prank(alice);
        staking.unstake(50e18);

        assertEq(staking.balances(alice), 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_UnpauseRestoresStaking() public {
        vm.prank(owner);
        staking.pause();
        vm.prank(owner);
        staking.unpause();

        vm.prank(alice);
        staking.stake(100e18);

        assertEq(staking.balances(alice), 100e18);
        assertEq(staking.totalStaked(), 100e18);
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        staking.pause();

        assertFalse(staking.paused());
    }

    function test_OnlyOwnerCanUnpause() public {
        vm.prank(owner);
        staking.pause();

        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        staking.unpause();

        assertTrue(staking.paused());
    }

    function test_PauseDoesNotAffectBalances() public {
        vm.prank(alice);
        staking.stake(25e18);

        vm.prank(owner);
        staking.pause();

        // Pause is a control surface, not an accounting one: balances are untouched.
        assertEq(staking.balances(alice), 25e18);
        assertEq(staking.totalStaked(), 25e18);

        vm.prank(owner);
        staking.unpause();

        assertEq(staking.balances(alice), 25e18);
        assertEq(staking.totalStaked(), 25e18);
    }
}
