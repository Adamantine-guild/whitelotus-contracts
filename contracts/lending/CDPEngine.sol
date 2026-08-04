// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function decimals() external view returns (uint8);
}

/**
 * @title CDPEngine
 * @notice Multi-Collateral Debt Position Engine allowing users to deposit whitelisted collateral ERC20s,
 *         and borrow a stablecoin using dynamic parameters and normalized fixed-point 18-decimal math.
 */
contract CDPEngine is Ownable2Step {
    error ZeroStablecoin();
    error ZeroToken();
    error InvalidMinimumCollateralRatio();
    error InvalidLiquidationPenalty();
    error ZeroPriceFeed();
    error CollateralNotWhitelisted();
    error ZeroAmount();
    error InsufficientCollateralBalance();
    error PositionUnsafeAfterWithdrawal();
    error BorrowExceedsMaxLTV();
    error RepayExceedsDebt();
    error PositionIsSafe();
    error ZeroDebtToCover();
    error CoverExceedsDebt();
    error PriceFeedNotSet();
    error InvalidPrice();

    using SafeERC20 for IERC20;

    // ─── Structs ────────────────────────────────────────────────────────────

    struct Position {
        uint256 collateral; // Raw amount of collateral deposited
        uint256 debt; // Borrowed debt amount (18 decimals)
    }

    struct CollateralConfig {
        bool whitelisted;
        uint256 minCollateralRatio; // 18 decimals (e.g. 1.5 * 1e18 = 150%)
        uint256 liquidationPenalty; // 18 decimals (e.g. 1.1 * 1e18 = 110% multiplier)
    }

    // ─── State ──────────────────────────────────────────────────────────────

    IMintableERC20 public immutable stablecoin;

    mapping(address => CollateralConfig) public collateralConfigs;
    mapping(address => address) public priceFeeds;

    // collateral => user => position
    mapping(address => mapping(address => Position)) public positions;

    address public liquidatorRole;

    // ─── Events ─────────────────────────────────────────────────────────────

    event CollateralWhitelisted(
        address indexed token, uint256 minCollateralRatio, uint256 liquidationPenalty
    );
    event PriceFeedSet(address indexed token, address indexed priceFeed);
    event LiquidatorRoleSet(address indexed liquidator);
    event CollateralDeposited(address indexed collateralType, address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed collateralType, address indexed user, uint256 amount);
    event Borrowed(address indexed collateralType, address indexed user, uint256 amount);
    event Repaid(address indexed collateralType, address indexed user, uint256 amount);
    event Liquidated(
        address indexed collateralType,
        address indexed user,
        uint256 debtCovered,
        uint256 collateralSeized,
        address indexed liquidator
    );

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(IMintableERC20 stablecoin_, address owner_) Ownable2Step() {
        if (owner_ != msg.sender) _transferOwnership(owner_);
        if (!(address(stablecoin_) != address(0))) revert ZeroStablecoin();
        stablecoin = stablecoin_;
    }

    // ─── Admin Whitelisting ─────────────────────────────────────────────────

    function whitelistCollateral(
        address token,
        uint256 minCollateralRatio,
        uint256 liquidationPenalty
    ) external onlyOwner {
        if (!(token != address(0))) revert ZeroToken();
        if (!(minCollateralRatio >= 1e18)) revert InvalidMinimumCollateralRatio();
        if (!(liquidationPenalty >= 1e18)) revert InvalidLiquidationPenalty();

        collateralConfigs[token] = CollateralConfig({
            whitelisted: true,
            minCollateralRatio: minCollateralRatio,
            liquidationPenalty: liquidationPenalty
        });

        emit CollateralWhitelisted(token, minCollateralRatio, liquidationPenalty);
    }

    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        if (!(token != address(0))) revert ZeroToken();
        if (!(priceFeed != address(0))) revert ZeroPriceFeed();
        if (!(collateralConfigs[token].whitelisted)) revert CollateralNotWhitelisted();

        priceFeeds[token] = priceFeed;
        emit PriceFeedSet(token, priceFeed);
    }

    function setLiquidatorRole(address _liquidator) external onlyOwner {
        liquidatorRole = _liquidator;
        emit LiquidatorRoleSet(_liquidator);
    }

    // ─── Collateral Operations ──────────────────────────────────────────────

    function depositCollateral(address collateralType, uint256 amount) external {
        if (!(collateralConfigs[collateralType].whitelisted)) revert CollateralNotWhitelisted();
        if (!(amount > 0)) revert ZeroAmount();

        positions[collateralType][msg.sender].collateral += amount;

        IERC20(collateralType).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(collateralType, msg.sender, amount);
    }

    function withdrawCollateral(address collateralType, uint256 amount) external {
        Position storage pos = positions[collateralType][msg.sender];
        if (!(amount > 0)) revert ZeroAmount();
        if (!(pos.collateral >= amount)) revert InsufficientCollateralBalance();

        pos.collateral -= amount;

        // Position safety check (only if there is active debt)
        if (pos.debt > 0) {
            if (!(isPositionSafe(collateralType, msg.sender))) revert PositionUnsafeAfterWithdrawal();
        }

        IERC20(collateralType).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(collateralType, msg.sender, amount);
    }

    // ─── Debt Operations ────────────────────────────────────────────────────

    function borrow(address collateralType, uint256 amount) external {
        if (!(collateralConfigs[collateralType].whitelisted)) revert CollateralNotWhitelisted();
        if (!(amount > 0)) revert ZeroAmount();

        Position storage pos = positions[collateralType][msg.sender];
        pos.debt += amount;

        if (!(isPositionSafe(collateralType, msg.sender))) revert BorrowExceedsMaxLTV();

        stablecoin.mint(msg.sender, amount);

        emit Borrowed(collateralType, msg.sender, amount);
    }

    function repay(address collateralType, uint256 amount) external {
        Position storage pos = positions[collateralType][msg.sender];
        if (!(amount > 0)) revert ZeroAmount();
        if (!(pos.debt >= amount)) revert RepayExceedsDebt();

        pos.debt -= amount;

        stablecoin.burn(msg.sender, amount);

        emit Repaid(collateralType, msg.sender, amount);
    }

    // ─── Liquidation ────────────────────────────────────────────────────────

    function liquidate(address collateralType, address user, uint256 debtToCover) external {
        if (!(collateralConfigs[collateralType].whitelisted)) revert CollateralNotWhitelisted();
        Position storage pos = positions[collateralType][user];

        if (!(!isPositionSafe(collateralType, user))) revert PositionIsSafe();
        if (!(debtToCover > 0)) revert ZeroDebtToCover();
        if (!(pos.debt >= debtToCover)) revert CoverExceedsDebt();

        uint256 price = getNormalizedPrice(collateralType);
        uint256 appliedPenalty = collateralConfigs[collateralType].liquidationPenalty;

        // Seized collateral value in USD (with penalty applied)
        uint256 collateralValueToSeize = (debtToCover * appliedPenalty) / 1e18;

        // Seized collateral amount (normalized to 18 decimals)
        // Amount = Value / Price
        uint256 normalizedCollateralToSeize = (collateralValueToSeize * 1e18) / price;

        // Convert normalized collateral amount to the token's native decimals
        uint256 collateralToSeize =
            denormalizeCollateralAmount(collateralType, normalizedCollateralToSeize);

        // Cap to total collateral available in the position (if position is underwater)
        if (collateralToSeize > pos.collateral) {
            collateralToSeize = pos.collateral;
        }

        pos.debt -= debtToCover;
        pos.collateral -= collateralToSeize;

        // Burn debt covering stablecoin from liquidator
        IERC20(address(stablecoin)).safeTransferFrom(msg.sender, address(this), debtToCover);
        stablecoin.burn(address(this), debtToCover);

        // Transfer seized collateral to liquidator
        IERC20(collateralType).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(collateralType, user, debtToCover, collateralToSeize, msg.sender);
    }

    // ─── Safety & Normalized Math ───────────────────────────────────────────

    function isPositionSafe(address collateralType, address user) public view returns (bool) {
        Position memory pos = positions[collateralType][user];
        if (pos.debt == 0) {
            return true;
        }

        CollateralConfig memory config = collateralConfigs[collateralType];
        uint256 price = getNormalizedPrice(collateralType);
        uint256 normalizedCollateral = getNormalizedCollateralAmount(collateralType, pos.collateral);

        // Collateral value = normalized collateral amount * price / 1e18
        uint256 collateralValue = (normalizedCollateral * price) / 1e18;

        // Required collateral value = debt * minCollateralRatio / 1e18
        uint256 requiredCollateralValue = (pos.debt * config.minCollateralRatio) / 1e18;

        return collateralValue >= requiredCollateralValue;
    }

    function getNormalizedPrice(address token) public view returns (uint256) {
        address feed = priceFeeds[token];
        if (!(feed != address(0))) revert PriceFeedNotSet();

        (, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
        if (!(answer > 0)) revert InvalidPrice();

        uint8 decimals = AggregatorV3Interface(feed).decimals();
        if (decimals == 18) {
            return uint256(answer);
        } else if (decimals < 18) {
            return uint256(answer) * 10 ** (18 - decimals);
        } else {
            return uint256(answer) / 10 ** (decimals - 18);
        }
    }

    function getNormalizedCollateralAmount(address token, uint256 amount)
        public
        view
        returns (uint256)
    {
        uint8 decimals = IMintableERC20(token).decimals();
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount * 10 ** (18 - decimals);
        } else {
            return amount / 10 ** (decimals - 18);
        }
    }

    function denormalizeCollateralAmount(address token, uint256 amount)
        public
        view
        returns (uint256)
    {
        uint8 decimals = IMintableERC20(token).decimals();
        if (decimals == 18) {
            return amount;
        } else if (decimals < 18) {
            return amount / 10 ** (18 - decimals);
        } else {
            return amount * 10 ** (decimals - 18);
        }
    }
}
