// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV2Pair (minimal)
/// @notice Minimal Uniswap V2 Pair interface — the token accessors Uniboost needs to derive the
///         pairing token from a target pool, plus the reserve/supply views UniPoolerV2 uses to size
///         its zap on-chain and to quote the expected LP.
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
}
