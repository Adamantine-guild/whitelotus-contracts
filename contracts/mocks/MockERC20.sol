// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20 - Freely mintable ERC20 for use in tests only
/// @dev Never deploy this to production. Any caller can mint arbitrary amounts.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` tokens to `to`. Open to any caller — tests only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn `amount` tokens from `from`. Open to any caller — tests only.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
