import { expect } from "chai";
import hre from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("OmnichainReceiver", function () {
  let receiver: any;
  let mockEndpoint: any;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let ethers: any;

  const srcChainId = 1;
  const mockChainId = 2;
  let srcAddressPath: string;

  beforeEach(async function () {
    const connection = await (hre as any).network.create();
    ethers = connection.ethers;
    [owner, user] = await ethers.getSigners();

    // Deploy Mock Endpoint
    const MockEndpoint = await ethers.getContractFactory("LZEndpointMock");
    mockEndpoint = await MockEndpoint.deploy(mockChainId);
    await mockEndpoint.waitForDeployment();

    // Deploy OmnichainReceiver
    // We assume the contract uses OpenZeppelin Ownable requiring owner address
    const Receiver = await ethers.getContractFactory("OmnichainReceiver");
    try {
        // Attempt to pass both endpoint and owner if constructor requires it
        receiver = await Receiver.deploy(await mockEndpoint.getAddress(), owner.address);
    } catch(e) {
        // Fallback for when NonblockingLzApp uses Ownable without owner param in constructor
        receiver = await Receiver.deploy(await mockEndpoint.getAddress());
    }
    
    await receiver.waitForDeployment();

    // Set trusted remote for srcChainId
    // In LayerZero, path is usually tightly packed srcAddress + dstAddress
    const srcAddress = ethers.zeroPadValue(owner.address, 20);
    const dstAddress = ethers.zeroPadValue(await receiver.getAddress(), 20);
    srcAddressPath = ethers.solidityPacked(["bytes", "bytes"], [srcAddress, dstAddress]);

    await receiver.setTrustedRemote(srcChainId, srcAddressPath);
  });

  it("should revert if called by anyone other than the LZ Endpoint", async function () {
    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256"],
      [user.address, 100]
    );

    // Calling lzReceive directly instead of going through Endpoint should revert
    await expect(
      receiver.lzReceive(srcChainId, srcAddressPath, 1, payload)
    ).to.be.revertedWith("LzApp: invalid endpoint caller");
  });

  it("should successfully decode payload and update state", async function () {
    const amount = 100;
    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256"],
      [user.address, amount]
    );

    // Call through the mock endpoint to simulate successful cross-chain delivery
    await expect(mockEndpoint.receivePayload(
        srcChainId,
        srcAddressPath,
        await receiver.getAddress(),
        1, // nonce
        200000, // gasLimit
        payload
    )).to.emit(receiver, "PayloadReceived").withArgs(srcChainId, srcAddressPath, 1, payload)
      .and.to.emit(receiver, "CollateralMinted").withArgs(user.address, amount);

    const balance = await receiver.syntheticCollateral(user.address);
    expect(balance).to.equal(amount);
  });

  it("should correctly handle failed message execution without reverting entire transaction (non-blocking)", async function () {
    const malformedPayload = ethers.randomBytes(10);
    
    await mockEndpoint.receivePayload(
        srcChainId,
        srcAddressPath,
        await receiver.getAddress(),
        2, 
        200000, 
        malformedPayload
    );

    const payloadHash = ethers.keccak256(malformedPayload);
    const storedHash = await receiver.failedMessages(srcChainId, srcAddressPath, 2);
    expect(storedHash).to.equal(payloadHash);
  });

  it("should enforce replay protection and cache on duplicate nonce", async function () {
    const amount = 50;
    const payload = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "uint256"],
      [user.address, amount]
    );

    await mockEndpoint.receivePayload(
        srcChainId,
        srcAddressPath,
        await receiver.getAddress(),
        3, 
        200000, 
        payload
    );

    // Try receiving the exact same payload and nonce again
    // Replay protection in _nonblockingLzReceive will revert, NonblockingLzApp catches it and stores in failedMessages
    await mockEndpoint.receivePayload(
        srcChainId,
        srcAddressPath,
        await receiver.getAddress(),
        3, 
        200000, 
        payload
    );
    
    const payloadHash = ethers.keccak256(payload);
    const storedHash = await receiver.failedMessages(srcChainId, srcAddressPath, 3);
    expect(storedHash).to.equal(payloadHash);
  });
  it("should successfully transfer ownership during deployment", async function () {
    const Receiver = await ethers.getContractFactory("OmnichainReceiver");
    let testReceiver;
    try {
        testReceiver = await Receiver.deploy(await mockEndpoint.getAddress(), user.address);
    } catch(e) {
        testReceiver = await Receiver.deploy(await mockEndpoint.getAddress());
        await testReceiver.waitForDeployment();
        await testReceiver.transferOwnership(user.address);
        // Two-step ownership (issue #139): the new owner must acceptOwnership()
        // before the transfer finalizes.
        await testReceiver.connect(user).acceptOwnership();
    }
    await testReceiver.waitForDeployment();
    expect(await testReceiver.owner()).to.equal(user.address);
  });

  it("should revert when retrying a persistently failing message", async function () {
    const malformedPayload = ethers.randomBytes(10);
    
    await mockEndpoint.receivePayload(
        srcChainId,
        srcAddressPath,
        await receiver.getAddress(),
        4, 
        200000, 
        malformedPayload
    );

    const storedHash = await receiver.failedMessages(srcChainId, srcAddressPath, 4);
    expect(storedHash).to.equal(ethers.keccak256(malformedPayload));

    // Retrying the malformed payload will revert again inside _nonblockingLzReceive
    let reverted = false;
    try {
        await receiver.retryMessage(srcChainId, srcAddressPath, 4, malformedPayload);
    } catch(e) {
        reverted = true;
    }
    expect(reverted).to.be.true;
  });
});
