// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBurnable
 * @notice Interface for tokens that support burning from msg.sender
 * @dev This matches the EYE token's burn function signature
 */
interface IBurnable {
    /**
     * @notice Burn tokens from the caller's balance
     * @param value Amount of tokens to burn
     */
    function burn(uint256 value) external;
}
