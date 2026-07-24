// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BalancerPoolerV2} from "../src/dispatchers/BalancerPoolerV2.sol";
import {IUnlockCallback} from "../src/interfaces/balancer/IUnlockCallback.sol";
import {
    AddLiquidityParams,
    AddLiquidityKind,
    VaultSwapParams,
    SwapKind
} from "../src/interfaces/balancer/BalancerTypes.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {MockMintable} from "./mocks/MockMintable.sol";
import {BalancerPoolerMintDebtHook} from "../src/hooks/BalancerPoolerMintDebtHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockERC4626Wrapper} from "./mocks/MockERC4626Wrapper.sol";
import {MockSkyPSM} from "./mocks/MockSkyPSM.sol";
import {MockNudgeBatchMinter} from "./mocks/MockNudgeBatchMinter.sol";
import {NudgeStreamer} from "phoenix-nft-staking/NudgeStreamer.sol";

/// @dev Mock ERC20 with configurable decimals for testing.
contract MockERC20 is ERC20 {
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

/// @dev Mock Balancer Vault that implements the unlock/callback pattern.
contract MockBalancerVault {
    using SafeERC20 for IERC20;

    /// @dev Internal-balance ledger: token => amount credited to the caller of `swap`,
    ///      pending withdrawal via `sendTo`. Models the V3 Vault's transient accounting:
    ///      swap credits the output token to the caller's internal balance; the caller
    ///      must explicitly call `sendTo(tokenOut, recipient, amount)` to receive the
    ///      ERC20 from the vault. If the production code skips `sendTo`, downstream
    ///      operations against the dispatcher's real balance will fail — which is the
    ///      exact regression this mock now catches.
    mapping(address => uint256) public internalBalance;

    AddLiquidityParams public lastParams;
    bool public addLiquidityCalled;

    /// @dev Configurable BPT output. When > 0, overrides the default 1:1 behavior.
    uint256 public configurableBptOut;

    struct Settlement {
        address token;
        uint256 amount;
    }

    Settlement[] public settlements;

    /// @dev Captured `swap` invocation state.
    bool public swapCalled;
    SwapKind public lastSwapKind;
    address public lastSwapPool;
    address public lastSwapTokenIn;
    address public lastSwapTokenOut;
    uint256 public lastSwapAmountGivenRaw;
    uint256 public lastSwapLimitRaw;
    bytes public lastSwapUserData;

    /// @dev Configurable swap output rate, in basis points relative to amountGivenRaw
    ///      (10000 = 1:1, 5000 = 0.5x, etc.). Tests can also override via
    ///      `setConfigurableSwapOut` to return a fixed amount.
    uint256 public swapRateBps = 10000;
    uint256 public configurableSwapOut;

    function unlock(bytes calldata data) external returns (bytes memory result) {
        (bool success, bytes memory returnData) = msg.sender.call(data);
        require(success, "MockBalancerVault: unlock callback failed");
        result = returnData;
    }

    function addLiquidity(AddLiquidityParams memory params)
        external
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData)
    {
        lastParams.pool = params.pool;
        lastParams.to = params.to;
        lastParams.minBptAmountOut = params.minBptAmountOut;
        lastParams.kind = params.kind;
        lastParams.userData = params.userData;

        delete lastParams.maxAmountsIn;
        for (uint256 i = 0; i < params.maxAmountsIn.length; i++) {
            lastParams.maxAmountsIn.push(params.maxAmountsIn[i]);
        }

        addLiquidityCalled = true;

        uint256 totalIn;
        for (uint256 i = 0; i < params.maxAmountsIn.length; i++) {
            totalIn += params.maxAmountsIn[i];
        }

        // Use configurable output if set, otherwise 1:1
        bptAmountOut = configurableBptOut > 0 ? configurableBptOut : totalIn;

        require(bptAmountOut >= params.minBptAmountOut, "BPT_OUT_MIN_AMOUNT");
        MockERC20(params.pool).mint(params.to, bptAmountOut);

        amountsIn = params.maxAmountsIn;
        returnData = "";
    }

    function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit) {
        settlements.push(Settlement({token: address(token), amount: amountHint}));
        return amountHint;
    }

    function swap(VaultSwapParams memory params)
        external
        returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw)
    {
        swapCalled = true;
        lastSwapKind = params.kind;
        lastSwapPool = params.pool;
        lastSwapTokenIn = address(params.tokenIn);
        lastSwapTokenOut = address(params.tokenOut);
        lastSwapAmountGivenRaw = params.amountGivenRaw;
        lastSwapLimitRaw = params.limitRaw;
        lastSwapUserData = params.userData;

        amountInRaw = params.amountGivenRaw;
        amountOutRaw = configurableSwapOut > 0 ? configurableSwapOut : (params.amountGivenRaw * swapRateBps) / 10000;
        amountCalculatedRaw = 0;

        // Real V3 Vault behaviour: credit tokenOut to the caller's internal balance
        // and hold the actual ERC20 inside the vault until `sendTo` is invoked.
        // The mock keeps the shares it mints on its own balance; the caller must
        // call `sendTo(tokenOut, recipient, amountOutRaw)` to receive them.
        MockERC4626Wrapper(address(params.tokenOut)).mintShares(address(this), amountOutRaw);
        internalBalance[address(params.tokenOut)] += amountOutRaw;
    }

    /// @dev Real implementation modelling the V3 Vault's `sendTo`. Debits the
    ///      caller's internal-balance credit and transfers the held ERC20 from
    ///      the vault to the recipient. Reverts if the caller hasn't credited
    ///      enough via a prior `swap`.
    function sendTo(IERC20 token, address to, uint256 amount) external {
        require(internalBalance[address(token)] >= amount, "MockBalancerVault: insufficient credit");
        internalBalance[address(token)] -= amount;
        token.safeTransfer(to, amount);
    }

    function setSwapRateBps(uint256 rateBps) external {
        swapRateBps = rateBps;
    }

    function setConfigurableSwapOut(uint256 amount) external {
        configurableSwapOut = amount;
    }

    function resetSwapCalled() external {
        swapCalled = false;
    }

    /// @dev Set a fixed BPT output amount (for slippage testing). Set 0 to revert to default.
    function setConfigurableBptOut(uint256 amount) external {
        configurableBptOut = amount;
    }

    function resetAddLiquidityCalled() external {
        addLiquidityCalled = false;
    }

    function getSettlementsCount() external view returns (uint256) {
        return settlements.length;
    }

    function getSettlement(uint256 index) external view returns (address token, uint256 amount) {
        Settlement memory s = settlements[index];
        return (s.token, s.amount);
    }

    function getLastParamsPool() external view returns (address) {
        return lastParams.pool;
    }

    function getLastParamsKind() external view returns (AddLiquidityKind) {
        return lastParams.kind;
    }

    function getLastParamsMinBptAmountOut() external view returns (uint256) {
        return lastParams.minBptAmountOut;
    }

    function getLastParamsMaxAmountsIn() external view returns (uint256[] memory) {
        return lastParams.maxAmountsIn;
    }
}

