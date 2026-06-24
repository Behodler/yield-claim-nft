// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDispatchHook} from "../interfaces/IDispatchHook.sol";
import {IUniboostMintDebtHook} from "../interfaces/IUniboostMintDebtHook.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title  UniboostMintDebtHook
/// @notice `IDispatchHook` implementation that accrues a phUSD *mint debt* on every
///         dispatch routed through a specific `Uniboost` dispatcher. The debt equals
///         `ratio`% of the prime-token `amount` forwarded by the dispatcher, scaled
///         from the prime token's decimals up to phUSD's 18 decimals. A later
///         call to `pull()` by the owner or the configured `recipient` realises
///         the debt by minting phUSD to `recipient` and zeroing the ledger.
/// @dev    Mirrors `BalancerPoolerMintDebtHook` exactly, but is prime-decimals-aware:
///         the constructor reads `IERC20Metadata(primeToken_).decimals()` once and sets
///         the immutable `scale = 10 ** (18 - decimals)`. This makes the hook correct
///         for a 6-decimal prime (USDC/USDT, `scale == 1e12`), an 18-decimal prime
///         (`scale == 1`, identical to `BalancerPoolerMintDebtHook`), or any `<= 18`-dp
///         prime. `dispatcher` is mutable storage — seeded in the constructor to the
///         live `Uniboost` that will call `onDispatch`, and owner-repointable via
///         `setDispatcher` so a future dispatcher swap does not require redeploying the
///         hook. `onDispatch` is gated to the current dispatcher so no external caller
///         can inflate the debt. Trust model is unchanged: the owner is already fully
///         trusted, so a repointable dispatcher adds no new risk.
contract UniboostMintDebtHook is IDispatchHook, IUniboostMintDebtHook, Ownable, ReentrancyGuard {
    /// @notice Exclusive upper bound on `ratio`. Max settable ratio is `MAX_RATIO - 1`.
    uint8 public constant MAX_RATIO = 50;

    /// @notice Default ratio applied when the hook is first deployed (50%).
    uint8 public constant DEFAULT_RATIO = 50;

    /// @notice The dispatcher permitted to call `onDispatch`. Owner-repointable
    ///         via `setDispatcher` so future dispatcher swaps reuse this hook.
    address public dispatcher;

    /// @notice The phUSD (or compatible) mintable token. Immutable.
    IMintable public immutable phUSD;

    /// @notice Decimal-scaling factor `10 ** (18 - primeDecimals)` applied to the
    ///         dispatched amount before accruing debt. Read once from the prime token
    ///         at construction and immutable thereafter. `1e12` for a 6-decimal prime,
    ///         `1` for an 18-decimal prime. Exposed for transparency/debugging.
    uint256 public immutable scale;

    /// @notice The address credited by `pull()`. Zero until an owner sets it.
    address public recipient;

    /// @notice Accrued phUSD debt pending redemption via `pull()`.
    uint256 public mintDebt;

    /// @notice Percentage of dispatched prime that becomes debt. Strictly `< MAX_RATIO`.
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
    /// @param dispatcher_  The Uniboost instance permitted to call `onDispatch`.
    /// @param phUSD_       The mintable phUSD token minted to `recipient` on `pull`.
    /// @param primeToken_  The prime token whose `decimals()` determines `scale`. Must
    ///                     expose `decimals() <= 18`.
    constructor(address initialOwner, address dispatcher_, address phUSD_, address primeToken_) Ownable(initialOwner) {
        require(dispatcher_ != address(0), "dispatcher=0");
        require(phUSD_ != address(0), "phUSD=0");
        require(primeToken_ != address(0), "primeToken=0");
        uint8 d = IERC20Metadata(primeToken_).decimals();
        require(d <= 18, "decimals>18");
        dispatcher = dispatcher_;
        phUSD = IMintable(phUSD_);
        scale = 10 ** (18 - d);
        ratio = DEFAULT_RATIO;
        emit RatioUpdated(0, DEFAULT_RATIO);
    }

    /// @notice Update the mint-debt ratio. Only callable by owner.
    /// @param  newRatio Must be strictly less than `MAX_RATIO` (50).
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
        // Scale the prime-decimal dispatched amount up to 18-dp phUSD, then apply the ratio.
        // Multiply-then-divide floors the result, so sub-wei dust accrues to the protocol.
        uint256 added = (amount * scale * ratio) / 100;
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
}
