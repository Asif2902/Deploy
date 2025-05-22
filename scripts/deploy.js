const hre = require("hardhat"); // replace this line
// const { ethers, network } = require("hardhat"); <- REMOVE this line

require('dotenv').config();

async function main() {
  console.log("Starting deployment of MonBridgeDex contract...");

  const WETH_ADDRESS = process.env.WETH_ADDRESS || "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701";

  // Use hre.ethers directly
  const MonBridgeDex = await hre.ethers.getContractFactory("MonBridgeDex");

  console.log(`Deploying with WETH address: ${WETH_ADDRESS}`);
  console.log("Network:", hre.network.name);

  const dex = await MonBridgeDex.deploy(WETH_ADDRESS);

  console.log("Deployment transaction initiated...");
  console.log("Transaction hash:", dex.deployTransaction.hash);

  await dex.deployed();

  console.log(`MonBridgeDex deployed to: ${dex.address}`);

  const fs = require("fs");

  const deploymentInfo = {
    contractAddress: dex.address,
    networkName: hre.network.name,
    chainId: hre.network.config.chainId,
    timestamp: new Date().toISOString(),
    wethAddress: WETH_ADDRESS
  };

  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }

  fs.writeFileSync(
    `./deployments/${hre.network.name}-deployment.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );

  console.log(`Deployment info saved to ./deployments/${hre.network.name}-deployment.json`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error during deployment:", error);
    process.exit(1);
  });