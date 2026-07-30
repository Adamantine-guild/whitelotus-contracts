// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingLogic} from "../../contracts/core/StakingLogic.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract StakingLogicTest is Test {
    StakingLogic internal staking;
    address internal alice = address(0xB0B);
    address internal bob = address(0xCA11);

    function setUp() public {
        StakingLogic impl = new StakingLogic();
        bytes memory initData = abi.encodeWithSelector(StakingLogic.initialize.selector, address(this));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        staking = StakingLogic(address(proxy));
    }

    function test_ZeroAddressInitializerReverts() public {
        StakingLogic impl = new StakingLogic();
        bytes memory initData = abi.encodeWithSelector(StakingLogic.initialize.selector, address(0));
        vm.expectRevert(StakingLogic.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_StakeWithZeroAmountReverts() public {
        vm.expectRevert(StakingLogic.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_StakeIncreasesBalance() public {
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 100e18);
        vm.prank(alice);
        staking.stake(100e18);
        assertEq(staking.balances(alice), 100e18);
        assertEq(staking.totalStaked(), 100e18);
    }

    function test_StakeMultipleUsers() public {
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 50e18);
        vm.prank(alice);
        staking.stake(50e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(bob, 30e18);
        vm.prank(bob);
        staking.stake(30e18);
        assertEq(staking.balances(alice), 50e18);
        assertEq(staking.balances(bob), 30e18);
        assertEq(staking.totalStaked(), 80e18);
    }

    function test_UnstakeWithZeroAmountReverts() public {
        vm.expectRevert(StakingLogic.ZeroAmount.selector);
        staking.unstake(0);
    }

    function test_UnstakeExceedingBalanceReverts() public {
        vm.prank(alice);
        staking.stake(10e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StakingLogic.InsufficientStake.selector, 10e18, 20e18)
        );
        staking.unstake(20e18);
    }

    function test_UnstakePartial() public {
        vm.prank(alice);
        staking.stake(100e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Unstaked(alice, 30e18);
        vm.prank(alice);
        staking.unstake(30e18);
        assertEq(staking.balances(alice), 70e18);
        assertEq(staking.totalStaked(), 70e18);
    }

    function test_UnstakeFull() public {
        vm.prank(alice);
        staking.stake(50e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Unstaked(alice, 50e18);
        vm.prank(alice);
        staking.unstake(50e18);
        assertEq(staking.balances(alice), 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_UnstakeWithoutStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StakingLogic.InsufficientStake.selector, 0, 1)
        );
        staking.unstake(1);
    }

    function test_StakeAccumulatesAcrossCalls() public {
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 10e18);
        staking.stake(10e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 20e18);
        staking.stake(20e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 30e18);
        staking.stake(30e18);
        vm.stopPrank();
        assertEq(staking.balances(alice), 60e18);
        assertEq(staking.totalStaked(), 60e18);
    }

    function test_StakeAndUnstakeMultiple() public {
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 100e18);
        staking.stake(100e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Unstaked(alice, 40e18);
        staking.unstake(40e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Staked(alice, 20e18);
        staking.stake(20e18);
        vm.expectEmit(true, true, false, false);
        emit StakingLogic.Unstaked(alice, 80e18);
        staking.unstake(80e18);
        vm.stopPrank();
        assertEq(staking.balances(alice), 0);
        assertEq(staking.totalStaked(), 0);
    }
}
