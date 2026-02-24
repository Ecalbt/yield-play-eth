// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

/**
 * @title MockYieldStrategy
 * @notice Mock yield strategy for testing that simulates configurable yield
 * @dev DO NOT USE IN PRODUCTION - This is for testing only
 */
contract MockYieldStrategy is IYieldStrategy, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The underlying asset token
    IERC20 public immutable underlyingAsset;
    
    /// @notice The YieldPlay protocol address
    address public yieldPlay;
    
    /// @notice Total amount deposited
    uint256 public totalDeposited;
    
    /// @notice Simulated yield percentage in basis points (100 = 1%)
    uint256 public yieldRateBps;

    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();

    event Deposited(uint256 amount);
    event Withdrawn(uint256 assets);
    event YieldRateUpdated(uint256 newRate);

    modifier onlyYieldPlay() {
        if (msg.sender != yieldPlay) revert Unauthorized();
        _;
    }

    /**
     * @notice Initialize the mock strategy
     * @param _asset The underlying asset token
     * @param _yieldPlay The YieldPlay protocol address
     * @param _yieldRateBps Initial yield rate in basis points
     */
    constructor(
        address _asset,
        address _yieldPlay,
        uint256 _yieldRateBps
    ) Ownable(msg.sender) {
        if (_asset == address(0) || _yieldPlay == address(0)) {
            revert ZeroAddress();
        }
        
        underlyingAsset = IERC20(_asset);
        yieldPlay = _yieldPlay;
        yieldRateBps = _yieldRateBps;
    }

    /**
     * @notice Set the simulated yield rate
     * @param _yieldRateBps New yield rate in basis points
     */
    function setYieldRate(uint256 _yieldRateBps) external onlyOwner {
        yieldRateBps = _yieldRateBps;
        emit YieldRateUpdated(_yieldRateBps);
    }

    /**
     * @notice Update the YieldPlay address
     * @param _newYieldPlay New YieldPlay protocol address
     */
    function setYieldPlay(address _newYieldPlay) external onlyOwner {
        if (_newYieldPlay == address(0)) revert ZeroAddress();
        yieldPlay = _newYieldPlay;
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function deposit(uint256 amount) external override onlyYieldPlay returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        
        // Transfer from YieldPlay to this contract
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        
        emit Deposited(amount);
        return amount; // Return amount as "shares" for simplicity
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function withdrawAll() external override onlyYieldPlay returns (uint256 assets) {
        if (totalDeposited == 0) return 0;
        
        // Calculate assets with simulated yield
        assets = totalAssets();
        totalDeposited = 0;
        
        // Transfer back to YieldPlay
        underlyingAsset.safeTransfer(msg.sender, assets);
        
        emit Withdrawn(assets);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function totalAssets() public view override returns (uint256) {
        if (totalDeposited == 0) return 0;
        // Simulate yield: principal + (principal * yieldRate / 10000)
        return totalDeposited + (totalDeposited * yieldRateBps / 10000);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function asset() external view override returns (address) {
        return address(underlyingAsset);
    }

    /**
     * @notice Add yield tokens to strategy (for testing)
     * @param amount Amount of tokens to add as yield
     */
    function addYield(uint256 amount) external {
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Emergency withdraw - only owner
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(recipient, amount);
    }
}
