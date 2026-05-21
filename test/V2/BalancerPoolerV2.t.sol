// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPoolerV2} from "../../src/V2/dispatchers/BalancerPoolerV2.sol";
import {IUnlockCallback} from "../../src/interfaces/balancer/IUnlockCallback.sol";
import {
    AddLiquidityParams,
    AddLiquidityKind,
    VaultSwapParams,
    SwapKind
} from "../../src/interfaces/balancer/BalancerTypes.sol";
import {IDispatchHook} from "../../src/V2/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "../mocks/MockDispatchHook.sol";
import {MockMintable} from "../mocks/MockMintable.sol";
import {BalancerPoolerMintDebtHook} from "../../src/V2/hooks/BalancerPoolerMintDebtHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";

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
        amountOutRaw = configurableSwapOut > 0
            ? configurableSwapOut
            : (params.amountGivenRaw * swapRateBps) / 10000;
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
        require(
            internalBalance[address(token)] >= amount,
            "MockBalancerVault: insufficient credit"
        );
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
        pooler.pool(0, 0);
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
        pooler.pool(0, 0);
    }

    function test_pool_revertsWhenSUSDSBalanceIsZero() public {
        vm.prank(authorizedPooler);
        vm.expectRevert("BalancerPoolerV2: nothing to pool");
        pooler.pool(0, 0);
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
        pooler.pool(0, 0);

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
        pooler.pool(0, 0);
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
        pooler.pool(80e18, 0); // minBPT = 80e18, but vault returns 50e18
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
        poolerReversed.pool(0, 0);

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
        pooler.pool(0, 0);

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
        pooler.pool(0, 0);

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
        pooler.pool(0, 0);
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
        pooler.pool(0, 0);

        vm.prank(poolerB);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0, 0);

        // Re-authorize only poolerA
        pooler.setAuthorizedPooler(poolerA, true);
        assertEq(pooler.poolerAuthVersion(poolerA), 2, "poolerA should be at version 2");

        vm.prank(poolerA);
        pooler.pool(0, 0);

        // poolerB still reverts
        // Need more sUSDS for another attempt
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(poolerB);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0, 0);
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
        pooler.pool(0, 0);

        // Re-authorize -> should now work with version 2
        pooler.setAuthorizedPooler(p, true);
        assertEq(pooler.poolerAuthVersion(p), 2, "Re-authorized at version 2");

        vm.prank(p);
        pooler.pool(0, 0);
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
            mockVault.addLiquidityCalled(),
            "H-02: addLiquidity must NOT fire during dispatch (empty extraData)"
        );

        // Scenario 2: non-empty extraData (attacker-supplied low slippage)
        usds.mint(address(pooler), amount);
        mockVault.resetAddLiquidityCalled();

        vm.prank(minter);
        pooler.dispatch(minter, amount, abi.encode(uint256(0)));

        assertFalse(
            mockVault.addLiquidityCalled(),
            "H-02: addLiquidity must NOT fire during dispatch (extraData with 0 minBPT)"
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
        pooler.unlockCallback(abi.encode(address(0x1), uint256(100e18), uint256(0), uint256(0)));
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
        pooler.pool(0, 0);

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
        pooler.pool(0, 0);

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
        pooler.pool(0, 0);

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
    // Story-031: Batch donation — setters
    // =========================================================================

    address public batchMinter = address(0xBA7C);
    MockERC20 public usdc;
    MockERC4626Wrapper public waUsdc;
    address public swapPool = address(0xB0011); // dummy swap pool address; mock vault ignores it

    /// @dev Helper: wire up donation config (mocks + setters) on `pooler`.
    function _wireDonation(uint256 size) internal {
        if (address(usdc) == address(0)) {
            usdc = new MockERC20("USD Coin", "USDC", 6);
            waUsdc = new MockERC4626Wrapper("Wrapped Aave USDC", "waUSDC", address(usdc), 6, 10000);
        }
        pooler.setBatchMinter(batchMinter);
        pooler.setSwapConfig(swapPool, address(waUsdc), address(usdc));
        pooler.setBatchDonationSize(size);
    }

    /// @dev Helper: seed the waUSDC wrapper with USDC liquidity so its `redeem` can pay out.
    function _fundWaUsdc(uint256 usdcAmount) internal {
        usdc.mint(address(waUsdc), usdcAmount);
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
        // First set non-zero, then zero — both must succeed.
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

    function test_setSwapConfig_revertsOnZeroSwapPool() public {
        vm.expectRevert("BalancerPoolerV2: zero swapPool");
        pooler.setSwapConfig(address(0), address(0xAA), address(0xBB));
    }

    function test_setSwapConfig_revertsOnZeroWaUsdc() public {
        vm.expectRevert("BalancerPoolerV2: zero waUsdc");
        pooler.setSwapConfig(address(0xAA), address(0), address(0xBB));
    }

    function test_setSwapConfig_revertsOnZeroUsdc() public {
        vm.expectRevert("BalancerPoolerV2: zero usdc");
        pooler.setSwapConfig(address(0xAA), address(0xBB), address(0));
    }

    function test_setSwapConfig_storesAllThreeAndEmits() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        waUsdc = new MockERC4626Wrapper("Wrapped Aave USDC", "waUSDC", address(usdc), 6, 10000);

        vm.expectEmit(false, false, false, true);
        emit BalancerPoolerV2.SwapConfigSet(swapPool, address(waUsdc), address(usdc));
        pooler.setSwapConfig(swapPool, address(waUsdc), address(usdc));

        assertEq(pooler.swapPool(), swapPool);
        assertEq(pooler.waUsdc(), address(waUsdc));
        assertEq(pooler.usdc(), address(usdc));
    }

    function test_setSwapConfig_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.setSwapConfig(address(0xAA), address(0xBB), address(0xCC));
    }

    // =========================================================================
    // Story-031: Batch donation — donation skipped (parity with old behaviour)
    // =========================================================================

    function _seedSUSDS(uint256 amount) internal {
        usds.mint(address(pooler), amount);
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");
    }

    function test_pool_defaultStateNoDonation_fullLP() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        // Full sUSDS amount went to LP; no swap occurred.
        assertEq(sUsds.balanceOf(address(mockVault)), amount, "Vault should hold full sUSDS");
        assertEq(bptToken.balanceOf(address(pooler)), amount, "Pooler should hold full BPT");
        assertFalse(mockVault.swapCalled(), "swap should NOT have been called");
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have fired");
    }

    function test_pool_donationSizeSetButBatchMinterUnset_skipsDonation() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        // Set size but leave batchMinter as 0 (and don't set swap config).
        pooler.setBatchDonationSize(30);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertFalse(mockVault.swapCalled(), "swap should NOT fire when batchMinter is unset");
        assertEq(bptToken.balanceOf(address(pooler)), amount, "All sUSDS should go to LP");
    }

    function test_pool_donationSizeSetButSwapPoolUnset_skipsDonation() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);

        // Set size + batchMinter, leave swap config unset (all zero).
        pooler.setBatchDonationSize(30);
        pooler.setBatchMinter(batchMinter);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertFalse(mockVault.swapCalled(), "swap should NOT fire when swap config is unset");
        assertEq(bptToken.balanceOf(address(pooler)), amount, "All sUSDS should go to LP");
    }

    function test_pool_donationRoundsToZero_skipsDonation() public {
        // batchDonationSize = 1, sUSDSAmount = 50 wei -> donationSUSDS = 0
        uint256 amount = 50;
        _seedSUSDS(amount);
        _wireDonation(1);

        // Confirm assumption: (50 * 1) / 100 == 0.
        assertEq((amount * 1) / 100, 0, "donationSUSDS should round to 0");

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertFalse(mockVault.swapCalled(), "swap should NOT fire when donationSUSDS rounds to 0");
        assertEq(bptToken.balanceOf(address(pooler)), amount, "Full amount should go to LP");
    }

    // =========================================================================
    // Story-031: Batch donation — donation active
    // =========================================================================

    function test_pool_donation30Percent_correctSplit() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(30);

        // Mock vault swap returns waUSDC at 6e-12 ratio (1e18 sUSDS -> 1e6 waUSDC).
        // At 30% donation: 300e18 sUSDS -> 300e6 waUSDC -> 300e6 USDC.
        mockVault.setConfigurableSwapOut(300e6);
        _fundWaUsdc(300e6);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        // Swap captured params
        assertTrue(mockVault.swapCalled(), "swap should fire");
        assertEq(uint256(mockVault.lastSwapKind()), uint256(SwapKind.EXACT_IN));
        assertEq(mockVault.lastSwapPool(), swapPool);
        assertEq(mockVault.lastSwapTokenIn(), address(sUsds));
        assertEq(mockVault.lastSwapTokenOut(), address(waUsdc));
        assertEq(mockVault.lastSwapAmountGivenRaw(), 300e18, "30% of 1000e18 sUSDS swapped");
        assertEq(mockVault.lastSwapLimitRaw(), 0, "limitRaw should be 0 (final check on USDC)");

        // USDC delivered to batchMinter
        assertEq(usdc.balanceOf(batchMinter), 300e6, "batchMinter should receive 300e6 USDC");

        // Remaining 700e18 sUSDS went to LP
        assertTrue(mockVault.addLiquidityCalled(), "LP add should still fire");
        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 700e18, "LP should receive 70% of sUSDS");
        assertEq(bptToken.balanceOf(address(pooler)), 700e18, "Pooler should hold 700e18 BPT");
    }

    function test_pool_donation100Percent_skipsLP() public {
        uint256 amount = 500e18;
        _seedSUSDS(amount);
        _wireDonation(100);

        mockVault.setConfigurableSwapOut(500e6);
        _fundWaUsdc(500e6);

        // No Pooled event should fire at 100% donation
        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertTrue(mockVault.swapCalled(), "swap should fire");
        assertFalse(mockVault.addLiquidityCalled(), "LP add MUST NOT fire at 100% donation");
        assertEq(usdc.balanceOf(batchMinter), 500e6, "batchMinter receives full USDC equivalent");
        assertEq(bptToken.balanceOf(address(pooler)), 0, "No BPT at 100% donation");
    }

    function test_pool_donation1Percent_correctMath() public {
        uint256 amount = 100_000e18;
        _seedSUSDS(amount);
        _wireDonation(1);

        uint256 expectedDonation = 1_000e18; // 1% of 100_000e18
        mockVault.setConfigurableSwapOut(1_000e6);
        _fundWaUsdc(1_000e6);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertEq(mockVault.lastSwapAmountGivenRaw(), expectedDonation, "1% should be 1000e18");
        assertEq(usdc.balanceOf(batchMinter), 1_000e6, "USDC delivered correctly");
        assertEq(bptToken.balanceOf(address(pooler)), 99_000e18, "99% goes to LP");
    }

    function test_pool_donation_slippageRevert_whenUsdcBelowMin() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(50);

        // Configure swap to return only 100e6 waUSDC; unwrap is 1:1 -> 100e6 USDC
        mockVault.setConfigurableSwapOut(100e6);
        _fundWaUsdc(100e6);

        // Demand 200e6 USDC minimum -> revert
        vm.prank(authorizedPooler);
        vm.expectRevert("MockBalancerVault: unlock callback failed");
        pooler.pool(0, 200e6);
    }

    function test_pool_donation_slippageAccepted_whenUsdcAtMin() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(50);

        // Swap returns exactly 250e6
        mockVault.setConfigurableSwapOut(250e6);
        _fundWaUsdc(250e6);

        vm.prank(authorizedPooler);
        pooler.pool(0, 250e6); // exactly at the minimum
        assertEq(usdc.balanceOf(batchMinter), 250e6, "USDC at min accepted");
    }

    function test_pool_donation_emitsBatchDonatedEvent() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(40);

        mockVault.setConfigurableSwapOut(400e6);
        _fundWaUsdc(400e6);

        vm.expectEmit(true, true, false, true);
        emit BalancerPoolerV2.BatchDonated(authorizedPooler, 400e18, 400e6, 400e6, batchMinter);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);
    }

    function test_pool_donation_pooledEventStillFires_whenDonationLessThan100() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(25);

        mockVault.setConfigurableSwapOut(250e6);
        _fundWaUsdc(250e6);

        vm.expectEmit(true, false, false, true);
        emit BalancerPoolerV2.Pooled(authorizedPooler, 750e18, 750e18, 0);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);
    }

    function test_pool_donation_unwrapAtNonOneToOne_appliesRate() public {
        // waUSDC redeems shares -> assets at 5000 bps (0.5 USDC per waUSDC share).
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(50);

        // Swap returns 500e6 waUSDC, unwrap rate 5000 bps -> 250e6 USDC.
        mockVault.setConfigurableSwapOut(500e6);
        waUsdc.setRate(5000);
        _fundWaUsdc(250e6);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        assertEq(usdc.balanceOf(batchMinter), 250e6, "Final USDC reflects unwrap rate");
    }

    function test_pool_donation_settlesSUSDSForBothPhases() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(30);

        mockVault.setConfigurableSwapOut(300e6);
        _fundWaUsdc(300e6);

        vm.prank(authorizedPooler);
        pooler.pool(0, 0);

        // Two settlements expected: donation (300e18) and LP (700e18).
        assertEq(mockVault.getSettlementsCount(), 2, "Two settlements (donation + LP)");
        (address t0, uint256 a0) = mockVault.getSettlement(0);
        (address t1, uint256 a1) = mockVault.getSettlement(1);
        assertEq(t0, address(sUsds));
        assertEq(a0, 300e18, "Donation settlement = 300e18");
        assertEq(t1, address(sUsds));
        assertEq(a1, 700e18, "LP settlement = 700e18");
    }

    function test_pool_donation_pauseBlocksPool() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(30);
        mockVault.setConfigurableSwapOut(300e6);
        _fundWaUsdc(300e6);

        vm.prank(minter);
        pooler.pause();

        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        pooler.pool(0, 0);

        assertFalse(mockVault.swapCalled(), "swap must not fire when paused");
        assertFalse(mockVault.addLiquidityCalled(), "LP must not fire when paused");
    }

    function test_pool_donation_revertsForNonAuthorizedPooler() public {
        uint256 amount = 1000e18;
        _seedSUSDS(amount);
        _wireDonation(30);
        mockVault.setConfigurableSwapOut(300e6);
        _fundWaUsdc(300e6);

        vm.prank(nonOwner);
        vm.expectRevert("BalancerPoolerV2: caller not authorized pooler");
        pooler.pool(0, 0);
    }

    // =========================================================================
    // Story-032: Regression guard — mock vault credits internal ledger, not
    //            the caller. Proves that `sendTo` is required to move tokenOut
    //            from the vault to the recipient. If a future contributor
    //            removes the production-side `sendTo` line, donation tests
    //            will fail because the dispatcher's real waUSDC balance is
    //            zero between `swap` and `sendTo`.
    // =========================================================================

    function test_mockVault_swapCreditsInternalLedger_sendToFlipsBalances() public {
        // Configure mock vault to return a deterministic swap output.
        usdc = new MockERC20("USD Coin", "USDC", 6);
        waUsdc = new MockERC4626Wrapper("Wrapped Aave USDC", "waUSDC", address(usdc), 6, 10000);
        uint256 waUsdcOut = 750e6;
        mockVault.setConfigurableSwapOut(waUsdcOut);

        // The "dispatcher" role in this test is `address(this)`. It would
        // normally transfer sUSDS to the vault before calling swap, but the
        // mock does not consume the input — only the output side is what we
        // care about here.
        VaultSwapParams memory swapParams = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: swapPool,
            tokenIn: IERC20(address(sUsds)),
            tokenOut: IERC20(address(waUsdc)),
            amountGivenRaw: 1000e18,
            limitRaw: 0,
            userData: ""
        });

        // 1. Swap: mock credits the internal ledger and mints shares to itself.
        (, , uint256 returnedOut) = mockVault.swap(swapParams);
        assertEq(returnedOut, waUsdcOut, "swap should return configured output amount");

        // 2. Settle the input side (no-op on the output ledger, just for parity
        //    with the real production flow).
        mockVault.settle(IERC20(address(sUsds)), 1000e18);

        // After swap+settle but BEFORE sendTo:
        //   - the recipient (this test contract) holds zero waUSDC
        //   - the mock vault holds the actual ERC20 waUSDC shares
        //   - the mock vault's internal ledger records the owed amount
        assertEq(
            waUsdc.balanceOf(address(this)),
            0,
            "recipient must not hold waUSDC before sendTo"
        );
        assertEq(
            waUsdc.balanceOf(address(mockVault)),
            waUsdcOut,
            "mock vault should hold the credited waUSDC shares"
        );
        assertEq(
            mockVault.internalBalance(address(waUsdc)),
            waUsdcOut,
            "mock vault internalBalance[waUsdc] should match credited amount"
        );

        // 3. sendTo: debits the ledger and transfers the ERC20 to the recipient.
        mockVault.sendTo(IERC20(address(waUsdc)), address(this), waUsdcOut);

        // After sendTo:
        //   - the recipient now holds the waUSDC shares
        //   - the mock vault no longer holds them
        //   - the internal ledger is back to zero
        assertEq(
            waUsdc.balanceOf(address(this)),
            waUsdcOut,
            "recipient should hold waUSDC after sendTo"
        );
        assertEq(
            waUsdc.balanceOf(address(mockVault)),
            0,
            "mock vault should no longer hold waUSDC after sendTo"
        );
        assertEq(
            mockVault.internalBalance(address(waUsdc)),
            0,
            "mock vault internalBalance[waUsdc] should be drained after sendTo"
        );
    }
}
