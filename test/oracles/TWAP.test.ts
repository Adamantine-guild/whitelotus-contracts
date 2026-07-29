import { expect } from "chai";
import hre from "hardhat";

const WAD = 10n ** 18n;
const TARGET_WINDOW = 1800;
const MAX_GAP = 3600;
const INTERVAL = 60;

const TOKEN_A = "0x1111111111111111111111111111111111111111";
const TOKEN_B = "0x2222222222222222222222222222222222222222";
const TOKEN_C = "0x3333333333333333333333333333333333333333";

/// Reference implementation of the contract's Q64.64 binary logarithm, used to assert on raw
/// accumulator values.
function log2Q64(x: bigint): bigint {
  const msb = BigInt(x.toString(2).length - 1);
  let result = msb << 64n;
  let mantissa = msb >= 126n ? x >> (msb - 126n) : x << (126n - msb);

  for (let bit = 1n << 63n; bit > 0n; bit >>= 1n) {
    mantissa = (mantissa * mantissa) >> 126n;
    if (mantissa >= 1n << 127n) {
      mantissa >>= 1n;
      result |= bit;
    }
  }
  return result;
}

/// Time-weighted geometric mean computed in floating point, independent of the on-chain math.
function geometricMean(segments: { price: bigint; seconds: number }[]): number {
  const total = segments.reduce((sum, s) => sum + s.seconds, 0);
  const weighted = segments.reduce(
    (sum, s) => sum + Math.log(Number(s.price)) * s.seconds,
    0
  );
  return Math.exp(weighted / total);
}

function relativeError(actual: bigint, expected: number): number {
  return Math.abs(Number(actual) - expected) / expected;
}

/// Asserts `actual` is within `1 / tolerance` of `expected`, allowing for the two wei of
/// downward rounding the fixed-point conversions can introduce.
function expectClose(actual: bigint, expected: bigint, tolerance: bigint) {
  const difference = actual > expected ? actual - expected : expected - actual;
  expect(difference).to.be.lessThanOrEqual(expected / tolerance + 2n);
}

const ONE_PART_IN_1E15 = 10n ** 15n;

