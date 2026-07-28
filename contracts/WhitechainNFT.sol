// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title WhitechainNFT
 * @notice Standard ERC721 NFT contract with ERC721Enumerable logic hooked on-chain
 *         to easily track owned token IDs without relying on off-chain indexing.
 */
contract WhitechainNFT is ERC721, ERC721Enumerable, Ownable {
    uint256 private _nextTokenId;

    constructor(string memory name_, string memory symbol_, address owner_)
        ERC721(name_, symbol_)
        Ownable(owner_)
    {}

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

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 amount)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, amount);
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
