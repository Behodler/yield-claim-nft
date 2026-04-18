// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDispatchHook
/// @notice Observation hook invoked by V2 dispatchers after `_dispatch` completes.
/// @dev    Called with the same `(minter, amount, extraData)` tuple forwarded to
///         `ATokenDispatcherV2.dispatch`. Implementations must not rely on any
///         storage state of the dispatcher and must be prepared for arbitrary
///         `extraData` payloads. A reverting hook reverts the enclosing dispatch.
interface IDispatchHook {
    function onDispatch(address minter, uint256 amount, bytes calldata extraData) external;
}
