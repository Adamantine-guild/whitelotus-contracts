// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../../interfaces/IDiamondLoupe.sol";

contract DiamondLoupeFacet is IDiamondLoupe {
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numSelectors = ds.selectors.length;
        address[] memory addresses = new address[](numSelectors);
        uint256 numFacets = 0;

        for (uint256 i = 0; i < numSelectors; i++) {
            bytes4 selector = ds.selectors[i];
            address facetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            bool found = false;
            for (uint256 j = 0; j < numFacets; j++) {
                if (addresses[j] == facetAddress) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                addresses[numFacets] = facetAddress;
                numFacets++;
            }
        }

        facets_ = new Facet[](numFacets);
        for (uint256 i = 0; i < numFacets; i++) {
            address facetAddress = addresses[i];
            facets_[i].facetAddress = facetAddress;
            // find selectors for facet
            uint256 count = 0;
            for (uint256 j = 0; j < numSelectors; j++) {
                bytes4 selector = ds.selectors[j];
                if (ds.facetAddressAndSelectorPosition[selector].facetAddress == facetAddress) {
                    count++;
                }
            }
            bytes4[] memory selectors = new bytes4[](count);
            uint256 idx = 0;
            for (uint256 j = 0; j < numSelectors; j++) {
                bytes4 selector = ds.selectors[j];
                if (ds.facetAddressAndSelectorPosition[selector].facetAddress == facetAddress) {
                    selectors[idx] = selector;
                    idx++;
                }
            }
            facets_[i].functionSelectors = selectors;
        }
    }

    function facetFunctionSelectors(address _facet)
        external
        view
        override
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numSelectors = ds.selectors.length;
        uint256 count = 0;
        for (uint256 i = 0; i < numSelectors; i++) {
            bytes4 selector = ds.selectors[i];
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress == _facet) {
                count++;
            }
        }
        facetFunctionSelectors_ = new bytes4[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < numSelectors; i++) {
            bytes4 selector = ds.selectors[i];
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress == _facet) {
                facetFunctionSelectors_[idx] = selector;
                idx++;
            }
        }
    }

    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numSelectors = ds.selectors.length;
        address[] memory addresses = new address[](numSelectors);
        uint256 numFacets = 0;
        for (uint256 i = 0; i < numSelectors; i++) {
            bytes4 selector = ds.selectors[i];
            address facetAddress = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            bool found = false;
            for (uint256 j = 0; j < numFacets; j++) {
                if (addresses[j] == facetAddress) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                addresses[numFacets] = facetAddress;
                numFacets++;
            }
        }
        facetAddresses_ = new address[](numFacets);
        for (uint256 i = 0; i < numFacets; i++) {
            facetAddresses_[i] = addresses[i];
        }
    }

    function facetAddress(bytes4 _functionSelector)
        external
        view
        override
        returns (address facetAddress_)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddress_ = ds.facetAddressAndSelectorPosition[_functionSelector].facetAddress;
    }
}
