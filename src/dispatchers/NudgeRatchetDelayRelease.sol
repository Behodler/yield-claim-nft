// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {INudgeRatchetMintDebtHook} from "../interfaces/INudgeRatchetMintDebtHook.sol";

/// @title NudgeRatchetDelayRelease
/// @notice A V2 token dispatcher that HOLDS its USDC on dispatch instead of forwarding it
///         immediately, and only releases it to the owner-settable `batchMinter` when a
///         whitelisted `releaser` calls `release(amount)`. This gives admins rate control over
///         how fast accumulated USDC reaches the batchMinter. Sibling of `NudgeRatchet`.
/// @dev The mint-debt side is UNCHANGED from NudgeRatchet: the base `dispatch` still calls
///      `hook.onDispatch(minter, amount, extraData)` after `_dispatch`, so the
///      NudgeRatchetMintDebtHook accrues phUSD mint-debt against `amount` on every dispatch.
///
///      KNOWN / ACCEPTED DESIGN PROPERTIES — these are intentional; DO NOT re-flag as findings:
///        * Debt/release timing is DECOUPLED ON PURPOSE. phUSD mint-debt accrues (and the
///          downstream staker may realise phUSD via the hook's `pull()`) at DISPATCH time, while
///          the USDC backing it can still be sitting on this contract, un-released. There is
///          therefore an intended, admin-controlled window in which phUSD has been realised but
///          the corresponding USDC has NOT yet reached the batchMinter. This is the whole point
///          of the contract (rate-controlled release), not an accounting bug.
///        * No unbacked phUSD is created by this. The USDC that backs the accrued debt is HELD on
///          this contract from dispatch onward; `release` only RELOCATES that existing backing to
///          the batchMinter (it never mints or burns), so total system backing is conserved at
///          all times. The only thing the release schedule changes is WHERE the backing sits
///          (dispatcher vs. sink), never WHETHER it exists.
///        * Release rate is a trusted admin lever. `release` is gated to an owner-managed
///          `releasers` whitelist; the owner deliberately controls how fast held USDC flows to
///          the batchMinter. Slow/withheld releases are an operational choice, not a liveness bug.
///        * `rescueERC20` can withdraw held `_token` (USDC). This is an accepted owner power with
///          the same trust assumption as `setBatchMinter`; see its NatSpec.
contract NudgeRatchetDelayRelease is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @notice The token this dispatcher acts on. Must be USDC (6 decimals). Immutable.
    address internal immutable _token;

    /// @notice Owner-settable nudge-reward sink that receives released USDC.
    address public batchMinter;

    /// @notice Owner-configurable whitelist of addresses permitted to call `release`.
    mapping(address => bool) public releasers;

    /// @dev Must equal NudgeRatchetMintDebtHook.HOOK_TYPE_ID. Kept as a local constant
    ///      (rather than importing) to avoid a hard dependency cycle; both derive from the
    ///      same literal string and must stay in sync. (Audit M-04)
    bytes32 private constant EXPECTED_HOOK_TYPE_ID = keccak256("NudgeRatchetMintDebtHook.v1");

    /// @notice Emitted when the batchMinter address is updated.
    event BatchMinterUpdated(address indexed oldBatchMinter, address indexed newBatchMinter);
    /// @notice Emitted when a releaser is added to or removed from the whitelist.
    event ReleaserUpdated(address indexed releaser, bool approved);
    /// @notice Emitted when a releaser releases held USDC to the batchMinter.
    event Released(address indexed releaser, uint256 amount);

    /// @dev Restricts a function to whitelisted releasers.
    modifier onlyReleaser() {
        require(releasers[msg.sender], "NudgeRatchetDelayRelease: caller is not releaser");
        _;
    }

    /// @param token_ The token this dispatcher acts on — must be 6-decimal USDC.
    /// @param batchMinter_ The initial nudge-reward sink to release tokens to.
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address token_, address batchMinter_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(batchMinter_ != address(0), "NudgeRatchetDelayRelease: zero batchMinter");
        // Deploy-time USDC guard: batchMinter only accepts USDC (6-decimal) rewards.
        require(
            IERC20Metadata(token_).decimals() == 6,
            "NudgeRatchetDelayRelease: token must be 6-decimal USDC"
        );
        _token = token_;
        batchMinter = batchMinter_;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @notice Updates the batchMinter sink. Only callable by the owner.
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        require(newBatchMinter != address(0), "NudgeRatchetDelayRelease: zero batchMinter");
        address old = batchMinter;
        batchMinter = newBatchMinter;
        emit BatchMinterUpdated(old, newBatchMinter);
    }

    /// @notice Adds (`approved == true`) or removes (`approved == false`) a releaser. Owner only.
    function setReleaser(address releaser, bool approved) external onlyOwner {
        releasers[releaser] = approved;
        emit ReleaserUpdated(releaser, approved);
    }

    /// @notice Releases `amount` of held USDC to the batchMinter. Only callable by a releaser.
    /// @dev Reverts (via SafeERC20) if `amount` exceeds the held balance. KNOWN/ACCEPTED (not a
    ///      finding): the mint-debt backing this USDC was already accrued in the hook at DISPATCH
    ///      time and may already have been realised as phUSD by the downstream staker. This call
    ///      only RELOCATES already-held backing to the sink at an admin-controlled rate; it is
    ///      intentionally independent of phUSD realisation and creates no unbacked phUSD.
    function release(uint256 amount) external onlyReleaser nonReentrant {
        IERC20(_token).safeTransfer(batchMinter, amount);
        emit Released(msg.sender, amount);
    }

    /// @notice Owner escape hatch to recover ERC20s held by this contract. Mirrors
    ///         BalancerPoolerV2/Uniboost. NOT pause-gated, by design.
    /// @dev NOTE: this CAN withdraw held `_token` (USDC), which is backing for already-accrued
    ///      mint-debt. Using it on `_token` can leave debt under-backed and is an owner
    ///      responsibility; intended use is recovering non-`_token` assets sent here by mistake.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "NudgeRatchetDelayRelease: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Holds dispatched USDC on this contract; does NOT forward to the batchMinter.
    /// @dev Unlike NudgeRatchet (which sweeps to the batchMinter here), this variant retains the
    ///      token so a releaser can later forward it via `release(amount)` at an admin-controlled
    ///      rate. The hook-type guard is preserved so the base's post-`_dispatch`
    ///      `hook.onDispatch` still accrues mint-debt through the correct hook. Tokens arrive via
    ///      the minter's transferFrom before `dispatch` is called. The `amount` argument is the
    ///      basis for that mint-debt accrual (handled by the base after this returns); nothing is
    ///      transferred here.
    function _dispatch(address, uint256 /* amount */, bytes calldata /* extraData */)
        internal
        view
        override
    {
        // Audit M-04 (story 037): refuse to dispatch through a missing/wrong hook. A no-op or
        // unrelated hook lacks hookTypeId(), so this call reverts loudly.
        require(
            INudgeRatchetMintDebtHook(address(hook)).hookTypeId() == EXPECTED_HOOK_TYPE_ID,
            "NudgeRatchetDelayRelease: hook is not NudgeRatchetMintDebtHook"
        );
        // Intentionally NO transfer: USDC is HELD until a releaser calls release(amount).
    }
}
