// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {INudgeRatchetMintDebtHook} from "../interfaces/INudgeRatchetMintDebtHook.sol";

/// @title NudgeRatchet
/// @notice A V2 token dispatcher that forwards its USDC token to an owner-settable
///         `batchMinter` address — the nudge-reward sink. Modeled on `GatherV2`.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom; `_dispatch`
///      only forwards the already-present balance with a single `safeTransfer`. The
///      `batchMinter` sink only accepts USDC, so the constructor enforces a 6-decimal
///      deploy-time guard on the token. The base `dispatch` applies the
///      `nonReentrant`/`onlyMinter`/`whenNotPaused` modifier chain.
contract NudgeRatchet is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @notice The token this dispatcher forwards. Must be USDC (6 decimals). Immutable.
    address internal immutable _token;

    /// @notice Owner-settable nudge-reward sink that receives forwarded USDC.
    address public batchMinter;

    /// @dev Must equal NudgeRatchetMintDebtHook.HOOK_TYPE_ID. Kept as a local
    ///      constant (rather than importing) to avoid a hard dependency cycle;
    ///      both derive from the same literal string and must stay in sync. (Audit M-04)
    bytes32 private constant EXPECTED_HOOK_TYPE_ID = keccak256("NudgeRatchetMintDebtHook.v1");

    /// @notice Emitted when the batchMinter address is updated.
    event BatchMinterUpdated(address indexed oldBatchMinter, address indexed newBatchMinter);

    /// @param token_ The token this dispatcher acts on — must be 6-decimal USDC.
    /// @param batchMinter_ The initial nudge-reward sink to forward tokens to.
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address token_, address batchMinter_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(batchMinter_ != address(0), "NudgeRatchet: zero batchMinter");
        // Deploy-time USDC guard: batchMinter only accepts USDC (6-decimal) rewards.
        require(IERC20Metadata(token_).decimals() == 6, "NudgeRatchet: token must be 6-decimal USDC");
        _token = token_;
        batchMinter = batchMinter_;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @notice Updates the batchMinter sink. Only callable by the owner.
    /// @param newBatchMinter The new nudge-reward sink address. Must be non-zero.
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        require(newBatchMinter != address(0), "NudgeRatchet: zero batchMinter");
        address old = batchMinter;
        batchMinter = newBatchMinter;
        emit BatchMinterUpdated(old, newBatchMinter);
    }

    /// @notice Forwards this contract's USDC to the batchMinter.
    /// @dev DESIGN: this sweeps the FULL token balance, not the `amount` argument.
    ///      Rationale and known/accepted properties (do not re-flag as findings):
    ///        * Self-cleaning: any USDC sent here out-of-band (mistaken transfers,
    ///          airdrops) is forwarded on the next dispatch, so no rescueERC20
    ///          escape hatch is needed for `_token`. (Non-`_token` assets are out of
    ///          scope and intentionally have no recovery path on this contract.)
    ///        * Debt/transfer decoupling is INTENTIONAL. The base dispatcher accrues
    ///          mint-debt in the hook against `amount` (see ATokenDispatcherV2.dispatch
    ///          -> hook.onDispatch), while this transfers the actual balance. The two
    ///          quantities differ only when stray USDC is present.
    ///        * Surplus is SAFE and protocol-favouring: balance > amount means the
    ///          batchMinter receives more USDC than debt was recorded for, i.e. the
    ///          protocol is over-backed. No unbacked phUSD is ever created this way.
    ///        * The hook's DebtAccrued event therefore reports `amount`, which may be
    ///          below the USDC actually forwarded when stray funds exist. This is a
    ///          known, accepted reporting nuance, not a discrepancy bug; it always
    ///          errs toward over-backing.
    /// @param amount Minimum balance required to dispatch AND the basis for mint-debt
    ///        accrual in the hook. NOT necessarily the exact quantity transferred.
    function _dispatch(address, uint256 amount, bytes calldata /* extraData */) internal override {
        // Audit M-04 (story 037): refuse to dispatch through a missing/wrong hook. A
        // no-op or unrelated hook lacks hookTypeId(), so this call reverts loudly.
        require(
            INudgeRatchetMintDebtHook(address(hook)).hookTypeId() == EXPECTED_HOOK_TYPE_ID,
            "NudgeRatchet: hook is not NudgeRatchetMintDebtHook"
        );

        uint256 bal = IERC20(_token).balanceOf(address(this));
        // Defense-in-depth, NOT the load-bearing guard: NFTMinter already guarantees
        // the deposited balance covers `amount` before calling dispatch. We re-assert
        // it locally because debt accrues against `amount` in the hook, so forwarding
        // LESS than `amount` would be the one direction that mints unbacked phUSD.
        // Cheap, redundant, and documents the invariant at the point it matters.
        require(bal >= amount, "NudgeRatchet: insufficient balance for dispatch");

        // Sweep the full balance (>= amount). Surplus, if any, is over-backing.
        IERC20(_token).safeTransfer(batchMinter, bal);
    }
}
