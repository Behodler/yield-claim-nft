// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenDispatcher {
    /// @notice Returns the primary token this dispatcher acts on.
    function primeToken() external view returns (address);

    /// @notice Returns the name metadata for this dispatcher.
    function name() external view returns (string memory);

    /// @notice Returns the image metadata for this dispatcher.
    function image() external view returns (string memory);

    /// @notice Returns the description metadata for this dispatcher.
    function description() external view returns (string memory);
}
