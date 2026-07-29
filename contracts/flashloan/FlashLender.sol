// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC3156FlashBorrower} from "../interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "../interfaces/IERC3156FlashLender.sol";

contract FlashLender is ERC4626, Ownable, ReentrancyGuard, IERC3156FlashLender {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 100;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    uint256 public feeBps;
    uint256 public totalFeesCollected;

    error UnsupportedToken(address token);
    error FeeTooHigh(uint256 feeBps);
    error InvalidCallback();
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error RepaymentFailed(uint256 expectedBalance, uint256 actualBalance);

    event FeeUpdated(uint256 previousFeeBps, uint256 newFeeBps);
    event FlashLoanExecuted(
        address indexed receiver, address indexed initiator, uint256 amount, uint256 fee
    );

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance_,
        uint256 initialFeeBps
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable() {
        if (governance_ != msg.sender) _transferOwnership(governance_);
        _setFee(initialFeeBps);
    }

    function setFee(uint256 newFeeBps) external onlyOwner {
        _setFee(newFeeBps);
    }

    function maxFlashLoan(address token) public view override returns (uint256) {
        return token == asset() ? IERC20(asset()).balanceOf(address(this)) : 0;
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        if (token != asset()) revert UnsupportedToken(token);
        // Compute ceil(amount * feeBps / BPS_DENOMINATOR) so fee always rounds up.
        // Safe unchecked: feeBps ≤ MAX_FEE_BPS (100), amount bounded by token total supply.
        uint256 fee;
        unchecked {
            uint256 numerator = amount * feeBps;
            fee = numerator / BPS_DENOMINATOR;
            if (numerator % BPS_DENOMINATOR != 0) {
                fee += 1;
            }
        }
        return fee;
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override nonReentrant returns (bool) {
        if (token != asset()) revert UnsupportedToken(token);

        IERC20 loanToken = IERC20(token);
        uint256 balanceBefore = loanToken.balanceOf(address(this));
        if (amount > balanceBefore) revert InsufficientLiquidity(balanceBefore, amount);

        uint256 fee = flashFee(token, amount);
        loanToken.safeTransfer(address(receiver), amount);
        bytes32 callbackResult = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        if (callbackResult != CALLBACK_SUCCESS) revert InvalidCallback();

        loanToken.safeTransferFrom(address(receiver), address(this), amount + fee);
        uint256 balanceAfter = loanToken.balanceOf(address(this));
        uint256 expectedBalance = balanceBefore + fee;
        if (balanceAfter < expectedBalance) revert RepaymentFailed(expectedBalance, balanceAfter);

        totalFeesCollected += balanceAfter - balanceBefore;
        emit FlashLoanExecuted(address(receiver), msg.sender, amount, balanceAfter - balanceBefore);
        return true;
    }

    function _setFee(uint256 newFeeBps) internal {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        uint256 previousFeeBps = feeBps;
        feeBps = newFeeBps;
        emit FeeUpdated(previousFeeBps, newFeeBps);
    }
}
