// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "../../contracts/interfaces/IERC3156FlashBorrower.sol";
import {FlashLender} from "../../contracts/flashloan/FlashLender.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract FlashBorrowerMock is IERC3156FlashBorrower {
    IERC20 public immutable token;
    FlashLender public immutable lender;
    bool public returnInvalidCallback;
    bool public skipApproval;
    bool public attemptReentrancy;

    constructor(IERC20 token_, FlashLender lender_) {
        token = token_;
        lender = lender_;
    }

    function configure(bool invalidCallback, bool noApproval, bool reenter) external {
        returnInvalidCallback = invalidCallback;
        skipApproval = noApproval;
        attemptReentrancy = reenter;
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == address(lender), "Borrower: untrusted lender");
        if (attemptReentrancy) {
            lender.flashLoan(this, address(token), 1, "");
        }
        if (!skipApproval) {
            token.approve(address(lender), amount + fee);
        }
        if (returnInvalidCallback) return bytes32(0);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

contract FlashLenderTest is Test {
    MockERC20 internal token;
    MockERC20 internal unsupportedToken;
    FlashLender internal lender;
    FlashBorrowerMock internal borrower;
    address internal governance = address(0xA11CE);
    address internal staker = address(0xB0B);

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 18);
        unsupportedToken = new MockERC20("Other", "OTHER", 18);
        lender = new FlashLender(token, "Staked USDC", "sUSDC", governance, 50);
        borrower = new FlashBorrowerMock(token, lender);

        token.mint(staker, 100_000 ether);
        vm.startPrank(staker);
        token.approve(address(lender), type(uint256).max);
        lender.deposit(100_000 ether, staker);
        vm.stopPrank();
    }

    function testFlashLoanCollectsFeeForStakers() public {
        uint256 amount = 10_000 ether;
        uint256 fee = lender.flashFee(address(token), amount);
        token.mint(address(borrower), fee);

        assertTrue(lender.flashLoan(borrower, address(token), amount, ""));
        assertEq(lender.totalFeesCollected(), fee);
        assertEq(lender.totalAssets(), 100_000 ether + fee);
        assertApproxEqAbs(lender.previewRedeem(lender.balanceOf(staker)), 100_000 ether + fee, 1);
    }

    function testFlashLoanRevertsWithoutRepaymentApproval() public {
        uint256 amount = 10_000 ether;
        token.mint(address(borrower), lender.flashFee(address(token), amount));
        borrower.configure(false, true, false);

        vm.expectRevert();
        lender.flashLoan(borrower, address(token), amount, "");
    }

    function testFlashLoanRejectsInvalidCallback() public {
        uint256 amount = 10_000 ether;
        token.mint(address(borrower), lender.flashFee(address(token), amount));
        borrower.configure(true, false, false);

        vm.expectRevert(FlashLender.InvalidCallback.selector);
        lender.flashLoan(borrower, address(token), amount, "");
    }

    function testFlashLoanPreventsReentrancy() public {
        uint256 amount = 10_000 ether;
        token.mint(address(borrower), lender.flashFee(address(token), amount));
        borrower.configure(false, false, true);

        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        lender.flashLoan(borrower, address(token), amount, "");
    }

    function testGovernanceCanUpdateFeeWithinCap() public {
        vm.prank(governance);
        lender.setFee(100);
        assertEq(lender.feeBps(), 100);
        assertEq(lender.flashFee(address(token), 1000), 10);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(FlashLender.FeeTooHigh.selector, 101));
        lender.setFee(101);
    }

    function testUnsupportedTokenAndExcessLiquidityAreRejected() public {
        assertEq(lender.maxFlashLoan(address(unsupportedToken)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(FlashLender.UnsupportedToken.selector, address(unsupportedToken))
        );
        lender.flashFee(address(unsupportedToken), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                FlashLender.InsufficientLiquidity.selector, 100_000 ether, 100_001 ether
            )
        );
        lender.flashLoan(borrower, address(token), 100_001 ether, "");
    }
}
