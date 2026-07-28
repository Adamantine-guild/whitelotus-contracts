// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILayerZeroEndpointV2, ILayerZeroReceiver} from "../bridge/LZAdapter.sol";

contract MockLZEndpointV2 is ILayerZeroEndpointV2 {
    uint256 public nonce;
    MessagingParams public lastParams;

    function send(MessagingParams calldata params, MessagingFee calldata, address)
        external
        payable
        returns (bytes32 guid)
    {
        lastParams = params;
        guid = keccak256(abi.encode(msg.sender, ++nonce, params.message));
    }

    function deliver(
        address receiver,
        uint32 srcEid,
        bytes32 sender,
        uint64 messageNonce,
        bytes32 guid,
        bytes calldata message
    ) external {
        ILayerZeroReceiver(receiver)
            .lzReceive(Origin(srcEid, sender, messageNonce), guid, message, address(this), "");
    }
}
