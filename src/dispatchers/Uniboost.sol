// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../interfaces/uniswap/IUniswapV2Pair.sol";

/// @title Uniboost
/// @notice A V2 token dispatcher that boosts the price and liquidity of a target Uniswap V2
///         pool via the classic "buy-and-pool" zap, plus an optional prime-token donation split.
/// @dev Structurally a blend of `GatherV2` (tokens already on the contract via the minter's
///      `transferFrom`; owner-settable recipient) and `BalancerPoolerV2` (two-phase split:
///      `_dispatch` carves the donation and retains the rest; a separate authorized-pooler-gated
///      `pool(...)` later performs the boost). Unlike `BalancerPoolerV2`, the prime token here
///      IS the donation token, so the donation is a plain `safeTransfer` — no PSM, no swap.
///
///      The boost (`pool`) swaps all retained prime into the pool's pairing token, swaps ~half of
///      that into the boosted target token, then adds both sides as liquidity to the target pool.
///      UniV2 has no single-sided join, so we buy one side and add liquidity two-sided. The LP
///      tokens (the pair ERC20) accrue on the dispatcher as protocol-owned liquidity.
///
///      Guards live on this concrete dispatcher, never the abstract base. `_dispatch` overrides
///      only the internal extension point and MUST NOT re-declare `onlyMinter` / `whenNotPaused`
///      / `nonReentrant` — those modifiers live on the base's external `dispatch`.
contract Uniboost is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    address private immutable _primeToken;
    address private immutable _router;

    /// @notice The token to boost (e.g. EYE). Must be one of the target pool's two tokens.
    address public immutable targetToken;

    /// @notice The UniV2 pair to boost. Owner-settable via `setPool`.
    address private _targetPool;

    /// @notice The pool's other token (the routing/pairing token, e.g. WETH). Derived on `setPool`.
    address private _pairToken;

    /// @notice Owner-settable routing path for the prime -> pair swap. When empty, the direct
    ///         `[primeToken, pairToken]` path is used. When set it must start at `primeToken` and
    ///         end at `_pairToken` (validated in `setPrimeToPairPath`).
    address[] private _primeToPairPath;

    /// @notice Percentage (0..100) of each dispatched prime amount forwarded to `recipient` on
    ///         dispatch. Defaults to 0 (donation disabled).
    uint256 public donationSplit;

    /// @notice Recipient of the donated prime token (intended: the BalancerPooler batch-minter).
    ///         address(0) disables the donation even if donationSplit > 0.
    address public recipient;

    uint256 public authVersion;
    mapping(address => uint256) public poolerAuthVersion;

    event PoolerAuthorized(address indexed pooler, uint256 atAuthVersion);
    event PoolerDeauthorized(address indexed pooler);
    event AuthVersionIncremented(uint256 newAuthVersion);
    event Pooled(address indexed pooler, uint256 primeSpent, uint256 liquidity, uint256 minLP);

    event PoolSet(address indexed pool, address indexed pairToken);
    event DonationSplitSet(uint256 newSplit);
    event RecipientSet(address newRecipient);
    event PrimeToPairPathSet(address[] path);

    modifier onlyAuthorizedPooler() {
        require(poolerAuthVersion[msg.sender] == authVersion, "Uniboost: caller not authorized pooler");
        _;
    }

    /// @param primeToken_ The mint token, e.g. USDC. Returned by `primeToken()`.
    /// @param router_ The Uniswap V2 Router02 used for swaps and `addLiquidity`.
    /// @param targetPool_ The UniV2 pair to boost (must contain `targetToken_`).
    /// @param targetToken_ The token to boost (e.g. EYE).
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(
        address primeToken_,
        address router_,
        address targetPool_,
        address targetToken_,
        address initialOwner
    ) ATokenDispatcherV2(initialOwner) {
        require(primeToken_ != address(0), "Uniboost: zero prime");
        require(router_ != address(0), "Uniboost: zero router");
        require(targetToken_ != address(0), "Uniboost: zero target token");
        _primeToken = primeToken_;
        _router = router_;
        targetToken = targetToken_;
        authVersion = 1;
        _setPool(targetPool_);
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view override returns (address) {
        return _primeToken;
    }

    /// @notice Returns the Uniswap V2 router address.
    function router() external view returns (address) {
        return _router;
    }

    /// @notice Returns the current target pool address.
    function targetPool() external view returns (address) {
        return _targetPool;
    }

    /// @notice Returns the cached pairing token (the pool's non-target token).
    function pairToken() external view returns (address) {
        return _pairToken;
    }

    /// @notice Sets the target UniV2 pool to boost. Only callable by owner.
    /// @param newPool The new pool address (must contain `targetToken`).
    function setPool(address newPool) external onlyOwner {
        _setPool(newPool);
    }

    /// @dev Validates the pool contains `targetToken`, caches the other token as `_pairToken`,
    ///      stores the pool, and emits `PoolSet`.
    function _setPool(address newPool) internal {
        require(newPool != address(0), "Uniboost: zero pool");
        address token0 = IUniswapV2Pair(newPool).token0();
        address token1 = IUniswapV2Pair(newPool).token1();
        require(targetToken == token0 || targetToken == token1, "Uniboost: pool missing target token");
        address pairToken_ = targetToken == token0 ? token1 : token0;
        _targetPool = newPool;
        _pairToken = pairToken_;
        emit PoolSet(newPool, pairToken_);
    }

    /// @notice Sets the donation percentage (0..100) of each dispatched prime amount forwarded to
    ///         `recipient`. Setting 0 disables the donation. Only callable by owner.
    /// @param newSplit The new percentage. Must be <= 100.
    function setDonationSplit(uint256 newSplit) external onlyOwner {
        require(newSplit <= 100, "Uniboost: split > 100");
        donationSplit = newSplit;
        emit DonationSplitSet(newSplit);
    }

    /// @notice Sets the donation recipient. address(0) is allowed and disables the donation even
    ///         if donationSplit > 0. Only callable by owner.
    /// @param newRecipient The new recipient address (or address(0) to disable).
    function setRecipient(address newRecipient) external onlyOwner {
        recipient = newRecipient;
        emit RecipientSet(newRecipient);
    }

    /// @notice Sets a custom routing path for the prime -> pair swap performed in `pool()`.
    ///         Must start at `primeToken` and end at the current `_pairToken`. Only callable by
    ///         owner. Passing an empty array reverts; to revert to the direct route, set
    ///         `[primeToken, pairToken]` explicitly (or rely on the default before any set).
    /// @param path The routing path.
    function setPrimeToPairPath(address[] calldata path) external onlyOwner {
        require(path.length >= 2, "Uniboost: path too short");
        require(path[0] == _primeToken, "Uniboost: path start not prime");
        require(path[path.length - 1] == _pairToken, "Uniboost: path end not pair");
        _primeToPairPath = path;
        emit PrimeToPairPathSet(path);
    }

    /// @notice Returns the prime -> pair routing path. Defaults to the direct `[primeToken, pairToken]`
    ///         when no custom path has been set.
    function primeToPairPath() public view returns (address[] memory) {
        if (_primeToPairPath.length == 0) {
            address[] memory path = new address[](2);
            path[0] = _primeToken;
            path[1] = _pairToken;
            return path;
        }
        return _primeToPairPath;
    }

    /// @notice Dispatches prime tokens (already on this contract): forwards `donationSplit%` to
    ///         `recipient` when the donation is enabled, retaining the rest for the next `pool()`.
    /// @dev Donation is carved out only when enabled (recipient set, split > 0). The base then
    ///      calls `hook.onDispatch(minter, amount)` with the gross amount, so mint-debt accrues on
    ///      the full dispatched prime regardless of the donation (same convention as
    ///      `BalancerPoolerV2`). MUST NOT re-declare base modifiers.
    /// @param amount The FOT-adjusted amount of prime token to dispatch.
    function _dispatch(
        address,
        uint256 amount,
        bytes calldata /* extraData */
    )
        internal
        override
    {
        bool donationEnabled = recipient != address(0) && donationSplit > 0;
        uint256 donationAmount = donationEnabled ? (amount * donationSplit) / 100 : 0;
        if (donationAmount > 0) {
            IERC20(_primeToken).safeTransfer(recipient, donationAmount);
        }
        // The remainder simply stays on the contract — it is the prime balance the next pool()
        // will consume. No wrapping, no swap, nothing else.
    }

    /// @notice Boosts the target pool: swaps `amountIn` of retained prime -> pair, swaps ~half the
    ///         pair -> target, then adds both sides as liquidity. LP tokens accrue on the dispatcher
    ///         (protocol-owned liquidity). Only callable by authorized poolers. Pooling less than
    ///         the full retained balance leaves the remainder on the dispatcher for a later `pool()`.
    /// @param amountIn Absolute amount of retained prime token to pool (raw token units). Must be
    ///        nonzero and no greater than the dispatcher's current prime balance.
    /// @param minPairOut Slippage floor for the pair token received from swapping `amountIn` of prime.
    /// @param minTargetOut Slippage floor for the target token received from swapping ~half the pair.
    /// @param minLP Floor for the LP minted by `addLiquidity` (enforced post-call; UniV2's router
    ///        has no min-liquidity param).
    function pool(uint256 amountIn, uint256 minPairOut, uint256 minTargetOut, uint256 minLP)
        external
        onlyAuthorizedPooler
        whenNotPaused
        nonReentrant
    {
        // Step 1: swap `amountIn` of retained prime -> pairing token.
        require(amountIn > 0, "Uniboost: nothing to pool");
        require(amountIn <= IERC20(_primeToken).balanceOf(address(this)), "Uniboost: insufficient prime");
        IERC20(_primeToken).forceApprove(_router, amountIn);
        IUniswapV2Router02(_router).swapExactTokensForTokens(
            amountIn, minPairOut, primeToPairPath(), address(this), block.timestamp
        );
        IERC20(_primeToken).forceApprove(_router, 0);

        // Step 2: swap ~half the pairing token -> target token.
        uint256 pairBal = IERC20(_pairToken).balanceOf(address(this));
        uint256 half = pairBal / 2;
        if (half > 0) {
            address[] memory pairToTargetPath = new address[](2);
            pairToTargetPath[0] = _pairToken;
            pairToTargetPath[1] = targetToken;
            IERC20(_pairToken).forceApprove(_router, half);
            IUniswapV2Router02(_router).swapExactTokensForTokens(
                half, minTargetOut, pairToTargetPath, address(this), block.timestamp
            );
            IERC20(_pairToken).forceApprove(_router, 0);
        }

        // Step 3: add liquidity (targetToken + pairToken). The router consumes the optimal ratio
        // and refunds the unused side; any residual dust accrues on the dispatcher and is swept by
        // the next pool(). minAmounts are 0 — slippage is bounded by the two swap floors and minLP.
        uint256 targetBal = IERC20(targetToken).balanceOf(address(this));
        uint256 pairRemaining = IERC20(_pairToken).balanceOf(address(this));
        IERC20(targetToken).forceApprove(_router, targetBal);
        IERC20(_pairToken).forceApprove(_router, pairRemaining);
        (,, uint256 liquidity) = IUniswapV2Router02(_router).addLiquidity(
            targetToken, _pairToken, targetBal, pairRemaining, 0, 0, address(this), block.timestamp
        );
        require(liquidity >= minLP, "Uniboost: insufficient LP");
        IERC20(targetToken).forceApprove(_router, 0);
        IERC20(_pairToken).forceApprove(_router, 0);

        emit Pooled(msg.sender, amountIn, liquidity, minLP);
    }

    /// @notice Sets or revokes an authorized pooler. Only callable by owner.
    /// @param pooler The address to authorize or deauthorize.
    /// @param authorized True to authorize, false to deauthorize.
    function setAuthorizedPooler(address pooler, bool authorized) external onlyOwner {
        require(pooler != address(0), "Uniboost: zero pooler");
        if (authorized) {
            poolerAuthVersion[pooler] = authVersion;
            emit PoolerAuthorized(pooler, authVersion);
        } else {
            delete poolerAuthVersion[pooler];
            emit PoolerDeauthorized(pooler);
        }
    }

    /// @notice Increments the auth version, mass-revoking all current pooler authorizations.
    function incrementAuthVersion() external onlyOwner {
        authVersion += 1;
        emit AuthVersionIncremented(authVersion);
    }

    /// @notice Owner escape hatch. Transfers `amount` of any ERC20 token held by this contract to
    ///         `to`. Also serves as the LP-withdrawal mechanism (the LP token is the pair ERC20).
    ///         Not pause-gated — escape hatch must function during a pause.
    /// @param token The ERC20 token to rescue.
    /// @param to Recipient of the rescued tokens. Must be non-zero.
    /// @param amount Amount of `token` to transfer.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Uniboost: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
