// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@layerzerolabs/solidity-examples/contracts/lzApp/NonblockingLzApp.sol";

/**
 * @title OmnichainReceiver
 * @dev Secure, non-blocking receiver contract that interfaces directly with the LayerZero endpoint.
 */
contract OmnichainReceiver is NonblockingLzApp {
    // Tracks processed nonces per chain and sender for strict replay protection
    mapping(uint16 => mapping(bytes => mapping(uint64 => bool))) public processedNonces;

    // Example application state
    mapping(address => uint256) public syntheticCollateral;

    event PayloadReceived(uint16 srcChainId, bytes srcAddress, uint64 nonce, bytes payload);
    event CollateralMinted(address user, uint256 amount);

    /**
     * @param _endpoint The LayerZero Endpoint address on this chain
     * @param _owner The initial owner address for Ownable (if required by custom modifications, but typically passed implicitly)
     */
    constructor(address _endpoint, address _owner) NonblockingLzApp(_endpoint) {
        // Transfer ownership if needed by the local Ownable pattern
        if (_owner != msg.sender) {
            transferOwnership(_owner);
        }
    }

    /**
     * @dev Called by NonblockingLzApp when a message is successfully received from the endpoint.
     * @param _srcChainId The source chain ID
     * @param _srcAddress The source address (trusted path)
     * @param _nonce The message nonce
     * @param _payload The payload
     */
    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal override {
        // Strict replay protection mechanism
        require(!processedNonces[_srcChainId][_srcAddress][_nonce], "OmnichainReceiver: Payload already processed");
        processedNonces[_srcChainId][_srcAddress][_nonce] = true;

        emit PayloadReceived(_srcChainId, _srcAddress, _nonce, _payload);

        // Decode payload and execute local state transitions
        // Payload structure expected: abi.encode(address user, uint256 amount)
        (address user, uint256 amount) = abi.decode(_payload, (address, uint256));

        // State update (e.g., minting synthetic collateral)
        syntheticCollateral[user] += amount;

        emit CollateralMinted(user, amount);
    }
}
