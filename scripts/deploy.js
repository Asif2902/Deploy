const { ethers, network } = require("hardhat");
require('dotenv').config();

async function main() {
  console.log("Starting deployment of MonBridgeDex contract...");

  // Get the WETH address from environment variables or use default
  const WETH_ADDRESS = process.env.WETH_ADDRESS || "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701";
  
  // Get the contract factory
  const MonBridgeDex = await ethers.getContractFactory("MonBridgeDex");
  
  // Deploy the contract with the specified WETH address
  console.log(`Deploying with WETH address: ${WETH_ADDRESS}`);
  console.log("Network:", network.name);
  
  // Deploy the contract
  const dex = await MonBridgeDex.deploy(WETH_ADDRESS);
  
  console.log("Deployment transaction initiated...");
  console.log("Transaction hash:", dex.deployTransaction.hash);
  
  // Wait for deployment to finish
  console.log("Waiting for deployment confirmation...");
  await dex.deployed();
  
  console.log(`MonBridgeDex deployed to: ${dex.address}`);
  console.log("Deployment completed successfully!");
  console.log("You can now configure the DEX by adding routers and whitelisting tokens.");
  
  // Save deployment info to a file for the frontend to use
  const fs = require("fs");
  const deploymentInfo = {
    contractAddress: dex.address,
    networkName: network.name,
    chainId: network.config.chainId,
    timestamp: new Date().toISOString(),
    wethAddress: WETH_ADDRESS
  };
  
  // Create a deployments directory if it doesn't exist
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }
  
  fs.writeFileSync(
    `./deployments/${network.name}-deployment.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log(`Deployment info saved to ./deployments/${network.name}-deployment.json`);
}

// Execute the deployment
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error during deployment:", error);
    process.exit(1);
  });
