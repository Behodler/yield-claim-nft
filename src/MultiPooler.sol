// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniboostPooler} from "./interfaces/IUniboostPooler.sol";

/// @title MultiPooler
/// @notice Batch-pools across many `Uniboost` dispatchers in a single keeper transaction. Accepts
///         an array of `PoolCall` structs — each bundling one target `Uniboost` with its four pool
///         parameters — and forwards one `pool(...)` call per struct. This backs a UI form where an
///         operator fills in each dispatcher's pooling parameters (including how much of each to
///         use), one form row per struct, and submits the whole batch with one button.
/// @dev Holds no funds; it is a pure forwarder. Each target `Uniboost` holds and spends its own
///      retained prime. The batch is gated by a single owner-settable `pooler` address. The
///      MultiPooler address must itself be registered as an authorized pooler on each target
///      `Uniboost` (via that dispatcher's `setAuthorizedPooler`) for the forwarded calls to pass
///      `Uniboost.onlyAuthorizedPooler`. Guards live on this concrete contract per project convention.
contract MultiPooler is Ownable {
    /// @notice One batch row: a target `Uniboost` plus its four `pool(...)` parameters.
    struct PoolCall {
        address uniboost;
        uint256 amountIn;
        uint256 minPairOut;
        uint256 minTargetOut;
        uint256 minLP;
    }

    /// @notice The single authorized batch-caller. Owner-settable; `address(0)` disables batching.
    address public pooler;

    /// @notice Emitted when the authorized batch-caller is changed.
    event PoolerSet(address indexed previousPooler, address indexed newPooler);

    /// @notice Emitted after a successful batch, recording the caller and the number of rows.
    event BatchPooled(address indexed pooler, uint256 count);

    /// @notice Restricts the batch entry point to the single authorized `pooler`.
    modifier onlyPooler() {
        require(msg.sender == pooler, "MultiPooler: caller not pooler");
        _;
    }

    /// @param initialOwner The initial owner of this contract. `pooler` starts unset
    ///        (`address(0)`), which disables batch pooling until the owner sets it.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets the single authorized batch-caller. Only callable by owner. Passing
    ///         `address(0)` is allowed and disables batch pooling.
    /// @param newPooler The new pooler address (or `address(0)` to disable).
    function setPooler(address newPooler) external onlyOwner {
        address oldPooler = pooler;
        pooler = newPooler;
        emit PoolerSet(oldPooler, newPooler);
    }

    /// @notice Forwards one `pool(...)` call per row to each row's target `Uniboost`. All-or-nothing:
    ///         any single target's revert (e.g. unmet min-out, `amountIn > balance`, un-authorized
    ///         target, or paused dispatcher) bubbles up and reverts the entire batch.
    /// @param calls One `PoolCall` per target dispatcher; must be non-empty.
    function pool(PoolCall[] calldata calls) external onlyPooler {
        require(calls.length > 0, "MultiPooler: empty batch");
        for (uint256 i = 0; i < calls.length; i++) {
            PoolCall calldata c = calls[i];
            IUniboostPooler(c.uniboost).pool(c.amountIn, c.minPairOut, c.minTargetOut, c.minLP);
        }
        emit BatchPooled(msg.sender, calls.length);
    }
}
