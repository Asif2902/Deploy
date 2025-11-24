
const { ethers, network } = require("hardhat");
require('dotenv').config();

async function main() {
  console.log("Starting deployment and configuration of MonBridgeDex contract...");
  console.log("Network:", network.name);
  console.log("Chain ID:", network.config.chainId);

  // Configuration
  const WETH_ADDRESS = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
  const ROUTERS = [
    "0x26CEb692410c4b3C12D63e01CFc03eEA103fc474",
    "0x73fa4d18C80411E420a2E083f1Cf0dc5020cB067",
    "0x8cFe327CEc66d1C090Dd72bd0FF11d690C33a2Eb",
    "0x276e41572bb7A063EC728d659467d42BC91f9f6c",
    "0xBfd2cf709A17c4eEE8DaaF3B96E134408881259e",
    "0x22aDf91b491abc7a50895Cd5c5c194EcCC93f5E2",
    "0x4B2ab38DBF28D31D467aA8993f6c2585981D6804"
  ];
  const WHITELIST_TOKENS = [
    "0x754704Bc059F8C67012fEd69BC8A327a5aafb603"
  ];

  // Get the contract factory
  const MonBridgeDex = await ethers.getContractFactory("MonBridgeDex");
  
  // Deploy the contract
  console.log(`Deploying with WETH address: ${WETH_ADDRESS}`);
  console.log("Network:", network.name);
  
  const dex = await MonBridgeDex.deploy(WETH_ADDRESS);
  
  console.log("Deployment transaction initiated...");
  console.log("Transaction hash:", dex.deployTransaction.hash);
  
  // Wait for deployment
  console.log("Waiting for deployment confirmation...");
  await dex.deployed();
  
  console.log(`MonBridgeDex deployed to: ${dex.address}`);
  
  // Wait for a few blocks to ensure deployment is confirmed
  console.log("Waiting for additional confirmations...");
  await new Promise(resolve => setTimeout(resolve, 10000));
  
  // Add routers
  console.log("\nAdding routers...");
  const addRoutersTx = await dex.addRouters(ROUTERS);
  await addRoutersTx.wait();
  console.log("Routers added successfully!");
  console.log(`Added ${ROUTERS.length} routers`);
  
  // Whitelist tokens
  console.log("\nWhitelisting tokens...");
  const whitelistTx = await dex.whitelistTokens(WHITELIST_TOKENS);
  await whitelistTx.wait();
  console.log("Tokens whitelisted successfully!");
  console.log(`Whitelisted ${WHITELIST_TOKENS.length} tokens`);
  
  // Save deployment info
  const fs = require("fs");
  const deploymentInfo = {
    contractAddress: dex.address,
    networkName: network.name,
    chainId: network.config.chainId,
    timestamp: new Date().toISOString(),
    wethAddress: WETH_ADDRESS,
    routers: ROUTERS,
    whitelistedTokens: WHITELIST_TOKENS
  };
  
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }
  
  fs.writeFileSync(
    `./deployments/${network.name}-deployment.json`,
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log(`\nDeployment info saved to ./deployments/${network.name}-deployment.json`);
  
  console.log("\n=== Deployment Summary ===");
  console.log(`Contract Address: ${dex.address}`);
  console.log(`WETH Address: ${WETH_ADDRESS}`);
  console.log(`Routers Added: ${ROUTERS.length}`);
  console.log(`Tokens Whitelisted: ${WHITELIST_TOKENS.length}`);
  console.log("=========================");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error during deployment:", error);
    process.exit(1);
  });
