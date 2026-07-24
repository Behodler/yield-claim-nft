// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INudgeStreamer} from "phoenix-nft-staking/INudgeStreamer.sol";

/// @dev Minimal stand-in for `BatchNFTMinterMultiToken` covering only the surface the
///      `NudgeStreamer` needs from a nudge sink:
///
///        * `isNudgeToken(address)` — `NudgeStreamer.registerStream` calls this on the
///          target both to check the token is whitelisted AND (structurally) to reject
///          non-MultiToken targets. A plain EOA sink like `address(0xCAFE)` cannot be
///          registered, so dispatcher unit tests need at least this much of a contract.
///        * `pullPendingStream` forwarding — lets a unit test flush the accrued stream
///          the way the real batch-minter does in `batchMint` step 3.5.
///
///      The full-fidelity path (real `NudgeStreamer` + real `BatchNFTMinterMultiToken` +
///      real dispatchers) is exercised in `test/integration/NudgeStreamerDonorIntegration.t.sol`;
///      this mock exists only to keep the per-dispatcher unit suites lightweight.
contract MockNudgeBatchMinter {
    mapping(address => bool) public isNudgeToken;

    function setNudgeToken(address token, bool allowed) external {
        isNudgeToken[token] = allowed;
    }

    /// @dev Mirrors `BatchNFTMinterMultiToken`'s step-3.5 flush: the batch-minter is the
    ///      `msg.sender` the streamer settles to.
    function flush(address streamer, address token) external {
        INudgeStreamer(streamer).pullPendingStream(token);
    }
}
