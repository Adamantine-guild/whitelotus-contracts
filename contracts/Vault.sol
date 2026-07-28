// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from
    "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title Vault – EIP-4626 Tokenized Yield Vault
///
/// @notice A fully EIP-4626-compliant yield-bearing vault that wraps any ERC-20 "asset" token
///         and issues "share" tokens representing a proportional claim on the pool.
///
/// @dev Design highlights
///
///      ┌─ Inflation Attack Defence ───────────────────────────────────────────┐
///      │  The classical "first depositor" inflation attack works by:           │
///      │    1. Attacker deposits 1 wei, receives 1 share.                     │
///      │    2. Attacker donates a large amount directly to the vault.          │
///      │    3. Next depositor's preview rounds to 0 shares; funds are stolen. │
///      │                                                                       │
///      │  We defend with TWO layered mechanisms:                               │
///      │                                                                       │
///      │  A) Virtual Share Offset (_decimalsOffset = 18)                       │
///      │     OZ's ERC4626 adds `10**_decimalsOffset()` to both numerator and  │
///      │     denominator of every share↔asset conversion. With an offset of   │
///      │     18 the virtual pool is 10^18 shares / 10^18 assets, so an        │
///      │     attacker would need to donate 10^18 tokens (≈1 ETH-scaled unit)  │
///      │     per wei of victim deposit to grief them — economically absurd.   │
///      │                                                                       │
///      │  B) Dead shares on first deposit                                      │
///      │     The constructor mints DEAD_SHARES to address(1). These shares    │
///      │     are permanently locked ("dead"). They ensure totalSupply() > 0   │
///      │     from the very first moment, so the share price is always          │
///      │     anchored, even before any real user interacts with the vault.     │
///      └───────────────────────────────────────────────────────────────────────┘
///
///      ┌─ Yield Accrual ───────────────────────────────────────────────────────┐
///      │  `totalAssets()` returns `asset.balanceOf(address(this))`.            │
///      │  As yield-generating strategies send assets into the vault the share  │
///      │  price (`convertToAssets(1e18 shares)`) automatically increases,      │
///      │  benefiting all holders proportionally.                               │
///      └───────────────────────────────────────────────────────────────────────┘
///
///      ┌─ Slippage Guards ─────────────────────────────────────────────────────┐
///      │  Overloaded `deposit` and `mint` accept optional slippage parameters: │
///      │    deposit(assets, receiver, minSharesOut) – reverts if shares minted │
///      │      are below the caller's acceptable minimum (sandwich protection). │
///      │    mint(shares, receiver, maxAssetsIn) – reverts if assets pulled      │
///      │      exceed the caller's maximum (prevents share-price front-running). │
///      └───────────────────────────────────────────────────────────────────────┘
///
///      ┌─ Pause Mechanism ─────────────────────────────────────────────────────┐
///      │  Owner can pause. While paused:                                       │
///      │    • deposit() and mint() revert immediately.                         │
///      │    • withdraw() and redeem() remain fully operational.               │
///      │  This asymmetry matches DeFi convention: users can always exit.      │
///      └───────────────────────────────────────────────────────────────────────┘

