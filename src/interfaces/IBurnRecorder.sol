// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBurnRecorder {
    /// @notice Records a burn event for a given token and amount.
    /// @param token The address of the token that was burned.
    /// @param amount The amount of tokens burned.
    function burn(address token, uint256 amount) external;

    /// @notice Sets the authorized burner address.
    /// @param burner_ The address of the burner contract.
    function setBurner(address burner_) external;
}
