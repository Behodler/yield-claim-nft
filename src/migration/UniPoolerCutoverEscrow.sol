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

    /// @dev RED PHASE STUB (story 052): the surface compiles so the tests can run and fail.
    constructor(address, address, address, address) {}

    function exitAndSeed(ExitMode, uint256[] calldata, uint256) external returns (uint256) {
        revert("UniPoolerCutoverEscrow: not implemented");
    }

    function wrapUsds() external returns (uint256) {
        revert("UniPoolerCutoverEscrow: not implemented");
    }

    function abort() external {
        revert("UniPoolerCutoverEscrow: not implemented");
    }

    function operator() external pure returns (address) {
        return address(0);
    }

    function newPooler() external pure returns (address) {
        return address(0);
    }

    function oldPooler() external pure returns (address) {
        return address(0);
    }

    function v3Router() external pure returns (address) {
        return address(0);
    }

    function bpt() external pure returns (address) {
        return address(0);
    }

    function usds() external pure returns (address) {
        return address(0);
    }

    function sUSDS() external pure returns (address) {
        return address(0);
    }

    function phUSD() external pure returns (address) {
        return address(0);
    }

    function pair() external pure returns (address) {
        return address(0);
    }

    function uniRouter() external pure returns (address) {
        return address(0);
    }
}
