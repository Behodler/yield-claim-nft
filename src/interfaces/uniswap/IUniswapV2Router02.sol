// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV2Router02 (minimal)
/// @notice Minimal Uniswap V2 Router02 interface — the functions the dispatchers need
///         (`swapExactTokensForTokens` / `swapExactTokensForETH` / `swapExactETHForTokens`
///         for the buy legs, `addLiquidity` for the pool add, and `factory` for UniPoolerV2's
///         canonical-pair check).
interface IUniswapV2Router02 {
    /// @notice The Uniswap V2 factory whose pairs this router swaps and adds liquidity against.
    function factory() external view returns (address);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swaps `amountIn` of `path[0]` for native ETH (unwrapped from WETH), delivered to `to`.
    /// @dev `path` must end at WETH; the router unwraps and sends native ETH to `to`.
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swaps the attached native ETH for `path[last]`, delivered to `to`.
    /// @dev `path` must start at WETH; the router wraps the sent ETH into WETH first.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

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
