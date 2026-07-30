import { expect } from "chai";
import hre from "hardhat";

const WAD = 10n ** 18n;
const OFFSET = 6;
const MAX_BPS = 10_000;

/// Asserts `actual` is within `tolerance` wei of `expected`, absorbing the rounding the virtual
/// share offset introduces on every conversion.
function expectApprox(actual: bigint, expected: bigint, tolerance = 10n) {
  const difference = actual > expected ? actual - expected : expected - actual;
  expect(
    difference <= tolerance,
    `expected ${actual} to be within ${tolerance} of ${expected}`
  ).to.equal(true);
}

describe("WhiteLotusERC4626", function () {
  let connection: any;
  let ethers: any;
  let governance: any;
  let keeper: any;
  let alice: any;
  let bob: any;
  let attacker: any;

  let asset: any;
  let assetAddress: string;
  let vault: any;
  let vaultAddress: string;
  let implementation: any;

  let pool: any;
  let aToken: any;
  let aaveStrategy: any;
  let aaveAddress: string;

  async function deployVault(offset: number) {
    const factory = await ethers.getContractFactory(
      "contracts/vaults/WhiteLotusERC4626.sol:WhiteLotusERC4626"
    );
    const impl = await factory.deploy();
    await impl.waitForDeployment();

    const initData = factory.interface.encodeFunctionData("initialize", [
      assetAddress,
      "White Lotus mUSDC Vault",
      "wlmUSDC",
      offset,
      await governance.getAddress(),
    ]);

    const proxyFactory = await ethers.getContractFactory(
      "contracts/vaults/VaultProxy.sol:VaultProxy"
    );
    const proxy = await proxyFactory.deploy(await impl.getAddress(), initData);
    await proxy.waitForDeployment();

    return {
      impl,
      vault: factory.attach(await proxy.getAddress()).connect(governance),
    };
  }

  async function deployAaveStrategy(target: string) {
    const poolFactory = await ethers.getContractFactory(
      "contracts/mocks/MockAavePool.sol:MockAavePool"
    );
    const lendingPool = await poolFactory.deploy();
    await lendingPool.waitForDeployment();

    const aTokenFactory = await ethers.getContractFactory(
      "contracts/mocks/MockAToken.sol:MockAToken"
    );
    const receipt = await aTokenFactory.deploy(
      assetAddress,
      await lendingPool.getAddress(),
      "Aave Mock USDC",
      "aMUSDC"
    );
    await receipt.waitForDeployment();
    await lendingPool.setAToken(assetAddress, await receipt.getAddress());

    const strategyFactory = await ethers.getContractFactory(
      "contracts/strategies/AaveYieldStrategy.sol:AaveYieldStrategy"
    );
    const strategy = await strategyFactory.deploy(
      assetAddress,
      target,
      await lendingPool.getAddress(),
      await receipt.getAddress()
    );
    await strategy.waitForDeployment();

    return { pool: lendingPool, aToken: receipt, strategy };
  }

  async function deployMockStrategy(target: string) {
    const factory = await ethers.getContractFactory(
      "contracts/mocks/MockYieldStrategy.sol:MockYieldStrategy"
    );
    const strategy = await factory.deploy(assetAddress, target);
    await strategy.waitForDeployment();
    return strategy;
  }

  async function fund(account: any, amount: bigint) {
    await asset.mint(await account.getAddress(), amount);
    await asset.connect(account).approve(vaultAddress, ethers.MaxUint256);
  }

  beforeEach(async function () {
    connection = await hre.network.create();
    ethers = connection.ethers;
    [governance, keeper, alice, bob, attacker] = await ethers.getSigners();

    const assetFactory = await ethers.getContractFactory(
      "contracts/mocks/MockERC20.sol:MockERC20"
    );
    asset = await assetFactory.deploy("Mock USDC", "mUSDC", 18);
    await asset.waitForDeployment();
    assetAddress = await asset.getAddress();

    const deployment = await deployVault(OFFSET);
    implementation = deployment.impl;
    vault = deployment.vault;
    vaultAddress = await vault.getAddress();

    const aave = await deployAaveStrategy(vaultAddress);
    pool = aave.pool;
    aToken = aave.aToken;
    aaveStrategy = aave.strategy;
    aaveAddress = await aaveStrategy.getAddress();

    await fund(alice, 1_000_000n * WAD);
    await fund(bob, 1_000_000n * WAD);
    await fund(attacker, 1_000_000n * WAD);
  });

  describe("initialization", function () {
    it("wires up the asset, share token and roles", async function () {
      expect(await vault.asset()).to.equal(assetAddress);
      expect(await vault.name()).to.equal("White Lotus mUSDC Vault");
      expect(await vault.symbol()).to.equal("wlmUSDC");
      expect(await vault.decimals()).to.equal(18 + OFFSET);
      expect(await vault.totalAssets()).to.equal(0);

      const governor = await governance.getAddress();
      expect(await vault.hasRole(await vault.DEFAULT_ADMIN_ROLE(), governor)).to.equal(true);
      expect(await vault.hasRole(await vault.GOVERNOR_ROLE(), governor)).to.equal(true);
      expect(await vault.hasRole(await vault.KEEPER_ROLE(), governor)).to.equal(true);
    });

    it("rejects a zero governance address", async function () {
      const factory = await ethers.getContractFactory(
        "contracts/vaults/WhiteLotusERC4626.sol:WhiteLotusERC4626"
      );
      const impl = await factory.deploy();
      await impl.waitForDeployment();

      const initData = factory.interface.encodeFunctionData("initialize", [
        assetAddress,
        "n",
        "s",
        OFFSET,
        ethers.ZeroAddress,
      ]);

      const proxyFactory = await ethers.getContractFactory(
        "contracts/vaults/VaultProxy.sol:VaultProxy"
      );
      await expect(
        proxyFactory.deploy(await impl.getAddress(), initData)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");
    });

    it("rejects an offset above the supported maximum", async function () {
      await expect(deployVault(19)).to.be.revertedWithCustomError(vault, "InvalidOffset");
    });

    it("cannot be initialized twice", async function () {
      await expect(
        vault.initialize(assetAddress, "n", "s", OFFSET, await governance.getAddress())
      ).to.be.revertedWithCustomError(vault, "InvalidInitialization");
    });

    it("leaves the implementation itself uninitializable", async function () {
      await expect(
        implementation.initialize(assetAddress, "n", "s", OFFSET, await governance.getAddress())
      ).to.be.revertedWithCustomError(implementation, "InvalidInitialization");
    });
  });

  describe("ERC-4626 conformance", function () {
    it("mints shares matching previewDeposit", async function () {
      const assets = 1000n * WAD;
      const preview = await vault.previewDeposit(assets);

      await expect(vault.connect(alice).deposit(assets, await alice.getAddress()))
        .to.emit(vault, "Deposit")
        .withArgs(await alice.getAddress(), await alice.getAddress(), assets, preview);

      expect(await vault.balanceOf(await alice.getAddress())).to.equal(preview);
      expect(await vault.totalAssets()).to.equal(assets);
    });

    it("charges assets matching previewMint", async function () {
      const shares = 1000n * WAD * BigInt(10 ** OFFSET);
      const preview = await vault.previewMint(shares);
      const before = await asset.balanceOf(await alice.getAddress());

      await vault.connect(alice).mint(shares, await alice.getAddress());

      expect(await vault.balanceOf(await alice.getAddress())).to.equal(shares);
      expect(before - (await asset.balanceOf(await alice.getAddress()))).to.equal(preview);
    });

    it("burns shares matching previewWithdraw and previewRedeem", async function () {
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());

      const withdrawAmount = 400n * WAD;
      const expectedShares = await vault.previewWithdraw(withdrawAmount);
      const sharesBefore = await vault.balanceOf(await alice.getAddress());

      await expect(
        vault
          .connect(alice)
          .withdraw(withdrawAmount, await alice.getAddress(), await alice.getAddress())
      ).to.emit(vault, "Withdraw");

      expect(sharesBefore - (await vault.balanceOf(await alice.getAddress()))).to.equal(
        expectedShares
      );

      const remaining = await vault.balanceOf(await alice.getAddress());
      const expectedAssets = await vault.previewRedeem(remaining);
      const assetsBefore = await asset.balanceOf(await alice.getAddress());

      await vault.connect(alice).redeem(remaining, await alice.getAddress(), await alice.getAddress());

      expect((await asset.balanceOf(await alice.getAddress())) - assetsBefore).to.equal(
        expectedAssets
      );
    });

    it("round-trips through convertToShares and convertToAssets", async function () {
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());

      const assets = 137n * WAD;
      const shares = await vault.convertToShares(assets);
      expectApprox(await vault.convertToAssets(shares), assets);
    });

    it("honours an allowance when a third party redeems", async function () {
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      const shares = await vault.balanceOf(await alice.getAddress());

      await vault.connect(alice).approve(await bob.getAddress(), shares);
      await vault.connect(bob).redeem(shares, await bob.getAddress(), await alice.getAddress());

      expect(await vault.balanceOf(await alice.getAddress())).to.equal(0);
      expectApprox(await asset.balanceOf(await bob.getAddress()), 1_001_000n * WAD);
    });

    it("reports the deposit ceiling as unlimited while open", async function () {
      expect(await vault.maxDeposit(await alice.getAddress())).to.equal(ethers.MaxUint256);
      expect(await vault.maxMint(await alice.getAddress())).to.equal(ethers.MaxUint256);
    });
  });

  describe("inflation attack", function () {
    async function runDonationAttack(offset: number) {
      const { vault: target } = await deployVault(offset);
      const targetAddress = await target.getAddress();

      await asset.connect(attacker).approve(targetAddress, ethers.MaxUint256);
      await asset.connect(bob).approve(targetAddress, ethers.MaxUint256);

      await target.connect(attacker).deposit(1n, await attacker.getAddress());
      await asset.connect(attacker).transfer(targetAddress, 10_000n * WAD);

      const victimDeposit = 10_000n * WAD;
      await target.connect(bob).deposit(victimDeposit, await bob.getAddress());

      const victimShares = await target.balanceOf(await bob.getAddress());
      return {
        victimShares,
        recoverable: await target.previewRedeem(victimShares),
        victimDeposit,
      };
    }

    it("lets a donation grief the first depositor when the offset is zero", async function () {
      const { victimShares, recoverable, victimDeposit } = await runDonationAttack(0);

      expect(victimShares).to.be.lessThan(10n);
      expect(((victimDeposit - recoverable) * 10_000n) / victimDeposit).to.be.greaterThan(3000n);
    });

    it("neutralises the same donation with a virtual share offset", async function () {
      const { victimShares, recoverable, victimDeposit } = await runDonationAttack(OFFSET);

      expect(victimShares).to.be.greaterThan(10n ** 6n);
      expect(((victimDeposit - recoverable) * 10_000n) / victimDeposit).to.equal(0n);
    });

    it("costs the attacker far more than the victim can be made to lose", async function () {
      const donation = 500_000n * WAD;
      await vault.connect(attacker).deposit(1n, await attacker.getAddress());
      await asset.connect(attacker).transfer(vaultAddress, donation);

      // Only deposits below donation / 10**offset round away entirely.
      expect(await vault.previewDeposit(donation / 10n ** BigInt(OFFSET) / 4n)).to.equal(0);

      const deposit = 100n * WAD;
      await vault.connect(bob).deposit(deposit, await bob.getAddress());
      const recoverable = await vault.previewRedeem(await vault.balanceOf(await bob.getAddress()));

      const victimLoss = deposit - recoverable;
      expect(donation / victimLoss).to.be.greaterThan(1_000_000n);
    });

    it("credits a donation to existing holders rather than losing it", async function () {
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      const shares = await vault.balanceOf(await alice.getAddress());

      await asset.connect(attacker).transfer(vaultAddress, 100n * WAD);

      expect(await vault.totalAssets()).to.equal(1100n * WAD);
      expectApprox(await vault.convertToAssets(shares), 1100n * WAD);
    });
  });

  describe("share ratios under yield and loss", function () {
    beforeEach(async function () {
      await vault.addStrategy(aaveAddress, MAX_BPS);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.connect(bob).deposit(500n * WAD, await bob.getAddress());
      await vault.rebalance();
    });

    it("keeps deposits proportional before any yield", async function () {
      const aliceShares = await vault.balanceOf(await alice.getAddress());
      const bobShares = await vault.balanceOf(await bob.getAddress());

      expect(aliceShares).to.equal(bobShares * 2n);
      expect(await vault.totalAssets()).to.equal(1500n * WAD);
      expect(await aaveStrategy.totalAssets()).to.equal(1500n * WAD);
    });

    it("raises every holder's claim by the same proportion as the yield", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 150n * WAD);

      expect(await vault.totalAssets()).to.equal(1650n * WAD);

      const aliceValue = await vault.convertToAssets(
        await vault.balanceOf(await alice.getAddress())
      );
      const bobValue = await vault.convertToAssets(await vault.balanceOf(await bob.getAddress()));

      expectApprox(aliceValue, 1100n * WAD);
      expectApprox(bobValue, 550n * WAD);
      expectApprox(aliceValue + bobValue, 1650n * WAD);
    });

    it("pays out the accrued yield on redemption", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 150n * WAD);

      const before = await asset.balanceOf(await alice.getAddress());
      await vault
        .connect(alice)
        .redeem(
          await vault.balanceOf(await alice.getAddress()),
          await alice.getAddress(),
          await alice.getAddress()
        );

      expectApprox((await asset.balanceOf(await alice.getAddress())) - before, 1100n * WAD);
    });

    it("leaves the remaining holder's claim untouched when someone exits", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 150n * WAD);

      const bobShares = await vault.balanceOf(await bob.getAddress());
      const bobValueBefore = await vault.convertToAssets(bobShares);

      await vault
        .connect(alice)
        .redeem(
          await vault.balanceOf(await alice.getAddress()),
          await alice.getAddress(),
          await alice.getAddress()
        );

      expectApprox(await vault.convertToAssets(bobShares), bobValueBefore);
    });

    it("passes a loss through proportionally", async function () {
      await pool.simulateLoss(assetAddress, aaveAddress, 300n * WAD);

      expect(await vault.totalAssets()).to.equal(1200n * WAD);
      expectApprox(
        await vault.convertToAssets(await vault.balanceOf(await alice.getAddress())),
        800n * WAD
      );
      expectApprox(
        await vault.convertToAssets(await vault.balanceOf(await bob.getAddress())),
        400n * WAD
      );
    });

    it("prices a later deposit at the post-yield rate", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 1500n * WAD);

      const bobSharesBefore = await vault.balanceOf(await bob.getAddress());
      await vault.connect(bob).deposit(1000n * WAD, await bob.getAddress());
      const minted = (await vault.balanceOf(await bob.getAddress())) - bobSharesBefore;

      expectApprox(await vault.convertToAssets(minted), 1000n * WAD);
      expectApprox(
        await vault.convertToAssets(bobSharesBefore),
        1000n * WAD,
        WAD / 1_000_000n
      );
    });
  });

  describe("strategy management", function () {
    it("registers a strategy and reserves its allocation", async function () {
      await expect(vault.addStrategy(aaveAddress, 6000))
        .to.emit(vault, "StrategyAdded")
        .withArgs(aaveAddress, 6000);

      const params = await vault.strategyParams(aaveAddress);
      expect(params.active).to.equal(true);
      expect(params.targetBps).to.equal(6000);
      expect(await vault.totalTargetBps()).to.equal(6000);
      expect(await vault.strategyCount()).to.equal(1);
      expect(await vault.strategies()).to.deep.equal([aaveAddress]);
    });

    it("refuses a strategy bound to another asset or vault", async function () {
      const otherAsset = await (
        await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20")
      ).deploy("Other", "OTH", 18);
      await otherAsset.waitForDeployment();

      const wrongAssetFactory = await ethers.getContractFactory(
        "contracts/mocks/MockYieldStrategy.sol:MockYieldStrategy"
      );
      const wrongAsset = await wrongAssetFactory.deploy(
        await otherAsset.getAddress(),
        vaultAddress
      );
      await wrongAsset.waitForDeployment();

      await expect(
        vault.addStrategy(await wrongAsset.getAddress(), 1000)
      ).to.be.revertedWithCustomError(vault, "AssetMismatch");

      const wrongVault = await deployMockStrategy(await alice.getAddress());
      await expect(
        vault.addStrategy(await wrongVault.getAddress(), 1000)
      ).to.be.revertedWithCustomError(vault, "VaultMismatch");
    });

    it("rejects duplicates, zero addresses and over-allocation", async function () {
      await vault.addStrategy(aaveAddress, 6000);

      await expect(vault.addStrategy(aaveAddress, 1000))
        .to.be.revertedWithCustomError(vault, "StrategyAlreadyRegistered")
        .withArgs(aaveAddress);

      await expect(vault.addStrategy(ethers.ZeroAddress, 1000)).to.be.revertedWithCustomError(
        vault,
        "ZeroAddress"
      );

      const second = await deployMockStrategy(vaultAddress);
      await expect(vault.addStrategy(await second.getAddress(), 5000))
        .to.be.revertedWithCustomError(vault, "AllocationExceeded")
        .withArgs(11000, MAX_BPS);
    });

    it("caps the number of registered strategies", async function () {
      const limit = Number(await vault.MAX_STRATEGIES());
      for (let i = 0; i < limit; i++) {
        const strategy = await deployMockStrategy(vaultAddress);
        await vault.addStrategy(await strategy.getAddress(), 0);
      }

      const overflow = await deployMockStrategy(vaultAddress);
      await expect(
        vault.addStrategy(await overflow.getAddress(), 0)
      ).to.be.revertedWithCustomError(vault, "StrategyLimitReached");
    });

    it("updates an allocation without moving capital", async function () {
      await vault.addStrategy(aaveAddress, 6000);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();

      await expect(vault.setAllocation(aaveAddress, 3000))
        .to.emit(vault, "StrategyAllocationUpdated")
        .withArgs(aaveAddress, 6000, 3000);

      expect(await vault.totalTargetBps()).to.equal(3000);
      expect(await aaveStrategy.totalAssets()).to.equal(600n * WAD);

      await vault.rebalance();
      expect(await aaveStrategy.totalAssets()).to.equal(300n * WAD);
    });

    it("splits capital across strategies by weight", async function () {
      const second = await deployMockStrategy(vaultAddress);
      await vault.addStrategy(aaveAddress, 7000);
      await vault.addStrategy(await second.getAddress(), 2000);

      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();

      expect(await aaveStrategy.totalAssets()).to.equal(700n * WAD);
      expect(await second.totalAssets()).to.equal(200n * WAD);
      expect(await asset.balanceOf(vaultAddress)).to.equal(100n * WAD);
      expect(await vault.totalAssets()).to.equal(1000n * WAD);
    });

    it("returns everything to the vault when a strategy is retired", async function () {
      await vault.addStrategy(aaveAddress, MAX_BPS);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();

      await expect(vault.removeStrategy(aaveAddress))
        .to.emit(vault, "StrategyRemoved")
        .withArgs(aaveAddress, 1000n * WAD);

      expect(await vault.strategyCount()).to.equal(0);
      expect(await vault.totalTargetBps()).to.equal(0);
      expect(await vault.totalAssets()).to.equal(1000n * WAD);
      expect(await asset.balanceOf(vaultAddress)).to.equal(1000n * WAD);
    });

    it("restricts strategy management to governance", async function () {
      await expect(
        vault.connect(alice).addStrategy(aaveAddress, 1000)
      ).to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");

      await vault.addStrategy(aaveAddress, 1000);

      await expect(
        vault.connect(alice).setAllocation(aaveAddress, 2000)
      ).to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
      await expect(
        vault.connect(alice).removeStrategy(aaveAddress)
      ).to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
    });

    it("rejects operations on an unregistered strategy", async function () {
      await expect(vault.setAllocation(aaveAddress, 1000))
        .to.be.revertedWithCustomError(vault, "StrategyNotRegistered")
        .withArgs(aaveAddress);
      await expect(vault.removeStrategy(aaveAddress)).to.be.revertedWithCustomError(
        vault,
        "StrategyNotRegistered"
      );
      await expect(vault.harvest(aaveAddress)).to.be.revertedWithCustomError(
        vault,
        "StrategyNotRegistered"
      );
    });
  });

  describe("harvesting", function () {
    beforeEach(async function () {
      await vault.addStrategy(aaveAddress, MAX_BPS);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();
    });

    it("books accrued yield as a gain against the committed principal", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 80n * WAD);

      await expect(vault.harvest(aaveAddress))
        .to.emit(vault, "StrategyReported")
        .withArgs(aaveAddress, 80n * WAD, 0, 1080n * WAD);

      expect((await vault.strategyParams(aaveAddress)).principal).to.equal(1080n * WAD);
    });

    it("books a shortfall as a loss", async function () {
      await pool.simulateLoss(assetAddress, aaveAddress, 120n * WAD);

      await expect(vault.harvest(aaveAddress))
        .to.emit(vault, "StrategyReported")
        .withArgs(aaveAddress, 0, 120n * WAD, 880n * WAD);
    });

    it("counts yield in the share price before it is ever harvested", async function () {
      const valueBefore = await vault.convertToAssets(
        await vault.balanceOf(await alice.getAddress())
      );

      await pool.simulateYield(assetAddress, aaveAddress, 80n * WAD);

      const valueAfter = await vault.convertToAssets(
        await vault.balanceOf(await alice.getAddress())
      );
      expect(valueAfter).to.be.greaterThan(valueBefore);
      expectApprox(valueAfter, 1080n * WAD);
    });

    it("compounds loose asset back into the market and redeploys idle capital", async function () {
      await asset.connect(attacker).transfer(aaveAddress, 50n * WAD);
      await asset.connect(attacker).transfer(vaultAddress, 25n * WAD);

      await vault.harvestAll();

      expect(await aToken.balanceOf(aaveAddress)).to.equal(1075n * WAD);
      expect(await asset.balanceOf(aaveAddress)).to.equal(0);
      expect(await asset.balanceOf(vaultAddress)).to.equal(0);
      expect(await vault.totalAssets()).to.equal(1075n * WAD);
    });

    it("restricts the harvest cycle to keepers", async function () {
      await expect(vault.connect(alice).harvest(aaveAddress)).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );
      await expect(vault.connect(alice).harvestAll()).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );
      await expect(vault.connect(alice).rebalance()).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );

      await vault.grantRole(await vault.KEEPER_ROLE(), await keeper.getAddress());
      await vault.connect(keeper).harvestAll();
    });
  });

  describe("strategy migration", function () {
    let replacement: any;
    let replacementAddress: string;

    beforeEach(async function () {
      await vault.addStrategy(aaveAddress, 8000);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();

      replacement = await deployMockStrategy(vaultAddress);
      replacementAddress = await replacement.getAddress();
    });

    it("moves capital and allocation to the replacement in one transaction", async function () {
      await expect(vault.migrateStrategy(aaveAddress, replacementAddress))
        .to.emit(vault, "StrategyMigrated")
        .withArgs(aaveAddress, replacementAddress, 800n * WAD);

      expect(await aaveStrategy.totalAssets()).to.equal(0);
      expect(await replacement.totalAssets()).to.equal(800n * WAD);
      expect(await vault.totalAssets()).to.equal(1000n * WAD);

      const params = await vault.strategyParams(replacementAddress);
      expect(params.active).to.equal(true);
      expect(params.targetBps).to.equal(8000);
      expect(params.principal).to.equal(800n * WAD);

      expect((await vault.strategyParams(aaveAddress)).active).to.equal(false);
      expect(await vault.strategies()).to.deep.equal([replacementAddress]);
      expect(await vault.totalTargetBps()).to.equal(8000);
    });

    it("carries accrued yield across the migration", async function () {
      await pool.simulateYield(assetAddress, aaveAddress, 200n * WAD);
      const totalBefore = await vault.totalAssets();

      await vault.migrateStrategy(aaveAddress, replacementAddress);

      expect(await vault.totalAssets()).to.equal(totalBefore);
      expect(await replacement.totalAssets()).to.equal(1000n * WAD);
    });

    it("leaves user funds withdrawable throughout", async function () {
      const valueBefore = await vault.convertToAssets(
        await vault.balanceOf(await alice.getAddress())
      );

      await vault.migrateStrategy(aaveAddress, replacementAddress);

      expectApprox(
        await vault.convertToAssets(await vault.balanceOf(await alice.getAddress())),
        valueBefore
      );

      const before = await asset.balanceOf(await alice.getAddress());
      await vault
        .connect(alice)
        .redeem(
          await vault.balanceOf(await alice.getAddress()),
          await alice.getAddress(),
          await alice.getAddress()
        );

      expectApprox((await asset.balanceOf(await alice.getAddress())) - before, 1000n * WAD);
    });

    it("refuses to migrate when the old strategy cannot fully exit", async function () {
      const stuck = await deployMockStrategy(vaultAddress);
      await vault.setAllocation(aaveAddress, 0);
      await vault.addStrategy(await stuck.getAddress(), 5000);
      await vault.rebalance();
      await stuck.setLockedAssets(100n * WAD);

      const target = await deployMockStrategy(vaultAddress);
      await expect(vault.migrateStrategy(await stuck.getAddress(), await target.getAddress()))
        .to.be.revertedWithCustomError(vault, "IncompleteExit")
        .withArgs(await stuck.getAddress(), 100n * WAD);
    });

    it("validates the replacement before committing", async function () {
      await expect(
        vault.migrateStrategy(aaveAddress, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, "ZeroAddress");

      const foreign = await deployMockStrategy(await alice.getAddress());
      await expect(
        vault.migrateStrategy(aaveAddress, await foreign.getAddress())
      ).to.be.revertedWithCustomError(vault, "VaultMismatch");

      await vault.addStrategy(replacementAddress, 1000);
      await expect(
        vault.migrateStrategy(aaveAddress, replacementAddress)
      ).to.be.revertedWithCustomError(vault, "StrategyAlreadyRegistered");
    });

    it("restricts migration to governance", async function () {
      await expect(
        vault.connect(alice).migrateStrategy(aaveAddress, replacementAddress)
      ).to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
    });
  });

  describe("withdrawals against deployed capital", function () {
    beforeEach(async function () {
      await vault.addStrategy(aaveAddress, MAX_BPS);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();
    });

    it("pulls from the strategies when the idle buffer is short", async function () {
      expect(await asset.balanceOf(vaultAddress)).to.equal(0);

      const before = await asset.balanceOf(await alice.getAddress());
      await vault
        .connect(alice)
        .withdraw(600n * WAD, await alice.getAddress(), await alice.getAddress());

      expect((await asset.balanceOf(await alice.getAddress())) - before).to.equal(600n * WAD);
      expect(await aaveStrategy.totalAssets()).to.equal(400n * WAD);
      expect((await vault.strategyParams(aaveAddress)).principal).to.equal(400n * WAD);
    });

    it("caps maxWithdraw at what the strategies can actually release", async function () {
      await pool.drainLiquidity(assetAddress, 700n * WAD);

      expect(await vault.liquidAssets()).to.equal(300n * WAD);
      expect(await vault.maxWithdraw(await alice.getAddress())).to.equal(300n * WAD);

      await expect(
        vault.connect(alice).withdraw(400n * WAD, await alice.getAddress(), await alice.getAddress())
      ).to.be.revertedWithCustomError(vault, "ERC4626ExceededMaxWithdraw");

      await vault
        .connect(alice)
        .withdraw(300n * WAD, await alice.getAddress(), await alice.getAddress());
    });

    it("reverts instead of half-paying when a strategy overstates its liquidity", async function () {
      const liar = await deployMockStrategy(vaultAddress);
      await vault.setAllocation(aaveAddress, 0);
      await vault.addStrategy(await liar.getAddress(), MAX_BPS);
      await vault.rebalance();

      await liar.setLockedAssets(400n * WAD);
      await liar.setOverstatesLiquidity(true);

      expect(await vault.maxWithdraw(await alice.getAddress())).to.equal(1000n * WAD);

      await expect(
        vault
          .connect(alice)
          .withdraw(1000n * WAD, await alice.getAddress(), await alice.getAddress())
      )
        .to.be.revertedWithCustomError(vault, "InsufficientLiquidity")
        .withArgs(1000n * WAD, 600n * WAD);
    });

    it("caps maxRedeem in share terms", async function () {
      await pool.drainLiquidity(assetAddress, 700n * WAD);

      const shares = await vault.balanceOf(await alice.getAddress());
      const capped = await vault.maxRedeem(await alice.getAddress());

      expect(capped).to.be.lessThan(shares);
      expectApprox(await vault.convertToAssets(capped), 300n * WAD);
    });
  });

  describe("pausing", function () {
    beforeEach(async function () {
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.pause();
    });

    it("closes deposits and reports a zero ceiling", async function () {
      expect(await vault.maxDeposit(await alice.getAddress())).to.equal(0);
      expect(await vault.maxMint(await alice.getAddress())).to.equal(0);

      await expect(
        vault.connect(alice).deposit(1n * WAD, await alice.getAddress())
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
      await expect(
        vault.connect(alice).mint(1n * WAD, await alice.getAddress())
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });

    it("closes withdrawals and redemptions and reports a zero ceiling", async function () {
      expect(await vault.maxWithdraw(await alice.getAddress())).to.equal(0);
      expect(await vault.maxRedeem(await alice.getAddress())).to.equal(0);
      await expect(
        vault
          .connect(alice)
          .withdraw(500n * WAD, await alice.getAddress(), await alice.getAddress())
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
      await expect(
        vault
          .connect(alice)
          .redeem(500n * WAD, await alice.getAddress(), await alice.getAddress())
      ).to.be.revertedWithCustomError(vault, "EnforcedPause");
    });
    it("reopens withdrawals after unpause", async function () {
      await vault.unpause();
      const before = await asset.balanceOf(await alice.getAddress());
      await vault
        .connect(alice)
        .withdraw(500n * WAD, await alice.getAddress(), await alice.getAddress());
      expect((await asset.balanceOf(await alice.getAddress())) - before).to.equal(500n * WAD);
    });

    it("reopens on unpause and is governance gated", async function () {
      await expect(vault.connect(alice).unpause()).to.be.revertedWithCustomError(
        vault,
        "AccessControlUnauthorizedAccount"
      );

      await vault.unpause();
      await vault.connect(alice).deposit(1n * WAD, await alice.getAddress());
    });
  });

  describe("upgrades", function () {
    let upgradeHelper: any;

    beforeEach(async function () {
      // Deploy a helper contract so upgrade calls come from a contract (multi-sig),
      // not an EOA – matching the production Gnosis Safe flow.
      const helperFactory = await ethers.getContractFactory(
        "contracts/mocks/UpgradeHelper.sol:UpgradeHelper"
      );
      upgradeHelper = await helperFactory.deploy();
      await upgradeHelper.waitForDeployment();

      // Grant the helper the admin role so it can execute upgrades.
      await vault.grantRole(
        await vault.DEFAULT_ADMIN_ROLE(),
        await upgradeHelper.getAddress()
      );
    });

    it("preserves vault state across an implementation swap", async function () {
      await vault.addStrategy(aaveAddress, MAX_BPS);
      await vault.connect(alice).deposit(1000n * WAD, await alice.getAddress());
      await vault.rebalance();

      const sharesBefore = await vault.balanceOf(await alice.getAddress());

      const factory = await ethers.getContractFactory(
        "contracts/vaults/WhiteLotusERC4626.sol:WhiteLotusERC4626"
      );
      const next = await factory.deploy();
      await next.waitForDeployment();

      await upgradeHelper.executeUpgradeTo(vaultAddress, await next.getAddress(), "0x");

      expect(await vault.balanceOf(await alice.getAddress())).to.equal(sharesBefore);
      expect(await vault.totalAssets()).to.equal(1000n * WAD);
      expect(await vault.strategies()).to.deep.equal([aaveAddress]);
      expect(await vault.decimals()).to.equal(18 + OFFSET);
    });

    it("reverts when an EOA calls upgradeToAndCall directly", async function () {
      const factory = await ethers.getContractFactory(
        "contracts/vaults/WhiteLotusERC4626.sol:WhiteLotusERC4626"
      );
      const next = await factory.deploy();
      await next.waitForDeployment();

      // Even though governance has DEFAULT_ADMIN_ROLE, the EOA check blocks it.
      await expect(
        vault.upgradeToAndCall(await next.getAddress(), "0x")
      ).to.be.revertedWithCustomError(vault, "EOAUpgradeNotAllowed");
    });

    it("restricts upgrades to the admin role", async function () {
      const factory = await ethers.getContractFactory(
        "contracts/vaults/WhiteLotusERC4626.sol:WhiteLotusERC4626"
      );
      const next = await factory.deploy();
      await next.waitForDeployment();

      // alice does not have DEFAULT_ADMIN_ROLE
      await expect(
        vault.connect(alice).upgradeToAndCall(await next.getAddress(), "0x")
      ).to.be.revertedWithCustomError(vault, "AccessControlUnauthorizedAccount");
    });
  });

  describe("strategy access control", function () {
    it("only lets the vault move capital", async function () {
      await expect(aaveStrategy.connect(alice).deposit(1n)).to.be.revertedWithCustomError(
        aaveStrategy,
        "NotVault"
      );
      await expect(aaveStrategy.connect(alice).withdraw(1n)).to.be.revertedWithCustomError(
        aaveStrategy,
        "NotVault"
      );
      await expect(aaveStrategy.connect(alice).withdrawAll()).to.be.revertedWithCustomError(
        aaveStrategy,
        "NotVault"
      );
      await expect(aaveStrategy.connect(alice).harvest()).to.be.revertedWithCustomError(
        aaveStrategy,
        "NotVault"
      );
    });

    it("reports the pair it is bound to", async function () {
      expect(await aaveStrategy.asset()).to.equal(assetAddress);
      expect(await aaveStrategy.vault()).to.equal(vaultAddress);
    });
  });
});
