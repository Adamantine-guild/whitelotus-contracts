// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamondCut} from "../../contracts/interfaces/IDiamondCut.sol";

/// @title MockSafe – Simulates a multi-sig wallet for testing upgrade access control.
/// @notice When the EOA check (`tx.origin != msg.sender`) is active, direct `vm.prank(eoa)`
///         calls to `diamondCut` / `upgradeToAndCall` revert.  Tests should deploy a
///         MockSafe, transfer ownership to it, and route upgrade calls through
///         `executeDiamondCut` / `executeUpgradeTo`.
contract MockSafe {
    error DiamondCutFailed();
    error UpgradeFailed();

    /// @notice Call `diamondCut` on a Diamond proxy from within this contract.
    /// @param diamond   Address of the Diamond proxy.
    /// @param cut       Facet cut to apply.
    /// @param init      Initialization target (or address(0)).
    /// @param data      Initialization calldata (or empty).
    function executeDiamondCut(
        address diamond,
        IDiamondCut.FacetCut[] calldata cut,
        address init,
        bytes calldata data
    ) external {
        (bool ok, bytes memory ret) =
            diamond.call(abi.encodeWithSelector(IDiamondCut.diamondCut.selector, cut, init, data));
        if (!ok) {
            // Bubble up the revert reason
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Call `upgradeToAndCall` on a UUPS proxy from within this contract.
    /// @param proxy      Address of the UUPS proxy.
    /// @param newImpl    New implementation address.
    /// @param data       Initialization calldata (or empty).
    function executeUpgradeTo(address proxy, address newImpl, bytes calldata data) external {
        (bool ok, bytes memory ret) =
            proxy.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, data));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
