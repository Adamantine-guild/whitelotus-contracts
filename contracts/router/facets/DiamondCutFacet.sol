// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamondCut} from "../../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";

contract DiamondCutFacet is IDiamondCut {
    /// @notice Upgrades must be initiated by a contract (e.g. Gnosis Safe), never an EOA.
    error EOAUpgradeNotAllowed();

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata)
        external
        override
    {
        if (tx.origin == msg.sender) revert EOAUpgradeNotAllowed();
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}
