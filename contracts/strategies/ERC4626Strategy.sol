// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IYieldStrategy} from "../interfaces/IYieldStrategy.sol";

/**
 * @title ERC4626Strategy
 * @notice Yield strategy that deposits into any ERC4626 compliant vault
 * @dev Compatible with Yearn V3, Aave V3 wrapped tokens, etc.
 */
contract ERC4626Strategy is IYieldStrategy, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The underlying asset token
    IERC20 public immutable underlyingAsset;
    
    /// @notice The ERC4626 vault to deposit into
    IERC4626 public immutable vault;
    
    /// @notice The YieldPlay protocol address
    address public yieldPlay;
    
    /// @notice Total shares held by this strategy
    uint256 public totalShares;

    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();

    event Deposited(uint256 amount, uint256 shares);
    event Withdrawn(uint256 assets, uint256 shares);
    event YieldPlayUpdated(address indexed newYieldPlay);

    modifier onlyYieldPlay() {
        if (msg.sender != yieldPlay) revert Unauthorized();
        _;
    }

    /**
     * @notice Initialize the ERC4626 strategy
     * @param _asset The underlying asset token
     * @param _vault The ERC4626 vault address
     * @param _yieldPlay The YieldPlay protocol address
     */
    constructor(
        address _asset,
        address _vault,
        address _yieldPlay
    ) Ownable(msg.sender) {
        if (_asset == address(0) || _vault == address(0) || _yieldPlay == address(0)) {
            revert ZeroAddress();
        }
        
        underlyingAsset = IERC20(_asset);
        vault = IERC4626(_vault);
        yieldPlay = _yieldPlay;
        
        // Max approve vault for deposits
        underlyingAsset.approve(_vault, type(uint256).max);
    }

    /**
     * @notice Update the YieldPlay address
     * @param _newYieldPlay New YieldPlay protocol address
     */
    function setYieldPlay(address _newYieldPlay) external onlyOwner {
        if (_newYieldPlay == address(0)) revert ZeroAddress();
        yieldPlay = _newYieldPlay;
        emit YieldPlayUpdated(_newYieldPlay);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function deposit(uint256 amount) external override onlyYieldPlay returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        
        // Transfer from YieldPlay to this contract
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Deposit into vault
        shares = vault.deposit(amount, address(this));
        totalShares += shares;
        
        emit Deposited(amount, shares);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function withdrawAll() external override onlyYieldPlay returns (uint256 assets) {
        if (totalShares == 0) return 0;
        
        uint256 sharesToRedeem = totalShares;
        totalShares = 0;
        
        // Redeem all shares for underlying assets
        assets = vault.redeem(sharesToRedeem, msg.sender, address(this));
        
        emit Withdrawn(assets, sharesToRedeem);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function totalAssets() external view override returns (uint256) {
        if (totalShares == 0) return 0;
        return vault.previewRedeem(totalShares);
    }

    /**
     * @inheritdoc IYieldStrategy
     */
    function asset() external view override returns (address) {
        return address(underlyingAsset);
    }

    /**
     * @notice Get current share balance
     * @return Number of vault shares held
     */
    function getShares() external view returns (uint256) {
        return totalShares;
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
