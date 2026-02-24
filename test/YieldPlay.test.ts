import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { 
  YieldPlay, 
  MockERC20, 
  MockYieldStrategy 
} from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("YieldPlay", function () {
  let yieldPlay: YieldPlay;
  let mockToken: MockERC20;
  let mockStrategy: MockYieldStrategy;
  let owner: SignerWithAddress;
  let gameOwner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let user3: SignerWithAddress;
  let treasury: SignerWithAddress;
  let protocolTreasury: SignerWithAddress;

  const DECIMALS = 6;
  const INITIAL_BALANCE = ethers.parseUnits("10000", DECIMALS);
  const YIELD_RATE_BPS = 500; // 5% yield

  beforeEach(async function () {
    [owner, gameOwner, user1, user2, user3, treasury, protocolTreasury] = 
      await ethers.getSigners();

    // Deploy Mock Token
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20Factory.deploy("Mock USDC", "mUSDC", DECIMALS);
    await mockToken.waitForDeployment();

    // Deploy YieldPlay
    const YieldPlayFactory = await ethers.getContractFactory("YieldPlay");
    yieldPlay = await YieldPlayFactory.deploy(protocolTreasury.address);
    await yieldPlay.waitForDeployment();

    // Deploy Mock Strategy
    const MockStrategyFactory = await ethers.getContractFactory("MockYieldStrategy");
    mockStrategy = await MockStrategyFactory.deploy(
      await mockToken.getAddress(),
      await yieldPlay.getAddress(),
      YIELD_RATE_BPS
    );
    await mockStrategy.waitForDeployment();

    // Configure strategy
    await yieldPlay.setStrategy(
      await mockToken.getAddress(),
      await mockStrategy.getAddress()
    );

    // Mint tokens to users
    await mockToken.mint(user1.address, INITIAL_BALANCE);
    await mockToken.mint(user2.address, INITIAL_BALANCE);
    await mockToken.mint(user3.address, INITIAL_BALANCE);

    // Mint tokens to strategy for yield simulation
    const yieldFunding = ethers.parseUnits("10000", DECIMALS);
    await mockToken.mint(await mockStrategy.getAddress(), yieldFunding);

    // Approve YieldPlay
    await mockToken.connect(user1).approve(await yieldPlay.getAddress(), ethers.MaxUint256);
    await mockToken.connect(user2).approve(await yieldPlay.getAddress(), ethers.MaxUint256);
    await mockToken.connect(user3).approve(await yieldPlay.getAddress(), ethers.MaxUint256);
  });

  describe("Game Creation", function () {
    it("Should create a game successfully", async function () {
      const gameName = "TestGame";
      const devFeeBps = 1000; // 10%

      const tx = await yieldPlay.connect(gameOwner).createGame(
        gameName,
        devFeeBps,
        treasury.address,
        await mockToken.getAddress()
      );

      const gameId = await yieldPlay.calculateGameId(gameOwner.address, gameName);
      const game = await yieldPlay.getGame(gameId);

      expect(game.owner).to.equal(gameOwner.address);
      expect(game.gameName).to.equal(gameName);
      expect(game.devFeeBps).to.equal(devFeeBps);
      expect(game.treasury).to.equal(treasury.address);
      expect(game.initialized).to.be.true;

      await expect(tx)
        .to.emit(yieldPlay, "GameCreated")
        .withArgs(gameId, gameOwner.address, gameName, devFeeBps, await mockToken.getAddress());
    });

    it("Should revert if dev fee exceeds 100%", async function () {
      await expect(
        yieldPlay.connect(gameOwner).createGame(
          "TestGame",
          10001, // > 100%
          treasury.address,
          await mockToken.getAddress()
        )
      ).to.be.revertedWithCustomError(yieldPlay, "InvalidDevFeeBps");
    });

    it("Should revert if game already exists", async function () {
      const gameName = "TestGame";
      await yieldPlay.connect(gameOwner).createGame(
        gameName,
        1000,
        treasury.address,
        await mockToken.getAddress()
      );

      await expect(
        yieldPlay.connect(gameOwner).createGame(
          gameName,
          1000,
          treasury.address,
          await mockToken.getAddress()
        )
      ).to.be.revertedWithCustomError(yieldPlay, "GameAlreadyExists");
    });
  });

  describe("Round Creation", function () {
    let gameId: string;

    beforeEach(async function () {
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000,
        treasury.address,
        await mockToken.getAddress()
      );
      gameId = await yieldPlay.calculateGameId(gameOwner.address, "TestGame");
    });

    it("Should create a round successfully", async function () {
      const now = await time.latest();
      const startTs = now + 100;
      const endTs = now + 1000;
      const lockTime = 500;

      const tx = await yieldPlay.connect(gameOwner).createRound(
        gameId,
        startTs,
        endTs,
        lockTime
      );

      const round = await yieldPlay.getRound(gameId, 0);

      expect(round.gameId).to.equal(gameId);
      expect(round.roundId).to.equal(0);
      expect(round.startTs).to.equal(startTs);
      expect(round.endTs).to.equal(endTs);
      expect(round.lockTime).to.equal(lockTime);
      expect(round.status).to.equal(0); // NotStarted

      await expect(tx)
        .to.emit(yieldPlay, "RoundCreated")
        .withArgs(gameId, 0, startTs, endTs, lockTime);
    });

    it("Should revert if caller is not game owner", async function () {
      const now = await time.latest();
      await expect(
        yieldPlay.connect(user1).createRound(gameId, now + 100, now + 1000, 500)
      ).to.be.revertedWithCustomError(yieldPlay, "Unauthorized");
    });

    it("Should revert if end time is before start time", async function () {
      const now = await time.latest();
      await expect(
        yieldPlay.connect(gameOwner).createRound(gameId, now + 1000, now + 100, 500)
      ).to.be.revertedWithCustomError(yieldPlay, "InvalidRoundTime");
    });
  });

  describe("Deposits", function () {
    let gameId: string;

    beforeEach(async function () {
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000,
        treasury.address,
        await mockToken.getAddress()
      );
      gameId = await yieldPlay.calculateGameId(gameOwner.address, "TestGame");

      const now = await time.latest();
      await yieldPlay.connect(gameOwner).createRound(
        gameId,
        now + 10,
        now + 1000,
        500
      );

      // Advance to start
      await time.increase(20);
    });

    it("Should accept deposits during InProgress", async function () {
      const depositAmount = ethers.parseUnits("1000", DECIMALS);

      const tx = await yieldPlay.connect(user1).deposit(gameId, 0, depositAmount);

      const userDeposit = await yieldPlay.getUserDeposit(gameId, 0, user1.address);
      expect(userDeposit.depositAmount).to.equal(depositAmount);
      expect(userDeposit.exists).to.be.true;

      const round = await yieldPlay.getRound(gameId, 0);
      expect(round.totalDeposit).to.equal(depositAmount);

      await expect(tx)
        .to.emit(yieldPlay, "Deposited")
        .withArgs(gameId, 0, user1.address, depositAmount);
    });

    it("Should allow multiple deposits from same user", async function () {
      const depositAmount1 = ethers.parseUnits("500", DECIMALS);
      const depositAmount2 = ethers.parseUnits("300", DECIMALS);

      await yieldPlay.connect(user1).deposit(gameId, 0, depositAmount1);
      await yieldPlay.connect(user1).deposit(gameId, 0, depositAmount2);

      const userDeposit = await yieldPlay.getUserDeposit(gameId, 0, user1.address);
      expect(userDeposit.depositAmount).to.equal(depositAmount1 + depositAmount2);
    });

    it("Should reject deposits before round starts", async function () {
      // Create a new round that hasn't started
      const now = await time.latest();
      await yieldPlay.connect(gameOwner).createRound(
        gameId,
        now + 1000, // starts in the future
        now + 2000,
        500
      );

      await expect(
        yieldPlay.connect(user1).deposit(gameId, 1, ethers.parseUnits("100", DECIMALS))
      ).to.be.revertedWithCustomError(yieldPlay, "RoundNotActive");
    });

    it("Should reject zero amount deposits", async function () {
      await expect(
        yieldPlay.connect(user1).deposit(gameId, 0, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "InvalidAmount");
    });
  });

  describe("Full Round Lifecycle", function () {
    let gameId: string;
    const depositAmount1 = ethers.parseUnits("1000", DECIMALS);
    const depositAmount2 = ethers.parseUnits("2000", DECIMALS);

    beforeEach(async function () {
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000, // 10% dev fee
        treasury.address,
        await mockToken.getAddress()
      );
      gameId = await yieldPlay.calculateGameId(gameOwner.address, "TestGame");

      const now = await time.latest();
      await yieldPlay.connect(gameOwner).createRound(
        gameId,
        now + 10,
        now + 500,
        300
      );

      // Advance to start and deposit
      await time.increase(20);
      await yieldPlay.connect(user1).deposit(gameId, 0, depositAmount1);
      await yieldPlay.connect(user2).deposit(gameId, 0, depositAmount2);
    });

    it("Should complete full lifecycle: deposit -> deploy -> withdraw -> settle -> choose winner -> claim", async function () {
      // Advance past deposit period
      await time.increase(500);

      // Deploy to strategy
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      
      let round = await yieldPlay.getRound(gameId, 0);
      expect(round.fundsDeployed).to.be.true;

      // Advance past lock period
      await time.increase(400);

      // Withdraw from strategy
      await yieldPlay.connect(gameOwner).withdrawFromStrategy(gameId, 0);
      
      round = await yieldPlay.getRound(gameId, 0);
      expect(round.fundsDeployed).to.be.false;

      // Settlement
      const treasuryBalanceBefore = await mockToken.balanceOf(treasury.address);
      const protocolBalanceBefore = await mockToken.balanceOf(protocolTreasury.address);

      await yieldPlay.connect(gameOwner).settlement(gameId, 0);

      round = await yieldPlay.getRound(gameId, 0);
      expect(round.isSettled).to.be.true;
      expect(round.totalWin).to.be.gt(0);

      // Treasury should have received dev fee
      const treasuryBalanceAfter = await mockToken.balanceOf(treasury.address);
      expect(treasuryBalanceAfter).to.be.gt(treasuryBalanceBefore);

      // Protocol treasury should have received performance fee
      const protocolBalanceAfter = await mockToken.balanceOf(protocolTreasury.address);
      expect(protocolBalanceAfter).to.be.gt(protocolBalanceBefore);

      // Choose winner (user1 gets all prizes)
      const prizeAmount = round.totalWin;
      await yieldPlay.connect(gameOwner).chooseWinner(gameId, 0, user1.address, prizeAmount);

      round = await yieldPlay.getRound(gameId, 0);
      expect(round.totalWin).to.equal(0);
      expect(round.status).to.equal(4); // DistributingRewards

      // Users claim
      const user1BalanceBefore = await mockToken.balanceOf(user1.address);
      await yieldPlay.connect(user1).claim(gameId, 0);
      const user1BalanceAfter = await mockToken.balanceOf(user1.address);

      // User1 should receive deposit + prize
      expect(user1BalanceAfter - user1BalanceBefore).to.equal(depositAmount1 + prizeAmount);

      const user2BalanceBefore = await mockToken.balanceOf(user2.address);
      await yieldPlay.connect(user2).claim(gameId, 0);
      const user2BalanceAfter = await mockToken.balanceOf(user2.address);

      // User2 should receive only deposit (no prize)
      expect(user2BalanceAfter - user2BalanceBefore).to.equal(depositAmount2);
    });

    it("Should allow multiple winners", async function () {
      // Add user3
      await yieldPlay.connect(user3).deposit(gameId, 0, ethers.parseUnits("1000", DECIMALS));

      await time.increase(500);
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      await time.increase(400);
      await yieldPlay.connect(gameOwner).withdrawFromStrategy(gameId, 0);
      await yieldPlay.connect(gameOwner).settlement(gameId, 0);

      let round = await yieldPlay.getRound(gameId, 0);
      const totalPrize = round.totalWin;
      const prize1 = totalPrize / 2n;
      const prize2 = totalPrize - prize1;

      // User1 wins half
      await yieldPlay.connect(gameOwner).chooseWinner(gameId, 0, user1.address, prize1);
      
      round = await yieldPlay.getRound(gameId, 0);
      expect(round.status).to.equal(3); // Still ChoosingWinners

      // User3 wins other half
      await yieldPlay.connect(gameOwner).chooseWinner(gameId, 0, user3.address, prize2);

      round = await yieldPlay.getRound(gameId, 0);
      expect(round.status).to.equal(4); // DistributingRewards
    });

    it("Should reject claims before round is complete", async function () {
      await expect(
        yieldPlay.connect(user1).claim(gameId, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "RoundNotCompleted");
    });

    it("Should reject double claims", async function () {
      await time.increase(500);
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      await time.increase(400);
      await yieldPlay.connect(gameOwner).withdrawFromStrategy(gameId, 0);
      await yieldPlay.connect(gameOwner).settlement(gameId, 0);
      await yieldPlay.connect(gameOwner).finalizeRound(gameId, 0);

      await yieldPlay.connect(user1).claim(gameId, 0);

      await expect(
        yieldPlay.connect(user1).claim(gameId, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "AlreadyClaimed");
    });
  });

  describe("Access Control", function () {
    let gameId: string;

    beforeEach(async function () {
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000,
        treasury.address,
        await mockToken.getAddress()
      );
      gameId = await yieldPlay.calculateGameId(gameOwner.address, "TestGame");

      const now = await time.latest();
      await yieldPlay.connect(gameOwner).createRound(
        gameId,
        now + 10,
        now + 500,
        300
      );

      await time.increase(20);
      await yieldPlay.connect(user1).deposit(gameId, 0, ethers.parseUnits("1000", DECIMALS));
      await time.increase(500);
    });

    it("Should reject depositToStrategy from non-owner", async function () {
      await expect(
        yieldPlay.connect(user1).depositToStrategy(gameId, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "Unauthorized");
    });

    it("Should reject withdrawFromStrategy from non-owner", async function () {
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      await time.increase(400);

      await expect(
        yieldPlay.connect(user1).withdrawFromStrategy(gameId, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "Unauthorized");
    });

    it("Should reject settlement from non-owner", async function () {
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      await time.increase(400);
      await yieldPlay.connect(gameOwner).withdrawFromStrategy(gameId, 0);

      await expect(
        yieldPlay.connect(user1).settlement(gameId, 0)
      ).to.be.revertedWithCustomError(yieldPlay, "Unauthorized");
    });

    it("Should reject chooseWinner from non-owner", async function () {
      await yieldPlay.connect(gameOwner).depositToStrategy(gameId, 0);
      await time.increase(400);
      await yieldPlay.connect(gameOwner).withdrawFromStrategy(gameId, 0);
      await yieldPlay.connect(gameOwner).settlement(gameId, 0);

      await expect(
        yieldPlay.connect(user1).chooseWinner(gameId, 0, user1.address, 100)
      ).to.be.revertedWithCustomError(yieldPlay, "Unauthorized");
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to pause and unpause", async function () {
      await yieldPlay.pause();
      
      await expect(
        yieldPlay.connect(gameOwner).createGame(
          "TestGame",
          1000,
          treasury.address,
          await mockToken.getAddress()
        )
      ).to.be.revertedWithCustomError(yieldPlay, "EnforcedPause");

      await yieldPlay.unpause();

      // Should work now
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000,
        treasury.address,
        await mockToken.getAddress()
      );
    });

    it("Should allow owner to update protocol treasury", async function () {
      const newTreasury = user3.address;
      
      await expect(yieldPlay.setProtocolTreasury(newTreasury))
        .to.emit(yieldPlay, "ProtocolTreasuryUpdated")
        .withArgs(newTreasury);

      expect(await yieldPlay.protocolTreasury()).to.equal(newTreasury);
    });

    it("Should allow owner to set strategy", async function () {
      const newToken = user3.address; // Just using as address
      const newStrategy = treasury.address;

      await expect(yieldPlay.setStrategy(newToken, newStrategy))
        .to.emit(yieldPlay, "StrategyUpdated")
        .withArgs(newToken, newStrategy);

      expect(await yieldPlay.strategies(newToken)).to.equal(newStrategy);
    });

    it("Should reject admin functions from non-owner", async function () {
      await expect(
        yieldPlay.connect(user1).pause()
      ).to.be.revertedWithCustomError(yieldPlay, "OwnableUnauthorizedAccount");

      await expect(
        yieldPlay.connect(user1).setProtocolTreasury(user1.address)
      ).to.be.revertedWithCustomError(yieldPlay, "OwnableUnauthorizedAccount");

      await expect(
        yieldPlay.connect(user1).setStrategy(user1.address, user2.address)
      ).to.be.revertedWithCustomError(yieldPlay, "OwnableUnauthorizedAccount");
    });
  });

  describe("View Functions", function () {
    it("Should calculate correct game ID", async function () {
      const gameName = "TestGame";
      const expectedId = ethers.keccak256(
        ethers.solidityPacked(["address", "string"], [gameOwner.address, gameName])
      );

      const calculatedId = await yieldPlay.calculateGameId(gameOwner.address, gameName);
      expect(calculatedId).to.equal(expectedId);
    });

    it("Should return correct current status", async function () {
      await yieldPlay.connect(gameOwner).createGame(
        "TestGame",
        1000,
        treasury.address,
        await mockToken.getAddress()
      );
      const gameId = await yieldPlay.calculateGameId(gameOwner.address, "TestGame");

      const now = await time.latest();
      await yieldPlay.connect(gameOwner).createRound(
        gameId,
        now + 100,
        now + 500,
        300
      );

      // NotStarted
      expect(await yieldPlay.getCurrentStatus(gameId, 0)).to.equal(0);

      await time.increase(150);
      // InProgress
      expect(await yieldPlay.getCurrentStatus(gameId, 0)).to.equal(1);

      await time.increase(400);
      // Locking
      expect(await yieldPlay.getCurrentStatus(gameId, 0)).to.equal(2);

      await time.increase(400);
      // ChoosingWinners
      expect(await yieldPlay.getCurrentStatus(gameId, 0)).to.equal(3);
    });
  });
});
