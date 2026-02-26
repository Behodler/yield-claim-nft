// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";

/// @title Accumulator
/// @notice A no-op token dispatcher. Tokens simply accumulate in the minter.
/// @dev Used for tokens like sUSDS that are consumed by other dispatchers (e.g., BalancerPooler).
contract Accumulator is ATokenDispatcher {
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

    /// @notice No-op: tokens stay in the minter and accumulate.
    function dispatch(address, uint256) external override whenNotPaused {
        // No-op: tokens stay in the minter and accumulate
    }
}
