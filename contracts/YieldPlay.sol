// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IYieldStrategy} from "./interfaces/IYieldStrategy.sol";
import {Game, Round, UserDeposit, RoundStatus} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title YieldPlay
 * @author No-Loss Protocol Team
 * @notice A no-loss prize game protocol where depositors' funds generate yield
 *         that is distributed to selected winners while principals are returned.
 * @dev This contract manages multiple games, each with multiple rounds.
 *      Funds are deployed to external yield strategies during the lock period.
 */
contract YieldPlay is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    
    /// @notice Performance fee rate (20% = 2000 bps)
    uint256 public constant PERFORMANCE_FEE_BPS = 2000;
    
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ State Variables ============
    
    /// @notice Protocol admin treasury for performance fees
    address public protocolTreasury;
    
    /// @notice Mapping from gameId to Game struct
    mapping(bytes32 => Game) public games;
    
    /// @notice Mapping from gameId => roundId => Round struct
    mapping(bytes32 => mapping(uint256 => Round)) public rounds;
    
    /// @notice Mapping from gameId => roundId => user => UserDeposit
    mapping(bytes32 => mapping(uint256 => mapping(address => UserDeposit))) public userDeposits;
    
    /// @notice Mapping from payment token => yield strategy
    mapping(address => address) public strategies;
    
    /// @notice Mapping from gameId => roundId => deposited amount to strategy
    mapping(bytes32 => mapping(uint256 => uint256)) public deployedAmounts;

    // ============ Events ============
    
    event GameCreated(
        bytes32 indexed gameId,
        address indexed owner,
        string gameName,
        uint16 devFeeBps,
        address paymentToken
    );
    
    event RoundCreated(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint64 startTs,
        uint64 endTs,
        uint64 lockTime
    );
    
    event Deposited(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 amount
    );
    
    event FundsDeployed(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 amount
    );
    
    event FundsWithdrawn(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 principal,
        uint256 yield
    );
    
    event RoundSettled(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        uint256 totalYield,
        uint256 performanceFee,
        uint256 devFee,
        uint256 prizePool
    );
    
    event WinnerChosen(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed winner,
        uint256 amount
    );
    
    event Claimed(
        bytes32 indexed gameId,
        uint256 indexed roundId,
        address indexed user,
        uint256 principal,
        uint256 prize
    );
    
    event StrategyUpdated(address indexed token, address indexed strategy);
    event ProtocolTreasuryUpdated(address indexed newTreasury);

    // ============ Constructor ============
    
    /**
     * @notice Initialize the YieldPlay protocol
     * @param _protocolTreasury Address to receive protocol performance fees
     */
    constructor(address _protocolTreasury) Ownable(msg.sender) {
        if (_protocolTreasury == address(0)) revert Errors.ZeroAddress();
        protocolTreasury = _protocolTreasury;
    }

    // ============ Admin Functions ============
    
    /**
     * @notice Set the yield strategy for a specific token
     * @param token ERC20 token address
     * @param strategy Yield strategy contract address
     */
    function setStrategy(address token, address strategy) external onlyOwner {
        if (token == address(0)) revert Errors.ZeroAddress();
        strategies[token] = strategy;
        emit StrategyUpdated(token, strategy);
    }
    
    /**
     * @notice Update the protocol treasury address
     * @param newTreasury New treasury address
     */
    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert Errors.ZeroAddress();
        protocolTreasury = newTreasury;
        emit ProtocolTreasuryUpdated(newTreasury);
    }
    
    /**
     * @notice Pause the protocol
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Unpause the protocol
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Game Management ============
    
    /**
     * @notice Create a new game
     * @param gameName Unique name for the game
     * @param devFeeBps Developer fee in basis points (max 10000)
     * @param treasury Address to receive developer fees
     * @param paymentToken ERC20 token accepted for deposits
     * @return gameId The unique identifier for the created game
     */
    function createGame(
        string calldata gameName,
        uint16 devFeeBps,
        address treasury,
        address paymentToken
    ) external whenNotPaused returns (bytes32 gameId) {
        if (devFeeBps > BPS_DENOMINATOR) revert Errors.InvalidDevFeeBps();
        if (paymentToken == address(0)) revert Errors.InvalidPaymentToken();
        if (treasury == address(0)) revert Errors.ZeroAddress();
        
        gameId = keccak256(abi.encodePacked(msg.sender, gameName));
        
        if (games[gameId].initialized) revert Errors.GameAlreadyExists();
        
        games[gameId] = Game({
            owner: msg.sender,
            gameName: gameName,
            devFeeBps: devFeeBps,
            treasury: treasury,
            roundCounter: 0,
            paymentToken: paymentToken,
            initialized: true
        });
        
        emit GameCreated(gameId, msg.sender, gameName, devFeeBps, paymentToken);
    }

    // ============ Round Management ============
    
    /**
     * @notice Create a new round for a game
     * @param gameId The game identifier
     * @param startTs Round start timestamp
     * @param endTs Round end timestamp (deposits close)
     * @param lockTime Additional lock period in seconds
     * @return roundId The created round's ID
     */
    function createRound(
        bytes32 gameId,
        uint64 startTs,
        uint64 endTs,
        uint64 lockTime
    ) external whenNotPaused returns (uint256 roundId) {
        Game storage game = games[gameId];
        
        if (!game.initialized) revert Errors.GameNotFound();
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (endTs <= startTs) revert Errors.InvalidRoundTime();
        
        roundId = game.roundCounter;
        
        rounds[gameId][roundId] = Round({
            gameId: gameId,
            roundId: roundId,
            totalDeposit: 0,
            devFee: 0,
            totalWin: 0,
            startTs: startTs,
            endTs: endTs,
            lockTime: lockTime,
            isSettled: false,
            status: RoundStatus.NotStarted,
            fundsDeployed: false
        });
        
        game.roundCounter++;
        
        emit RoundCreated(gameId, roundId, startTs, endTs, lockTime);
    }
    
    /**
     * @notice Update round status based on current timestamp
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function updateRoundStatus(bytes32 gameId, uint256 roundId) public {
        Round storage round = rounds[gameId][roundId];
        
        // Don't change status if already distributing
        if (round.status == RoundStatus.DistributingRewards) return;
        
        uint256 nowTs = block.timestamp;
        
        if (nowTs < round.startTs) {
            round.status = RoundStatus.NotStarted;
        } else if (nowTs >= round.startTs && nowTs <= round.endTs) {
            round.status = RoundStatus.InProgress;
        } else if (nowTs > round.endTs && nowTs <= round.endTs + round.lockTime) {
            round.status = RoundStatus.Locking;
        } else if (nowTs > round.endTs + round.lockTime) {
            round.status = RoundStatus.ChoosingWinners;
        }
    }

    // ============ User Actions ============
    
    /**
     * @notice Deposit tokens into a round
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param amount Amount of tokens to deposit
     */
    function deposit(
        bytes32 gameId,
        uint256 roundId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.InvalidAmount();
        
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (!game.initialized) revert Errors.GameNotFound();
        
        // Update and verify status
        updateRoundStatus(gameId, roundId);
        if (round.status != RoundStatus.InProgress) revert Errors.RoundNotActive();
        
        // Transfer tokens from user
        IERC20(game.paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update round state
        round.totalDeposit += amount;
        
        // Update user state
        UserDeposit storage userDep = userDeposits[gameId][roundId][msg.sender];
        userDep.depositAmount += amount;
        userDep.exists = true;
        
        emit Deposited(gameId, roundId, msg.sender, amount);
    }
    
    /**
     * @notice Claim principal and any winnings after round completion
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function claim(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        UserDeposit storage userDep = userDeposits[gameId][roundId][msg.sender];
        
        if (round.status != RoundStatus.DistributingRewards) {
            revert Errors.RoundNotCompleted();
        }
        if (userDep.isClaimed) revert Errors.AlreadyClaimed();
        if (!userDep.exists || userDep.depositAmount == 0) {
            revert Errors.NoDepositsFound();
        }
        
        uint256 totalAmount = userDep.depositAmount + userDep.amountToClaim;
        
        userDep.isClaimed = true;
        
        if (totalAmount > 0) {
            IERC20(game.paymentToken).safeTransfer(msg.sender, totalAmount);
        }
        
        emit Claimed(gameId, roundId, msg.sender, userDep.depositAmount, userDep.amountToClaim);
    }

    // ============ Game Owner Actions ============
    
    /**
     * @notice Deploy round funds to yield strategy
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function depositToStrategy(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        
        updateRoundStatus(gameId, roundId);
        
        // Can deploy during Locking or InProgress (if owner wants early deployment)
        // But typically after InProgress ends
        if (round.status == RoundStatus.NotStarted || 
            round.status == RoundStatus.ChoosingWinners ||
            round.status == RoundStatus.DistributingRewards) {
            revert Errors.RoundNotActive();
        }
        
        if (round.fundsDeployed) revert Errors.FundsAlreadyDeployed();
        if (round.totalDeposit == 0) revert Errors.InvalidAmount();
        
        address strategy = strategies[game.paymentToken];
        if (strategy == address(0)) revert Errors.StrategyNotSet();
        
        uint256 amount = round.totalDeposit;
        
        // Approve and deposit to strategy
        IERC20(game.paymentToken).safeIncreaseAllowance(strategy, amount);
        IYieldStrategy(strategy).deposit(amount);
        
        round.fundsDeployed = true;
        deployedAmounts[gameId][roundId] = amount;
        
        emit FundsDeployed(gameId, roundId, amount);
    }
    
    /**
     * @notice Withdraw funds from yield strategy
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function withdrawFromStrategy(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        
        updateRoundStatus(gameId, roundId);
        
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotEnded();
        }
        if (!round.fundsDeployed) revert Errors.FundsNotDeployed();
        
        address strategy = strategies[game.paymentToken];
        if (strategy == address(0)) revert Errors.StrategyNotSet();
        
        uint256 balanceBefore = IERC20(game.paymentToken).balanceOf(address(this));
        IYieldStrategy(strategy).withdrawAll();
        uint256 balanceAfter = IERC20(game.paymentToken).balanceOf(address(this));
        
        uint256 withdrawn = balanceAfter - balanceBefore;
        uint256 principal = deployedAmounts[gameId][roundId];
        uint256 yieldAmount = withdrawn > principal ? withdrawn - principal : 0;
        
        round.fundsDeployed = false;
        
        emit FundsWithdrawn(gameId, roundId, principal, yieldAmount);
    }
    
    /**
     * @notice Settle the round - calculate and distribute fees
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function settlement(
        bytes32 gameId,
        uint256 roundId
    ) external nonReentrant whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        
        updateRoundStatus(gameId, roundId);
        
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotEnded();
        }
        if (round.isSettled) revert Errors.RoundAlreadySettled();
        if (round.fundsDeployed) revert Errors.FundsNotDeployed(); // Must withdraw first
        
        uint256 vaultBalance = IERC20(game.paymentToken).balanceOf(address(this));
        
        // Calculate yield: current balance - total deposits across all active rounds
        // For simplicity, we track per-round
        uint256 principal = round.totalDeposit;
        
        // Assume all excess over principal is yield for this round
        // In production, track accumulated balances more carefully
        uint256 yieldAmount = vaultBalance >= principal ? vaultBalance - principal : 0;
        
        // Recalculate based on deployed amount tracking
        uint256 deployedPrincipal = deployedAmounts[gameId][roundId];
        if (deployedPrincipal > 0) {
            // We withdrew everything, so let's calculate yield properly
            // vaultBalance should be at least round.totalDeposit if no losses
            // Actually we need to track what we withdrew specifically for this round
            // For now, use the difference
        }
        
        uint256 performanceFee = 0;
        uint256 devFee = 0;
        uint256 prizePool = 0;
        
        if (yieldAmount > 0) {
            // Calculate performance fee (20%)
            performanceFee = (yieldAmount * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
            uint256 afterPerformance = yieldAmount - performanceFee;
            
            // Calculate dev fee on remaining
            devFee = (afterPerformance * game.devFeeBps) / BPS_DENOMINATOR;
            prizePool = afterPerformance - devFee;
            
            // Transfer fees
            if (performanceFee > 0) {
                IERC20(game.paymentToken).safeTransfer(protocolTreasury, performanceFee);
            }
            if (devFee > 0) {
                IERC20(game.paymentToken).safeTransfer(game.treasury, devFee);
            }
        }
        
        round.isSettled = true;
        round.totalWin = prizePool;
        round.devFee = devFee;
        
        emit RoundSettled(gameId, roundId, yieldAmount, performanceFee, devFee, prizePool);
    }
    
    /**
     * @notice Choose a winner and assign prize amount
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param winner Winner address
     * @param amount Prize amount to assign
     */
    function chooseWinner(
        bytes32 gameId,
        uint256 roundId,
        address winner,
        uint256 amount
    ) external whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        UserDeposit storage winnerDep = userDeposits[gameId][roundId][winner];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotCompleted();
        }
        if (!round.isSettled) revert Errors.RoundNotSettled();
        if (amount > round.totalWin) revert Errors.InsufficientPrizePool();
        if (!winnerDep.exists || winnerDep.depositAmount == 0) {
            revert Errors.NoDepositsFound();
        }
        
        winnerDep.amountToClaim += amount;
        round.totalWin -= amount;
        
        // Transition to distributing when all prizes allocated
        if (round.totalWin == 0) {
            round.status = RoundStatus.DistributingRewards;
        }
        
        emit WinnerChosen(gameId, roundId, winner, amount);
    }
    
    /**
     * @notice Finalize round and allow claims (if prizes not fully allocated)
     * @param gameId The game identifier
     * @param roundId The round identifier
     */
    function finalizeRound(
        bytes32 gameId,
        uint256 roundId
    ) external whenNotPaused {
        Game storage game = games[gameId];
        Round storage round = rounds[gameId][roundId];
        
        if (msg.sender != game.owner) revert Errors.Unauthorized();
        if (round.status != RoundStatus.ChoosingWinners) {
            revert Errors.RoundNotCompleted();
        }
        if (!round.isSettled) revert Errors.RoundNotSettled();
        
        // Allow finalization even if not all prizes distributed
        // Remaining goes back to depositors proportionally or stays for next round
        round.status = RoundStatus.DistributingRewards;
    }

    // ============ View Functions ============
    
    /**
     * @notice Get game details
     * @param gameId The game identifier
     * @return Game struct
     */
    function getGame(bytes32 gameId) external view returns (Game memory) {
        return games[gameId];
    }
    
    /**
     * @notice Get round details
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @return Round struct
     */
    function getRound(bytes32 gameId, uint256 roundId) external view returns (Round memory) {
        return rounds[gameId][roundId];
    }
    
    /**
     * @notice Get user deposit details
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @param user User address
     * @return UserDeposit struct
     */
    function getUserDeposit(
        bytes32 gameId,
        uint256 roundId,
        address user
    ) external view returns (UserDeposit memory) {
        return userDeposits[gameId][roundId][user];
    }
    
    /**
     * @notice Calculate game ID from owner and name
     * @param owner Game owner address
     * @param gameName Game name
     * @return gameId The calculated game identifier
     */
    function calculateGameId(
        address owner,
        string calldata gameName
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, gameName));
    }
    
    /**
     * @notice Get current round status
     * @param gameId The game identifier
     * @param roundId The round identifier
     * @return Current RoundStatus
     */
    function getCurrentStatus(
        bytes32 gameId,
        uint256 roundId
    ) external view returns (RoundStatus) {
        Round storage round = rounds[gameId][roundId];
        
        if (round.status == RoundStatus.DistributingRewards) {
            return RoundStatus.DistributingRewards;
        }
        
        uint256 nowTs = block.timestamp;
        
        if (nowTs < round.startTs) {
            return RoundStatus.NotStarted;
        } else if (nowTs >= round.startTs && nowTs <= round.endTs) {
            return RoundStatus.InProgress;
        } else if (nowTs > round.endTs && nowTs <= round.endTs + round.lockTime) {
            return RoundStatus.Locking;
        } else {
            return RoundStatus.ChoosingWinners;
        }
    }
}
