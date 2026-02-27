// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Accumulator} from "../src/dispatchers/Accumulator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AccumulatorTest is Test {
    Accumulator public accumulator;
    MockERC20 public token;

    address public owner = address(this);
    address public minter = address(0xBEEF);

    function setUp() public {
        token = new MockERC20("Accumulate Token", "ACC");
        accumulator = new Accumulator(address(token), "Accumulate ACC", owner);
    }

    // =========================================================================
    // primeToken tests
    // =========================================================================

    function test_primeToken_returnsCorrectAddress() public view {
        assertEq(accumulator.primeToken(), address(token));
    }

    // =========================================================================
    // flavour tests
    // =========================================================================

    function test_flavour_returnsCorrectString() public view {
        assertEq(accumulator.flavour(), "Accumulate ACC");
    }

    // =========================================================================
    // dispatch tests - no-op behavior
    // =========================================================================

    function test_dispatch_doesNothing_tokenBalancesUnchanged() public {
        uint256 minterBalance = 100e18;
        token.mint(minter, minterBalance);

        // Dispatch should be a no-op
        accumulator.dispatch(minter, 50e18);

        // Minter balance should be unchanged
        assertEq(token.balanceOf(minter), minterBalance);
        // Accumulator should not have received any tokens
        assertEq(token.balanceOf(address(accumulator)), 0);
    }

    function test_dispatch_multipleCalls_noEffect() public {
        uint256 minterBalance = 100e18;
        token.mint(minter, minterBalance);

        // Multiple dispatches should all be no-ops
        accumulator.dispatch(minter, 10e18);
        accumulator.dispatch(minter, 20e18);
        accumulator.dispatch(minter, 30e18);

        assertEq(token.balanceOf(minter), minterBalance);
        assertEq(token.balanceOf(address(accumulator)), 0);
    }
}