describe("TWAPOracle", function () {
  let connection: any;
  let ethers: any;
  let owner: any;
  let stranger: any;
  let oracle: any;
  let pool: any;
  let poolAddress: string;
  let start: number;

  async function setNextTimestamp(timestamp: number) {
    await connection.provider.request({
      method: "evm_setNextBlockTimestamp",
      params: ["0x" + timestamp.toString(16)],
    });
  }

  async function mineAt(timestamp: number) {
    await setNextTimestamp(timestamp);
    await connection.provider.request({ method: "evm_mine", params: [] });
  }

  /// Reserves of (1 WAD, price) make the pool's spot price exactly `price`.
  async function setPriceAt(timestamp: number, price: bigint) {
    await setNextTimestamp(timestamp);
    return (await pool.sync(WAD, price)).wait();
  }

  async function deployOracle(targetWindow: number, maxGap: number) {
    const factory = await ethers.getContractFactory(
      "contracts/oracles/TWAPOracle.sol:TWAPOracle"
    );
    const deployed = await factory.deploy(targetWindow, maxGap, await owner.getAddress());
    await deployed.waitForDeployment();
    return deployed;
  }

  async function deployPool(target: any, token0: string, token1: string) {
    const factory = await ethers.getContractFactory(
      "contracts/mocks/MockAMMPool.sol:MockAMMPool"
    );
    const deployed = await factory.deploy(await target.getAddress(), token0, token1);
    await deployed.waitForDeployment();
    await target.registerPool(await deployed.getAddress(), token0, token1);
    return deployed;
  }

  beforeEach(async function () {
    connection = await hre.network.create();
    ethers = connection.ethers;
    [owner, stranger] = await ethers.getSigners();

    oracle = await deployOracle(TARGET_WINDOW, MAX_GAP);
    pool = await deployPool(oracle, TOKEN_A, TOKEN_B);
    poolAddress = await pool.getAddress();

    const latest = await ethers.provider.getBlock("latest");
    start = latest.timestamp + 100;
  });

  describe("configuration", function () {
    it("stores the window and gap supplied at deployment", async function () {
      expect(await oracle.targetWindow()).to.equal(TARGET_WINDOW);
      expect(await oracle.maxObservationGap()).to.equal(MAX_GAP);
      expect(await oracle.owner()).to.equal(await owner.getAddress());
    });

    it("rejects a zero window or a zero gap", async function () {
      await expect(deployOracle(0, MAX_GAP)).to.be.revertedWithCustomError(
        oracle,
        "InvalidConfig"
      );
      await expect(deployOracle(TARGET_WINDOW, 0)).to.be.revertedWithCustomError(
        oracle,
        "InvalidConfig"
      );
    });

    it("lets the owner update the configuration", async function () {
      await expect(oracle.setConfig(900, 1200))
        .to.emit(oracle, "ConfigUpdated")
        .withArgs(900, 1200);

      expect(await oracle.targetWindow()).to.equal(900);
      expect(await oracle.maxObservationGap()).to.equal(1200);
    });

    it("rejects configuration changes from anyone else", async function () {
      await expect(
        oracle.connect(stranger).setConfig(900, 1200)
      ).to.be.revertedWithCustomError(oracle, "OwnableUnauthorizedAccount");
    });
  });

  describe("pool registration", function () {
    it("binds a pool to the pair it prices", async function () {
      const state = await oracle.pools(poolAddress);
      expect(state.token0).to.equal(TOKEN_A);
      expect(state.token1).to.equal(TOKEN_B);
      expect(state.registered).to.equal(true);
      expect(state.cardinality).to.equal(0);
    });

    it("emits on registration", async function () {
      const factory = await ethers.getContractFactory(
        "contracts/mocks/MockAMMPool.sol:MockAMMPool"
      );
      const fresh = await factory.deploy(await oracle.getAddress(), TOKEN_A, TOKEN_C);
      await fresh.waitForDeployment();

      await expect(oracle.registerPool(await fresh.getAddress(), TOKEN_A, TOKEN_C))
        .to.emit(oracle, "PoolRegistered")
        .withArgs(await fresh.getAddress(), TOKEN_A, TOKEN_C);
    });

    it("rejects invalid or duplicate registrations", async function () {
      await expect(
        oracle.registerPool(ethers.ZeroAddress, TOKEN_A, TOKEN_B)
      ).to.be.revertedWithCustomError(oracle, "ZeroAddress");

      await expect(
        oracle.registerPool(TOKEN_C, TOKEN_A, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(oracle, "ZeroAddress");

      await expect(
        oracle.registerPool(TOKEN_C, TOKEN_A, TOKEN_A)
      ).to.be.revertedWithCustomError(oracle, "IdenticalTokens");

      await expect(oracle.registerPool(poolAddress, TOKEN_A, TOKEN_B))
        .to.be.revertedWithCustomError(oracle, "PoolAlreadyRegistered")
        .withArgs(poolAddress);
    });

    it("rejects registration from anyone but the owner", async function () {
      await expect(
        oracle.connect(stranger).registerPool(TOKEN_C, TOKEN_A, TOKEN_B)
      ).to.be.revertedWithCustomError(oracle, "OwnableUnauthorizedAccount");
    });

    it("refuses checkpoints from an unregistered caller", async function () {
      await expect(oracle.connect(stranger).record(WAD))
        .to.be.revertedWithCustomError(oracle, "PoolNotRegistered")
        .withArgs(await stranger.getAddress());
    });
  });

  describe("checkpoint recording", function () {
    it("seeds the buffer with a zeroed checkpoint", async function () {
      await setPriceAt(start, 2000n * WAD);

      const state = await oracle.pools(poolAddress);
      expect(state.cardinality).to.equal(1);
      expect(state.index).to.equal(0);
      expect(state.logPriceLast).to.equal(log2Q64(2000n * WAD));

      const observation = await oracle.getObservation(poolAddress, 0);
      expect(observation.blockTimestamp).to.equal(start);
      expect(observation.logPriceCumulative).to.equal(0);
      expect(observation.initialized).to.equal(true);
    });

    it("weights each price by the time it was held", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 300, 3000n * WAD);
      await setPriceAt(start + 800, 1500n * WAD);

      const second = await oracle.getObservation(poolAddress, 1);
      expect(second.blockTimestamp).to.equal(start + 300);
      expect(second.logPriceCumulative).to.equal(log2Q64(2000n * WAD) * 300n);

      const third = await oracle.getObservation(poolAddress, 2);
      expect(third.blockTimestamp).to.equal(start + 800);
      expect(third.logPriceCumulative).to.equal(
        log2Q64(2000n * WAD) * 300n + log2Q64(3000n * WAD) * 500n
      );
    });

    it("does not checkpoint twice in the same block", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 300, 2000n * WAD);

      const before = await oracle.pools(poolAddress);

      await setNextTimestamp(start + 600);
      await (await pool.flashManipulate(WAD, 500_000n * WAD)).wait();

      const after = await oracle.pools(poolAddress);
      expect(after.index).to.equal(before.index + 1n);
      expect(after.logPriceLast).to.equal(log2Q64(2000n * WAD));
    });

    it("rejects a zero price", async function () {
      await setNextTimestamp(start);
      await expect(pool.sync(WAD, 0n)).to.be.revertedWithCustomError(
        oracle,
        "InvalidPrice"
      );
    });
  });

  describe("manipulation resistance", function () {
    async function buildStableHistory(price: bigint) {
      for (let i = 0; i <= TARGET_WINDOW / INTERVAL; i++) {
        await setPriceAt(start + i * INTERVAL, price);
      }
    }

    it("ignores a spike created and unwound inside a single block", async function () {
      const price = 2000n * WAD;
      await buildStableHistory(price);

      const spiked = 200_000n * WAD;
      await setNextTimestamp(start + TARGET_WINDOW + INTERVAL);
      await expect(pool.flashManipulate(WAD, spiked))
        .to.emit(oracle, "PriceRecorded")
        .withArgs(poolAddress, start + TARGET_WINDOW + INTERVAL, spiked, (v: bigint) => v > 0n);

      expect(await pool.spotPrice()).to.equal(price);

      expectClose(
        await oracle.consult(poolAddress, TARGET_WINDOW),
        price,
        ONE_PART_IN_1E15
      );
    });

    it("caps the influence of a spike at its share of the window", async function () {
      const price = 2000n * WAD;
      const spiked = 200_000n * WAD;
      await buildStableHistory(price);

      const spikeAt = start + TARGET_WINDOW + INTERVAL;
      await setPriceAt(spikeAt, spiked);
      await mineAt(spikeAt + 12);

      const twap = await oracle.consult(poolAddress, TARGET_WINDOW);
      const expected = geometricMean([
        { price, seconds: TARGET_WINDOW - 12 },
        { price: spiked, seconds: 12 },
      ]);

      expect(relativeError(twap, expected)).to.be.lessThan(1e-12);

      const drift = Number(twap) / Number(price) - 1;
      expect(drift).to.be.greaterThan(0.03);
      expect(drift).to.be.lessThan(0.032);
    });

    it("tracks a repricing once it has held for the whole window", async function () {
      const price = 2000n * WAD;
      const repriced = 3200n * WAD;
      await buildStableHistory(price);

      const repricedAt = start + TARGET_WINDOW + INTERVAL;
      await setPriceAt(repricedAt, repriced);
      for (let i = 1; i <= TARGET_WINDOW / INTERVAL; i++) {
        await setPriceAt(repricedAt + i * INTERVAL, repriced);
      }

      expectClose(
        await oracle.consult(poolAddress, TARGET_WINDOW),
        repriced,
        ONE_PART_IN_1E15
      );
    });

    it("dilutes a spike driven through the constant-product curve", async function () {
      const reserve0 = 1000n * WAD;
      const reserve1 = 2_000_000n * WAD;

      await setNextTimestamp(start);
      await (await pool.sync(reserve0, reserve1)).wait();
      const spot = await pool.spotPrice();

      for (let i = 1; i <= TARGET_WINDOW / INTERVAL; i++) {
        await setNextTimestamp(start + i * INTERVAL);
        await (await pool.poke()).wait();
      }

      await setNextTimestamp(start + TARGET_WINDOW + INTERVAL);
      await (await pool.swap1For0(18_000_000n * WAD)).wait();
      expect(await pool.spotPrice()).to.be.greaterThan(spot * 9n);

      expectClose(
        await oracle.consult(poolAddress, TARGET_WINDOW),
        spot,
        ONE_PART_IN_1E15
      );
    });
  });

  describe("price accuracy", function () {
    it("reproduces a constant price across many orders of magnitude", async function () {
      const prices = [10n ** 12n, WAD, 2000n * WAD, 10n ** 24n, 10n ** 30n];

      for (const [i, price] of prices.entries()) {
        const base = start + i * 4000;
        await setPriceAt(base, price);
        await setPriceAt(base + 900, price);
        await mineAt(base + TARGET_WINDOW);

        expectClose(
          await oracle.consult(poolAddress, TARGET_WINDOW),
          price,
          ONE_PART_IN_1E15
        );
      }
    });

    it("returns the geometric mean, not the arithmetic mean", async function () {
      await setPriceAt(start, 1000n * WAD);
      await setPriceAt(start + TARGET_WINDOW / 2, 4000n * WAD);
      await mineAt(start + TARGET_WINDOW);

      const twap = await oracle.consult(poolAddress, TARGET_WINDOW);

      expect(relativeError(twap, 2000e18)).to.be.lessThan(1e-15);
      expect(relativeError(twap, 2500e18)).to.be.greaterThan(0.19);
    });

    it("stays accurate across irregular block durations", async function () {
      const segments = [
        { price: 1500n * WAD, seconds: 137 },
        { price: 1812n * WAD, seconds: 421 },
        { price: 903n * WAD, seconds: 89 },
        { price: 3040n * WAD, seconds: 1153 },
      ];

      let cursor = start;
      for (const segment of segments) {
        await setPriceAt(cursor, segment.price);
        cursor += segment.seconds;
      }
      await mineAt(cursor);

      const twap = await oracle.consult(poolAddress, TARGET_WINDOW);
      expect(relativeError(twap, geometricMean(segments))).to.be.lessThan(1e-12);
    });

    it("is symmetric under inversion of the pair", async function () {
      await setPriceAt(start, 1000n * WAD);
      await setPriceAt(start + TARGET_WINDOW / 2, 4000n * WAD);
      await mineAt(start + TARGET_WINDOW);

      const forward = await oracle.quote(poolAddress, TOKEN_A, WAD, TARGET_WINDOW);
      const backward = await oracle.quote(poolAddress, TOKEN_B, forward, TARGET_WINDOW);

      expect(relativeError(forward, 2000e18)).to.be.lessThan(1e-15);
      expect(relativeError(backward, 1e18)).to.be.lessThan(1e-15);
    });

    it("rejects a quote for a token outside the pair", async function () {
      await setPriceAt(start, 2000n * WAD);
      await mineAt(start + TARGET_WINDOW);

      await expect(oracle.quote(poolAddress, TOKEN_C, WAD, TARGET_WINDOW))
        .to.be.revertedWithCustomError(oracle, "UnknownToken")
        .withArgs(poolAddress, TOKEN_C);
    });
  });

  describe("historical lookup", function () {
    it("interpolates between the checkpoints surrounding the target", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 5000n * WAD);
      await setPriceAt(start + 1200, 5000n * WAD);
      await mineAt(start + 1500);

      const before = await oracle.getObservation(poolAddress, 1);
      const after = await oracle.getObservation(poolAddress, 2);

      const target = 900n;
      const [value] = await oracle.observe(poolAddress, [1500 - Number(target)]);

      const gap = after.blockTimestamp - before.blockTimestamp;
      const expected =
        before.logPriceCumulative +
        ((after.logPriceCumulative - before.logPriceCumulative) *
          (BigInt(start) + target - before.blockTimestamp)) /
          gap;

      expect(value).to.equal(expected);
    });

    it("extends the newest checkpoint to the current block", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 5000n * WAD);
      await mineAt(start + 900);

      const [value] = await oracle.observe(poolAddress, [0]);
      const newest = await oracle.getObservation(poolAddress, 1);

      expect(value).to.equal(
        newest.logPriceCumulative + log2Q64(5000n * WAD) * 300n
      );
    });

    it("serves several lookback points in one call", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 2000n * WAD);
      await mineAt(start + 900);

      const values = await oracle.observe(poolAddress, [900, 600, 0]);
      expect(values.length).to.equal(3);
      expect(values[0]).to.equal(0);
      expect(values[1]).to.equal(log2Q64(2000n * WAD) * 300n);
      expect(values[2]).to.equal(log2Q64(2000n * WAD) * 900n);
    });
  });

  describe("insufficient and sparse data", function () {
    it("rejects a query against an unregistered pool", async function () {
      await expect(oracle.consult(TOKEN_C, TARGET_WINDOW))
        .to.be.revertedWithCustomError(oracle, "PoolNotRegistered")
        .withArgs(TOKEN_C);
    });

    it("rejects a query before the first checkpoint", async function () {
      await expect(oracle.consult(poolAddress, TARGET_WINDOW))
        .to.be.revertedWithCustomError(oracle, "OracleNotInitialized")
        .withArgs(poolAddress);
    });

    it("rejects a zero-length window", async function () {
      await setPriceAt(start, 2000n * WAD);
      await mineAt(start + 600);

      await expect(oracle.consult(poolAddress, 0))
        .to.be.revertedWithCustomError(oracle, "InvalidWindow")
        .withArgs(0);
    });

    it("rejects a window reaching past the oldest checkpoint", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 2000n * WAD);
      await mineAt(start + 900);

      await expect(oracle.consult(poolAddress, TARGET_WINDOW))
        .to.be.revertedWithCustomError(oracle, "InsufficientHistory")
        .withArgs(poolAddress, 900, TARGET_WINDOW);
    });

    it("rejects a query against a pool that has gone idle", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 2000n * WAD);
      await mineAt(start + 600 + MAX_GAP + 1);

      await expect(oracle.consult(poolAddress, TARGET_WINDOW))
        .to.be.revertedWithCustomError(oracle, "SparseObservations")
        .withArgs(poolAddress, MAX_GAP + 1, MAX_GAP);
    });

    it("reads around slots a cardinality increase has not reached yet", async function () {
      await setPriceAt(start, 2000n * WAD);
      await setPriceAt(start + 600, 2000n * WAD);
      await setPriceAt(start + 1200, 2000n * WAD);
      await mineAt(start + 1500);

      const state = await oracle.pools(poolAddress);
      expect(state.cardinality).to.equal(4);
      expect((await oracle.getObservation(poolAddress, 3)).initialized).to.equal(false);

      expectClose(
        await oracle.consult(poolAddress, 1500),
        2000n * WAD,
        ONE_PART_IN_1E15
      );

      await expect(oracle.consult(poolAddress, 1501))
        .to.be.revertedWithCustomError(oracle, "InsufficientHistory")
        .withArgs(poolAddress, 1500, 1501);
    });

    it("rejects a target falling inside an oversized checkpoint gap", async function () {
      const sparseOracle = await deployOracle(TARGET_WINDOW, 300);
      const sparsePool = await deployPool(sparseOracle, TOKEN_A, TOKEN_B);
      const sparseAddress = await sparsePool.getAddress();

      await setNextTimestamp(start);
      await (await sparsePool.sync(WAD, 2000n * WAD)).wait();
      await setNextTimestamp(start + 1000);
      await (await sparsePool.sync(WAD, 2000n * WAD)).wait();
      await setNextTimestamp(start + 1100);
      await (await sparsePool.sync(WAD, 2000n * WAD)).wait();

      await expect(sparseOracle.consult(sparseAddress, 800))
        .to.be.revertedWithCustomError(sparseOracle, "SparseObservations")
        .withArgs(sparseAddress, 1000, 300);
    });
  });

  describe("observation cardinality", function () {
    async function record(count: number, from = 0) {
      for (let i = from; i < from + count; i++) {
        await setPriceAt(start + i * INTERVAL, 2000n * WAD);
      }
    }

    it("grows the buffer until it spans the target window", async function () {
      await record(80);

      const state = await oracle.pools(poolAddress);
      expect(state.cardinality).to.equal(32);
      expect(state.cardinalityTarget).to.equal(state.cardinality);
      expect(await oracle.observationSpan(poolAddress)).to.be.greaterThanOrEqual(
        TARGET_WINDOW
      );
    });

    it("announces every increase", async function () {
      await setPriceAt(start, 2000n * WAD);
      await expect(setPriceAt(start + INTERVAL, 2000n * WAD))
        .to.emit(oracle, "ObservationCardinalityIncreased")
        .withArgs(poolAddress, 2, 4);
    });

    it("does not grow past what the window needs", async function () {
      await record(40);
      const settled = await oracle.pools(poolAddress);

      await record(40, 40);
      const later = await oracle.pools(poolAddress);

      expect(later.cardinality).to.equal(settled.cardinality);
      expect(later.cardinalityTarget).to.equal(settled.cardinalityTarget);
    });

    it("keeps serving the window after the buffer wraps", async function () {
      await record(80);
      await mineAt(start + 80 * INTERVAL);

      expectClose(
        await oracle.consult(poolAddress, TARGET_WINDOW),
        2000n * WAD,
        ONE_PART_IN_1E15
      );

      await expect(
        oracle.consult(poolAddress, TARGET_WINDOW + 600)
      ).to.be.revertedWithCustomError(oracle, "InsufficientHistory");
    });
  });
});
