// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";

/// @title Burner
/// @notice A token dispatcher that burns the prime token received from minting.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom. Calls IBurnable.burn(amount).
contract Burner is ATokenDispatcher {
    address private immutable _token;
    string private _flavour;

    constructor(address token_, string memory flavour_, address initialOwner) ATokenDispatcher(initialOwner) {
        _token = token_;
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

    /// @notice Burns tokens already on this contract.
    /// @param amount The FOT-adjusted amount of prime token to burn.
    function dispatch(address, uint256 amount) external override onlyMinter whenNotPaused {
        IBurnable(_token).burn(amount);
    }
}
