// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {GrantRoundFactory} from "../contracts/GrantRoundFactory.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        GrantRoundFactory factory = new GrantRoundFactory();
        console.log("GrantRoundFactory deployed at", address(factory));

        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);
        address round = factory.createRound("MVP Round", "ipfs://metadata", 0, admin);
        console.log("GrantRound deployed at", round);

        vm.stopBroadcast();
    }
}
