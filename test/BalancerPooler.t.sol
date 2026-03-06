// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPooler} from "../src/dispatchers/BalancerPooler.sol";
import {IUnlockCallback} from "../src/interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../src/interfaces/balancer/BalancerTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockFOTToken} from "./mocks/MockFOTToken.sol";

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
    // Recorded addLiquidity call parameters
    AddLiquidityParams public lastParams;
    bool public addLiquidityCalled;

    // Track settlements
    struct Settlement {
        address token;
        uint256 amount;
    }

    Settlement[] public settlements;

    function unlock(bytes calldata data) external returns (bytes memory result) {
        // Call back to the sender (BalancerPooler) with the data
        result = IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function addLiquidity(AddLiquidityParams memory params)
        external
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData)
    {
        // Record the call parameters for test assertions
        lastParams.pool = params.pool;
        lastParams.to = params.to;
        lastParams.minBptAmountOut = params.minBptAmountOut;
        lastParams.kind = params.kind;
        lastParams.userData = params.userData;

        // Copy maxAmountsIn
        delete lastParams.maxAmountsIn;
        for (uint256 i = 0; i < params.maxAmountsIn.length; i++) {
            lastParams.maxAmountsIn.push(params.maxAmountsIn[i]);
        }

        addLiquidityCalled = true;

        // Simulate BPT minting: mint sum of maxAmountsIn as BPT to params.to
        uint256 totalIn;
        for (uint256 i = 0; i < params.maxAmountsIn.length; i++) {
            totalIn += params.maxAmountsIn[i];
        }
        // Revert if below minBptAmountOut (simulating Balancer behavior)
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

    // Helper functions for test assertions
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

contract BalancerPoolerTest is Test {
    BalancerPooler public pooler;
    MockERC20 public primeToken;
    MockBalancerVault public mockVault;
    MockERC20 public bptToken; // BPT token (pool address in Balancer V3)
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        primeToken = new MockERC20("Prime Token", "PRM", 18);
        bptToken = new MockERC20("Balancer Pool Token", "BPT", 18);
        mockVault = new MockBalancerVault();
        pooler = new BalancerPooler(
            address(primeToken),
            address(bptToken),
            address(mockVault),
            true, // primeTokenIsFirst
            owner
        );
        // Set the minter so dispatch() can be called via onlyMinter
        pooler.setMinter(minter);
    }

    // =========================================================================
    // primeToken tests
    // =========================================================================

    function test_primeToken_returnsCorrectAddress() public view {
        assertEq(pooler.primeToken(), address(primeToken));
    }

    // =========================================================================
    // vault() getter test
    // =========================================================================

    function test_vault_returnsCorrectAddress() public view {
        assertEq(pooler.vault(), address(mockVault));
    }

    // =========================================================================
    // dispatch tests - tokens already on pooler, donates always
    // =========================================================================

    function test_dispatch_alwaysDonates_noThresholdGating() public {
        uint256 amount = 1e18;
        // Tokens already on pooler (sent by minter's transferFrom)
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify addLiquidity was called (donation happened)
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called even for small amounts");
    }

    /// @notice Verifies that dispatch reverts when called by non-minter.
    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        // Non-minter cannot call dispatch
        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        pooler.dispatch(nonOwner, amount, "");
    }

    // =========================================================================
    // dispatch tests - no phUSD minted (single-sided join)
    // =========================================================================

    function test_dispatch_noPhUSDMinted_singleSidedJoin() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // maxAmountsIn should have primeToken amount and 0 for phUSD slot
        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        // primeTokenIsFirst = true, so amounts[0] = primeAmount, amounts[1] = 0
        assertEq(amounts[0], amount, "Prime amount should be 100e18");
        assertEq(amounts[1], 0, "phUSD slot should be 0 for single-sided join");
    }

    // =========================================================================
    // dispatch tests - token ordering
    // =========================================================================

    function test_dispatch_primeTokenIsFirst_correctOrdering() public {
        // Default setUp has primeTokenIsFirst = true
        uint256 amount = 75e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "maxAmountsIn[0] should be primeAmount when primeTokenIsFirst=true");
        assertEq(amounts[1], 0, "maxAmountsIn[1] should be 0 (phUSD slot) when primeTokenIsFirst=true");
    }

    function test_dispatch_primeTokenIsSecond_correctOrdering() public {
        // Create pooler with primeTokenIsFirst = false
        BalancerPooler poolerReversed = new BalancerPooler(
            address(primeToken),
            address(bptToken),
            address(mockVault),
            false, // primeTokenIsFirst = false
            owner
        );
        poolerReversed.setMinter(minter);

        uint256 amount = 60e18;
        primeToken.mint(address(poolerReversed), amount);

        vm.prank(minter);
        poolerReversed.dispatch(minter, amount, "");

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 0, "maxAmountsIn[0] should be 0 (phUSD slot) when primeTokenIsFirst=false");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be primeAmount when primeTokenIsFirst=false");
    }

    // =========================================================================
    // dispatch tests - donation via vault
    // =========================================================================

    function test_dispatch_addsUnbalancedLiquidityViaVault() public {
        uint256 amount = 100e18;
        // Tokens already on pooler
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify addLiquidity was called
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");

        // Verify UNBALANCED kind
        assertEq(
            uint256(mockVault.getLastParamsKind()),
            uint256(AddLiquidityKind.UNBALANCED),
            "addLiquidity should use UNBALANCED kind"
        );

        // Verify correct pool
        assertEq(mockVault.getLastParamsPool(), address(bptToken), "Should use the correct pool address");

        // Verify minBptAmountOut defaults to 0 with empty extraData
        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should be 0 with empty extraData");
    }

    // =========================================================================
    // unlockCallback tests
    // =========================================================================

    function test_unlockCallback_revertsIfCallerIsNotVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPooler: caller is not vault");
        pooler.unlockCallback(abi.encode(uint256(100e18), uint256(0)));
    }

    // =========================================================================
    // dispatch tests - settlement amounts match actual vault receipts
    // =========================================================================

    function test_dispatch_settlementAmountsMatchVaultReceipts() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Only primeToken settlement (no phUSD settlement)
        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement (prime only)");

        // First settlement: primeToken
        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(primeToken), "First settlement should be primeToken");
        assertEq(settledAmount0, amount, "Prime settlement amount should match transferred amount");
    }

    // =========================================================================
    // FOT token dispatch tests (tokens already on pooler, only callback transfer has FOT fee)
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_singleSidedJoin() public {
        // Create an FOT prime token (2% fee)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken), address(bptToken), address(vault2), true, owner
        );
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        // Should not revert
        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        // addLiquidity should have been called
        assertTrue(vault2.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_dispatch_FOTToken_settlementAmountsMatchActualVaultReceipts() public {
        // Create an FOT prime token (2% fee = 200 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken), address(bptToken), address(vault2), true, owner
        );
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        // Only ONE FOT fee now: pooler -> vault transfer (2% fee on 100e18)
        // actualPrimeInVault = 100e18 - (100e18 * 200 / 10000) = 100e18 - 2e18 = 98e18
        uint256 expectedPrimeInVault = 98e18;

        // Only 1 settlement (primeToken only, no phUSD)
        uint256 settlementsCount = vault2.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement (prime only)");

        (address settledToken0, uint256 settledAmount0) = vault2.getSettlement(0);
        assertEq(settledToken0, address(fotToken), "First settlement should be FOT primeToken");
        assertEq(
            settledAmount0,
            expectedPrimeInVault,
            "Prime settlement should match actual vault receipt after single FOT fee"
        );

        // maxAmountsIn should have prime amount and 0 for phUSD
        uint256[] memory amounts = vault2.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], expectedPrimeInVault, "maxAmountsIn[0] should be actualPrimeInVault");
        assertEq(amounts[1], 0, "maxAmountsIn[1] should be 0 (phUSD slot)");
    }

    function test_dispatch_FOTToken_noStuckTokensInPooler() public {
        // Create an FOT prime token (5% fee = 500 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 500);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken), address(bptToken), address(vault2), true, owner
        );
        fotPooler.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotPooler), amount);

        vm.prank(minter);
        fotPooler.dispatch(minter, amount, "");

        // No tokens should be stuck in the pooler
        assertEq(fotToken.balanceOf(address(fotPooler)), 0, "No FOT tokens should be stuck in pooler");
    }

    function test_dispatch_standardToken_stillWorksIdentically() public {
        // This tests that a standard (non-FOT) token still works correctly
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify standard behavior
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");

        // Vault should hold primeToken only (no phUSD)
        assertEq(primeToken.balanceOf(address(mockVault)), amount, "Vault should hold full primeToken amount");

        // Nothing stuck in pooler
        assertEq(primeToken.balanceOf(address(pooler)), 0, "No primeTokens should be stuck in pooler");

        // Only primeToken settlement
        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 1, "Should have 1 settlement (prime only)");

        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(primeToken));
        assertEq(settledAmount0, amount);
    }

    // =========================================================================
    // dispatch tests - extraData / slippage protection
    // =========================================================================

    function test_dispatch_withExtraData_setsMinBptAmountOut() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        // Encode a minBptAmountOut of 80e18 via extraData
        // (mock mints totalIn = 100e18 + 0 = 100e18, so 80e18 is valid)
        uint256 minBpt = 80e18;
        bytes memory extraData = abi.encode(minBpt);

        vm.prank(minter);
        pooler.dispatch(minter, amount, extraData);

        // Verify the mock vault received the correct minBptAmountOut
        assertEq(
            mockVault.getLastParamsMinBptAmountOut(), minBpt, "minBptAmountOut should match the encoded extraData value"
        );
    }

    function test_dispatch_withEmptyExtraData_defaultsMinBptToZero() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Verify the mock vault received 0 as minBptAmountOut
        assertEq(
            mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should default to 0 when extraData is empty"
        );
    }

    // =========================================================================
    // BPT token accumulation tests
    // =========================================================================

    function test_dispatch_bptTokensHeldByDispatcher() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        // Before dispatch, pooler has no BPT
        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT before dispatch");

        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Mock vault mints totalIn = primeAmount + 0 = 100e18 (single-sided)
        uint256 expectedBpt = 100e18;
        assertEq(bptToken.balanceOf(address(pooler)), expectedBpt, "Pooler should hold BPT tokens after dispatch");
    }

    function test_dispatch_multipleDispatchesAccumulateBPT() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 75e18;

        // First dispatch
        primeToken.mint(address(pooler), amount1);
        vm.prank(minter);
        pooler.dispatch(minter, amount1, "");

        uint256 bptAfterFirst = bptToken.balanceOf(address(pooler));
        // Mock mints totalIn = 50e18 + 0 = 50e18 (single-sided)
        assertEq(bptAfterFirst, 50e18, "BPT after first dispatch");

        // Second dispatch
        primeToken.mint(address(pooler), amount2);
        vm.prank(minter);
        pooler.dispatch(minter, amount2, "");

        uint256 bptAfterSecond = bptToken.balanceOf(address(pooler));
        // Mock mints totalIn = 75e18 + 0 = 75e18, accumulated with previous 50e18
        assertEq(bptAfterSecond, 125e18, "BPT should accumulate across multiple dispatches");
    }

    // =========================================================================
    // withdrawBPT tests
    // =========================================================================

    function test_withdrawBPT_transfersBptToRecipient() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        // Dispatch to accumulate BPT on pooler
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        uint256 poolerBpt = bptToken.balanceOf(address(pooler));
        assertTrue(poolerBpt > 0, "Pooler should have BPT");

        address recipient = address(0xDEAD);

        // Owner withdraws BPT
        pooler.withdrawBPT(recipient, poolerBpt);

        assertEq(bptToken.balanceOf(recipient), poolerBpt, "Recipient should receive all BPT");
        assertEq(bptToken.balanceOf(address(pooler)), 0, "Pooler should have 0 BPT after withdrawal");
    }

    function test_withdrawBPT_revertsWhenCalledByNonOwner() public {
        uint256 amount = 100e18;
        primeToken.mint(address(pooler), amount);

        // Dispatch to accumulate BPT on pooler
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        // Non-owner tries to withdraw
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        pooler.withdrawBPT(nonOwner, 1e18);
    }
}
