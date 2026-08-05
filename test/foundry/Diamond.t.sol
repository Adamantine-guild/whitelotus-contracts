// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../contracts/router/Diamond.sol";
import {DiamondCutFacet} from "../../contracts/router/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/router/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../contracts/router/facets/OwnershipFacet.sol";
import {SwapFacet} from "../../contracts/router/facets/SwapFacet.sol";
import {LiquidityFacet} from "../../contracts/router/facets/LiquidityFacet.sol";
import {FlashloanFacet, IFlashloanReceiver} from "../../contracts/router/facets/FlashloanFacet.sol";
import {IDiamondCut} from "../../contracts/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../contracts/interfaces/IDiamondLoupe.sol";
import {MockSafe} from "./MockSafe.sol";

contract MockFlashloanReceiver is IFlashloanReceiver {
    bool public executed;

    function executeOperation(address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bool)
    {
        executed = true;
        return true;
    }
}

contract DiamondTest is Test {
    Diamond internal diamond;
    DiamondCutFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    OwnershipFacet internal ownershipFacet;
    SwapFacet internal swapFacet;
    LiquidityFacet internal liquidityFacet;
    FlashloanFacet internal flashloanFacet;
    MockSafe internal mockSafe;

    address internal owner = address(0x1111);
    address internal user = address(0x2222);

    function setUp() public {
        vm.deal(user, 10 ether);

        // Deploy facets
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        swapFacet = new SwapFacet();
        liquidityFacet = new LiquidityFacet();
        flashloanFacet = new FlashloanFacet();

        // Deploy MockSafe and set it as the Diamond owner.
        // (In production the owner would be a Gnosis Safe.)
        mockSafe = new MockSafe();

        // Deploy Diamond with MockSafe as the contract owner.
        // diamondCut calls must route through mockSafe because EOAs are rejected.
        diamond = new Diamond(address(mockSafe), address(cutFacet));
    }

    /// @notice An EOA (even the contract owner) cannot call diamondCut directly.
    function testEOACannotCut() public {
        bytes4[] memory loupeSelectors = new bytes4[](1);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        // The MockSafe IS the owner, so `enforceIsContractOwner` would pass.
        // But when we prank as the MockSafe, `tx.origin` is still this test
        // contract (an EOA from Foundry's perspective).
        // Use an EOA that is NOT the contract owner to test EOA rejection
        // independently of the ownership check.
        address eoa = address(0xB0B);
        vm.prank(eoa);
        vm.expectRevert(DiamondCutFacet.EOAUpgradeNotAllowed.selector);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    /// @notice Plain ETH sent to the Diamond is rejected instantly (#51):
    ///         the diamond must not absorb stray native tokens.
    function testDirectETHRejected() public {
        vm.prank(user);
        vm.expectRevert(Diamond.DirectETHNotAllowed.selector);
        payable(address(diamond)).call{value: 1 ether}("");

        assertEq(address(diamond).balance, 0);
    }

    /// @notice Ownership can still be transferred (transferOwnership has no EOA check).
    function testOwnershipTransferNotBlocked() public {
        // Add ownership facet first
        _addOwnershipFacet();

        // MockSafe transfers ownership to a new EOA
        vm.prank(address(mockSafe));
        OwnershipFacet(address(diamond)).transferOwnership(owner);

        assertEq(OwnershipFacet(address(diamond)).owner(), owner);
    }

    function testDiamondCutAndLoupe() public {
        // Prepare selectors for Loupe Facet
        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;

        // Perform diamond cut to add Loupe facet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");

        // Verify Loupe functions via Diamond
        address[] memory addresses = IDiamondLoupe(address(diamond)).facetAddresses();
        assertEq(addresses.length, 2); // DiamondCutFacet and DiamondLoupeFacet
        assertEq(addresses[0], address(cutFacet));
        assertEq(addresses[1], address(loupeFacet));
    }

    function testSwapLiquidityAndFlashloan() public {
        // Add all facets: Loupe, Ownership, Swap, Liquidity, Flashloan
        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;

        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownershipSelectors[1] = OwnershipFacet.owner.selector;

        bytes4[] memory swapSelectors = new bytes4[](4);
        swapSelectors[0] = SwapFacet.swapExactTokensForTokens.selector;
        swapSelectors[1] = SwapFacet.getAmountOut.selector;
        swapSelectors[2] = SwapFacet.getTotalSwaps.selector;
        swapSelectors[3] = SwapFacet.getBalance.selector;

        bytes4[] memory liquiditySelectors = new bytes4[](3);
        liquiditySelectors[0] = LiquidityFacet.addLiquidity.selector;
        liquiditySelectors[1] = LiquidityFacet.removeLiquidity.selector;
        liquiditySelectors[2] = LiquidityFacet.getTotalLiquidityAdded.selector;

        bytes4[] memory flashloanSelectors = new bytes4[](2);
        flashloanSelectors[0] = FlashloanFacet.flashLoan.selector;
        flashloanSelectors[1] = FlashloanFacet.getTotalFlashLoans.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });
        cut[1] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });
        cut[2] = IDiamondCut.FacetCut({
            facetAddress: address(swapFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: swapSelectors
        });
        cut[3] = IDiamondCut.FacetCut({
            facetAddress: address(liquidityFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: liquiditySelectors
        });
        cut[4] = IDiamondCut.FacetCut({
            facetAddress: address(flashloanFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: flashloanSelectors
        });

        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");

        // Test Ownership
        assertEq(OwnershipFacet(address(diamond)).owner(), address(mockSafe));

        // Test Swapping
        vm.prank(user);
        uint256 amountOut = SwapFacet(address(diamond))
            .swapExactTokensForTokens(address(0xAAAA), address(0xBBBB), 1000, 900);
        assertEq(amountOut, 1000);
        assertEq(SwapFacet(address(diamond)).getBalance(user), 1000);
        assertEq(SwapFacet(address(diamond)).getTotalSwaps(), 1);

        // Test Liquidity
        vm.prank(user);
        uint256 liquidity = LiquidityFacet(address(diamond))
            .addLiquidity(address(0xAAAA), address(0xBBBB), 500, 500);
        assertEq(liquidity, 1000);
        // Swapping balance (1000) + Liquidity balance (1000) = 2000
        assertEq(SwapFacet(address(diamond)).getBalance(user), 2000);
        assertEq(LiquidityFacet(address(diamond)).getTotalLiquidityAdded(), 1);

        // Remove Liquidity
        vm.prank(user);
        (uint256 amountA, uint256 amountB) =
            LiquidityFacet(address(diamond)).removeLiquidity(address(0xAAAA), address(0xBBBB), 1000);
        assertEq(amountA, 500);
        assertEq(amountB, 500);
        assertEq(SwapFacet(address(diamond)).getBalance(user), 1000);

        // Test Flashloan
        MockFlashloanReceiver receiver = new MockFlashloanReceiver();
        FlashloanFacet(address(diamond)).flashLoan(address(receiver), address(0xAAAA), 10_000, "");
        assertTrue(receiver.executed());
        assertEq(FlashloanFacet(address(diamond)).getTotalFlashLoans(), 1);
    }

    function testReplaceAndRemove() public {
        // Add ownership facet
        _addOwnershipFacet();

        // Deploy new ownership facet
        OwnershipFacet newOwnershipFacet = new OwnershipFacet();

        // Replace transferOwnership
        bytes4[] memory replaceSelectors = new bytes4[](1);
        replaceSelectors[0] = OwnershipFacet.transferOwnership.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(newOwnershipFacet),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });

        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");

        // Remove owner selector
        bytes4[] memory removeSelectors = new bytes4[](1);
        removeSelectors[0] = OwnershipFacet.owner.selector;

        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: removeSelectors
        });

        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");

        // Check if owner function reverted
        vm.expectRevert(Diamond.FunctionDoesNotExist.selector);
        OwnershipFacet(address(diamond)).owner();
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _addOwnershipFacet() internal {
        bytes4[] memory ownershipSelectors = new bytes4[](2);
        ownershipSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownershipSelectors[1] = OwnershipFacet.owner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: ownershipSelectors
        });

        mockSafe.executeDiamondCut(address(diamond), cut, address(0), "");
    }
}
