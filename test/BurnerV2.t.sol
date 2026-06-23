// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BurnerV2} from "../src/dispatchers/BurnerV2.sol";
import {BurnRecorder} from "../src/BurnRecorder.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
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

/// @dev Mock ERC20 with FOT (fee-on-transfer) AND burn capability for BurnerV2 tests.
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

contract BurnerV2Test is Test {
    BurnerV2 public burner;
    MockBurnableERC20 public token;
    BurnRecorder public burnRecorder;

    address public owner = address(this);
    address public minter = address(0xABCDEF);

    function setUp() public {
        token = new MockBurnableERC20("Burn Token", "BURN");
        burnRecorder = new BurnRecorder(owner);
        burner = new BurnerV2(address(token), address(burnRecorder), owner);
        burnRecorder.setBurner(address(burner), true);
        burner.setMinter(minter);
    }

    // =========================================================================
    // dispatch tests (tokens already on burner, just burn them)
    // =========================================================================

    function test_dispatch_burnsToken() public {
        uint256 amount = 100e18;
        token.mint(address(burner), amount);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        assertEq(token.totalSupply(), 0, "Tokens should be burned, reducing total supply to 0");
        assertEq(token.balanceOf(address(burner)), 0, "Burner should have 0 balance after burning");
    }

    function test_dispatch_burnsCorrectAmount() public {
        uint256 amount = 50e18;
        token.mint(address(burner), amount + 25e18);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        assertEq(token.balanceOf(address(burner)), 25e18, "Only dispatched amount should be burned");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        token.mint(address(burner), amount);

        vm.prank(address(0xDEAD));
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        burner.dispatch(address(0xDEAD), amount, "");
    }

    // =========================================================================
    // FOT token dispatch tests
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_tokensBurned() public {
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 200);
        BurnRecorder fotBurnRecorder = new BurnRecorder(owner);
        BurnerV2 fotBurner = new BurnerV2(address(fotToken), address(fotBurnRecorder), owner);
        fotBurnRecorder.setBurner(address(fotBurner), true);
        fotBurner.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotBurner), amount);

        vm.prank(minter);
        fotBurner.dispatch(minter, amount, "");

        assertEq(fotToken.totalSupply(), 0, "All tokens should be burned after dispatch");
    }

    function test_dispatch_FOTToken_zeroTokensStuckInBurner() public {
        MockBurnableFOTToken fotToken = new MockBurnableFOTToken("FOT Burn Token", "FOTBURN", 300);
        BurnRecorder fotBurnRecorder = new BurnRecorder(owner);
        BurnerV2 fotBurner = new BurnerV2(address(fotToken), address(fotBurnRecorder), owner);
        fotBurnRecorder.setBurner(address(fotBurner), true);
        fotBurner.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotBurner), amount);

        vm.prank(minter);
        fotBurner.dispatch(minter, amount, "");

        assertEq(fotToken.balanceOf(address(fotBurner)), 0, "Burner should have 0 balance after FOT dispatch");
    }

    // =========================================================================
    // BurnRecorder integration tests
    // =========================================================================

    function test_dispatch_callsBurnRecorder() public {
        uint256 amount = 100e18;
        token.mint(address(burner), amount);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");

        assertEq(burnRecorder.getTotalBurnt(address(token)), amount, "BurnRecorder should track the burn amount");
    }

    function test_dispatch_burnRecorderAccumulatesAcrossMultipleDispatches() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 30e18;
        uint256 amount3 = 20e18;

        token.mint(address(burner), amount1);
        vm.prank(minter);
        burner.dispatch(minter, amount1, "");
        assertEq(burnRecorder.getTotalBurnt(address(token)), amount1, "After first dispatch");

        token.mint(address(burner), amount2);
        vm.prank(minter);
        burner.dispatch(minter, amount2, "");
        assertEq(burnRecorder.getTotalBurnt(address(token)), amount1 + amount2, "After second dispatch");

        token.mint(address(burner), amount3);
        vm.prank(minter);
        burner.dispatch(minter, amount3, "");
        assertEq(
            burnRecorder.getTotalBurnt(address(token)),
            amount1 + amount2 + amount3,
            "After third dispatch, cumulative total should be correct"
        );
    }

    function test_dispatch_burnRecorderEmitsEvent() public {
        uint256 amount = 75e18;
        token.mint(address(burner), amount);

        vm.expectEmit(true, false, false, true);
        emit BurnRecorder.tokenBurnt(address(token), amount, block.timestamp);

        vm.prank(minter);
        burner.dispatch(minter, amount, "");
    }

    // =========================================================================
    // Hook integration tests
    // =========================================================================

    function test_dispatch_invokesHookWithForwardedArgs() public {
        MockDispatchHook hook = new MockDispatchHook();
        burner.setHook(IDispatchHook(address(hook)));

        uint256 amount = 100e18;
        bytes memory payload = hex"01020304";
        token.mint(address(burner), amount);

        vm.prank(minter);
        burner.dispatch(minter, amount, payload);

        assertEq(hook.callCount(), 1, "hook should be called once after burn");
        assertEq(hook.lastMinter(), minter, "hook should receive minter");
        assertEq(hook.lastAmount(), amount, "hook should receive amount");
        assertEq(hook.lastExtraData(), payload, "hook should receive extraData verbatim");
    }
}
