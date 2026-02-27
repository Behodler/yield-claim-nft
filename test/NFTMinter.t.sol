// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMinter} from "../src/NFTMinter.sol";
import {Accumulator} from "../src/dispatchers/Accumulator.sol";
import {ATokenDispatcher} from "../src/dispatchers/ATokenDispatcher.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockFOTToken} from "./mocks/MockFOTToken.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock ERC20 with burn capability for Burner dispatcher tests.
contract MockBurnableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract NFTMinterTest is Test {
    NFTMinter public minter;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    Accumulator public accumulator;
    Burner public burner;

    address public owner = address(this);
    address public user = address(0xBEEF);
    address public recipient = address(0xCAFE);

    function setUp() public {
        minter = new NFTMinter(owner);
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");

        // Create dispatchers
        accumulator = new Accumulator(address(tokenA), "Accumulate TKA", owner);
        burner = new Burner(address(tokenA), "Burn TKA", owner);
    }

    // =========================================================================
    // registerDispatcher tests
    // =========================================================================

    function test_registerDispatcher_createsCorrectConfig() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150; // 1.5%

        minter.registerDispatcher(address(accumulator), initialPrice, growthBps);

        (address dispatcher, uint256 price, uint256 growthBasisPoints) = minter.configs(1);
        assertEq(dispatcher, address(accumulator));
        assertEq(price, initialPrice);
        assertEq(growthBasisPoints, growthBps);
    }

    function test_registerDispatcher_updatesMappings() public {
        minter.registerDispatcher(address(accumulator), 10e18, 150);

        // dispatcherToIndex
        assertEq(minter.dispatcherToIndex(address(accumulator)), 1);

        // tokenToIndexes
        uint256[] memory indexes = minter.getDispatchers(address(tokenA));
        assertEq(indexes.length, 1);
        assertEq(indexes[0], 1);
    }

    function test_registerDispatcher_emitsEvent() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150;

        vm.expectEmit(true, true, true, true);
        emit NFTMinter.DispatcherRegistered(1, address(accumulator), address(tokenA), initialPrice, growthBps);

        minter.registerDispatcher(address(accumulator), initialPrice, growthBps);
    }

    function test_registerDispatcher_incrementsNextIndex() public {
        assertEq(minter.nextIndex(), 1);

        minter.registerDispatcher(address(accumulator), 10e18, 100);
        assertEq(minter.nextIndex(), 2);

        Accumulator accumulator2 = new Accumulator(address(tokenB), "Accumulate TKB", owner);
        minter.registerDispatcher(address(accumulator2), 5e18, 200);
        assertEq(minter.nextIndex(), 3);
    }

    function test_registerDispatcher_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        minter.registerDispatcher(address(accumulator), 10e18, 100);
    }

    function test_registerDispatcher_revertsForZeroAddress() public {
        vm.expectRevert("NFTMinter: zero dispatcher address");
        minter.registerDispatcher(address(0), 10e18, 100);
    }

    function test_registerDispatcher_revertsForDuplicateDispatcher() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        vm.expectRevert("NFTMinter: dispatcher already registered");
        minter.registerDispatcher(address(accumulator), 5e18, 200);
    }

    // =========================================================================
    // mint tests
    // =========================================================================

    function test_mint_pullsTokenAndMintsNFT() public {
        // Setup: register accumulator dispatcher
        uint256 price = 10e18;
        minter.registerDispatcher(address(accumulator), price, 0);

        // Give user tokens and approve minter
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint
        vm.prank(user);
        bool success = minter.mint(address(tokenA), 1, recipient);

        assertTrue(success);
        // User paid price
        assertEq(tokenA.balanceOf(user), 90e18);
        // Minter holds the tokens (accumulator is no-op)
        assertEq(tokenA.balanceOf(address(minter)), 10e18);
        // Recipient got 1 claim NFT
        assertEq(minter.balanceOf(recipient, minter.CLAIM_TOKEN_ID()), 1);
    }

    function test_mint_revertsIfIndexNotRegistered() public {
        vm.expectRevert("NFTMinter: index not registered");
        minter.mint(address(tokenA), 999, recipient);
    }

    function test_mint_revertsIfTokenMismatch() public {
        minter.registerDispatcher(address(accumulator), 10e18, 0);

        tokenB.mint(user, 100e18);
        vm.prank(user);
        tokenB.approve(address(minter), type(uint256).max);

        vm.prank(user);
        vm.expectRevert("NFTMinter: token mismatch");
        minter.mint(address(tokenB), 1, recipient); // tokenB != tokenA
    }

    function test_mint_priceGrowsCorrectly() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150; // 1.5%

        minter.registerDispatcher(address(accumulator), initialPrice, growthBps);

        tokenA.mint(user, 1000e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // First mint at 10e18
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);
        // New price should be 10e18 + (10e18 * 150 / 10000) = 10e18 + 0.15e18 = 10.15e18
        uint256 expectedPrice = initialPrice + (initialPrice * growthBps) / 10000;
        assertEq(minter.getPrice(1), expectedPrice);

        // Second mint at 10.15e18
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);
        uint256 expectedPrice2 = expectedPrice + (expectedPrice * growthBps) / 10000;
        assertEq(minter.getPrice(1), expectedPrice2);
    }

    function test_mint_invokesDispatcher() public {
        // Register burner dispatcher with a burnable token - it will pull tokens from minter and burn them
        MockBurnableERC20 burnableToken = new MockBurnableERC20("Burnable Token", "BRN");
        Burner burnableDispatcher = new Burner(address(burnableToken), "Burn BRN", owner);
        minter.registerDispatcher(address(burnableDispatcher), 10e18, 0);

        burnableToken.mint(user, 100e18);
        vm.prank(user);
        burnableToken.approve(address(minter), type(uint256).max);

        vm.prank(user);
        minter.mint(address(burnableToken), 1, recipient);

        // Burner should have burned the tokens (not holding them)
        assertEq(burnableToken.balanceOf(address(burnableDispatcher)), 0);
        assertEq(burnableToken.balanceOf(address(minter)), 0);
        // Total supply should be reduced by the burned amount
        assertEq(burnableToken.totalSupply(), 90e18);
    }

    // =========================================================================
    // getDispatchers tests
    // =========================================================================

    function test_getDispatchers_returnsAllIndexesForToken() public {
        // Register multiple dispatchers for tokenA
        Accumulator acc1 = new Accumulator(address(tokenA), "Acc1", owner);
        Accumulator acc2 = new Accumulator(address(tokenA), "Acc2", owner);
        Burner burn1 = new Burner(address(tokenA), "Burn1", owner);

        minter.registerDispatcher(address(acc1), 10e18, 100);
        minter.registerDispatcher(address(acc2), 20e18, 200);
        minter.registerDispatcher(address(burn1), 30e18, 300);

        uint256[] memory indexes = minter.getDispatchers(address(tokenA));
        assertEq(indexes.length, 3);
        assertEq(indexes[0], 1);
        assertEq(indexes[1], 2);
        assertEq(indexes[2], 3);
    }

    // =========================================================================
    // getFlavour tests
    // =========================================================================

    function test_getFlavour_returnsCorrectString() public {
        Accumulator acc = new Accumulator(address(tokenA), "My Flavour", owner);
        minter.registerDispatcher(address(acc), 10e18, 100);

        assertEq(minter.getFlavour(1), "My Flavour");
    }

    function test_getFlavour_revertsForUnregisteredIndex() public {
        vm.expectRevert("NFTMinter: index not registered");
        minter.getFlavour(999);
    }

    // =========================================================================
    // setPrice and setGrowthFactor tests
    // =========================================================================

    function test_setPrice_updatesCorrectly() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        minter.setPrice(1, 20e18);
        assertEq(minter.getPrice(1), 20e18);
    }

    function test_setPrice_onlyOwner() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        vm.prank(user);
        vm.expectRevert();
        minter.setPrice(1, 20e18);
    }

    function test_setPrice_emitsEvent() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.PriceUpdated(1, 10e18, 20e18);

        minter.setPrice(1, 20e18);
    }

    function test_setGrowthFactor_updatesCorrectly() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        minter.setGrowthFactor(1, 500);
        (, , uint256 growthBps) = minter.configs(1);
        assertEq(growthBps, 500);
    }

    function test_setGrowthFactor_onlyOwner() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        vm.prank(user);
        vm.expectRevert();
        minter.setGrowthFactor(1, 500);
    }

    function test_setGrowthFactor_emitsEvent() public {
        minter.registerDispatcher(address(accumulator), 10e18, 100);

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.GrowthFactorUpdated(1, 100, 500);

        minter.setGrowthFactor(1, 500);
    }

    // =========================================================================
    // Multiple mints: balance accumulates and price escalates
    // =========================================================================

    function test_multipleMints_balanceAccumulatesAndPriceEscalates() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 200; // 2%

        minter.registerDispatcher(address(accumulator), initialPrice, growthBps);

        tokenA.mint(user, 10000e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        uint256 expectedPrice = initialPrice;
        uint256 totalPaid = 0;

        // Mint 5 times
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user);
            minter.mint(address(tokenA), 1, recipient);

            totalPaid += expectedPrice;
            expectedPrice = expectedPrice + (expectedPrice * growthBps) / 10000;
        }

        // Recipient should have 5 claim NFTs
        assertEq(minter.balanceOf(recipient, minter.CLAIM_TOKEN_ID()), 5);

        // Price should have escalated correctly
        assertEq(minter.getPrice(1), expectedPrice);

        // User's balance should reflect total paid
        assertEq(tokenA.balanceOf(user), 10000e18 - totalPaid);
    }

    // =========================================================================
    // emergencyWithdraw tests
    // =========================================================================

    function test_emergencyWithdraw_succeeds_forOwnerWithStuckTokens() public {
        // Register accumulator (no-op dispatcher, tokens stay in minter)
        minter.registerDispatcher(address(accumulator), 10e18, 0);

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint to accumulate tokens in the minter
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);

        // Minter should have 10e18 stuck
        assertEq(tokenA.balanceOf(address(minter)), 10e18);

        // Owner (this contract) calls emergencyWithdraw
        vm.expectEmit(true, true, false, true);
        emit NFTMinter.EmergencyWithdraw(address(tokenA), owner, 10e18);
        minter.emergencyWithdraw(address(tokenA));

        // Tokens rescued to owner
        assertEq(tokenA.balanceOf(owner), 10e18);
        assertEq(tokenA.balanceOf(address(minter)), 0);
    }

    function test_emergencyWithdraw_revertsForNonOwner() public {
        // Get some tokens stuck in minter
        minter.registerDispatcher(address(accumulator), 10e18, 0);
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);

        // Non-owner should be rejected
        vm.prank(user);
        vm.expectRevert();
        minter.emergencyWithdraw(address(tokenA));
    }

    function test_emergencyWithdraw_revertsWhenNoTokens() public {
        // No tokens in minter
        vm.expectRevert("NFTMinter: no tokens to withdraw");
        minter.emergencyWithdraw(address(tokenA));
    }

    // =========================================================================
    // setDispatcherActive tests
    // =========================================================================

    /// @dev Helper to register a dispatcher and set up minter as the authorized minter on the dispatcher.
    function _registerAndAuthorizeMinter(address dispatcher_) internal {
        minter.registerDispatcher(dispatcher_, 10e18, 0);
        // The dispatcher owner (this test contract) authorizes the minter to pause/unpause
        ATokenDispatcher(dispatcher_).setMinter(address(minter));
    }

    function test_setDispatcherActive_false_pausesDispatcher() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Pause the dispatcher
        minter.setDispatcherActive(address(accumulator), false);

        // Verify the dispatcher is paused
        assertTrue(accumulator.paused(), "Dispatcher should be paused");
    }

    function test_setDispatcherActive_true_unpausesDispatcher() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Pause first
        minter.setDispatcherActive(address(accumulator), false);
        assertTrue(accumulator.paused(), "Dispatcher should be paused");

        // Unpause
        minter.setDispatcherActive(address(accumulator), true);
        assertFalse(accumulator.paused(), "Dispatcher should be unpaused");
    }

    function test_setDispatcherActive_revertsForNonOwner() public {
        _registerAndAuthorizeMinter(address(accumulator));

        vm.prank(user);
        vm.expectRevert();
        minter.setDispatcherActive(address(accumulator), false);
    }

    function test_setDispatcherActive_revertsForUnregisteredDispatcher() public {
        vm.expectRevert("NFTMinter: dispatcher not registered");
        minter.setDispatcherActive(address(accumulator), false);
    }

    function test_setDispatcherActive_emitsEvent() public {
        _registerAndAuthorizeMinter(address(accumulator));

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.DispatcherActiveChanged(address(accumulator), false);
        minter.setDispatcherActive(address(accumulator), false);
    }

    function test_setDispatcherActive_handlesAlreadyPausedGracefully() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Pause the dispatcher
        minter.setDispatcherActive(address(accumulator), false);
        assertTrue(accumulator.paused());

        // Calling pause again should not revert (graceful handling)
        minter.setDispatcherActive(address(accumulator), false);
        assertTrue(accumulator.paused());
    }

    function test_setDispatcherActive_handlesAlreadyUnpausedGracefully() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Dispatcher starts unpaused, calling unpause again should not revert
        assertFalse(accumulator.paused());
        minter.setDispatcherActive(address(accumulator), true);
        assertFalse(accumulator.paused());
    }

    // =========================================================================
    // mint() with paused dispatcher tests
    // =========================================================================

    function test_mint_revertsWhenDispatcherIsPaused() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Pause the dispatcher
        minter.setDispatcherActive(address(accumulator), false);

        // Mint should revert because dispatcher is paused (whenNotPaused reverts with EnforcedPause)
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter.mint(address(tokenA), 1, recipient);
    }

    function test_mint_worksNormallyWhenDispatcherIsActive() public {
        _registerAndAuthorizeMinter(address(accumulator));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Dispatcher is active (not paused) by default
        assertFalse(accumulator.paused());

        // Mint should succeed
        vm.prank(user);
        bool success = minter.mint(address(tokenA), 1, recipient);
        assertTrue(success);
        assertEq(minter.balanceOf(recipient, minter.CLAIM_TOKEN_ID()), 1);
    }

    // =========================================================================
    // ATokenDispatcher setMinter tests
    // =========================================================================

    function test_ATokenDispatcher_setMinter_onlyOwner() public {
        // Non-owner should not be able to call setMinter
        vm.prank(user);
        vm.expectRevert();
        accumulator.setMinter(user);
    }

    function test_ATokenDispatcher_setMinter_ownerCanSet() public {
        // Owner (this test contract) should be able to set the minter
        accumulator.setMinter(address(minter));
        // No revert means success. Verify by testing that minter can now call pause
        vm.prank(address(minter));
        accumulator.pause();
        assertTrue(accumulator.paused());
    }

    // =========================================================================
    // ATokenDispatcher pause/unpause restricted to minter
    // =========================================================================

    function test_ATokenDispatcher_pause_restrictedToMinter() public {
        accumulator.setMinter(address(minter));

        // Non-minter should not be able to call pause
        vm.prank(user);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        accumulator.pause();

        // Owner (not the minter) also cannot call pause
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        accumulator.pause();
    }

    function test_ATokenDispatcher_unpause_restrictedToMinter() public {
        accumulator.setMinter(address(minter));

        // Pause first via the minter
        vm.prank(address(minter));
        accumulator.pause();
        assertTrue(accumulator.paused());

        // Non-minter should not be able to unpause
        vm.prank(user);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        accumulator.unpause();

        // Owner (not the minter) also cannot unpause
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        accumulator.unpause();
    }

    function test_ATokenDispatcher_minterCanPauseAndUnpause() public {
        accumulator.setMinter(address(minter));

        // Minter can pause
        vm.prank(address(minter));
        accumulator.pause();
        assertTrue(accumulator.paused());

        // Minter can unpause
        vm.prank(address(minter));
        accumulator.unpause();
        assertFalse(accumulator.paused());
    }

    // =========================================================================
    // Global Pauser Integration tests (IPausable / setPauser / pause / unpause)
    // =========================================================================

    address public globalPauser = address(0xDA05);

    function test_setPauser_setsPauserAddress() public {
        minter.setPauser(globalPauser);
        assertEq(minter.pauser(), globalPauser);
    }

    function test_setPauser_emitsPauserChangedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit NFTMinter.PauserChanged(address(0), globalPauser);

        minter.setPauser(globalPauser);
    }

    function test_setPauser_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        minter.setPauser(globalPauser);
    }

    function test_globalPause_setsPausedTrue() public {
        minter.setPauser(globalPauser);

        vm.prank(globalPauser);
        minter.pause();

        assertTrue(minter.paused());
    }

    function test_globalPause_emitsPausedEvent() public {
        minter.setPauser(globalPauser);

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.Paused(globalPauser);

        vm.prank(globalPauser);
        minter.pause();
    }

    function test_globalPause_revertsWhenCalledByNonPauser() public {
        minter.setPauser(globalPauser);

        // Random user cannot pause
        vm.prank(user);
        vm.expectRevert("Only pauser");
        minter.pause();

        // Owner cannot pause (only pauser can)
        vm.expectRevert("Only pauser");
        minter.pause();
    }

    function test_globalUnpause_setsPausedFalse() public {
        minter.setPauser(globalPauser);

        // Pause first
        vm.prank(globalPauser);
        minter.pause();
        assertTrue(minter.paused());

        // Unpause
        vm.prank(globalPauser);
        minter.unpause();
        assertFalse(minter.paused());
    }

    function test_globalUnpause_emitsUnpausedEvent() public {
        minter.setPauser(globalPauser);

        vm.prank(globalPauser);
        minter.pause();

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.Unpaused(globalPauser);

        vm.prank(globalPauser);
        minter.unpause();
    }

    function test_globalUnpause_revertsWhenCalledByNonPauser() public {
        minter.setPauser(globalPauser);

        // Pause first
        vm.prank(globalPauser);
        minter.pause();

        // Random user cannot unpause
        vm.prank(user);
        vm.expectRevert("Only pauser");
        minter.unpause();

        // Owner cannot unpause (only pauser can)
        vm.expectRevert("Only pauser");
        minter.unpause();
    }

    function test_mint_revertsWhenContractIsPaused() public {
        // Register dispatcher and authorize minter
        _registerAndAuthorizeMinter(address(accumulator));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Set pauser and pause the contract
        minter.setPauser(globalPauser);
        vm.prank(globalPauser);
        minter.pause();

        // Mint should revert with "Contract is paused"
        vm.prank(user);
        vm.expectRevert("Contract is paused");
        minter.mint(address(tokenA), 1, recipient);
    }

    function test_mint_worksNormallyWhenContractIsNotPaused() public {
        // Register dispatcher and authorize minter
        _registerAndAuthorizeMinter(address(accumulator));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Set pauser but do NOT pause
        minter.setPauser(globalPauser);
        assertFalse(minter.paused());

        // Mint should succeed
        vm.prank(user);
        bool success = minter.mint(address(tokenA), 1, recipient);
        assertTrue(success);
        assertEq(minter.balanceOf(recipient, minter.CLAIM_TOKEN_ID()), 1);
    }

    function test_pauserGetter_returnsCorrectAddress() public {
        // Initially zero
        assertEq(minter.pauser(), address(0));

        // After setting
        minter.setPauser(globalPauser);
        assertEq(minter.pauser(), globalPauser);

        // After changing
        address newPauser = address(0xEEEE);
        minter.setPauser(newPauser);
        assertEq(minter.pauser(), newPauser);
    }

    function test_adminFunctions_workWhenContractIsPaused() public {
        // Register a dispatcher first
        _registerAndAuthorizeMinter(address(accumulator));

        // Pause the contract
        minter.setPauser(globalPauser);
        vm.prank(globalPauser);
        minter.pause();
        assertTrue(minter.paused());

        // registerDispatcher should still work
        Accumulator accumulator2 = new Accumulator(address(tokenB), "Acc2", owner);
        accumulator2.setMinter(address(minter));
        minter.registerDispatcher(address(accumulator2), 5e18, 200);
        (address dispatcher,,) = minter.configs(2);
        assertEq(dispatcher, address(accumulator2));

        // setPrice should still work
        minter.setPrice(1, 20e18);
        assertEq(minter.getPrice(1), 20e18);

        // setGrowthFactor should still work
        minter.setGrowthFactor(1, 500);
        (,, uint256 growthBps) = minter.configs(1);
        assertEq(growthBps, 500);
    }

    // =========================================================================
    // FOT token tests
    // =========================================================================

    function test_mint_FOTToken_withAccumulator_noRevert_NFTMinted() public {
        // Create a FOT token with 2% fee (200 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);

        // Create Accumulator for FOT token
        Accumulator fotAccumulator = new Accumulator(address(fotToken), "Accumulate FOT", owner);
        fotAccumulator.setMinter(address(minter));

        uint256 initialPrice = 100e18;
        minter.registerDispatcher(address(fotAccumulator), initialPrice, 0);

        // Give user tokens and approve
        fotToken.mint(user, 1000e18);
        vm.prank(user);
        fotToken.approve(address(minter), type(uint256).max);

        // Mint should not revert
        vm.prank(user);
        bool success = minter.mint(address(fotToken), 1, recipient);

        assertTrue(success, "Mint should succeed with FOT token");
        // Recipient should have 1 claim NFT
        assertEq(minter.balanceOf(recipient, minter.CLAIM_TOKEN_ID()), 1, "Recipient should have 1 claim NFT");
        // User loses exactly `price` from their balance (amount-fee transferred + fee burned)
        assertEq(fotToken.balanceOf(user), 1000e18 - initialPrice, "User should have lost exactly price from balance");
        // But minter received less than price due to FOT fee (2% of 100e18 = 2e18 burned)
        assertEq(fotToken.balanceOf(address(minter)), 98e18, "Minter should have received price minus 2% fee");
    }

    function test_mint_FOTToken_actualReceivedLessThanPrice_passedToDispatcher() public {
        // Create a FOT token with 5% fee (500 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 500);

        // Create Accumulator for FOT token (no-op, tokens stay in minter)
        Accumulator fotAccumulator = new Accumulator(address(fotToken), "Accumulate FOT", owner);
        fotAccumulator.setMinter(address(minter));

        uint256 price = 100e18;
        minter.registerDispatcher(address(fotAccumulator), price, 0);

        // Give user tokens and approve
        fotToken.mint(user, 1000e18);
        vm.prank(user);
        fotToken.approve(address(minter), type(uint256).max);

        // Record minter balance before
        uint256 minterBalanceBefore = fotToken.balanceOf(address(minter));

        // Mint
        vm.prank(user);
        minter.mint(address(fotToken), 1, recipient);

        // Minter should have received less than price due to FOT fee
        uint256 minterBalanceAfter = fotToken.balanceOf(address(minter));
        uint256 actualReceived = minterBalanceAfter - minterBalanceBefore;

        // 5% fee: actualReceived should be 95e18
        assertEq(actualReceived, 95e18, "Minter should receive price minus 5% fee");
        assertTrue(actualReceived < price, "actualReceived should be less than price for FOT token");

        // Price growth should still be based on original price (unchanged)
        // Since growth is 0, price stays the same
        assertEq(minter.getPrice(1), price, "Price should remain unchanged with 0 growth");
    }
}