/// @dev Mock Balancer Router for queryAddLiquidityUnbalanced.
contract MockBalancerRouter {
    uint256 public configurableBptOut;
    address public lastPool;
    uint256[] public lastExactAmountsIn;
    address public lastSender;
    bytes public lastUserData;
    bool public queryCalled;

    function setConfigurableBptOut(uint256 amount) external {
        configurableBptOut = amount;
    }

    function queryAddLiquidityUnbalanced(
        address pool_,
        uint256[] memory exactAmountsIn_,
        address sender_,
        bytes memory userData_
    ) external returns (uint256 bptAmountOut) {
        lastPool = pool_;
        delete lastExactAmountsIn;
        for (uint256 i = 0; i < exactAmountsIn_.length; i++) {
            lastExactAmountsIn.push(exactAmountsIn_[i]);
        }
        lastSender = sender_;
        lastUserData = userData_;
        queryCalled = true;
        return configurableBptOut;
    }

    function getLastExactAmountsIn() external view returns (uint256[] memory) {
        return lastExactAmountsIn;
    }
}

contract BalancerPoolerV2Test is Test {
    BalancerPoolerV2 public pooler;
    MockERC20 public usds; // underlying prime token (USDS)
    MockERC4626 public sUsds; // ERC4626 wrapper (sUSDS)
    MockBalancerVault public mockVault;
    MockBalancerRouter public mockRouter;
    MockERC20 public bptToken;
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);
    address public authorizedPooler = address(0xD00D);

    function setUp() public {
        usds = new MockERC20("USDS", "USDS", 18);
        sUsds = new MockERC4626("Savings USDS", "sUSDS", address(usds), 10000); // 1:1 rate
        bptToken = new MockERC20("Balancer Pool Token", "BPT", 18);
        mockVault = new MockBalancerVault();
        mockRouter = new MockBalancerRouter();
        pooler = new BalancerPoolerV2(
            address(sUsds), address(bptToken), address(mockVault), address(mockRouter), true, owner
        );
        pooler.setMinter(minter);
        pooler.setAuthorizedPooler(authorizedPooler, true);

        // Story 047: the donation now hops through a real NudgeStreamer, so the whole nudge
        // stack (USDC + PSM + batch-minter + streamer) is stood up eagerly and the pooler is
        // pointed at the streamer. Tests that need an UNWIRED pooler build a fresh one.
        _ensurePSM();
        pooler.setNudgeStreamer(address(streamer));
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroSUSDS() public {
        vm.expectRevert("BalancerPoolerV2: zero sUSDS");
        new BalancerPoolerV2(address(0), address(bptToken), address(mockVault), address(mockRouter), true, owner);
    }

    function test_constructor_revertsWithZeroRouter() public {
        vm.expectRevert("BalancerPoolerV2: zero router");
        new BalancerPoolerV2(address(sUsds), address(bptToken), address(mockVault), address(0), true, owner);
    }

    function test_constructor_authVersionInitializedToOne() public view {
        assertEq(pooler.authVersion(), 1, "authVersion should be initialized to 1");
    }

    // =========================================================================
    // primeToken() getter tests
    // =========================================================================

    function test_primeToken_returnsUSDSAddress() public view {
        assertEq(pooler.primeToken(), address(usds), "primeToken() should return the USDS address");
    }

    // =========================================================================
    // sUSDS() getter tests
    // =========================================================================

    function test_sUSDS_returnsConstructorSuppliedAddress() public view {
        assertEq(pooler.sUSDS(), address(sUsds), "sUSDS() should return the constructor-supplied sUSDS address");
    }

    // =========================================================================
    // vault() and pool() getter tests
    // =========================================================================

    function test_vault_returnsCorrectAddress() public view {
        assertEq(pooler.vault(), address(mockVault));
    }

    function test_pool_returnsCorrectAddress() public view {
        assertEq(pooler.pool(), address(bptToken));
    }

    // =========================================================================
    // setPool tests
    // =========================================================================

    function test_setPool_ownerCanSetPool() public {
        address newPool = address(0x1234);
        pooler.setPool(newPool);
        assertEq(pooler.pool(), newPool, "Pool should be updated");
    }

    function test_setPool_revertsWhenCalledByNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setPool(address(0x1234));
    }

    function test_setPool_revertsWithZeroAddress() public {
        vm.expectRevert("BalancerPoolerV2: zero pool address");
        pooler.setPool(address(0));
    }

    // =========================================================================
    // dispatch tests — USDS wrap to sUSDS only
    // =========================================================================

    function test_dispatch_wrapsUSDSToSUSDS() public {
        uint256 amount = 1e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // sUSDS balance should increase, USDS balance should go to 0
        assertEq(sUsds.balanceOf(address(pooler)), amount, "Dispatcher sUSDS balance should increase");
        assertEq(usds.balanceOf(address(pooler)), 0, "Dispatcher USDS balance should go to 0");
    }

    function test_dispatch_doesNotCallAddLiquidity() public {
        uint256 amount = 1e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertFalse(mockVault.addLiquidityCalled(), "addLiquidity should NOT have been called after dispatch");
    }

    function test_dispatch_ignoresNonEmptyExtraData() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        // Passing extraData with a uint256 should not revert and should not affect behavior
        bytes memory extraData = abi.encode(uint256(999e18));

        vm.prank(minter);
        pooler.dispatch(minter, amount, extraData);

        // Dispatch should still just wrap USDS -> sUSDS
        assertEq(sUsds.balanceOf(address(pooler)), amount, "sUSDS balance should reflect wrap");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should be 0");
        assertFalse(mockVault.addLiquidityCalled(), "addLiquidity should NOT be called");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.dispatch(nonOwner, amount, "");
    }

    // =========================================================================
    // Hook integration tests
    // =========================================================================

    function test_dispatch_invokesHookAfterWrap() public {
        MockDispatchHook hook = new MockDispatchHook();
        pooler.setHook(IDispatchHook(address(hook)));

        uint256 amount = 100e18;
        bytes memory payload = hex"aabbcc";
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, payload);

        // Wrap happened
        assertEq(sUsds.balanceOf(address(pooler)), amount, "USDS should have been wrapped to sUSDS");
        // Hook was called exactly once with forwarded args
        assertEq(hook.callCount(), 1, "hook should be called once");
        assertEq(hook.lastMinter(), minter, "hook should receive minter");
        assertEq(hook.lastAmount(), amount, "hook should receive amount");
        assertEq(hook.lastExtraData(), payload, "hook should receive extraData verbatim");
    }

    function test_pool_doesNotInvokeHook() public {
        MockDispatchHook hook = new MockDispatchHook();
        pooler.setHook(IDispatchHook(address(hook)));

        // Seed sUSDS via dispatch (this consumes one hook invocation)
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        assertEq(hook.callCount(), 1, "dispatch should have invoked hook once");

        // Now pool — hook should NOT be invoked again
        vm.prank(authorizedPooler);
        pooler.pool(0);
        assertEq(hook.callCount(), 1, "pool() must not invoke the dispatch hook");
    }

    // =========================================================================
    // pool() function tests — authorized pooler
    // =========================================================================

    function test_pool_revertsWhenCalledByNonAuthorizedAddress() public {
        // Seed some sUSDS
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(nonOwner);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);
    }

    function test_pool_revertsWhenSUSDSBalanceIsZero() public {
        vm.prank(authorizedPooler);
        vm.expectRevert("BalancerPoolerV2: nothing to pool");
        pooler.pool(0);
    }

    function test_pool_endToEnd() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        // Dispatch to wrap USDS -> sUSDS
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(sUsds.balanceOf(address(pooler)), amount, "sUSDS should be on dispatcher before pool");
        assertFalse(mockVault.addLiquidityCalled(), "addLiquidity not called yet");

        // Pool the sUSDS
        vm.prank(authorizedPooler);
        vm.expectEmit(true, false, false, true);
        emit BalancerPoolerV2.Pooled(authorizedPooler, amount, amount, 0);
        pooler.pool(0);

        // Verify: vault received sUSDS, dispatcher received BPT, sUSDS drained
        assertEq(sUsds.balanceOf(address(mockVault)), amount, "Vault should have received sUSDS");
        assertEq(bptToken.balanceOf(address(pooler)), amount, "Dispatcher should hold BPT");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "sUSDS should be drained from dispatcher");
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_pool_respectsWhenNotPaused() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Pause the dispatcher
        vm.prank(minter);
        pooler.pause();

        // pool should revert even for authorized pooler
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pooler.pool(0);
    }

    function test_pool_slippageFloorEnforced() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Configure vault to return less BPT than minBPT
        mockVault.setConfigurableBptOut(50e18);

        vm.prank(authorizedPooler);
        vm.expectRevert("MockBalancerVault: unlock callback failed");
        pooler.pool(80e18); // minBPT = 80e18, but vault returns 50e18
    }

    function test_pool_sUSDSIsSecond_correctOrdering() public {
        // Create a pooler with sUSDSIsFirst=false
        BalancerPoolerV2 poolerReversed = new BalancerPoolerV2(
            address(sUsds), address(bptToken), address(mockVault), address(mockRouter), false, owner
        );
        poolerReversed.setMinter(minter);
        poolerReversed.setAuthorizedPooler(authorizedPooler, true);

        uint256 amount = 60e18;
        usds.mint(address(poolerReversed), amount);

        vm.prank(minter);
        poolerReversed.dispatch(minter, amount, "");

        vm.prank(authorizedPooler);
        poolerReversed.pool(0);

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 0, "maxAmountsIn[0] should be 0 when sUSDSIsFirst=false");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be sUSDS shares when sUSDSIsFirst=false");
    }

    function test_pool_multipleDispatchesAccumulateSUSDS_singlePoolDrains() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;

        usds.mint(address(pooler), amount1);
        vm.prank(minter);
        pooler.dispatch(minter, amount1, "");

        usds.mint(address(pooler), amount2);
        vm.prank(minter);
        pooler.dispatch(minter, amount2, "");

        // Total sUSDS = 125e18
        assertEq(sUsds.balanceOf(address(pooler)), 125e18, "sUSDS should accumulate");

        // Single pool drains all
        vm.prank(authorizedPooler);
        pooler.pool(0);

        assertEq(sUsds.balanceOf(address(pooler)), 0, "All sUSDS should be drained after pool");
        assertEq(bptToken.balanceOf(address(pooler)), 125e18, "BPT should reflect total pooled");
    }

    function test_pool_nonOneToOneRate_routesSharesNotAssets() public {
        // Set sUSDS rate to 5000 bps = 0.5 shares per asset
        sUsds.setRate(5000);

        uint256 usdsAmount = 100e18;
        usds.mint(address(pooler), usdsAmount);

        vm.prank(minter);
        pooler.dispatch(minter, usdsAmount, "");

        // At 5000 bps, 100e18 USDS -> 50e18 sUSDS shares
        uint256 expectedShares = 50e18;
        assertEq(sUsds.balanceOf(address(pooler)), expectedShares, "sUSDS should be shares not assets");

        vm.prank(authorizedPooler);
        pooler.pool(0);

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], expectedShares, "maxAmountsIn should use sUSDS shares, not USDS assets");
    }

    // =========================================================================
    // getIdealBPT tests
    // =========================================================================

    function test_getIdealBPT_returnsZeroWhenSUSDSBalanceIsZero() public {
        uint256 result = pooler.getIdealBPT();
        assertEq(result, 0, "getIdealBPT should return 0 when sUSDS balance is 0");
    }

    function test_getIdealBPT_returnsRouterBptOut() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        mockRouter.setConfigurableBptOut(95e18);

        uint256 result = pooler.getIdealBPT();
        assertEq(result, 95e18, "getIdealBPT should return the router's bptAmountOut");

        // Verify router received correct args
        assertTrue(mockRouter.queryCalled(), "Router query should have been called");
        assertEq(mockRouter.lastPool(), address(bptToken), "Router should receive pool address");
        assertEq(mockRouter.lastSender(), address(pooler), "Router should receive dispatcher address");

        uint256[] memory routerAmounts = mockRouter.getLastExactAmountsIn();
        assertEq(routerAmounts[0], amount, "exactAmountsIn[0] should be sUSDS amount when sUSDSIsFirst=true");
        assertEq(routerAmounts[1], 0, "exactAmountsIn[1] should be 0 when sUSDSIsFirst=true");
    }

    function test_getIdealBPT_isCallableByUnauthorizedAddresses() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        mockRouter.setConfigurableBptOut(90e18);

        // Call from an unauthorized address
        vm.prank(nonOwner);
        uint256 result = pooler.getIdealBPT();
        assertEq(result, 90e18, "getIdealBPT should be callable by anyone (ungated)");
    }

    function test_getIdealBPT_sUSDSIsSecond_correctOrdering() public {
        BalancerPoolerV2 poolerReversed = new BalancerPoolerV2(
            address(sUsds), address(bptToken), address(mockVault), address(mockRouter), false, owner
        );
        poolerReversed.setMinter(minter);

        uint256 amount = 80e18;
        usds.mint(address(poolerReversed), amount);
        vm.prank(minter);
        poolerReversed.dispatch(minter, amount, "");

        mockRouter.setConfigurableBptOut(75e18);

        uint256 result = poolerReversed.getIdealBPT();
        assertEq(result, 75e18, "getIdealBPT should return router value");

        uint256[] memory routerAmounts = mockRouter.getLastExactAmountsIn();
        assertEq(routerAmounts[0], 0, "exactAmountsIn[0] should be 0 when sUSDSIsFirst=false");
        assertEq(routerAmounts[1], amount, "exactAmountsIn[1] should be sUSDS amount when sUSDSIsFirst=false");
    }

    // =========================================================================
    // setAuthorizedPooler tests
    // =========================================================================

    function test_setAuthorizedPooler_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setAuthorizedPooler(address(0x1111), true);
    }

    function test_setAuthorizedPooler_revertsOnZeroAddress() public {
        vm.expectRevert("BalancerPoolerV2: zero pooler");
        pooler.setAuthorizedPooler(address(0), true);
    }

    function test_setAuthorizedPooler_authorizeSetsVersionAndEmits() public {
        address newPooler = address(0x2222);

        vm.expectEmit(true, false, false, true);
        emit BalancerPoolerV2.PoolerAuthorized(newPooler, 1);
        pooler.setAuthorizedPooler(newPooler, true);

        assertEq(pooler.poolerAuthVersion(newPooler), 1, "poolerAuthVersion should match current authVersion");
    }

    function test_setAuthorizedPooler_deauthorizeClearsAndEmits() public {
        address p = address(0x3333);
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 1, "Should be authorized");

        vm.expectEmit(true, false, false, false);
        emit BalancerPoolerV2.PoolerDeauthorized(p);
        pooler.setAuthorizedPooler(p, false);

        assertEq(pooler.poolerAuthVersion(p), 0, "poolerAuthVersion should be cleared");

        // Seed sUSDS and verify pool reverts
        uint256 amount = 10e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(p);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);
    }

    // =========================================================================
    // incrementAuthVersion tests
    // =========================================================================

    function test_incrementAuthVersion_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.incrementAuthVersion();
    }

    function test_incrementAuthVersion_massRevoke() public {
        address poolerA = address(0x4444);
        address poolerB = address(0x5555);
        pooler.setAuthorizedPooler(poolerA, true);
        pooler.setAuthorizedPooler(poolerB, true);

        // Seed sUSDS
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Increment auth version -> both should be revoked
        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.AuthVersionIncremented(2);
        pooler.incrementAuthVersion();

        assertEq(pooler.authVersion(), 2, "authVersion should be 2");

        vm.prank(poolerA);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);

        vm.prank(poolerB);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);

        // Re-authorize only poolerA
        pooler.setAuthorizedPooler(poolerA, true);
        assertEq(pooler.poolerAuthVersion(poolerA), 2, "poolerA should be at version 2");

        vm.prank(poolerA);
        pooler.pool(0);

        // poolerB still reverts
        // Need more sUSDS for another attempt
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(poolerB);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);
    }

    function test_staleAuthorizationBoundary() public {
        address p = address(0x6666);
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 1, "Authorized at version 1");

        // Increment to version 2
        pooler.incrementAuthVersion();
        assertEq(pooler.authVersion(), 2, "authVersion should be 2");

        // poolerAuthVersion[p] still reads 1 but pool() should revert
        assertEq(pooler.poolerAuthVersion(p), 1, "Stale: poolerAuthVersion still V");

        // Seed sUSDS
        uint256 amount = 10e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(p);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0);

        // Re-authorize -> should now work with version 2
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 2, "Re-authorized at version 2");

        vm.prank(p);
        pooler.pool(0);
    }

    // =========================================================================
    // authorized pooler does not leak into owner-only functions
    // =========================================================================

    function test_authorizedPoolerCannotCallOwnerFunctions() public {
        vm.startPrank(authorizedPooler);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.setAuthorizedPooler(address(0x9999), true);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.incrementAuthVersion();

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.withdrawBPT(authorizedPooler, 1e18);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", authorizedPooler));
        pooler.setPool(address(0x9999));

        // pause is onlyMinter, not onlyOwner
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.pause();

        vm.stopPrank();
    }

    // =========================================================================
    // H-02 regression test
    // =========================================================================

    function test_H02_regression_noAddLiquidityDuringMintPath() public {
        // Reproduce H-02 attack shape: dispatch is called via the mint path
        // with empty or low extraData. Assert no addLiquidity fires.
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        // Reset to ensure clean state
        mockVault.resetAddLiquidityCalled();

        // Scenario 1: empty extraData
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertFalse(
            mockVault.addLiquidityCalled(), "H-02: addLiquidity must NOT fire during dispatch (empty extraData)"
        );

        // Scenario 2: non-empty extraData (attacker-supplied low slippage)
        usds.mint(address(pooler), amount);
        mockVault.resetAddLiquidityCalled();

        vm.prank(minter);
        pooler.dispatch(minter, amount, abi.encode(uint256(0)));

        assertFalse(
            mockVault.addLiquidityCalled(), "H-02: addLiquidity must NOT fire during dispatch (extraData with 0 minBPT)"
        );

        // Verify sUSDS accumulated but no Balancer interaction occurred
        assertEq(sUsds.balanceOf(address(pooler)), 200e18, "sUSDS should accumulate from dispatches");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should all be wrapped");
    }

    // =========================================================================
    // unlockCallback tests
    // =========================================================================

    function test_unlockCallback_revertsIfCallerIsNotVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPoolerV2: caller is not vault");
        pooler.unlockCallback(abi.encode(address(0x1), uint256(100e18), uint256(0)));
    }

    // =========================================================================
    // settlement tests — sUSDS is settled after pool()
    // =========================================================================

    function test_pool_settlementTokenIsSUSDS() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(authorizedPooler);
        pooler.pool(0);

        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement");

        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(sUsds), "Settlement token should be sUSDS");
        assertEq(settledAmount0, amount, "Settlement amount should match sUSDS shares");
    }

    // =========================================================================
    // withdrawBPT tests
    // =========================================================================

    function test_withdrawBPT_transfersBptToRecipient() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(authorizedPooler);
        pooler.pool(0);

        uint256 poolerBpt = bptToken.balanceOf(address(pooler));
        assertTrue(poolerBpt > 0, "Pooler should have BPT");

        address recipient = address(0xDEAD);
        pooler.withdrawBPT(recipient, poolerBpt);

        assertEq(bptToken.balanceOf(recipient), poolerBpt, "Recipient should receive all BPT");
        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT after withdrawal");
    }

    function test_withdrawBPT_revertsWhenCalledByNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.withdrawBPT(nonOwner, 1e18);
    }

    // =========================================================================
    // rescueERC20 tests
    // =========================================================================

    function test_rescueERC20_transfersArbitraryToken() public {
        // Deploy a scratch token unrelated to the pooler's normal tokens
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 50e18;
        strayToken.mint(address(pooler), amount);

        address recipient = address(0xBBBB);
        pooler.rescueERC20(address(strayToken), recipient, amount);

        assertEq(strayToken.balanceOf(recipient), amount, "Recipient should receive rescued tokens");
        assertEq(strayToken.balanceOf(address(pooler)), 0, "Pooler should have 0 after rescue");
    }

    function test_rescueERC20_worksForSUsds() public {
        // Dispatch wraps USDS -> sUSDS, leaving sUSDS on the pooler
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256 sUsdsBalance = sUsds.balanceOf(address(pooler));
        assertTrue(sUsdsBalance > 0, "Pooler should hold sUSDS after dispatch");

        address recipient = address(0xCCCC);
        pooler.rescueERC20(address(sUsds), recipient, sUsdsBalance);

        assertEq(sUsds.balanceOf(recipient), sUsdsBalance, "Recipient should receive all sUSDS");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "Pooler sUSDS should be drained");
    }

    function test_rescueERC20_worksForBpt() public {
        // Pool to get BPT on the pooler, then rescue it
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(authorizedPooler);
        pooler.pool(0);

        uint256 poolerBpt = bptToken.balanceOf(address(pooler));
        assertTrue(poolerBpt > 0, "Pooler should have BPT after pooling");

        address recipient = address(0xDDDD);
        pooler.rescueERC20(address(bptToken), recipient, poolerBpt);

        assertEq(bptToken.balanceOf(recipient), poolerBpt, "Recipient should receive all BPT");
        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler BPT should be 0 after rescue");
    }

    function test_rescueERC20_revertsWhenCalledByNonOwner() public {
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 10e18);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.rescueERC20(address(strayToken), nonOwner, 10e18);
    }

    function test_rescueERC20_revertsWhenRecipientIsZero() public {
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 10e18);

        vm.expectRevert("BalancerPoolerV2: zero recipient");
        pooler.rescueERC20(address(strayToken), address(0), 10e18);
    }

    function test_rescueERC20_worksWhilePaused() public {
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 25e18;
        strayToken.mint(address(pooler), amount);

        // Pause the dispatcher (pause is called by minter)
        vm.prank(minter);
        pooler.pause();

        // rescueERC20 should still work — escape hatch, not pause-gated
        address recipient = address(0xEEEE);
        pooler.rescueERC20(address(strayToken), recipient, amount);

        assertEq(strayToken.balanceOf(recipient), amount, "Rescue should work while paused");
    }

    function test_rescueERC20_zeroAmountIsNoop() public {
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 10e18;
        strayToken.mint(address(pooler), amount);

        address recipient = address(0xFFFF);
        pooler.rescueERC20(address(strayToken), recipient, 0);

        assertEq(strayToken.balanceOf(recipient), 0, "Recipient balance should remain 0");
        assertEq(strayToken.balanceOf(address(pooler)), amount, "Pooler balance should be unchanged");
    }

    function test_rescueERC20_revertsOnInsufficientBalance() public {
        MockERC20 strayToken = new MockERC20("Stray", "STRAY", 18);
        strayToken.mint(address(pooler), 5e18);

        // Try to rescue more than the pooler holds
        vm.expectRevert();
        pooler.rescueERC20(address(strayToken), address(0xAAAA), 10e18);
    }

    // =========================================================================
    // BalancerPoolerMintDebtHook integration
    // =========================================================================

    event DebtAccrued(address indexed minter, uint256 dispatchedAmount, uint256 debtAdded, uint256 newTotalDebt);
    event DebtPulled(address indexed recipient, uint256 amount);

    function test_mintDebtHook_integration_accruesOnDispatch() public {
        // Wire a real BalancerPoolerMintDebtHook to the pooler.
        MockMintable phUSD = new MockMintable();
        BalancerPoolerMintDebtHook debtHook = new BalancerPoolerMintDebtHook(owner, address(pooler), address(phUSD));
        pooler.setHook(IDispatchHook(address(debtHook)));

        uint256 amount = 1000e18;
        uint256 expectedDebt = (amount * 50) / 100; // 500e18
        usds.mint(address(pooler), amount);

        // Expect the debt-accrued event from the hook.
        vm.expectEmit(true, false, false, true, address(debtHook));
        emit DebtAccrued(minter, amount, expectedDebt, expectedDebt);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Debt recorded on the hook.
        assertEq(debtHook.mintDebt(), expectedDebt, "hook mintDebt should equal 50% of dispatched amount");

        // Existing dispatcher invariants still hold: USDS wrapped into sUSDS, no BPT op.
        assertEq(sUsds.balanceOf(address(pooler)), amount, "sUSDS should reflect the full wrap");
        assertEq(usds.balanceOf(address(pooler)), 0, "USDS should be fully wrapped");
        assertFalse(mockVault.addLiquidityCalled(), "addLiquidity must not fire during dispatch");
    }

    function test_mintDebtHook_integration_pullMintsPhUSD() public {
        MockMintable phUSD = new MockMintable();
        BalancerPoolerMintDebtHook debtHook = new BalancerPoolerMintDebtHook(owner, address(pooler), address(phUSD));
        pooler.setHook(IDispatchHook(address(debtHook)));

        // Dispatch to accrue debt.
        uint256 amount = 500e18;
        uint256 expectedDebt = (amount * 50) / 100; // 250e18
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(debtHook.mintDebt(), expectedDebt, "debt accrued");

        // Set recipient and pull.
        address stakingModule = address(0xBADA55);
        debtHook.setRecipient(stakingModule);

        vm.expectEmit(true, false, false, true, address(debtHook));
        emit DebtPulled(stakingModule, expectedDebt);
        debtHook.pull();

        assertEq(debtHook.mintDebt(), 0, "debt cleared after pull");
        assertEq(phUSD.balanceOf(stakingModule), expectedDebt, "phUSD minted to staking module");
        assertEq(phUSD.mintCallCount(), 1, "exactly one mint call");
    }

    // =========================================================================
    // Story-034: PSM donation — config setters
    // =========================================================================

    /// @dev Story 047: the nudge sink can no longer be a plain EOA — `registerStream` calls
    ///      `isNudgeToken(token)` on it, so it must be a contract. `batchMinter` is assigned in
    ///      `_ensurePSM()` (invoked from `setUp`).
    address public batchMinter;
    MockNudgeBatchMinter public batchMinterMock;
    NudgeStreamer public streamer;
    MockERC20 public usdc;
    MockSkyPSM public psm;

    uint256 internal constant STREAM_DURATION = 1000;

    /// @dev Helper: seed sUSDS onto the pooler by minting USDS + dispatching.
    function _seedSUSDS(uint256 amount) internal {
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
    }

    /// @dev Deploy the USDC token + Sky PSM mock, fund the PSM reserve, and stand up the nudge
    ///      stack (batch-minter sink + streamer) in the documented ops order: whitelist the
    ///      nudge token on the sink FIRST, then `registerStream` (reversing the two reverts
    ///      `NudgeStreamer__NotWhitelisted`).
    function _ensurePSM() internal {
        if (address(usdc) == address(0)) {
            usdc = new MockERC20("USD Coin", "USDC", 6);
            // to18ConversionFactor = 1e12 (18 - 6 decimals), matching live USDC PSM.
            psm = new MockSkyPSM(address(usds), address(usdc), 1e12);
            // Fund the PSM's finite USDC reserve generously.
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

    /// @dev Wire donation config: batchMinter + PSM + size. Donation happens in _dispatch,
    ///      so this must be set BEFORE the dispatch that should donate. The streamer is
    ///      already wired in `setUp`.
    function _wireDonation(uint256 size) internal {
        _ensurePSM();
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(size);
    }

    /// @dev A pooler with no `nudgeStreamer` configured, otherwise identical to `pooler`.
    function _freshPooler() internal returns (BalancerPoolerV2 fresh) {
        fresh = new BalancerPoolerV2(
            address(sUsds), address(bptToken), address(mockVault), address(mockRouter), true, owner
        );
        fresh.setMinter(minter);
    }

    // Mirror contract events for vm.expectEmit.
    event BatchDonatedViaPSM(uint256 usdsSpent, uint256 usdcDonated, address indexed batchMinter);
    event DonationSkipped(uint256 usdsParked);

    /// @dev Scan recorded logs from `pooler` for a BatchDonatedViaPSM event and assert payload.
    ///      Used instead of vm.expectEmit because the PSM path emits intervening
    ///      Transfer/Approval logs that break strict next-event matching.
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

    /// @dev Scan recorded logs from `pooler` for a DonationSkipped(usdsParked) event.
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

    /// @dev Inverse of `_assertDonationSkipped`: proves the donation path completed cleanly
    ///      (or short-circuited) rather than being swallowed by the try/catch.
    function _assertNoDonationSkipped(Vm.Log[] memory logs) internal view {
        bytes32 sig = keccak256("DonationSkipped(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pooler) && logs[i].topics[0] == sig) {
                revert("DonationSkipped emitted but the donation was expected to be a clean no-op");
            }
        }
    }

    function test_setPSM_revertsOnZero() public {
        vm.expectRevert("BalancerPoolerV2: zero psm");
        pooler.setPSM(address(0));
    }

    function test_setPSM_storesAndEmits() public {
        _ensurePSM();
        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.PSMSet(address(psm));
        pooler.setPSM(address(psm));
        assertEq(pooler.psm(), address(psm));
    }

    function test_setPSM_revertsForNonOwner() public {
        _ensurePSM();
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setPSM(address(psm));
    }

    function test_maxTout_defaultsToOnePercent() public view {
        assertEq(pooler.maxTout(), 0.01e18, "maxTout default should be 1% WAD");
    }

    function test_setMaxTout_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.MaxToutSet(0.05e18);
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
        emit BalancerPoolerV2.BatchDonationSizeSet(0);
        pooler.setBatchDonationSize(0);
        assertEq(pooler.batchDonationSize(), 0);
    }

    function test_setBatchDonationSize_oneHundredAllowedAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.BatchDonationSizeSet(100);
        pooler.setBatchDonationSize(100);
        assertEq(pooler.batchDonationSize(), 100);
    }

    function test_setBatchDonationSize_revertsAbove100() public {
        vm.expectRevert("BalancerPoolerV2: size > 100");
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
        emit BalancerPoolerV2.BatchMinterSet(address(0));
        pooler.setBatchMinter(address(0));
        assertEq(pooler.batchMinter(), address(0));
    }

    function test_setBatchMinter_emitsEventWithNewAddress() public {
        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.BatchMinterSet(batchMinter);
        pooler.setBatchMinter(batchMinter);
        assertEq(pooler.batchMinter(), batchMinter);
    }

    function test_setBatchMinter_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setBatchMinter(batchMinter);
    }

    // =========================================================================
    // Story-047: setNudgeStreamer
    // =========================================================================

    function test_setNudgeStreamer_revertsOnZero() public {
        vm.expectRevert("BalancerPoolerV2: zero nudgeStreamer");
        pooler.setNudgeStreamer(address(0));
    }

    function test_setNudgeStreamer_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setNudgeStreamer(address(0xB0B));
    }

    function test_setNudgeStreamer_storesAndEmits() public {
        BalancerPoolerV2 fresh = _freshPooler();
        assertEq(fresh.nudgeStreamer(), address(0), "starts unset");

        vm.expectEmit(true, true, false, false);
        emit BalancerPoolerV2.NudgeStreamerUpdated(address(0), address(streamer));
        fresh.setNudgeStreamer(address(streamer));
        assertEq(fresh.nudgeStreamer(), address(streamer), "streamer stored");

        // Repointing reports the previous streamer as `oldStreamer`.
        vm.expectEmit(true, true, false, false);
        emit BalancerPoolerV2.NudgeStreamerUpdated(address(streamer), address(0xB0B));
        fresh.setNudgeStreamer(address(0xB0B));
        assertEq(fresh.nudgeStreamer(), address(0xB0B), "streamer repointed");
    }

    // =========================================================================
    // Story-034: _dispatch — donation disabled => full amount wrapped
    // =========================================================================

    function test_dispatch_noDonationConfig_wrapsFullAmount() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        // No donation config: full amount wrapped to sUSDS, no USDS parked.
        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped to sUSDS");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked");
    }

    function test_dispatch_donationSizeSetButBatchMinterUnset_wrapsFull() public {
        _ensurePSM();
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(30);
        // batchMinter still 0 => donation disabled.

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when batchMinter unset");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation");
    }

    function test_dispatch_donationSizeSetButPSMUnset_wrapsFull() public {
        _ensurePSM();
        pooler.setBatchMinter(batchMinter);
        pooler.setBatchDonationSize(30);
        // psm still 0 => donation disabled.

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when psm unset");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation");
    }

    function test_dispatch_donationSizeZero_wrapsFull() public {
        _ensurePSM();
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(psm));
        pooler.setBatchDonationSize(0);

        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        assertEq(sUsds.balanceOf(address(pooler)), amount, "full amount wrapped when size 0");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation at size 0");
    }

    // =========================================================================
    // Story-034: _dispatch — donation active (pooling wrap + PSM donation)
    // =========================================================================

    function test_dispatch_donation10Percent_splitsPoolingAndDonates() public {
        _wireDonation(10);

        uint256 amount = 1000e18; // 10% donation => 100e18 USDS -> 100e6 USDC (tout=0)
        _seedSUSDS(amount);

        // 90% wrapped to sUSDS (1:1 rate), donation share converted to USDC.
        assertEq(sUsds.balanceOf(address(pooler)), 900e18, "90% wrapped to sUSDS");
        assertEq(usdc.balanceOf(address(streamer)), 100e6, "10% donated as USDC at 1:1 (18->6 decimals)");
        assertEq(usdc.balanceOf(batchMinter), 0, "story 047: USDC buffers in the streamer, not the sink");
        assertEq(usdc.balanceOf(address(pooler)), 0, "pooler keeps no USDC");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS parked on success");
    }

    /// @dev Story 047: the PSM delivers to the POOLER, which streams it on. The batch-minter is
    ///      paid linearly out of the streamer's buffer, not in a lump on dispatch.
    function test_dispatch_donation_buffersInStreamerAndReleasesLinearly() public {
        _wireDonation(100);

        uint256 amount = 100e18; // 100% donation => 100e6 USDC
        _seedSUSDS(amount);

        (uint256 duration, uint256 buffer, uint256 rewardPerSecond,) = streamer.streams(batchMinter, address(usdc));
        assertEq(duration, STREAM_DURATION, "duration untouched by a deposit");
        assertEq(buffer, 100e6, "streamer buffers the whole donation");
        assertEq(rewardPerSecond, (100e6 * 1e18) / STREAM_DURATION, "rate recomputed over the full window");
        assertEq(usdc.balanceOf(batchMinter), 0, "nothing settled to the sink yet");

        // Half the window elapses -> half the donation is claimable, and a flush delivers it.
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        assertApproxEqAbs(streamer.pendingStream(batchMinter, address(usdc)), 50e6, 1, "half accrued");
        batchMinterMock.flush(address(streamer), address(usdc));
        assertApproxEqAbs(usdc.balanceOf(batchMinter), 50e6, 1, "flush delivers the accrued half");
    }

    /// @dev The approval handed to the streamer is the EXACT gemAmt and is fully consumed by
    ///      `collectNudge` in the same call — never an infinite approval, never a residual.
    function test_dispatch_donation_leavesNoResidualStreamerAllowance() public {
        _wireDonation(100);
        _seedSUSDS(100e18);

        assertEq(usdc.allowance(address(pooler), address(streamer)), 0, "streamer allowance fully consumed");
        assertEq(usds.allowance(address(pooler), address(psm)), 0, "PSM allowance tidied");
    }

    function test_dispatch_donationDecimals18to6_exact() public {
        // Guards the 1e12 off-by-factor: 1e18 USDS donation => exactly 1e6 USDC.
        _wireDonation(100); // donate the entire amount

        uint256 amount = 1e18;
        _seedSUSDS(amount);

        assertEq(usdc.balanceOf(address(streamer)), 1e6, "1e18 USDS -> 1e6 USDC exact");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "nothing wrapped at 100% donation");
    }

    function test_dispatch_donation_emitsBatchDonatedViaPSM() public {
        _wireDonation(50);

        uint256 amount = 200e18; // 50% => 100e18 USDS -> 100e6 USDC, tout=0 => usdsSpent=100e18
        vm.recordLogs();
        _seedSUSDS(amount);
        _assertBatchDonatedViaPSM(vm.getRecordedLogs(), 100e18, 100e6);
    }

    function test_dispatch_donation_toutFeeApplied() public {
        _wireDonation(100);
        psm.setTout(0.01e18); // 1% tout, exactly at default maxTout ceiling

        // amount = 101e18 USDS. gemAmt = floor(101e18 * 1e18 / (1e12 * 1.01e18))
        //        = floor(101e18 / (1.01e12)) = floor(100.0...e6) = 100e6 USDC.
        uint256 amount = 101e18;
        _seedSUSDS(amount);

        assertEq(usdc.balanceOf(address(streamer)), 100e6, "tout fee reduces USDC out (100e6 for 101e18 in)");
        // usdsSpent = 100e6 * 1e12 * 1.01 = 101e18 exactly; no dust this case.
        assertEq(usds.balanceOf(address(pooler)), 0, "exact spend leaves no USDS");
    }

    function test_dispatch_donation_floorsGemAndKeepsDust() public {
        _wireDonation(100);
        psm.setTout(0.01e18); // 1% tout

        // amount = 102e18. gemAmt = floor(102e18 / 1.01e12) = floor(100.990...e6) = 100990099 (6dp).
        uint256 amount = 102e18;
        uint256 expectedGem = (amount * 1e18) / (1e12 * (1e18 + 0.01e18));
        _seedSUSDS(amount);

        assertEq(usdc.balanceOf(address(streamer)), expectedGem, "USDC out is floored gemAmt");
        // usdsSpent = expectedGem * 1e12 * 1.01; dust = amount - usdsSpent stays parked.
        uint256 usdsSpent = expectedGem * 1e12 * (1e18 + 0.01e18) / 1e18;
        assertEq(usds.balanceOf(address(pooler)), amount - usdsSpent, "rounding dust stays on contract");
    }

    /// @dev Story 047: a gemAmt that floors to zero is now a CLEAN no-op behind the
    ///      `if (gemAmt > 0)` guard, not a caught revert. The guard is load-bearing — without
    ///      it the call would reach `collectNudge(…, 0)` and revert
    ///      `NudgeStreamer__ZeroAmount()`, which the catch would then swallow. The sub-unit
    ///      USDS dust simply stays put and is re-swept on the next dispatch.
    function test_dispatch_donationRoundsToZeroGem_isCleanNoOp() public {
        _wireDonation(100);
        // Tiny amount whose floored gemAmt is 0: amount < 1e12 USDS -> gemAmt floors to 0.
        uint256 amount = 1e11; // 0.0000001 USDS, < 1e12 conv -> gemAmt = 0
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, ""); // must NOT revert
        _assertNoDonationSkipped(vm.getRecordedLogs());

        assertEq(usdc.balanceOf(address(streamer)), 0, "no donation when gem floors to 0");
        assertEq(usdc.balanceOf(batchMinter), 0, "no donation when gem floors to 0");
        assertEq(usds.balanceOf(address(pooler)), amount, "sub-unit dust retained for the next sweep");
    }

    /// @dev The other zero case: donation fully enabled but there is no USDS to sweep. The
    ///      `remainingUSDS > 0` guard in `_dispatch` short-circuits before `_psmDonate`, so
    ///      nothing reverts, nothing is parked and no `DonationSkipped` is emitted.
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
        // _psmDonate is self-gated: only `address(this)` (via the try/catch) may call it.
        _wireDonation(50);
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPoolerV2: only self");
        pooler._psmDonate(100e18);
    }

    // =========================================================================
    // Story-034: silent failure (mint never reverts)
    // =========================================================================

    function test_dispatch_psmEmptyReserve_silentSkip_mintSucceeds() public {
        _ensurePSM();
        // Deploy a SECOND PSM with NO reserve so buyGem reverts on insufficient reserve.
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        uint256 amount = 1000e18; // donation share 200e18
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, ""); // must NOT revert
        _assertDonationSkipped(vm.getRecordedLogs(), 200e18);

        // Pooling portion still wrapped; donation USDS parked; no USDC moved.
        assertEq(sUsds.balanceOf(address(pooler)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(pooler)), 200e18, "donation USDS parked on contract");
        assertEq(usdc.balanceOf(address(streamer)), 0, "no USDC donated on PSM failure");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC donated on PSM failure");
    }

    function test_dispatch_toutAboveMaxTout_silentSkip_mintSucceeds() public {
        _wireDonation(20);
        psm.setTout(0.02e18); // 2% > default maxTout 1% => _psmDonate reverts (tout too high)

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

    // =========================================================================
    // Story-047: streamer misconfiguration is CAUGHT (the isolation contract holds)
    // =========================================================================

    /// @dev `nudgeStreamer` unset on a LIVE donation: `_psmDonate` reverts on our own require,
    ///      the envelope swallows it, the USDS parks and the mint still succeeds. Quiet by
    ///      design — the documented, accepted consequence of preserving failure isolation.
    function test_dispatch_streamerUnset_donationCaughtAndParked() public {
        _ensurePSM();
        BalancerPoolerV2 fresh = _freshPooler();
        fresh.setBatchMinter(batchMinter);
        fresh.setPSM(address(psm));
        fresh.setBatchDonationSize(20);
        assertEq(fresh.nudgeStreamer(), address(0), "streamer starts unset");

        uint256 amount = 1000e18;
        usds.mint(address(fresh), amount);

        vm.prank(minter);
        fresh.dispatch(minter, amount, ""); // must NOT revert

        assertEq(sUsds.balanceOf(address(fresh)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(fresh)), 200e18, "donation USDS parked when streamer unset");
        assertEq(usdc.balanceOf(address(streamer)), 0, "no USDC moved");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC moved");

        // Wiring the streamer and dispatching again drains the parked backlog.
        fresh.setNudgeStreamer(address(streamer));
        vm.prank(minter);
        fresh.dispatch(minter, 0, "");
        assertEq(usdc.balanceOf(address(streamer)), 200e6, "parked USDS recovered once wired");
        assertEq(usds.balanceOf(address(fresh)), 0, "backlog drained");
    }

    /// @dev Streamer wired but ops forgot `registerStream(batchMinter, USDC, duration)`:
    ///      `collectNudge` reverts `NudgeStreamer__NotRegistered()`, which is likewise caught.
    function test_dispatch_streamNotRegistered_donationCaughtAndParked() public {
        _wireDonation(20);
        NudgeStreamer unregistered = new NudgeStreamer(owner);
        pooler.setNudgeStreamer(address(unregistered));

        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);

        vm.recordLogs();
        vm.prank(minter);
        pooler.dispatch(minter, amount, ""); // must NOT revert
        _assertDonationSkipped(vm.getRecordedLogs(), 200e18);

        assertEq(sUsds.balanceOf(address(pooler)), 800e18, "pooling portion still wrapped");
        assertEq(usds.balanceOf(address(pooler)), 200e18, "donation USDS parked when stream unregistered");
        assertEq(usdc.balanceOf(address(unregistered)), 0, "no USDC reached the unregistered streamer");
        assertEq(usdc.balanceOf(batchMinter), 0, "no USDC reached the sink");
    }

    /// @dev A donation-disabled pooler must stay deployable AND dispatchable with no streamer
    ///      configured — the streamer requirement lives on the live-donation branch only.
    function test_dispatch_donationDisabled_needsNoStreamer() public {
        BalancerPoolerV2 fresh = _freshPooler();
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
        psm.setTout(0.02e18); // 2%

        // With default 1% ceiling, donation is skipped.
        uint256 amount = 1000e18;
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
        assertEq(usdc.balanceOf(address(streamer)), 0, "skipped at 1% ceiling");
        assertEq(usds.balanceOf(address(pooler)), amount, "parked at 1% ceiling");

        // Owner raises the ceiling; next dispatch sweeps the parked USDS and donates.
        pooler.setMaxTout(0.05e18);
        uint256 amount2 = 0; // no new mint; just trigger a sweep via a fresh dispatch
        // Need a dispatch to trigger; mint 0 not allowed to do nothing useful, so dispatch tiny.
        // Instead, dispatch another amount to re-sweep the parked balance too.
        usds.mint(address(pooler), amount2);
        vm.prank(minter);
        pooler.dispatch(minter, amount2, "");

        // The whole parked 1000e18 is now swept: gemAmt = floor(1000e18 / 1.02e12).
        uint256 expectedGem = (amount * 1e18) / (1e12 * (1e18 + 0.02e18));
        assertEq(usdc.balanceOf(address(streamer)), expectedGem, "donated after raising maxTout");
    }

    // =========================================================================
    // Story-034: stranded-USDS sweep on next dispatch
    // =========================================================================

    function test_dispatch_strandedUSDS_sweptOnNextDispatch() public {
        _ensurePSM();
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        // First dispatch: PSM empty => 200e18 USDS stranded.
        _seedSUSDS(1000e18);
        assertEq(usds.balanceOf(address(pooler)), 200e18, "first donation stranded");

        // Repoint to the healthy, funded PSM.
        pooler.setPSM(address(psm));

        // Second dispatch (500e18, 20% => 100e18 new donation). Sweep picks up the
        // stranded 200e18 + new 100e18 = 300e18 USDS -> 300e6 USDC.
        _seedSUSDS(500e18);

        assertEq(usdc.balanceOf(address(streamer)), 300e6, "stranded + new donation swept together");
        assertEq(usds.balanceOf(address(pooler)), 0, "no USDS left after healthy sweep");
        // sUSDS: 800e18 (first pooling) + 400e18 (second pooling) = 1200e18.
        assertEq(sUsds.balanceOf(address(pooler)), 1200e18, "pooling portions accumulated");
    }

    // =========================================================================
    // Story-034: donation is independent of pool() (pool() is a pure LP add)
    // =========================================================================

    function test_pool_pureLP_afterDonatingDispatch() public {
        _wireDonation(10);
        _seedSUSDS(1000e18); // 900e18 wrapped, 100e6 USDC donated

        vm.prank(authorizedPooler);
        vm.expectEmit(true, false, false, true);
        emit BalancerPoolerV2.Pooled(authorizedPooler, 900e18, 900e18, 0);
        pooler.pool(0);

        assertEq(sUsds.balanceOf(address(mockVault)), 900e18, "vault holds pooled sUSDS");
        assertEq(bptToken.balanceOf(address(pooler)), 900e18, "pooler holds BPT");
        assertFalse(mockVault.swapCalled(), "pool() must not call any swap (donation moved out)");
    }

    function test_pool_doesNotTouchParkedUSDS() public {
        _ensurePSM();
        MockSkyPSM emptyPsm = new MockSkyPSM(address(usds), address(usdc), 1e12);
        pooler.setBatchMinter(batchMinter);
        pooler.setPSM(address(emptyPsm));
        pooler.setBatchDonationSize(20);

        _seedSUSDS(1000e18); // 200e18 USDS parked, 800e18 sUSDS
        assertEq(usds.balanceOf(address(pooler)), 200e18, "USDS parked");

        // pool() reads balanceOf(sUSDS) only — parked raw USDS is never pooled.
        vm.prank(authorizedPooler);
        pooler.pool(0);

        assertEq(usds.balanceOf(address(pooler)), 200e18, "parked USDS untouched by pool()");
        assertEq(bptToken.balanceOf(address(pooler)), 800e18, "only sUSDS pooled");
    }
}
