// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IUniboostMintDebtHook
/// @notice Consumer-facing surface of `UniboostMintDebtHook`. Lets the
///         configured recipient inspect the outstanding phUSD mint debt and
///         realise it by minting to themselves.
interface IUniboostMintDebtHook {
    /// @notice Outstanding phUSD debt pending redemption via `pull()`.
    function mintDebt() external view returns (uint256);

    /// @notice Realise accumulated debt by minting phUSD to the configured
    ///         recipient and zeroing the debt ledger.
    function pull() external;
}
