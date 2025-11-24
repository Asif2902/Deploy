
require("dotenv").config();
const fs = require("fs");
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(process.env.MONAD_TESTNET_RPC);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const artifact = JSON.parse(fs.readFileSync("artifacts/contracts/MonBridgeDex.sol/MonBridgeDex.json", "utf8"));
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

  // Get the WETH address from environment variables or use default
  const WETH_ADDRESS = process.env.WETH_ADDRESS || "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A";
  
  console.log("Deploying MonBridgeDex...");
  console.log(`Using WETH address: ${WETH_ADDRESS}`);
  const contract = await factory.deploy(WETH_ADDRESS);

  console.log("Waiting for confirmation...");
  await contract.deployTransaction.wait();

  console.log("✅ Deployed to:", contract.address);
  
  // Save deployment info
  const deploymentInfo = {
    contractAddress: contract.address,
    transactionHash: contract.deployTransaction.hash,
    timestamp: new Date().toISOString(),
    wethAddress: WETH_ADDRESS
  };
  
  // Create a deployments directory if it doesn't exist
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }
  
  fs.writeFileSync(
    "./deployments/raw-deployment.json",
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("Deployment info saved to ./deployments/raw-deployment.json");
}

main().catch((err) => {
  console.error("❌ Error during deployment:", err);
  process.exit(1);
});
