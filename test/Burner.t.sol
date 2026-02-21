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
    // dispatch tests
    // =========================================================================

    /// @notice Verifies that dispatch pulls tokens from the minter and burns them.
    function test_dispatch_burnsToken() public {
        uint256 amount = 100e18;

        // Mint tokens to the minter address
        token.mint(minter, amount);

        // Approve burner to pull from minter
        vm.prank(minter);
        token.approve(address(burner), type(uint256).max);

        // Dispatch
        burner.dispatch(minter, amount);

        // After dispatch, the tokens should be BURNED (total supply decreased)
        assertEq(token.totalSupply(), 0, "Tokens should be burned, reducing total supply to 0");
        // Burner contract should have 0 balance (tokens are burned, not held)
        assertEq(token.balanceOf(address(burner)), 0, "Burner should have 0 balance after burning");
    }

    /// @notice Verifies that dispatch pulls tokens from the minter and burns them.
    function test_dispatch_pullsTokensFromMinter() public {
        uint256 amount = 50e18;

        token.mint(minter, amount);

        vm.prank(minter);
        token.approve(address(burner), type(uint256).max);

        burner.dispatch(minter, amount);

        // Minter should have no tokens left (they were pulled)
        assertEq(token.balanceOf(minter), 0);
        // Burner should have no tokens (they were burned)
        assertEq(token.balanceOf(address(burner)), 0);
    }
}
