// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {ISkyPSM} from "../interfaces/ISkyPSM.sol";
import {IPhusdBurnable} from "../interfaces/IPhusdBurnable.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "../interfaces/balancer/IUnlockCallback.sol";
import {VaultSwapParams, SwapKind} from "../interfaces/balancer/BalancerTypes.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../interfaces/uniswap/IUniswapV2Pair.sol";
import {INudgeStreamer} from "phoenix-nft-staking/INudgeStreamer.sol";

/// @title PromotionUniV2_Eth
/// @notice A reusable, per-partner V2 token dispatcher that boosts a phUSD/promotion Uniswap V2
///         pool via a two-legged "buy-and-pool" zap, plus an optional prime-token donation split.
/// @dev Structurally a blend of `Uniboost` (donation split, authorized-pooler machinery, UniV2
///      zap, `setPool`/`_setPool` pair validation, `rescueERC20`) and `BalancerPoolerV2` (the
///      Balancer V3 `unlock`→`swap`→`settle`→`sendTo` interaction, the USDS→sUSDS ERC4626 wrap,
///      and the SKY PSM fee/decimal scaffolding — here inverted from `buyGem` to `sellGem`).
///
///      The prime token is USDC. On `dispatch`, a configurable donation split of the USDC is
///      routed to `batchMinter` through the `NudgeStreamer` and the rest is retained.
///
///      ### The streamer is mandatory ON THE LIVE-DONATION BRANCH ONLY (story 046)
///
///      The legacy direct `safeTransfer(batchMinter, donationAmount)` has been REMOVED, not kept
///      as a fallback. The requirement is scoped to the branch that would actually pay, so a
///      donation-disabled deployment (`batchMinter == address(0)` or `donationSplit == 0`) stays
///      fully deployable and dispatchable with no streamer set. Once the donation IS live:
///
///        * `nudgeStreamer == address(0)` (its post-deploy state — it is a setter-only field,
///          deliberately not a constructor arg because the streamer is deployed later) makes
///          `dispatch` revert `"PromotionUniV2_Eth: nudgeStreamer unset"`.
///        * If the streamer is set but ops forgot `registerStream(batchMinter, USDC, duration)`
///          on it, every `dispatch` reverts `NudgeStreamer__NotRegistered()`. That is the accepted
///          consequence of the mandatory-streamer decision, NOT an audit finding. Repointing
///          `batchMinter` re-arms the same failure mode; register the new pair first.
///
///      **Required ops ordering** (reversing the first two reverts
///      `NudgeStreamer__NotWhitelisted`):
///        1. `batchMinter.setNudgeTokenWhitelist(USDC, true)`
///        2. `nudgeStreamer.registerStream(batchMinter, USDC, duration)`
///        3. `this.setNudgeStreamer(nudgeStreamer)`
///
///      **Gas / behaviour:** the donation is no longer a leaf `transfer`. `collectNudge` first
///      settles the accrued stream (an outbound transfer to `batchMinter`) and then pulls via
///      `transferFrom`, all inside this dispatch transaction, so dispatch is measurably more
///      expensive and now depends on external streamer state. `collectNudge` also reverts
///      `NudgeStreamer__ZeroAmount()` on a zero amount, which is why the `donationAmount > 0`
///      guard is load-bearing rather than cosmetic.
///
///      On `pool` (authorized-pooler gated),
///      the retained USDC is split 60/30/10:
///        - Leg A (60%) → phUSD: USDC →(SKY PSM `sellGem`)→ USDS →(ERC4626 `deposit`)→ sUSDS
///          →(Balancer V3 swap)→ phUSD. HALF the acquired phUSD is burned (permanent supply cut);
///          the rest is pooled, value-matching the promotion side.
///        - Leg B (30%) → promotion: USDC →(UniV2 `swapExactTokensForETH`)→ native ETH
///          →(UniV2 `swapExactETHForTokens`)→ promotion token.
///        - Leg C (10%) → WBTC: USDC →(UniV2 `swapExactTokensForTokens`)→ WBTC, retained on the
///          dispatcher as an insurance reserve (NOT pooled; withdrawable only by `insurer`).
///      The phUSD and promotion sides are added as liquidity to the target phUSD/promotion UniV2
///      pair; the LP token accrues on the dispatcher as protocol-owned liquidity (withdrawn via
///      `rescueERC20`).
///
///      Everything mainnet-fixed is hardcoded as `address constant`s; only the promotion token and
///      its phUSD/promotion pair are per-partner (constructor params). Guards live on this concrete
///      dispatcher, never the abstract base. `_dispatch` overrides only the internal extension
///      point and MUST NOT re-declare `onlyMinter` / `whenNotPaused` / `nonReentrant`.
contract PromotionUniV2_Eth is ATokenDispatcherV2, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Hardcoded mainnet infrastructure (per the 2026-07-18 planning decision)
    // ---------------------------------------------------------------------

    /// @notice phUSD — our token (the phUSD/promotion pool's phUSD side). 18dp.
    address public constant phUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    /// @notice USDC — the prime (mint) token. 6dp.
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice USDS — the Sky stablecoin received from the PSM `sellGem`. 18dp.
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    /// @notice sUSDS — the ERC4626 wrapper the Balancer phUSD pool pairs against.
    address public constant sUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    /// @notice WETH — the native-ETH wrapper used as the Leg B routing hub.
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @notice Balancer V3 vault.
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    /// @notice The 50/50 weighted phUSD/sUSDS Balancer pool (the only pool used for Leg A).
    address public constant BALANCER_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    /// @notice Uniswap V2 Router02.
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    /// @notice WBTC — the insurance-reserve asset acquired by Leg C. 8dp. Never pooled; withdrawable
    ///         only by `insurer` (via `withdrawWBTC`), and explicitly excluded from `rescueERC20`.
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @dev 1e18 fixed-point scale (matches the Sky PSM WAD used for `tin`).
    uint256 internal constant WAD = 1e18;

    // ---------------------------------------------------------------------
    // Owner-settable infrastructure (hardcoded defaults; setters mirror BalancerPoolerV2)
    // ---------------------------------------------------------------------

    /// @notice The Sky USDS↔USDC PSM (UsdsPsmWrapper) used by Leg A step 1. Non-zero.
    address public psm = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    /// @notice WAD-scaled ceiling on the PSM `tin` (sell fee). Leg A reverts above this. 1% default.
    uint256 public maxTin = 1e16;

    // ---------------------------------------------------------------------
    // Per-partner state
    // ---------------------------------------------------------------------

    /// @notice The sponsoring partner's promotion token (the pool's non-phUSD side).
    address public immutable promotionToken;

    /// @notice The phUSD/promotion UniV2 pair (LP target). Owner-settable via `setPool`.
    address private _targetPair;

    /// @notice Owner-settable routing path for Leg B step 2 (ETH → promotion). When empty, the
    ///         direct `[WETH, promotionToken]` path is used. When set it must start at WETH and end
    ///         at `promotionToken` (validated in `setEthToPromotionPath`).
    address[] private _ethToPromotionPath;

    /// @notice Owner-settable routing path for Leg C (USDC → WBTC). When empty, the direct
    ///         `[USDC, WBTC]` path is used (cheapest gas; the direct V2 pool is deep enough for the
    ///         small per-pool amounts). Set it to e.g. `[USDC, WETH, WBTC]` to reroute via WETH if
    ///         the direct pool degrades. Must start at USDC and end at WBTC.
    address[] private _usdcToWbtcPath;

    /// @notice The insurance-reserve role — the ONLY address permitted to withdraw WBTC (via
    ///         `withdrawWBTC`). Owner-settable via `setInsurer`; deliberately NOT seeded in the
    ///         constructor (starts address(0), which locks `withdrawWBTC` until an owner sets it).
    address public insurer;

    // ---------------------------------------------------------------------
    // Donation state (copied from Uniboost, named per spec)
    // ---------------------------------------------------------------------

    /// @notice Recipient of the donated USDC (the BalancerPooler batch-minter). address(0) disables
    ///         the donation even if `donationSplit > 0`.
    address public batchMinter;

    /// @notice Percentage (0..100) of each dispatched USDC amount forwarded to `batchMinter` on
    ///         dispatch. Defaults to 0 (donation disabled).
    uint256 public donationSplit;

    /// @notice The NudgeStreamer that buffers and linearly releases nudge donations to
    ///         `batchMinter`. Setter-only (starts `address(0)`); mandatory only when the donation
    ///         branch is live — see the contract-level dev notes.
    address public nudgeStreamer;

    // ---------------------------------------------------------------------
    // Pooler-auth set (copied verbatim from Uniboost)
    // ---------------------------------------------------------------------

    uint256 public authVersion;
    mapping(address => uint256) public poolerAuthVersion;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PoolerAuthorized(address indexed pooler, uint256 atAuthVersion);
    event PoolerDeauthorized(address indexed pooler);
    event AuthVersionIncremented(uint256 newAuthVersion);

    /// @notice Emitted once per `pool()`. Consolidates the full 60/30/10 outcome.
    event Pooled(
        address indexed pooler,
        uint256 primeSpent, // amountIn (USDC)
        uint256 phusdAcquired, // gross phUSD out of Leg A (pre-burn)
        uint256 phusdBurned, // = phusdAcquired / 2
        uint256 wbtcAcquired, // WBTC out of Leg C (8dp)
        uint256 liquidity // LP minted into the phUSD/promotion pair
    );

    event PoolSet(address indexed pair);
    event DonationSplitSet(uint256 newSplit);
    event BatchMinterSet(address newBatchMinter);
    event NudgeStreamerUpdated(address indexed oldStreamer, address indexed newStreamer);
    event PSMSet(address newPSM);
    event MaxTinSet(uint256 newMaxTin);
    event EthToPromotionPathSet(address[] path);
    event UsdcToWbtcPathSet(address[] path);
    event InsurerSet(address newInsurer);
    event WBTCWithdrawn(address indexed to, uint256 amount);

    modifier onlyAuthorizedPooler() {
        require(poolerAuthVersion[msg.sender] == authVersion, "PromotionUniV2_Eth: caller not authorized pooler");
        _;
    }

    modifier onlyInsurer() {
        require(msg.sender == insurer, "PromotionUniV2_Eth: not insurer");
        _;
    }

    /// @param promotionToken_ The sponsoring partner's token (the pool's non-phUSD side).
    /// @param targetPair_ The phUSD/promotion UniV2 pair to boost (must contain both tokens).
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address promotionToken_, address targetPair_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(promotionToken_ != address(0), "PromotionUniV2_Eth: zero promotion token");
        promotionToken = promotionToken_;
        authVersion = 1;
        _setPool(targetPair_);
        // phUSD's burn is allowance-based (transferFrom-style): to burn its own phUSD in `pool()`
        // the dispatcher must be an approved spender over itself. Set an infinite self-allowance
        // once here (OZ skips the decrement on a max allowance, so no `pool()` needs a per-call
        // approve). Harmless: it only lets the contract burn phUSD it already holds.
        IERC20(phUSD).forceApprove(address(this), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external pure override returns (address) {
        return USDC;
    }

    /// @notice Returns the current target phUSD/promotion UniV2 pair.
    function targetPool() external view returns (address) {
        return _targetPair;
    }

    /// @notice Returns the effective ETH → promotion routing path (defaults to `[WETH, promotion]`).
    function ethToPromotionPath() public view returns (address[] memory) {
        if (_ethToPromotionPath.length == 0) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = promotionToken;
            return path;
        }
        return _ethToPromotionPath;
    }

    /// @notice Returns the effective USDC → WBTC routing path for Leg C (defaults to the direct
    ///         `[USDC, WBTC]` single hop).
    function usdcToWbtcPath() public view returns (address[] memory) {
        if (_usdcToWbtcPath.length == 0) {
            address[] memory path = new address[](2);
            path[0] = USDC;
            path[1] = WBTC;
            return path;
        }
        return _usdcToWbtcPath;
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @notice Sets the target UniV2 pool to boost. Only callable by owner.
    /// @param newPair The new pair address (must contain phUSD and `promotionToken`).
    function setPool(address newPair) external onlyOwner {
        _setPool(newPair);
    }

    /// @dev Validates the pair's token set equals `{phUSD, promotionToken}` (order-agnostic),
    ///      stores it, and emits `PoolSet`.
    function _setPool(address newPair) internal {
        require(newPair != address(0), "PromotionUniV2_Eth: zero pool");
        address token0 = IUniswapV2Pair(newPair).token0();
        address token1 = IUniswapV2Pair(newPair).token1();
        bool ok = (token0 == phUSD && token1 == promotionToken) || (token0 == promotionToken && token1 == phUSD);
        require(ok, "PromotionUniV2_Eth: pair missing token");
        _targetPair = newPair;
        emit PoolSet(newPair);
    }

    /// @notice Sets a custom routing path for the ETH → promotion swap performed in `pool()`.
    ///         Must start at WETH and end at `promotionToken`. Only callable by owner.
    /// @param path The routing path (length >= 2).
    function setEthToPromotionPath(address[] calldata path) external onlyOwner {
        require(path.length >= 2, "PromotionUniV2_Eth: path too short");
        require(path[0] == WETH, "PromotionUniV2_Eth: path start not WETH");
        require(path[path.length - 1] == promotionToken, "PromotionUniV2_Eth: path end not promotion");
        _ethToPromotionPath = path;
        emit EthToPromotionPathSet(path);
    }

    /// @notice Sets a custom routing path for the USDC → WBTC swap performed in `pool()` (Leg C).
    ///         Must start at USDC and end at WBTC. Only callable by owner.
    /// @param path The routing path (length >= 2).
    function setUsdcToWbtcPath(address[] calldata path) external onlyOwner {
        require(path.length >= 2, "PromotionUniV2_Eth: path too short");
        require(path[0] == USDC, "PromotionUniV2_Eth: path start not USDC");
        require(path[path.length - 1] == WBTC, "PromotionUniV2_Eth: path end not WBTC");
        _usdcToWbtcPath = path;
        emit UsdcToWbtcPathSet(path);
    }

    /// @notice Sets the insurance-reserve role permitted to withdraw WBTC. Must be non-zero.
    ///         Only callable by owner.
    function setInsurer(address newInsurer) external onlyOwner {
        require(newInsurer != address(0), "PromotionUniV2_Eth: zero insurer");
        insurer = newInsurer;
        emit InsurerSet(newInsurer);
    }

    /// @notice Withdraws `amount` (WBTC, 8dp) of the insurance reserve to `to`. Insurer only.
    ///         Not pause-gated (escape-hatch convention); insurer-gated instead.
    function withdrawWBTC(address to, uint256 amount) external onlyInsurer {
        require(to != address(0), "PromotionUniV2_Eth: zero recipient");
        IERC20(WBTC).safeTransfer(to, amount);
        emit WBTCWithdrawn(to, amount);
    }

    /// @notice Sets the Sky USDS↔USDC PSM used by Leg A. Must be non-zero. Only callable by owner.
    function setPSM(address newPSM) external onlyOwner {
        require(newPSM != address(0), "PromotionUniV2_Eth: zero psm");
        psm = newPSM;
        emit PSMSet(newPSM);
    }

    /// @notice Sets the WAD-scaled ceiling on the PSM `tin` accepted for Leg A. Only callable by owner.
    function setMaxTin(uint256 newMaxTin) external onlyOwner {
        maxTin = newMaxTin;
        emit MaxTinSet(newMaxTin);
    }

    /// @notice Sets the donation percentage (0..100) of each dispatched USDC forwarded to
    ///         `batchMinter`. Setting 0 disables the donation. Only callable by owner.
    function setDonationSplit(uint256 newSplit) external onlyOwner {
        require(newSplit <= 100, "PromotionUniV2_Eth: split > 100");
        donationSplit = newSplit;
        emit DonationSplitSet(newSplit);
    }

    /// @notice Sets the donation recipient. address(0) is allowed and disables the donation even if
    ///         `donationSplit > 0`. Only callable by owner.
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        batchMinter = newBatchMinter;
        emit BatchMinterSet(newBatchMinter);
    }

    /// @notice Updates the NudgeStreamer donations are routed through. Only callable by owner.
    /// @param newStreamer The new streamer address. Must be non-zero.
    function setNudgeStreamer(address newStreamer) external onlyOwner {
        require(newStreamer != address(0), "PromotionUniV2_Eth: zero nudgeStreamer");
        address old = nudgeStreamer;
        nudgeStreamer = newStreamer;
        emit NudgeStreamerUpdated(old, newStreamer);
    }

    /// @notice Sets or revokes an authorized pooler. Only callable by owner.
    function setAuthorizedPooler(address pooler, bool authorized) external onlyOwner {
        require(pooler != address(0), "PromotionUniV2_Eth: zero pooler");
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

    // ---------------------------------------------------------------------
    // Dispatch
    // ---------------------------------------------------------------------

    /// @notice Dispatches prime USDC (already on this contract): streams `donationSplit%` to
    ///         `batchMinter` when the donation is enabled, retaining the rest for the next `pool()`.
    /// @dev The base then calls `hook.onDispatch(minter, amount)` with the GROSS amount, so
    ///      mint-debt accrues on the full dispatched USDC regardless of the donation (same
    ///      convention as `Uniboost` / `BalancerPoolerV2`). Only the live-donation branch requires
    ///      a configured `nudgeStreamer`. MUST NOT re-declare base modifiers.
    function _dispatch(address, uint256 amount, bytes calldata /* extraData */ ) internal override {
        bool donationEnabled = batchMinter != address(0) && donationSplit > 0;
        uint256 donationAmount = donationEnabled ? (amount * donationSplit) / 100 : 0;
        // The `> 0` guard is load-bearing: `collectNudge` reverts `NudgeStreamer__ZeroAmount()`
        // on zero, which would brick dispatch. It also scopes the mandatory-streamer requirement
        // to the live-donation branch, so a donation-disabled deployment dispatches with no
        // streamer set. `forceApprove` with the exact amount (USDC rejects a plain `approve` over
        // a non-zero residual allowance); `collectNudge` consumes the whole allowance in this
        // same transaction, so nothing lingers.
        if (donationAmount > 0) {
            address streamer = nudgeStreamer;
            require(streamer != address(0), "PromotionUniV2_Eth: nudgeStreamer unset");
            IERC20(USDC).forceApprove(streamer, donationAmount);
            INudgeStreamer(streamer).collectNudge(batchMinter, USDC, donationAmount);
        }
        // The remainder simply stays on the contract as the prime balance the next pool() consumes.
    }

    // ---------------------------------------------------------------------
    // Pool
    // ---------------------------------------------------------------------

    /// @notice Boosts the target pool: splits `amountIn` of retained USDC 60/30/10 — 60% to phUSD
    ///         (Leg A, Balancer), 30% to promotion (Leg B, native ETH), 10% to WBTC (Leg C, direct
    ///         UniV2). HALF the acquired phUSD is burned (permanent supply cut) so the pooled phUSD
    ///         value (~30% of USDC) matches the pooled promotion value (~30% of USDC); the rest is
    ///         added as liquidity. The WBTC is retained as an insurance reserve (NOT pooled). LP
    ///         tokens accrue on the dispatcher (protocol-owned liquidity). Only callable by
    ///         authorized poolers.
    /// @param amountIn Absolute amount of retained USDC to pool. Nonzero, <= the current USDC balance.
    /// @param minPhusdOut Slippage floor for phUSD out of the Balancer swap (Leg A, full pre-burn output).
    /// @param minEthOut Slippage floor for native ETH out of the USDC→ETH swap (Leg B step 1).
    /// @param minPromoOut Slippage floor for promotion out of the ETH→promotion swap (Leg B step 2).
    /// @param minWbtcOut Slippage floor for WBTC out of the USDC→WBTC swap (Leg C).
    /// @param minLP Floor for the LP minted by `addLiquidity` (enforced post-call).
    function pool(
        uint256 amountIn,
        uint256 minPhusdOut,
        uint256 minEthOut,
        uint256 minPromoOut,
        uint256 minWbtcOut,
        uint256 minLP
    )
        external
        onlyAuthorizedPooler
        whenNotPaused
        nonReentrant
    {
        require(amountIn > 0, "PromotionUniV2_Eth: nothing to pool");
        require(amountIn <= IERC20(USDC).balanceOf(address(this)), "PromotionUniV2_Eth: insufficient prime");

        uint256 phusdAcquired;
        uint256 wbtcAcquired;
        {
            // Scoped so the leg amounts free their stack slots before the add-liquidity step
            // (this contract compiles without via_ir, so local-variable count matters).
            uint256 amountA = (amountIn * 60) / 100; // phUSD leg
            uint256 amountB = (amountIn * 30) / 100; // promotion leg
            uint256 amountC = amountIn - amountA - amountB; // WBTC leg (~10% + rounding dust → reserve)

            phusdAcquired = _legA(amountA, minPhusdOut);
            _legB(amountB, minEthOut, minPromoOut);
            wbtcAcquired = _legC(amountC, minWbtcOut);
        }

        // Burn half the acquired phUSD (permanent supply cut); pool the rest. This value-matches the
        // pooled phUSD (~30% of USDC) to the pooled promotion (~30% of USDC). phUSD's burn is
        // allowance-based; the infinite self-allowance set in the constructor authorizes this.
        uint256 phusdBurned = phusdAcquired / 2;
        IPhusdBurnable(phUSD).burn(address(this), phusdBurned);

        uint256 liquidity = _addPhusdPromoLiquidity(minLP);

        emit Pooled(msg.sender, amountIn, phusdAcquired, phusdBurned, wbtcAcquired, liquidity);
    }

    /// @dev Adds all resident phUSD + promotion as liquidity to the target pair. Sides are ~equal
    ///      value post-burn so the router refund is negligible. minAmounts stay 0 (bounded by the
    ///      leg floors + `minLP`). Extracted from `pool()` to keep its stack shallow (no via_ir).
    /// @return liquidity LP minted into the phUSD/promotion pair.
    function _addPhusdPromoLiquidity(uint256 minLP) internal returns (uint256 liquidity) {
        uint256 phusdBal = IERC20(phUSD).balanceOf(address(this));
        uint256 promoBal = IERC20(promotionToken).balanceOf(address(this));
        IERC20(phUSD).forceApprove(UNIV2_ROUTER, phusdBal);
        IERC20(promotionToken).forceApprove(UNIV2_ROUTER, promoBal);
        (,, liquidity) = IUniswapV2Router02(UNIV2_ROUTER).addLiquidity(
            phUSD, promotionToken, phusdBal, promoBal, 0, 0, address(this), block.timestamp
        );
        require(liquidity >= minLP, "PromotionUniV2_Eth: insufficient LP");
        IERC20(phUSD).forceApprove(UNIV2_ROUTER, 0);
        IERC20(promotionToken).forceApprove(UNIV2_ROUTER, 0);
    }

    /// @dev Leg A: USDC →(PSM sellGem)→ USDS →(ERC4626 deposit)→ sUSDS →(Balancer swap)→ phUSD.
    /// @param usdcAmount USDC (6dp) to convert.
    /// @param minPhusdOut Slippage floor for the phUSD received from the Balancer swap.
    /// @return phusdOut phUSD acquired.
    function _legA(uint256 usdcAmount, uint256 minPhusdOut) internal returns (uint256 phusdOut) {
        // Step 1: USDC -> USDS via the SKY PSM. PSM has no slippage; the `tin` fee is the risk.
        require(ISkyPSM(psm).tin() <= maxTin, "PromotionUniV2_Eth: tin too high");
        IERC20(USDC).forceApprove(psm, usdcAmount);
        uint256 usdsOut = ISkyPSM(psm).sellGem(address(this), usdcAmount);
        IERC20(USDC).forceApprove(psm, 0);

        // Step 2: USDS -> sUSDS (the Balancer phUSD pool pairs against sUSDS, not USDS).
        IERC20(USDS).forceApprove(sUSDS, usdsOut);
        uint256 shares = IERC4626(sUSDS).deposit(usdsOut, address(this));

        // Step 3: sUSDS -> phUSD via the Balancer V3 low-level swap.
        phusdOut = _swapSusdsForPhusd(shares, minPhusdOut);
    }

    /// @dev Leg B: USDC →(UniV2 swapExactTokensForETH)→ ETH →(UniV2 swapExactETHForTokens)→ promotion.
    /// @param usdcAmount USDC (6dp) to convert.
    /// @param minEthOut Slippage floor for native ETH from the USDC→ETH swap.
    /// @param minPromoOut Slippage floor for promotion from the ETH→promotion swap.
    function _legB(uint256 usdcAmount, uint256 minEthOut, uint256 minPromoOut) internal {
        address[] memory usdcToEth = new address[](2);
        usdcToEth[0] = USDC;
        usdcToEth[1] = WETH;
        IERC20(USDC).forceApprove(UNIV2_ROUTER, usdcAmount);
        IUniswapV2Router02(UNIV2_ROUTER).swapExactTokensForETH(
            usdcAmount, minEthOut, usdcToEth, address(this), block.timestamp
        );
        IERC20(USDC).forceApprove(UNIV2_ROUTER, 0);

        uint256 ethBal = address(this).balance;
        IUniswapV2Router02(UNIV2_ROUTER).swapExactETHForTokens{value: ethBal}(
            minPromoOut, ethToPromotionPath(), address(this), block.timestamp
        );
    }

    /// @dev Leg C: USDC → WBTC via `swapExactTokensForTokens(usdcToWbtcPath())` (default `[USDC, WBTC]`,
    ///      one hop, cheapest gas). The acquired WBTC (8dp) is retained as the insurance reserve — NOT
    ///      pooled; it leaves only via `withdrawWBTC` (insurer-gated).
    /// @param usdcAmount USDC (6dp) to convert.
    /// @param minWbtcOut Slippage floor for the WBTC (8dp) received.
    /// @return wbtcOut WBTC acquired (8dp).
    function _legC(uint256 usdcAmount, uint256 minWbtcOut) internal returns (uint256 wbtcOut) {
        IERC20(USDC).forceApprove(UNIV2_ROUTER, usdcAmount);
        uint256[] memory amounts = IUniswapV2Router02(UNIV2_ROUTER).swapExactTokensForTokens(
            usdcAmount, minWbtcOut, usdcToWbtcPath(), address(this), block.timestamp
        );
        IERC20(USDC).forceApprove(UNIV2_ROUTER, 0);
        wbtcOut = amounts[amounts.length - 1];
    }

    /// @dev Balancer V3 low-level EXACT_IN swap of `sharesIn` sUSDS for phUSD (min-out = `minPhusdOut`),
    ///      via the vault `unlock` → `unlockCallback` reentrancy pattern.
    function _swapSusdsForPhusd(uint256 sharesIn, uint256 minPhusdOut) internal returns (uint256) {
        bytes memory inner = abi.encode(sharesIn, minPhusdOut);
        bytes memory ret =
            IBalancerVault(BALANCER_VAULT).unlock(abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, inner));
        // `unlock` returns the callback's raw returndata verbatim, which is the ABI-encoding of the
        // callback's declared `bytes` return value (itself `abi.encode(amountOut)`). Unwrap the outer
        // `bytes` first, then decode the inner word — decoding `ret` directly as a uint256 would read
        // the ABI offset (0x20), silently collapsing amountOut to 32 and burning almost nothing.
        return abi.decode(abi.decode(ret, (bytes)), (uint256));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable via the vault during `unlock` (guarded by `msg.sender == BALANCER_VAULT`).
    ///      Order: pay input (transfer) → swap → settle input → pull output (sendTo). `limitRaw` on
    ///      an EXACT_IN swap is the min-out floor.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == BALANCER_VAULT, "PromotionUniV2_Eth: caller is not vault");
        (uint256 sharesIn, uint256 minPhusdOut) = abi.decode(data, (uint256, uint256));

        IERC20(sUSDS).safeTransfer(BALANCER_VAULT, sharesIn); // 1. pay input
        VaultSwapParams memory p = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: BALANCER_POOL,
            tokenIn: IERC20(sUSDS),
            tokenOut: IERC20(phUSD),
            amountGivenRaw: sharesIn,
            limitRaw: minPhusdOut,
            userData: ""
        });
        (,, uint256 amountOut) = IBalancerVault(BALANCER_VAULT).swap(p); // 2. swap
        IBalancerVault(BALANCER_VAULT).settle(IERC20(sUSDS), sharesIn); // 3. settle input
        IBalancerVault(BALANCER_VAULT).sendTo(IERC20(phUSD), address(this), amountOut); // 4. pull output
        return abi.encode(amountOut);
    }

    // ---------------------------------------------------------------------
    // Escape hatches
    // ---------------------------------------------------------------------

    /// @notice Owner escape hatch. Transfers `amount` of any ERC20 held by this contract to `to`.
    ///         Also the LP-withdrawal mechanism (the LP token is the pair ERC20). WBTC is excluded:
    ///         the insurance reserve leaves only via the insurer-gated `withdrawWBTC`, never the
    ///         owner escape hatch. Not pause-gated.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "PromotionUniV2_Eth: zero recipient");
        require(token != WBTC, "PromotionUniV2_Eth: WBTC is insurer-only");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Owner escape hatch for native ETH left by a failed/partial Leg B. Not pause-gated.
    function rescueETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "PromotionUniV2_Eth: zero recipient");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "PromotionUniV2_Eth: eth rescue failed");
    }

    /// @notice Accepts native ETH from the `swapExactTokensForETH` unwrap in Leg B.
    receive() external payable {}
}
