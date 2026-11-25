// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IUniswapV3SwapRouter} from "../interfaces/uniswap/IUniswapV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UsdcToWbtcAccumulator
/// @notice NFTMinterV2 dispatcher (intended for index 5, the "Bitcoin Buildup" NFT) that is paid in
///         USDC, keeps the USDC, and lets an authorised buyer later swap it into WBTC on Uniswap V3.
///         The WBTC stays on this contract; it can only leave through the owner's `rescueERC20`, which
///         pays the stored `treasuryRecipient` and nobody else.
/// @dev    Design source: phStaging2 `docs/NudgeLock/step-lock-plan.md` §3.4 (route and tolerance §5).
///
///         **Why the buy is deferred (MEV).** Swapping inside `mint` would be sandwichable: the minter's
///         caller sets no floor, so a bot could tilt the pool around every mint. Instead `_dispatch`
///         keeps the USDC and an authorised buyer calls `buy` with a floor quoted off-chain just
///         before submission, following the MEV rule in phStaging2 `docs/NFT/UniV2PriceTilting.md`,
///         as `UniPoolerV2.pool` and `buyAndBurn` do. The contract cannot know the fair price; it only
///         refuses a zero floor. A compromised buyer key is limited to trading at a bad floor of its
///         own choosing, and `incrementAuthVersion` revokes every buyer at once.
///
///         **Pause.** The inherited `pause`/`unpause` are `onlyMinter` (NFTMinterV2's
///         `setDispatcherActive`) and gate `dispatch` only, i.e. mints. `buy` and `rescueERC20` are
///         deliberately not pause-gated. The contract is not registered on PauserV2.
///
///         **No funds to the owner.** `setTreasuryRecipient` refuses `owner()`, and `rescueERC20` has no
///         `to` argument and re-checks the recipient against `owner()` at call time, so an ownership
///         transfer onto the recipient cannot route funds to the owner either.
///
///         Guards live on this concrete dispatcher, never the abstract base. `_dispatch` overrides only
///         the internal extension point and does not re-declare `onlyMinter` / `whenNotPaused` /
///         `nonReentrant` — those modifiers live on the base's external `dispatch`.
contract UsdcToWbtcAccumulator is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @dev USDC: the payment token NFTMinterV2 pulls on mint.
    address private immutable _primeToken;

    /// @notice WBTC: the token `buy` accumulates on this contract.
    address public immutable targetToken;

    /// @notice Uniswap V3 SwapRouter (v1, whose params struct carries `deadline`). Owner-settable.
    address public router;

    /// @notice Fee tier of the USDC/WBTC V3 pool used by `buy` (e.g. 3000 = 0.3%). Owner-settable.
    uint24 public poolFee;

    /// @notice The only destination of `rescueERC20`. `address(0)` at deploy (rescues disabled).
    address public treasuryRecipient;

    /// @notice Current buyer authorisation version. Starts at 1 (a zero version would authorise
    ///         every address, whose mapping entry defaults to 0).
    uint256 public authVersion;

    /// @notice The auth version each buyer was authorised at; a buyer is live iff it equals `authVersion`.
    mapping(address => uint256) public buyerAuthVersion;

    /// @notice Emitted on every successful `buy`. `wbtcOut` is the measured WBTC balance delta.
    event Bought(address indexed buyer, uint256 usdcIn, uint256 wbtcOut);
    /// @notice Emitted when the swap router changes.
    event RouterSet(address indexed oldRouter, address indexed newRouter);
    /// @notice Emitted when the pool fee tier changes.
    event PoolFeeSet(uint24 oldPoolFee, uint24 newPoolFee);
    /// @notice Emitted when a buyer is authorised at `atAuthVersion`.
    event BuyerAuthorized(address indexed buyer, uint256 atAuthVersion);
    /// @notice Emitted when a buyer is individually revoked.
    event BuyerDeauthorized(address indexed buyer);
    /// @notice Emitted when the auth version is bumped, revoking every buyer.
    event AuthVersionIncremented(uint256 newAuthVersion);
    /// @notice Emitted when the treasury recipient changes.
    event TreasuryRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /// @notice Emitted when tokens are rescued to the treasury recipient.
    event Rescued(address indexed token, address indexed recipient, uint256 amount);

    /// @notice A required address argument was zero.
    error UsdcToWbtcAccumulator__ZeroAddress();
    /// @notice USDC and WBTC were the same address.
    error UsdcToWbtcAccumulator__SameToken();
    /// @notice A pool fee of zero was supplied.
    error UsdcToWbtcAccumulator__ZeroPoolFee();
    /// @notice `caller` is not an authorised buyer at the current auth version.
    error UsdcToWbtcAccumulator__NotAuthorizedBuyer(address caller);
    /// @notice `buy` was called after its `deadline`.
    error UsdcToWbtcAccumulator__DeadlinePassed(uint256 deadline, uint256 timestamp);
    /// @notice `buy` was called with `usdcIn == 0`.
    error UsdcToWbtcAccumulator__ZeroAmountIn();
    /// @notice `buy` was called with `minWbtcOut == 0` (a zero floor invites a sandwich).
    error UsdcToWbtcAccumulator__ZeroMinOut();
    /// @notice The measured WBTC delta fell below the floor.
    error UsdcToWbtcAccumulator__InsufficientOutput(uint256 wbtcOut, uint256 minWbtcOut);
    /// @notice The treasury recipient would be (or has become) the owner.
    error UsdcToWbtcAccumulator__RecipientIsOwner();
    /// @notice `rescueERC20` was called while no treasury recipient is set.
    error UsdcToWbtcAccumulator__TreasuryRecipientUnset();

    /// @dev Live buyer: authorised at the current auth version (which is never 0).
    modifier onlyAuthorizedBuyer() {
        if (buyerAuthVersion[msg.sender] != authVersion) {
            revert UsdcToWbtcAccumulator__NotAuthorizedBuyer(msg.sender);
        }
        _;
    }

    /// @param usdc The payment token (USDC), returned by `primeToken()`.
    /// @param wbtc The accumulated token (WBTC), `targetToken`.
    /// @param router_ The Uniswap V3 SwapRouter v1.
    /// @param poolFee_ The USDC/WBTC pool fee tier (non-zero; no silent default).
    /// @param initialOwner The initial owner.
    constructor(address usdc, address wbtc, address router_, uint24 poolFee_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        if (usdc == address(0) || wbtc == address(0) || router_ == address(0)) {
            revert UsdcToWbtcAccumulator__ZeroAddress();
        }
        if (usdc == wbtc) revert UsdcToWbtcAccumulator__SameToken();
        if (poolFee_ == 0) revert UsdcToWbtcAccumulator__ZeroPoolFee();
        _primeToken = usdc;
        targetToken = wbtc;
        router = router_;
        poolFee = poolFee_;
        authVersion = 1;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view override returns (address) {
        return _primeToken;
    }

    /// @dev Keeps the USDC NFTMinterV2 already transferred here. Forwards and emits nothing.
    function _dispatch(address, uint256, bytes calldata) internal override {}

    /// @notice Swaps `usdcIn` of the held USDC for WBTC on Uniswap V3; the WBTC lands on this contract.
    /// @dev    Not pause-gated. Output is measured as this contract's WBTC balance delta, never the
    ///         router's return value. The router allowance is reset to 0 afterwards.
    /// @param  usdcIn Amount of USDC to sell (bounded by the balance: the router's pull fails beyond it).
    /// @param  minWbtcOut Floor from an off-chain quote; must be non-zero.
    /// @param  deadline Latest timestamp at which the swap may execute.
    /// @return wbtcOut WBTC received, as measured by balance delta.
    function buy(uint256 usdcIn, uint256 minWbtcOut, uint256 deadline)
        external
        nonReentrant
        onlyAuthorizedBuyer
        returns (uint256 wbtcOut)
    {
        if (block.timestamp > deadline) {
            revert UsdcToWbtcAccumulator__DeadlinePassed(deadline, block.timestamp);
        }
        if (usdcIn == 0) revert UsdcToWbtcAccumulator__ZeroAmountIn();
        if (minWbtcOut == 0) revert UsdcToWbtcAccumulator__ZeroMinOut();

        address router_ = router;
        IERC20 wbtc = IERC20(targetToken);

        IERC20(_primeToken).forceApprove(router_, usdcIn);
        uint256 before = wbtc.balanceOf(address(this));
        IUniswapV3SwapRouter(router_)
            .exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: _primeToken,
                    tokenOut: targetToken,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: usdcIn,
                    amountOutMinimum: minWbtcOut,
                    sqrtPriceLimitX96: 0
                })
            );
        wbtcOut = wbtc.balanceOf(address(this)) - before;
        if (wbtcOut < minWbtcOut) revert UsdcToWbtcAccumulator__InsufficientOutput(wbtcOut, minWbtcOut);
        IERC20(_primeToken).forceApprove(router_, 0);

        emit Bought(msg.sender, usdcIn, wbtcOut);
    }

    /// @notice Sets the swap router. Only callable by the owner.
    /// @param  newRouter The new Uniswap V3 SwapRouter v1 (non-zero).
    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert UsdcToWbtcAccumulator__ZeroAddress();
        address old = router;
        router = newRouter;
        emit RouterSet(old, newRouter);
    }

    /// @notice Sets the pool fee tier. Only callable by the owner.
    /// @param  newPoolFee The new fee tier (non-zero).
    function setPoolFee(uint24 newPoolFee) external onlyOwner {
        if (newPoolFee == 0) revert UsdcToWbtcAccumulator__ZeroPoolFee();
        uint24 old = poolFee;
        poolFee = newPoolFee;
        emit PoolFeeSet(old, newPoolFee);
    }

    /// @notice Authorises or revokes a buyer. Only callable by the owner.
    /// @param  buyer The buyer address (non-zero).
    /// @param  authorized True to authorise at the current auth version, false to revoke.
    function setAuthorizedBuyer(address buyer, bool authorized) external onlyOwner {
        if (buyer == address(0)) revert UsdcToWbtcAccumulator__ZeroAddress();
        if (authorized) {
            buyerAuthVersion[buyer] = authVersion;
            emit BuyerAuthorized(buyer, authVersion);
        } else {
            delete buyerAuthVersion[buyer];
            emit BuyerDeauthorized(buyer);
        }
    }

    /// @notice Bumps the auth version, revoking every current buyer (the kill switch).
    function incrementAuthVersion() external onlyOwner {
        authVersion += 1;
        emit AuthVersionIncremented(authVersion);
    }

    /// @notice Sets the treasury recipient, the only destination of `rescueERC20`. Only callable by
    ///         the owner. Refuses `owner()`; accepts `address(0)`, which switches rescues off again.
    /// @param  newRecipient The new recipient.
    function setTreasuryRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == owner()) revert UsdcToWbtcAccumulator__RecipientIsOwner();
        address old = treasuryRecipient;
        treasuryRecipient = newRecipient;
        emit TreasuryRecipientSet(old, newRecipient);
    }

    /// @notice Sends `amount` of `token` to `treasuryRecipient`. Only callable by the owner; not
    ///         pause-gated. The only way WBTC (or stray USDC) leaves this contract.
    /// @dev    Reverts while the recipient is unset, and if it has become the owner.
    /// @param  token The ERC20 to rescue.
    /// @param  amount The amount to send.
    function rescueERC20(address token, uint256 amount) external onlyOwner {
        address recipient = treasuryRecipient;
        if (recipient == address(0)) revert UsdcToWbtcAccumulator__TreasuryRecipientUnset();
        if (recipient == owner()) revert UsdcToWbtcAccumulator__RecipientIsOwner();
        IERC20(token).safeTransfer(recipient, amount);
        emit Rescued(token, recipient, amount);
    }
}
