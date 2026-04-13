// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenMinterV2 {
    /// @notice Mints a claim NFT by paying with a registered protocol token.
    /// @param token The ERC20 token address to pay with.
    /// @param index The dispatcher index to route the payment to.
    /// @param recipient The address that receives the claim NFT.
    /// @return success True if the mint was successful.
    function mint(address token, uint256 index, address recipient) external returns (bool);

    /// @notice Mints a claim NFT, forwarding arbitrary extra data to the dispatcher.
    /// @param token The ERC20 token address to pay with.
    /// @param index The dispatcher index to route the payment to.
    /// @param recipient The address that receives the claim NFT.
    /// @param extraData Dispatcher-specific encoded data (e.g. slippage parameters).
    /// @return success True if the mint was successful.
    function mint(address token, uint256 index, address recipient, bytes calldata extraData) external returns (bool);

    /// @notice Registers a new token dispatcher. Only callable by owner.
    /// @param dispatcher The dispatcher contract address.
    /// @param initialPrice The initial mint price in token units.
    /// @param growthBasisPoints Price growth per mint in basis points (100 = 1%).
    function registerDispatcher(address dispatcher, uint256 initialPrice, uint256 growthBasisPoints) external;

    /// @notice Returns the current mint price for a given dispatcher index.
    /// @param index The dispatcher index.
    /// @return The current price in token units.
    function getPrice(uint256 index) external view returns (uint256);

    /// @notice Sets the mint price for a given dispatcher index. Only callable by owner.
    /// @param index The dispatcher index.
    /// @param newPrice The new price in token units.
    function setPrice(uint256 index, uint256 newPrice) external;

    /// @notice Sets the growth factor for a given dispatcher index. Only callable by owner.
    /// @param index The dispatcher index.
    /// @param newGrowthBasisPoints The new growth factor in basis points.
    function setGrowthFactor(uint256 index, uint256 newGrowthBasisPoints) external;
}
