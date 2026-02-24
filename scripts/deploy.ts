import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance));

  // Deploy YieldPlay
  const protocolTreasury = deployer.address; // Use deployer as treasury for demo
  
  console.log("\n--- Deploying YieldPlay ---");
  const YieldPlay = await ethers.getContractFactory("YieldPlay");
  const yieldPlay = await YieldPlay.deploy(protocolTreasury);
  await yieldPlay.waitForDeployment();
  const yieldPlayAddress = await yieldPlay.getAddress();
  console.log("YieldPlay deployed to:", yieldPlayAddress);

  console.log("\n--- Deployment Complete ---");
  console.log({
    yieldPlay: yieldPlayAddress,
    protocolTreasury: protocolTreasury,
    deployer: deployer.address,
  });

  // Return addresses for verification
  return {
    yieldPlay: yieldPlayAddress,
    protocolTreasury: protocolTreasury,
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
