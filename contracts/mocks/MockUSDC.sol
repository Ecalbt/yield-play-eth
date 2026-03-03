// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice A simple mock USDC token for testing on testnets
 * @dev Anyone can mint tokens for testing (faucet-style)
 */
contract MockUSDC is ERC20, Ownable {
    uint8 private _decimals;
    uint256 public constant MAX_MINT_AMOUNT = 10000 * 10**6; // 10,000 USDC per mint
    
    mapping(address => uint256) public lastMintTime;
    uint256 public mintCooldown = 1 hours;

    event Minted(address indexed to, uint256 amount);

    constructor() ERC20("Mock USDC", "mUSDC") Ownable(msg.sender) {
        _decimals = 6; // USDC has 6 decimals
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Faucet - anyone can mint tokens (with cooldown)
     * @param amount Amount to mint (max 10,000 USDC)
     */
    function mint(uint256 amount) external {
        require(amount <= MAX_MINT_AMOUNT, "Exceeds max mint amount");
        require(
            block.timestamp >= lastMintTime[msg.sender] + mintCooldown,
            "Mint cooldown not passed"
        );
        
        lastMintTime[msg.sender] = block.timestamp;
        _mint(msg.sender, amount);
        emit Minted(msg.sender, amount);
    }

    /**
     * @notice Owner can mint any amount (for initial setup)
     */
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    /**
     * @notice Owner can update mint cooldown
     */
    function setMintCooldown(uint256 _cooldown) external onlyOwner {
        mintCooldown = _cooldown;
    }

    /**
     * @notice Disable cooldown for testing
     */
    function disableCooldown() external onlyOwner {
        mintCooldown = 0;
    }
}
