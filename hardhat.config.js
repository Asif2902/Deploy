require("@nomicfoundation/hardhat-toolbox"); // Includes ethers, waffle, etc.
require('dotenv').config();

module.exports = {
  solidity: {
    version: "0.8.26", // Required for newer EVM targets like Shanghai + viaIR
    settings: {
      evmVersion: "shanghai",
      optimizer: {
        enabled: true,
        runs: 2000000, // Higher for more optimized runtime gas
      },
      viaIR: true
    }
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true
    },
    localhost: {
      url: "http://127.0.0.1:8545/",
      allowUnlimitedContractSize: true
    },
    monad_testnet: {
      url: process.env.MONAD_TESTNET_RPC || "https://testnet-rpc.monad.xyz",
      chainId: 10143,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      allowUnlimitedContractSize: true
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};