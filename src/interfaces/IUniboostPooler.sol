// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IUniboostPooler
/// @notice Minimal forwarding interface for the Uniboost-style `pool(...)` entry point.
/// @dev Covers only the 4-arg `pool(uint256,uint256,uint256,uint256)` shape introduced for the
///      parameterized pool amount. `BalancerPoolerV2.pool(uint256 minBPT)` has a DIFFERENT
///      signature and is intentionally NOT covered here — MultiPooler batches Uniboost-style
///      dispatchers only. Using a minimal interface avoids importing the full Uniboost dispatcher
///      (and its base / OZ dependencies) into MultiPooler.
interface IUniboostPooler {
    function pool(uint256 amountIn, uint256 minPairOut, uint256 minTargetOut, uint256 minLP) external;
}
