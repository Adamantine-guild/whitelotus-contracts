// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DeterministicFactory
 * @notice Factory contract that deploys contracts using the CREATE2 opcode for predictable addresses.
 *         Ensures safety checks matching EIP-3607/EVM requirements.
 */
contract DeterministicFactory {
    // ─── State ──────────────────────────────────────────────────────────────

    mapping(bytes32 => bool) public saltUsed;

    // ─── Events ─────────────────────────────────────────────────────────────

    event Deployed(bytes32 indexed salt, address indexed deployedAddress);

    // ─── External Deploy Entrypoint ─────────────────────────────────────────

    /**
     * @notice Deploys a contract using CREATE2.
     * @param salt Unique user salt.
     * @param bytecode The deployment initialization bytecode.
     * @return addr The deployed contract address.
     */
    function deploy(bytes32 salt, bytes memory bytecode) external payable returns (address addr) {
        require(bytecode.length > 0, "DeterministicFactory: Empty bytecode");
        require(!saltUsed[salt], "DeterministicFactory: Salt already used");

        bytes32 bytecodeHash = keccak256(bytecode);
        address target = computeAddress(salt, bytecodeHash);

        // EIP-3607 check: Target must not already have code (prevent overwriting contracts)
        require(target.code.length == 0, "DeterministicFactory: Target already has code");

        // Prevent deploying over active addresses in the same transaction
        require(target != msg.sender, "DeterministicFactory: Target cannot be caller");
        require(target != address(this), "DeterministicFactory: Target cannot be factory");

        saltUsed[salt] = true;

        assembly {
            addr := create2(callvalue(), add(bytecode, 0x20), mload(bytecode), salt)
        }

        require(addr != address(0), "DeterministicFactory: Deployment failed");
        require(addr == target, "DeterministicFactory: Address mismatch");

        emit Deployed(salt, addr);
    }

    // ─── Pre-calculation View ───────────────────────────────────────────────

    /**
     * @notice Local pre-calculation of deterministic CREATE2 address.
     * @param salt Unique user salt.
     * @param bytecodeHash The hash of the initialization bytecode.
     * @return The pre-calculated contract address.
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash) public view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))
                )
            )
        );
    }
}
