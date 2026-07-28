// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

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
contract CDPEngine is Ownable {
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

    // ─── Events ─────────────────────────────────────────────────────────────

    event CollateralWhitelisted(
        address indexed token, uint256 minCollateralRatio, uint256 liquidationPenalty
    );
    event PriceFeedSet(address indexed token, address indexed priceFeed);
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

    constructor(IMintableERC20 stablecoin_, address owner_) Ownable(owner_) {
        require(address(stablecoin_) != address(0), "CDPEngine: Zero stablecoin");
        stablecoin = stablecoin_;
    }

    // ─── Admin Whitelisting ─────────────────────────────────────────────────

    function whitelistCollateral(
        address token,
        uint256 minCollateralRatio,
        uint256 liquidationPenalty
    ) external onlyOwner {
        require(token != address(0), "CDPEngine: Zero token");
        require(minCollateralRatio >= 1e18, "CDPEngine: Ratio must be >= 100%");
        require(liquidationPenalty >= 1e18, "CDPEngine: Penalty must be >= 100%");

        collateralConfigs[token] = CollateralConfig({
            whitelisted: true,
            minCollateralRatio: minCollateralRatio,
            liquidationPenalty: liquidationPenalty
        });

        emit CollateralWhitelisted(token, minCollateralRatio, liquidationPenalty);
    }

    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        require(token != address(0), "CDPEngine: Zero token");
        require(priceFeed != address(0), "CDPEngine: Zero price feed");
        require(collateralConfigs[token].whitelisted, "CDPEngine: Collateral not whitelisted");

        priceFeeds[token] = priceFeed;
        emit PriceFeedSet(token, priceFeed);
    }

    // ─── Collateral Operations ──────────────────────────────────────────────

    function depositCollateral(address collateralType, uint256 amount) external {
        require(
            collateralConfigs[collateralType].whitelisted, "CDPEngine: Collateral not whitelisted"
        );
        require(amount > 0, "CDPEngine: Zero amount");

        positions[collateralType][msg.sender].collateral += amount;

        IERC20(collateralType).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralDeposited(collateralType, msg.sender, amount);
    }

    function withdrawCollateral(address collateralType, uint256 amount) external {
        Position storage pos = positions[collateralType][msg.sender];
        require(amount > 0, "CDPEngine: Zero amount");
        require(pos.collateral >= amount, "CDPEngine: Insufficient collateral balance");

        pos.collateral -= amount;

        // Position safety check (only if there is active debt)
        if (pos.debt > 0) {
            require(
                isPositionSafe(collateralType, msg.sender),
                "CDPEngine: Position unsafe after withdrawal"
            );
        }

        IERC20(collateralType).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(collateralType, msg.sender, amount);
    }

    // ─── Debt Operations ────────────────────────────────────────────────────

    function borrow(address collateralType, uint256 amount) external {
        require(
            collateralConfigs[collateralType].whitelisted, "CDPEngine: Collateral not whitelisted"
        );
        require(amount > 0, "CDPEngine: Zero amount");

        Position storage pos = positions[collateralType][msg.sender];
        pos.debt += amount;

        require(isPositionSafe(collateralType, msg.sender), "CDPEngine: Borrow exceeds max LTV");

        stablecoin.mint(msg.sender, amount);

        emit Borrowed(collateralType, msg.sender, amount);
    }

    function repay(address collateralType, uint256 amount) external {
        Position storage pos = positions[collateralType][msg.sender];
        require(amount > 0, "CDPEngine: Zero amount");
        require(pos.debt >= amount, "CDPEngine: Repay exceeds debt");

        pos.debt -= amount;

        stablecoin.burn(msg.sender, amount);

        emit Repaid(collateralType, msg.sender, amount);
    }

    // ─── Liquidation ────────────────────────────────────────────────────────

    function liquidate(address collateralType, address user, uint256 debtToCover) external {
        require(
            collateralConfigs[collateralType].whitelisted, "CDPEngine: Collateral not whitelisted"
        );
        Position storage pos = positions[collateralType][user];

        require(!isPositionSafe(collateralType, user), "CDPEngine: Position is safe");
        require(debtToCover > 0, "CDPEngine: Zero debt to cover");
        require(pos.debt >= debtToCover, "CDPEngine: Cover exceeds debt");

        CollateralConfig memory config = collateralConfigs[collateralType];
        uint256 price = getNormalizedPrice(collateralType);

        // Seized collateral value in USD (with penalty applied, e.g. 1.1 * debtToCover)
        uint256 collateralValueToSeize = (debtToCover * config.liquidationPenalty) / 1e18;

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
        require(feed != address(0), "CDPEngine: Price feed not set");

        (, int256 answer,,,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, "CDPEngine: Invalid price");

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
