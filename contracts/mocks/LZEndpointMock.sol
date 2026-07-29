// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILayerZeroReceiver {
    function lzReceive(uint16 _srcChainId, bytes calldata _srcAddress, uint64 _nonce, bytes calldata _payload) external;
}

contract LZEndpointMock {
    uint16 public mockChainId;

    constructor(uint16 _chainId) {
        mockChainId = _chainId;
    }

    // Mocks the behavior of the endpoint delivering a message to the destination application
    function receivePayload(
        uint16 _srcChainId,
        bytes calldata _path,
        address _dstAddress,
        uint64 _nonce,
        uint _gasLimit,
        bytes calldata _payload
    ) public {
        ILayerZeroReceiver(_dstAddress).lzReceive(
            _srcChainId,
            _path,
            _nonce,
            _payload
        );
    }
}
