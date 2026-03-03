import { ethers } from "hardhat";

/**
 * Deploy Mock Vault + YieldPlay to Avalanche Fuji C-Chain Testnet
 * 
 * This script deploys:
 * 1. MockUSDC - A faucet-style test token
 * 2. MockERC4626Vault - A simple ERC4626 vault for testing
 * 3. YieldPlay - The main protocol contract
 * 
 * Prerequisites:
 * 1. Create .env file with:
 *    - PRIVATE_KEY=your_private_key
 * 
 * 2. Make sure you have Fuji AVAX for gas
 *    Faucet: https://faucet.avax.network/
 * 
 * Run: npx hardhat run scripts/deployAvalancheFuji.ts --network avalancheFuji
 */

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=".repeat(60));
  console.log("Deploying YieldPlay + Mock Vault to Avalanche Fuji");
  console.log("=".repeat(60));
  console.log("\nDeployer address:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "AVAX");

  if (balance === 0n) {
    throw new Error("No AVAX balance! Please fund your account from https://faucet.avax.network/");
  }

  // ============ 1. Deploy MockUSDC ============
  console.log("\n--- Deploying MockUSDC ---");
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  const mockUSDCAddress = await mockUSDC.getAddress();
  console.log("MockUSDC deployed to:", mockUSDCAddress);

  // Mint initial supply to deployer
  const initialMint = ethers.parseUnits("1000000", 6); // 1M USDC
  await mockUSDC.ownerMint(deployer.address, initialMint);
  console.log("Minted 1,000,000 mUSDC to deployer");

  // ============ 2. Deploy MockERC4626Vault ============
  console.log("\n--- Deploying MockERC4626Vault ---");
  const MockVault = await ethers.getContractFactory("MockERC4626Vault");
  const mockVault = await MockVault.deploy(
    mockUSDCAddress,
    "Mock Yield Vault USDC",
    "mvUSDC"
  );
  await mockVault.waitForDeployment();
  const mockVaultAddress = await mockVault.getAddress();
  console.log("MockERC4626Vault deployed to:", mockVaultAddress);

  // ============ 3. Deploy YieldPlay ============
  console.log("\n--- Deploying YieldPlay ---");
  const protocolTreasury = deployer.address;
  
  const YieldPlay = await ethers.getContractFactory("YieldPlay");
  const yieldPlay = await YieldPlay.deploy(protocolTreasury);
  await yieldPlay.waitForDeployment();
  const yieldPlayAddress = await yieldPlay.getAddress();
  console.log("YieldPlay deployed to:", yieldPlayAddress);

  // ============ 4. Configure YieldPlay ============
  console.log("\n--- Configuring YieldPlay ---");
  const tx = await yieldPlay.setVault(mockUSDCAddress, mockVaultAddress);
  await tx.wait();
  console.log("Vault configured for MockUSDC!");

  // ============ Print Summary ============
  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT COMPLETE");
  console.log("=".repeat(60));
  
  console.log("\nContract Addresses:");
  console.log("  MockUSDC:          ", mockUSDCAddress);
  console.log("  MockERC4626Vault:  ", mockVaultAddress);
  console.log("  YieldPlay:         ", yieldPlayAddress);
  console.log("  Treasury:          ", protocolTreasury);

  console.log("\n--- Verification Commands ---");
  console.log(`npx hardhat verify --network avalancheFuji ${mockUSDCAddress}`);
  console.log(`npx hardhat verify --network avalancheFuji ${mockVaultAddress} ${mockUSDCAddress} "Mock Yield Vault USDC" "mvUSDC"`);
  console.log(`npx hardhat verify --network avalancheFuji ${yieldPlayAddress} ${protocolTreasury}`);

  console.log("\n--- SDK Configuration ---");
  console.log(`const YIELD_PLAY_ADDRESS = "${yieldPlayAddress}";`);
  console.log(`const TOKEN_ADDRESS = "${mockUSDCAddress}";`);
  console.log(`const VAULT_ADDRESS = "${mockVaultAddress}";`);
  console.log(`const RPC_URL = "https://api.avax-test.network/ext/bc/C/rpc";`);

  console.log("\n--- Snowtrace Links ---");
  console.log(`MockUSDC:    https://testnet.snowtrace.io/address/${mockUSDCAddress}`);
  console.log(`MockVault:   https://testnet.snowtrace.io/address/${mockVaultAddress}`);
  console.log(`YieldPlay:   https://testnet.snowtrace.io/address/${yieldPlayAddress}`);

  console.log("\n--- How to get test tokens ---");
  console.log("1. Call mockUSDC.mint(amount) - max 10,000 USDC per call");
  console.log("2. Or use: npx hardhat run scripts/mintTestTokens.ts --network avalancheFuji");

  console.log("\n--- Faucet ---");
  console.log("Get test AVAX: https://faucet.avax.network/");

  return {
    mockUSDC: mockUSDCAddress,
    mockVault: mockVaultAddress,
    yieldPlay: yieldPlayAddress,
    treasury: protocolTreasury,
  };
}

main()
  .then((result) => {
    console.log("\n✅ Deployment successful!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
