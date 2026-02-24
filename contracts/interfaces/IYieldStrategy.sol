// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IYieldStrategy
 * @notice Interface for yield-generating strategies
 */
interface IYieldStrategy {
    /**
     * @notice Deposit assets into the yield strategy
     * @param amount Amount of underlying asset to deposit
     * @return shares Amount of shares/receipt tokens received
     */
    function deposit(uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw all assets from the yield strategy
     * @return assets Amount of underlying assets withdrawn
     */
    function withdrawAll() external returns (uint256 assets);

    /**
     * @notice Get the current balance including unrealized yield
     * @return Total assets that would be received on full withdrawal
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Get the underlying asset address
     * @return Address of the underlying ERC20 token
     */
    function asset() external view returns (address);
}
