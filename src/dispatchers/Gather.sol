// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";

/// @title Gather
/// @notice A token dispatcher that forwards received tokens to a configurable recipient address.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom.
///      The recipient address is updatable by the owner.
contract Gather is ATokenDispatcher {
    using SafeERC20 for IERC20;

    address private immutable _token;
    address private _recipient;

    /// @notice Emitted when the recipient address is updated.
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @param token_ The prime token this dispatcher acts on.
    /// @param recipient_ The initial address to forward tokens to.
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address token_, address recipient_, address initialOwner)
        ATokenDispatcher(initialOwner)
    {
        require(recipient_ != address(0), "Gather: zero recipient address");
        _token = token_;
        _recipient = recipient_;
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _token;
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

    /// @notice Forwards tokens (already on this contract) to the recipient.
    /// @param amount The FOT-adjusted amount of prime token to forward.
    function dispatch(
        address,
        uint256 amount,
        bytes calldata /* extraData */
    )
        external
        override
        onlyMinter
        whenNotPaused
    {
        IERC20(_token).safeTransfer(_recipient, amount);
    }
}
