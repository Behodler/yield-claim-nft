// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalancerPooler} from "../src/dispatchers/BalancerPooler.sol";
import {ITokenDispatcher} from "../src/interfaces/ITokenDispatcher.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BalancerPoolerTest is Test {
    BalancerPooler public pooler;
    MockERC20 public primeToken;
    MockERC20 public matchingToken;
    address public pool = address(0xA001);
    address public owner = address(this);
    address public minter = address(0xBEEF);
    address public nonOwner = address(0xCAFE);

    function setUp() public {
        primeToken = new MockERC20("Prime Token", "PRM");
        matchingToken = new MockERC20("Matching Token", "MTH");
        pooler = new BalancerPooler(address(primeToken), address(matchingToken), pool, "Pool PRM/MTH", owner);
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
    // dispatch tests - both thresholds met: transferFrom succeeds
    // =========================================================================

    function test_dispatch_bothThresholdsMet_transfersTokens() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        // Both meet thresholds
        primeToken.mint(minter, 150e18);
        matchingToken.mint(minter, 200e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // All tokens should have been transferred from minter to pooler
        assertEq(primeToken.balanceOf(minter), 0);
        assertEq(matchingToken.balanceOf(minter), 0);
        assertEq(primeToken.balanceOf(address(pooler)), 150e18);
        assertEq(matchingToken.balanceOf(address(pooler)), 200e18);
    }

    // =========================================================================
    // dispatch tests - TODO pool donation (tokens stay in pooler, not donated)
    // =========================================================================

    /// @notice After transferFrom succeeds, the pool donation is a TODO stub.
    /// @dev This test verifies that tokens end up in the pooler contract (not the pool)
    ///      because the actual pool donation has not been implemented yet.
    ///      Once pool donation is implemented, tokens should move from pooler to pool.
    function test_dispatch_afterTransfer_poolDonationIsTodo() public {
        pooler.setPrimeTokenThreshold(100e18);
        pooler.setMatchingTokenThreshold(100e18);

        primeToken.mint(minter, 100e18);
        matchingToken.mint(minter, 100e18);

        vm.startPrank(minter);
        primeToken.approve(address(pooler), type(uint256).max);
        matchingToken.approve(address(pooler), type(uint256).max);
        vm.stopPrank();

        pooler.dispatch(minter, 10e18);

        // Tokens are in the pooler, NOT in the pool - pool donation is TODO
        assertEq(primeToken.balanceOf(address(pooler)), 100e18, "Prime tokens stuck in pooler (pool donation is TODO)");
        assertEq(matchingToken.balanceOf(address(pooler)), 100e18, "Matching tokens stuck in pooler (pool donation is TODO)");
        assertEq(primeToken.balanceOf(pool), 0, "Pool has no tokens - donation not implemented yet");
        assertEq(matchingToken.balanceOf(pool), 0, "Pool has no tokens - donation not implemented yet");
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

        // Tokens should be transferred since thresholds are 0
        assertEq(primeToken.balanceOf(minter), 0);
        assertEq(matchingToken.balanceOf(minter), 0);
        assertEq(primeToken.balanceOf(address(pooler)), 10e18);
        assertEq(matchingToken.balanceOf(address(pooler)), 5e18);
    }
}
