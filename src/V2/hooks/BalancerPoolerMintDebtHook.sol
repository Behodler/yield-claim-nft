// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDispatchHook} from "../interfaces/IDispatchHook.sol";
import {IMintable} from "../../interfaces/IMintable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BalancerPoolerMintDebtHook
/// @notice `IDispatchHook` implementation that accrues a phUSD *mint debt* on every
///         dispatch routed through a specific `BalancerPoolerV2`. The debt equals
///         `ratio`% of the USDS `amount` forwarded by the dispatcher. A later
///         call to `pull()` by the owner or the configured `recipient` realises
///         the debt by minting phUSD to `recipient` and zeroing the ledger.
/// @dev    `dispatcher` is immutable — set in the constructor to the already-live
///         `BalancerPoolerV2` that will call `onDispatch`. `onDispatch` is gated
///         to this dispatcher so no external caller can inflate the debt.
contract BalancerPoolerMintDebtHook is IDispatchHook, Ownable, ReentrancyGuard {
    /// @notice Exclusive upper bound on `ratio`. Max settable ratio is `MAX_RATIO - 1`.
    uint8 public constant MAX_RATIO = 50;

    /// @notice Default ratio applied when the hook is first deployed (50%).
    uint8 public constant DEFAULT_RATIO = 50;

    /// @notice The dispatcher permitted to call `onDispatch`. Immutable.
    address public immutable dispatcher;

    /// @notice The phUSD (or compatible) mintable token. Immutable.
    IMintable public immutable phUSD;

    /// @notice The address credited by `pull()`. Zero until an owner sets it.
    address public recipient;

    /// @notice Accrued phUSD debt pending redemption via `pull()`.
    uint256 public mintDebt;

    /// @notice Percentage of dispatched USDS that becomes debt. Strictly `< MAX_RATIO`.
    uint8 public ratio;

    event RatioUpdated(uint8 oldRatio, uint8 newRatio);
    event RecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event DebtAccrued(
        address indexed minter,
        uint256 dispatchedAmount,
        uint256 debtAdded,
        uint256 newTotalDebt
    );
    event DebtPulled(address indexed recipient, uint256 amount);

    error OnlyDispatcher();
    error OnlyOwnerOrRecipient();
    error RecipientUnset();
    error RatioTooHigh();

    modifier onlyOwnerOrRecipient() {
        if (msg.sender != owner() && msg.sender != recipient)
            revert OnlyOwnerOrRecipient();
        _;
    }

    /// @param initialOwner Address granted `Ownable` ownership of the hook.
    /// @param dispatcher_  The BalancerPoolerV2 instance permitted to call `onDispatch`.
    /// @param phUSD_       The mintable phUSD token minted to `recipient` on `pull`.
    constructor(
        address initialOwner,
        address dispatcher_,
        address phUSD_
    ) Ownable(initialOwner) {
        require(dispatcher_ != address(0), "dispatcher=0");
        require(phUSD_ != address(0), "phUSD=0");
        dispatcher = dispatcher_;
        phUSD = IMintable(phUSD_);
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

    /// @inheritdoc IDispatchHook
    /// @dev Gated to `dispatcher` to prevent unbounded phUSD debt inflation by
    ///      arbitrary callers. Silent no-op when `added == 0` (zero ratio or
    ///      small-amount rounding) so the debt ledger never emits empty events.
    function onDispatch(
        address minter,
        uint256 amount,
        bytes calldata
    ) external {
        if (msg.sender != dispatcher) revert OnlyDispatcher();
        uint256 added = (amount * ratio) / 100;
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
