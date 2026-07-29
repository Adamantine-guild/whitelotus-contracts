// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {Vault} from "../Vault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC3156FlashBorrower} from "../interfaces/IERC3156FlashBorrower.sol";

interface IERC3156FlashLender {
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
}

contract ArbitrageVault is Vault, ReentrancyGuard, IERC3156FlashBorrower {
    error ZeroAddress();
    error UnauthorizedCaller();
    error UntrustedLender();
    error UnauthorizedInitiator();
    error InsufficientBalanceForRepayment();
    error SwapStepFailed();

    // ─── Structs ────────────────────────────────────────────────────────────

    struct SwapStep {
        address target;
        bytes callData;
    }

    // ─── State ──────────────────────────────────────────────────────────────

    mapping(address => bool) public approvedLenders;
    mapping(address => bool) public keepers;

    // ─── Events ─────────────────────────────────────────────────────────────

    event LenderSet(address indexed lender, bool approved);
    event KeeperSet(address indexed keeper, bool active);
    event ArbitrageExecuted(uint256 profit);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address owner_)
        Vault(asset_, name_, symbol_, owner_)
    {}

    // ─── Whitelist Management ───────────────────────────────────────────────

    function setApprovedLender(address lender, bool approved) external onlyOwner {
        if (!(lender != address(0))) revert ZeroAddress();
        approvedLenders[lender] = approved;
        emit LenderSet(lender, approved);
    }

    function setKeeper(address keeper, bool active) external onlyOwner {
        if (!(keeper != address(0))) revert ZeroAddress();
        keepers[keeper] = active;
        emit KeeperSet(keeper, active);
    }

    // ─── Flashloan Initiation ───────────────────────────────────────────────

    function initiateFlashLoan(address lender, address token, uint256 amount, bytes calldata data)
        external
    {
        if (!(msg.sender == owner() || keepers[msg.sender])) revert UnauthorizedCaller();
        if (!(approvedLenders[lender])) revert UntrustedLender();

        IERC3156FlashLender(lender).flashLoan(this, token, amount, data);
    }

    // ─── IERC3156FlashBorrower Callback ─────────────────────────────────────

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override nonReentrant returns (bytes32) {
        if (!(approvedLenders[msg.sender])) revert UntrustedLender();
        if (!(initiator == address(this))) revert UnauthorizedInitiator();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Execute arbitrage swap steps from payload
        SwapStep[] memory steps = abi.decode(data, (SwapStep[]));
        for (uint256 i = 0; i < steps.length; i++) {
            (bool success, bytes memory returnData) = steps[i].target.call(steps[i].callData);
            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        let returndata_size := mload(returnData)
                        revert(add(32, returnData), returndata_size)
                    }
                } else {
                    revert SwapStepFailed();
                }
            }
        }

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 repayment = amount + fee;

        if (!(balanceAfter >= repayment)) revert InsufficientBalanceForRepayment();

        // Approve lender to pull the repayment amount
        IERC20(token).approve(msg.sender, repayment);

        // Record profit
        uint256 netProfit = balanceAfter - repayment - (balanceBefore - amount);
        emit ArbitrageExecuted(netProfit);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
