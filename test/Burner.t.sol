// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
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

/// @dev Mock ERC20 with FOT (fee-on-transfer) AND burn capability for Burner dispatcher tests.
contract MockBurnableFOTToken is ERC20 {
    uint256 public feeBasisPoints;

    constructor(string memory name_, string memory symbol_, uint256 feeBps) ERC20(name_, symbol_) {
        feeBasisPoints = feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBasisPoints) / 10000;
        _transfer(msg.sender, to, amount - fee);
        _burn(msg.sender, fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * feeBasisPoints) / 10000;
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        return true;
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

    // =========================================================================
    // FOT token dispatch tests
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_tokensBurned() public {
        // Create a burnable FOT token with 2% fee (200 bps)
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 200);
        Burner fotBurner = new Burner(address(fotToken), "Burn FOTBURN", owner);

        uint256 amount = 100e18;
        fotToken.mint(minter, amount);

        vm.prank(minter);
        fotToken.approve(address(fotBurner), type(uint256).max);

        // Should not revert
        fotBurner.dispatch(minter, amount);

        // transferFrom: minter -> burner, 2% fee = 2e18 burned in transfer, burner receives 98e18
        // burn: burner burns 98e18
        // Total supply should be 0 (100e18 minted - 2e18 FOT fee burned - 98e18 explicitly burned)
        assertEq(fotToken.totalSupply(), 0, "All tokens should be burned after FOT dispatch");
    }

    function test_dispatch_FOTToken_zeroTokensStuckInBurner() public {
        // Create a burnable FOT token with 3% fee (300 bps)
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 300);
        Burner fotBurner = new Burner(address(fotToken), "Burn FOTBURN", owner);

        uint256 amount = 100e18;
        fotToken.mint(minter, amount);

        vm.prank(minter);
        fotToken.approve(address(fotBurner), type(uint256).max);

        fotBurner.dispatch(minter, amount);

        // Burner should have 0 balance (all burned)
        assertEq(fotToken.balanceOf(address(fotBurner)), 0, "Burner should have 0 balance after FOT dispatch");
    }
}
