// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GatherV2} from "../../src/V2/dispatchers/GatherV2.sol";
import {NFTMinterV2} from "../../src/V2/NFTMinterV2.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockFOTToken} from "../mocks/MockFOTToken.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract GatherV2Test is Test {
    GatherV2 public gather;
    MockERC20 public token;

    address public owner = address(this);
    address public minter = address(0xABCDEF);
    address public recipientAddr = address(0xCAFE);

    function setUp() public {
        token = new MockERC20("Gather Token", "GTH");
        gather = new GatherV2(address(token), recipientAddr, owner);
        // Set the minter so dispatch() can be called via onlyMinter
        gather.setMinter(minter);
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

    function test_dispatch_transfersTokenToRecipient() public {
        uint256 amount = 100e18;
        token.mint(address(gather), amount);

        vm.prank(minter);
        gather.dispatch(minter, amount, "");

        assertEq(token.balanceOf(recipientAddr), amount, "Recipient should have received the tokens");
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance after forwarding");
    }

    function test_dispatch_forwardsTokensToRecipient() public {
        uint256 amount = 50e18;
        token.mint(address(gather), amount);

        vm.prank(minter);
        gather.dispatch(minter, amount, "");

        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance");
        assertEq(token.balanceOf(recipientAddr), amount, "Recipient should have received tokens");
    }

    function test_dispatch_revertsWhenPaused() public {
        uint256 amount = 100e18;
        token.mint(address(gather), amount);

        vm.prank(minter);
        gather.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        gather.dispatch(minter, amount, "");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e18;
        token.mint(address(gather), amount);

        vm.prank(address(0xDEAD));
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
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
        emit GatherV2.RecipientUpdated(recipientAddr, newRecipient);
        gather.setRecipient(newRecipient);
    }

    function test_setRecipient_revertsWhenCalledByNonOwner() public {
        address nonOwner = address(0xDEAD);
        vm.prank(nonOwner);
        vm.expectRevert();
        gather.setRecipient(address(0xBEEF));
    }

    function test_setRecipient_revertsWithZeroAddress() public {
        vm.expectRevert("GatherV2: zero recipient address");
        gather.setRecipient(address(0));
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroRecipientAddress() public {
        vm.expectRevert("GatherV2: zero recipient address");
        new GatherV2(address(token), address(0), owner);
    }

    // =========================================================================
    // FOT token dispatch tests
    // =========================================================================

    function test_dispatch_FOTToken_recipientGetsTokensAfterSingleFee() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);
        GatherV2 fotGather = new GatherV2(address(fotToken), recipientAddr, owner);
        fotGather.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotGather), amount);

        vm.prank(minter);
        fotGather.dispatch(minter, amount, "");

        uint256 expectedRecipientBalance = 98e18;
        assertEq(
            fotToken.balanceOf(recipientAddr),
            expectedRecipientBalance,
            "Recipient should receive tokens after single FOT fee"
        );
    }

    function test_dispatch_FOTToken_zeroTokensStuckInGather() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 300);
        GatherV2 fotGather = new GatherV2(address(fotToken), recipientAddr, owner);
        fotGather.setMinter(minter);

        uint256 amount = 100e18;
        fotToken.mint(address(fotGather), amount);

        vm.prank(minter);
        fotGather.dispatch(minter, amount, "");

        assertEq(fotToken.balanceOf(address(fotGather)), 0, "Gather should have 0 balance after FOT dispatch");
    }

    // =========================================================================
    // Integration test: NFTMinterV2 -> GatherV2 -> Recipient
    // =========================================================================

    function test_integration_mintNFTWithGatherV2Dispatcher() public {
        NFTMinterV2 nftMinter = new NFTMinterV2(owner);

        uint256 initialPrice = 10e18;
        nftMinter.registerDispatcher(address(gather), initialPrice, 0);
        gather.setMinter(address(nftMinter));

        address user = address(0xBEEF);
        token.mint(user, 100e18);
        vm.prank(user);
        token.approve(address(nftMinter), type(uint256).max);

        address nftRecipient = address(0xFACE);
        vm.prank(user);
        bool success = nftMinter.mint(1, nftRecipient);

        assertTrue(success, "Mint should succeed");
        assertEq(token.balanceOf(user), 90e18, "User should have paid 10e18");
        assertEq(token.balanceOf(recipientAddr), 10e18, "Gather recipient should have received the tokens");
        assertEq(token.balanceOf(address(nftMinter)), 0, "NFTMinterV2 should have 0 balance");
        assertEq(token.balanceOf(address(gather)), 0, "Gather should have 0 balance");
        assertEq(nftMinter.balanceOf(nftRecipient, 1), 1, "NFT recipient should have 1 claim NFT");
    }
}
