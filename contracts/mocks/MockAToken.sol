// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAToken - Interest bearing receipt token for {MockAavePool}, tests only
/// @dev Never deploy this to production. Mirrors Aave V3 in the one way strategies depend on: the
///      aToken custodies the supplied underlying, so its asset balance is the market's liquidity.
contract MockAToken is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    address public immutable pool;

    error NotPool(address caller);

    modifier onlyPool() {
        if (msg.sender != pool) revert NotPool(msg.sender);
        _;
    }

    constructor(IERC20 underlying_, address pool_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        underlying = underlying_;
        pool = pool_;
    }

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` and release the matching underlying to `to`.
    function burnAndRelease(address from, address to, uint256 amount) external onlyPool {
        _burn(from, amount);
        underlying.safeTransfer(to, amount);
    }

    /// @notice Burn `amount` without releasing underlying, modelling a market shortfall.
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
