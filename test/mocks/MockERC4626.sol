// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal ERC4626 mock for testing. Wraps an underlying ERC20 with a configurable exchange rate.
///      Rate is expressed as basis points: 10000 = 1:1, 5000 = 2 assets per 1 share (shares worth more).
///      The rate determines how many shares you get per asset: shares = assets * rateBps / 10000.
contract MockERC4626 is ERC20 {
    address private _asset;
    uint256 private _rateBps; // 10000 = 1:1

    constructor(string memory name_, string memory symbol_, address asset_, uint256 rateBps_)
        ERC20(name_, symbol_)
    {
        _asset = asset_;
        _rateBps = rateBps_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    /// @dev Deposits `assets` of the underlying token and mints shares to `receiver`.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * _rateBps) / 10000;
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    /// @dev Sets the exchange rate (for testing non-1:1 scenarios).
    function setRate(uint256 rateBps_) external {
        _rateBps = rateBps_;
    }

    function getRate() external view returns (uint256) {
        return _rateBps;
    }
}
