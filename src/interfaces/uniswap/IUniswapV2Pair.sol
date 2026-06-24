// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV2Pair (minimal)
/// @notice Minimal Uniswap V2 Pair interface — only the token accessors Uniboost needs to
///         derive the pairing token from a target pool.
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}
