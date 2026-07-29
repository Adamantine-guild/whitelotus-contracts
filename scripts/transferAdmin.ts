import hre from "hardhat";

/// @notice Transfers proxy admin / ownership of deployed WhiteLotus contracts to a Gnosis Safe.
///
/// Supported contract types:
///   - **Diamond proxy** – transfers `contractOwner` to the Safe via the OwnershipFacet.
///   - **UUPS proxies** (BaseLogic descendants) – transfers `Ownable.owner()` to the Safe.
///   - **WhiteLotusERC4626** (AccessControl-based) – grants `DEFAULT_ADMIN_ROLE` to the
///     Safe and the current admin renounces the role.
///
/// Usage:
///   SAFE_ADDRESS=<gnosis-safe> \
///   DIAMOND_ADDRESS=<diamond-proxy> \
///   ERC4626_PROXY=<vault-proxy> \
///   STAKING_PROXY=<staking-proxy> \
///   npx hardhat run scripts/transferAdmin.ts
///
/// Each contract address is optional – the script skips any that are not provided.

interface TransferTarget {
  label: string;
  address: string;
  type: "diamond" | "ownable" | "access-control";
}

function requiredEnv(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`Missing required env var: ${key}`);
  return value;
}

async function main() {
  const connection = await hre.network.create();
  const ethers = connection.ethers;

  const safeAddress = requiredEnv("SAFE_ADDRESS");
  const [deployer] = await ethers.getSigners();

  console.log("=== Transferring Admin to Gnosis Safe ===");
  console.log("Safe address :", safeAddress);
  console.log("Caller       :", await deployer.getAddress());
  console.log("");

  // ── Build list of targets from env vars ──────────────────────────
  const targets: TransferTarget[] = [];

  if (process.env.DIAMOND_ADDRESS) {
    targets.push({
      label: "Diamond proxy",
      address: process.env.DIAMOND_ADDRESS,
      type: "diamond",
    });
  }
  if (process.env.ERC4626_PROXY) {
    targets.push({
      label: "ERC4626 vault proxy",
      address: process.env.ERC4626_PROXY,
      type: "access-control",
    });
  }
  if (process.env.STAKING_PROXY) {
    targets.push({
      label: "StakingLogic proxy",
      address: process.env.STAKING_PROXY,
      type: "ownable",
    });
  }
  // Generic ownable proxies can be passed as comma-separated list
  if (process.env.OWNABLE_PROXIES) {
    process.env.OWNABLE_PROXIES.split(",")
      .map((a) => a.trim())
      .filter(Boolean)
      .forEach((addr) => {
        targets.push({ label: `Ownable proxy ${addr.slice(0, 10)}…`, address: addr, type: "ownable" });
      });
  }

  if (targets.length === 0) {
    console.log(
      "No contract addresses provided. Set one or more of:\n" +
        "  DIAMOND_ADDRESS, ERC4626_PROXY, STAKING_PROXY, OWNABLE_PROXIES"
    );
    return;
  }

  // ── Process each target ─────────────────────────────────────────
  for (const target of targets) {
    console.log(`[${target.label}] ${target.address}`);

    try {
      if (target.type === "diamond") {
        // Diamond: call OwnershipFacet.transferOwnership via the proxy
        const ownershipFacet = await ethers.getContractAt(
          ["function owner() view returns (address)", "function transferOwnership(address)"],
          target.address
        );
        const currentOwner = await ownershipFacet.owner();
        console.log(`  Current owner: ${currentOwner}`);

        if (currentOwner.toLowerCase() === safeAddress.toLowerCase()) {
          console.log("  Already owned by Safe – skipping");
          continue;
        }

        const tx = await ownershipFacet.transferOwnership(safeAddress);
        await tx.wait();
        console.log(`  ✓ Ownership transferred. Tx: ${tx.hash}`);
      } else if (target.type === "ownable") {
        // UUPS Ownable: transfer ownership on the proxy
        const ownable = await ethers.getContractAt(
          ["function owner() view returns (address)", "function transferOwnership(address)"],
          target.address
        );
        const currentOwner = await ownable.owner();
        console.log(`  Current owner: ${currentOwner}`);

        if (currentOwner.toLowerCase() === safeAddress.toLowerCase()) {
          console.log("  Already owned by Safe – skipping");
          continue;
        }

        const tx = await ownable.transferOwnership(safeAddress);
        await tx.wait();
        console.log(`  ✓ Ownership transferred. Tx: ${tx.hash}`);
      } else if (target.type === "access-control") {
        // AccessControl: grant + renounce DEFAULT_ADMIN_ROLE
        const access = await ethers.getContractAt(
          [
            "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
            "function hasRole(bytes32, address) view returns (bool)",
            "function grantRole(bytes32, address)",
            "function renounceRole(bytes32, address)",
            "function getRoleAdmin(bytes32) view returns (bytes32)",
          ],
          target.address
        );

        const role = await access.DEFAULT_ADMIN_ROLE();
        const hasRole = await access.hasRole(role, safeAddress);
        const caller = await deployer.getAddress();

        if (hasRole) {
          console.log("  Safe already has DEFAULT_ADMIN_ROLE – skipping grant");
        } else {
          const grantTx = await access.grantRole(role, safeAddress);
          await grantTx.wait();
          console.log(`  ✓ Granted DEFAULT_ADMIN_ROLE to Safe. Tx: ${grantTx.hash}`);
        }

        // Renounce the deployer's admin role (only if the Safe has it)
        if (await access.hasRole(role, caller)) {
          const renounceTx = await access.renounceRole(role, caller);
          await renounceTx.wait();
          console.log(`  ✓ Deployer renounced DEFAULT_ADMIN_ROLE. Tx: ${renounceTx.hash}`);
        }
      }
    } catch (err: any) {
      console.error(`  ✗ Failed: ${err.message ?? err}`);
    }
    console.log("");
  }

  console.log("=== Transfer Complete ===");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
