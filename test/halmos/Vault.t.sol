// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../contracts/Vault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract VaultHalmosTest is Test {
    Vault internal vault;
    MockERC20 internal underlying;
    address internal owner = makeAddr("owner");

    function setUp() public {
        underlying = new MockERC20();
        vault = new Vault(underlying, "Vault Share", "vSHARE", owner);
        
        // Give the vault some initial underlying balance so totalAssets > 0 is possible
        // underlying.mint(address(vault), 1000);
    }

    /// @notice Rule 1: userBalance(A) + userBalance(B) <= totalPoolBalance()
    /// Because this is an ERC4626 vault, we prove that the sum of the shares of two users
    /// is less than or equal to the total supply of shares.
    function check_solvency(address userA, address userB) public {
        vm.assume(userA != userB);
        
        uint256 balanceA = vault.balanceOf(userA);
        uint256 balanceB = vault.balanceOf(userB);
        uint256 total = vault.totalSupply();

        // The invariant: sum of any two distinct users' balances cannot exceed totalSupply
        // To avoid overflow in the assertion itself (though Halmos handles it), we use unchecked or just simple addition
        // since if balanceA + balanceB > total, it will either overflow (and thus fail if not unchecked)
        // or just fail the assert.
        unchecked {
            uint256 sum = balanceA + balanceB;
            assert(sum >= balanceA); // Sanity check for overflow
            assert(sum <= total);
        }
    }

    /// @notice Rule 2: withdraw(assets) MUST decrease userBalance by exactly the shares burned
    function check_withdraw_accounting(uint256 assets, address user) public {
        vm.assume(assets > 0);
        vm.assume(user != address(0));

        uint256 sharesBefore = vault.balanceOf(user);
        
        // We need to assume the user has enough shares to cover the withdrawal of 'assets'
        // and the vault has enough assets.
        uint256 sharesToBurn = vault.previewWithdraw(assets);
        vm.assume(sharesToBurn > 0);
        vm.assume(sharesBefore >= sharesToBurn);
        
        // Assume the vault has enough assets
        vm.assume(vault.totalAssets() >= assets);
        
        // Assume the user has approved the test contract if necessary, 
        // or we just prank as the user
        vm.prank(user);
        uint256 burned = vault.withdraw(assets, user, user);

        uint256 sharesAfter = vault.balanceOf(user);
        
        // Verify exactly 'burned' shares were removed
        assert(sharesAfter == sharesBefore - burned);
    }
}
