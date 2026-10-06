// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router02} from "../interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../interfaces/uniswap/IUniswapV2Pair.sol";

/// @notice The read-only surface of the new UniPoolerV2 the escrow seeds.
interface ICutoverNewPooler {
    function pair() external view returns (address);
    function router() external view returns (address);
    function sUSDS() external view returns (address);
    function phUSD() external view returns (address);
}

/// @notice The read-only surface of the old (Balancer-era) pooler the escrow unwinds.
interface ICutoverOldPooler {
    function pool() external view returns (address);
    function primeToken() external view returns (address);
    function sUSDS() external view returns (address);
}

/// @notice The two V3 Router exit entry points (mainnet selectors `0x51682750`, `0x08c04793`).
interface IV3RouterExit {
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);

    function removeLiquidityRecovery(address pool, uint256 exactBptAmountIn, uint256[] memory minAmountsOut)
        external
        payable
        returns (uint256[] memory amountsOut);
}

/// @notice The Uniswap V2 pair's `skim`, absent from the repo's minimal pair interface.
interface ICutoverPairSkim {
    function skim(address to) external;
}

/// @title UniPoolerCutoverEscrow
/// @notice One-shot custody contract for the Balancexit cutover. It receives the old pooler's pool
///         tokens (BPT) and parked USDS, exits the BPT through the Balancer V3 Router, and seeds
///         the new UniPoolerV2's empty sUSDS/phUSD Uniswap V2 pair with everything recovered, so
///         that no cutover funds ever pass through an externally owned account.
/// @dev ### Custody guarantee
///
///      No function takes a caller-chosen recipient. The only ways value can leave this contract:
///      - `exitAndSeed`: BPT to the V3 Router (burned against the router's exact, then reset,
///        allowance); sUSDS and phUSD to the pair via Router02 `addLiquidity`, with the LP minted
///        to `newPooler`; and, if the empty pair holds an unsynced donation, `skim(newPooler)`.
///      - `wrapUsds`: USDS into sUSDS via `IERC4626.deposit`, shares credited to `newPooler`.
///      - `abort`: the whole BPT, sUSDS, phUSD and USDS balances back to `oldPooler`, where the
///        old pooler's owner can recover them (`withdrawBPT` / `rescueERC20`).
///
///      There is no owner, no `receive`/`fallback`, and no setter: every address is immutable.
///      The `operator` gate exists only to deny strangers control of timing and slippage floors
///      (sandwiching, front-running the cutover broadcast between `withdrawBPT` and
///      `exitAndSeed`, griefing `abort`). The custody guarantee does not depend on it.
///
///      ### One-shot
///
///      `exitAndSeed` requires an empty pair and leaves it seeded, so it can succeed at most
///      once. `wrapUsds` and `abort` may be called repeatedly; both only ever pay protocol
///      contracts.
///
///      ### Whole-balance seed
///
///      The seed uses the escrow's entire sUSDS and phUSD balances rather than the exit's deltas,
///      so stray tokens anyone sent are swept into protocol liquidity instead of being stranded.
///      A non-proportional stray balance shifts the seeded price slightly; the operator chooses
///      when to call. The escrow does not recompute the live proportional share: `minAmountsOut`
///      (non-zero per token, computed off-chain by the caller) is the exit's slippage guard.
contract UniPoolerCutoverEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Which V3 Router exit `exitAndSeed` uses. Chosen by the operator, never by the clock.
    /// @dev `PROPORTIONAL` is the normal exit; `RECOVERY` works only once the pool is in Recovery
    ///      Mode (e.g. after a pause), when the proportional exit reverts.
    enum ExitMode {
        PROPORTIONAL,
        RECOVERY
    }

    /// @notice The maximum distance of `deadline` into the future, mirroring the cutover core.
    uint256 public constant MAX_DEADLINE_WINDOW = 1 days;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _operator;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _newPooler;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _oldPooler;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _v3Router;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _bpt;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _usds;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _sUSDS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _phUSD;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _pair;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address private immutable _uniRouter;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bool private immutable _sUSDSIsToken0;

    /// @notice Emitted once the BPT has been exited and the pair seeded.
    /// @param bptIn The BPT exited (the escrow's whole BPT balance).
    /// @param sUSDSSeeded The sUSDS added to the pair (the escrow's whole sUSDS balance).
    /// @param phUSDSeeded The phUSD added to the pair (the escrow's whole phUSD balance).
    /// @param liquidity The LP minted to `newPooler`.
    /// @param mode The exit used.
    event Seeded(uint256 bptIn, uint256 sUSDSSeeded, uint256 phUSDSeeded, uint256 liquidity, ExitMode mode);

    /// @notice Emitted when an unsynced donation sitting on the still-empty pair is skimmed.
    /// @param recipient Always `newPooler`.
    /// @param amount0 Token0 skimmed.
    /// @param amount1 Token1 skimmed.
    event PairSkimmed(address indexed recipient, uint256 amount0, uint256 amount1);

    /// @notice Emitted when the escrow's USDS is wrapped into sUSDS credited to `newPooler`.
    /// @param usdsWrapped The USDS deposited.
    /// @param shares The sUSDS shares minted to `newPooler`.
    event UsdsWrapped(uint256 usdsWrapped, uint256 shares);

    /// @notice Emitted when the escrow returns its whole balances to the old pooler.
    /// @param recipient Always `oldPooler`.
    /// @param bpt BPT returned.
    /// @param sUSDSAmount sUSDS returned.
    /// @param phUSDAmount phUSD returned.
    /// @param usdsAmount USDS returned.
    event Aborted(address indexed recipient, uint256 bpt, uint256 sUSDSAmount, uint256 phUSDAmount, uint256 usdsAmount);

    /// @notice The caller is not the immutable `operator`.
    error UniPoolerCutoverEscrow__NotOperator(address caller);
    /// @notice The old pooler's sUSDS differs from the new pooler's.
    error UniPoolerCutoverEscrow__SUSDSMismatch(address oldPoolerSUSDS, address newPoolerSUSDS);
    /// @notice The old pooler's prime token is not `sUSDS.asset()`.
    error UniPoolerCutoverEscrow__UsdsMismatch(address primeToken, address sUSDSAsset);
    /// @notice The pair still has reserves or token balances after the optional skim.
    error UniPoolerCutoverEscrow__PairNotEmpty(uint256 reserve0, uint256 reserve1, uint256 balance0, uint256 balance1);
    /// @notice The escrow holds no BPT.
    error UniPoolerCutoverEscrow__NoBPT();
    /// @notice `minAmountsOut` does not have exactly two entries.
    error UniPoolerCutoverEscrow__BadMinAmountsLength(uint256 length);
    /// @notice `minAmountsOut[index]` is zero. Zero floors are forbidden.
    error UniPoolerCutoverEscrow__ZeroMinAmountOut(uint256 index);
    /// @notice `deadline` is not in `(block.timestamp, block.timestamp + MAX_DEADLINE_WINDOW]`.
    error UniPoolerCutoverEscrow__BadDeadline(uint256 deadline, uint256 timestamp);
    /// @notice BPT remained on the escrow after the exit.
    error UniPoolerCutoverEscrow__BPTRemaining(uint256 remaining);
    /// @notice The exit left the escrow with no sUSDS or no phUSD to seed.
    error UniPoolerCutoverEscrow__NothingToSeed(uint256 sUSDSAmount, uint256 phUSDAmount);
    /// @notice Router02 did not consume exactly the desired amounts.
    error UniPoolerCutoverEscrow__SeedNotExact(uint256 sUSDSUsed, uint256 phUSDUsed);
    /// @notice No LP was minted, or `newPooler`'s LP balance did not rise by `liquidity`.
    error UniPoolerCutoverEscrow__LPNotMinted(uint256 liquidity, uint256 lpReceived);
    /// @notice The pair's reserves after the seed differ from the seeded amounts.
    error UniPoolerCutoverEscrow__ReserveMismatch(uint256 reserveSUSDS, uint256 reservePhUSD);
    /// @notice A token balance remained on the escrow after the operation.
    error UniPoolerCutoverEscrow__BalanceRemaining(address token, uint256 remaining);
    /// @notice The escrow holds no USDS to wrap.
    error UniPoolerCutoverEscrow__NoUSDS();

    /// @notice Restricts a function to the immutable `operator`.
    modifier onlyOperator() {
        if (msg.sender != _operator) revert UniPoolerCutoverEscrow__NotOperator(msg.sender);
        _;
    }

    /// @param operator_ The only address allowed to call the state-changing functions (the cutover
    ///        sender; mainnet `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`).
    /// @param newPooler_ The UniPoolerV2 to seed; its `pair()`, `router()`, `sUSDS()` and `phUSD()`
    ///        are read and fixed here.
    /// @param oldPooler_ The old pooler (mainnet `0x7f6874332c4629429d70D15f685A8230323F11F1`);
    ///        its `pool()` (snapshotted, since it is mutable there) and `primeToken()` are read here.
    /// @param v3Router_ The Balancer V3 Router (mainnet `0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd`),
    ///        passed in because the old pooler keeps its router private.
    constructor(address operator_, address newPooler_, address oldPooler_, address v3Router_) {
        require(operator_ != address(0), "UniPoolerCutoverEscrow: zero operator");
        require(newPooler_ != address(0), "UniPoolerCutoverEscrow: zero newPooler");
        require(oldPooler_ != address(0), "UniPoolerCutoverEscrow: zero oldPooler");
        require(v3Router_ != address(0), "UniPoolerCutoverEscrow: zero v3Router");

        address pair_ = ICutoverNewPooler(newPooler_).pair();
        address uniRouter_ = ICutoverNewPooler(newPooler_).router();
        address sUSDS_ = ICutoverNewPooler(newPooler_).sUSDS();
        address phUSD_ = ICutoverNewPooler(newPooler_).phUSD();
        address bpt_ = ICutoverOldPooler(oldPooler_).pool();
        address usds_ = ICutoverOldPooler(oldPooler_).primeToken();
        require(pair_ != address(0), "UniPoolerCutoverEscrow: zero pair");
        require(uniRouter_ != address(0), "UniPoolerCutoverEscrow: zero router");
        require(sUSDS_ != address(0), "UniPoolerCutoverEscrow: zero sUSDS");
        require(phUSD_ != address(0), "UniPoolerCutoverEscrow: zero phUSD");
        require(bpt_ != address(0), "UniPoolerCutoverEscrow: zero pool");
        require(usds_ != address(0), "UniPoolerCutoverEscrow: zero USDS");

        address oldSUSDS = ICutoverOldPooler(oldPooler_).sUSDS();
        if (oldSUSDS != sUSDS_) revert UniPoolerCutoverEscrow__SUSDSMismatch(oldSUSDS, sUSDS_);
        address asset = IERC4626(sUSDS_).asset();
        if (asset != usds_) revert UniPoolerCutoverEscrow__UsdsMismatch(usds_, asset);

        _operator = operator_;
        _newPooler = newPooler_;
        _oldPooler = oldPooler_;
        _v3Router = v3Router_;
        _bpt = bpt_;
        _usds = usds_;
        _sUSDS = sUSDS_;
        _phUSD = phUSD_;
        _pair = pair_;
        _uniRouter = uniRouter_;
        _sUSDSIsToken0 = IUniswapV2Pair(pair_).token0() == sUSDS_;
    }

    // ─────────────────────────────── Operator actions ───────────────────────────────

    /// @notice Exits the escrow's whole BPT balance through the V3 Router and seeds the new
    ///         pooler's empty pair with the escrow's whole sUSDS and phUSD balances, minting the LP
    ///         to `newPooler`. Atomic: any failed check reverts everything.
    /// @dev Steps: (1) require an empty pair, skimming an unsynced donation to `newPooler` first;
    ///      (2) require BPT > 0; (3) validate `minAmountsOut` and `deadline`; (4) exact-approve the
    ///      V3 Router (it burns the BPT by spending ITS allowance), exit, reset the approval;
    ///      (5) exact-approve Router02 and `addLiquidity` with mins == desired (an empty pair
    ///      consumes the desired amounts exactly), then verify the LP and reserves; (6) require the
    ///      escrow holds no BPT, sUSDS or phUSD.
    /// @param mode `PROPORTIONAL` or `RECOVERY` (see `ExitMode`).
    /// @param minAmountsOut Per-token exit floors in Balancer pool-token order; two entries, all
    ///        non-zero.
    /// @param deadline Router02 deadline; must lie in `(block.timestamp, block.timestamp + 1 days]`.
    /// @return liquidity The LP minted to `newPooler`.
    function exitAndSeed(ExitMode mode, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        onlyOperator
        nonReentrant
        returns (uint256 liquidity)
    {
        // 1. The pair must be empty.
        _requireEmptyPair();

        // 2. BPT in: the escrow's whole balance.
        uint256 bptIn = IERC20(_bpt).balanceOf(address(this));
        if (bptIn == 0) revert UniPoolerCutoverEscrow__NoBPT();

        // 3. Argument checks.
        if (minAmountsOut.length != 2) revert UniPoolerCutoverEscrow__BadMinAmountsLength(minAmountsOut.length);
        for (uint256 i = 0; i < 2; i++) {
            if (minAmountsOut[i] == 0) revert UniPoolerCutoverEscrow__ZeroMinAmountOut(i);
        }
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_DEADLINE_WINDOW) {
            revert UniPoolerCutoverEscrow__BadDeadline(deadline, block.timestamp);
        }

        // 4. Exit.
        _exit(mode, bptIn, minAmountsOut);

        // 5. Seed with the whole balances.
        uint256 s = IERC20(_sUSDS).balanceOf(address(this));
        uint256 p = IERC20(_phUSD).balanceOf(address(this));
        liquidity = _seed(s, p, deadline);

        // 6. Post-conditions.
        _requireNoBalance(_bpt);
        _requireNoBalance(_sUSDS);
        _requireNoBalance(_phUSD);

        emit Seeded(bptIn, s, p, liquidity, mode);
    }

    /// @notice Wraps the escrow's whole USDS balance into sUSDS, crediting the shares to
    ///         `newPooler`. Used for the old pooler's parked USDS.
    /// @return shares The sUSDS shares minted to `newPooler`.
    function wrapUsds() external onlyOperator nonReentrant returns (uint256 shares) {
        uint256 amt = IERC20(_usds).balanceOf(address(this));
        if (amt == 0) revert UniPoolerCutoverEscrow__NoUSDS();
        IERC20(_usds).forceApprove(_sUSDS, amt);
        shares = IERC4626(_sUSDS).deposit(amt, _newPooler);
        IERC20(_usds).forceApprove(_sUSDS, 0);
        _requireNoBalance(_usds);
        emit UsdsWrapped(amt, shares);
    }

    /// @notice Returns the escrow's whole BPT, sUSDS, phUSD and USDS balances to `oldPooler`, the
    ///         only abort destination. All four are recoverable there by the old pooler's owner.
    function abort() external onlyOperator nonReentrant {
        uint256 b = _returnAll(_bpt);
        uint256 s = _returnAll(_sUSDS);
        uint256 p = _returnAll(_phUSD);
        uint256 u = _returnAll(_usds);
        emit Aborted(_oldPooler, b, s, p, u);
    }

    // ─────────────────────────────── Views ───────────────────────────────

    /// @notice The only address allowed to call `exitAndSeed`, `wrapUsds` and `abort`.
    function operator() external view returns (address) {
        return _operator;
    }

    /// @notice The UniPoolerV2 that receives the LP, the skim and the wrapped sUSDS.
    function newPooler() external view returns (address) {
        return _newPooler;
    }

    /// @notice The old pooler: the only `abort` destination.
    function oldPooler() external view returns (address) {
        return _oldPooler;
    }

    /// @notice The Balancer V3 Router used for the exit.
    function v3Router() external view returns (address) {
        return _v3Router;
    }

    /// @notice The BPT, snapshotted from the old pooler's `pool()` at construction.
    function bpt() external view returns (address) {
        return _bpt;
    }

    /// @notice USDS: the old pooler's prime token and `sUSDS.asset()`.
    function usds() external view returns (address) {
        return _usds;
    }

    /// @notice sUSDS, shared by both poolers.
    function sUSDS() external view returns (address) {
        return _sUSDS;
    }

    /// @notice phUSD.
    function phUSD() external view returns (address) {
        return _phUSD;
    }

    /// @notice The new pooler's sUSDS/phUSD Uniswap V2 pair.
    function pair() external view returns (address) {
        return _pair;
    }

    /// @notice The new pooler's Uniswap V2 Router02.
    function uniRouter() external view returns (address) {
        return _uniRouter;
    }

    // ─────────────────────────────── Internals ───────────────────────────────

    /// @dev Skims an unsynced donation on a reserve-less pair to `newPooler`, then requires zero
    ///      reserves and zero token balances. A synced donation therefore reverts (DoS only).
    function _requireEmptyPair() internal {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(_pair).getReserves();
        address t0 = IUniswapV2Pair(_pair).token0();
        address t1 = IUniswapV2Pair(_pair).token1();
        uint256 b0 = IERC20(t0).balanceOf(_pair);
        uint256 b1 = IERC20(t1).balanceOf(_pair);
        if (r0 == 0 && r1 == 0 && (b0 != 0 || b1 != 0)) {
            ICutoverPairSkim(_pair).skim(_newPooler);
            emit PairSkimmed(_newPooler, b0, b1);
            (r0, r1,) = IUniswapV2Pair(_pair).getReserves();
            b0 = IERC20(t0).balanceOf(_pair);
            b1 = IERC20(t1).balanceOf(_pair);
        }
        if (r0 != 0 || r1 != 0 || b0 != 0 || b1 != 0) {
            revert UniPoolerCutoverEscrow__PairNotEmpty(r0, r1, b0, b1);
        }
    }

    /// @dev Exact-approves the V3 Router for `bptIn`, exits by `mode`, resets the approval and
    ///      requires every BPT to be gone.
    function _exit(ExitMode mode, uint256 bptIn, uint256[] calldata minAmountsOut) internal {
        IERC20(_bpt).forceApprove(_v3Router, bptIn);
        if (mode == ExitMode.PROPORTIONAL) {
            IV3RouterExit(_v3Router).removeLiquidityProportional(_bpt, bptIn, minAmountsOut, false, "");
        } else {
            IV3RouterExit(_v3Router).removeLiquidityRecovery(_bpt, bptIn, minAmountsOut);
        }
        IERC20(_bpt).forceApprove(_v3Router, 0);
        uint256 remaining = IERC20(_bpt).balanceOf(address(this));
        if (remaining != 0) revert UniPoolerCutoverEscrow__BPTRemaining(remaining);
    }

    /// @dev Adds `s` sUSDS and `p` phUSD to the empty pair via Router02 (mins == desired), LP to
    ///      `newPooler`, and verifies exact consumption, the LP credit and the resulting reserves.
    function _seed(uint256 s, uint256 p, uint256 deadline) internal returns (uint256 liquidity) {
        if (s == 0 || p == 0) revert UniPoolerCutoverEscrow__NothingToSeed(s, p);
        uint256 lpBefore = IERC20(_pair).balanceOf(_newPooler);

        IERC20(_sUSDS).forceApprove(_uniRouter, s);
        IERC20(_phUSD).forceApprove(_uniRouter, p);
        (uint256 a, uint256 b, uint256 liq) =
            IUniswapV2Router02(_uniRouter).addLiquidity(_sUSDS, _phUSD, s, p, s, p, _newPooler, deadline);
        IERC20(_sUSDS).forceApprove(_uniRouter, 0);
        IERC20(_phUSD).forceApprove(_uniRouter, 0);

        if (a != s || b != p) revert UniPoolerCutoverEscrow__SeedNotExact(a, b);
        uint256 lpReceived = IERC20(_pair).balanceOf(_newPooler) - lpBefore;
        if (liq == 0 || lpReceived != liq) revert UniPoolerCutoverEscrow__LPNotMinted(liq, lpReceived);

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(_pair).getReserves();
        (uint256 rS, uint256 rP) = _sUSDSIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rS != s || rP != p) revert UniPoolerCutoverEscrow__ReserveMismatch(rS, rP);
        liquidity = liq;
    }

    /// @dev Transfers the escrow's whole `token` balance to `oldPooler`; returns the amount.
    function _returnAll(address token) internal returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(_oldPooler, amount);
    }

    /// @dev Reverts if the escrow still holds any `token`.
    function _requireNoBalance(address token) internal view {
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert UniPoolerCutoverEscrow__BalanceRemaining(token, remaining);
    }
}
