// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Gather} from "../src/dispatchers/Gather.sol";
import {NFTMinter} from "../src/NFTMinter.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
    // dispatch tests
    // =========================================================================

    /// @notice Verifies that dispatch transfers tokens to the recipient.
    function test_dispatch_transfersTokenToRecipient() public {
        uint256 amount = 100e18;

        // Mint tokens to the minter address
        token.mint(minter, amount);

        // Approve gather to pull from minter
        vm.prank(minter);
        token.approve(address(gather), type(uint256).max);

        // Dispatch
        gather.dispatch(minter, amount);

        // After dispatch, the recipient should have the tokens
        assertEq(token.balanceOf(recipientAddr), amount, "Recipient should have received the tokens");
        // Gather contract should have 0 balance (tokens are forwarded, not held)
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance after forwarding");
    }

    /// @notice Verifies that dispatch pulls tokens from the minter.
    function test_dispatch_pullsTokensFromMinter() public {
        uint256 amount = 50e18;

        token.mint(minter, amount);

        vm.prank(minter);
        token.approve(address(gather), type(uint256).max);

        gather.dispatch(minter, amount);

        // Minter should have no tokens left (they were pulled)
        assertEq(token.balanceOf(minter), 0, "Minter should have 0 balance after dispatch");
        // Gather should have no tokens (they were forwarded)
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance");
    }

    /// @notice Verifies that dispatch reverts when the dispatcher is paused.
    function test_dispatch_revertsWhenPaused() public {
        uint256 amount = 100e18;

        token.mint(minter, amount);

        vm.prank(minter);
        token.approve(address(gather), type(uint256).max);

        // Set the minter on the dispatcher so it can be paused
        gather.setMinter(address(this));
        gather.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        gather.dispatch(minter, amount);
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

        // Authorize NFTMinter as the minter on Gather (so it can pause/unpause)
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
        assertEq(nftMinter.balanceOf(nftRecipient, nftMinter.CLAIM_TOKEN_ID()), 1, "NFT recipient should have 1 claim NFT");
    }
}
