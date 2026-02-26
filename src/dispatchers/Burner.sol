// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";

/// @title Burner
/// @notice A token dispatcher that burns the prime token received from minting.
/// @dev Calls IBurnable.burn(amount) on the token after pulling it from the minter.
contract Burner is ATokenDispatcher {
    address private immutable _token;
    string private _flavour;

    constructor(address token_, string memory flavour_, address initialOwner) ATokenDispatcher(initialOwner) {
        _token = token_;
        _flavour = flavour_;
    }

    /// @inheritdoc ITokenDispatcher
    function tokensToApprove() external pure returns (address[] memory) {
        return new address[](0);
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @inheritdoc ITokenDispatcher
    function flavour() external view returns (string memory) {
        return _flavour;
    }

    /// @notice Pulls prime tokens from the minter and burns them.
    function dispatch(address minter, uint256 amount) external override whenNotPaused {
        // Pull the prime token from the minter
        IERC20(_token).transferFrom(minter, address(this), amount);

        // Burn the tokens
        IBurnable(_token).burn(amount);
    }
}
