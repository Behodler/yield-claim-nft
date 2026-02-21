// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBurnable} from "../interfaces/IBurnable.sol";

/// @title Burner
/// @notice A token dispatcher that burns the prime token received from minting.
/// @dev Calls IBurnable.burn(amount) on the token after pulling it from the minter.
contract Burner is ITokenDispatcher, Ownable {
    address private immutable _token;
    string private _flavour;

    constructor(address token_, string memory flavour_, address initialOwner) Ownable(initialOwner) {
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

    /// @inheritdoc ITokenDispatcher
    function dispatch(address minter, uint256 amount) external {
        // Pull the prime token from the minter
        IERC20(_token).transferFrom(minter, address(this), amount);

        // Burn the tokens
        IBurnable(_token).burn(amount);
    }
}
