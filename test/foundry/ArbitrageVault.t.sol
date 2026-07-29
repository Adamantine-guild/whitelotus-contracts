// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ArbitrageVault, IERC3156FlashLender} from "../../contracts/strategies/ArbitrageVault.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockFlashLender is IERC3156FlashLender {
    MockERC20 public token;
    uint256 public feeRate = 10; // 1% fee (10/1000)

    constructor(MockERC20 token_) {
        token = token_;
    }

    function flashFee(address _token, uint256 amount) public view returns (uint256) {
        require(_token == address(token), "Unsupported token");
        return (amount * feeRate) / 1000;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address _token,
        uint256 amount,
        bytes calldata data
    ) external override returns (bool) {
        require(_token == address(token), "Unsupported token");
        uint256 fee = flashFee(_token, amount);

        // Mint loan amount directly to receiver
        token.mint(address(receiver), amount);

        // Execute borrower callback
        bytes32 result = receiver.onFlashLoan(
            address(receiver), // initiator is the vault itself
            _token,
            amount,
            fee,
            data
        );
        require(result == keccak256("ERC3156FlashBorrower.onFlashLoan"), "Lender: Callback failed");

        // Pull repayment + fee
        token.transferFrom(address(receiver), address(this), amount + fee);

        // Burn pulled tokens to simulate complete loan cycle
        token.burn(address(this), amount + fee);

        return true;
    }
}

contract MockDex {
    MockERC20 public token;

    constructor(MockERC20 token_) {
        token = token_;
    }

    // Profitable swap: pulls amountIn, mints amountOut
    function swap(uint256 amountIn, uint256 amountOut) external {
        token.transferFrom(msg.sender, address(this), amountIn);
        token.mint(msg.sender, amountOut);
    }
}

contract ArbitrageVaultTest is Test {
    MockERC20 internal token;
    ArbitrageVault internal vault;
    MockFlashLender internal lender;
    MockDex internal dex;

    address internal owner = address(0x1111);
    address internal keeper = address(0x2222);
    address internal user = address(0x3333);

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 18);
        vault = new ArbitrageVault(token, "wlUSDC", "wlUSDC", owner);
        lender = new MockFlashLender(token);
        dex = new MockDex(token);

        vm.prank(owner);
        vault.setApprovedLender(address(lender), true);

        vm.prank(owner);
        vault.setKeeper(keeper, true);
    }

    function testFlashloanArbitrageSuccessful() public {
        // Flash loan: borrow 10,000 USDC. Fee = 100 USDC.
        // Arbitrage Trade: Swap 10,000 USDC for 10,500 USDC on MockDex.
        // Repayment = 10,100 USDC. Net Profit = 400 USDC.
        uint256 borrowAmount = 10_000;
        uint256 swapAmountOut = 10_500;

        ArbitrageVault.SwapStep[] memory steps = new ArbitrageVault.SwapStep[](2);

        // Step 1: Approve MockDex to spend borrowed tokens
        steps[0] = ArbitrageVault.SwapStep({
            target: address(token),
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(dex), borrowAmount)
        });

        // Step 2: Call swap on MockDex
        steps[1] = ArbitrageVault.SwapStep({
            target: address(dex),
            callData: abi.encodeWithSelector(MockDex.swap.selector, borrowAmount, swapAmountOut)
        });

        bytes memory data = abi.encode(steps);

        uint256 balanceBefore = token.balanceOf(address(vault));

        vm.prank(keeper);
        vault.initiateFlashLoan(address(lender), address(token), borrowAmount, data);

        uint256 balanceAfter = token.balanceOf(address(vault));

        // Profit: 10500 output - 10100 repayment = 400 net profit
        assertEq(balanceAfter - balanceBefore, 400);
    }

    function testRevertUntrustedLender() public {
        ArbitrageVault.SwapStep[] memory steps = new ArbitrageVault.SwapStep[](0);
        bytes memory data = abi.encode(steps);

        // Call from unapproved lender directly to callback
        vm.prank(address(0xBAD));
        vm.expectRevert(ArbitrageVault.UntrustedLender.selector);
        vault.onFlashLoan(address(vault), address(token), 1000, 10, data);
    }

    function testRevertUnauthorizedInitiator() public {
        ArbitrageVault.SwapStep[] memory steps = new ArbitrageVault.SwapStep[](0);
        bytes memory data = abi.encode(steps);

        // Call callback with initiator != address(vault)
        vm.prank(address(lender));
        vm.expectRevert(ArbitrageVault.UnauthorizedInitiator.selector);
        vault.onFlashLoan(address(0xBAD), address(token), 1000, 10, data);
    }

    function testRevertUnauthorizedCallerInitiate() public {
        ArbitrageVault.SwapStep[] memory steps = new ArbitrageVault.SwapStep[](0);
        bytes memory data = abi.encode(steps);

        // Attempt to initiate flashloan by standard unprivileged user
        vm.prank(user);
        vm.expectRevert(ArbitrageVault.UnauthorizedCaller.selector);
        vault.initiateFlashLoan(address(lender), address(token), 1000, data);
    }

    function testReentrancyPrevention() public {
        // Prepare a swap step that targets the vault and attempts to call onFlashLoan again
        ArbitrageVault.SwapStep[] memory steps = new ArbitrageVault.SwapStep[](1);
        steps[0] = ArbitrageVault.SwapStep({
            target: address(vault),
            callData: abi.encodeWithSelector(
                ArbitrageVault.onFlashLoan.selector, address(vault), address(token), 1000, 10, ""
            )
        });
        bytes memory data = abi.encode(steps);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        vault.initiateFlashLoan(address(lender), address(token), 1000, data);
    }
}
