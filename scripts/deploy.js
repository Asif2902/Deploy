const { ethers, network } = require("hardhat");
require("dotenv").config();
const fs = require("fs");

async function main() {
  console.log("Starting deployment of MonBridgeDex contract...");

  const WETH_ADDRESS = process.env.WETH_ADDRESS || "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701";
  const MonBridgeDex = await ethers.getContractFactory("MonBridgeDex");

  console.log(`Deploying with WETH address: ${WETH_ADDRESS}`);
  console.log("Network:", network.name);

  const dex = await MonBridgeDex.deploy(WETH_ADDRESS);

  console.log("Deployment transaction initiated...");
  console.log("Transaction hash:", dex.deployTransaction.hash);

  await dex.deployed();

  console.log(`MonBridgeDex deployed to: ${dex.address}`);
  console.log("Deployment completed successfully!");

  const deploymentInfo = {
    contractAddress: dex.address,
    networkName: network.name,
    chainId: network.config.chainId,
    timestamp: new Date().toISOString(),
    wethAddress: WETH_ADDRESS,
  };

  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }

  fs.writeFileSync(
    `./deployments/${network.name}-deployment.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );

  console.log(`Deployment info saved to ./deployments/${network.name}-deployment.json`);
}

main().catch((error) => {
  console.error("Error during deployment:", error);
  process.exit(1);
});