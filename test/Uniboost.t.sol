// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Uniboost} from "../src/dispatchers/Uniboost.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mock ERC20 with configurable decimals and open mint/burn for testing.
contract MockERC20 is ERC20 {
    uint8 private _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}

/// @dev Mock UniV2 pair exposing token0/token1. Doubles as the LP token (mintable) so the mock
///      router can mint LP to the dispatcher, mirroring the spec's "LP token is the pair ERC20".
contract MockUniV2Pair is MockERC20 {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) MockERC20("UniV2 LP", "UNI-V2", 18) {
        token0 = token0_;
        token1 = token1_;
    }
}

/// @dev Mock Uniswap V2 Router02. Simulates swapExactTokensForTokens (pulls amountIn of path[0],
///      mints a configurable rate of path[last] to `to`, honors amountOutMin) and addLiquidity
///      (pulls both desired amounts, mints LP = the pair token, honors a configurable LP-out).
contract MockUniV2Router {
    using SafeERC20 for IERC20;

    /// @dev Output rate in basis points relative to amountIn (10000 = 1:1).
    uint256 public swapRateBps = 10000;

    /// @dev When > 0, addLiquidity mints exactly this much LP. When 0, mints amountADesired (1:1).
    uint256 public configurableLP;

    /// @dev The LP token to mint on addLiquidity (set to the target pool / pair token).
    MockUniV2Pair public lpToken;

    bool public swapCalled;
    bool public addLiquidityCalled;
    uint256 public swapCallCount;

    address public lastSwapPathFirst;
    address public lastSwapPathLast;
    uint256 public lastSwapAmountIn;
    address public lastAddTokenA;
    address public lastAddTokenB;
    uint256 public lastAddAmountA;
    uint256 public lastAddAmountB;

    function setSwapRateBps(uint256 bps) external {
        swapRateBps = bps;
    }

    function setConfigurableLP(uint256 amount) external {
        configurableLP = amount;
    }

    function setLpToken(MockUniV2Pair lp) external {
        lpToken = lp;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        swapCalled = true;
        swapCallCount += 1;
        lastSwapPathFirst = path[0];
        lastSwapPathLast = path[path.length - 1];
        lastSwapAmountIn = amountIn;

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * swapRateBps) / 10000;
        require(amountOut >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MockERC20(path[path.length - 1]).mint(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256, /* amountAMin */
        uint256, /* amountBMin */
        address to,
        uint256 /* deadline */
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        addLiquidityCalled = true;
        lastAddTokenA = tokenA;
        lastAddTokenB = tokenB;
        lastAddAmountA = amountADesired;
        lastAddAmountB = amountBDesired;

        // Pull both sides (consumes the dispatcher's full desired balances in this mock).
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);

        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = configurableLP > 0 ? configurableLP : amountADesired;
        lpToken.mint(to, liquidity);
    }
}

