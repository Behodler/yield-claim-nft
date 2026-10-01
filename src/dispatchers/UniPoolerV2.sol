// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {ISkyPSM} from "../interfaces/ISkyPSM.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../interfaces/uniswap/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "../interfaces/uniswap/IUniswapV2Factory.sol";
import {INudgeStreamer} from "phoenix-nft-staking/INudgeStreamer.sol";

/// @title UniPoolerV2
/// @notice A V2 token dispatcher that wraps USDS into sUSDS on dispatch, then lets an authorized
///         pooler zap that sUSDS into a phUSD/sUSDS Uniswap V2 pair. The LP stays on this contract
///         as protocol-owned liquidity.
/// @dev The replacement for the Balancer V3 pooler at NFT index 4 (Balancexit plan, Stage 1a). The
///      mint path — `_dispatch` and `_psmDonate` — is copied from that contract (only revert-string
///      prefixes, NatSpec, and the hook-not-set guard at the top of `_dispatch` differ; see "Hook
///      must be set before the first mint"), so the NFT minter, the mint-debt hook and the
///      donation stack see an identical dispatcher once its hook is set: USDS -> sUSDS wrap of the
///      pooling share, plus the failure-isolated Sky PSM donation streamed to `batchMinter` via
///      `nudgeStreamer`.
///
///      ### Donation (unchanged from the previous pooler)
///
///      The PSM delivers USDC to **this contract**, which `forceApprove`s the exact `gemAmt` to
///      `nudgeStreamer` and calls `collectNudge(batchMinter, gem, gemAmt)`. The streamer is
///      mandatory on the live-donation branch only. `_psmDonate` is wrapped in a
///      `try this._psmDonate{} catch` envelope so a donation call that reverts (PSM outage,
///      `tout` above `maxTout`, streamer unset, stream unregistered) parks the swept USDS and
///      emits `DonationSkipped` instead of reverting the mint; the next dispatch re-sweeps it.
///      A sweep too small to buy one unit of gem (`gemAmt` floors to zero) is not a failure: it
///      is a silent no-op that emits nothing, and the USDS likewise waits for the next sweep.
///
///      **Required ops ordering** (reversing the first two reverts `NudgeStreamer__NotWhitelisted`):
///        1. `batchMinter.setNudgeTokenWhitelist(gem /* USDC */, true)`
///        2. `nudgeStreamer.registerStream(batchMinter, gem, duration)`
///        3. `this.setNudgeStreamer(nudgeStreamer)`
///
///      ### The zap: swap size computed on-chain from synced reserves
///
///      `pool(sUSDSIn, minPhusdOut, minLP)` first calls `pair.sync()`, then reads the pair's
///      reserves and swaps exactly
///
///          s = (sqrt(r * (r * 3988009 + a * 3988000)) - r * 1997) / 1994
///
///      sUSDS -> phUSD (r = live sUSDS reserve, a = sUSDSIn, 0.30% fee; 3988009 = 1997^2,
///      3988000 = 4 * 997 * 1000, 1994 = 2 * 997). Swapping `s` leaves `(a - s)` sUSDS and the
///      bought phUSD in exactly the post-swap reserve ratio, so `addLiquidity` consumes both sides
///      to within wei-level rounding dust.
///
///      The `sync()` is load-bearing. V2 `swap()` credits the input as `balance - reserve`, so
///      tokens transferred to the pair without a sync (a donation) would be absorbed into our
///      swap and LP mint while `s`, sized from the stale reserves, no longer balances the two
///      legs: non-dust phUSD or sUSDS would be stranded here (e.g. ~229 phUSD on a 100k zap after
///      a 0.5% donation) or `pool()` would revert on its own quote's floors. Syncing folds the
///      donation into the reserves — to the pair's LPs, overwhelmingly this contract's POL — so
///      `s` balances again. `skim()` is deliberately never called: it would hand the donation to
///      an arbitrary recipient. `quotePool` cannot sync (it is `view`), so it sizes from the
///      pair's token balances, which are exactly the reserves `sync()` will produce.
///
///      Because `s` is derived from the reserves the swap
///      actually executes against, a front-run changes `s` and the price we buy at but never the
///      leftover; the worst it can do is a worse price, and that is what `minPhusdOut` and `minLP`
///      bound. The UI calls `quotePool(sUSDSIn)` and passes its outputs, reduced by a tolerance,
///      as the floors. It never passes `s`.
///
///      **Overflow bound.** `r * (r * 3988009 + a * 3988000)` is evaluated with checked
///      arithmetic. V2 reserves are `uint112` (< 5.2e33), and `a` is capped by this contract's
///      sUSDS balance which, to be added as liquidity at all, must also fit `uint112`; the product
///      is then below 5.2e33 * (5.2e33 * 4e6 * 2) ~= 2.2e74, far under 2^256 ~= 1.16e77. An
///      out-of-range input reverts rather than wrapping.
///
///      **Deliberately no price ceiling.** Pooling that pushes phUSD above the $1 mint price is
///      intended: arbitrageurs then mint phUSD through `PhusdStableMinter` and sell into the pair,
///      and every such mint adds collateral to the yield strategies.
///
///      ### Kill switches
///
///      - `incrementAuthVersion()` (owner) is the **pool-only** kill switch: it revokes every
///        authorized pooler at once, so `pool()` stops while mints (`dispatch`) keep working.
///      - `pause()` / `unpause()` come from the base and are `onlyMinter`, reachable only through
///        `NFTMinterV2.setDispatcherActive`. `dispatch` is `whenNotPaused`, so pausing blocks
///        dispatch and therefore every index-4 mint (and `pool()`, which is also gated).
///        There is no `pauser()` getter, so the Pauser contract cannot register this dispatcher.
///
///      ### Hook must be set before the first mint
///
///      `_dispatch` reverts `UniPoolerV2__HookNotSet` while `hook` is still the
///      DefaultDispatchHook the base constructor deployed, so a deployment that skips or
///      reorders `setHook` makes every index-4 mint revert loudly instead of silently accruing
///      zero phUSD mint-debt. Only that constructor-deployed instance is detected: an owner who
///      deliberately installs a freshly deployed DefaultDispatchHook opts out of the guard.
///
///      Guards live on this concrete dispatcher, never the abstract base. `_dispatch` overrides
///      only the internal extension point; `onlyMinter` / `whenNotPaused` / `nonReentrant` live on
///      the base's external `dispatch`.
contract UniPoolerV2 is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @dev 1e18 fixed-point scale, matching the Sky PSM WAD used for `tout`.
    uint256 internal constant WAD = 1e18;

    address internal immutable _sUSDS;
    address internal immutable _primeToken;
    address internal immutable _phUSD;
    address private immutable _router;
    address private immutable _pair;
    bool private immutable _sUSDSIsToken0;
    /// @dev The DefaultDispatchHook the base constructor deployed. `_dispatch` reverts while
    ///      `hook` still points at it. Named in the file's `_camelCase` immutable convention.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _defaultHook;

    uint256 public authVersion;
    mapping(address => uint256) public poolerAuthVersion;

    /// @notice Percentage (0..100) of each dispatched USDS amount to divert to the donation
    ///         on each dispatch. Defaults to 0 (donation disabled).
    uint256 public batchDonationSize;

    /// @notice Recipient of the donated USDC. address(0) disables the donation.
    address public batchMinter;

    /// @notice The Sky USDS↔USDC PSM (UsdsPsmWrapper). address(0) disables the donation.
    /// @dev Canonical live PSM (verify before deploy): Sky `UsdsPsmWrapper`
    ///      ("LitePSMWrapper-USDS-USDC") at 0xA188EEC8F81263234dA3622A406892F3D630f98c on
    ///      Ethereum mainnet (source: github.com/sky-ecosystem/usds-wrappers). Set via setPSM.
    address public psm;

    /// @notice WAD-scaled ceiling on the PSM `tout` (buy fee). A `tout` above this routes the
    ///         donation into the silent fallback (USDS parks) rather than ship a worse rate.
    /// @dev Defaults to 0.01e18 = 1%. Owner-settable so a legitimate Sky-governance `tout`
    ///      rise can be accommodated without redeploying. The live `tout` has historically
    ///      been ~0 (source: makerdao/dss-lite-psm; Sky PSM docs).
    uint256 public maxTout = 0.01e18;

    /// @notice The NudgeStreamer that buffers the donated USDC and releases it linearly to
    ///         `batchMinter`. Setter-only (starts `address(0)`); mandatory on the live-donation
    ///         branch only — see the contract-level dev notes.
    address public nudgeStreamer;

    event PoolerAuthorized(address indexed pooler, uint256 atAuthVersion);
    event PoolerDeauthorized(address indexed pooler);
    event AuthVersionIncremented(uint256 newAuthVersion);

    /// @notice Emitted on a successful zap. `swapIn` is the on-chain-derived `s`.
    event Pooled(address indexed pooler, uint256 sUSDSIn, uint256 swapIn, uint256 phusdOut, uint256 liquidity);

    event BatchDonationSizeSet(uint256 newSize);
    event BatchMinterSet(address newBatchMinter);
    event PSMSet(address newPSM);
    event MaxToutSet(uint256 newMaxTout);

    /// @notice Emitted when the nudgeStreamer address is updated.
    event NudgeStreamerUpdated(address indexed oldStreamer, address indexed newStreamer);

    /// @notice Emitted on a successful PSM donation. `usdsSpent` is the USDS pulled by the PSM
    ///         (incl. tout fee); `usdcDonated` is the USDC handed to the `nudgeStreamer` for
    ///         linear release to `batchMinter`.
    event BatchDonatedViaPSM(uint256 usdsSpent, uint256 usdcDonated, address indexed batchMinter);

    /// @notice Emitted when the donation call reverts (PSM outage, `tout` above `maxTout`,
    ///         streamer unset, stream unregistered) and the mint proceeds without it.
    ///         `usdsParked` USDS — the whole sweep — stays on the contract for the next dispatch
    ///         to retry. A sweep whose `gemAmt` floors to zero is NOT a skip: it is a silent
    ///         no-op that emits no event (the USDS still waits for the next sweep).
    event DonationSkipped(uint256 usdsParked);

    /// @notice The pair's tokens are not exactly {sUSDS, phUSD}.
    error UniPoolerV2__PairTokenMismatch(address token0, address token1);
    /// @notice `minPhusdOut` or `minLP` is zero. Zero floors are forbidden.
    error UniPoolerV2__ZeroMinimum();
    /// @notice `sUSDSIn` is zero.
    error UniPoolerV2__NothingToPool();
    /// @notice `sUSDSIn` exceeds the sUSDS this contract holds.
    error UniPoolerV2__InsufficientSUSDS(uint256 requested, uint256 available);
    /// @notice The pair has no liquidity (either reserve is zero).
    error UniPoolerV2__EmptyPair();
    /// @notice `sUSDSIn` is too small for the derived swap amount to be non-zero.
    error UniPoolerV2__AmountTooSmall();
    /// @notice The LP minted is below the caller's floor.
    error UniPoolerV2__InsufficientLP(uint256 liquidity, uint256 minLP);
    /// @notice `dispatch` was called while `hook` is still the constructor-deployed default.
    error UniPoolerV2__HookNotSet();
    /// @notice `pair_` is not the router factory's canonical sUSDS/phUSD pair (`expected`).
    error UniPoolerV2__PairNotCanonical(address expected, address actual);

    modifier onlyAuthorizedPooler() {
        require(poolerAuthVersion[msg.sender] == authVersion, "UniPoolerV2: caller not authorized pooler");
        _;
    }

    /// @param sUSDS_ The sUSDS ERC4626 wrapper; its `asset()` (USDS) becomes the prime token.
    /// @param phUSD_ phUSD.
    /// @param router_ Uniswap V2 Router02 (mainnet 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D).
    /// @param pair_ The phUSD/sUSDS Uniswap V2 pair. It must already exist as the router
    ///        factory's canonical sUSDS/phUSD pair (`IUniswapV2Factory(router_.factory())
    ///        .getPair(sUSDS_, phUSD_) == pair_`), so the pair whose reserves size the zap is the
    ///        pair the router swaps and adds liquidity against. It may have zero reserves: the
    ///        pair is created first, the pooler deployed, then the pair seeded.
    /// @param initialOwner The owner.
    constructor(address sUSDS_, address phUSD_, address router_, address pair_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(sUSDS_ != address(0), "UniPoolerV2: zero sUSDS");
        require(phUSD_ != address(0), "UniPoolerV2: zero phUSD");
        require(router_ != address(0), "UniPoolerV2: zero router");
        require(pair_ != address(0), "UniPoolerV2: zero pair");

        address t0 = IUniswapV2Pair(pair_).token0();
        address t1 = IUniswapV2Pair(pair_).token1();
        bool sFirst = t0 == sUSDS_ && t1 == phUSD_;
        if (!sFirst && !(t0 == phUSD_ && t1 == sUSDS_)) revert UniPoolerV2__PairTokenMismatch(t0, t1);

        address canonical = IUniswapV2Factory(IUniswapV2Router02(router_).factory()).getPair(sUSDS_, phUSD_);
        if (canonical != pair_) revert UniPoolerV2__PairNotCanonical(canonical, pair_);

        _sUSDS = sUSDS_;
        _primeToken = IERC4626(sUSDS_).asset();
        _phUSD = phUSD_;
        _router = router_;
        _pair = pair_;
        _sUSDSIsToken0 = sFirst;
        // The base constructor has already run, so `hook` is its DefaultDispatchHook.
        _defaultHook = address(hook);
        authVersion = 1;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view override returns (address) {
        return _primeToken;
    }

    /// @notice Returns the sUSDS (ERC4626 wrapper) address.
    function sUSDS() external view returns (address) {
        return _sUSDS;
    }

    /// @notice Returns the phUSD address.
    function phUSD() external view returns (address) {
        return _phUSD;
    }

    /// @notice Returns the Uniswap V2 Router02 address.
    function router() external view returns (address) {
        return _router;
    }

    /// @notice Returns the phUSD/sUSDS Uniswap V2 pair (also the LP token).
    function pair() external view returns (address) {
        return _pair;
    }

    /// @notice True when sUSDS is the pair's token0.
    function sUSDSIsToken0() external view returns (bool) {
        return _sUSDSIsToken0;
    }

    /// @notice Sets or revokes an authorized pooler. Only callable by owner.
    /// @param pooler The address to authorize or deauthorize.
    /// @param authorized True to authorize, false to deauthorize.
    function setAuthorizedPooler(address pooler, bool authorized) external onlyOwner {
        require(pooler != address(0), "UniPoolerV2: zero pooler");
        if (authorized) {
            poolerAuthVersion[pooler] = authVersion;
            emit PoolerAuthorized(pooler, authVersion);
        } else {
            delete poolerAuthVersion[pooler];
            emit PoolerDeauthorized(pooler);
        }
    }

    /// @notice Increments the auth version, mass-revoking all current pooler authorizations.
    /// @dev The pool-only kill switch: `pool()` stops for every pooler; mints keep working.
    function incrementAuthVersion() external onlyOwner {
        authVersion += 1;
        emit AuthVersionIncremented(authVersion);
    }

    /// @notice Sets the batch-donation percentage (0..100) of each dispatched USDS amount to
    ///         divert to the PSM donation. Setting 0 disables the donation.
    /// @param newSize The new percentage. Must be <= 100.
    function setBatchDonationSize(uint256 newSize) external onlyOwner {
        require(newSize <= 100, "UniPoolerV2: size > 100");
        batchDonationSize = newSize;
        emit BatchDonationSizeSet(newSize);
    }

    /// @notice Sets the recipient of the donated USDC. address(0) is allowed and disables
    ///         the donation even if batchDonationSize > 0.
    /// @param newBatchMinter The new recipient address (or address(0) to disable).
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        batchMinter = newBatchMinter;
        emit BatchMinterSet(newBatchMinter);
    }

    /// @notice Sets the Sky USDS↔USDC PSM used for the donation. Must be non-zero.
    /// @dev Mirrors the auditable, re-pointable shape of the old `setSwapConfig`.
    /// @param newPSM The PSM (UsdsPsmWrapper) address.
    function setPSM(address newPSM) external onlyOwner {
        require(newPSM != address(0), "UniPoolerV2: zero psm");
        psm = newPSM;
        emit PSMSet(newPSM);
    }

    /// @notice Sets the WAD-scaled ceiling on the PSM `tout` accepted for a donation.
    /// @param newMaxTout The new ceiling (1e18 == 100%).
    function setMaxTout(uint256 newMaxTout) external onlyOwner {
        maxTout = newMaxTout;
        emit MaxToutSet(newMaxTout);
    }

    /// @notice Updates the NudgeStreamer the PSM donation is routed through. Only callable by
    ///         the owner. Must be non-zero (there is no "unset" path — a pooler that should not
    ///         donate is disabled via `setBatchMinter(0)` / `setBatchDonationSize(0)`).
    /// @dev Wire this LAST: the streamer must already have `registerStream(batchMinter, gem, …)`
    ///      called on it, which in turn requires the batch-minter to have whitelisted the gem.
    /// @param newStreamer The new streamer address. Must be non-zero.
    function setNudgeStreamer(address newStreamer) external onlyOwner {
        require(newStreamer != address(0), "UniPoolerV2: zero nudgeStreamer");
        address old = nudgeStreamer;
        nudgeStreamer = newStreamer;
        emit NudgeStreamerUpdated(old, newStreamer);
    }

    /// @notice Dispatches tokens: wraps the pooling portion of USDS into sUSDS, then attempts
    ///         a silent PSM donation of the remaining raw USDS toward `batchMinter` via the
    ///         `nudgeStreamer`.
    /// @dev Donation is carved out **only when enabled** (batchMinter + psm set, size > 0); when
    ///      disabled the full `amount` is wrapped so nothing is stranded. The donation sweeps
    ///      `balanceOf(USDS)` — not just this dispatch's share — so USDS stranded by a prior
    ///      failed donation is automatically retried (the recovery mechanism; no separate
    ///      retry function needed). The conversion is isolated in `try this._psmDonate{} catch`
    ///      so a reverting donation (PSM outage, `tout` above `maxTout`, empty or short reserve,
    ///      streamer unset, stream unregistered) parks the USDS and emits `DonationSkipped`
    ///      instead of reverting the mint; a sweep whose `gemAmt` floors to zero is a silent
    ///      no-op with no event. The base class then calls `hook.onDispatch(minter, amount)`
    ///      with the **gross** amount, so mint-debt accrues on the full dispatched USDS
    ///      regardless of donation outcome.
    /// @dev Reverts `UniPoolerV2__HookNotSet` while `hook` is still the constructor-deployed
    ///      DefaultDispatchHook (see contract dev notes); the revert fails the whole mint.
    /// @param amount The FOT-adjusted amount of USDS to dispatch.
    function _dispatch(
        address,
        uint256 amount,
        bytes calldata /*extraData*/
    )
        internal
        override
    {
        if (address(hook) == _defaultHook) revert UniPoolerV2__HookNotSet();

        bool donationEnabled = batchMinter != address(0) && psm != address(0) && batchDonationSize > 0;

        uint256 donationUSDS = donationEnabled ? (amount * batchDonationSize) / 100 : 0;
        uint256 poolingUSDS = amount - donationUSDS;

        // Wrap ONLY the pooling portion -> sUSDS (this is what pool() will later consume).
        if (poolingUSDS > 0) {
            IERC20(_primeToken).forceApprove(_sUSDS, poolingUSDS);
            IERC4626(_sUSDS).deposit(poolingUSDS, address(this));
        }

        // Sweep ALL remaining raw USDS (this dispatch's donation share + any USDS stranded by
        // a previous failed donation) and attempt the PSM conversion. Silent on failure.
        if (donationEnabled) {
            uint256 remainingUSDS = IERC20(_primeToken).balanceOf(address(this));
            if (remainingUSDS > 0) {
                try this._psmDonate(remainingUSDS) {}
                catch {
                    // The donation call reverted: the USDS parks on the contract for retry.
                    emit DonationSkipped(remainingUSDS);
                }
            }
        }
    }

    /// @notice Failure-isolated USDS->USDC donation via the Sky PSM, streamed to `batchMinter`
    ///         through the `nudgeStreamer`. Self-gated `external` so any revert (tout ceiling,
    ///         empty reserve, short reserve, streamer unset, stream not registered) rolls back
    ///         the entire approve+buyGem+collectNudge atomically — the `_dispatch` try/catch
    ///         then leaves the swept USDS untouched (parked for the next dispatch to retry) and
    ///         emits `DonationSkipped`. A `gemAmt` that floors to zero returns without reverting
    ///         and without any event: the USDS stays for the next sweep.
    /// @dev MUST be called only via `try this._psmDonate{}` from `_dispatch`.
    /// @dev Story 047: the streamer hop lives INSIDE this envelope on purpose. A streamer
    ///      misconfiguration therefore parks USDS and emits `DonationSkipped` rather than
    ///      reverting the mint — quiet, but the deliberate preservation of the isolation
    ///      contract. See the contract-level dev notes.
    /// @param usdsAmount Raw USDS available to convert (this dispatch's share + any stranded).
    function _psmDonate(uint256 usdsAmount) external {
        require(msg.sender == address(this), "UniPoolerV2: only self");

        uint256 tout = ISkyPSM(psm).tout();
        require(tout <= maxTout, "UniPoolerV2: tout too high");

        // Size USDC out (6dp) from USDS in (18dp), net of tout. FLOOR -> dust accrues to
        // the protocol (never over-credits). Mirrors the real PSM buyGem math:
        //   usdsInWad = gemAmt * to18ConversionFactor; if (tout>0) usdsInWad += usdsInWad*tout/WAD
        // so the max gemAmt affordable from `usdsAmount` is:
        //   gemAmt = floor( usdsAmount * WAD / (conv * (WAD + tout)) )
        // (source: makerdao/dss-lite-psm DssLitePsm._buyGem; conv=to18ConversionFactor=1e12 USDC.)
        uint256 conv = ISkyPSM(psm).to18ConversionFactor();
        uint256 gemAmt = (usdsAmount * WAD) / (conv * (WAD + tout));

        // The `gemAmt > 0` guard is load-bearing, not cosmetic: `collectNudge` reverts
        // `NudgeStreamer__ZeroAmount()` on a zero amount, so a dust-sized sweep whose gemAmt
        // floors to zero must short-circuit to a clean no-op here rather than propagate a
        // revert into the caller's catch. That no-op emits nothing (no `DonationSkipped`, no
        // `BatchDonatedViaPSM`); the dust USDS simply stays put and is re-swept on the next
        // dispatch.
        if (gemAmt > 0) {
            // Exact USDS the PSM will pull for this gemAmt (<= usdsAmount; remainder is dust).
            uint256 usdsSpent = gemAmt * conv * (WAD + tout) / WAD;

            IERC20(_primeToken).forceApprove(psm, usdsSpent);
            // Story 047: USDC lands HERE, not on the batch-minter — it is streamed on below.
            ISkyPSM(psm).buyGem(address(this), gemAmt);
            IERC20(_primeToken).forceApprove(psm, 0); // tidy allowance.

            // Push the freshly-bought USDC through the streamer, which buffers it and releases
            // it linearly to `batchMinter`. `forceApprove` (not `approve`) with the EXACT
            // gemAmt because the gem is USDC, which rejects a plain `approve` over a non-zero
            // residual; `collectNudge` consumes the whole allowance in this same call, so
            // nothing lingers and no infinite approval is ever handed out.
            address streamer = nudgeStreamer;
            require(streamer != address(0), "UniPoolerV2: nudgeStreamer unset");
            address gem = ISkyPSM(psm).gem();
            IERC20(gem).forceApprove(streamer, gemAmt);
            INudgeStreamer(streamer).collectNudge(batchMinter, gem, gemAmt);

            emit BatchDonatedViaPSM(usdsSpent, gemAmt, batchMinter);
        }
    }

    /// @notice Zaps `sUSDSIn` of the contract's sUSDS into the phUSD/sUSDS V2 pair. The pair is
    ///         synced first, then the swap amount is derived on-chain from the synced reserves
    ///         (see contract dev notes); the LP stays on this contract.
    /// @dev The router's `amountAMin`/`amountBMin` are 0: the two sides are sized from the same
    ///      reserves inside this transaction, so they are balanced by construction, and the
    ///      overall outcome is bounded by `minPhusdOut` (swap floor) and `minLP` (LP floor).
    /// @param sUSDSIn sUSDS to pool. Must be non-zero and at most the contract's sUSDS balance.
    /// @param minPhusdOut Floor on phUSD bought by the swap leg. Must be non-zero.
    /// @param minLP Floor on LP minted. Must be non-zero.
    function pool(uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP)
        external
        onlyAuthorizedPooler
        whenNotPaused
        nonReentrant
    {
        if (minPhusdOut == 0 || minLP == 0) revert UniPoolerV2__ZeroMinimum();
        if (sUSDSIn == 0) revert UniPoolerV2__NothingToPool();
        uint256 available = IERC20(_sUSDS).balanceOf(address(this));
        if (sUSDSIn > available) revert UniPoolerV2__InsufficientSUSDS(sUSDSIn, available);

        // Fold any unsynced donation into the reserves before sizing (see contract dev notes).
        IUniswapV2Pair(_pair).sync();
        (uint256 rS,) = _reserves();
        uint256 s = _swapAmount(rS, sUSDSIn);

        // Swap s sUSDS -> phUSD against the same reserves s was derived from.
        address[] memory path = new address[](2);
        path[0] = _sUSDS;
        path[1] = _phUSD;
        IERC20(_sUSDS).forceApprove(_router, s);
        uint256[] memory amounts =
            IUniswapV2Router02(_router).swapExactTokensForTokens(s, minPhusdOut, path, address(this), block.timestamp);
        IERC20(_sUSDS).forceApprove(_router, 0);
        uint256 phusdOut = amounts[1];

        // Add (a - s) sUSDS + phusdOut phUSD; LP is minted to this contract (LP custody: pooler).
        uint256 sUSDSRemaining = sUSDSIn - s;
        IERC20(_sUSDS).forceApprove(_router, sUSDSRemaining);
        IERC20(_phUSD).forceApprove(_router, phusdOut);
        (,, uint256 liquidity) = IUniswapV2Router02(_router)
            .addLiquidity(_sUSDS, _phUSD, sUSDSRemaining, phusdOut, 0, 0, address(this), block.timestamp);
        if (liquidity < minLP) revert UniPoolerV2__InsufficientLP(liquidity, minLP);
        IERC20(_sUSDS).forceApprove(_router, 0);
        IERC20(_phUSD).forceApprove(_router, 0);

        emit Pooled(msg.sender, sUSDSIn, s, phusdOut, liquidity);
    }

    /// @notice Quotes `pool(sUSDSIn, …)` against the pair's live token balances. The UI passes
    ///         `phusdOut` and `expectedLP`, reduced by a tolerance, as `pool`'s floors.
    /// @dev Sizes from `balanceOf(pair)` rather than `getReserves()` because `pool()` syncs
    ///      before sizing, and the synced reserves are exactly those balances; quoting from stale
    ///      reserves after an unsynced donation would mis-size the zap and the floors. Reverts `UniPoolerV2__EmptyPair` on an empty pair and `UniPoolerV2__AmountTooSmall`
    ///      when the derived swap is zero. Does not check the contract's balance, so it can quote
    ///      hypothetical amounts. `expectedLP` assumes the factory protocol fee is off; when it is
    ///      on, the pair mints the fee share before ours, which only raises our LP, so the quote
    ///      remains a valid floor.
    /// @return swapIn The sUSDS the zap will swap (`s`).
    /// @return phusdOut The phUSD that swap returns (0.30% fee, V2 `getAmountOut`).
    /// @return expectedLP The LP `addLiquidity` will mint.
    function quotePool(uint256 sUSDSIn) external view returns (uint256 swapIn, uint256 phusdOut, uint256 expectedLP) {
        (uint256 rS, uint256 rP) = _balances();
        swapIn = _swapAmount(rS, sUSDSIn);

        uint256 inWithFee = swapIn * 997;
        phusdOut = (inWithFee * rP) / (rS * 1000 + inWithFee);

        // Post-swap reserves, then the router's optimal-amount selection.
        uint256 rS2 = rS + swapIn;
        uint256 rP2 = rP - phusdOut;
        uint256 amtS = sUSDSIn - swapIn;
        uint256 amtP = (amtS * rP2) / rS2;
        if (amtP > phusdOut) {
            amtP = phusdOut;
            amtS = (phusdOut * rS2) / rP2;
        }
        uint256 ts = IUniswapV2Pair(_pair).totalSupply();
        expectedLP = Math.min((amtS * ts) / rS2, (amtP * ts) / rP2);
    }

    /// @dev Stored (sUSDS, phUSD) reserves — synced by `pool()` just before. Reverts on an
    ///      empty pair.
    function _reserves() internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(_pair).getReserves();
        (rS, rP) = _sUSDSIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rS == 0 || rP == 0) revert UniPoolerV2__EmptyPair();
    }

    /// @dev The pair's (sUSDS, phUSD) token balances — the reserves `sync()` would set. Reverts
    ///      on an empty pair, exactly as `_reserves()` does after a sync.
    function _balances() internal view returns (uint256 bS, uint256 bP) {
        bS = IERC20(_sUSDS).balanceOf(_pair);
        bP = IERC20(_phUSD).balanceOf(_pair);
        if (bS == 0 || bP == 0) revert UniPoolerV2__EmptyPair();
    }

    /// @dev Closed-form optimal single-sided zap swap for a 0.30%-fee constant-product pair:
    ///      s = (sqrt(r * (r * 3988009 + a * 3988000)) - r * 1997) / 1994.
    ///      sqrt(r^2 * 1997^2 + …) >= r * 1997, so the subtraction never underflows. See the
    ///      contract dev notes for the overflow bound.
    function _swapAmount(uint256 r, uint256 a) internal pure returns (uint256 s) {
        s = (Math.sqrt(r * (r * 3988009 + a * 3988000)) - r * 1997) / 1994;
        if (s == 0) revert UniPoolerV2__AmountTooSmall();
    }

    /// @notice Owner escape hatch. Transfers `amount` of any ERC20 token held by
    ///         this contract to `to`. Used to recover tokens stuck on the dispatcher
    ///         (e.g., accidental transfers, airdrops, or USDS parked by a skipped
    ///         donation). Not pause-gated — escape hatch must function during a pause.
    /// @dev    This is also the LP exit: the pooler holds the phUSD/sUSDS V2 LP it mints, and
    ///         the owner withdraws it with `rescueERC20(pair, to, amount)` (there is no
    ///         dedicated LP-withdraw function).
    /// @param  token  The ERC20 token to rescue.
    /// @param  to     Recipient of the rescued tokens. Must be non-zero.
    /// @param  amount Amount of `token` to transfer.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "UniPoolerV2: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
