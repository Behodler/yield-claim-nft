// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";

/// @title Gather
/// @notice A token dispatcher that forwards received tokens to a configurable recipient address.
/// @dev Pulls prime tokens from the minter and transfers them to the recipient.
///      The recipient address is updatable by the owner.
contract Gather is ATokenDispatcher {
    address private immutable _token;
    address private _recipient;
    string private _flavour;

    /// @notice Emitted when the recipient address is updated.
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @param token_ The prime token this dispatcher acts on.
    /// @param recipient_ The initial address to forward tokens to.
    /// @param flavour_ A human-readable metadata string describing this dispatcher.
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address token_, address recipient_, string memory flavour_, address initialOwner)
        ATokenDispatcher(initialOwner)
    {
        require(recipient_ != address(0), "Gather: zero recipient address");
        _token = token_;
        _recipient = recipient_;
        _flavour = flavour_;
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @inheritdoc ITokenDispatcher
    function flavour() external view returns (string memory) {
        return _flavour;
    }

    /// @notice Returns the current recipient address where tokens are forwarded.
    function recipient() external view returns (address) {
        return _recipient;
    }

    /// @notice Updates the recipient address. Only callable by the owner.
    /// @param newRecipient The new address to forward tokens to.
    function setRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Gather: zero recipient address");
        address oldRecipient = _recipient;
        _recipient = newRecipient;
        emit RecipientUpdated(oldRecipient, newRecipient);
    }

    /// @notice Pulls prime tokens from the minter and transfers them to the recipient.
    /// @param minter The NFTMinter contract address.
    /// @param amount The amount of prime token to gather.
    function dispatch(address minter, uint256 amount) external override whenNotPaused {
        // Pull the prime token from the minter
        IERC20(_token).transferFrom(minter, address(this), amount);

        // Forward to the recipient
        IERC20(_token).transfer(_recipient, amount);
    }
}
