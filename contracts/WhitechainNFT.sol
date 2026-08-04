// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title WhitechainNFT
 * @notice Standard ERC721 NFT contract with ERC721Enumerable logic hooked on-chain
 *         to easily track owned token IDs without relying on off-chain indexing.
 *
 * ─── Gas Impact of ERC721Enumerable ─────────────────────────────────────────
 *
 * The ERC721Enumerable extension adds two on-chain data structures that track
 * (a) a global token array (`_allTokens`) and (b) per-owner token arrays
 * (`_ownedTokens[owner]`). These are updated inside `_beforeTokenTransfer`,
 * which is called on every mint, transfer, and burn.
 *
 *   Operation | Additional Gas vs Bare ERC721         | Notes
 *   ──────────┼───────────────────────────────────────┼───────────────────────────
 *   Mint      | ~40 k (cold) / ~20 k (warm)          | 4 SSTOREs (2 arrays)
 *   Transfer  | ~40-60 k (cold) / ~20-30 k (warm)  | Removes from old owner,
 *            |                                       | adds to new owner
 *   Burn      | ~45-70 k (cold) / ~25-40 k (warm)    | Also removes from global
 *            |                                       | array; O(n) worst case
 *            |                                       | when burning a non-last token
 *
 *   View Function         | Gas Cost   | Complexity
 *   ──────────────────────┼────────────┼───────────
 *   totalSupply()         | ~2.5 k     | O(1)
 *   tokenByIndex(idx)     | ~3 k       | O(1)
 *   tokenOfOwnerByIndex() | ~3 k       | O(1)
 *   balanceOf(owner)      | ~2.5 k     | O(1)
 *
 * Deployment bytecode size increases by approximately 3-4 KB compared to a
 * bare ERC721 due to the additional inherited functions from ERC721Enumerable.
 *
 * These costs are inherent to on-chain enumerability and are comparable to
 * the OpenZeppelin reference implementation. Dapps that only need off-chain
 * indexing (e.g., via The Graph or an indexer) should prefer bare ERC721 to
 * save gas on every transfer.
 */
contract WhitechainNFT is ERC721, ERC721Enumerable, Ownable2Step {
    uint256 private _nextTokenId;

    constructor(string memory name_, string memory symbol_, address owner_)
        ERC721(name_, symbol_)
        Ownable2Step()
    {
        if (owner_ != msg.sender) _transferOwnership(owner_);
    }

    /**
     * @notice Mints a new token to `to`. Gated to owner/admin.
     * @param to The recipient address.
     * @return The newly minted tokenId.
     */
    function mint(address to) external onlyOwner returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    /**
     * @notice Burns `tokenId`. Gated to any caller for test / demonstration purposes.
     * @param tokenId The target token ID to burn.
     */
    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }

    // ─── Overrides ──────────────────────────────────────────────────────────

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
