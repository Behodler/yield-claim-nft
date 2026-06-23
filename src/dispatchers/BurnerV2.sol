// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";
import {IBurnRecorder} from "../interfaces/IBurnRecorder.sol";

/// @title BurnerV2
/// @notice A V2 token dispatcher that burns the token received from minting.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom. Calls IBurnable.burn(amount).
///      V2 removes primeToken() from the public interface.
contract BurnerV2 is ATokenDispatcherV2 {
    address internal immutable _token;
    IBurnRecorder private immutable _burnRecorder;

    constructor(address token_, address burnRecorder_, address initialOwner) ATokenDispatcherV2(initialOwner) {
        _token = token_;
        _burnRecorder = IBurnRecorder(burnRecorder_);
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @notice Burns tokens already on this contract and records the burn.
    /// @param amount The FOT-adjusted amount of token to burn.
    function _dispatch(
        address,
        uint256 amount,
        bytes calldata /* extraData */
    )
        internal
        override
    {
        IBurnable(_token).burn(amount);
        _burnRecorder.burn(_token, amount);
    }
}
