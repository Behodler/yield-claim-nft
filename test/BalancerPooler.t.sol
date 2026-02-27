// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPooler} from "../src/dispatchers/BalancerPooler.sol";
import {IMintable} from "../src/interfaces/IMintable.sol";
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

/// @dev Mock ERC20 that implements IMintable (represents phUSD). Actually mints tokens.
contract MockMintableToken is ERC20, IMintable {
    uint8 private _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function mint(address recipient, uint256 amount) external override {
        _mint(recipient, amount);
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

        // Return dummy values
        amountsIn = params.maxAmountsIn;
        bptAmountOut = 0;
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
    MockMintableToken public phUSDToken;
    MockBalancerVault public mockVault;
    address public pool = address(0xA001);
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        primeToken = new MockERC20("Prime Token", "PRM", 18);
        phUSDToken = new MockMintableToken("phUSD", "phUSD", 18);
        mockVault = new MockBalancerVault();
        pooler = new BalancerPooler(
            address(primeToken),
            address(phUSDToken),
            pool,
            address(mockVault),
            true, // primeTokenIsFirst
            "Pool PRM/phUSD",
            owner
        );
    }

    // =========================================================================
    // primeToken tests
    // =========================================================================

    function test_primeToken_returnsCorrectAddress() public view {
        assertEq(pooler.primeToken(), address(primeToken));
    }

    // =========================================================================
    // flavour tests
    // =========================================================================

    function test_flavour_returnsCorrectString() public view {
        assertEq(pooler.flavour(), "Pool PRM/phUSD");
    }

    // =========================================================================
    // vault() getter test
    // =========================================================================

    function test_vault_returnsCorrectAddress() public view {
        assertEq(pooler.vault(), address(mockVault));
    }

    // =========================================================================
    // phUSD() getter test
    // =========================================================================

    function test_phUSD_returnsCorrectAddress() public view {
        assertEq(pooler.phUSD(), address(phUSDToken));
    }

    // =========================================================================
    // dispatch tests - always donates (no threshold gating)
    // =========================================================================

    function test_dispatch_alwaysDonates_noThresholdGating() public {
        uint256 amount = 1e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        // Verify addLiquidity was called (donation happened)
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called even for small amounts");
    }

    // =========================================================================
    // dispatch tests - mints phUSD
    // =========================================================================

    function test_dispatch_mintsPhUSD() public {
        uint256 amount = 100e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        // Before dispatch, phUSD totalSupply is 0
        assertEq(phUSDToken.totalSupply(), 0);

        pooler.dispatch(minter, amount);

        // phUSD was minted to pooler then transferred to vault during settlement
        // So vault should hold the phUSD now
        assertEq(phUSDToken.balanceOf(address(mockVault)), amount, "Vault should hold minted phUSD after settlement");
    }

    // =========================================================================
    // dispatch tests - decimal normalization (18-to-18)
    // =========================================================================

    function test_dispatch_sameDecimals_equalRawAmounts() public {
        // Both tokens are 18 decimals (setUp default)
        uint256 amount = 50e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        // With same decimals, phUSD amount should equal prime amount
        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        // primeTokenIsFirst = true, so amounts[0] = primeAmount, amounts[1] = phUSDAmount
        assertEq(amounts[0], amount, "Prime amount should be 50e18");
        assertEq(amounts[1], amount, "phUSD amount should equal prime amount for same decimals");
    }

    // =========================================================================
    // dispatch tests - decimal normalization (6-to-18)
    // =========================================================================

    function test_dispatch_6to18_normalizes() public {
        // Create 6-decimal prime token and 18-decimal phUSD
        MockERC20 primeToken6 = new MockERC20("USDC-like", "USDC", 6);
        MockMintableToken phUSD18 = new MockMintableToken("phUSD", "phUSD", 18);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler pooler6 = new BalancerPooler(
            address(primeToken6),
            address(phUSD18),
            pool,
            address(vault2),
            true,
            "Pool USDC/phUSD",
            owner
        );

        uint256 amount = 100e6; // 100 USDC (6 decimals)
        primeToken6.mint(minter, amount);

        vm.prank(minter);
        primeToken6.approve(address(pooler6), type(uint256).max);

        pooler6.dispatch(minter, amount);

        uint256[] memory amounts = vault2.getLastParamsMaxAmountsIn();
        // primeTokenIsFirst = true
        assertEq(amounts[0], 100e6, "Prime amount in prime decimals");
        assertEq(amounts[1], 100e18, "phUSD amount should be primeAmount * 10^12 for 6-to-18 normalization");
    }

    // =========================================================================
    // dispatch tests - donation amounts in respective decimals
    // =========================================================================

    function test_dispatch_donationAmountsInRespectiveDecimals() public {
        // Create 6-decimal prime token and 18-decimal phUSD
        MockERC20 primeToken6 = new MockERC20("USDC-like", "USDC", 6);
        MockMintableToken phUSD18 = new MockMintableToken("phUSD", "phUSD", 18);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler pooler6 = new BalancerPooler(
            address(primeToken6),
            address(phUSD18),
            pool,
            address(vault2),
            true,
            "Pool USDC/phUSD",
            owner
        );

        uint256 primeAmount = 50e6; // 50 USDC
        primeToken6.mint(minter, primeAmount);

        vm.prank(minter);
        primeToken6.approve(address(pooler6), type(uint256).max);

        pooler6.dispatch(minter, primeAmount);

        // Check that vault received correct amounts in their respective decimals
        assertEq(primeToken6.balanceOf(address(vault2)), 50e6, "Prime token donated in prime decimals (6)");
        assertEq(phUSD18.balanceOf(address(vault2)), 50e18, "phUSD donated in phUSD decimals (18)");
    }

    // =========================================================================
    // dispatch tests - token ordering
    // =========================================================================

    function test_dispatch_primeTokenIsFirst_correctOrdering() public {
        // Default setUp has primeTokenIsFirst = true
        uint256 amount = 75e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "maxAmountsIn[0] should be primeAmount when primeTokenIsFirst=true");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be phUSDAmount when primeTokenIsFirst=true");
    }

    function test_dispatch_primeTokenIsSecond_correctOrdering() public {
        // Create pooler with primeTokenIsFirst = false
        BalancerPooler poolerReversed = new BalancerPooler(
            address(primeToken),
            address(phUSDToken),
            pool,
            address(mockVault),
            false, // primeTokenIsFirst = false
            "Pool phUSD/PRM",
            owner
        );

        uint256 amount = 60e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(poolerReversed), type(uint256).max);

        poolerReversed.dispatch(minter, amount);

        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], amount, "maxAmountsIn[0] should be phUSDAmount when primeTokenIsFirst=false");
        assertEq(amounts[1], amount, "maxAmountsIn[1] should be primeAmount when primeTokenIsFirst=false");
    }

    // =========================================================================
    // dispatch tests - donation via vault
    // =========================================================================

    function test_dispatch_donatesViaVault() public {
        uint256 amount = 100e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        // Verify addLiquidity was called
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");

        // Verify DONATION kind
        assertEq(
            uint256(mockVault.getLastParamsKind()),
            uint256(AddLiquidityKind.DONATION),
            "addLiquidity should use DONATION kind"
        );

        // Verify correct pool
        assertEq(mockVault.getLastParamsPool(), pool, "Donation should use the correct pool address");

        // Verify minBptAmountOut is 0
        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should be 0 for donation");
    }

    // =========================================================================
    // unlockCallback tests
    // =========================================================================

    function test_unlockCallback_revertsIfCallerIsNotVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPooler: caller is not vault");
        pooler.unlockCallback(abi.encode(uint256(100e18)));
    }

    // =========================================================================
    // dispatch tests - settlement amounts match actual vault receipts
    // =========================================================================

    function test_dispatch_settlementAmountsMatchVaultReceipts() public {
        uint256 amount = 100e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        // Both settlements should match actual amounts
        uint256 settlementsCount = mockVault.getSettlementsCount();
        assertEq(settlementsCount, 2, "Should have 2 settlements (prime + phUSD)");

        // First settlement: primeToken
        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(primeToken), "First settlement should be primeToken");
        assertEq(settledAmount0, amount, "Prime settlement amount should match transferred amount");

        // Second settlement: phUSD
        (address settledToken1, uint256 settledAmount1) = mockVault.getSettlement(1);
        assertEq(settledToken1, address(phUSDToken), "Second settlement should be phUSD");
        assertEq(settledAmount1, amount, "phUSD settlement amount should match for same decimals");
    }

    // =========================================================================
    // FOT token dispatch tests
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_phUSDMintedInCallback() public {
        // Create an FOT prime token (2% fee)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken),
            address(phUSDToken),
            pool,
            address(vault2),
            true,
            "Pool FOT/phUSD",
            owner
        );

        uint256 amount = 100e18;
        fotToken.mint(minter, amount);

        vm.prank(minter);
        fotToken.approve(address(fotPooler), type(uint256).max);

        // Before dispatch, phUSD totalSupply is 0
        assertEq(phUSDToken.totalSupply(), 0);

        // Should not revert
        fotPooler.dispatch(minter, amount);

        // phUSD should have been minted (in callback)
        assertTrue(phUSDToken.totalSupply() > 0, "phUSD should have been minted in callback");

        // addLiquidity should have been called
        assertTrue(vault2.addLiquidityCalled(), "addLiquidity should have been called");
    }

    function test_dispatch_FOTToken_settlementAmountsMatchActualVaultReceipts() public {
        // Create an FOT prime token (2% fee = 200 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken),
            address(phUSDToken),
            pool,
            address(vault2),
            true,
            "Pool FOT/phUSD",
            owner
        );

        uint256 amount = 100e18;
        fotToken.mint(minter, amount);

        vm.prank(minter);
        fotToken.approve(address(fotPooler), type(uint256).max);

        fotPooler.dispatch(minter, amount);

        // First transfer: minter -> pooler (2% fee)
        // actualReceived by pooler = 100e18 - 2e18 = 98e18
        // Second transfer: pooler -> vault (2% fee on 98e18)
        // actualPrimeInVault = 98e18 - (98e18 * 200 / 10000) = 98e18 - 1.96e18 = 96.04e18
        uint256 expectedPrimeInVault = 9604e16; // 96.04e18

        // Check settlements
        (address settledToken0, uint256 settledAmount0) = vault2.getSettlement(0);
        assertEq(settledToken0, address(fotToken), "First settlement should be FOT primeToken");
        assertEq(settledAmount0, expectedPrimeInVault, "Prime settlement should match actual vault receipt after double FOT fee");

        (address settledToken1, uint256 settledAmount1) = vault2.getSettlement(1);
        assertEq(settledToken1, address(phUSDToken), "Second settlement should be phUSD");
        assertEq(settledAmount1, expectedPrimeInVault, "phUSD settlement should match normalized actualPrimeInVault");

        // maxAmountsIn should also match
        uint256[] memory amounts = vault2.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], expectedPrimeInVault, "maxAmountsIn[0] should be actualPrimeInVault");
        assertEq(amounts[1], expectedPrimeInVault, "maxAmountsIn[1] should be phUSDAmount matching actualPrimeInVault");
    }

    function test_dispatch_FOTToken_noStuckTokensInPooler() public {
        // Create an FOT prime token (5% fee = 500 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 500);
        MockBalancerVault vault2 = new MockBalancerVault();

        BalancerPooler fotPooler = new BalancerPooler(
            address(fotToken),
            address(phUSDToken),
            pool,
            address(vault2),
            true,
            "Pool FOT/phUSD",
            owner
        );

        uint256 amount = 100e18;
        fotToken.mint(minter, amount);

        vm.prank(minter);
        fotToken.approve(address(fotPooler), type(uint256).max);

        fotPooler.dispatch(minter, amount);

        // No tokens should be stuck in the pooler
        assertEq(fotToken.balanceOf(address(fotPooler)), 0, "No FOT tokens should be stuck in pooler");
        assertEq(phUSDToken.balanceOf(address(fotPooler)), 0, "No phUSD should be stuck in pooler");
    }

    function test_dispatch_standardToken_stillWorksIdentically() public {
        // This tests that a standard (non-FOT) token still works correctly after changes
        uint256 amount = 100e18;
        primeToken.mint(minter, amount);

        vm.prank(minter);
        primeToken.approve(address(pooler), type(uint256).max);

        pooler.dispatch(minter, amount);

        // Verify standard behavior
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");

        // Vault should hold both tokens
        assertEq(primeToken.balanceOf(address(mockVault)), amount, "Vault should hold full primeToken amount");
        assertEq(phUSDToken.balanceOf(address(mockVault)), amount, "Vault should hold matching phUSD amount");

        // Nothing stuck in pooler
        assertEq(primeToken.balanceOf(address(pooler)), 0, "No primeTokens should be stuck in pooler");
        assertEq(phUSDToken.balanceOf(address(pooler)), 0, "No phUSD should be stuck in pooler");

        // Settlements should match
        (address settledToken0, uint256 settledAmount0) = mockVault.getSettlement(0);
        assertEq(settledToken0, address(primeToken));
        assertEq(settledAmount0, amount);

        (address settledToken1, uint256 settledAmount1) = mockVault.getSettlement(1);
        assertEq(settledToken1, address(phUSDToken));
        assertEq(settledAmount1, amount);
    }
}
