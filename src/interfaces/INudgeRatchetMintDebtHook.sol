// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  INudgeRatchetMintDebtHook
/// @notice Consumer-facing surface of `NudgeRatchetMintDebtHook`. Lets the
///         configured recipient inspect the outstanding phUSD mint debt and
///         realise it by minting to themselves.
interface INudgeRatchetMintDebtHook {
    /// @notice Outstanding phUSD debt pending redemption via `pull()`.
    function mintDebt() external view returns (uint256);

    /// @notice Realise accumulated debt by minting phUSD to the configured
    ///         recipient and zeroing the debt ledger.
    function pull() external;

    /// @notice Unique type marker proving this is a NudgeRatchetMintDebtHook.
    ///         NudgeRatchet asserts this value on every dispatch so a missing or
    ///         wrong hook (e.g. the no-op DefaultDispatchHook) reverts loudly
    ///         instead of silently skipping mint-debt accrual. (Audit M-04)
    function hookTypeId() external pure returns (bytes32);
}
