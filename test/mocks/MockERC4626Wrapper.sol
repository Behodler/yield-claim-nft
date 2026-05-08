// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal ERC4626-shaped wrapper mock used to stand in for the on-chain
///      "Wrapped Aave Ethereum USDC" (waUSDC). Exposes a configurable share-to-asset
///      rate and only the methods BalancerPoolerV2 actually uses (`asset()` and
///      `redeem(shares, receiver, owner)`).
///
///      `decimals()` is configurable so a 6-decimal token like waUSDC can be modelled.
///
///      `rateBps`: 10000 = 1:1 (1 share == 1 asset). 5000 = 0.5 assets per share, etc.
///      Asset payout = (shares * rateBps) / 10000.
contract MockERC4626Wrapper is ERC20 {
    address private immutable _asset;
    uint8 private immutable _decimals;
    uint256 public rateBps;

    constructor(string memory name_, string memory symbol_, address asset_, uint8 decimals_, uint256 rateBps_)
        ERC20(name_, symbol_)
    {
        _asset = asset_;
        _decimals = decimals_;
        rateBps = rateBps_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setRate(uint256 rateBps_) external {
        rateBps = rateBps_;
    }

    /// @dev Test helper: mint shares to an address (no underlying transfer).
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }

    /// @dev Burn `shares` from `owner` and transfer (`shares * rateBps / 10000`) of the
    ///      underlying asset to `receiver`. Does not enforce ERC20 allowance from
    ///      `owner` -> `msg.sender` because the production caller (BalancerPoolerV2)
    ///      always invokes with `owner == address(this)`.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _burn(owner, shares);
        assets = (shares * rateBps) / 10000;
        IERC20(_asset).transfer(receiver, assets);
    }
}
