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
    MockERC20 public usds; // underlying prime token (USDS)
    MockERC4626 public sUsds; // ERC4626 wrapper (sUSDS)
    MockBalancerVault public mockVault;
    MockERC20 public bptToken;
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        usds = new MockERC20("USDS", "USDS", 18);
        sUsds = new MockERC4626("Savings USDS", "sUSDS", address(usds), 10000); // 1:1 rate
        bptToken = new MockERC20("Balancer Pool Token", "BPT", 18);
        mockVault = new MockBalancerVault();
        pooler = new BalancerPoolerV2(address(sUsds), address(bptToken), address(mockVault), true, owner);
        pooler.setMinter(minter);
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroSUSDS() public {
        vm.expectRevert("BalancerPoolerV2: zero sUSDS");
        new BalancerPoolerV2(address(0), address(bptToken), address(mockVault), true, owner);
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

    function test_setPool_poolIsUsedInSubsequentDispatch() public {
        // Create a new BPT token to use as the new pool
        MockERC20 newBptToken = new MockERC20("New BPT", "NBPT", 18);

        // Set new pool
        pooler.setPool(address(newBptToken));

        // Dispatch should use the new pool
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify the new pool was used
        assertEq(mockVault.getLastParamsPool(), address(newBptToken), "Dispatch should use the updated pool address");

        // New BPT tokens should be minted to pooler (by the mock vault)
        assertEq(newBptToken.balanceOf(address(pooler)), amount, "Pooler should hold new BPT tokens");
    }

    // =========================================================================
    // dispatch tests — USDS wrap to sUSDS flow
    // =========================================================================

    function test_dispatch_wrapsUSDSToSUSDSAndCallsAddLiquidity() public {
        uint256 amount = 1e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        pooler.dispatch(nonOwner, amount, "");
    }

    function test_dispatch_singleSidedJoin_sUSDSAmount() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // With 1:1 rate, sUSDS shares == USDS amount
        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "sUSDS amount should be 100e18 at 1:1 rate");
        assertEq(amounts[1], 0, "Second slot should be 0 for single-sided join");
    }

    function test_dispatch_sUSDSIsFirst_correctOrdering() public {
        uint256 amount = 75e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "maxAmountsIn[0] should be sUSDS shares when sUSDSIsFirst=true");
        assertEq(amounts[1], 0, "maxAmountsIn[1] should be 0 when sUSDSIsFirst=true");
    }

    function test_dispatch_sUSDSIsSecond_correctOrdering() public {
        BalancerPoolerV2 poolerReversed =
            new BalancerPoolerV2(address(sUsds), address(bptToken), address(mockVault), false, owner);
        poolerReversed.setMinter(minter);

        uint256 amount = 60e18;
        usds.mint(address(poolerReversed), amount);

        vm.prank(minter);
        poolerReversed.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 0, "maxAmountsIn[0] should be 0 when sUSDSIsFirst=false");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be sUSDS shares when sUSDSIsFirst=false");
    }

    function test_dispatch_addsUnbalancedLiquidityViaVault() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

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
    // settlement tests — sUSDS is settled, not USDS
    // =========================================================================

    function test_dispatch_settlementTokenIsSUSDS() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement");

        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(sUsds), "Settlement token should be sUSDS, not USDS");
        assertEq(settledAmount0, amount, "Settlement amount should match sUSDS shares (1:1 rate)");
    }

    // =========================================================================
    // Non-1:1 exchange rate tests
    // =========================================================================

    function test_dispatch_nonOneToOneRate_usesExactSharesFromDeposit() public {
        // Set sUSDS rate to 5000 bps = 0.5 shares per asset (sUSDS is worth more than USDS)
        sUsds.setRate(5000);

        uint256 usdsAmount = 100e18;
        usds.mint(address(pooler), usdsAmount);

        vm.prank(minter);
        pooler.dispatch(minter, usdsAmount, "");

        // At 5000 bps rate, 100e18 USDS -> 50e18 sUSDS shares
        uint256 expectedShares = 50e18;

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], expectedShares, "maxAmountsIn should use exact sUSDS shares from deposit, not USDS amount");
        assertEq(amounts[1], 0, "Second slot should be 0");

        // Settlement should also use sUSDS shares amount
        (address settledToken, uint256 settledAmount) = mockVault.getSettlement(0);
        assertEq(settledToken, address(sUsds), "Settlement token should be sUSDS");
        assertEq(settledAmount, expectedShares, "Settlement amount should be sUSDS shares, not USDS amount");
    }

    function test_dispatch_nonOneToOneRate_balancerVaultReceivesSUSDS() public {
        // 2:1 rate — 2 shares per asset
        sUsds.setRate(20000);

        uint256 usdsAmount = 50e18;
        usds.mint(address(pooler), usdsAmount);

        vm.prank(minter);
        pooler.dispatch(minter, usdsAmount, "");

        uint256 expectedShares = 100e18; // 50e18 * 20000 / 10000

        // sUSDS was transferred to mock vault
        uint256 vaultSUsdsBalance = sUsds.balanceOf(address(mockVault));
        assertEq(vaultSUsdsBalance, expectedShares, "Balancer vault should have received sUSDS shares");

        // USDS should NOT be in the vault
        uint256 vaultUsdsBalance = usds.balanceOf(address(mockVault));
        assertEq(vaultUsdsBalance, 0, "Balancer vault should NOT have received USDS");
    }

    // =========================================================================
    // extraData / slippage protection tests
    // =========================================================================

    function test_dispatch_withExtraData_setsMinBptAmountOut() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        uint256 minBpt = 80e18;
        bytes memory extraData = abi.encode(minBpt);

        vm.prank(minter);
        pooler.dispatch(minter, amount, extraData);

        assertEq(mockVault.getLastParamsMinBptAmountOut(), minBpt, "minBptAmountOut should match extraData value");
    }

    function test_dispatch_withEmptyExtraData_defaultsMinBptToZero() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should default to 0");
    }

    // =========================================================================
    // BPT token accumulation tests
    // =========================================================================

    function test_dispatch_bptTokensHeldByDispatcher() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT before dispatch");

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(bptToken.balanceOf(address(pooler)), 100e18, "Pooler should hold BPT tokens after dispatch");
    }

    function test_dispatch_multipleDispatchesAccumulateBPT() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;

        usds.mint(address(pooler), amount1);
        vm.prank(minter);
        pooler.dispatch(minter, amount1, "");
        assertEq(bptToken.balanceOf(address(pooler)), 50e18, "BPT after first dispatch");

        usds.mint(address(pooler), amount2);
        vm.prank(minter);
        pooler.dispatch(minter, amount2, "");
        assertEq(bptToken.balanceOf(address(pooler)), 125e18, "BPT should accumulate across multiple dispatches");
    }

    // =========================================================================
    // withdrawBPT tests
    // =========================================================================

    function test_withdrawBPT_transfersBptToRecipient() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

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
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.withdrawBPT(nonOwner, 1e18);
    }

    // =========================================================================
    // USDS stays out of Balancer vault — only sUSDS enters
    // =========================================================================

    function test_dispatch_noUSDSInBalancerVault() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(usds.balanceOf(address(mockVault)), 0, "USDS should NOT be sent to Balancer vault");
        assertEq(sUsds.balanceOf(address(mockVault)), amount, "sUSDS should be in Balancer vault");
    }

    // =========================================================================
    // No stuck tokens in pooler after dispatch
    // =========================================================================

    function test_dispatch_noStuckUSDSInPooler() public {
        uint256 amount = 100e18;
        usds.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertEq(usds.balanceOf(address(pooler)), 0, "No USDS should be stuck in pooler");
        assertEq(sUsds.balanceOf(address(pooler)), 0, "No sUSDS should be stuck in pooler");
    }
}
