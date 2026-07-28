import { HardhatUserConfig } from "hardhat/config";
import hhEthers from "@nomicfoundation/hardhat-ethers";
import hhUpgrades from "@openzeppelin/hardhat-upgrades";

const config: HardhatUserConfig = {
  solidity: "0.8.24",
  paths: {
    sources: "./contracts",
    tests: "./test/upgradeability"
  },
  plugins: [
    hhEthers,
    hhUpgrades
  ]
};

export default config;
