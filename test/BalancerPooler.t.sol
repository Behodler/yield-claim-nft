// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPooler} from "../src/dispatchers/BalancerPooler.sol";
import {ITokenDispatcher} from "../src/interfaces/ITokenDispatcher.sol";
import {IUnlockCallback} from "../src/interfaces/balancer/IUnlockCallback.sol";
import {IBalancerVault} from "../src/interfaces/balancer/IBalancerVault.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../src/interfaces/balancer/BalancerTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
    MockERC20 public matchingToken;
    MockBalancerVault public mockVault;
    address public pool = address(0xA001);
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        primeToken = new MockERC20("Prime Token", "PRM");
        matchingToken = new MockERC20("Matching Token", "MTH");
        mockVault = new MockBalancerVault();
        pooler = new BalancerPooler(
            address(primeToken),
            address(matchingToken),
            pool,
            address(mockVault),
            true, // primeTokenIsFirst
            "Pool PRM/MTH",
            owner
        );
    }

    // =========================================================================
    // Threshold configuration tests
    // =========================================================================

    function test_setPrimeTokenThreshold_ownerCanSet() public {
        pooler.setPrimeTokenThreshold(100e18);
        assertEq(pooler.primeTokenThreshold(), 100e18);
    }

    function test_setMatchingTokenThreshold_ownerCanSet() public {
        pooler.setMatchingTokenThreshold(200e18);
        assertEq(pooler.matchingTokenThreshold(), 200e18);
    }

    function test_setPrimeTokenThreshold_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        pooler.setPrimeTokenThreshold(100e18);
    }

    function test_setMatchingTokenThreshold_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        pooler.setMatchingTokenThreshold(200e18);
    }

    function test_setThresholds_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BalancerPooler.ThresholdsUpdated(100e18, 0);
        pooler.setPrimeTokenThreshold(100e18);

        vm.expectEmit(false, false, false, true);
        emit BalancerPooler.ThresholdsUpdated(100e18, 200e18);
        pooler.setMatchingTokenThreshold(200e18);
    }

    // =========================================================================
    // tokensToApprove tests
    // =========================================================================

    function test_tokensToApprove_returnsMatchingToken() public view {
        address[] memory tokens = pooler.tokensToApprove();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(matchingToken));
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
        assertEq(pooler.flavour(), "Pool PRM/MTH");
    }

    // =========================================================================
    // vault() getter test
    // =========================================================================

    function test_vault_returnsCorrectAddress() public view {
        assertEq(pooler.vault(), address(mockVault));
    }

    // =========================================================================
    // dispatch tests - thresholds NOT met
    // =========================================================================

    function test_dispatch_bothThresholdsNotMet_noTransfers() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        // Give minter some tokens but below thresholds
        primeToken.mint(minter, 50e18);
        matchingToken.mint(minter, 50e18);

        // Approve pooler to pull from minter
        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        // Dispatch - should do nothing since thresholds not met
        pooler.dispatch(minter, 10e18);

        // Balances should be unchanged
        assertEq(primeToken.balanceOf(minter), 50e18);
        assertEq(matchingToken.balanceOf(minter), 50e18);
        assertEq(primeToken.balanceOf(address(pooler)), 0);
        assertEq(matchingToken.balanceOf(address(pooler)), 0);
    }

    function test_dispatch_primeThresholdMetButMatchingNot_noTransfers() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        // Prime meets threshold, matching does not
        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 50e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // No transfers should occur
        assertEq(primeToken.balanceOf(minter), 100e18);
        assertEq(matchingToken.balanceOf(minter), 50e18);
        assertEq(primeToken.balanceOf(address(pooler)), 0);
        assertEq(matchingToken.balanceOf(address(pooler)), 0);
    }

    // =========================================================================
    // dispatch tests - both thresholds met: 1:1 ratio transfers
    // =========================================================================

    function test_dispatch_bothThresholdsMet_transfersTokens() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        // Both meet thresholds, prime < matching
        primeToken.mint(minter, 150e18);
        matchingToken.mint(minter, 200e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // 1:1 ratio: donateAmount = min(150, 200) = 150
        // Prime: 150 donated, 0 remaining in minter
        // Matching: 150 donated, 50 remaining in minter
        // Tokens end up in vault after settle
        assertEq(primeToken.balanceOf(minter), 0, "All prime transferred (was the min)");
        assertEq(matchingToken.balanceOf(minter), 50e18, "Surplus matching stays in minter");
        assertEq(primeToken.balanceOf(address(mockVault)), 150e18, "Prime tokens settled in vault");
        assertEq(matchingToken.balanceOf(address(mockVault)), 150e18, "Matching tokens settled in vault");
    }

    // =========================================================================
    // dispatch tests - donation via vault
    // =========================================================================

    /// @notice Verifies that dispatch triggers the vault unlock flow and calls addLiquidity with DONATION kind.
    function test_dispatch_donatesViaVault() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // Verify addLiquidity was called
        assertTrue(mockVault.addLiquidityCalled(), "addLiquidity should have been called");

        // Verify DONATION kind
        assertEq(
            uint256(mockVault.getLastParamsKind()),
            uint256(AddLiquidityKind.DONATION),
            "addLiquidity should use DONATION kind"
        );
    }

    /// @notice Verifies that donation uses the correct pool address.
    function test_dispatch_donationUsesCorrectPool() public {
        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        assertEq(mockVault.getLastParamsPool(), pool, "Donation should use the correct pool address");
    }

    /// @notice Verifies donation sets minBptAmountOut to 0.
    function test_dispatch_donationSetsMinBptAmountOutToZero() public {
        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        assertEq(mockVault.getLastParamsMinBptAmountOut(), 0, "minBptAmountOut should be 0 for donation");
    }

    // =========================================================================
    // dispatch tests - 1:1 ratio behavior
    // =========================================================================

    /// @notice When primeBalance > matchingBalance, donateAmount equals matchingBalance
    ///         and surplus prime stays in minter.
    function test_dispatch_primeGreaterThanMatching_surplusPrimeStaysInMinter() public {
        primeToken.mint(minter, 200e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // donateAmount = min(200, 100) = 100
        assertEq(primeToken.balanceOf(minter), 100e18, "Surplus prime should stay in minter");
        assertEq(matchingToken.balanceOf(minter), 0, "All matching should be donated");
        // Tokens end up in vault
        assertEq(primeToken.balanceOf(address(mockVault)), 100e18, "100 prime donated to vault");
        assertEq(matchingToken.balanceOf(address(mockVault)), 100e18, "100 matching donated to vault");

        // Verify addLiquidity amounts
        uint256[] memory amounts = mockVault.getLastParamsMaxAmountsIn();
        assertEq(amounts[0], 100e18, "maxAmountsIn[0] should be donateAmount");
        assertEq(amounts[1], 100e18, "maxAmountsIn[1] should be donateAmount");
    }

    /// @notice When matchingBalance > primeBalance, donateAmount equals primeBalance
    ///         and surplus matching stays in minter.
    function test_dispatch_matchingGreaterThanPrime_surplusMatchingStaysInMinter() public {
        primeToken.mint(minter, 80e18);
        matchingToken.mint(minter, 150e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // donateAmount = min(80, 150) = 80
        assertEq(primeToken.balanceOf(minter), 0, "All prime should be donated");
        assertEq(matchingToken.balanceOf(minter), 70e18, "Surplus matching should stay in minter");
        // Tokens end up in vault
        assertEq(primeToken.balanceOf(address(mockVault)), 80e18, "80 prime donated to vault");
        assertEq(matchingToken.balanceOf(address(mockVault)), 80e18, "80 matching donated to vault");
    }

    /// @notice When balances are equal, both fully donated with nothing remaining in minter.
    function test_dispatch_equalBalances_bothFullyDonated() public {
        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // donateAmount = min(100, 100) = 100
        assertEq(primeToken.balanceOf(minter), 0, "No prime should remain in minter");
        assertEq(matchingToken.balanceOf(minter), 0, "No matching should remain in minter");
        // Tokens end up in vault
        assertEq(primeToken.balanceOf(address(mockVault)), 100e18, "100 prime donated to vault");
        assertEq(matchingToken.balanceOf(address(mockVault)), 100e18, "100 matching donated to vault");
    }

    // =========================================================================
    // dispatch tests - zero thresholds (always transfers)
    // =========================================================================

    function test_dispatch_zeroThresholds_alwaysTransfers() public {
        // Default thresholds are 0, so any balance >= 0 triggers transfer
        primeToken.mint(minter, 10e18);
        matchingToken.mint(minter, 5e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // 1:1 ratio: donateAmount = min(10, 5) = 5
        assertEq(primeToken.balanceOf(minter), 5e18, "Surplus prime stays in minter");
        assertEq(matchingToken.balanceOf(minter), 0, "All matching donated");
        assertEq(primeToken.balanceOf(address(mockVault)), 5e18, "5 prime in vault");
        assertEq(matchingToken.balanceOf(address(mockVault)), 5e18, "5 matching in vault");
    }

    // =========================================================================
    // unlockCallback tests
    // =========================================================================

    /// @notice unlockCallback reverts if caller is not the vault.
    function test_unlockCallback_revertsIfCallerIsNotVault() public {
        vm.prank(nonOwner);
        vm.expectRevert("BalancerPooler: caller is not vault");
        pooler.unlockCallback(abi.encode(uint256(100e18)));
    }
}
