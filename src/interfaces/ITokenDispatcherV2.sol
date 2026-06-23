// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenDispatcherV2 {
    /// @notice Returns the authoritative prime token address for this dispatcher.
    function primeToken() external view returns (address);

    /// @notice Returns the name metadata for this dispatcher.
    function name() external view returns (string memory);

    /// @notice Returns the image metadata for this dispatcher.
    function image() external view returns (string memory);

    /// @notice Returns the description metadata for this dispatcher.
    function description() external view returns (string memory);
}
