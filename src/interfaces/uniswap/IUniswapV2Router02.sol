// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV2Router02 (minimal)
/// @notice Minimal Uniswap V2 Router02 interface — only the functions Uniboost needs
///         (`swapExactTokensForTokens` for the buy legs and `addLiquidity` for the pool add).
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
