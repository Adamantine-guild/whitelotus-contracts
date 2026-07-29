// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title VaultProxy - ERC-1967 proxy that fronts a {WhiteLotusERC4626} implementation
/// @notice Deploy the vault behind one of these and call it at the proxy address. Upgrades are
///         authorised by the implementation's own `_authorizeUpgrade`, so there is no proxy admin.
contract VaultProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
