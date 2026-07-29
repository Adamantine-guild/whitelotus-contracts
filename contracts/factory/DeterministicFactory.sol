// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/**
 * @title DeterministicFactory
 * @notice Factory contract that deploys contracts using the CREATE2 opcode for predictable addresses.
 *         Ensures safety checks matching EIP-3607/EVM requirements.
 */
contract DeterministicFactory {
    error EmptyBytecode();
    error SaltAlreadyUsed();
    error TargetAlreadyHasCode();
    error TargetCannotBeCaller();
    error TargetCannotBeFactory();
    error DeploymentFailed();
    error AddressMismatch();

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
        if (!(bytecode.length > 0)) revert EmptyBytecode();
        if (!(!saltUsed[salt])) revert SaltAlreadyUsed();

        bytes32 bytecodeHash = keccak256(bytecode);
        address target = computeAddress(salt, bytecodeHash);

        // EIP-3607 check: Target must not already have code (prevent overwriting contracts)
        if (!(target.code.length == 0)) revert TargetAlreadyHasCode();

        // Prevent deploying over active addresses in the same transaction
        if (!(target != msg.sender)) revert TargetCannotBeCaller();
        if (!(target != address(this))) revert TargetCannotBeFactory();

        saltUsed[salt] = true;

        assembly {
            addr := create2(callvalue(), add(bytecode, 0x20), mload(bytecode), salt)
        }

        if (!(addr != address(0))) revert DeploymentFailed();
        if (!(addr == target)) revert AddressMismatch();

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
