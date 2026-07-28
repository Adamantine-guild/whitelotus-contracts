import { defineConfig } from "hardhat/config";
import hhEthers from "@nomicfoundation/hardhat-ethers";
import hhMocha from "@nomicfoundation/hardhat-mocha";
import hhEthersChaiMatchers from "@nomicfoundation/hardhat-ethers-chai-matchers";
import hhUpgrades from "@openzeppelin/hardhat-upgrades";

export default defineConfig({
  solidity: {
    version: "0.8.24",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test"
  },
  plugins: [
    hhEthers,
    hhMocha,
    hhEthersChaiMatchers,
    hhUpgrades
  ]
});
