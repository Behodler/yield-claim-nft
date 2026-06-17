// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDispatchHook} from "../interfaces/IDispatchHook.sol";
import {INudgeRatchetMintDebtHook} from "../interfaces/INudgeRatchetMintDebtHook.sol";
import {IMintable} from "../../interfaces/IMintable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  NudgeRatchetMintDebtHook
/// @notice `IDispatchHook` implementation that accrues a phUSD *mint debt* on every
///         dispatch routed through a specific `NudgeRatchet`. The debt equals
///         `ratio`% of the USDC `amount` forwarded by the dispatcher. A later
///         call to `pull()` by the owner or the configured `recipient` realises
///         the debt by minting phUSD to `recipient` and zeroing the ledger.
/// @dev    `dispatcher` is mutable storage — seeded in the constructor to the
///         live `NudgeRatchet` that will call `onDispatch`, and owner-repointable
///         via `setDispatcher` so a future dispatcher swap does not require redeploying
///         the hook. `onDispatch` is gated to the current dispatcher so no external
///         caller can inflate the debt. Trust model is unchanged: the owner is already
///         fully trusted, so a repointable dispatcher adds no new risk.
contract NudgeRatchetMintDebtHook is IDispatchHook, INudgeRatchetMintDebtHook, Ownable, ReentrancyGuard {
    /// @notice Inclusive upper bound on `ratio` (200%). The maximum settable ratio is
    ///         `MAX_RATIO` itself — `setRatio(200)` is allowed, only `> MAX_RATIO` reverts.
    uint8 public constant MAX_RATIO = 200;

    /// @notice Default ratio applied when the hook is first deployed (100%).
    uint8 public constant DEFAULT_RATIO = 100;

    /// @notice Unique identity marker for this hook type. (Audit M-04)
    bytes32 public constant HOOK_TYPE_ID = keccak256("NudgeRatchetMintDebtHook.v1");

    /// @dev USDC has 6 decimals; phUSD has 18. `mintDebt` is denominated in phUSD wei,
    ///      so the 6-decimal dispatched amount is scaled up by `10**(18-6) = 1e12`.
    ///      Mirrors `ISkyPSM.to18ConversionFactor()` (`1e12` for 6-decimal USDC). The
    ///      scale is a fixed constant because `NudgeRatchet` hard-guards its token to
    ///      exactly 6 decimals at deploy and phUSD is the protocol's own 18-decimal token.
    uint256 internal constant USDC_TO_PHUSD_SCALE = 1e12;

    /// @notice The dispatcher permitted to call `onDispatch`. Owner-repointable
    ///         via `setDispatcher` so future dispatcher swaps reuse this hook.
    address public dispatcher;

    /// @notice The phUSD (or compatible) mintable token. Immutable.
    IMintable public immutable phUSD;

    /// @notice The address credited by `pull()`. Zero until an owner sets it.
    address public recipient;

    /// @notice Accrued phUSD debt pending redemption via `pull()`.
    uint256 public mintDebt;

    /// @notice Percentage of dispatched USDC that becomes debt. May be any value in
    ///         the inclusive range `[0, MAX_RATIO]` (i.e. `0` through `200`).
    uint8 public ratio;

    event RatioUpdated(uint8 oldRatio, uint8 newRatio);
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DebtAccrued(address indexed minter, uint256 dispatchedAmount, uint256 debtAdded, uint256 newTotalDebt);
    event DebtPulled(address indexed recipient, uint256 amount);
    event DispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);

    error OnlyDispatcher();
    error OnlyOwnerOrRecipient();
    error RecipientUnset();
    error RatioTooHigh();

    modifier onlyOwnerOrRecipient() {
        if (msg.sender != owner() && msg.sender != recipient) {
            revert OnlyOwnerOrRecipient();
        }
        _;
    }

    /// @param initialOwner Address granted `Ownable` ownership of the hook.
    /// @param dispatcher_  The NudgeRatchet instance permitted to call `onDispatch`.
    /// @param phUSD_       The mintable phUSD token minted to `recipient` on `pull`.
    constructor(address initialOwner, address dispatcher_, address phUSD_) Ownable(initialOwner) {
        require(dispatcher_ != address(0), "dispatcher=0");
        require(phUSD_ != address(0), "phUSD=0");
        dispatcher = dispatcher_;
        phUSD = IMintable(phUSD_);
        ratio = DEFAULT_RATIO;
        emit RatioUpdated(0, DEFAULT_RATIO);
    }

    /// @notice Update the mint-debt ratio. Only callable by owner.
    /// @param  newRatio The new percentage. Must be `<= MAX_RATIO` (200); the bound is
    ///         inclusive, so `200` is accepted and only values strictly above it revert.
    function setRatio(uint8 newRatio) external onlyOwner {
        if (newRatio > MAX_RATIO) revert RatioTooHigh();
        uint8 old = ratio;
        ratio = newRatio;
        emit RatioUpdated(old, newRatio);
    }

    /// @notice Update the `recipient` credited by `pull()`. Only callable by owner.
    /// @dev    Zero is allowed — re-arms the hook. `pull()` reverts while zero.
    /// @param  newRecipient The new recipient address, or `address(0)` to unset.
    function setRecipient(address newRecipient) external onlyOwner {
        address old = recipient;
        recipient = newRecipient;
        emit RecipientUpdated(old, newRecipient);
    }

    /// @notice Repoint the dispatcher permitted to call `onDispatch`. Only owner.
    /// @dev    Lets a future dispatcher swap reuse this hook without a redeploy.
    ///         Operationally, `pull()` the outstanding `mintDebt` before repointing so
    ///         the ledger is clean across the swap. Trust model unchanged (owner-only).
    /// @param  newDispatcher The replacement dispatcher. Must be non-zero.
    function setDispatcher(address newDispatcher) external onlyOwner {
        require(newDispatcher != address(0), "dispatcher=0");
        address old = dispatcher;
        dispatcher = newDispatcher;
        emit DispatcherUpdated(old, newDispatcher);
    }

    /// @inheritdoc IDispatchHook
    /// @dev Gated to `dispatcher` to prevent unbounded phUSD debt inflation by
    ///      arbitrary callers. Silent no-op when `added == 0` (zero ratio or
    ///      small-amount rounding) so the debt ledger never emits empty events.
    function onDispatch(address minter, uint256 amount, bytes calldata) external {
        if (msg.sender != dispatcher) revert OnlyDispatcher();
        // Scale 6-dp USDC up to 18-dp phUSD before applying the ratio. Multiply-then-divide
        // keeps full precision and floors the result, so any sub-wei remainder accrues to
        // the protocol (never over-credits).
        uint256 added = (amount * USDC_TO_PHUSD_SCALE * ratio) / 100;
        if (added == 0) return;
        mintDebt += added;
        emit DebtAccrued(minter, amount, added, mintDebt);
    }

    /// @notice Realise accumulated debt by minting phUSD to `recipient` and
    ///         zeroing the debt ledger. Only callable by owner or recipient.
    /// @dev    No-op when `mintDebt == 0`; reverts when `recipient == address(0)`.
    function pull() external onlyOwnerOrRecipient nonReentrant {
        if (recipient == address(0)) revert RecipientUnset();
        uint256 debt = mintDebt;
        if (debt == 0) return;
        mintDebt = 0;
        phUSD.mint(recipient, debt);
        emit DebtPulled(recipient, debt);
    }

    /// @inheritdoc INudgeRatchetMintDebtHook
    function hookTypeId() external pure returns (bytes32) {
        return HOOK_TYPE_ID;
    }
}
