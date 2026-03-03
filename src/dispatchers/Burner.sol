// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";
import {IBurnRecorder} from "../interfaces/IBurnRecorder.sol";

/// @title Burner
/// @notice A token dispatcher that burns the prime token received from minting.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom. Calls IBurnable.burn(amount).
contract Burner is ATokenDispatcher {
    address private immutable _token;
    IBurnRecorder private immutable _burnRecorder;
    string private _flavour;

    constructor(address token_, string memory flavour_, address burnRecorder_, address initialOwner) ATokenDispatcher(initialOwner) {
        _token = token_;
        _flavour = flavour_;
        _burnRecorder = IBurnRecorder(burnRecorder_);
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @inheritdoc ITokenDispatcher
    function flavour() external view returns (string memory) {
        return _flavour;
    }

    /// @notice Burns tokens already on this contract and records the burn.
    /// @param amount The FOT-adjusted amount of prime token to burn.
    function dispatch(address, uint256 amount, bytes calldata /* extraData */) external override onlyMinter whenNotPaused {
        IBurnable(_token).burn(amount);
        _burnRecorder.burn(_token, amount);
    }
}
