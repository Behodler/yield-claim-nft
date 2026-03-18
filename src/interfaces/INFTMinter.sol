// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinter} from "./ITokenMinter.sol";

/// @notice Comprehensive interface for NFTMinter exposing all NFTMinter-specific
/// public functions (mint, burn, admin, views) for dependency injection.
interface INFTMinter is ITokenMinter {
    // --- Burn ---

    /// @notice Burns claim NFTs from a holder. Only callable by authorized burners.
    /// @param holder The address holding the NFTs to burn.
    /// @param tokenId The token ID to burn.
    /// @param quantity The number of tokens to burn.
    function burn(address holder, uint256 tokenId, uint256 quantity) external;

    /// @notice Returns whether an address is an authorized burner.
    /// @param burner The address to check.
    /// @return True if the address is authorized to burn.
    function authorizedBurners(address burner) external view returns (bool);

    /// @notice Sets or removes an address as an authorized burner. Only callable by owner.
    /// @param burner The address to authorize or deauthorize.
    /// @param authorized Whether the address is authorized to burn.
    function setAuthorizedBurner(address burner, bool authorized) external;

    // --- Admin ---

    /// @notice Sets the authorized pauser address. Only callable by owner.
    /// @param newPauser The new pauser address.
    function setPauser(address newPauser) external;

    /// @notice Enables or disables minting for a dispatcher. Only callable by owner.
    /// @param index The dispatcher index.
    /// @param disabled If true, new mints are blocked; if false, mints are re-enabled.
    function setDispatcherDisabled(uint256 index, bool disabled) external;

    /// @notice Rescues any ERC20 token stuck in this contract. Only callable by owner.
    /// @param token The ERC20 token address to withdraw.
    function emergencyWithdraw(address token) external;

    /// @notice Pauses or unpauses a registered dispatcher. Only callable by owner.
    /// @param dispatcher The dispatcher contract address.
    /// @param active If true, unpauses the dispatcher; if false, pauses it.
    function setDispatcherActive(address dispatcher, bool active) external;

    // --- Views ---

    /// @notice Whether the contract is currently paused.
    function paused() external view returns (bool);

    /// @notice Auto-incrementing dispatcher index (starts at 1 so 0 is invalid).
    function nextIndex() external view returns (uint256);

    /// @notice Maps dispatcher index to its configuration.
    /// @param index The dispatcher index.
    /// @return dispatcher The dispatcher contract address.
    /// @return price The current mint price.
    /// @return growthBasisPoints Price growth per mint in basis points.
    /// @return disabled Whether minting is disabled for this dispatcher.
    function configs(uint256 index) external view returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);

    /// @notice Maps dispatcher contract address to its index.
    /// @param dispatcher The dispatcher address.
    /// @return The dispatcher index.
    function dispatcherToIndex(address dispatcher) external view returns (uint256);

    /// @notice Reverse lookup: maps token ID to the dispatcher address that produces it.
    /// @param tokenId The token ID.
    /// @return The dispatcher address.
    function tokenIdToDispatcher(uint256 tokenId) external view returns (address);
}
