// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBurnRecorder} from "./interfaces/IBurnRecorder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BurnRecorder
/// @notice A shared recorder for burn events across all burn dispatchers.
/// @dev Provides a unified event log and cumulative burn tracking per token.
///      The tokenIndex mapping simulates an array for enumeration of registered tokens.
contract BurnRecorder is IBurnRecorder, Ownable {
    /// @notice Mapping of authorized burner addresses that can record burns.
    mapping(address => bool) private _burners;

    /// @notice Cumulative amount burned per token address.
    mapping(address => uint256) private totalBurnt;

    /// @notice Maps an index to a token address for enumeration.
    mapping(uint256 => address) private tokenIndex;

    /// @notice The number of registered tokens (next available index).
    uint256 private _latestIndex;

    /// @notice Emitted when a burn is recorded.
    /// @param token The address of the token that was burned.
    /// @param quantity The amount of tokens burned in this event.
    /// @param timestamp The block timestamp when the burn was recorded.
    event tokenBurnt(address indexed token, uint256 quantity, uint256 timestamp);

    /// @notice Restricts function access to authorized burners.
    modifier onlyBurner() {
        require(_burners[msg.sender], "BurnRecorder: caller is not burner");
        _;
    }

    /// @param initialOwner The initial owner of this contract.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets or revokes an authorized burner address.
    /// @param burner_ The address of the burner contract.
    /// @param approved_ Whether the address is authorized as a burner.
    function setBurner(address burner_, bool approved_) external onlyOwner {
        _burners[burner_] = approved_;
    }

    /// @notice Records a burn event for a given token and amount.
    /// @dev Accumulates the total burned for the token and emits a tokenBurnt event.
    /// @param token The address of the token that was burned.
    /// @param amount The amount of tokens burned.
    function burn(address token, uint256 amount) external onlyBurner {
        totalBurnt[token] += amount;
        emit tokenBurnt(token, amount, block.timestamp);
    }

    /// @notice Returns the cumulative amount burned for a given token.
    /// @param token The address of the token to query.
    /// @return The total amount burned for the token.
    function getTotalBurnt(address token) public view returns (uint256) {
        return totalBurnt[token];
    }

    /// @notice Registers a token address for enumeration.
    /// @dev Only callable by the owner. Adds the token to the tokenIndex mapping.
    /// @param token The address of the token to register.
    function registerToken(address token) external onlyOwner {
        tokenIndex[_latestIndex] = token;
        _latestIndex++;
    }

    /// @notice Returns the number of registered tokens.
    /// @return The count of registered tokens.
    function getTokenCount() public view returns (uint256) {
        return _latestIndex;
    }

    /// @notice Returns the token address at a given index.
    /// @param index The index to query.
    /// @return The token address at the given index.
    function getTokenAtIndex(uint256 index) public view returns (address) {
        return tokenIndex[index];
    }
}
