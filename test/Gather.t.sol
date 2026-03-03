// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Gather} from "../src/dispatchers/Gather.sol";
import {NFTMinter} from "../src/NFTMinter.sol";
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

contract GatherTest is Test {
    Gather public gather;
    MockERC20 public token;

    address public owner = address(this);
    address public minter = address(0xABCDEF);
    address public recipientAddr = address(0xCAFE);

    function setUp() public {
        token = new MockERC20("Gather Token", "GTH");
        gather = new Gather(address(token), recipientAddr, "Gather GTH", owner);
        // Set the minter so dispatch() can be called via onlyMinter
        gather.setMinter(minter);
    }

    // =========================================================================
    // primeToken tests
    // =========================================================================

    function test_primeToken_returnsCorrectAddress() public view {
        assertEq(gather.primeToken(), address(token));
    }

    // =========================================================================
    // flavour tests
    // =========================================================================

    function test_flavour_returnsCorrectString() public view {
        assertEq(gather.flavour(), "Gather GTH");
    }

    // =========================================================================
    // recipient tests
    // =========================================================================

    function test_recipient_returnsInitialRecipientAddress() public view {
        assertEq(gather.recipient(), recipientAddr);
    }

    // =========================================================================
    // dispatch tests (tokens already on gather, just forward to recipient)
    // =========================================================================

    /// @notice Verifies that dispatch transfers tokens to the recipient.
    function test_dispatch_transfersTokenToRecipient() public {
        uint256 amount = 100e18;

        // Tokens are already on gather (sent by minter's transferFrom)
        token.mint(address(gather), amount);

        // Dispatch (called by minter)
        vm.prank(minter);
        gather.dispatch(minter, amount, "");

        // After dispatch, the recipient should have the tokens
        assertEq(token.balanceOf(recipientAddr), amount, "Recipient should have received the tokens");
        // Gather contract should have 0 balance (tokens are forwarded, not held)
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance after forwarding");
    }

    /// @notice Verifies that dispatch forwards all tokens from gather to recipient.
    function test_dispatch_forwardsTokensToRecipient() public {
        uint256 amount = 50e18;

        // Tokens already on gather
        token.mint(address(gather), amount);

        vm.prank(minter);
        gather.dispatch(minter, amount, "");

        // Gather should have no tokens (they were forwarded)
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance");
        // Recipient should have the tokens
        assertEq(token.balanceOf(recipientAddr), amount, "Recipient should have received tokens");
    }

    /// @notice Verifies that dispatch reverts when the dispatcher is paused.
    function test_dispatch_revertsWhenPaused() public {
        uint256 amount = 100e18;

        token.mint(address(gather), amount);

        // Pause the dispatcher
        vm.prank(minter);
        gather.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gather.dispatch(minter, amount, "");
    }

    /// @notice Verifies that dispatch reverts when called by non-minter.
    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;

        token.mint(address(gather), amount);

        // Non-minter cannot call dispatch
        vm.prank(address(0xDEAD));
        vm.expectRevert("ATokenDispatcher: caller is not minter");
        gather.dispatch(address(0xDEAD), amount, "");
    }

    // =========================================================================
    // setRecipient tests
    // =========================================================================

    function test_setRecipient_updatesRecipientAddress() public {
        address newRecipient = address(0xBEEF);

        gather.setRecipient(newRecipient);

        assertEq(gather.recipient(), newRecipient, "Recipient should be updated");
    }

    function test_setRecipient_emitsRecipientUpdatedEvent() public {
        address newRecipient = address(0xBEEF);

        vm.expectEmit(true, true, false, true);
        emit Gather.RecipientUpdated(recipientAddr, newRecipient);

        gather.setRecipient(newRecipient);
    }

    function test_setRecipient_revertsWhenCalledByNonOwner() public {
        address nonOwner = address(0xDEAD);

        vm.prank(nonOwner);
        vm.expectRevert();
        gather.setRecipient(address(0xBEEF));
    }

    function test_setRecipient_revertsWithZeroAddress() public {
        vm.expectRevert("Gather: zero recipient address");
        gather.setRecipient(address(0));
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroRecipientAddress() public {
        vm.expectRevert("Gather: zero recipient address");
        new Gather(address(token), address(0), "Gather GTH", owner);
    }

    // =========================================================================
    // Integration test: NFTMinter -> Gather -> Recipient
    // =========================================================================

    /// @notice Full integration: register Gather with NFTMinter, user mints NFT, token arrives at recipient.
    function test_integration_mintNFTWithGatherDispatcher() public {
        // Deploy NFTMinter
        NFTMinter nftMinter = new NFTMinter(owner);

        // Register the Gather dispatcher with NFTMinter
        uint256 initialPrice = 10e18;
        nftMinter.registerDispatcher(address(gather), initialPrice, 0);

        // Authorize NFTMinter as the minter on Gather (so it can pause/unpause and call dispatch)
        gather.setMinter(address(nftMinter));

        // Setup user with tokens
        address user = address(0xBEEF);
        token.mint(user, 100e18);
        vm.prank(user);
        token.approve(address(nftMinter), type(uint256).max);

        // User mints an NFT
        address nftRecipient = address(0xFACE);
        vm.prank(user);
        bool success = nftMinter.mint(address(token), 1, nftRecipient);

        // Verify success
        assertTrue(success, "Mint should succeed");

        // Verify user paid the price
        assertEq(token.balanceOf(user), 90e18, "User should have paid 10e18");

        // Verify tokens arrived at the Gather recipient (not stuck in minter or gather)
        assertEq(token.balanceOf(recipientAddr), 10e18, "Gather recipient should have received the tokens");
        assertEq(token.balanceOf(address(nftMinter)), 0, "NFTMinter should have 0 balance");
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance");

        // Verify NFT was minted
        assertEq(
            nftMinter.balanceOf(nftRecipient, nftMinter.CLAIM_TOKEN_ID()), 1, "NFT recipient should have 1 claim NFT"
        );
    }

    // =========================================================================
    // FOT token dispatch tests (only one fee: gather -> recipient)
    // =========================================================================

    function test_dispatch_FOTToken_noRevert_recipientGetsTokensAfterSingleFee() public {
        // Create a FOT token with 2% fee (200 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        Gather fotGather = new Gather(address(fotToken), recipientAddr, "Gather FOT", owner);
        fotGather.setMinter(minter);

        uint256 amount = 100e18;
        // Tokens already on gather (simulating direct transfer from minter)
        fotToken.mint(address(fotGather), amount);

        // Should not revert
        vm.prank(minter);
        fotGather.dispatch(minter, amount, "");

        // transfer: Gather -> recipient, 2% fee on 100e18 = 2e18 burned, recipient receives 98e18
        // Only ONE fee deduction (gather -> recipient), not double fee like before
        uint256 expectedRecipientBalance = 98e18;

        assertEq(
            fotToken.balanceOf(recipientAddr),
            expectedRecipientBalance,
            "Recipient should receive tokens after single FOT fee"
        );
    }

    function test_dispatch_FOTToken_zeroTokensStuckInGather() public {
        // Create a FOT token with 3% fee (300 bps)
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 300);
        Gather fotGather = new Gather(address(fotToken), recipientAddr, "Gather FOT", owner);
        fotGather.setMinter(minter);

        uint256 amount = 100e18;
        // Tokens already on gather
        fotToken.mint(address(fotGather), amount);

        vm.prank(minter);
        fotGather.dispatch(minter, amount, "");

        // Gather should have 0 balance (all forwarded to recipient)
        assertEq(fotToken.balanceOf(address(fotGather)), 0, "Gather should have 0 balance after FOT dispatch");
    }
}
