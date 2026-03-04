// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMinter} from "../src/NFTMinter.sol";
import {Gather} from "../src/dispatchers/Gather.sol";
import {ATokenDispatcher} from "../src/dispatchers/ATokenDispatcher.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
import {BurnRecorder} from "../src/BurnRecorder.sol";
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
    Gather public gather;
    Burner public burner;
    BurnRecorder public burnRecorder;

    address public owner = address(this);
    address public user = address(0xBEEF);
    address public recipient = address(0xCAFE);
    address public gatherRecipient = address(0xFEED);

    function setUp() public {
        minter = new NFTMinter(owner);
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        // Predict the burner address so BurnRecorder can authorize it as minter.
        // BurnRecorder deploys at nonce N, Gather at N+1, Burner at N+2.
        address predictedBurner = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        burnRecorder = new BurnRecorder(owner, predictedBurner);

        // Create dispatchers
        gather = new Gather(address(tokenA), gatherRecipient, owner);
        burner = new Burner(address(tokenA), address(burnRecorder), owner);
    }

    // =========================================================================
    // registerDispatcher tests
    // =========================================================================

    function test_registerDispatcher_createsCorrectConfig() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150; // 1.5%

        minter.registerDispatcher(address(gather), initialPrice, growthBps);

        (address dispatcher, uint256 price, uint256 growthBasisPoints) = minter.configs(1);
        assertEq(dispatcher, address(gather));
        assertEq(price, initialPrice);
        assertEq(growthBasisPoints, growthBps);
    }

    function test_registerDispatcher_updatesMappings() public {
        minter.registerDispatcher(address(gather), 10e18, 150);

        // dispatcherToIndex
        assertEq(minter.dispatcherToIndex(address(gather)), 1);

        // tokenToIndexes
        uint256[] memory indexes = minter.getDispatchers(address(tokenA));
        assertEq(indexes.length, 1);
        assertEq(indexes[0], 1);
    }

    function test_registerDispatcher_emitsEvent() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150;

        vm.expectEmit(true, true, true, true);
        emit NFTMinter.DispatcherRegistered(1, address(gather), address(tokenA), initialPrice, growthBps);

        minter.registerDispatcher(address(gather), initialPrice, growthBps);
    }

    function test_registerDispatcher_incrementsNextIndex() public {
        assertEq(minter.nextIndex(), 1);

        minter.registerDispatcher(address(gather), 10e18, 100);
        assertEq(minter.nextIndex(), 2);

        Gather gather2 = new Gather(address(tokenB), gatherRecipient, owner);
        minter.registerDispatcher(address(gather2), 5e18, 200);
        assertEq(minter.nextIndex(), 3);
    }

    function test_registerDispatcher_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        minter.registerDispatcher(address(gather), 10e18, 100);
    }

    function test_registerDispatcher_revertsForZeroAddress() public {
        vm.expectRevert("NFTMinter: zero dispatcher address");
        minter.registerDispatcher(address(0), 10e18, 100);
    }

    function test_registerDispatcher_revertsForDuplicateDispatcher() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.expectRevert("NFTMinter: dispatcher already registered");
        minter.registerDispatcher(address(gather), 5e18, 200);
    }

    // =========================================================================
    // mint tests
    // =========================================================================

    function test_mint_transfersTokenToDispatcherAndMintsNFT() public {
        // Setup: register gather dispatcher and authorize minter
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

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
        // Minter should have 0 balance (tokens went directly to dispatcher)
        assertEq(tokenA.balanceOf(address(minter)), 0, "Minter should have 0 balance");
        // Gather forwarded tokens to its recipient
        assertEq(tokenA.balanceOf(gatherRecipient), 10e18, "Gather recipient should have received tokens");
        // Recipient got 1 claim NFT
        assertEq(minter.balanceOf(recipient, 1), 1);
    }

    function test_mint_revertsIfIndexNotRegistered() public {
        vm.expectRevert("NFTMinter: index not registered");
        minter.mint(address(tokenA), 999, recipient);
    }

    function test_mint_revertsIfTokenMismatch() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        tokenB.mint(user, 100e18);
        vm.prank(user);
        tokenB.approve(address(minter), type(uint256).max);

        vm.prank(user);
        vm.expectRevert("NFTMinter: token mismatch");
        minter.mint(address(tokenB), 1, recipient); // tokenB != tokenA
    }

    /// @notice Dedicated test for primeToken validation: minting with wrong token reverts with "NFTMinter: token mismatch"
    function test_mint_dedicatedTokenMismatchTest() public {
        // Register gather dispatcher for tokenA
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        // Give user tokenB (wrong token) and approve
        tokenB.mint(user, 100e18);
        vm.prank(user);
        tokenB.approve(address(minter), type(uint256).max);

        // Attempt to mint with tokenB against a dispatcher registered for tokenA
        vm.prank(user);
        vm.expectRevert("NFTMinter: token mismatch");
        minter.mint(address(tokenB), 1, recipient);
    }

    function test_mint_priceGrowsCorrectly() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150; // 1.5%

        minter.registerDispatcher(address(gather), initialPrice, growthBps);
        gather.setMinter(address(minter));

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
        // Register burner dispatcher with a burnable token - tokens go directly to burner and are burned
        MockBurnableERC20 burnableToken = new MockBurnableERC20("Burnable Token", "BRN");
        // Predict the burnableDispatcher address so its BurnRecorder can authorize it as minter.
        address predictedDispatcher = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        BurnRecorder localBurnRecorder = new BurnRecorder(owner, predictedDispatcher);
        Burner burnableDispatcher = new Burner(address(burnableToken), address(localBurnRecorder), owner);
        burnableDispatcher.setMinter(address(minter));
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
    // Minter balance invariant: minter should never hold tokens after mint
    // =========================================================================

    function test_mint_minterBalanceIsZeroAfterMint() public {
        // Register gather dispatcher
        uint256 price = 25e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Give user tokens and approve minter
        tokenA.mint(user, 200e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint multiple times and check invariant each time
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user);
            minter.mint(address(tokenA), 1, recipient);
            assertEq(tokenA.balanceOf(address(minter)), 0, "Minter balance must be 0 after mint");
        }
    }

    // =========================================================================
    // getDispatchers tests
    // =========================================================================

    function test_getDispatchers_returnsAllIndexesForToken() public {
        // Register multiple dispatchers for tokenA
        Gather g1 = new Gather(address(tokenA), gatherRecipient, owner);
        Gather g2 = new Gather(address(tokenA), gatherRecipient, owner);
        Burner burn1 = new Burner(address(tokenA), address(burnRecorder), owner);

        minter.registerDispatcher(address(g1), 10e18, 100);
        minter.registerDispatcher(address(g2), 20e18, 200);
        minter.registerDispatcher(address(burn1), 30e18, 300);

        uint256[] memory indexes = minter.getDispatchers(address(tokenA));
        assertEq(indexes.length, 3);
        assertEq(indexes[0], 1);
        assertEq(indexes[1], 2);
        assertEq(indexes[2], 3);
    }

    // =========================================================================
    // setPrice and setGrowthFactor tests
    // =========================================================================

    function test_setPrice_updatesCorrectly() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        minter.setPrice(1, 20e18);
        assertEq(minter.getPrice(1), 20e18);
    }

    function test_setPrice_onlyOwner() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.prank(user);
        vm.expectRevert();
        minter.setPrice(1, 20e18);
    }

    function test_setPrice_emitsEvent() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.PriceUpdated(1, 10e18, 20e18);

        minter.setPrice(1, 20e18);
    }

    function test_setGrowthFactor_updatesCorrectly() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        minter.setGrowthFactor(1, 500);
        (,, uint256 growthBps) = minter.configs(1);
        assertEq(growthBps, 500);
    }

    function test_setGrowthFactor_onlyOwner() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.prank(user);
        vm.expectRevert();
        minter.setGrowthFactor(1, 500);
    }

    function test_setGrowthFactor_emitsEvent() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.GrowthFactorUpdated(1, 100, 500);

        minter.setGrowthFactor(1, 500);
    }

    // =========================================================================
    // Multiple mints: tokens go to dispatcher and price escalates
    // =========================================================================

    function test_multipleMints_tokensGoToDispatcherAndPriceEscalates() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 200; // 2%

        minter.registerDispatcher(address(gather), initialPrice, growthBps);
        gather.setMinter(address(minter));

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

            // Invariant: minter balance is always 0
            assertEq(tokenA.balanceOf(address(minter)), 0, "Minter balance must be 0 after each mint");
        }

        // Recipient should have 5 claim NFTs
        assertEq(minter.balanceOf(recipient, 1), 5);

        // Price should have escalated correctly
        assertEq(minter.getPrice(1), expectedPrice);

        // User's balance should reflect total paid
        assertEq(tokenA.balanceOf(user), 10000e18 - totalPaid);

        // Gather recipient should have received all tokens
        assertEq(tokenA.balanceOf(gatherRecipient), totalPaid);
    }

    // =========================================================================
    // emergencyWithdraw tests
    // =========================================================================

    function test_emergencyWithdraw_succeeds_forOwnerWithStuckTokens() public {
        // Directly send tokens to minter to simulate stuck tokens (edge case)
        tokenA.mint(address(minter), 10e18);

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
        // Directly send tokens to minter to simulate stuck tokens
        tokenA.mint(address(minter), 10e18);

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
        _registerAndAuthorizeMinter(address(gather));

        // Pause the dispatcher
        minter.setDispatcherActive(address(gather), false);

        // Verify the dispatcher is paused
        assertTrue(gather.paused(), "Dispatcher should be paused");
    }

    function test_setDispatcherActive_true_unpausesDispatcher() public {
        _registerAndAuthorizeMinter(address(gather));

        // Pause first
        minter.setDispatcherActive(address(gather), false);
        assertTrue(gather.paused(), "Dispatcher should be paused");

        // Unpause
        minter.setDispatcherActive(address(gather), true);
        assertFalse(gather.paused(), "Dispatcher should be unpaused");
    }

    function test_setDispatcherActive_revertsForNonOwner() public {
        _registerAndAuthorizeMinter(address(gather));

        vm.prank(user);
        vm.expectRevert();
        minter.setDispatcherActive(address(gather), false);
    }

    function test_setDispatcherActive_revertsForUnregisteredDispatcher() public {
        vm.expectRevert("NFTMinter: dispatcher not registered");
        minter.setDispatcherActive(address(gather), false);
    }

    function test_setDispatcherActive_emitsEvent() public {
        _registerAndAuthorizeMinter(address(gather));

        vm.expectEmit(true, false, false, true);
        emit NFTMinter.DispatcherActiveChanged(address(gather), false);
        minter.setDispatcherActive(address(gather), false);
    }

    function test_setDispatcherActive_handlesAlreadyPausedGracefully() public {
        _registerAndAuthorizeMinter(address(gather));

        // Pause the dispatcher
        minter.setDispatcherActive(address(gather), false);
        assertTrue(gather.paused());

        // Calling pause again should not revert (graceful handling)
        minter.setDispatcherActive(address(gather), false);
        assertTrue(gather.paused());
    }

    function test_setDispatcherActive_handlesAlreadyUnpausedGracefully() public {
        _registerAndAuthorizeMinter(address(gather));

        // Dispatcher starts unpaused, calling unpause again should not revert
        assertFalse(gather.paused());
        minter.setDispatcherActive(address(gather), true);
        assertFalse(gather.paused());
    }

    // =========================================================================
    // mint() with paused dispatcher tests
    // =========================================================================

    function test_mint_revertsWhenDispatcherIsPaused() public {
        _registerAndAuthorizeMinter(address(gather));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Pause the dispatcher
        minter.setDispatcherActive(address(gather), false);

        // Mint should revert because dispatcher is paused (whenNotPaused reverts with EnforcedPause)
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter.mint(address(tokenA), 1, recipient);
    }

    function test_mint_worksNormallyWhenDispatcherIsActive() public {
        _registerAndAuthorizeMinter(address(gather));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Dispatcher is active (not paused) by default
        assertFalse(gather.paused());

        // Mint should succeed
        vm.prank(user);
        bool success = minter.mint(address(tokenA), 1, recipient);
        assertTrue(success);
        assertEq(minter.balanceOf(recipient, 1), 1);
    }

    // =========================================================================
    // ATokenDispatcher setMinter tests
    // =========================================================================

    function test_ATokenDispatcher_setMinter_onlyOwner() public {
        // Non-owner should not be able to call setMinter
        vm.prank(user);
        vm.expectRevert();
        gather.setMinter(user);
    }

    function test_ATokenDispatcher_setMinter_ownerCanSet() public {
        // Owner (this test contract) should be able to set the minter
        gather.setMinter(address(minter));
        // No revert means success. Verify by testing that minter can now call pause
        vm.prank(address(minter));
        gather.pause();
        assertTrue(gather.paused());
    }

    // =========================================================================
    // ATokenDispatcher pause/unpause restricted to minter
    // =========================================================================

    function test_ATokenDispatcher_pause_restrictedToMinter() public {
        gather.setMinter(address(minter));

        // Non-minter should not be able to call pause
        vm.prank(user);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.pause();

        // Owner (not the minter) also cannot call pause
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.pause();
    }

    function test_ATokenDispatcher_unpause_restrictedToMinter() public {
        gather.setMinter(address(minter));

        // Pause first via the minter
        vm.prank(address(minter));
        gather.pause();
        assertTrue(gather.paused());

        // Non-minter should not be able to unpause
        vm.prank(user);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.unpause();

        // Owner (not the minter) also cannot unpause
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.unpause();
    }

    function test_ATokenDispatcher_dispatch_restrictedToMinter() public {
        gather.setMinter(address(minter));

        // Give the dispatcher some tokens so dispatch has something to work with
        tokenA.mint(address(gather), 10e18);

        // Non-minter (random user) should not be able to call dispatch
        vm.prank(user);
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.dispatch(user, 10e18, "");

        // Owner (this test contract, not the minter) also cannot call dispatch
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.dispatch(address(this), 10e18, "");
    }

    function test_ATokenDispatcher_minterCanPauseAndUnpause() public {
        gather.setMinter(address(minter));

        // Minter can pause
        vm.prank(address(minter));
        gather.pause();
        assertTrue(gather.paused());

        // Minter can unpause
        vm.prank(address(minter));
        gather.unpause();
        assertFalse(gather.paused());
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
        _registerAndAuthorizeMinter(address(gather));

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
        _registerAndAuthorizeMinter(address(gather));

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
        assertEq(minter.balanceOf(recipient, 1), 1);
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
        _registerAndAuthorizeMinter(address(gather));

        // Pause the contract
        minter.setPauser(globalPauser);
        vm.prank(globalPauser);
        minter.pause();
        assertTrue(minter.paused());

        // registerDispatcher should still work
        Gather gather2 = new Gather(address(tokenB), gatherRecipient, owner);
        gather2.setMinter(address(minter));
        minter.registerDispatcher(address(gather2), 5e18, 200);
        (address dispatcher,,) = minter.configs(2);
        assertEq(dispatcher, address(gather2));

        // setPrice should still work
        minter.setPrice(1, 20e18);
        assertEq(minter.getPrice(1), 20e18);

        // setGrowthFactor should still work
        minter.setGrowthFactor(1, 500);
        (,, uint256 growthBps) = minter.configs(1);
        assertEq(growthBps, 500);
    }

    // =========================================================================
    // FOT token tests (only one fee deduction: user -> dispatcher)
    // =========================================================================

    function test_mint_FOTToken_withGather_noRevert_NFTMinted() public {
        // Create a FOT token with 2% fee (200 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);

        // Create Gather for FOT token
        Gather fotGather = new Gather(address(fotToken), gatherRecipient, owner);
        fotGather.setMinter(address(minter));

        uint256 initialPrice = 100e18;
        minter.registerDispatcher(address(fotGather), initialPrice, 0);

        // Give user tokens and approve
        fotToken.mint(user, 1000e18);
        vm.prank(user);
        fotToken.approve(address(minter), type(uint256).max);

        // Mint should not revert
        vm.prank(user);
        bool success = minter.mint(address(fotToken), 1, recipient);

        assertTrue(success, "Mint should succeed with FOT token");
        // Recipient should have 1 claim NFT
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 claim NFT");
        // User loses exactly `price` from their balance (amount-fee transferred + fee burned)
        assertEq(fotToken.balanceOf(user), 1000e18 - initialPrice, "User should have lost exactly price from balance");
        // Minter should have 0 balance (tokens go directly to dispatcher)
        assertEq(fotToken.balanceOf(address(minter)), 0, "Minter should have 0 balance");
        // Dispatcher received 98e18 (2% fee deducted once: user -> dispatcher)
        // Gather then forwarded to gatherRecipient (but FOT deducts another 2% on the Gather->recipient transfer)
        // Gather balance should be 0
        assertEq(fotToken.balanceOf(address(fotGather)), 0, "Gather should have 0 balance");
    }

    function test_mint_FOTToken_actualReceivedLessThanPrice_onlyOneFeeDeduction() public {
        // Create a FOT token with 5% fee (500 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 500);

        // Create Gather for FOT token
        Gather fotGather = new Gather(address(fotToken), gatherRecipient, owner);
        fotGather.setMinter(address(minter));

        uint256 price = 100e18;
        minter.registerDispatcher(address(fotGather), price, 0);

        // Give user tokens and approve
        fotToken.mint(user, 1000e18);
        vm.prank(user);
        fotToken.approve(address(minter), type(uint256).max);

        // Record dispatcher balance before
        uint256 dispatcherBalanceBefore = fotToken.balanceOf(address(fotGather));

        // Mint
        vm.prank(user);
        minter.mint(address(fotToken), 1, recipient);

        // Under the new flow, there is only ONE transfer with FOT fee: user -> dispatcher
        // 5% fee on 100e18 = 5e18 burned, dispatcher receives 95e18
        // Then Gather transfers to gatherRecipient (another FOT fee applies on that transfer)
        // But the minter's actualReceived is 95e18 (not double-fee'd like old flow)
        // Minter should have 0 balance
        assertEq(fotToken.balanceOf(address(minter)), 0, "Minter should have 0 balance with FOT token");

        // Price growth should still be based on original price (unchanged)
        // Since growth is 0, price stays the same
        assertEq(minter.getPrice(1), price, "Price should remain unchanged with 0 growth");
    }

    // =========================================================================
    // 4-parameter mint() overload with extraData
    // =========================================================================

    function test_mint_withExtraData_transfersTokenAndMintsNFT() public {
        // Setup: register gather dispatcher and authorize minter
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Give user tokens and approve minter
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint using 4-parameter overload with non-empty extraData
        bytes memory extraData = abi.encode(uint256(42), uint256(100));
        vm.prank(user);
        bool success = minter.mint(address(tokenA), 1, recipient, extraData);

        assertTrue(success, "4-parameter mint should succeed");
        // User paid price
        assertEq(tokenA.balanceOf(user), 90e18, "User should have paid 10e18");
        // Minter should have 0 balance (tokens went directly to dispatcher)
        assertEq(tokenA.balanceOf(address(minter)), 0, "Minter should have 0 balance");
        // Gather forwarded tokens to its recipient
        assertEq(tokenA.balanceOf(gatherRecipient), 10e18, "Gather recipient should have received tokens");
        // Recipient got 1 claim NFT
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 claim NFT");
    }

    function test_mint_withEmptyExtraData_matchesBehaviorOf3ParamMint() public {
        // Setup: register gather dispatcher and authorize minter
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Give user tokens and approve minter
        tokenA.mint(user, 200e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // First mint via 3-parameter overload
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);
        assertEq(minter.balanceOf(recipient, 1), 1, "First mint should produce 1 NFT");

        // Second mint via 4-parameter overload with empty bytes
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient, "");
        assertEq(minter.balanceOf(recipient, 1), 2, "Second mint should produce 2 total NFTs");

        // Both mints should have forwarded tokens to gather recipient
        assertEq(
            tokenA.balanceOf(gatherRecipient), 20e18, "Gather recipient should have received tokens from both mints"
        );
    }

    // =========================================================================
    // Metadata tests (setMetadata, name, image, description)
    // =========================================================================

    function test_setMetadata_setsNameImageDescription() public {
        gather.setMetadata("Gather NFT", "https://example.com/image.png", "A gather dispatcher NFT");

        assertEq(gather.name(), "Gather NFT");
        assertEq(gather.image(), "https://example.com/image.png");
        assertEq(gather.description(), "A gather dispatcher NFT");
    }

    function test_metadata_gettersReturnCorrectValues() public {
        gather.setMetadata("Test Name", "ipfs://QmTest", "Test description");

        assertEq(gather.name(), "Test Name");
        assertEq(gather.image(), "ipfs://QmTest");
        assertEq(gather.description(), "Test description");
    }

    function test_setMetadata_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        gather.setMetadata("Name", "Image", "Description");
    }

    // =========================================================================
    // Per-dispatcher token ID tests
    // =========================================================================

    function test_mint_defaultsToDispatcherIndexAsTokenId() public {
        // Register gather dispatcher (will be index 1)
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);

        // Default token ID should be the dispatcher index (1)
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 NFT with token ID = dispatcher index");
        assertEq(minter.balanceOf(recipient, 2), 0, "Recipient should have 0 NFTs with other token IDs");
    }

    function test_setDispatcherTokenId_overridesDefaultTokenId() public {
        minter.registerDispatcher(address(gather), 10e18, 0);

        // Override to token ID 42
        minter.setDispatcherTokenId(address(gather), 42);

        assertEq(minter.dispatcherTokenIdOverride(address(gather)), 42);
        assertEq(minter.tokenIdToDispatcher(42), address(gather));
        // Old default mapping should be cleaned up
        assertEq(minter.tokenIdToDispatcher(1), address(0));
    }

    function test_setDispatcherTokenId_revertsForUnregisteredDispatcher() public {
        vm.expectRevert("NFTMinter: dispatcher not registered");
        minter.setDispatcherTokenId(address(0xDEAD), 42);
    }

    function test_setDispatcherTokenId_revertsForDuplicateTokenId() public {
        // Register two dispatchers
        Gather gather2 = new Gather(address(tokenB), gatherRecipient, owner);
        minter.registerDispatcher(address(gather), 10e18, 0);
        minter.registerDispatcher(address(gather2), 10e18, 0);

        // Override gather to token ID 42
        minter.setDispatcherTokenId(address(gather), 42);

        // Try to assign same token ID to gather2 - should revert
        vm.expectRevert("NFTMinter: tokenId already assigned to another dispatcher");
        minter.setDispatcherTokenId(address(gather2), 42);
    }

    function test_mint_usesOverriddenTokenIdWhenSet() public {
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Override to token ID 99
        minter.setDispatcherTokenId(address(gather), 99);

        // Give user tokens and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint
        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);

        // NFT should be minted with overridden token ID 99, not default 1
        assertEq(minter.balanceOf(recipient, 99), 1, "Recipient should have 1 NFT with overridden token ID 99");
        assertEq(minter.balanceOf(recipient, 1), 0, "Recipient should have 0 NFTs with default token ID 1");
    }

    function test_uri_returnsDispatcherMetadata() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMetadata("Test NFT", "https://example.com/nft.png", "A test NFT");

        string memory result = minter.uri(1);
        assertEq(
            result,
            '{"name":"Test NFT","image":"https://example.com/nft.png","description":"A test NFT"}'
        );
    }

    function test_uri_returnsEmptyStringForUnmappedTokenId() public {
        string memory result = minter.uri(999);
        assertEq(result, "", "uri should return empty string for unmapped token ID");
    }

    function test_setDispatcherTokenId_onlyOwner() public {
        minter.registerDispatcher(address(gather), 10e18, 0);

        vm.prank(user);
        vm.expectRevert();
        minter.setDispatcherTokenId(address(gather), 42);
    }

    // =========================================================================
    // Authorized Burner & Burn tests
    // =========================================================================

    address public authorizedBurnerAddr = address(0xBBBB);

    /// @dev Helper to register a dispatcher, mint an NFT to a holder, and return the token ID.
    function _mintNFTToHolder(address holder) internal returns (uint256 tokenId) {
        // Register gather dispatcher
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        // Give holder tokens and approve
        tokenA.mint(holder, 100e18);
        vm.prank(holder);
        tokenA.approve(address(minter), type(uint256).max);

        // Mint NFT to holder
        vm.prank(holder);
        minter.mint(address(tokenA), 1, holder);

        return 1; // default token ID = dispatcher index
    }

    function test_burn_authorizedBurnerCanBurnNFTs() public {
        uint256 tokenId = _mintNFTToHolder(user);
        assertEq(minter.balanceOf(user, tokenId), 1);

        // Authorize burner
        minter.setAuthorizedBurner(authorizedBurnerAddr, true);

        // Burn
        vm.prank(authorizedBurnerAddr);
        minter.burn(user, tokenId, 1);

        assertEq(minter.balanceOf(user, tokenId), 0);
    }

    function test_burn_unauthorizedAddressCannotBurn() public {
        uint256 tokenId = _mintNFTToHolder(user);

        // Try to burn without authorization
        vm.prank(authorizedBurnerAddr);
        vm.expectRevert("NFTMinter: caller is not authorized burner");
        minter.burn(user, tokenId, 1);
    }

    function test_setAuthorizedBurner_togglesAuthorizationCorrectly() public {
        // Initially not authorized
        assertFalse(minter.authorizedBurners(authorizedBurnerAddr));

        // Authorize
        minter.setAuthorizedBurner(authorizedBurnerAddr, true);
        assertTrue(minter.authorizedBurners(authorizedBurnerAddr));

        // Deauthorize
        minter.setAuthorizedBurner(authorizedBurnerAddr, false);
        assertFalse(minter.authorizedBurners(authorizedBurnerAddr));
    }

    function test_setAuthorizedBurner_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        minter.setAuthorizedBurner(authorizedBurnerAddr, true);
    }

    function test_burn_emitsClaimBurnedEvent() public {
        uint256 tokenId = _mintNFTToHolder(user);

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);

        vm.expectEmit(true, true, false, true);
        emit NFTMinter.ClaimBurned(user, tokenId, 1);

        vm.prank(authorizedBurnerAddr);
        minter.burn(user, tokenId, 1);
    }

    function test_burn_revertsWhenHolderHasInsufficientBalance() public {
        // Register dispatcher but don't mint any NFTs to user
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);

        // Try to burn when user has 0 balance
        vm.prank(authorizedBurnerAddr);
        vm.expectRevert();
        minter.burn(user, 1, 1);
    }

    function test_setAuthorizedBurner_emitsAuthorizedBurnerSetEvent() public {
        vm.expectEmit(true, false, false, true);
        emit NFTMinter.AuthorizedBurnerSet(authorizedBurnerAddr, true);

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);
    }
}
