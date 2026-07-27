// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrantRoundFactory} from "../contracts/GrantRoundFactory.sol";

/// @title Deploy - Unified deployment script for the WhiteLotus grant stack
/// @notice Deploys GrantRoundFactory and optionally creates initial grant rounds.
/// @dev Run with:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast --verify \
///     --etherscan-api-key $ETHERSCAN_API_KEY \
///     -vvvv
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envOr("ADMIN_ADDRESS", vm.addr(deployerKey));

        console.log("=== WhiteLotus Deployment ===");
        console.log("Deployer :", vm.addr(deployerKey));
        console.log("Admin    :", admin);
        console.log("");

        // ── 1. Deploy GrantRoundFactory ──────────────────────────────
        vm.startBroadcast(deployerKey);

        GrantRoundFactory factory = new GrantRoundFactory();
        console.log("[1/2] GrantRoundFactory deployed at:", address(factory));

        // ── 2. Create initial round (if configured) ──────────────────
        string memory roundTitle = vm.envOr("INIT_ROUND_TITLE", string(""));
        if (bytes(roundTitle).length > 0) {
            string memory metaURI = vm.envOr("INIT_ROUND_METADATA", string("ipfs://"));
            uint256 budget = vm.envOr("INIT_ROUND_BUDGET", uint256(0));
            uint256 fundingWei = vm.envOr("INIT_ROUND_FUNDING", uint256(0));

            address roundAddr;
            if (fundingWei > 0) {
                roundAddr =
                    factory.createRound{value: fundingWei}(roundTitle, metaURI, budget, admin);
            } else {
                roundAddr = factory.createRound(roundTitle, metaURI, budget, admin);
            }

            console.log("[2/2] Initial GrantRound deployed at:", roundAddr);
            console.log("       Title  :", roundTitle);
            console.log("       Budget :", budget);
            if (fundingWei > 0) {
                console.log("       Funding:", fundingWei);
            }
        } else {
            console.log("[2/2] No initial round configured (set INIT_ROUND_TITLE to create one)");
        }

        vm.stopBroadcast();

        // ── Summary ──────────────────────────────────────────────────
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("GrantRoundFactory:", address(factory));
        console.log("Total rounds     :", factory.roundsCount());
    }
}
