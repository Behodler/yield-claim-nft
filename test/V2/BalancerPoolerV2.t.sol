// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPoolerV2} from "../../src/V2/dispatchers/BalancerPoolerV2.sol";
import {IUnlockCallback} from "../../src/interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../../src/interfaces/balancer/BalancerTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFOTToken} from "../mocks/MockFOTToken.sol";

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
        require(totalIn >= params.minBptAmountOut, "BPT_OUT_MIN_AMOUNT");
        MockERC20(params.pool).mint(params.to, totalIn);

        amountsIn = params.maxAmountsIn;
        bptAmountOut = totalIn;
        returnData = "";
    }

    function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit) {
        settlements.push(Settlement({token: address(token), amount: amountHint}));
        return amountHint;
    }

    function sendTo(IERC20, address, uint256) external pure {}

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

contract BalancerPoolerV2Test is Test {
    BalancerPoolerV2 public pooler;
    MockERC20 public primeToken;
    MockBalancerVault public mockVault;
    MockERC20 public bptToken;
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        primeToken = new MockERC20("Prime Token", "PRM", 18);
        bptToken = new MockERC20("Balancer Pool Token", "BPT", 18);
        mockVault = new MockBalancerVault();
        pooler = new BalancerPoolerV2(address(primeToken), address(bptToken), address(mockVault), true, owner);
        pooler.setMinter(minter);
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

    function test_setPool_poolIsUsedInSubsequentDispatch() public {
        // Create a new BPT token to use as the new pool
        MockERC20 newBptToken = new MockERC20("New BPT", "NBPT", 18);

        // Set new pool
        pooler.setPool(address(newBptToken));

        // Dispatch should use the new pool
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify the new pool was used
        assertEq(mockVault.getLastParamsPool(), address(newBptToken), "Dispatch should use the updated pool address");

        // New BPT tokens should be minted to pooler (by the mock vault)
        assertEq(newBptToken.balanceOf(address(pooler)), amount, "Pooler should hold new BPT tokens");
    }

    // =========================================================================
    // dispatch tests
    // =========================================================================

    function test_dispatch_alwaysDonates() public {
        uint256 amount = 1e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.dispatch(nonOwner, amount, "");
    }

    function test_dispatch_singleSidedJoin() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "Prime amount should be 100e18");
        assertEq(amounts[1], 0, "Second slot should be 0 for single-sided join");
    }

    function test_dispatch_primeTokenIsFirst_correctOrdering() public {
        uint256 amount = 75e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "maxAmountsIn[0] should be primeAmount when primeTokenIsFirst=true");
        assertEq(amounts[1], 0, "maxAmountsIn[1] should be 0 when primeTokenIsFirst=true");
    }

    function test_dispatch_primeTokenIsSecond_correctOrdering() public {
        BalancerPoolerV2 poolerReversed =
            new BalancerPoolerV2(address(primeToken), address(bptToken), address(mockVault), false, owner);
        poolerReversed.setMinter(minter);

        uint256 amount = 60e18;
        primeToken.mint(address(poolerReversed), amount);

        vm.prank(minter);
        poolerReversed.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 0, "maxAmountsIn[0] should be 0 when primeTokenIsFirst=false");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be primeAmount when primeTokenIsFirst=false");
    }

    function test_dispatch_addsUnbalancedLiquidityViaVault() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");
        assertEq(
            uint256(mockVault.getLastParamsKind()),
            uint256(AddLiquidityKind.UNBALANCED),
            "addLiquidity should use UNBALANCED kind"
        );
        assertEq(mockVault.getLastParamsPool(), address(bptToken), "Should use the correct pool address");
        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should be 0 with empty extraData");
    }

    // =========================================================================
    // unlockCallback tests
    // =========================================================================

    function test_unlockCallback_revertsIfCallerIsNotVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPoolerV2: caller is not vault");
        pooler.unlockCallback(abi.encode(uint256(100e18), uint256(0)));
    }

    // =========================================================================
    // settlement tests
    // =========================================================================

    function test_dispatch_settlementAmountsMatchVaultReceipts() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement");

        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(primeToken), "Settlement should be primeToken");
        assertEq(settledAmount0, amount, "Settlement amount should match transferred amount");
    }

    // =========================================================================
    // FOT token dispatch tests
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_singleSidedJoin() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPoolerV2 fotPooler =
            new BalancerPoolerV2(address(fotToken), address(bptToken), address(vault2), true, owner);
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        assertTrue(vault2.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_dispatch_FOTToken_settlementAmountsMatchActualVaultReceipts() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPoolerV2 fotPooler =
            new BalancerPoolerV2(address(fotToken), address(bptToken), address(vault2), true, owner);
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        uint256 expectedPrimeInVault = 98e18;

        uint256 settlementsCount = vault2.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement");

        (address settledToken0, uint256 settledAmount0) = vault2.getSettlement(0);
        assertEq(settledToken0, address(fotToken), "Settlement should be FOT primeToken");
        assertEq(settledAmount0, expectedPrimeInVault, "Settlement should match actual vault receipt after FOT fee");

        uint256[] memory amounts = vault2.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], expectedPrimeInVault, "maxAmountsIn[0] should be actualPrimeInVault");
        assertEq(amounts[1], 0, "maxAmountsIn[1] should be 0");
    }

    function test_dispatch_FOTToken_noStuckTokensInPooler() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 500);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPoolerV2 fotPooler =
            new BalancerPoolerV2(address(fotToken), address(bptToken), address(vault2), true, owner);
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        assertEq(fotToken.balanceOf(address(fotPooler)), 0, "No FOT tokens should be stuck in pooler");
    }

    // =========================================================================
    // extraData / slippage protection tests
    // =========================================================================

    function test_dispatch_withExtraData_setsMinBptAmountOut() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        uint256 minBpt = 80e18;
        bytes memory extraData = abi.encode(minBpt);

        vm.prank(minter);
        pooler.dispatch(minter, amount, extraData);

        assertEq(mockVault.getLastParamsMinBptAmountOut(), minBpt, "minBptAmountOut should match extraData value");
    }

    function test_dispatch_withEmptyExtraData_defaultsMinBptToZero() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should default to 0");
    }

    // =========================================================================
    // BPT token accumulation tests
    // =========================================================================

    function test_dispatch_bptTokensHeldByDispatcher() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT before dispatch");

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(bptToken.balanceOf(address(pooler)), 100e18, "Pooler should hold BPT tokens after dispatch");
    }

    function test_dispatch_multipleDispatchesAccumulateBPT() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;

        primeToken.mint(address(pooler), amount1);
        vm.prank(minter);
        pooler.dispatch(minter, amount1, "");
        assertEq(bptToken.balanceOf(address(pooler)), 50e18, "BPT after first dispatch");

        primeToken.mint(address(pooler), amount2);
        vm.prank(minter);
        pooler.dispatch(minter, amount2, "");
        assertEq(bptToken.balanceOf(address(pooler)), 125e18, "BPT should accumulate across multiple dispatches");
    }

    // =========================================================================
    // withdrawBPT tests
    // =========================================================================

    function test_withdrawBPT_transfersBptToRecipient() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256 poolerBpt = bptToken.balanceOf(address(pooler));
        assertTrue(poolerBpt > 0, "Pooler should have BPT");

        address recipient = address(0xDEAD);
        pooler.withdrawBPT(recipient, poolerBpt);

        assertEq(bptToken.balanceOf(recipient), poolerBpt, "Recipient should receive all BPT");
        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT after withdrawal");
    }

    function test_withdrawBPT_revertsWhenCalledByNonOwner() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.withdrawBPT(nonOwner, 1e18);
    }
}