contract UniboostTest is Test {
    Uniboost public uniboost;
    MockERC20 public prime; // USDC, 6dp
    MockERC20 public target; // EYE, 18dp
    MockERC20 public pair; // WETH, 18dp
    MockUniV2Pair public pool; // EYE/WETH pair (also LP token)
    MockUniV2Router public router;

    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);
    address public recipientAddr = address(0xD011);
    address public authorizedPooler = address(0xD00D);

    function setUp() public {
        prime = new MockERC20("USD Coin", "USDC", 6);
        target = new MockERC20("EYE", "EYE", 18);
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        // token0 = target (EYE), token1 = pair (WETH)
        pool = new MockUniV2Pair(address(target), address(pair));
        router = new MockUniV2Router();
        router.setLpToken(pool);

        uniboost = new Uniboost(address(prime), address(router), address(pool), address(target), owner);
        uniboost.setMinter(minter);
        uniboost.setAuthorizedPooler(authorizedPooler, true);
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroPrime() public {
        vm.expectRevert("Uniboost: zero prime");
        new Uniboost(address(0), address(router), address(pool), address(target), owner);
    }

    function test_constructor_revertsWithZeroRouter() public {
        vm.expectRevert("Uniboost: zero router");
        new Uniboost(address(prime), address(0), address(pool), address(target), owner);
    }

    function test_constructor_revertsWithZeroTargetToken() public {
        vm.expectRevert("Uniboost: zero target token");
        new Uniboost(address(prime), address(router), address(pool), address(0), owner);
    }

    function test_constructor_revertsWhenPoolMissingTargetToken() public {
        // Pool of two unrelated tokens that do not include `target`.
        MockUniV2Pair badPool = new MockUniV2Pair(address(prime), address(pair));
        vm.expectRevert("Uniboost: pool missing target token");
        new Uniboost(address(prime), address(router), address(badPool), address(target), owner);
    }

    function test_constructor_authVersionInitializedToOne() public view {
        assertEq(uniboost.authVersion(), 1, "authVersion should be 1");
    }

    function test_constructor_cachesPairToken_targetIsToken0() public view {
        // pool token0 = target, token1 = pair => pairToken should be pair.
        assertEq(uniboost.pairToken(), address(pair), "pairToken should be the non-target token (token1)");
    }

    function test_constructor_cachesPairToken_targetIsToken1() public {
        // Build a pool where target is token1.
        MockUniV2Pair reversedPool = new MockUniV2Pair(address(pair), address(target));
        Uniboost ub = new Uniboost(address(prime), address(router), address(reversedPool), address(target), owner);
        assertEq(ub.pairToken(), address(pair), "pairToken should be token0 when target is token1");
    }

    // =========================================================================
    // getter tests
    // =========================================================================

    function test_primeToken_returnsPrime() public view {
        assertEq(uniboost.primeToken(), address(prime));
    }

    function test_router_returnsRouter() public view {
        assertEq(uniboost.router(), address(router));
    }

    function test_targetPool_returnsPool() public view {
        assertEq(uniboost.targetPool(), address(pool));
    }

    function test_targetToken_returnsTarget() public view {
        assertEq(uniboost.targetToken(), address(target));
    }

    // =========================================================================
    // setPool tests
    // =========================================================================

    function test_setPool_repointsPoolAndPairToken() public {
        // New pool with a different pairing token.
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockUniV2Pair newPool = new MockUniV2Pair(address(target), address(dai));

        vm.expectEmit(true, true, false, true);
        emit Uniboost.PoolSet(address(newPool), address(dai));
        uniboost.setPool(address(newPool));

        assertEq(uniboost.targetPool(), address(newPool), "pool should be repointed");
        assertEq(uniboost.pairToken(), address(dai), "pairToken should be the new pool's other token");
    }

    function test_setPool_revertsWithZeroAddress() public {
        vm.expectRevert("Uniboost: zero pool");
        uniboost.setPool(address(0));
    }

    function test_setPool_revertsWhenPoolMissingTargetToken() public {
        MockUniV2Pair badPool = new MockUniV2Pair(address(prime), address(pair));
        vm.expectRevert("Uniboost: pool missing target token");
        uniboost.setPool(address(badPool));
    }

    function test_setPool_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.setPool(address(pool));
    }

    // =========================================================================
    // setDonationSplit / setRecipient tests
    // =========================================================================

    function test_setDonationSplit_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit Uniboost.DonationSplitSet(50);
        uniboost.setDonationSplit(50);
        assertEq(uniboost.donationSplit(), 50);
    }

    function test_setDonationSplit_oneHundredAllowed() public {
        uniboost.setDonationSplit(100);
        assertEq(uniboost.donationSplit(), 100);
    }

    function test_setDonationSplit_revertsAbove100() public {
        vm.expectRevert("Uniboost: split > 100");
        uniboost.setDonationSplit(101);
    }

    function test_setDonationSplit_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.setDonationSplit(10);
    }

    function test_setRecipient_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit Uniboost.RecipientSet(recipientAddr);
        uniboost.setRecipient(recipientAddr);
        assertEq(uniboost.recipient(), recipientAddr);
    }

    function test_setRecipient_zeroAllowed() public {
        uniboost.setRecipient(recipientAddr);
        uniboost.setRecipient(address(0));
        assertEq(uniboost.recipient(), address(0), "zero recipient allowed (disables donation)");
    }

    function test_setRecipient_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.setRecipient(recipientAddr);
    }

    // =========================================================================
    // _dispatch tests (via dispatch as minter)
    // =========================================================================

    function _enableDonation(uint256 split) internal {
        uniboost.setRecipient(recipientAddr);
        uniboost.setDonationSplit(split);
    }

    function test_dispatch_donationEnabled_forwardsSplitAndRetainsRemainder() public {
        _enableDonation(50);

        uint256 amount = 10e6; // 10 USDC
        prime.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.dispatch(minter, amount, "");

        assertEq(prime.balanceOf(recipientAddr), 5e6, "50% forwarded to recipient");
        assertEq(prime.balanceOf(address(uniboost)), 5e6, "remainder retained on contract");
    }

    function test_dispatch_donationDisabled_recipientZero_retainsFull() public {
        uniboost.setDonationSplit(50); // recipient unset => disabled
        uint256 amount = 10e6;
        prime.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.dispatch(minter, amount, "");

        assertEq(prime.balanceOf(recipientAddr), 0, "no donation when recipient is zero");
        assertEq(prime.balanceOf(address(uniboost)), amount, "full amount retained");
    }

    function test_dispatch_donationDisabled_splitZero_retainsFull() public {
        uniboost.setRecipient(recipientAddr); // split 0 => disabled
        uint256 amount = 10e6;
        prime.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.dispatch(minter, amount, "");

        assertEq(prime.balanceOf(recipientAddr), 0, "no donation at split 0");
        assertEq(prime.balanceOf(address(uniboost)), amount, "full amount retained");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 10e6;
        prime.mint(address(uniboost), amount);

        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        uniboost.dispatch(nonOwner, amount, "");
    }

    function test_dispatch_revertsWhenPaused() public {
        uint256 amount = 10e6;
        prime.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        uniboost.dispatch(minter, amount, "");
    }

    function test_dispatch_invokesHookWithGrossAmount() public {
        MockDispatchHook hook = new MockDispatchHook();
        uniboost.setHook(IDispatchHook(address(hook)));
        _enableDonation(50);

        uint256 amount = 10e6;
        bytes memory payload = hex"cafebabe";
        prime.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.dispatch(minter, amount, payload);

        assertEq(hook.callCount(), 1, "hook called once");
        assertEq(hook.lastMinter(), minter, "hook receives minter");
        assertEq(hook.lastAmount(), amount, "hook receives gross amount, not net of donation");
        assertEq(hook.lastExtraData(), payload, "hook receives extraData verbatim");
    }

    // =========================================================================
    // primeToPairPath / setPrimeToPairPath tests
    // =========================================================================

    function test_primeToPairPath_defaultsToDirect() public view {
        address[] memory path = uniboost.primeToPairPath();
        assertEq(path.length, 2, "default path is direct (length 2)");
        assertEq(path[0], address(prime), "path[0] == prime");
        assertEq(path[1], address(pair), "path[1] == pairToken");
    }

    function test_setPrimeToPairPath_storesCustomPath() public {
        MockERC20 hop = new MockERC20("HOP", "HOP", 18);
        address[] memory custom = new address[](3);
        custom[0] = address(prime);
        custom[1] = address(hop);
        custom[2] = address(pair);

        uniboost.setPrimeToPairPath(custom);

        address[] memory stored = uniboost.primeToPairPath();
        assertEq(stored.length, 3, "custom path length");
        assertEq(stored[1], address(hop), "intermediate hop stored");
    }

    function test_setPrimeToPairPath_revertsWhenStartNotPrime() public {
        address[] memory bad = new address[](2);
        bad[0] = address(pair);
        bad[1] = address(pair);
        vm.expectRevert("Uniboost: path start not prime");
        uniboost.setPrimeToPairPath(bad);
    }

    function test_setPrimeToPairPath_revertsWhenEndNotPair() public {
        address[] memory bad = new address[](2);
        bad[0] = address(prime);
        bad[1] = address(target);
        vm.expectRevert("Uniboost: path end not pair");
        uniboost.setPrimeToPairPath(bad);
    }

    function test_setPrimeToPairPath_revertsWhenTooShort() public {
        address[] memory bad = new address[](1);
        bad[0] = address(prime);
        vm.expectRevert("Uniboost: path too short");
        uniboost.setPrimeToPairPath(bad);
    }

    function test_setPrimeToPairPath_revertsForNonOwner() public {
        address[] memory custom = new address[](2);
        custom[0] = address(prime);
        custom[1] = address(pair);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.setPrimeToPairPath(custom);
    }

    // =========================================================================
    // pool() tests
    // =========================================================================

    /// @dev Seed retained prime on the dispatcher (no donation) via a dispatch.
    function _seedPrime(uint256 amount) internal {
        prime.mint(address(uniboost), amount);
        vm.prank(minter);
        uniboost.dispatch(minter, amount, "");
    }

    function test_pool_revertsWhenNothingToPool() public {
        vm.prank(authorizedPooler);
        vm.expectRevert("Uniboost: nothing to pool");
        uniboost.pool(0, 0, 0, 0);
    }

    function test_pool_revertsForNonAuthorizedPooler() public {
        _seedPrime(100e6);
        vm.prank(nonOwner);
        vm.expectRevert("Uniboost: caller not authorized pooler");
        uniboost.pool(100e6, 0, 0, 0);
    }

    function test_pool_endToEnd_sequenceAndLPLandsOnDispatcher() public {
        // 1:1 swap rate. 100 USDC (6dp) -> 100 WETH(treated raw) -> half(50) -> 50 EYE.
        // addLiquidity pulls targetBal(50 EYE) + pairRemaining(50 WETH), mints LP = amountADesired = 50.
        _seedPrime(100e6);

        vm.prank(authorizedPooler);
        vm.expectEmit(true, false, false, true);
        emit Uniboost.Pooled(authorizedPooler, 100e6, 50e6, 0);
        uniboost.pool(100e6, 0, 0, 0);

        // prime fully spent (swapped away).
        assertEq(prime.balanceOf(address(uniboost)), 0, "prime fully swapped");
        // LP (the pool token) accrued on the dispatcher.
        assertEq(pool.balanceOf(address(uniboost)), 50e6, "LP minted to dispatcher");
        // Both swaps + addLiquidity ran.
        assertTrue(router.swapCalled(), "router swapped");
        assertEq(router.swapCallCount(), 2, "two swaps (prime->pair, pair->target)");
        assertTrue(router.addLiquidityCalled(), "addLiquidity ran");
        // addLiquidity received (targetToken, pairToken) ordering.
        assertEq(router.lastAddTokenA(), address(target), "addLiquidity tokenA == targetToken");
        assertEq(router.lastAddTokenB(), address(pair), "addLiquidity tokenB == pairToken");
    }

    function test_pool_usesDirectPath_forPrimeSwap() public {
        _seedPrime(100e6);
        vm.prank(authorizedPooler);
        uniboost.pool(100e6, 0, 0, 0);
        assertEq(router.lastSwapPathFirst(), address(pair), "last swap (pair->target) path[0] == pair");
        assertEq(router.lastSwapPathLast(), address(target), "last swap path[last] == target");
    }

    function test_pool_revertsWhenMinPairOutNotMet() public {
        _seedPrime(100e6);
        router.setSwapRateBps(5000); // 100 USDC -> 50 pair, below floor
        vm.prank(authorizedPooler);
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        uniboost.pool(100e6, 80e6, 0, 0); // minPairOut = 80, got 50
    }

    function test_pool_revertsWhenMinTargetOutNotMet() public {
        _seedPrime(100e6);
        // First swap 1:1 -> 100 pair. half = 50. Second swap at 5000bps -> 25 target < 40 floor.
        // Use a router that drops only the second swap: simplest is global 5000 but then first
        // swap (100->50) >= minPairOut(0) passes, half=25, second 25->12 < 20 floor.
        router.setSwapRateBps(5000);
        vm.prank(authorizedPooler);
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        uniboost.pool(100e6, 0, 20e6, 0); // minTargetOut not met on second swap
    }

    function test_pool_revertsWhenMinLPNotMet() public {
        _seedPrime(100e6);
        router.setConfigurableLP(10e6); // addLiquidity mints only 10 LP
        vm.prank(authorizedPooler);
        vm.expectRevert("Uniboost: insufficient LP");
        uniboost.pool(100e6, 0, 0, 50e6); // minLP = 50, got 10
    }

    function test_pool_respectsWhenNotPaused() public {
        _seedPrime(100e6);
        vm.prank(minter);
        uniboost.pause();
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        uniboost.pool(100e6, 0, 0, 0);
    }

    function test_pool_partialAmount_leavesRemainderAndStillMintsLP() public {
        // Retain 100 USDC; pool only 13. 1:1 swap: 13 USDC -> 13 pair, half(6.5) -> 6.5 target,
        // addLiquidity pulls targetBal(6.5) + pairRemaining(6.5), mints LP = amountADesired = 6.5.
        _seedPrime(100e6);

        uint256 amountIn = 13e6;
        vm.prank(authorizedPooler);
        vm.expectEmit(true, false, false, true);
        emit Uniboost.Pooled(authorizedPooler, amountIn, 6_500_000, 0);
        uniboost.pool(amountIn, 0, 0, 0);

        // Exactly amountIn consumed; remainder stays on the dispatcher for a later pool().
        assertEq(prime.balanceOf(address(uniboost)), 100e6 - amountIn, "remainder of prime retained");
        // Only amountIn was swapped into the pair side on the first swap.
        assertEq(router.lastAddTokenA(), address(target), "addLiquidity tokenA == targetToken");
        // LP still minted to the dispatcher.
        assertEq(pool.balanceOf(address(uniboost)), 6_500_000, "LP minted to dispatcher on partial pool");
    }

    function test_pool_revertsWhenAmountInZero() public {
        _seedPrime(100e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("Uniboost: nothing to pool");
        uniboost.pool(0, 0, 0, 0);
    }

    function test_pool_revertsWhenAmountInExceedsBalance() public {
        _seedPrime(100e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("Uniboost: insufficient prime");
        uniboost.pool(100e6 + 1, 0, 0, 0);
    }

    function test_pool_doesNotInvokeHook() public {
        MockDispatchHook hook = new MockDispatchHook();
        uniboost.setHook(IDispatchHook(address(hook)));
        _seedPrime(100e6);
        assertEq(hook.callCount(), 1, "dispatch invoked hook once");

        vm.prank(authorizedPooler);
        uniboost.pool(100e6, 0, 0, 0);
        assertEq(hook.callCount(), 1, "pool() must not invoke the dispatch hook");
    }

    // =========================================================================
    // setAuthorizedPooler / incrementAuthVersion tests
    // =========================================================================

    function test_setAuthorizedPooler_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.setAuthorizedPooler(address(0x1111), true);
    }

    function test_setAuthorizedPooler_revertsOnZeroAddress() public {
        vm.expectRevert("Uniboost: zero pooler");
        uniboost.setAuthorizedPooler(address(0), true);
    }

    function test_setAuthorizedPooler_authorizeSetsVersionAndEmits() public {
        address newPooler = address(0x2222);
        vm.expectEmit(true, false, false, true);
        emit Uniboost.PoolerAuthorized(newPooler, 1);
        uniboost.setAuthorizedPooler(newPooler, true);
        assertEq(uniboost.poolerAuthVersion(newPooler), 1);
    }

    function test_setAuthorizedPooler_deauthorizeClearsAndRevertsPool() public {
        address p = address(0x3333);
        uniboost.setAuthorizedPooler(p, true);

        vm.expectEmit(true, false, false, false);
        emit Uniboost.PoolerDeauthorized(p);
        uniboost.setAuthorizedPooler(p, false);
        assertEq(uniboost.poolerAuthVersion(p), 0);

        _seedPrime(100e6);
        vm.prank(p);
        vm.expectRevert("Uniboost: caller not authorized pooler");
        uniboost.pool(100e6, 0, 0, 0);
    }

    function test_incrementAuthVersion_massRevoke() public {
        uniboost.setAuthorizedPooler(authorizedPooler, true);

        vm.expectEmit(false, false, false, true);
        emit Uniboost.AuthVersionIncremented(2);
        uniboost.incrementAuthVersion();
        assertEq(uniboost.authVersion(), 2);

        _seedPrime(100e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("Uniboost: caller not authorized pooler");
        uniboost.pool(100e6, 0, 0, 0);

        // Re-authorize works at new version.
        uniboost.setAuthorizedPooler(authorizedPooler, true);
        assertEq(uniboost.poolerAuthVersion(authorizedPooler), 2);
        vm.prank(authorizedPooler);
        uniboost.pool(100e6, 0, 0, 0); // succeeds now
    }

    function test_incrementAuthVersion_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.incrementAuthVersion();
    }

    // =========================================================================
    // rescueERC20 tests
    // =========================================================================

    function test_rescueERC20_movesArbitraryToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 50e18;
        stray.mint(address(uniboost), amount);

        address to = address(0xBBBB);
        uniboost.rescueERC20(address(stray), to, amount);

        assertEq(stray.balanceOf(to), amount, "recipient received rescued tokens");
        assertEq(stray.balanceOf(address(uniboost)), 0, "dispatcher drained");
    }

    function test_rescueERC20_withdrawsLPPairToken() public {
        // Pool to leave LP (the pool token) on the dispatcher, then rescue it.
        _seedPrime(100e6);
        vm.prank(authorizedPooler);
        uniboost.pool(100e6, 0, 0, 0);

        uint256 lp = pool.balanceOf(address(uniboost));
        assertTrue(lp > 0, "dispatcher holds LP after pool");

        address to = address(0xCCCC);
        uniboost.rescueERC20(address(pool), to, lp);
        assertEq(pool.balanceOf(to), lp, "recipient receives all LP");
        assertEq(pool.balanceOf(address(uniboost)), 0, "dispatcher LP drained");
    }

    function test_rescueERC20_revertsForNonOwner() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(uniboost), 10e18);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        uniboost.rescueERC20(address(stray), nonOwner, 10e18);
    }

    function test_rescueERC20_revertsWhenRecipientZero() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(uniboost), 10e18);
        vm.expectRevert("Uniboost: zero recipient");
        uniboost.rescueERC20(address(stray), address(0), 10e18);
    }

    function test_rescueERC20_worksWhilePaused() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 25e18;
        stray.mint(address(uniboost), amount);

        vm.prank(minter);
        uniboost.pause();

        address to = address(0xEEEE);
        uniboost.rescueERC20(address(stray), to, amount);
        assertEq(stray.balanceOf(to), amount, "rescue works while paused");
    }
}
