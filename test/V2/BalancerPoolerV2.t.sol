// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPoolerV2} from "../../src/V2/dispatchers/BalancerPoolerV2.sol";
import {IUnlockCallback} from "../../src/interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../../src/interfaces/balancer/BalancerTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

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
    AddLiquidityParams public lastParams;
    bool public addLiquidityCalled;

    /// @dev Configurable BPT output. When > 0, overrides the default 1:1 behavior.
    uint256 public configurableBptOut;

    struct Settlement {
        address token;
        uint256 amount;
    }

    Settlement[] public settlements;

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

    function sendTo(IERC20, address, uint256) external pure {}

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
}
