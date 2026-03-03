// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BurnRecorder} from "../src/BurnRecorder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BurnRecorderTest is Test {
    BurnRecorder public recorder;

    address public owner = address(this);
    address public nonOwner = address(0xBEEF);
    address public tokenA = address(0xA);
    address public tokenB = address(0xB);
    address public tokenC = address(0xC);

    function setUp() public {
        recorder = new BurnRecorder(owner);
    }

    // =========================================================================
    // registerToken tests
    // =========================================================================

    /// @notice Test that registerToken adds tokens to index correctly.
    function test_registerToken_addsTokensToIndex() public {
        recorder.registerToken(tokenA);
        recorder.registerToken(tokenB);
        recorder.registerToken(tokenC);

        assertEq(recorder.getTokenCount(), 3, "Token count should be 3");
        assertEq(recorder.getTokenAtIndex(0), tokenA, "Token at index 0 should be tokenA");
        assertEq(recorder.getTokenAtIndex(1), tokenB, "Token at index 1 should be tokenB");
        assertEq(recorder.getTokenAtIndex(2), tokenC, "Token at index 2 should be tokenC");
    }

    /// @notice Test that registerToken reverts for non-owner.
    function test_registerToken_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        recorder.registerToken(tokenA);
    }

    // =========================================================================
    // burn tests
    // =========================================================================

    /// @notice Test that burn accumulates totalBurnt correctly.
    function test_burn_accumulatesTotalBurnt() public {
        recorder.burn(tokenA, 100e18);
        assertEq(recorder.getTotalBurnt(tokenA), 100e18, "After first burn");

        recorder.burn(tokenA, 50e18);
        assertEq(recorder.getTotalBurnt(tokenA), 150e18, "After second burn");

        recorder.burn(tokenA, 25e18);
        assertEq(recorder.getTotalBurnt(tokenA), 175e18, "After third burn");
    }

    /// @notice Test that burn emits tokenBurnt event with correct parameters.
    function test_burn_emitsTokenBurntEvent() public {
        uint256 amount = 100e18;

        vm.expectEmit(true, false, false, true);
        emit BurnRecorder.tokenBurnt(tokenA, amount, block.timestamp);

        recorder.burn(tokenA, amount);
    }

    /// @notice Test that burn tracks different tokens independently.
    function test_burn_tracksDifferentTokensIndependently() public {
        recorder.burn(tokenA, 100e18);
        recorder.burn(tokenB, 200e18);
        recorder.burn(tokenA, 50e18);

        assertEq(recorder.getTotalBurnt(tokenA), 150e18, "TokenA total should be 150e18");
        assertEq(recorder.getTotalBurnt(tokenB), 200e18, "TokenB total should be 200e18");
        assertEq(recorder.getTotalBurnt(tokenC), 0, "TokenC total should be 0 (never burned)");
    }

    // =========================================================================
    // getTotalBurnt tests
    // =========================================================================

    /// @notice Test that getTotalBurnt returns correct cumulative amount.
    function test_getTotalBurnt_returnsCorrectCumulativeAmount() public {
        // Initially zero
        assertEq(recorder.getTotalBurnt(tokenA), 0, "Initially should be 0");

        // After burns
        recorder.burn(tokenA, 10e18);
        recorder.burn(tokenA, 20e18);
        recorder.burn(tokenA, 30e18);

        assertEq(recorder.getTotalBurnt(tokenA), 60e18, "Cumulative total should be 60e18");
    }

    /// @notice Test that getTotalBurnt returns zero for unburned token.
    function test_getTotalBurnt_returnsZeroForUnburnedToken() public view {
        assertEq(recorder.getTotalBurnt(tokenA), 0, "Should return 0 for token with no burns");
    }

    // =========================================================================
    // getTokenCount and getTokenAtIndex tests
    // =========================================================================

    /// @notice Test getTokenCount returns correct values.
    function test_getTokenCount_returnsCorrectValues() public {
        assertEq(recorder.getTokenCount(), 0, "Initially should be 0");

        recorder.registerToken(tokenA);
        assertEq(recorder.getTokenCount(), 1, "After registering 1 token");

        recorder.registerToken(tokenB);
        assertEq(recorder.getTokenCount(), 2, "After registering 2 tokens");

        recorder.registerToken(tokenC);
        assertEq(recorder.getTokenCount(), 3, "After registering 3 tokens");
    }

    /// @notice Test getTokenAtIndex returns correct values.
    function test_getTokenAtIndex_returnsCorrectValues() public {
        recorder.registerToken(tokenA);
        recorder.registerToken(tokenB);

        assertEq(recorder.getTokenAtIndex(0), tokenA, "Index 0 should be tokenA");
        assertEq(recorder.getTokenAtIndex(1), tokenB, "Index 1 should be tokenB");
    }

    /// @notice Test getTokenAtIndex returns zero address for unregistered index.
    function test_getTokenAtIndex_returnsZeroAddressForUnregisteredIndex() public view {
        // No tokens registered, so any index should return address(0)
        assertEq(recorder.getTokenAtIndex(0), address(0), "Unregistered index should return address(0)");
        assertEq(recorder.getTokenAtIndex(999), address(0), "Large unregistered index should return address(0)");
    }
}
