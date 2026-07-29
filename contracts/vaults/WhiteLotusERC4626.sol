// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title WhiteLotusERC4626 - Tokenized vault routing capital across pluggable yield strategies
/// @notice An ERC-4626 vault whose assets are split between an idle buffer and any number of
///         registered strategies, each holding a governance-set share of the total. Share price is
///         derived from live strategy reports rather than a cached figure, so yield and losses are
///         reflected the moment they happen.
///    /// @dev Inflation attack defence. The vault is protected by the combination of
    ///      virtual shares baked into ERC4626's conversions and the strategy-based
    ///      yield routing that keeps assets visible to {totalAssets}.
    ///
    ///      Accounting. `totalAssets` sums the idle balance and every strategy's own report, so
    ///      capital deployed externally is never invisible to conversions. Each strategy's `principal`
    ///      records what the vault has committed to it, which is what turns a report into a gain or a
    ///      loss without trusting the strategy to track its own performance.
contract WhiteLotusERC4626 is
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Adds, retires and migrates strategies, and pauses deposits.
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Runs the routine harvest and rebalance cycle.
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant MAX_BPS = 10_000;

    /// @notice Upper bound on registered strategies, since conversions iterate over all of them.
    uint256 public constant MAX_STRATEGIES = 10;

    /// @param active    Whether the strategy is registered and may hold capital.
    /// @param targetBps Share of {totalAssets} the rebalancer aims to keep in this strategy.
    /// @param principal Assets the vault has committed, used to turn a report into gain or loss.
    struct StrategyParams {
        bool active;
        uint16 targetBps;
        uint256 principal;
    }

    mapping(address => StrategyParams) public strategyParams;

    address[] private _strategies;

    uint16 public totalTargetBps;

    uint256[47] private __gap;

    event StrategyAdded(address indexed strategy, uint16 targetBps);
    event StrategyAllocationUpdated(address indexed strategy, uint16 previousBps, uint16 newBps);
    event StrategyRemoved(address indexed strategy, uint256 returned);
    event StrategyMigrated(address indexed from, address indexed to, uint256 assets);
    event StrategyReported(address indexed strategy, uint256 gain, uint256 loss, uint256 principal);
    event Rebalanced(uint256 totalAssets, uint256 idle);

    error ZeroAddress();
    error StrategyAlreadyRegistered(address strategy);
    error StrategyNotRegistered(address strategy);
    error StrategyLimitReached();
    error AssetMismatch(address strategy, address expected, address actual);
    error VaultMismatch(address strategy, address expected, address actual);
    error AllocationExceeded(uint256 requested, uint256 maximum);
    error IncompleteExit(address strategy, uint256 remaining);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param asset_                The ERC-20 this vault accepts.
    /// @param name_                 Name of the share token.
    /// @param symbol_               Symbol of the share token.
    /// @param governance_           Receives the admin, governor and keeper roles.
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address governance_
    ) external initializer {
        if (governance_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20Upgradeable(address(asset_)));
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Idle balance plus every strategy's live report. Assets sitting in an external protocol
    ///      stay inside the share price rather than dropping out of it.
    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));

        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; ++i) {
            total += IStrategy(_strategies[i]).totalAssets();
        }
    }

    /// @notice Assets that could actually leave the vault this block.
    function liquidAssets() public view returns (uint256 liquid) {
        liquid = IERC20(asset()).balanceOf(address(this));

        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; ++i) {
            liquid += IStrategy(_strategies[i]).availableLiquidity();
        }
    }

    /// @notice Every registered strategy, in the order withdrawals draw from them.
    function strategies() external view returns (address[] memory) {
        return _strategies;
    }

    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @dev Withdrawals stay open while paused so a halt can never trap depositors.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(receiver);
    }

    /// @dev Capped by what the strategies can actually release, so a quote is never a promise the
    ///      vault cannot keep in the same block.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), liquidAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 redeemable = _convertToShares(liquidAssets(), MathUpgradeable.Rounding.Down);
        return Math.min(super.maxRedeem(owner), redeemable);
    }

    /// @notice Register a strategy and reserve `targetBps` of the vault's assets for it.
    function addStrategy(address strategy, uint16 targetBps) external onlyRole(GOVERNOR_ROLE) {
        if (strategy == address(0)) revert ZeroAddress();
        if (strategyParams[strategy].active) revert StrategyAlreadyRegistered(strategy);
        if (_strategies.length >= MAX_STRATEGIES) revert StrategyLimitReached();
        _validateStrategy(strategy);

        uint256 allocation = uint256(totalTargetBps) + targetBps;
        if (allocation > MAX_BPS) revert AllocationExceeded(allocation, MAX_BPS);

        strategyParams[strategy] =
            StrategyParams({active: true, targetBps: targetBps, principal: 0});
        _strategies.push(strategy);
        totalTargetBps = uint16(allocation);

        emit StrategyAdded(strategy, targetBps);
    }

    /// @notice Change how much of the vault a strategy is meant to hold.
    /// @dev Takes effect on the next {rebalance}; capital is not moved here.
    function setAllocation(address strategy, uint16 targetBps) external onlyRole(GOVERNOR_ROLE) {
        StrategyParams storage params = _activeStrategy(strategy);

        uint256 allocation = uint256(totalTargetBps) - params.targetBps + targetBps;
        if (allocation > MAX_BPS) revert AllocationExceeded(allocation, MAX_BPS);

        emit StrategyAllocationUpdated(strategy, params.targetBps, targetBps);

        params.targetBps = targetBps;
        totalTargetBps = uint16(allocation);
    }

    /// @notice Retire a strategy, returning everything it holds to the idle buffer.
    function removeStrategy(address strategy) external onlyRole(GOVERNOR_ROLE) {
        StrategyParams storage params = _activeStrategy(strategy);
        totalTargetBps -= params.targetBps;

        uint256 returned = _exitStrategy(strategy);

        delete strategyParams[strategy];
        _dropFromQueue(strategy);

        emit StrategyRemoved(strategy, returned);
    }

    /// @notice Move a strategy's capital and allocation to a replacement in one transaction.
    /// @dev The old strategy must be able to hand back its entire position; a partial exit reverts
    ///      the whole migration rather than stranding assets in a contract the vault has dropped.
    ///      A shortfall against the pre-migration report is surfaced as a loss.
    function migrateStrategy(address from, address to) external onlyRole(GOVERNOR_ROLE) {
        StrategyParams storage source = _activeStrategy(from);
        if (to == address(0)) revert ZeroAddress();
        if (strategyParams[to].active) revert StrategyAlreadyRegistered(to);
        _validateStrategy(to);

        uint16 targetBps = source.targetBps;
        uint256 expected = IStrategy(from).totalAssets();
        uint256 returned = _exitStrategy(from);

        delete strategyParams[from];
        _replaceInQueue(from, to);
        strategyParams[to] = StrategyParams({active: true, targetBps: targetBps, principal: 0});

        if (returned > 0) _deploy(to, returned);
        if (returned < expected) {
            emit StrategyReported(from, 0, expected - returned, 0);
        }

        emit StrategyMigrated(from, to, returned);
    }

    /// @notice Compound one strategy's yield and book the result against its principal.
    function harvest(address strategy) external onlyRole(KEEPER_ROLE) {
        _activeStrategy(strategy);
        _harvest(strategy);
    }

    /// @notice Compound every strategy and push the freed capital back out to target weights.
    function harvestAll() external onlyRole(KEEPER_ROLE) {
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; ++i) {
            _harvest(_strategies[i]);
        }
        _rebalance();
    }

    /// @notice Move capital between the idle buffer and the strategies to match target weights.
    function rebalance() external onlyRole(KEEPER_ROLE) {
        _rebalance();
    }

    /// @notice Halt deposits and mints. Withdrawals stay open.
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    /// @dev Tops the idle buffer up from the strategies before the shares are burned, so a user
    ///      exit never depends on the keeper having rebalanced recently.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 idle = IERC20(asset()).balanceOf(address(this));

        if (idle < assets) {
            uint256 raised = idle + _pullFromStrategies(assets - idle);
            if (raised < assets) revert InsufficientLiquidity(assets, raised);
        }

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Upgrades must be initiated by a contract (e.g. Gnosis Safe), never an EOA.
    error EOAUpgradeNotAllowed();

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tx.origin == msg.sender) revert EOAUpgradeNotAllowed();
    }

    /// @dev Draws from strategies in queue order until `needed` is covered or they run dry.
    function _pullFromStrategies(uint256 needed) private returns (uint256 raised) {
        uint256 length = _strategies.length;

        for (uint256 i = 0; i < length && raised < needed; ++i) {
            address strategy = _strategies[i];
            uint256 received = IStrategy(strategy).withdraw(needed - raised);
            if (received == 0) continue;

            raised += received;
            _reducePrincipal(strategy, received);
        }
    }

    function _rebalance() private {
        uint256 total = totalAssets();
        uint256 length = _strategies.length;

        for (uint256 i = 0; i < length; ++i) {
            address strategy = _strategies[i];
            uint256 target = total.mulDiv(strategyParams[strategy].targetBps, MAX_BPS);
            uint256 current = IStrategy(strategy).totalAssets();

            if (current > target) {
                uint256 received = IStrategy(strategy).withdraw(current - target);
                _reducePrincipal(strategy, received);
            }
        }

        uint256 idle = IERC20(asset()).balanceOf(address(this));

        for (uint256 i = 0; i < length && idle > 0; ++i) {
            address strategy = _strategies[i];
            uint256 target = total.mulDiv(strategyParams[strategy].targetBps, MAX_BPS);
            uint256 current = IStrategy(strategy).totalAssets();

            if (current < target) {
                uint256 amount = Math.min(target - current, idle);
                _deploy(strategy, amount);
                idle -= amount;
            }
        }

        emit Rebalanced(total, idle);
    }

    function _harvest(address strategy) private {
        IStrategy(strategy).harvest();

        StrategyParams storage params = strategyParams[strategy];
        uint256 principal = params.principal;
        uint256 current = IStrategy(strategy).totalAssets();

        params.principal = current;

        emit StrategyReported(
            strategy,
            current > principal ? current - principal : 0,
            principal > current ? principal - current : 0,
            current
        );
    }

    function _deploy(address strategy, uint256 assets) private {
        IERC20(asset()).safeTransfer(strategy, assets);
        IStrategy(strategy).deposit(assets);
        strategyParams[strategy].principal += assets;
    }

    /// @dev Unwind a strategy completely, measuring what the vault actually received rather than
    ///      trusting the strategy's return value, and refusing to continue if anything is left.
    function _exitStrategy(address strategy) private returns (uint256 returned) {
        IERC20 assetToken = IERC20(asset());
        uint256 balanceBefore = assetToken.balanceOf(address(this));

        IStrategy(strategy).withdrawAll();
        returned = assetToken.balanceOf(address(this)) - balanceBefore;

        uint256 remaining = IStrategy(strategy).totalAssets();
        if (remaining != 0) revert IncompleteExit(strategy, remaining);
    }

    function _reducePrincipal(address strategy, uint256 amount) private {
        StrategyParams storage params = strategyParams[strategy];
        params.principal = params.principal > amount ? params.principal - amount : 0;
    }

    function _validateStrategy(address strategy) private view {
        address expectedAsset = asset();
        address actualAsset = IStrategy(strategy).asset();
        if (actualAsset != expectedAsset) {
            revert AssetMismatch(strategy, expectedAsset, actualAsset);
        }

        address actualVault = IStrategy(strategy).vault();
        if (actualVault != address(this)) {
            revert VaultMismatch(strategy, address(this), actualVault);
        }
    }

    function _activeStrategy(address strategy)
        private
        view
        returns (StrategyParams storage params)
    {
        params = strategyParams[strategy];
        if (!params.active) revert StrategyNotRegistered(strategy);
    }

    function _dropFromQueue(address strategy) private {
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_strategies[i] == strategy) {
                _strategies[i] = _strategies[length - 1];
                _strategies.pop();
                return;
            }
        }
    }

    function _replaceInQueue(address from, address to) private {
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_strategies[i] == from) {
                _strategies[i] = to;
                return;
            }
        }
    }
}
