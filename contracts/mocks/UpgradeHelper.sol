// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title UpgradeHelper – Wraps upgrade calls so tests can route through a contract.
/// @notice When `_authorizeUpgrade` enforces `tx.origin != msg.sender`, direct calls from
///         Hardhat signers (EOAs) revert.  Tests should deploy an UpgradeHelper, grant it the
///         necessary role, and call `executeUpgradeTo`.
contract UpgradeHelper {
    error UpgradeFailed();

    /// @notice Call `upgradeToAndCall` on a UUPS proxy from within this contract.
    /// @param proxy      Address of the UUPS proxy.
    /// @param newImpl    New implementation address.
    /// @param data       Initialization calldata (or empty).
    function executeUpgradeTo(address proxy, address newImpl, bytes calldata data) external {
        (bool ok, bytes memory ret) =
            proxy.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, data));
        if (!ok) {
            // Bubble up the revert reason
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
