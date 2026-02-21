// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
import {ITokenDispatcher} from "../src/interfaces/ITokenDispatcher.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock ERC20 with burn capability for testing expected burn behavior.
contract MockBurnableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract BurnerTest is Test {
    Burner public burner;
    MockBurnableERC20 public token;

    address public owner = address(this);
    address public minter = address(0xABCDEF);

    function setUp() public {
        token = new MockBurnableERC20("Burn Token", "BURN");
        burner = new Burner(address(token), "Burn BURN", owner);
    }

    // =========================================================================
    // primeToken tests
    // =========================================================================

    function test_primeToken_returnsCorrectAddress() public view {
        assertEq(burner.primeToken(), address(token));
    }

    // =========================================================================
    // tokensToApprove tests
    // =========================================================================

    function test_tokensToApprove_returnsEmptyArray() public view {
        address[] memory tokens = burner.tokensToApprove();
        assertEq(tokens.length, 0);
    }

    // =========================================================================
    // flavour tests
    // =========================================================================

    function test_flavour_returnsCorrectString() public view {
        assertEq(burner.flavour(), "Burn BURN");
    }

    // =========================================================================
    // dispatch tests (TDD Red Phase - burn test should FAIL)
    // =========================================================================

    /// @notice This test verifies that dispatch pulls tokens from the minter and burns them.
    /// @dev TDD RED PHASE: This test is expected to FAIL because the burn logic is a TODO stub.
    ///      The Burner.dispatch currently pulls tokens from the minter to itself but does NOT
    ///      actually burn them. Once the burn implementation is added in a future story,
    ///      this test should pass.
    function test_dispatch_burnsToken_EXPECTED_FAIL() public {
        uint256 amount = 100e18;

        // Mint tokens to the minter address
        token.mint(minter, amount);

        // Approve burner to pull from minter
        vm.prank(minter);
        token.approve(address(burner), type(uint256).max);

        // Dispatch
        burner.dispatch(minter, amount);

        // After dispatch, the tokens should be BURNED (total supply decreased)
        // This WILL FAIL because burn is TODO - tokens are held by burner, not burned
        assertEq(token.totalSupply(), 0, "Tokens should be burned, reducing total supply to 0");
    }

    /// @notice Verifies that dispatch actually pulls tokens from the minter.
    /// @dev This test should PASS - the transferFrom works, just the burn is missing.
    function test_dispatch_pullsTokensFromMinter() public {
        uint256 amount = 50e18;

        token.mint(minter, amount);

        vm.prank(minter);
        token.approve(address(burner), type(uint256).max);

        burner.dispatch(minter, amount);

        // Minter should have no tokens left (they were pulled)
        assertEq(token.balanceOf(minter), 0);
        // Burner should hold the tokens (since burn is TODO)
        assertEq(token.balanceOf(address(burner)), amount);
    }
}
