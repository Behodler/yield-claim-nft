// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniPoolerV2} from "../src/dispatchers/UniPoolerV2.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {MockMintable} from "./mocks/MockMintable.sol";
import {BalancerPoolerMintDebtHook} from "../src/hooks/BalancerPoolerMintDebtHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockSkyPSM} from "./mocks/MockSkyPSM.sol";
import {MockNudgeBatchMinter} from "./mocks/MockNudgeBatchMinter.sol";
import {MockUniV2AmmPair, MockUniV2AmmRouter} from "./mocks/MockUniV2Amm.sol";
import {NudgeStreamer} from "phoenix-nft-staking/NudgeStreamer.sol";

/// @dev Mock ERC20 with configurable decimals for testing.
contract UPMockERC20 is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

/// @dev A "pair" that reports arbitrary token0/token1 — used only to exercise the constructor's
///      token-set validation in both orders and with a wrong token.
contract FakePairTokens {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }
}

/// @title UniPoolerV2Test
/// @notice Unit tests for UniPoolerV2 against a faithful-maths UniV2 pair/router, plus a port of
///         the BalancerPoolerV2 dispatch/donation/auth/rescue suite (same assertions; only the
///         deployment target — and the contract-name prefix in revert strings — differs).
contract UniPoolerV2Test is Test {
    UniPoolerV2 public pooler;
    UPMockERC20 public usds; // underlying prime token (USDS)
    MockERC4626 public sUsds; // ERC4626 wrapper (sUSDS), 1:1
    UPMockERC20 public phusd;
    MockUniV2AmmPair public pair;
    MockUniV2AmmRouter public router;

    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);
    address public authorizedPooler = address(0xD00D);
    address public lpSeeder = address(0x5EED);
    address public attacker = address(0xA77A);

    function setUp() public {
        usds = new UPMockERC20("USDS", "USDS", 18);
        sUsds = new MockERC4626("Savings USDS", "sUSDS", address(usds), 10000); // 1:1 rate
        phusd = new UPMockERC20("Phoenix USD", "phUSD", 18);
        pair = new MockUniV2AmmPair(address(sUsds), address(phusd));
        router = new MockUniV2AmmRouter(pair);

        pooler = new UniPoolerV2(address(sUsds), address(phusd), address(router), address(pair), owner);
        pooler.setMinter(minter);
        pooler.setAuthorizedPooler(authorizedPooler, true);

        _ensurePSM();
        pooler.setNudgeStreamer(address(streamer));
    }

    // =========================================================================
    // AMM helpers
    // =========================================================================

    function _dealSUSDS(address to, uint256 amount) internal {
        usds.mint(address(this), amount);
        usds.approve(address(sUsds), amount);
        sUsds.deposit(amount, to);
    }

    /// @dev Seed the pair with `rS` sUSDS and `rP` phUSD (first mint → LP to lpSeeder).
    function _seedPair(MockUniV2AmmPair p, uint256 rS, uint256 rP) internal {
        _dealSUSDS(address(p), rS);
        phusd.mint(address(p), rP);
        p.mint(lpSeeder);
    }

    function _seedPair(uint256 rS, uint256 rP) internal {
        _seedPair(pair, rS, rP);
    }

    /// @dev Front-run: attacker buys phUSD with `amountIn` sUSDS through the router.
    function _frontRunBuyPhusd(uint256 amountIn) internal {
        _dealSUSDS(attacker, amountIn);
        address[] memory path = new address[](2);
        path[0] = address(sUsds);
        path[1] = address(phusd);
        vm.startPrank(attacker);
        sUsds.approve(address(router), amountIn);
        router.swapExactTokensForTokens(amountIn, 0, path, attacker, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Front-run the other way: attacker dumps `amountIn` phUSD into the pair.
    function _frontRunSellPhusd(uint256 amountIn) internal {
        phusd.mint(attacker, amountIn);
        address[] memory path = new address[](2);
        path[0] = address(phusd);
        path[1] = address(sUsds);
        vm.startPrank(attacker);
        phusd.approve(address(router), amountIn);
        router.swapExactTokensForTokens(amountIn, 0, path, attacker, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Quote then pool `a` with the quote's outputs as exact floors.
    function _quoteAndPool(uint256 a) internal returns (uint256 swapIn, uint256 phusdOut, uint256 lp) {
        (swapIn, phusdOut, lp) = pooler.quotePool(a);
        vm.prank(authorizedPooler);
        pooler.pool(a, phusdOut, lp);
    }

    /// @dev Value of the pooler's leftover (sUSDS + phUSD priced at the live pair ratio), in sUSDS wei.
    function _leftoverValueInSUSDS(uint256 sUSDSBaseline) internal view returns (uint256 leftS, uint256 leftP) {
        leftS = sUsds.balanceOf(address(pooler)) - sUSDSBaseline;
        leftP = phusd.balanceOf(address(pooler));
    }

    function _reservesSP() internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rS, rP) = pair.token0() == address(sUsds) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Deploy a phUSD whose address sorts before/after sUSDS, for ordering coverage.
    function _deployPhusdOrdered(bool sUSDSFirst) internal returns (UPMockERC20 token) {
        for (uint256 salt = 0; salt < 256; salt++) {
            token = new UPMockERC20{salt: bytes32(salt)}("Phoenix USD", "phUSD", 18);
            if ((address(sUsds) < address(token)) == sUSDSFirst) return token;
        }
        revert("no salt found");
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroSUSDS() public {
        vm.expectRevert("UniPoolerV2: zero sUSDS");
        new UniPoolerV2(address(0), address(phusd), address(router), address(pair), owner);
    }

    function test_constructor_revertsWithZeroPhUSD() public {
        vm.expectRevert("UniPoolerV2: zero phUSD");
        new UniPoolerV2(address(sUsds), address(0), address(router), address(pair), owner);
    }

    function test_constructor_revertsWithZeroRouter() public {
        vm.expectRevert("UniPoolerV2: zero router");
        new UniPoolerV2(address(sUsds), address(phusd), address(0), address(pair), owner);
    }

    function test_constructor_revertsWithZeroPair() public {
        vm.expectRevert("UniPoolerV2: zero pair");
        new UniPoolerV2(address(sUsds), address(phusd), address(router), address(0), owner);
    }

    function test_constructor_acceptsSUSDSAsToken0() public {
        FakePairTokens fake = new FakePairTokens(address(sUsds), address(phusd));
        UniPoolerV2 p = new UniPoolerV2(address(sUsds), address(phusd), address(router), address(fake), owner);
        assertTrue(p.sUSDSIsToken0(), "sUSDS recorded as token0");
    }

    function test_constructor_acceptsSUSDSAsToken1() public {
        FakePairTokens fake = new FakePairTokens(address(phusd), address(sUsds));
        UniPoolerV2 p = new UniPoolerV2(address(sUsds), address(phusd), address(router), address(fake), owner);
        assertFalse(p.sUSDSIsToken0(), "sUSDS recorded as token1");
    }

    function test_constructor_revertsOnWrongTokenPair() public {
        UPMockERC20 other = new UPMockERC20("Other", "OTH", 18);
        FakePairTokens fake = new FakePairTokens(address(sUsds), address(other));
        vm.expectRevert(
            abi.encodeWithSelector(UniPoolerV2.UniPoolerV2__PairTokenMismatch.selector, address(sUsds), address(other))
        );
        new UniPoolerV2(address(sUsds), address(phusd), address(router), address(fake), owner);

        FakePairTokens fake2 = new FakePairTokens(address(other), address(phusd));
        vm.expectRevert(
            abi.encodeWithSelector(UniPoolerV2.UniPoolerV2__PairTokenMismatch.selector, address(other), address(phusd))
        );
        new UniPoolerV2(address(sUsds), address(phusd), address(router), address(fake2), owner);
    }

    function test_constructor_revertsOnSameTokenTwice() public {
        FakePairTokens fake = new FakePairTokens(address(sUsds), address(sUsds));
        vm.expectRevert(
            abi.encodeWithSelector(UniPoolerV2.UniPoolerV2__PairTokenMismatch.selector, address(sUsds), address(sUsds))
        );
        new UniPoolerV2(address(sUsds), address(phusd), address(router), address(fake), owner);
    }

    function test_constructor_allowsEmptyPair() public {
        // The cutover deploys the pooler before seeding the pair.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0) + uint256(r1), 0, "pair is empty");
        new UniPoolerV2(address(sUsds), address(phusd), address(router), address(pair), owner);
    }

    function test_constructor_authVersionInitializedToOne() public view {
        assertEq(pooler.authVersion(), 1, "authVersion should be initialized to 1");
    }

    // =========================================================================
    // getters
    // =========================================================================

    function test_primeToken_returnsUSDSAddress() public view {
        assertEq(pooler.primeToken(), address(usds), "primeToken() should return the USDS address");
    }

    function test_sUSDS_returnsConstructorSuppliedAddress() public view {
        assertEq(pooler.sUSDS(), address(sUsds));
    }

    function test_getters_routerPairPhUSD() public view {
        assertEq(pooler.router(), address(router));
        assertEq(pooler.pair(), address(pair));
        assertEq(pooler.phUSD(), address(phusd));
    }

    // =========================================================================
    // dispatch tests — USDS wrap to sUSDS only (ported)
    // =========================================================================

    function test_dispatch_wrapsUSDSToSUSDS() public {
        uint256 amount = 1e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(sUsds.balanceOf(address(pooler)), amount, "Dispatcher sUSDS balance should increase");
        assertEq(usds.balanceOf(address(pooler)), 0, "Dispatcher USDS balance should go to 0");
    }

    function test_dispatch_doesNotCallAddLiquidity() public {
        _seedPair(1000e18, 1000e18);
        uint256 amount = 1e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertFalse(router.addLiquidityCalled(), "addLiquidity should NOT have been called after dispatch");
        assertFalse(router.swapCalled(), "swap should NOT have been called after dispatch");
    }

    function test_dispatch_ignoresNonEmptyExtraData() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        bytes memory extraData = abi.encode(uint256(999e18));

        vm.prank(minter);
        pooler.dispatch(minter, amount, extraData);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "sUSDS balance should reflect wrap");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should be 0");
        assertFalse(router.addLiquidityCalled(), "addLiquidity should NOT be called");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.dispatch(nonOwner, amount, "");
    }

    function test_dispatch_invokesHookAfterWrap() public {
        MockDispatchHook hook = new MockDispatchHook();
        pooler.setHook(IDispatchHook(address(hook)));

        uint256 amount = 100e18;
        bytes memory payload = hex"aabbcc";
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, payload);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "USDS should have been wrapped to sUSDS");
        assertEq(hook.callCount(), 1, "hook should be called once");
        assertEq(hook.lastMinter(), minter, "hook should receive minter");
        assertEq(hook.lastAmount(), amount, "hook should receive amount");
        assertEq(hook.lastExtraData(), payload, "hook should receive extraData verbatim");
    }

    function test_pool_doesNotInvokeHook() public {
        _seedPair(10_000e18, 10_000e18);
        MockDispatchHook hook = new MockDispatchHook();
        pooler.setHook(IDispatchHook(address(hook)));

        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        assertEq(hook.callCount(), 1, "dispatch should have invoked hook once");

        _quoteAndPool(amount);
        assertEq(hook.callCount(), 1, "pool() must not invoke the dispatch hook");
    }

    // =========================================================================
    // pool() — guards
    // =========================================================================

    function test_pool_revertsWhenCalledByNonAuthorizedAddress() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);

        vm.prank(nonOwner);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(100e18, 1, 1);
    }

    function test_pool_revertsOnZeroMinPhusdOut() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);
        vm.prank(authorizedPooler);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__ZeroMinimum.selector);
        pooler.pool(100e18, 0, 1);
    }

    function test_pool_revertsOnZeroMinLP() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);
        vm.prank(authorizedPooler);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__ZeroMinimum.selector);
        pooler.pool(100e18, 1, 0);
    }

    function test_pool_revertsOnEmptyPair() public {
        _seedSUSDS(100e18);
        vm.prank(authorizedPooler);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__EmptyPair.selector);
        pooler.pool(100e18, 1, 1);
    }

    function test_quotePool_revertsOnEmptyPair() public {
        vm.expectRevert(UniPoolerV2.UniPoolerV2__EmptyPair.selector);
        pooler.quotePool(100e18);
    }

    function test_pool_revertsOnZeroAmount() public {
        _seedPair(10_000e18, 10_000e18);
        vm.prank(authorizedPooler);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__NothingToPool.selector);
        pooler.pool(0, 1, 1);
    }

    function test_pool_revertsWhenAmountExceedsBalance() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSelector(UniPoolerV2.UniPoolerV2__InsufficientSUSDS.selector, 101e18, 100e18));
        pooler.pool(101e18, 1, 1);
    }

    function test_pool_respectsWhenNotPaused() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);
        vm.prank(minter);
        pooler.pause();

        vm.prank(authorizedPooler);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pooler.pool(100e18, 1, 1);
    }

    // =========================================================================
    // pool() — closed-form zap behaviour
    // =========================================================================

    event Pooled(address indexed pooler, uint256 sUSDSIn, uint256 swapIn, uint256 phusdOut, uint256 liquidity);

    function test_pool_endToEnd_lpStaysOnPoolerAndQuoteIsExact() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 1_000e18;
        _seedSUSDS(a);

        (uint256 qSwap, uint256 qOut, uint256 qLP) = pooler.quotePool(a);
        assertGt(qSwap, 0);
        assertLt(qSwap, a);

        vm.expectEmit(true, false, false, true, address(pooler));
        emit Pooled(authorizedPooler, a, qSwap, qOut, qLP);
        vm.prank(authorizedPooler);
        pooler.pool(a, qOut, qLP);

        assertEq(pair.balanceOf(address(pooler)), qLP, "LP custody: the pooler holds the LP, quote exact");
        assertEq(sUsds.allowance(address(pooler), address(router)), 0, "sUSDS allowance reset");
        assertEq(phusd.allowance(address(pooler), address(router)), 0, "phUSD allowance reset");
    }

    function test_pool_onlyConsumesRequestedAmount() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(1_000e18);
        _quoteAndPool(400e18);
        // 600e18 remains (+ wei-level dust).
        assertApproxEqAbs(sUsds.balanceOf(address(pooler)), 600e18, 2, "only sUSDSIn is consumed");
    }

    /// @dev The headline efficiency requirement: across reserve sizes, skewed prices and
    ///      sUSDSIn small/large relative to the reserve, the zap leaves only wei-level dust.
    function test_pool_zapConsumesBothSidesToWithinDust_table() public {
        uint256[2][8] memory reserves = [
            [uint256(1e18), uint256(1e18)],
            [uint256(10_000e18), uint256(10_000e18)],
            [uint256(5_000_000e18), uint256(5_000_000e18)],
            [uint256(1e30), uint256(1e30)],
            [uint256(100_000e18), uint256(120_000e18)], // phUSD below peg
            [uint256(120_000e18), uint256(100_000e18)], // phUSD above peg
            [uint256(1_000e18), uint256(1_000_000e18)], // heavily skewed
            [uint256(1_000_000e18), uint256(1_000e18)] // heavily skewed the other way
        ];
        uint256[6] memory fractionsBps = [uint256(1), 10, 1_000, 10_000, 50_000, 200_000]; // 0.01% .. 20x r

        for (uint256 i = 0; i < reserves.length; i++) {
            for (uint256 j = 0; j < fractionsBps.length; j++) {
                uint256 snap = vm.snapshotState();
                _seedPair(reserves[i][0], reserves[i][1]);
                uint256 a = (reserves[i][0] * fractionsBps[j]) / 10_000;
                if (a == 0) a = 1e15;
                _seedSUSDS(a);

                _quoteAndPool(a);

                (uint256 leftS, uint256 leftP) = _leftoverValueInSUSDS(0);
                (uint256 rS, uint256 rP) = _reservesSP();
                // Wei-level: at most a couple of wei of sUSDS, and phUSD dust worth at most a
                // couple of wei of sUSDS at the post-pool price (plus 1 wei rounding).
                assertLe(leftS, 2, "sUSDS leftover must be wei-level");
                assertLe((leftP * rS) / rP, 2, "phUSD leftover must be worth wei-level sUSDS");
                vm.revertToState(snap);
            }
        }
    }

    function testFuzz_pool_zapDust(uint96 rS, uint96 rP, uint96 a) public {
        rS = uint96(bound(rS, 1e18, 1e27));
        // keep the price within 1000x either way of peg
        rP = uint96(bound(rP, uint256(rS) / 1000, uint256(rS) * 1000));
        a = uint96(bound(a, 1e12, uint256(rS) * 20));
        _seedPair(rS, rP);
        _seedSUSDS(a);

        (, uint256 qOut, uint256 qLP) = pooler.quotePool(a);
        vm.assume(qOut > 0 && qLP > 0);
        vm.prank(authorizedPooler);
        pooler.pool(a, qOut, qLP);

        (uint256 leftS, uint256 leftP) = _leftoverValueInSUSDS(0);
        (uint256 nS, uint256 nP) = _reservesSP();
        assertLe(leftS, 2, "sUSDS dust");
        assertLe((leftP * nS) / nP, 2, "phUSD dust");
    }

    /// @dev Contrast: the naive half-split leaves a large refund behind (what this story removes).
    function test_pool_closedFormBeatsHalfSplit() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 2_000e18;
        (uint256 s,,) = pooler.quotePool(a);
        // Optimal swap is noticeably less than half because of price impact + fee.
        assertLt(s, a / 2, "closed-form s < a/2 for a sizeable zap");
        assertGt(a / 2 - s, 10e18, "half-split would mis-size by >10 sUSDS here");
    }

    function test_pool_frontRunBuy_revertsOnMinPhusdOut_noStrandedRefund() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 1_000e18;
        _seedSUSDS(a);
        (, uint256 qOut, uint256 qLP) = pooler.quotePool(a);
        uint256 minOut = (qOut * 995) / 1000; // 0.5% tolerance
        uint256 minLP = (qLP * 995) / 1000;

        _frontRunBuyPhusd(500e18); // pushes phUSD price up well beyond 0.5%

        vm.prank(authorizedPooler);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        pooler.pool(a, minOut, minLP);

        assertEq(sUsds.balanceOf(address(pooler)), a, "sUSDS untouched after revert");
        assertEq(phusd.balanceOf(address(pooler)), 0, "no phUSD stranded");
        assertEq(pair.balanceOf(address(pooler)), 0, "no LP minted");
    }

    function test_pool_frontRunBuy_revertsOnMinLP_whenPhusdFloorLoose() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 1_000e18;
        _seedSUSDS(a);
        (,, uint256 qLP) = pooler.quotePool(a);

        _frontRunBuyPhusd(500e18);

        vm.prank(authorizedPooler);
        vm.expectPartialRevert(UniPoolerV2.UniPoolerV2__InsufficientLP.selector);
        pooler.pool(a, 1, (qLP * 995) / 1000);

        assertEq(sUsds.balanceOf(address(pooler)), a, "sUSDS untouched after revert");
        assertEq(phusd.balanceOf(address(pooler)), 0, "no phUSD stranded");
    }

    function test_pool_frontRunSell_revertsOnMinLP() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 1_000e18;
        _seedSUSDS(a);
        (,, uint256 qLP) = pooler.quotePool(a);

        _frontRunSellPhusd(2_000e18); // phUSD dumped: our LP share per sUSDS changes

        vm.prank(authorizedPooler);
        vm.expectPartialRevert(UniPoolerV2.UniPoolerV2__InsufficientLP.selector);
        pooler.pool(a, 1, qLP);
        assertEq(sUsds.balanceOf(address(pooler)), a, "sUSDS untouched after revert");
    }

    /// @dev A front-run inside tolerance succeeds, and the on-chain `s` re-derivation still
    ///      leaves only dust — the leftover does not depend on the quote.
    function test_pool_frontRunWithinTolerance_stillDustOnly() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 a = 1_000e18;
        _seedSUSDS(a);
        (, uint256 qOut, uint256 qLP) = pooler.quotePool(a);

        _frontRunBuyPhusd(5e18); // small shift

        vm.prank(authorizedPooler);
        pooler.pool(a, (qOut * 98) / 100, (qLP * 98) / 100);

        (uint256 leftS, uint256 leftP) = _leftoverValueInSUSDS(0);
        assertLe(leftS, 2, "sUSDS dust only");
        assertLe(leftP, 2, "phUSD dust only");
        assertGt(pair.balanceOf(address(pooler)), 0, "LP received");
    }

    function test_pool_bothTokenOrderings() public {
        for (uint256 k = 0; k < 2; k++) {
            bool sFirst = k == 0;
            UPMockERC20 ph = _deployPhusdOrdered(sFirst);
            MockUniV2AmmPair p = new MockUniV2AmmPair(address(sUsds), address(ph));
            assertEq(p.token0() == address(sUsds), sFirst, "ordering as intended");
            MockUniV2AmmRouter r = new MockUniV2AmmRouter(p);
            UniPoolerV2 up = new UniPoolerV2(address(sUsds), address(ph), address(r), address(p), owner);
            assertEq(up.sUSDSIsToken0(), sFirst);
            up.setMinter(minter);
            up.setAuthorizedPooler(authorizedPooler, true);

            // seed pair (skewed so a mixed-up index would be caught)
            _dealSUSDS(address(p), 10_000e18);
            ph.mint(address(p), 20_000e18);
            p.mint(lpSeeder);

            usds.mint(address(up), 500e18);
            vm.prank(minter);
            up.dispatch(minter, 500e18, "");

            (, uint256 qOut, uint256 qLP) = up.quotePool(500e18);
            vm.prank(authorizedPooler);
            up.pool(500e18, qOut, qLP);
            assertEq(p.balanceOf(address(up)), qLP, "quote exact in this ordering");
            assertLe(sUsds.balanceOf(address(up)), 2, "sUSDS dust");
            assertLe(ph.balanceOf(address(up)), 4, "phUSD dust");
        }
    }

    function test_pool_noPriceCeiling_canPushPhusdAbovePeg() public {
        _seedPair(10_000e18, 10_000e18); // phUSD at $1
        uint256 a = 5_000e18;
        _seedSUSDS(a);
        _quoteAndPool(a);
        (uint256 rS, uint256 rP) = _reservesSP();
        assertGt(rS, rP, "phUSD now trades above 1 sUSDS - no ceiling enforced");
    }

    // =========================================================================
    // Dispatch survives pool() being unavailable (plan: "dispatch while paused" —
    // reinterpreted, see story Autonomous Decisions)
    // =========================================================================

    function test_dispatch_worksWhilePoolUnavailable_emptyPair() public {
        _wireDonation(10);
        _seedSUSDS(1000e18);
        assertEq(sUsds.balanceOf(address(pooler)), 900e18, "wrap unchanged while pool() unavailable");
        assertEq(usdc.balanceOf(address(streamer)), 100e6, "donation unchanged while pool() unavailable");
        assertEq(usds.balanceOf(address(pooler)), 0, "nothing parked");

        // Pair is empty: pool() is unavailable...
        vm.prank(authorizedPooler);
        vm.expectRevert(UniPoolerV2.UniPoolerV2__EmptyPair.selector);
        pooler.pool(900e18, 1, 1);

        // ...and the mint path keeps working regardless.
        _seedSUSDS(1000e18);
        assertEq(sUsds.balanceOf(address(pooler)), 1800e18, "second dispatch still wraps");
        assertEq(usdc.balanceOf(address(streamer)), 200e6, "second dispatch still donates");
    }

    function test_dispatch_worksAfterPoolReverts() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(1000e18);
        // A pool() attempt reverts (floor unattainable)...
        vm.prank(authorizedPooler);
        vm.expectRevert();
        pooler.pool(1000e18, type(uint256).max, 1);
        // ...and the mint path is unaffected.
        _seedSUSDS(500e18);
        assertEq(sUsds.balanceOf(address(pooler)), 1500e18, "dispatch still wraps after a failed pool()");
    }

    /// @dev Documents the base behaviour that forced the reinterpretation: `dispatch` is
    ///      `whenNotPaused` on ATokenDispatcherV2, so pausing blocks the mint path as well.
    function test_pause_blocksDispatchAsWellAsPool_baseBehaviour() public {
        vm.prank(minter);
        pooler.pause();
        usds.mint(address(pooler), 1e18);
        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pooler.dispatch(minter, 1e18, "");
    }

    // =========================================================================
    // setAuthorizedPooler / incrementAuthVersion (ported)
    // =========================================================================

    function test_setAuthorizedPooler_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setAuthorizedPooler(address(0x1111), true);
    }

    function test_setAuthorizedPooler_revertsOnZeroAddress() public {
        vm.expectRevert("UniPoolerV2: zero pooler");
        pooler.setAuthorizedPooler(address(0), true);
    }

    function test_setAuthorizedPooler_authorizeSetsVersionAndEmits() public {
        address newPooler = address(0x2222);

        vm.expectEmit(true, false, false, true);
        emit UniPoolerV2.PoolerAuthorized(newPooler, 1);
        pooler.setAuthorizedPooler(newPooler, true);

        assertEq(pooler.poolerAuthVersion(newPooler), 1, "poolerAuthVersion should match current authVersion");
    }

    function test_setAuthorizedPooler_deauthorizeClearsAndEmits() public {
        _seedPair(10_000e18, 10_000e18);
        address p = address(0x3333);
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 1, "Should be authorized");

        vm.expectEmit(true, false, false, false);
        emit UniPoolerV2.PoolerDeauthorized(p);
        pooler.setAuthorizedPooler(p, false);

        assertEq(pooler.poolerAuthVersion(p), 0, "poolerAuthVersion should be cleared");

        _seedSUSDS(10e18);
        vm.prank(p);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(10e18, 1, 1);
    }

    function test_incrementAuthVersion_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.incrementAuthVersion();
    }

    function test_incrementAuthVersion_massRevoke() public {
        _seedPair(10_000e18, 10_000e18);
        address poolerA = address(0x4444);
        address poolerB = address(0x5555);
        pooler.setAuthorizedPooler(poolerA, true);
        pooler.setAuthorizedPooler(poolerB, true);

        uint256 amount = 100e18;
        _seedSUSDS(amount);

        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.AuthVersionIncremented(2);
        pooler.incrementAuthVersion();
        assertEq(pooler.authVersion(), 2, "authVersion should be 2");

        (, uint256 qOut, uint256 qLP) = pooler.quotePool(amount);

        vm.prank(poolerA);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(amount, qOut, qLP);

        vm.prank(poolerB);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(amount, qOut, qLP);

        // The previously authorized setUp pooler is revoked too.
        vm.prank(authorizedPooler);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(amount, qOut, qLP);

        pooler.setAuthorizedPooler(poolerA, true);
        assertEq(pooler.poolerAuthVersion(poolerA), 2, "poolerA should be at version 2");
        vm.prank(poolerA);
        pooler.pool(amount, qOut, qLP);

        _seedSUSDS(amount);
        (, qOut, qLP) = pooler.quotePool(amount);
        vm.prank(poolerB);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(amount, qOut, qLP);
    }

    function test_staleAuthorizationBoundary() public {
        _seedPair(10_000e18, 10_000e18);
        address p = address(0x6666);
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 1, "Authorized at version 1");

        pooler.incrementAuthVersion();
        assertEq(pooler.authVersion(), 2, "authVersion should be 2");
        assertEq(pooler.poolerAuthVersion(p), 1, "Stale: poolerAuthVersion still V");

        uint256 amount = 10e18;
        _seedSUSDS(amount);
        (, uint256 qOut, uint256 qLP) = pooler.quotePool(amount);

        vm.prank(p);
        vm.expectRevert("UniPoolerV2: caller not authorized pooler");
        pooler.pool(amount, qOut, qLP);

        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 2, "Re-authorized at version 2");

        vm.prank(p);
        pooler.pool(amount, qOut, qLP);
    }

    function test_authorizedPoolerCannotCallOwnerFunctions() public {
        vm.startPrank(authorizedPooler);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.setAuthorizedPooler(address(0x9999), true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.incrementAuthVersion();

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.rescueERC20(address(pair), authorizedPooler, 1);

        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.pause();

        vm.stopPrank();
    }

    // =========================================================================
    // H-02 regression (ported): the mint path never touches the AMM
    // =========================================================================

    function test_H02_regression_noAddLiquidityDuringMintPath() public {
        _seedPair(10_000e18, 10_000e18);
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        assertFalse(router.addLiquidityCalled(), "H-02: addLiquidity must NOT fire during dispatch (empty extraData)");

        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, abi.encode(uint256(0)));
        assertFalse(router.addLiquidityCalled(), "H-02: addLiquidity must NOT fire during dispatch (extraData)");
        assertFalse(router.swapCalled(), "H-02: no swap during dispatch");

        assertEq(sUsds.balanceOf(address(pooler)), 200e18, "sUSDS should accumulate from dispatches");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should all be wrapped");
    }

    // =========================================================================
    // rescueERC20 (ported) — also the LP exit
    // =========================================================================

    function test_rescueERC20_transfersArbitraryToken() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        uint256 amount = 50e18;
        strayToken.mint(address(pooler), amount);

        address recipient = address(0xBBBB);
        pooler.rescueERC20(address(strayToken), recipient, amount);

        assertEq(strayToken.balanceOf(recipient), amount, "Recipient should receive rescued tokens");
        assertEq(strayToken.balanceOf(address(pooler)), 0, "Pooler should have 0 after rescue");
    }

    function test_rescueERC20_worksForSUsds() public {
        _seedSUSDS(100e18);
        uint256 bal = sUsds.balanceOf(address(pooler));
        assertTrue(bal > 0, "Pooler should hold sUSDS after dispatch");

        address recipient = address(0xCCCC);
        pooler.rescueERC20(address(sUsds), recipient, bal);

        assertEq(sUsds.balanceOf(recipient), bal, "Recipient should receive all sUSDS");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "Pooler sUSDS should be drained");
    }

    /// @dev rescueERC20 is the LP exit (replaces BalancerPoolerV2.withdrawBPT).
    function test_rescueERC20_worksForLP() public {
        _seedPair(10_000e18, 10_000e18);
        _seedSUSDS(100e18);
        _quoteAndPool(100e18);

        uint256 lp = pair.balanceOf(address(pooler));
        assertTrue(lp > 0, "Pooler should have LP after pooling");

        address recipient = address(0xDDDD);
        pooler.rescueERC20(address(pair), recipient, lp);

        assertEq(pair.balanceOf(recipient), lp, "Recipient should receive all LP");
        assertEq(pair.balanceOf(address(pooler)), 0, "Pooler LP should be 0 after rescue");
    }

    function test_rescueERC20_revertsWhenCalledByNonOwner() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 10e18);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.rescueERC20(address(strayToken), nonOwner, 10e18);
    }

    function test_rescueERC20_revertsWhenRecipientIsZero() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 10e18);

        vm.expectRevert("UniPoolerV2: zero recipient");
        pooler.rescueERC20(address(strayToken), address(0), 10e18);
    }

    function test_rescueERC20_worksWhilePaused() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        uint256 amount = 25e18;
        strayToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.pause();

        address recipient = address(0xEEEE);
        pooler.rescueERC20(address(strayToken), recipient, amount);

        assertEq(strayToken.balanceOf(recipient), amount, "Rescue should work while paused");
    }

    function test_rescueERC20_zeroAmountIsNoop() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        uint256 amount = 10e18;
        strayToken.mint(address(pooler), amount);

        address recipient = address(0xFFFF);
        pooler.rescueERC20(address(strayToken), recipient, 0);

        assertEq(strayToken.balanceOf(recipient), 0, "Recipient balance should remain 0");
        assertEq(strayToken.balanceOf(address(pooler)), amount, "Pooler balance should be unchanged");
    }

    function test_rescueERC20_revertsOnInsufficientBalance() public {
        UPMockERC20 strayToken = new UPMockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 5e18);

        vm.expectRevert();
        pooler.rescueERC20(address(strayToken), address(0xAAAA), 10e18);
    }

    // =========================================================================
    // BalancerPoolerMintDebtHook integration (ported — index 4's hook is reused unchanged)
    // =========================================================================

    event DebtAccrued(address indexed minter, uint256 dispatchedAmount, uint256 debtAdded, uint256 newTotalDebt);
    event DebtPulled(address indexed recipient, uint256 amount);

    function test_mintDebtHook_integration_accruesOnDispatch() public {
        MockMintable phUSDMintable = new MockMintable();
        BalancerPoolerMintDebtHook debtHook =
            new BalancerPoolerMintDebtHook(owner, address(pooler), address(phUSDMintable));
        pooler.setHook(IDispatchHook(address(debtHook)));

        uint256 amount = 1000e18;
        uint256 expectedDebt = (amount * 50) / 100;
        usds.mint(address(pooler), amount);

        vm.expectEmit(true, false, false, true, address(debtHook));
        emit DebtAccrued(minter, amount, expectedDebt, expectedDebt);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(debtHook.mintDebt(), expectedDebt, "hook mintDebt should equal 50% of dispatched amount");
        assertEq(sUsds.balanceOf(address(pooler)), amount, "sUSDS should reflect the full wrap");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should be fully wrapped");
        assertFalse(router.addLiquidityCalled(), "addLiquidity must not fire during dispatch");
    }

    function test_mintDebtHook_integration_pullMintsPhUSD() public {
        MockMintable phUSDMintable = new MockMintable();
        BalancerPoolerMintDebtHook debtHook =
            new BalancerPoolerMintDebtHook(owner, address(pooler), address(phUSDMintable));
        pooler.setHook(IDispatchHook(address(debtHook)));

        uint256 amount = 500e18;
        uint256 expectedDebt = (amount * 50) / 100;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(debtHook.mintDebt(), expectedDebt, "debt accrued");

        address stakingModule = address(0xBADA55);
        debtHook.setRecipient(stakingModule);

        vm.expectEmit(true, false, false, true, address(debtHook));
        emit DebtPulled(stakingModule, expectedDebt);
        debtHook.pull();

        assertEq(debtHook.mintDebt(), 0, "debt cleared after pull");
        assertEq(phUSDMintable.balanceOf(stakingModule), expectedDebt, "phUSD minted to staking module");
        assertEq(phUSDMintable.mintCallCount(), 1, "exactly one mint call");
    }

    // =========================================================================
    // PSM donation — config setters (ported)
    // =========================================================================

    address public batchMinter;
    MockNudgeBatchMinter public batchMinterMock;
    NudgeStreamer public streamer;
    UPMockERC20 public usdc;
    MockSkyPSM public psm;

    uint256 internal constant STREAM_DURATION = 1000;

    function _seedSUSDS(uint256 amount) internal {
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
    }

    function _ensurePSM() internal {
        if (address(usdc) == address(0)) {
            usdc = new UPMockERC20("USD Coin", "USDC", 6);
            psm = new MockSkyPSM(address(usds), address(usdc), 1e12);
            usdc.mint(address(this), 1_000_000e6);
            usdc.approve(address(psm), type(uint256).max);
            psm.fundReserve(1_000_000e6);

            batchMinterMock = new MockNudgeBatchMinter();
            batchMinterMock.setNudgeToken(address(usdc), true);
            batchMinter = address(batchMinterMock);

            streamer = new NudgeStreamer(owner);
            streamer.registerStream(batchMinter, address(usdc), STREAM_DURATION);
        }
    }

    function _wireDonation(uint256 size) internal {
        _ensurePSM();
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(size);
    }

    function _freshPooler() internal returns (UniPoolerV2 fresh) {
        fresh = new UniPoolerV2(address(sUsds), address(phusd), address(router), address(pair), owner);
        fresh.setMinter(minter);
    }

    event BatchDonatedViaPSM(uint256 usdsSpent, uint256 usdcDonated, address indexed batchMinter);
    event DonationSkipped(uint256 usdsParked);

    function _assertBatchDonatedViaPSM(Vm.Log[] memory logs, uint256 usdsSpent, uint256 usdcDonated) internal view {
        bytes32 sig = keccak256("BatchDonatedViaPSM(uint256,uint256,address)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pooler) && logs[i].topics[0] == sig) {
                (uint256 spent, uint256 donated) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(spent, usdsSpent, "BatchDonatedViaPSM.usdsSpent");
                assertEq(donated, usdcDonated, "BatchDonatedViaPSM.usdcDonated");
                assertEq(address(uint160(uint256(logs[i].topics[1]))), batchMinter, "BatchDonatedViaPSM.batchMinter");
                found = true;
                break;
            }
        }
        assertTrue(found, "BatchDonatedViaPSM not emitted");
    }

    function _assertDonationSkipped(Vm.Log[] memory logs, uint256 usdsParked) internal view {
        bytes32 sig = keccak256("DonationSkipped(uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pooler) && logs[i].topics[0] == sig) {
                uint256 parked = abi.decode(logs[i].data, (uint256));
                assertEq(parked, usdsParked, "DonationSkipped.usdsParked");
                found = true;
                break;
            }
        }
        assertTrue(found, "DonationSkipped not emitted");
    }

    function _assertNoDonationSkipped(Vm.Log[] memory logs) internal view {
        bytes32 sig = keccak256("DonationSkipped(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pooler) && logs[i].topics[0] == sig) {
                revert("DonationSkipped emitted but the donation was expected to be a clean no-op");
            }
        }
    }

    function test_setPSM_revertsOnZero() public {
        vm.expectRevert("UniPoolerV2: zero psm");
        pooler.setPSM(address(0));
    }

    function test_setPSM_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.PSMSet(address(psm));
        pooler.setPSM(address(psm));
        assertEq(pooler.psm(), address(psm));
    }

    function test_setPSM_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setPSM(address(psm));
    }

    function test_maxTout_defaultsToOnePercent() public view {
        assertEq(pooler.maxTout(), 0.01e18, "maxTout default should be 1% WAD");
    }

    function test_setMaxTout_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.MaxToutSet(0.05e18);
        pooler.setMaxTout(0.05e18);
        assertEq(pooler.maxTout(), 0.05e18);
    }

    function test_setMaxTout_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setMaxTout(0.05e18);
    }

    function test_setBatchDonationSize_zeroAllowedAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.BatchDonationSizeSet(0);
        pooler.setBatchDonationSize(0);
        assertEq(pooler.batchDonationSize(), 0);
    }

    function test_setBatchDonationSize_oneHundredAllowedAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.BatchDonationSizeSet(100);
        pooler.setBatchDonationSize(100);
        assertEq(pooler.batchDonationSize(), 100);
    }

    function test_setBatchDonationSize_revertsAbove100() public {
        vm.expectRevert("UniPoolerV2: size > 100");
        pooler.setBatchDonationSize(101);
    }

    function test_setBatchDonationSize_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setBatchDonationSize(10);
    }

    function test_setBatchMinter_zeroAddressAllowed() public {
        pooler.setBatchMinter(address(0xCAFE));
        assertEq(pooler.batchMinter(), address(0xCAFE));

        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.BatchMinterSet(address(0));
        pooler.setBatchMinter(address(0));
        assertEq(pooler.batchMinter(), address(0));
    }

    function test_setBatchMinter_emitsEventWithNewAddress() public {
        vm.expectEmit(false, false, false, true);
        emit UniPoolerV2.BatchMinterSet(batchMinter);
        pooler.setBatchMinter(batchMinter);
        assertEq(pooler.batchMinter(), batchMinter);
    }

    function test_setBatchMinter_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setBatchMinter(batchMinter);
    }

    function test_setNudgeStreamer_revertsOnZero() public {
        vm.expectRevert("UniPoolerV2: zero nudgeStreamer");
        pooler.setNudgeStreamer(address(0));
    }

    function test_setNudgeStreamer_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setNudgeStreamer(address(0xB0B));
    }

    function test_setNudgeStreamer_storesAndEmits() public {
        UniPoolerV2 fresh = _freshPooler();
        assertEq(fresh.nudgeStreamer(), address(0), "starts unset");

        vm.expectEmit(true, true, false, false);
        emit UniPoolerV2.NudgeStreamerUpdated(address(0), address(streamer));
        fresh.setNudgeStreamer(address(streamer));
        assertEq(fresh.nudgeStreamer(), address(streamer), "streamer stored");

        vm.expectEmit(true, true, false, false);
        emit UniPoolerV2.NudgeStreamerUpdated(address(streamer), address(0xB0B));
        fresh.setNudgeStreamer(address(0xB0B));
        assertEq(fresh.nudgeStreamer(), address(0xB0B), "streamer repointed");
    }

    // =========================================================================
    // _dispatch — donation disabled => full amount wrapped (ported)
    // =========================================================================

    function test_dispatch_noDonationConfig_wrapsFullAmount() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped to sUSDS");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked");
    }

    function test_dispatch_donationSizeSetButBatchMinterUnset_wrapsFull() public {
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(30);

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when batchMinter unset");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation");
    }

    function test_dispatch_donationSizeSetButPSMUnset_wrapsFull() public {
        pooler.setBatchMinter(batchMinter);
        pooler.setBatchDonationSize(30);

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when psm unset");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation");
    }

    function test_dispatch_donationSizeZero_wrapsFull() public {
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(0);

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when size 0");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation at size 0");
    }

    // =========================================================================
    // _dispatch — donation active (ported)
    // =========================================================================

    function test_dispatch_donation10Percent_splitsPoolingAndDonates() public {
        _wireDonation(10);
        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), 900e18, "90% wrapped to sUSDS");
        assertEq(usdc.balanceOf(address(streamer)), 100e6, "10% donated as USDC at 1:1 (18->6 decimals)");
        assertEq(usdc.balanceOf(batchMinter), 0, "USDC buffers in the streamer, not the sink");
        assertEq(usdc.balanceOf(address(pooler)), 0, "pooler keeps no USDC");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked on success");
    }

    function test_dispatch_donation_buffersInStreamerAndReleasesLinearly() public {
        _wireDonation(100);
        _seedSUSDS(100e18);

        (uint256 duration, uint256 buffer, uint256 rewardPerSecond,) = streamer.streams(batchMinter, address(usdc));
        assertEq(duration, STREAM_DURATION, "duration untouched by a deposit");
        assertEq(buffer, 100e6, "streamer buffers the whole donation");
        assertEq(rewardPerSecond, (100e6 * 1e18) / STREAM_DURATION, "rate recomputed over the full window");
        assertEq(usdc.balanceOf(batchMinter), 0, "nothing settled to the sink yet");

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        assertApproxEqAbs(streamer.pendingStream(batchMinter, address(usdc)), 50e6, 1, "half accrued");
        batchMinterMock.flush(address(streamer), address(usdc));
        assertApproxEqAbs(usdc.balanceOf(batchMinter), 50e6, 1, "flush delivers the accrued half");
    }

    function test_dispatch_donation_leavesNoResidualStreamerAllowance() public {
        _wireDonation(100);
        _seedSUSDS(100e18);
        assertEq(usdc.allowance(address(pooler), address(streamer)), 0, "streamer allowance fully consumed");
        assertEq(usds.allowance(address(pooler), address(psm)), 0, "PSM allowance tidied");
    }

    function test_dispatch_donationDecimals18to6_exact() public {
        _wireDonation(100);
        _seedSUSDS(1e18);
        assertEq(usdc.balanceOf(address(streamer)), 1e6, "1e18 USDS -> 1e6 USDC exact");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "nothing wrapped at 100% donation");
    }

    function test_dispatch_donation_emitsBatchDonatedViaPSM() public {
        _wireDonation(50);
        vm.recordLogs();
        _seedSUSDS(200e18);
        _assertBatchDonatedViaPSM(vm.getRecordedLogs(), 100e18, 100e6);
    }

    function test_dispatch_donation_toutFeeApplied() public {
        _wireDonation(100);
        psm.setTout(0.01e18);
        _seedSUSDS(101e18);
        assertEq(usdc.balanceOf(address(streamer)), 100e6, "tout fee reduces USDC out (100e6 for 101e18 in)");
        assertEq(usds.balanceOf(address(pooler)), 0, "exact spend leaves no USDS");
    }

    function test_dispatch_donation_floorsGemAndKeepsDust() public {
        _wireDonation(100);
        psm.setTout(0.01e18);

        uint256 amount = 102e18;
        uint256 expectedGem = (amount * 1e18) / (1e12 * (1e18 + 0.01e18));
        _seedSUSDS(amount);

        assertEq(usdc.balanceOf(address(streamer)), expectedGem, "USDC out is floored gemAmt");
        uint256 usdsSpent = expectedGem * 1e12 * (1e18 + 0.01e18) / 1e18;
        assertEq(usds.balanceOf(address(pooler)), amount - usdsSpent, "rounding dust stays on contract");
    }

    function test_dispatch_donationRoundsToZeroGem_isCleanNoOp() public {
        _wireDonation(100);
        uint256 amount = 1e11;
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        _assertNoDonationSkipped(vm.getRecordedLogs());

        assertEq(usdc.balanceOf(address(streamer)), 0, "no donation when gem floors to 0");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation when gem floors to 0");
        assertEq(usds.balanceOf(address(pooler)), amount, "sub-unit dust retained for the next sweep");
    }

    function test_dispatch_zeroDonationSweep_isCleanNoOp() public {
        _wireDonation(100);
        assertEq(usds.balanceOf(address(pooler)), 0, "pooler starts empty");

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, 0, "");
        _assertNoDonationSkipped(vm.getRecordedLogs());

        assertEq(usds.balanceOf(address(pooler)), 0, "nothing parked");
        assertEq(usdc.balanceOf(address(streamer)), 0, "nothing streamed");
        (, uint256 buffer,,) = streamer.streams(batchMinter, address(usdc));
        assertEq(buffer, 0, "streamer untouched");
    }

    function test_psmDonate_revertsForExternalCaller() public {
        _wireDonation(50);
        vm.prank(nonOwner);
        vm.expectRevert("UniPoolerV2: only self");
        pooler._psmDonate(100e18);
    }

    // =========================================================================
    // silent failure (mint never reverts) (ported)
    // =========================================================================

    function test_dispatch_psmEmptyReserve_silentSkip_mintSucceeds() public {
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        _assertDonationSkipped(vm.getRecordedLogs(), 200e18);

        assertEq(sUsds.balanceOf(address(pooler)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(pooler)), 200e18, "donation USDS parked on contract");
        assertEq(usdc.balanceOf(address(streamer)), 0, "no USDC donated on PSM failure");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC donated on PSM failure");
    }

    function test_dispatch_toutAboveMaxTout_silentSkip_mintSucceeds() public {
        _wireDonation(20);
        psm.setTout(0.02e18);

        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        _assertDonationSkipped(vm.getRecordedLogs(), 200e18);

        assertEq(sUsds.balanceOf(address(pooler)), 800e18, "pooling portion wrapped");
        assertEq(usds.balanceOf(address(pooler)), 200e18, "donation USDS parked when tout too high");
        assertEq(usdc.balanceOf(address(streamer)), 0, "no donation when tout exceeds ceiling");
    }

    function test_dispatch_streamerUnset_donationCaughtAndParked() public {
        UniPoolerV2 fresh = _freshPooler();
        fresh.setBatchMinter(batchMinter);
        fresh.setPSM(address(psm));
        fresh.setBatchDonationSize(20);
        assertEq(fresh.nudgeStreamer(), address(0), "streamer starts unset");

        uint256 amount = 1000e18;
        usds.mint(address(fresh), amount);

        vm.prank(minter);
        fresh.dispatch(minter, amount, "");

        assertEq(sUsds.balanceOf(address(fresh)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(fresh)), 200e18, "donation USDS parked when streamer unset");
        assertEq(usdc.balanceOf(address(streamer)), 0, "no USDC moved");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC moved");

        fresh.setNudgeStreamer(address(streamer));
        vm.prank(minter);
        fresh.dispatch(minter, 0, "");
        assertEq(usdc.balanceOf(address(streamer)), 200e6, "parked USDS recovered once wired");
        assertEq(usds.balanceOf(address(fresh)), 0, "backlog drained");
    }

    function test_dispatch_streamNotRegistered_donationCaughtAndParked() public {
        _wireDonation(20);
        NudgeStreamer unregistered = new NudgeStreamer(owner);
        pooler.setNudgeStreamer(address(unregistered));

        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        _assertDonationSkipped(vm.getRecordedLogs(), 200e18);

        assertEq(sUsds.balanceOf(address(pooler)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(pooler)), 200e18, "donation USDS parked when stream unregistered");
        assertEq(usdc.balanceOf(address(unregistered)), 0, "no USDC reached the unregistered streamer");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC reached the sink");
    }

    function test_dispatch_donationDisabled_needsNoStreamer() public {
        UniPoolerV2 fresh = _freshPooler();
        assertEq(fresh.nudgeStreamer(), address(0), "streamer deliberately unset");

        uint256 amount = 1000e18;
        usds.mint(address(fresh), amount);
        vm.prank(minter);
        fresh.dispatch(minter, amount, "");

        assertEq(sUsds.balanceOf(address(fresh)), amount, "full amount wrapped, no streamer needed");
        assertEq(usds.balanceOf(address(fresh)), 0, "nothing parked");
    }

    function test_dispatch_raisingMaxTout_allowsHigherToutDonation() public {
        _wireDonation(100);
        psm.setTout(0.02e18);

        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        assertEq(usdc.balanceOf(address(streamer)), 0, "skipped at 1% ceiling");
        assertEq(usds.balanceOf(address(pooler)), amount, "parked at 1% ceiling");

        pooler.setMaxTout(0.05e18);
        vm.prank(minter);
        pooler.dispatch(minter, 0, "");

        uint256 expectedGem = (amount * 1e18) / (1e12 * (1e18 + 0.02e18));
        assertEq(usdc.balanceOf(address(streamer)), expectedGem, "donated after raising maxTout");
    }

    function test_dispatch_strandedUSDS_sweptOnNextDispatch() public {
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        _seedSUSDS(1000e18);
        assertEq(usds.balanceOf(address(pooler)), 200e18, "first donation stranded");

        pooler.setPSM(address(psm));
        _seedSUSDS(500e18);

        assertEq(usdc.balanceOf(address(streamer)), 300e6, "stranded + new donation swept together");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS left after healthy sweep");
        assertEq(sUsds.balanceOf(address(pooler)), 1200e18, "pooling portions accumulated");
    }

    // =========================================================================
    // donation is independent of pool() (ported)
    // =========================================================================

    function test_pool_pureLP_afterDonatingDispatch() public {
        _seedPair(10_000e18, 10_000e18);
        _wireDonation(10);
        _seedSUSDS(1000e18); // 900e18 wrapped, 100e6 USDC donated
        uint256 streamed = usdc.balanceOf(address(streamer));

        _quoteAndPool(900e18);

        assertLe(sUsds.balanceOf(address(pooler)), 2, "all wrapped sUSDS pooled (dust only)");
        assertGt(pair.balanceOf(address(pooler)), 0, "pooler holds LP");
        assertEq(usdc.balanceOf(address(streamer)), streamed, "pool() does not touch the donation");
        assertEq(usdc.balanceOf(address(pooler)), 0, "pool() moves no USDC");
    }

    function test_pool_doesNotTouchParkedUSDS() public {
        _seedPair(10_000e18, 10_000e18);
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        _seedSUSDS(1000e18); // 200e18 USDS parked, 800e18 sUSDS
        assertEq(usds.balanceOf(address(pooler)), 200e18, "USDS parked");

        _quoteAndPool(800e18);

        assertEq(usds.balanceOf(address(pooler)), 200e18, "parked USDS untouched by pool()");
        assertGt(pair.balanceOf(address(pooler)), 0, "only sUSDS pooled");
    }
}
