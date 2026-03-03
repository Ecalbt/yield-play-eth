// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC4626Vault
 * @notice A simple ERC4626 vault for testing on testnets
 * @dev Simulates yield by allowing owner to add yield to the vault
 */
contract MockERC4626Vault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint256 public yieldRate; // Basis points per day (e.g., 10 = 0.1% daily)
    uint256 public lastYieldTime;

    event YieldAdded(uint256 amount);
    event YieldRateUpdated(uint256 newRate);

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        yieldRate = 10; // Default 0.1% daily yield
        lastYieldTime = block.timestamp;
    }

    /**
     * @notice Owner can simulate yield by depositing extra tokens
     * @param amount Amount of underlying tokens to add as yield
     */
    function addYield(uint256 amount) external onlyOwner {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldAdded(amount);
    }

    /**
     * @notice Set the simulated yield rate
     * @param _yieldRate Yield rate in basis points per day
     */
    function setYieldRate(uint256 _yieldRate) external onlyOwner {
        yieldRate = _yieldRate;
        emit YieldRateUpdated(_yieldRate);
    }

    /**
     * @notice Get total assets including any simulated yield
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Rescue accidentally sent tokens (not the underlying asset)
     */
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != asset(), "Cannot rescue underlying asset");
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