contract Vault is ERC4626, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Constants ──────────────────────────────────────────────────────────

    /// @dev Number of shares permanently burned into address(1) on construction.
    ///      Prevents the vault from ever reaching totalSupply == 0 in practice.
    uint256 public constant DEAD_SHARES = 1_000;

    // ─── Errors ─────────────────────────────────────────────────────────────

    /// @notice Raised when the number of shares minted falls below `minSharesOut`.
    error SlippageExceeded(uint256 sharesOut, uint256 minSharesOut);

    /// @notice Raised when the assets required for a mint exceeds `maxAssetsIn`.
    error SlippageExceeded2(uint256 assetsIn, uint256 maxAssetsIn);

    // ─── Events ─────────────────────────────────────────────────────────────

    event DeadSharesMinted(address indexed to, uint256 shares);

    // ─── Constructor ────────────────────────────────────────────────────────

    /// @notice Deploy a new Vault.
    /// @param asset_  The underlying ERC-20 token this vault wraps.
    /// @param name_   Name of the share token (e.g. "White Lotus USDC Vault").
    /// @param symbol_ Symbol of the share token (e.g. "wlUSDC").
    /// @param owner_  Address that controls pause/unpause.
    constructor(IERC20 asset_, string memory name_, string memory symbol_, address owner_)
        ERC4626(asset_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        // ── Dead-share seeding ───────────────────────────────────────────────
        // Mint DEAD_SHARES to address(1) (a non-zero address that can never
        // sign transactions on mainnet, making these shares permanently locked).
        // This ensures totalSupply() > 0 immediately, anchoring the share price
        // and making the inflation attack economically impossible even without
        // the virtual offset.
        //
        // We call _mint() directly because the asset has not yet been deposited —
        // we are creating "empty" dead shares that inflate the denominator of
        // future conversions. Their cost is paid in diluted real assets, but
        // since DEAD_SHARES is tiny relative to 10**_decimalsOffset() the
        // impact on honest depositors is negligible.
        _mint(address(1), DEAD_SHARES);
        emit DeadSharesMinted(address(1), DEAD_SHARES);
    }

    // ─── EIP-4626 Core Overrides ────────────────────────────────────────────

    /// @notice Total assets managed by this vault.
    /// @dev Returns the contract's entire balance of the underlying asset.
    ///      Yield accrues as strategies deposit tokens here; the growing balance
    ///      automatically increases the share price for all holders.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev Overrides the OZ virtual shares offset to 18.
    ///
    ///      OpenZeppelin's ERC4626 formulas are:
    ///        shares = assets * (totalSupply + 10**offset) / (totalAssets + 10**offset)
    ///        assets = shares * (totalAssets + 10**offset) / (totalSupply + 10**offset)
    ///
    ///      With offset=18 the virtual pool starts at 1e18 / 1e18. An attacker
    ///      would need to donate 1e18 underlying tokens per 1-wei deposit to
    ///      cause even 1 wei of rounding loss — economically irrational.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 18;
    }

    // ─── Standard EIP-4626 entry points (with pause guard on deposits) ──────

    /// @inheritdoc ERC4626
    /// @dev Reverts while the vault is paused.
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        return super.deposit(assets, receiver);
    }

    /// @inheritdoc ERC4626
    /// @dev Reverts while the vault is paused.
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256) {
        return super.mint(shares, receiver);
    }

    // ─── Slippage-protected deposit / mint ──────────────────────────────────

    /// @notice Deposit `assets` and receive at least `minSharesOut` shares.
    /// @dev    Acts as a sandwich-attack guard. Reverts with `SlippageExceeded`
    ///         if the share price moved unfavourably between preview and execution.
    /// @param  assets       Amount of underlying asset to deposit.
    /// @param  receiver     Address that receives the newly minted shares.
    /// @param  minSharesOut Minimum acceptable shares. Pass 0 to disable.
    /// @return shares       Actual shares minted.
    function deposit(uint256 assets, address receiver, uint256 minSharesOut)
        external
        whenNotPaused
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minSharesOut) revert SlippageExceeded(shares, minSharesOut);
    }

    /// @notice Mint exactly `shares` shares, spending at most `maxAssetsIn` assets.
    /// @dev    Reverts with `SlippageExceeded2` if the required assets exceed `maxAssetsIn`.
    /// @param  shares      Number of shares to mint.
    /// @param  receiver    Address that receives the newly minted shares.
    /// @param  maxAssetsIn Maximum assets the caller is willing to spend. Pass type(uint256).max to disable.
    /// @return assets      Actual assets spent.
    function mint(uint256 shares, address receiver, uint256 maxAssetsIn)
        external
        whenNotPaused
        returns (uint256 assets)
    {
        assets = mint(shares, receiver);
        if (assets > maxAssetsIn) revert SlippageExceeded2(assets, maxAssetsIn);
    }

    // ─── EIP-4626 maxDeposit / maxMint overrides ────────────────────────────

    /// @dev Returns 0 when paused (spec §4.7: maxDeposit MUST return 0 if deposits are disabled).
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    /// @dev Returns 0 when paused (spec §4.8: maxMint MUST return 0 if minting is disabled).
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Emergency pause. Disables `deposit` and `mint`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operations.
    function unpause() external onlyOwner {
        _unpause();
    }
}
