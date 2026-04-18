// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDispatchHook} from "../../src/V2/interfaces/IDispatchHook.sol";

/// @dev Recording mock for IDispatchHook. Captures the last call's arguments and a
///      running call count for use in dispatcher-level tests.
contract MockDispatchHook is IDispatchHook {
    address public lastMinter;
    uint256 public lastAmount;
    bytes public lastExtraData;
    uint256 public callCount;

    function onDispatch(address minter, uint256 amount, bytes calldata extraData) external override {
        lastMinter = minter;
        lastAmount = amount;
        lastExtraData = extraData;
        callCount += 1;
    }
}

/// @dev Reverting hook — every `onDispatch` call reverts with a fixed string.
contract RevertingDispatchHook is IDispatchHook {
    function onDispatch(address, uint256, bytes calldata) external pure override {
        revert("RevertingDispatchHook: forced revert");
    }
}

/// @dev Reentrant hook — attempts to call `dispatch` on the supplied target inside
///      its own `onDispatch`. Used to assert `nonReentrant` on the external dispatch
///      blocks hook-initiated reentry.
interface IReentrantDispatchTarget {
    function dispatch(address minter, uint256 amount, bytes calldata extraData) external;
}

contract ReentrantDispatchHook is IDispatchHook {
    IReentrantDispatchTarget public target;

    function setTarget(IReentrantDispatchTarget target_) external {
        target = target_;
    }

    function onDispatch(address minter, uint256 amount, bytes calldata extraData) external override {
        target.dispatch(minter, amount, extraData);
    }
}
