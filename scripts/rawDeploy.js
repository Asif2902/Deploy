const { ethers } = require("ethers");
const fs = require("fs");
require("dotenv").config();

async function main() {
  console.log("Starting raw deployment...");

  const MONAD_RPC = process.env.MONAD_RPC || "https://testnet-rpc.monad.xyz";
  const PRIVATE_KEY = process.env.PRIVATE_KEY;

  const provider = new ethers.JsonRpcProvider(MONAD_RPC);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  // Load compiled artifact (replace with your real path)
  const artifact = JSON.parse(
    fs.readFileSync(
      "./artifacts/contracts/MonBridgeDex.sol/MonBridgeDex.json",
      "utf8"
    )
  );
  const bytecode = artifact.bytecode;
  const abi = artifact.abi;

  const iface = new ethers.Interface(abi);

  // Constructor argument encoding
  const constructorData = iface.encodeDeploy([
    process.env.WETH_ADDRESS || "0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701",
  ]);

  const fullInitCode = bytecode + constructorData.slice(2); // remove "0x" from constructorData

  const tx = await wallet.sendTransaction({
    data: fullInitCode,
    gasLimit: 20_000_000,
  });

  console.log("Tx hash:", tx.hash);
  const receipt = await tx.wait();

  console.log("Contract deployed at:", receipt.contractAddress);
}

main().catch(console.error);
