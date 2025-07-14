require("dotenv").config();
const fs = require("fs");
const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.MONAD_TESTNET_RPC);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

  const artifact = JSON.parse(fs.readFileSync("artifacts/contracts/MonBridgeDex.sol/MonBridgeDex.json", "utf8"));
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

  // Get the WETH address from environment variables or use default
  const WETH_ADDRESS = process.env.WETH_ADDRESS || "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701";
  
  console.log("Deploying MonBridgeDex...");
  console.log(`Using WETH address: ${WETH_ADDRESS}`);
  const contract = await factory.deploy(WETH_ADDRESS);

  console.log("Waiting for confirmation...");
  await contract.deploymentTransaction().wait();

  console.log("✅ Deployed to:", contract.target);
}

main().catch((err) => {
  console.error("❌ Error during deployment:", err);
  process.exit(1);
});
