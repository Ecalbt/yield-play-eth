import { ethers } from "hardhat";

/**
 * Full deployment script including mock tokens and strategies for testnet
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance));

  // ========== Deploy Mock Token ==========
  console.log("\n--- Deploying Mock USDC ---");
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockUSDC = await MockERC20.deploy("Mock USDC", "mUSDC", 6);
  await mockUSDC.waitForDeployment();
  const mockUSDCAddress = await mockUSDC.getAddress();
  console.log("Mock USDC deployed to:", mockUSDCAddress);

  // ========== Deploy YieldPlay ==========
  console.log("\n--- Deploying YieldPlay ---");
  const protocolTreasury = deployer.address;
  const YieldPlay = await ethers.getContractFactory("YieldPlay");
  const yieldPlay = await YieldPlay.deploy(protocolTreasury);
  await yieldPlay.waitForDeployment();
  const yieldPlayAddress = await yieldPlay.getAddress();
  console.log("YieldPlay deployed to:", yieldPlayAddress);

  // ========== Deploy Mock Strategy ==========
  console.log("\n--- Deploying Mock Yield Strategy ---");
  const yieldRateBps = 500; // 5% yield for testing
  const MockYieldStrategy = await ethers.getContractFactory("MockYieldStrategy");
  const mockStrategy = await MockYieldStrategy.deploy(
    mockUSDCAddress,
    yieldPlayAddress,
    yieldRateBps
  );
  await mockStrategy.waitForDeployment();
  const mockStrategyAddress = await mockStrategy.getAddress();
  console.log("Mock Strategy deployed to:", mockStrategyAddress);

  // ========== Configure YieldPlay ==========
  console.log("\n--- Configuring YieldPlay ---");
  const tx = await yieldPlay.setStrategy(mockUSDCAddress, mockStrategyAddress);
  await tx.wait();
  console.log("Strategy set for Mock USDC");

  // ========== Mint Test Tokens ==========
  console.log("\n--- Minting Test Tokens ---");
  const mintAmount = ethers.parseUnits("1000000", 6); // 1M USDC
  await mockUSDC.mint(deployer.address, mintAmount);
  console.log(`Minted ${ethers.formatUnits(mintAmount, 6)} mUSDC to deployer`);

  // Also mint to strategy for yield simulation
  const yieldAmount = ethers.parseUnits("100000", 6); // 100K for yield
  await mockUSDC.mint(mockStrategyAddress, yieldAmount);
  console.log(`Minted ${ethers.formatUnits(yieldAmount, 6)} mUSDC to strategy for yield`);

  // ========== Summary ==========
  console.log("\n========== Deployment Summary ==========");
  console.log({
    mockUSDC: mockUSDCAddress,
    yieldPlay: yieldPlayAddress,
    mockStrategy: mockStrategyAddress,
    protocolTreasury: protocolTreasury,
    deployer: deployer.address,
  });

  console.log("\n========== Verification Commands ==========");
  console.log(`npx hardhat verify --network <network> ${yieldPlayAddress} ${protocolTreasury}`);
  console.log(`npx hardhat verify --network <network> ${mockUSDCAddress} "Mock USDC" "mUSDC" 6`);
  console.log(`npx hardhat verify --network <network> ${mockStrategyAddress} ${mockUSDCAddress} ${yieldPlayAddress} ${yieldRateBps}`);

  return {
    mockUSDC: mockUSDCAddress,
    yieldPlay: yieldPlayAddress,
    mockStrategy: mockStrategyAddress,
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
