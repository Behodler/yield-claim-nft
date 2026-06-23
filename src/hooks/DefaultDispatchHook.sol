// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDispatchHook} from "../interfaces/IDispatchHook.sol";

/// @title DefaultDispatchHook
/// @notice Null-object implementation of IDispatchHook. Used by ATokenDispatcherV2
///         at construction time so the `hook` state variable is never the zero
///         address and dispatch can call `hook.onDispatch(...)` unconditionally.
contract DefaultDispatchHook is IDispatchHook {
    /// @inheritdoc IDispatchHook
    function onDispatch(address, uint256, bytes calldata) external {}
}
