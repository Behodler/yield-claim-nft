// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniswapV2Factory (minimal)
/// @notice Minimal Uniswap V2 Factory interface — the canonical-pair lookup UniPoolerV2 uses to
///         bind its pair to the one its router actually trades against.
interface IUniswapV2Factory {
    /// @notice The canonical pair for `tokenA`/`tokenB` (either order), or address(0) if none.
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
