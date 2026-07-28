import { expect } from "chai";
import hre from "hardhat";

describe("MerkleAirdrop", function () {
  let ethers: any;
  let mockToken: any;
  let merkleAirdrop: any;
  let owner: any;
  let addr1: any;
  let addr2: any;
  let addr3: any;
  let addr4: any;
  let claimers: { index: number; account: string; amount: bigint }[];
  let leaves: string[];
  let root: string;
  let proofs: string[][];

  // Helper function to hash a leaf using solidityPackedKeccak256
  function hashLeaf(index: number, account: string, amount: bigint): string {
    return ethers.solidityPackedKeccak256(
      ["uint256", "address", "uint256"],
      [index, account, amount]
    );
  }

  // Helper to hash a pair of sorted hashes
  function hashPair(a: string, b: string): string {
    return a.toLowerCase() < b.toLowerCase()
      ? ethers.keccak256(ethers.concat([a, b]))
      : ethers.keccak256(ethers.concat([b, a]));
  }

  beforeEach(async function () {
    const connection = await hre.network.create();
    ethers = connection.ethers;
    [owner, addr1, addr2, addr3, addr4] = await ethers.getSigners();

    // Deploy a Mock ERC20 Token (using a simple mock from contracts/mocks if available, or deploying a new one)
    // Let's check if MockERC20 is available.
    const MockERC20Factory = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    mockToken = await MockERC20Factory.deploy("Mock Token", "MTK", 18);
    await mockToken.waitForDeployment();

    const addr1Address = await addr1.getAddress();
    const addr2Address = await addr2.getAddress();
    const addr3Address = await addr3.getAddress();
    const addr4Address = await addr4.getAddress();

    // Set up the claimers data
    claimers = [
      { index: 0, account: addr1Address, amount: ethers.parseEther("100") },
      { index: 1, account: addr2Address, amount: ethers.parseEther("200") },
      { index: 2, account: addr3Address, amount: ethers.parseEther("300") },
      { index: 3, account: addr4Address, amount: ethers.parseEther("400") },
    ];

    // Compute leaves
    leaves = claimers.map((c) => hashLeaf(c.index, c.account, c.amount));

    // Construct the Merkle Tree of 4 elements
    // Layer 0: L0, L1, L2, L3
    // Layer 1: H01, H23
    // Layer 2: Root
    const H01 = hashPair(leaves[0], leaves[1]);
    const H23 = hashPair(leaves[2], leaves[3]);
    root = hashPair(H01, H23);

    // Compute proofs
    proofs = [
      [leaves[1], H23], // Proof for L0
      [leaves[0], H23], // Proof for L1
      [leaves[3], H01], // Proof for L2
      [leaves[2], H01], // Proof for L3
    ];

    // Deploy MerkleAirdrop
    const MerkleAirdropFactory = await ethers.getContractFactory("MerkleAirdrop");
    merkleAirdrop = await MerkleAirdropFactory.deploy(
      await mockToken.getAddress(),
      root
    );
    await merkleAirdrop.waitForDeployment();

    // Mint tokens to MerkleAirdrop contract
    const totalAirdropAmount = ethers.parseEther("1000");
    await mockToken.mint(await merkleAirdrop.getAddress(), totalAirdropAmount);
  });

  it("should deploy successfully and set correct parameters", async function () {
    expect(await merkleAirdrop.token()).to.equal(await mockToken.getAddress());
    expect(await merkleAirdrop.merkleRoot()).to.equal(root);
  });

  it("should allow a valid claim and transfer the correct amount of tokens", async function () {
    const claimer = claimers[0];
    const proof = proofs[0];

    const initialBalance = await mockToken.balanceOf(claimer.account);

    // Execute claim
    await expect(
      merkleAirdrop.claim(claimer.index, claimer.account, claimer.amount, proof)
    )
      .to.emit(merkleAirdrop, "Claimed")
      .withArgs(claimer.index, claimer.account, claimer.amount);

    // Check balance after claim
    const finalBalance = await mockToken.balanceOf(claimer.account);
    expect(finalBalance - initialBalance).to.equal(claimer.amount);

    // Verify claimed status in bitmap
    expect(await merkleAirdrop.isClaimed(claimer.index)).to.be.true;
  });

  it("should prevent double-claiming", async function () {
    const claimer = claimers[1];
    const proof = proofs[1];

    // Claim first time
    await merkleAirdrop.claim(claimer.index, claimer.account, claimer.amount, proof);
    expect(await merkleAirdrop.isClaimed(claimer.index)).to.be.true;

    // Claim second time should revert
    await expect(
      merkleAirdrop.claim(claimer.index, claimer.account, claimer.amount, proof)
    ).to.be.revertedWithCustomError(merkleAirdrop, "AlreadyClaimed");
  });

  it("should revert if an invalid/modified proof is supplied", async function () {
    const claimer = claimers[0];
    const badProof = [leaves[2], leaves[3]]; // Invalid proof for L0

    await expect(
      merkleAirdrop.claim(claimer.index, claimer.account, claimer.amount, badProof)
    ).to.be.revertedWithCustomError(merkleAirdrop, "InvalidProof");
  });

  it("should revert if user attempts to claim with a modified amount", async function () {
    const claimer = claimers[0];
    const proof = proofs[0];
    const modifiedAmount = claimer.amount + 1n;

    await expect(
      merkleAirdrop.claim(claimer.index, claimer.account, modifiedAmount, proof)
    ).to.be.revertedWithCustomError(merkleAirdrop, "InvalidProof");
  });
});
