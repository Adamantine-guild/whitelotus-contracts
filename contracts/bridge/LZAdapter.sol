// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface ILayerZeroEndpointV2 {
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function send(MessagingParams calldata params, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (bytes32 guid);
}

interface ILayerZeroReceiver {
    function lzReceive(
        ILayerZeroEndpointV2.Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

abstract contract LZAdapter is Ownable, ILayerZeroReceiver {
    error ZeroEndpoint();
    error ZeroPeer();
    error ZeroGasLimit();
    error ZeroExecutor();
    error GasLimitNotSet();
    error UnknownMessage();

    error CallerNotEndpoint();
    error InvalidPeer(uint32 srcEid, bytes32 sender);
    error MessageAlreadyProcessed(bytes32 guid);
    error InvalidNonce(uint32 srcEid, uint64 nonce);
    error MissingPeer(uint32 dstEid);
    error IncorrectNativeFee(uint256 supplied, uint256 required);
    error InvalidRemoteExecutor(uint32 srcEid, address target);
    error RemoteCallFailed();

    event PeerSet(uint32 indexed eid, bytes32 indexed peer);
    event GasLimitSet(uint32 indexed eid, uint128 gasLimit);
    event MessageSent(bytes32 indexed guid, uint32 indexed dstEid, bytes message);
    event MessageReceived(bytes32 indexed guid, uint32 indexed srcEid, uint64 nonce);
    event RemoteCallExecuted(uint32 indexed srcEid, address indexed target, bytes data);

    ILayerZeroEndpointV2 public immutable endpoint;
    mapping(uint32 eid => bytes32 peer) public peers;
    mapping(uint32 eid => uint128 gasLimit) public gasLimits;
    mapping(uint32 eid => uint64 nonce) public inboundNonces;
    mapping(bytes32 guid => bool processed) public processedGuid;
    mapping(uint32 eid => address executor) public remoteExecutors;

    constructor(address endpoint_, address owner_) Ownable(owner_) {
        if (!(endpoint_ != address(0))) revert ZeroEndpoint();
        endpoint = ILayerZeroEndpointV2(endpoint_);
    }

    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        if (!(peer != bytes32(0))) revert ZeroPeer();
        peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    function setGasLimit(uint32 eid, uint128 gasLimit) external onlyOwner {
        if (!(gasLimit != 0)) revert ZeroGasLimit();
        gasLimits[eid] = gasLimit;
        emit GasLimitSet(eid, gasLimit);
    }

    function setRemoteExecutor(uint32 eid, address executor) external onlyOwner {
        if (!(executor != address(0))) revert ZeroExecutor();
        remoteExecutors[eid] = executor;
    }

    function sendGovernanceCall(
        uint32 dstEid,
        address target,
        bytes calldata data,
        uint256 nativeFee
    ) external payable onlyOwner returns (bytes32 guid) {
        guid = _send(dstEid, abi.encode(uint8(1), target, data), nativeFee);
    }

    function lzReceive(
        ILayerZeroEndpointV2.Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable {
        if (msg.sender != address(endpoint)) revert CallerNotEndpoint();
        if (peers[origin.srcEid] != origin.sender) {
            revert InvalidPeer(origin.srcEid, origin.sender);
        }
        if (processedGuid[guid]) revert MessageAlreadyProcessed(guid);
        if (origin.nonce <= inboundNonces[origin.srcEid]) {
            revert InvalidNonce(origin.srcEid, origin.nonce);
        }

        processedGuid[guid] = true;
        inboundNonces[origin.srcEid] = origin.nonce;
        _handleMessage(origin.srcEid, message);
        emit MessageReceived(guid, origin.srcEid, origin.nonce);
    }

    function _send(uint32 dstEid, bytes memory message, uint256 nativeFee)
        internal
        returns (bytes32 guid)
    {
        if (msg.value != nativeFee) revert IncorrectNativeFee(msg.value, nativeFee);
        bytes32 peer = peers[dstEid];
        if (peer == bytes32(0)) revert MissingPeer(dstEid);
        uint128 gasLimit = gasLimits[dstEid];
        if (!(gasLimit != 0)) revert GasLimitNotSet();

        ILayerZeroEndpointV2.MessagingParams memory params = ILayerZeroEndpointV2.MessagingParams({
            dstEid: dstEid,
            receiver: peer,
            message: message,
            options: abi.encodePacked(
                uint16(3), uint8(1), uint16(33), uint8(1), gasLimit, uint128(0)
            ),
            payInLzToken: false
        });
        // solhint-disable-next-line check-send-result
        guid = endpoint.send{value: nativeFee}(
            params, ILayerZeroEndpointV2.MessagingFee(nativeFee, 0), msg.sender
        );
        emit MessageSent(guid, dstEid, message);
    }

    function _handleMessage(uint32 srcEid, bytes calldata message) internal virtual {
        (uint8 kind, address target, bytes memory data) =
            abi.decode(message, (uint8, address, bytes));
        if (!(kind == 1)) revert UnknownMessage();
        if (target != remoteExecutors[srcEid]) {
            revert InvalidRemoteExecutor(srcEid, target);
        }
        (bool success,) = target.call(data);
        if (!success) revert RemoteCallFailed();
        emit RemoteCallExecuted(srcEid, target, data);
    }
}
