// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UniPoolerV2} from "../src/dispatchers/UniPoolerV2.sol";
import {IUniswapV2Router02} from "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../src/interfaces/uniswap/IUniswapV2Pair.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";

/// @dev Reports the right token pair but is not the factory's pair (canonical-pair check).
contract ForkLookalikePair {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }
}

interface IUniswapV2FactoryMin {
    function getPair(address, address) external view returns (address);
}

/// @title UniPoolerV2 — mainnet fork test against the real Uniswap V2 Router02
/// @notice The phUSD/sUSDS V2 pair does not exist on mainnet yet, so the test creates and seeds it
///         (via the real router, which auto-creates the pair through the real factory) before
///         deploying UniPoolerV2 against it, then runs the UI flow: `quotePool` → `pool` with floors.
/// @dev RPC wiring follows `PromotionUniV2_Eth.t.sol`: `MAINNET_RPC_URL` (or the `.envrc` name
///      `RPC_MAINNET`) must point at an ARCHIVE endpoint because `FORK_BLOCK` is pinned. Unlike that
///      suite there is no public-node fallback: with neither variable set every test here SKIPS.
///      Story 051: setUp creates the pair through the real factory BEFORE deploying the pooler (the
///      constructor now requires the factory's canonical pair) and installs a recording hook (the
///      pooler refuses to dispatch while its hook is still the constructor default).
contract UniPoolerV2ForkTest is Test {
    using SafeERC20 for IERC20;

    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant sUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant phUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    /// @dev Same pinned block as PromotionUniV2_Eth: phUSD, sUSDS and Router02 are all live.
    uint256 internal constant FORK_BLOCK = 25_550_000;

    UniPoolerV2 internal pooler;
    address internal pair;
    bool internal forked;

    address internal owner = address(this);
    address internal minter = address(0xBEEF);
    address internal authorizedPooler = address(0xD00D);
    address internal attacker = address(0xA77A);

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", vm.envOr("RPC_MAINNET", string("")));
        if (bytes(rpc).length == 0) return; // tests skip
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        require(IUniswapV2FactoryMin(UNIV2_FACTORY).getPair(sUSDS, phUSD) == address(0), "pair already exists");

        // Seed ~at peg in dollar terms: 100k sUSDS worth of value vs 100k phUSD (sUSDS > $1, so the
        // pair prices phUSD a little above sUSDS' share price — irrelevant to the zap maths).
        _seedPair(100_000e18, 100_000e18);
        pair = IUniswapV2FactoryMin(UNIV2_FACTORY).getPair(sUSDS, phUSD);
        require(pair != address(0), "pair not created");

        pooler = new UniPoolerV2(sUSDS, phUSD, UNIV2_ROUTER, pair, owner);
        pooler.setMinter(minter);
        pooler.setAuthorizedPooler(authorizedPooler, true);
        pooler.setHook(IDispatchHook(address(new MockDispatchHook())));
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _seedPair(uint256 amtS, uint256 amtP) internal {
        deal(sUSDS, address(this), amtS);
        deal(phUSD, address(this), amtP);
        IERC20(sUSDS).forceApprove(UNIV2_ROUTER, amtS);
        IERC20(phUSD).forceApprove(UNIV2_ROUTER, amtP);
        IUniswapV2Router02(UNIV2_ROUTER).addLiquidity(sUSDS, phUSD, amtS, amtP, 0, 0, address(this), block.timestamp);
    }

    /// @dev Real mint path: USDS lands on the pooler and `dispatch` wraps it into real sUSDS.
    function _dispatchUSDS(uint256 amount) internal returns (uint256 shares) {
        uint256 before = IERC20(sUSDS).balanceOf(address(pooler));
        deal(USDS, address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        shares = IERC20(sUSDS).balanceOf(address(pooler)) - before;
    }

    function test_fork_constructorRecognisesRealPair() public onlyForked {
        assertEq(pooler.primeToken(), USDS, "primeToken is USDS");
        assertEq(pooler.sUSDSIsToken0(), IUniswapV2Pair(pair).token0() == sUSDS, "ordering recorded");
        assertEq(IUniswapV2Router02(UNIV2_ROUTER).factory(), UNIV2_FACTORY, "real router's factory");
    }

    function test_fork_constructorRejectsNonCanonicalPair() public onlyForked {
        ForkLookalikePair fake = new ForkLookalikePair(IUniswapV2Pair(pair).token0(), IUniswapV2Pair(pair).token1());
        vm.expectRevert(abi.encodeWithSelector(UniPoolerV2.UniPoolerV2__PairNotCanonical.selector, pair, address(fake)));
        new UniPoolerV2(sUSDS, phUSD, UNIV2_ROUTER, address(fake), owner);
    }

    function test_fork_dispatchRevertsUntilHookSet() public onlyForked {
        UniPoolerV2 fresh = new UniPoolerV2(sUSDS, phUSD, UNIV2_ROUTER, pair, owner);
        fresh.setMinter(minter);
        deal(USDS, address(fresh), 1_000e18);
        vm.prank(minter);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__HookNotSet.selector);
        fresh.dispatch(minter, 1_000e18, "");
    }

    /// @dev ycn20l24 on the real pair: seeded 100k/100k, a 0.5% donation transferred without a
    ///      sync, then a 100k zap. Pre-fix this stranded ~229 phUSD on the pooler; now the pooler
    ///      syncs first and the leftover is wei-level dust, with the quote's floors honoured.
    function _forkUnsyncedDonationZap(address donatedToken) internal {
        deal(donatedToken, address(0xD0E), 500e18);
        vm.prank(address(0xD0E));
        IERC20(donatedToken).safeTransfer(pair, 500e18);

        uint256 a = 100_000e18;
        deal(sUSDS, address(pooler), a);
        (, uint256 phusdOut, uint256 expectedLP) = pooler.quotePool(a);

        vm.prank(authorizedPooler);
        pooler.pool(a, phusdOut, expectedLP);

        assertGe(IERC20(pair).balanceOf(address(pooler)), expectedLP, "LP >= quote");
        // ~1:1 pair and a == r0: the unit suite's `_dustTol` bound is (4+4+4)*(2+1) = 36 wei.
        assertLe(IERC20(sUSDS).balanceOf(address(pooler)), 36, "sUSDS dust only");
        assertLe(IERC20(phUSD).balanceOf(address(pooler)), 36, "phUSD dust only");
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        assertEq(uint256(r0), IERC20(IUniswapV2Pair(pair).token0()).balanceOf(pair), "synced (token0)");
        assertEq(uint256(r1), IERC20(IUniswapV2Pair(pair).token1()).balanceOf(pair), "synced (token1)");
    }

    function test_fork_unsyncedSUSDSDonation_zapLeavesDust() public onlyForked {
        _forkUnsyncedDonationZap(sUSDS);
    }

    function test_fork_unsyncedPhUSDDonation_zapLeavesDust() public onlyForked {
        _forkUnsyncedDonationZap(phUSD);
    }

    function test_fork_quoteThenPool_realRouter() public onlyForked {
        uint256 shares = _dispatchUSDS(10_000e18);
        assertGt(shares, 0, "real sUSDS minted on dispatch");

        (uint256 swapIn, uint256 phusdOut, uint256 expectedLP) = pooler.quotePool(shares);
        assertGt(swapIn, 0);
        assertLt(swapIn, shares);

        // UI flow: floors = quote less a 0.5% tolerance.
        vm.prank(authorizedPooler);
        pooler.pool(shares, (phusdOut * 995) / 1000, (expectedLP * 995) / 1000);

        uint256 lp = IERC20(pair).balanceOf(address(pooler));
        // With the factory's protocol fee on, the pair mints the fee share before ours, which only
        // raises our LP; with it off the quote is exact. Either way the quote is a floor.
        assertGe(lp, expectedLP, "LP >= quote");
        // Wei-level dust: ~1:1 pair and a < r, so the unit suite's rounding bound is 24 wei
        // (see `_dustTol` in UniPoolerV2.t.sol for the derivation).
        assertLe(IERC20(sUSDS).balanceOf(address(pooler)), 24, "sUSDS dust only");
        assertLe(IERC20(phUSD).balanceOf(address(pooler)), 24, "phUSD dust only");
        assertEq(IERC20(sUSDS).allowance(address(pooler), UNIV2_ROUTER), 0, "allowance reset");
        assertEq(IERC20(phUSD).allowance(address(pooler), UNIV2_ROUTER), 0, "allowance reset");
    }

    function test_fork_frontRun_revertsOnFloor() public onlyForked {
        uint256 shares = _dispatchUSDS(10_000e18);
        (, uint256 phusdOut, uint256 expectedLP) = pooler.quotePool(shares);

        // Attacker buys phUSD with 5k sUSDS in front of us.
        deal(sUSDS, attacker, 5_000e18);
        address[] memory path = new address[](2);
        path[0] = sUSDS;
        path[1] = phUSD;
        vm.startPrank(attacker);
        IERC20(sUSDS).forceApprove(UNIV2_ROUTER, 5_000e18);
        IUniswapV2Router02(UNIV2_ROUTER).swapExactTokensForTokens(5_000e18, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        vm.prank(authorizedPooler);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        pooler.pool(shares, (phusdOut * 995) / 1000, (expectedLP * 995) / 1000);
        assertEq(IERC20(sUSDS).balanceOf(address(pooler)), shares, "nothing consumed, nothing stranded");
    }
}
