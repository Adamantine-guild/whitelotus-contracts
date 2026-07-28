// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockLZEndpointV2} from "../../contracts/mocks/MockLZEndpointV2.sol";
import {WhiteLotusOFT} from "../../contracts/bridge/WhiteLotusOFT.sol";
import {LZAdapter} from "../../contracts/bridge/LZAdapter.sol";

contract GovernanceTarget {
    uint256 public value;

    function setValue(uint256 value_) external {
        value = value_;
    }
}

contract CrossChainTest is Test {
    MockLZEndpointV2 internal endpoint;
    WhiteLotusOFT internal source;
    WhiteLotusOFT internal destination;
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    uint32 internal constant SOURCE_EID = 1;
    uint32 internal constant DESTINATION_EID = 2;
    bytes32 internal sourcePeer;
    bytes32 internal destinationPeer;

    function setUp() public {
        endpoint = new MockLZEndpointV2();
        source = new WhiteLotusOFT("White Lotus", "LOTUS", address(endpoint), owner, 100 ether);
        destination = new WhiteLotusOFT("White Lotus", "LOTUS", address(endpoint), owner, 0);
        sourcePeer = bytes32(uint256(uint160(address(source))));
        destinationPeer = bytes32(uint256(uint160(address(destination))));

        vm.startPrank(owner);
        source.setPeer(DESTINATION_EID, destinationPeer);
        destination.setPeer(SOURCE_EID, sourcePeer);
        source.setGasLimit(DESTINATION_EID, 200_000);
        destination.setGasLimit(SOURCE_EID, 200_000);
        vm.stopPrank();

        vm.prank(owner);
        source.transfer(user, 100 ether);
    }

    function testSendBurnsSourceAndIncludesConfiguredGasLimit() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        source.send{value: 1}(DESTINATION_EID, bytes32(uint256(uint160(user))), 10 ether, 1);

        assertEq(source.balanceOf(user), 90 ether);
        (uint32 dstEid,,, bytes memory options,) = endpoint.lastParams();
        assertEq(dstEid, DESTINATION_EID);
        assertEq(
            options,
            abi.encodePacked(
                uint16(3), uint8(1), uint16(33), uint8(1), uint128(200_000), uint128(0)
            )
        );
    }

    function testValidDeliveryMintsOnDestination() public {
        bytes memory message = abi.encode(uint8(0), bytes32(uint256(uint160(user))), 10 ether);
        endpoint.deliver(
            address(destination), SOURCE_EID, sourcePeer, 1, keccak256(message), message
        );
        assertEq(destination.balanceOf(user), 10 ether);
    }

    function testForgedSourceAndReplayAreRejected() public {
        bytes memory message = abi.encode(uint8(0), bytes32(uint256(uint160(user))), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(LZAdapter.InvalidPeer.selector, SOURCE_EID, bytes32(uint256(99)))
        );
        endpoint.deliver(
            address(destination), SOURCE_EID, bytes32(uint256(99)), 1, bytes32(uint256(1)), message
        );

        bytes32 guid = keccak256(message);
        endpoint.deliver(address(destination), SOURCE_EID, sourcePeer, 1, guid, message);
        vm.expectRevert(abi.encodeWithSelector(LZAdapter.MessageAlreadyProcessed.selector, guid));
        endpoint.deliver(address(destination), SOURCE_EID, sourcePeer, 2, guid, message);
    }

    function testStaleNonceIsRejected() public {
        bytes memory message = abi.encode(uint8(0), bytes32(uint256(uint160(user))), 10 ether);
        endpoint.deliver(
            address(destination), SOURCE_EID, sourcePeer, 2, bytes32(uint256(2)), message
        );

        vm.expectRevert(abi.encodeWithSelector(LZAdapter.InvalidNonce.selector, SOURCE_EID, 1));
        endpoint.deliver(
            address(destination), SOURCE_EID, sourcePeer, 1, bytes32(uint256(1)), message
        );
    }

    function testAuthenticatedGovernanceCallExecutesConfiguredTarget() public {
        GovernanceTarget target = new GovernanceTarget();
        vm.prank(owner);
        destination.setRemoteExecutor(SOURCE_EID, address(target));
        bytes memory callData = abi.encodeCall(GovernanceTarget.setValue, (42));
        bytes memory message = abi.encode(uint8(1), address(target), callData);

        endpoint.deliver(
            address(destination), SOURCE_EID, sourcePeer, 1, keccak256(message), message
        );
        assertEq(target.value(), 42);
    }
}
