// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    IERC20Permit
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IWhiteLotusToken
/// @notice Interface for the permit-enabled WhiteLotus token and its cross-chain transfer entry point.
/// @dev Cross-chain sends burn tokens on the source chain and mint them after a trusted peer delivers
///      the message on the destination chain. ERC-20 and ERC-2612 functions are inherited unchanged.
interface IWhiteLotusToken is IERC20Metadata, IERC20Permit {
    /// @notice Sends WhiteLotus tokens to a recipient on another supported chain.
    /// @dev Burns `amount` from the caller and forwards `nativeFee` to the messaging endpoint.
    ///      Reverts for a zero recipient, a zero amount, an untrusted destination, an insufficient
    ///      token balance, an insufficient native fee, or a mismatched `msg.value` and `nativeFee`.
    /// @param dstEid The LayerZero endpoint ID of the destination chain.
    /// @param recipient The destination recipient encoded as a left-padded 32-byte value.
    /// @param amount The number of tokens to burn on the source chain and mint on the destination.
    /// @param nativeFee The native-token fee forwarded to the messaging endpoint.
    /// @return guid The unique identifier assigned to the cross-chain message.
    function send(uint32 dstEid, bytes32 recipient, uint256 amount, uint256 nativeFee)
        external
        payable
        returns (bytes32 guid);
}
