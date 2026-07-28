// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeterministicFactory} from "../../contracts/factory/DeterministicFactory.sol";

// Simple wallet for testing deterministic deployments
contract SimpleWallet {
    address public owner;

    constructor() payable {
        owner = tx.origin;
    }

    function withdraw() external {
        require(tx.origin == owner, "Only owner");
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}

contract DeterministicFactoryTest is Test {
    DeterministicFactory internal factory;

    bytes internal targetBytecode;
    bytes32 internal targetBytecodeHash;

    function setUp() public {
        factory = new DeterministicFactory();
        targetBytecode = type(SimpleWallet).creationCode;
        targetBytecodeHash = keccak256(targetBytecode);
    }

    function testComputeAddressMatchesDeployed() public {
        bytes32 salt = bytes32(uint256(12_345));

        address computed = factory.computeAddress(salt, targetBytecodeHash);

        address deployed = factory.deploy(salt, targetBytecode);

        assertEq(computed, deployed);
        assertTrue(deployed.code.length > 0);
    }

    function testCounterfactualFunding() public {
        bytes32 salt = bytes32(uint256(99_999));

        address computed = factory.computeAddress(salt, targetBytecodeHash);

        // Pre-fund the computed address before it is deployed
        uint256 fundAmount = 1 ether;
        vm.deal(computed, fundAmount);
        assertEq(computed.balance, fundAmount);
        assertEq(computed.code.length, 0);

        // Deploy SimpleWallet to the pre-funded address
        address deployed = factory.deploy(salt, targetBytecode);
        assertEq(deployed, computed);

        // Verify balance remains and wallet functions correctly
        assertEq(deployed.balance, fundAmount);

        SimpleWallet wallet = SimpleWallet(payable(deployed));
        assertEq(wallet.owner(), tx.origin);

        // Withdraw funds and verify transfer
        uint256 balanceBefore = tx.origin.balance;
        wallet.withdraw();
        assertEq(tx.origin.balance, balanceBefore + fundAmount);
        assertEq(deployed.balance, 0);
    }

    function testRevertSaltAlreadyUsed() public {
        bytes32 salt = bytes32(uint256(11_111));

        factory.deploy(salt, targetBytecode);

        // Try deploying with the same salt again
        vm.expectRevert("DeterministicFactory: Salt already used");
        factory.deploy(salt, targetBytecode);
    }

    function testRevertDeployTargetAlreadyHasCode() public {
        bytes32 salt = bytes32(uint256(22_222));

        address deployed = factory.deploy(salt, targetBytecode);
        assertTrue(deployed.code.length > 0);

        // To bypass the saltUsed mapping and hit the target.code check directly,
        // we manually clear the salt state in testing storage
        bytes32 slot = keccak256(abi.encode(salt, uint256(0)));
        vm.store(address(factory), slot, bytes32(0));
        assertFalse(factory.saltUsed(salt));

        // Now executing deploy will trigger EIP-3607 check for target already has code
        vm.expectRevert("DeterministicFactory: Target already has code");
        factory.deploy(salt, targetBytecode);
    }
}
