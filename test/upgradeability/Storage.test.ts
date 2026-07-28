import { ethers, upgrades } from "hardhat";
import { expect } from "chai";

describe("Storage Collision Upgrades", function () {
  it("should validate BaseLogic upgradeability without storage collisions (Correct Gap Adjustment)", async function () {
    const V1 = await ethers.getContractFactory("MockContractV1");
    const V2_Correct = await ethers.getContractFactory("MockContractV2_Correct");

    // validateUpgrade statically checks the storage layout of V2 relative to V1
    await expect(upgrades.validateUpgrade(V1, V2_Correct)).to.not.be.rejected;
  });

  it("should fail validation if __gap is not properly adjusted (Simulated Collision)", async function () {
    const V1 = await ethers.getContractFactory("MockContractV1");
    const V2_Bad = await ethers.getContractFactory("MockContractV2_Bad");

    // The upgrades plugin should detect that childVar's storage slot was pushed down, causing a collision/layout change.
    await expect(upgrades.validateUpgrade(V1, V2_Bad)).to.be.rejectedWith(/New storage layout is incompatible/);
  });
});

