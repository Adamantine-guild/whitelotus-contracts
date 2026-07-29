// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {AppStorage} from "../../libraries/AppStorage.sol";

interface IFlashloanReceiver {
    function executeOperation(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bool);
}

contract FlashloanFacet {
    error ExecutionFailed();

    AppStorage internal s;

    event FlashloanExecuted(address indexed receiver, address token, uint256 amount, uint256 fee);

    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data)
        external
    {
        uint256 fee = amount / 1000; // 0.1% mock fee

        // Callback to receiver
        if (!(IFlashloanReceiver(receiver).executeOperation(token, amount, fee, data))) revert ExecutionFailed();

        s.totalFlashLoans += 1;

        emit FlashloanExecuted(receiver, token, amount, fee);
    }

    function getTotalFlashLoans() external view returns (uint256) {
        return s.totalFlashLoans;
    }
}
