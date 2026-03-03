// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
import {BurnRecorder} from "../src/BurnRecorder.sol";
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
    BurnRecorder public burnRecorder;

    address public owner = address(this);
    address public minter = address(0xABCDEF);

    function setUp() public {
        token = new MockBurnableERC20("Burn Token", "BURN");
        burnRecorder = new BurnRecorder(owner);
        burner = new Burner(address(token), "Burn BURN", address(burnRecorder), owner);
        // Set the minter so dispatch() can be called via onlyMinter
        burner.setMinter(minter);
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
    // dispatch tests (tokens already on burner, just burn them)
    // =========================================================================

    /// @notice Verifies that dispatch burns tokens already on the burner.
    function test_dispatch_burnsToken() public {
        uint256 amount = 100e18;

        // Tokens are already on burner (sent by minter's transferFrom)
        token.mint(address(burner), amount);

        // Dispatch (called by minter)
        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        // After dispatch, the tokens should be BURNED (total supply decreased)
        assertEq(token.totalSupply(), 0, "Tokens should be burned, reducing total supply to 0");
        // Burner contract should have 0 balance (tokens are burned, not held)
        assertEq(token.balanceOf(address(burner)), 0, "Burner should have 0 balance after burning");
    }

    /// @notice Verifies that dispatch burns the correct amount.
    function test_dispatch_burnsCorrectAmount() public {
        uint256 amount = 50e18;

        // Mint extra tokens to burner to verify only `amount` is burned
        token.mint(address(burner), amount + 25e18);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        // Only `amount` should be burned, 25e18 remains
        assertEq(token.balanceOf(address(burner)), 25e18, "Only dispatched amount should be burned");
    }

    /// @notice Verifies that dispatch reverts when called by non-minter.
    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;

        token.mint(address(burner), amount);

        // Non-minter cannot call dispatch
        vm.prank(address(0xDEAD));
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        burner.dispatch(address(0xDEAD), amount, "");
    }

    // =========================================================================
    // FOT token dispatch tests (tokens already on burner)
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_tokensBurned() public {
        // Create a burnable FOT token with 2% fee (200 bps)
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 200);
        Burner fotBurner = new Burner(address(fotToken), "Burn FOTBURN", address(burnRecorder), owner);
        fotBurner.setMinter(minter);

        uint256 amount = 100e18;
        // Tokens already on burner (sent by minter's transferFrom)
        fotToken.mint(address(fotBurner), amount);

        // Should not revert
        vm.prank(minter);
        fotBurner.dispatch(minter, amount, "");

        // burn: burner burns 100e18 (no transferFrom fee anymore, tokens already present)
        // Total supply should be 0
        assertEq(fotToken.totalSupply(), 0, "All tokens should be burned after dispatch");
    }

    function test_dispatch_FOTToken_zeroTokensStuckInBurner() public {
        // Create a burnable FOT token with 3% fee (300 bps)
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 300);
        Burner fotBurner = new Burner(address(fotToken), "Burn FOTBURN", address(burnRecorder), owner);
        fotBurner.setMinter(minter);

        uint256 amount = 100e18;
        // Tokens already on burner
        fotToken.mint(address(fotBurner), amount);

        vm.prank(minter);
        fotBurner.dispatch(minter, amount, "");

        // Burner should have 0 balance (all burned)
        assertEq(fotToken.balanceOf(address(fotBurner)), 0, "Burner should have 0 balance after FOT dispatch");
    }

    // =========================================================================
    // BurnRecorder integration tests
    // =========================================================================

    /// @notice Verifies that Burner.dispatch() calls BurnRecorder.burn() after token burn.
    function test_dispatch_callsBurnRecorder() public {
        uint256 amount = 100e18;

        // Tokens are already on burner
        token.mint(address(burner), amount);

        // Dispatch (called by minter)
        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        // BurnRecorder should have recorded the burn
        assertEq(burnRecorder.getTotalBurnt(address(token)), amount, "BurnRecorder should track the burn amount");
    }

    /// @notice Verifies that BurnRecorder state updates correctly through full Burner flow with multiple dispatches.
    function test_dispatch_burnRecorderAccumulatesAcrossMultipleDispatches() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 30e18;
        uint256 amount3 = 20e18;

        // First dispatch
        token.mint(address(burner), amount1);
        vm.prank(minter);
        burner.dispatch(minter, amount1, "");

        assertEq(burnRecorder.getTotalBurnt(address(token)), amount1, "After first dispatch");

        // Second dispatch
        token.mint(address(burner), amount2);
        vm.prank(minter);
        burner.dispatch(minter, amount2, "");

        assertEq(burnRecorder.getTotalBurnt(address(token)), amount1 + amount2, "After second dispatch");

        // Third dispatch
        token.mint(address(burner), amount3);
        vm.prank(minter);
        burner.dispatch(minter, amount3, "");

        assertEq(
            burnRecorder.getTotalBurnt(address(token)),
            amount1 + amount2 + amount3,
            "After third dispatch, cumulative total should be correct"
        );
    }

    /// @notice Verifies that BurnRecorder emits tokenBurnt event when called through Burner.dispatch().
    function test_dispatch_burnRecorderEmitsEvent() public {
        uint256 amount = 75e18;

        token.mint(address(burner), amount);

        vm.expectEmit(true, false, false, true);
        emit BurnRecorder.tokenBurnt(address(token), amount, block.timestamp);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");
    }
}
