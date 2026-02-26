// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenDispatcher {
    /// @notice Returns the list of token addresses the dispatcher needs ERC20 approval for from the minter.
    function tokensToApprove() external view returns (address[] memory);

    /// @notice Returns the primary token this dispatcher acts on.
    function primeToken() external view returns (address);

    /// @notice Returns a human-readable metadata string describing this dispatcher (like ERC20 symbol).
    function flavour() external view returns (string memory);
}
