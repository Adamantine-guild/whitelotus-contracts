// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title MerkleAirdrop
 * @notice Gas-optimized cryptographic airdrop claim contract utilizing Merkle trees and bitmap double-claim prevention.
 */
contract MerkleAirdrop {
    error InvalidTokenAddress();

    using SafeERC20 for IERC20;

    address public immutable token;
    bytes32 public immutable merkleRoot;

    // Bitmaps to keep track of claims
    mapping(uint256 => uint256) public claimedBitMap;

    event Claimed(uint256 indexed index, address indexed account, uint256 amount);

    error AlreadyClaimed();
    error InvalidProof();

    constructor(address _token, bytes32 _merkleRoot) {
        if (!(_token != address(0))) revert InvalidTokenAddress();
        token = _token;
        merkleRoot = _merkleRoot;
    }

    /**
     * @notice Returns true if the index has been claimed.
     * @param index The index of the claim.
     */
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        return (claimedWord & mask) != 0;
    }

    /**
     * @notice Set the claimed status of an index in the bitmap.
     * @param index The index of the claim.
     */
    function _setClaimed(uint256 index) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[claimedWordIndex] = claimedBitMap[claimedWordIndex] | (1 << claimedBitIndex);
    }

    /**
     * @notice Claim tokens using a valid Merkle proof.
     * @param index The index of the claim in the Merkle tree.
     * @param account The address claiming the tokens.
     * @param amount The amount of tokens to claim.
     * @param proof The cryptographic Merkle proof.
     */
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        if (isClaimed(index)) revert AlreadyClaimed();

        // Generate the leaf node hash using the standard encoding pattern.
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        
        // Verify the proof matches the root
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        // Mark index as claimed
        _setClaimed(index);

        // Safely transfer tokens to the claimer
        IERC20(token).safeTransfer(account, amount);

        emit Claimed(index, account, amount);
    }
}
