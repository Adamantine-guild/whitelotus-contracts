import { expect } from "chai";
import { ethers } from "hardhat";
import { Signer } from "ethers";
import { 
    CDPEngine, 
    Liquidator, 
    MockERC20, 
    MockAggregatorV3 
} from "../../typechain-types"; // Assuming standard typechain setup

describe("Autonomous Liquidation Engine", function () {
    let cdpEngine: CDPEngine;
    let liquidator: Liquidator;
    let stablecoin: MockERC20;
    let collateral: MockERC20;
    let oracle: MockAggregatorV3;
    let owner: Signer;
    let user: Signer;
    let liquidatorSigner: Signer;

    const MIN_COLLATERAL_RATIO = ethers.parseEther("1.5"); // 150%

    beforeEach(async function () {
        [owner, user, liquidatorSigner] = await ethers.getSigners();

        // Deploy Mock Tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        stablecoin = await MockERC20Factory.deploy("Stablecoin", "STABLE", 18) as unknown as MockERC20;
        collateral = await MockERC20Factory.deploy("Collateral", "COL", 18) as unknown as MockERC20;

        // Deploy Oracle
        const MockAggregatorFactory = await ethers.getContractFactory("MockAggregatorV3");
        oracle = await MockAggregatorFactory.deploy(18, ethers.parseEther("2000")) as unknown as MockAggregatorV3; // $2000 per COL

        // Deploy CDPEngine
        const CDPEngineFactory = await ethers.getContractFactory("CDPEngine");
        cdpEngine = await CDPEngineFactory.deploy(await stablecoin.getAddress(), await owner.getAddress()) as unknown as CDPEngine;

        // Deploy Liquidator
        const LiquidatorFactory = await ethers.getContractFactory("Liquidator");
        liquidator = await LiquidatorFactory.deploy(await cdpEngine.getAddress(), await stablecoin.getAddress()) as unknown as Liquidator;

        // Setup CDPEngine
        await cdpEngine.setLiquidatorRole(await liquidator.getAddress());
        await cdpEngine.whitelistCollateral(
            await collateral.getAddress(), 
            MIN_COLLATERAL_RATIO, 
            ethers.parseEther("1.1") // Old fixed penalty, ignored now
        );
        await cdpEngine.setPriceFeed(await collateral.getAddress(), await oracle.getAddress());

        // Mint initial tokens
        await collateral.mint(await user.getAddress(), ethers.parseEther("100"));
        await stablecoin.mint(await liquidatorSigner.getAddress(), ethers.parseEther("100000")); // For liquidating

        // User deposits 1 COL
        await collateral.connect(user).approve(await cdpEngine.getAddress(), ethers.parseEther("1"));
        await cdpEngine.connect(user).depositCollateral(await collateral.getAddress(), ethers.parseEther("1"));
    });

    it("should revert liquidation if health factor >= 1.0", async function () {
        // Price is $2000. 1 COL = $2000. 
        // Max borrow = 2000 / 1.5 = 1333.33 STABLE
        await cdpEngine.connect(user).borrow(await collateral.getAddress(), ethers.parseEther("1333"));
        
        // HF is > 1.0, so this should revert
        const debtToCover = ethers.parseEther("100");
        await stablecoin.connect(liquidatorSigner).approve(await liquidator.getAddress(), debtToCover);

        await expect(
            liquidator.connect(liquidatorSigner).liquidatePosition(await collateral.getAddress(), await user.getAddress(), debtToCover)
        ).to.be.revertedWith("Liquidator: Position is safe");
    });

    it("should allow liquidation if health factor strictly < 1.0", async function () {
        // Borrow exactly max safe amount initially
        await cdpEngine.connect(user).borrow(await collateral.getAddress(), ethers.parseEther("1333"));

        // Price drops to $1500
        await oracle.updateAnswer(ethers.parseEther("1500"));

        const debtToCover = ethers.parseEther("500");
        await stablecoin.connect(liquidatorSigner).approve(await liquidator.getAddress(), debtToCover);

        // Calculate expected penalty (HF is approx 1500 / (1333 * 1.5) = 1500 / 1999.5 = 0.75 < 0.90 => Tier 3: 15% penalty)
        // 500 debt * 1.15 penalty = 575 USD of collateral
        // 575 USD / 1500 = 0.38333 COL seized
        const expectedColSeized = ethers.parseEther("575") * 10n**18n / ethers.parseEther("1500");
        
        await expect(
            liquidator.connect(liquidatorSigner).liquidatePosition(await collateral.getAddress(), await user.getAddress(), debtToCover)
        ).to.emit(liquidator, "LiquidationExecuted")
         .withArgs(await collateral.getAddress(), await user.getAddress(), debtToCover, expectedColSeized, await liquidatorSigner.getAddress());
    });

    it("should apply tiered penalty accurately (Tier 1: HF 0.95-1.0)", async function () {
        await cdpEngine.connect(user).borrow(await collateral.getAddress(), ethers.parseEther("1333"));
        
        // Price drops slightly to $1950. 
        // HF = 1950 / (1333 * 1.5) = 0.975 (Tier 1 -> 5% penalty)
        await oracle.updateAnswer(ethers.parseEther("1950"));

        const debtToCover = ethers.parseEther("100");
        await stablecoin.connect(liquidatorSigner).approve(await liquidator.getAddress(), debtToCover);

        const expectedColSeized = ethers.parseEther("105") * 10n**18n / ethers.parseEther("1950");

        await expect(
            liquidator.connect(liquidatorSigner).liquidatePosition(await collateral.getAddress(), await user.getAddress(), debtToCover)
        ).to.emit(liquidator, "LiquidationExecuted")
         .withArgs(await collateral.getAddress(), await user.getAddress(), debtToCover, expectedColSeized, await liquidatorSigner.getAddress());
    });

    it("should apply tiered penalty accurately (Tier 2: HF 0.90-0.95)", async function () {
        await cdpEngine.connect(user).borrow(await collateral.getAddress(), ethers.parseEther("1333"));
        
        // Price drops to $1850. 
        // HF = 1850 / (1333 * 1.5) = 0.925 (Tier 2 -> 10% penalty)
        await oracle.updateAnswer(ethers.parseEther("1850"));

        const debtToCover = ethers.parseEther("100");
        await stablecoin.connect(liquidatorSigner).approve(await liquidator.getAddress(), debtToCover);

        const expectedColSeized = ethers.parseEther("110") * 10n**18n / ethers.parseEther("1850");

        await expect(
            liquidator.connect(liquidatorSigner).liquidatePosition(await collateral.getAddress(), await user.getAddress(), debtToCover)
        ).to.emit(liquidator, "LiquidationExecuted")
         .withArgs(await collateral.getAddress(), await user.getAddress(), debtToCover, expectedColSeized, await liquidatorSigner.getAddress());
    });

    it("should enforce the partial liquidation cap", async function () {
        await cdpEngine.connect(user).borrow(await collateral.getAddress(), ethers.parseEther("1333"));
        
        // Price drops to $1000
        await oracle.updateAnswer(ethers.parseEther("1000"));

        // Max liquidatable = 1333 * 50% = 666.5
        const debtToCover = ethers.parseEther("667"); // Exceeds cap
        await stablecoin.connect(liquidatorSigner).approve(await liquidator.getAddress(), debtToCover);

        await expect(
            liquidator.connect(liquidatorSigner).liquidatePosition(await collateral.getAddress(), await user.getAddress(), debtToCover)
        ).to.be.revertedWith("Liquidator: Exceeds partial liquidation cap");
    });
});
