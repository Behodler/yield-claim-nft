// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IBalancerPoolerMintDebtHook
/// @notice Consumer-facing surface of `BalancerPoolerMintDebtHook`. Lets the
///         configured recipient inspect the outstanding phUSD mint debt and
///         realise it by minting to themselves.
interface IBalancerPoolerMintDebtHook {
    /// @notice Outstanding phUSD debt pending redemption via `pull()`.
    function mintDebt() external view returns (uint256);

    /// @notice Realise accumulated debt by minting phUSD to the configured
    ///         recipient and zeroing the debt ledger.
    function pull() external;
}
