// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMinterV2} from "../../src/V2/NFTMinterV2.sol";
import {GatherV2} from "../../src/V2/dispatchers/GatherV2.sol";
import {ATokenDispatcherV2} from "../../src/V2/dispatchers/ATokenDispatcherV2.sol";
import {BurnerV2} from "../../src/V2/dispatchers/BurnerV2.sol";
import {BurnRecorder} from "../../src/BurnRecorder.sol";
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

/// @dev Mock ERC20 with burn capability for BurnerV2 dispatcher tests.
contract MockBurnableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract NFTMinterV2Test is Test {
    NFTMinterV2 public minter;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    GatherV2 public gather;
    BurnerV2 public burner;
    BurnRecorder public burnRecorder;

    address public owner = address(this);
    address public user = address(0xBEEF);
    address public recipient = address(0xCAFE);
    address public gatherRecipient = address(0xFEED);

    function setUp() public {
        minter = new NFTMinterV2(owner);
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        burnRecorder = new BurnRecorder(owner);

        // Create V2 dispatchers
        gather = new GatherV2(address(tokenA), gatherRecipient, owner);
        burner = new BurnerV2(address(tokenA), address(burnRecorder), owner);
        burnRecorder.setBurner(address(burner), true);
    }

    // =========================================================================
    // registerDispatcher tests
    // =========================================================================

    function test_registerDispatcher_createsCorrectConfig() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150;

        minter.registerDispatcher(address(gather), initialPrice, growthBps);

        (address dispatcher, uint256 price, uint256 growthBasisPoints,) = minter.configs(1);
        assertEq(dispatcher, address(gather));
        assertEq(price, initialPrice);
        assertEq(growthBasisPoints, growthBps);
    }

    function test_registerDispatcher_updatesMappings() public {
        minter.registerDispatcher(address(gather), 10e18, 150);

        assertEq(minter.dispatcherToIndex(address(gather)), 1);
        assertEq(minter.tokenIdToDispatcher(1), address(gather));
    }

    function test_registerDispatcher_emitsEvent() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150;

        vm.expectEmit(true, true, false, true);
        emit NFTMinterV2.DispatcherRegistered(1, address(gather), initialPrice, growthBps);

        minter.registerDispatcher(address(gather), initialPrice, growthBps);
    }

    function test_registerDispatcher_incrementsNextIndex() public {
        assertEq(minter.nextIndex(), 1);

        minter.registerDispatcher(address(gather), 10e18, 100);
        assertEq(minter.nextIndex(), 2);

        GatherV2 gather2 = new GatherV2(address(tokenB), gatherRecipient, owner);
        minter.registerDispatcher(address(gather2), 5e18, 200);
        assertEq(minter.nextIndex(), 3);
    }

    function test_registerDispatcher_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        minter.registerDispatcher(address(gather), 10e18, 100);
    }

    function test_registerDispatcher_revertsForZeroAddress() public {
        vm.expectRevert("NFTMinterV2: zero dispatcher address");
        minter.registerDispatcher(address(0), 10e18, 100);
    }

    function test_registerDispatcher_revertsForDuplicateDispatcher() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.expectRevert("NFTMinterV2: dispatcher already registered");
        minter.registerDispatcher(address(gather), 5e18, 200);
    }

    // =========================================================================
    // primeToken invariant — mint always uses dispatcher's prime token (H-01 fix)
    // =========================================================================

    function test_mint_usesDispatcherPrimeToken() public {
        // Register gather (internally uses tokenA) — mint always uses tokenA from dispatcher
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        // Give user tokenA and approve
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        bool success = minter.mint(1, recipient);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user), 90e18);
        assertEq(tokenA.balanceOf(gatherRecipient), 10e18);
        assertEq(minter.balanceOf(recipient, 1), 1);
    }

    function test_mint_transfersTokenToDispatcherAndMintsNFT() public {
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        bool success = minter.mint(1, recipient);

        assertTrue(success);
        assertEq(tokenA.balanceOf(user), 90e18);
        assertEq(tokenA.balanceOf(address(minter)), 0, "Minter should have 0 balance");
        assertEq(tokenA.balanceOf(gatherRecipient), 10e18, "Gather recipient should have received tokens");
        assertEq(minter.balanceOf(recipient, 1), 1);
    }

    function test_mint_revertsIfIndexNotRegistered() public {
        vm.expectRevert("NFTMinterV2: index not registered");
        minter.mint(999, recipient);
    }

    function test_mint_priceGrowsCorrectly() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 150;

        minter.registerDispatcher(address(gather), initialPrice, growthBps);
        gather.setMinter(address(minter));

        tokenA.mint(user, 1000e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        // First mint at 10e18
        vm.prank(user);
        minter.mint(1, recipient);
        uint256 expectedPrice = initialPrice + (initialPrice * growthBps) / 10000;
        assertEq(minter.getPrice(1), expectedPrice);

        // Second mint at new price
        vm.prank(user);
        minter.mint(1, recipient);
        uint256 expectedPrice2 = expectedPrice + (expectedPrice * growthBps) / 10000;
        assertEq(minter.getPrice(1), expectedPrice2);
    }

    function test_mint_invokesDispatcher() public {
        MockBurnableERC20 burnableToken = new MockBurnableERC20("Burnable Token", "BRN");
        BurnRecorder localBurnRecorder = new BurnRecorder(owner);
        BurnerV2 burnableDispatcher = new BurnerV2(address(burnableToken), address(localBurnRecorder), owner);
        localBurnRecorder.setBurner(address(burnableDispatcher), true);
        burnableDispatcher.setMinter(address(minter));
        minter.registerDispatcher(address(burnableDispatcher), 10e18, 0);

        burnableToken.mint(user, 100e18);
        vm.prank(user);
        burnableToken.approve(address(minter), type(uint256).max);

        vm.prank(user);
        minter.mint(1, recipient);

        assertEq(burnableToken.balanceOf(address(burnableDispatcher)), 0);
        assertEq(burnableToken.balanceOf(address(minter)), 0);
        assertEq(burnableToken.totalSupply(), 90e18);
    }

    function test_mint_minterBalanceIsZeroAfterMint() public {
        uint256 price = 25e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        tokenA.mint(user, 200e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user);
            minter.mint(1, recipient);
            assertEq(tokenA.balanceOf(address(minter)), 0, "Minter balance must be 0 after mint");
        }
    }

    // =========================================================================
    // setAuthorizedMinter tests
    // =========================================================================

    function test_setAuthorizedMinter_ownerCanAuthorize() public {
        address minterAddr = address(0xABC);
        minter.setAuthorizedMinter(minterAddr, true);
        assertTrue(minter.authorizedMinters(minterAddr));
    }

    function test_setAuthorizedMinter_ownerCanDeauthorize() public {
        address minterAddr = address(0xABC);
        minter.setAuthorizedMinter(minterAddr, true);
        assertTrue(minter.authorizedMinters(minterAddr));

        minter.setAuthorizedMinter(minterAddr, false);
        assertFalse(minter.authorizedMinters(minterAddr));
    }

    function test_setAuthorizedMinter_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert();
        minter.setAuthorizedMinter(address(0xABC), true);
    }

    function test_setAuthorizedMinter_emitsEvent() public {
        address minterAddr = address(0xABC);

        vm.expectEmit(true, false, false, true);
        emit NFTMinterV2.AuthorizedMinterSet(minterAddr, true);

        minter.setAuthorizedMinter(minterAddr, true);
    }

    // =========================================================================
    // mintFor tests
    // =========================================================================

    function test_mintFor_authorizedMinterCanMint() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);

        // Register a dispatcher
        minter.registerDispatcher(address(gather), 10e18, 100);

        // Authorized minter mints for recipient
        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);

        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 NFT");
    }

    function test_mintFor_nonAuthorizedReverts() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        vm.prank(user);
        vm.expectRevert("NFTMinterV2: caller is not authorized minter");
        minter.mintFor(1, recipient);
    }

    function test_mintFor_mintsCorrectTokenId() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);

        // Register two dispatchers
        GatherV2 gather2 = new GatherV2(address(tokenB), gatherRecipient, owner);
        minter.registerDispatcher(address(gather), 10e18, 0);
        minter.registerDispatcher(address(gather2), 5e18, 0);

        // Mint for index 2
        vm.prank(authorizedAddr);
        minter.mintFor(2, recipient);

        assertEq(minter.balanceOf(recipient, 1), 0, "Recipient should have 0 NFTs of token ID 1");
        assertEq(minter.balanceOf(recipient, 2), 1, "Recipient should have 1 NFT of token ID 2");
    }

    function test_mintFor_doesNotTransferTokens() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        // Authorized minter has no tokens
        assertEq(tokenA.balanceOf(authorizedAddr), 0);

        // mintFor should succeed without any token transfer
        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);

        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 NFT");
        // No tokens moved
        assertEq(tokenA.balanceOf(gatherRecipient), 0, "No tokens should have been forwarded");
        assertEq(tokenA.balanceOf(address(minter)), 0, "Minter should have 0 balance");
    }

    function test_mintFor_doesNotCallDispatch() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);

        // Register a burner dispatcher — if dispatch were called with no tokens, it would fail
        MockBurnableERC20 burnableToken = new MockBurnableERC20("Burnable Token", "BRN");
        BurnRecorder localBurnRecorder = new BurnRecorder(owner);
        BurnerV2 burnableDispatcher = new BurnerV2(address(burnableToken), address(localBurnRecorder), owner);
        localBurnRecorder.setBurner(address(burnableDispatcher), true);
        burnableDispatcher.setMinter(address(minter));
        minter.registerDispatcher(address(burnableDispatcher), 10e18, 0);

        // mintFor should succeed without calling dispatch (which would revert if called)
        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);

        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 NFT");
    }

    function test_mintFor_doesNotUpdatePrice() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);

        uint256 initialPrice = 10e18;
        uint256 growthBps = 1000; // 10%
        minter.registerDispatcher(address(gather), initialPrice, growthBps);

        // Mint via mintFor
        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);

        // Price should NOT have changed
        assertEq(minter.getPrice(1), initialPrice, "Price should not change after mintFor");
    }

    function test_mintFor_revertsForUnregisteredIndex() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);

        vm.prank(authorizedAddr);
        vm.expectRevert("NFTMinterV2: index not registered");
        minter.mintFor(999, recipient);
    }

    function test_mintFor_multipleMints() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);
        minter.registerDispatcher(address(gather), 10e18, 500);

        uint256 priceBefore = minter.getPrice(1);

        // Mint multiple
        vm.startPrank(authorizedAddr);
        minter.mintFor(1, recipient);
        minter.mintFor(1, recipient);
        minter.mintFor(1, recipient);
        vm.stopPrank();

        assertEq(minter.balanceOf(recipient, 1), 3, "Recipient should have 3 NFTs");
        assertEq(minter.getPrice(1), priceBefore, "Price should not have changed");
    }

    function test_mintFor_emitsClaimMintedForEvent() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);
        minter.registerDispatcher(address(gather), 10e18, 0);

        vm.expectEmit(true, true, true, true);
        emit NFTMinterV2.ClaimMintedFor(recipient, 1, authorizedAddr);

        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);
    }

    function test_mintFor_updatesTotalSupply() public {
        address authorizedAddr = address(0xABC);
        minter.setAuthorizedMinter(authorizedAddr, true);
        minter.registerDispatcher(address(gather), 10e18, 0);

        assertEq(minter.totalSupply(1), 0, "totalSupply should be 0 before mint");

        vm.prank(authorizedAddr);
        minter.mintFor(1, recipient);

        assertEq(minter.totalSupply(1), 1, "totalSupply should be 1 after mintFor");
    }

    // =========================================================================
    // replaceDispatcher tests
    // =========================================================================

    function test_replaceDispatcher_ownerCanReplace() public {
        minter.registerDispatcher(address(gather), 10e18, 150);

        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);

        minter.replaceDispatcher(1, address(newGather));

        (address dispatcher,,,) = minter.configs(1);
        assertEq(dispatcher, address(newGather), "Config should point to new dispatcher");
    }

    function test_replaceDispatcher_nonOwnerReverts() public {
        minter.registerDispatcher(address(gather), 10e18, 150);

        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);

        vm.prank(user);
        vm.expectRevert();
        minter.replaceDispatcher(1, address(newGather));
    }

    function test_replaceDispatcher_validatesIndexRegistered() public {
        vm.expectRevert("NFTMinterV2: index not registered");
        minter.replaceDispatcher(999, address(0x1234));
    }

    function test_replaceDispatcher_updatesAllMappings() public {
        minter.registerDispatcher(address(gather), 10e18, 150);

        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);

        minter.replaceDispatcher(1, address(newGather));

        // configs updated
        (address dispatcher,,,) = minter.configs(1);
        assertEq(dispatcher, address(newGather));

        // dispatcherToIndex: old cleared, new set
        assertEq(minter.dispatcherToIndex(address(gather)), 0, "Old dispatcher index should be cleared");
        assertEq(minter.dispatcherToIndex(address(newGather)), 1, "New dispatcher index should be set");

        // tokenIdToDispatcher updated
        assertEq(minter.tokenIdToDispatcher(1), address(newGather), "tokenIdToDispatcher should point to new");
    }

    function test_replaceDispatcher_preservesPriceGrowthDisabledState() public {
        uint256 initialPrice = 10e18;
        uint256 growthBps = 250;
        minter.registerDispatcher(address(gather), initialPrice, growthBps);
        gather.setMinter(address(minter));

        // Update price via a mint
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);
        vm.prank(user);
        minter.mint(1, recipient);

        uint256 priceAfterMint = minter.getPrice(1);
        assertTrue(priceAfterMint > initialPrice, "Price should have grown");

        // Disable the dispatcher
        minter.setDispatcherDisabled(1, true);

        // Replace dispatcher
        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);
        minter.replaceDispatcher(1, address(newGather));

        // Price, growth, and disabled state should all be preserved
        (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled) = minter.configs(1);
        assertEq(dispatcher, address(newGather));
        assertEq(price, priceAfterMint, "Price should be preserved");
        assertEq(growthBasisPoints, growthBps, "Growth should be preserved");
        assertTrue(disabled, "Disabled state should be preserved");
    }

    function test_replaceDispatcher_rejectsIfNewDispatcherRegisteredElsewhere() public {
        GatherV2 gather2 = new GatherV2(address(tokenB), gatherRecipient, owner);

        minter.registerDispatcher(address(gather), 10e18, 0);
        minter.registerDispatcher(address(gather2), 5e18, 0);

        // Try to replace index 1 with gather2 (already at index 2)
        vm.expectRevert("NFTMinterV2: new dispatcher already registered elsewhere");
        minter.replaceDispatcher(1, address(gather2));
    }

    function test_replaceDispatcher_emitsEvent() public {
        minter.registerDispatcher(address(gather), 10e18, 0);

        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);

        vm.expectEmit(true, true, true, true);
        emit NFTMinterV2.DispatcherReplaced(1, address(gather), address(newGather));

        minter.replaceDispatcher(1, address(newGather));
    }

    function test_replaceDispatcher_newDispatcherWorksForMint() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        // Replace with a new gather
        GatherV2 newGather = new GatherV2(address(tokenA), gatherRecipient, owner);
        newGather.setMinter(address(minter));
        minter.replaceDispatcher(1, address(newGather));

        // Mint should work with the new dispatcher
        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        bool success = minter.mint(1, recipient);

        assertTrue(success, "Mint should succeed with replaced dispatcher");
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 NFT");
        assertEq(tokenA.balanceOf(gatherRecipient), 10e18, "Gather recipient should have received tokens");
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
        emit NFTMinterV2.PriceUpdated(1, 10e18, 20e18);

        minter.setPrice(1, 20e18);
    }

    function test_setGrowthFactor_updatesCorrectly() public {
        minter.registerDispatcher(address(gather), 10e18, 100);

        minter.setGrowthFactor(1, 500);
        (,, uint256 growthBps,) = minter.configs(1);
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
        emit NFTMinterV2.GrowthFactorUpdated(1, 100, 500);

        minter.setGrowthFactor(1, 500);
    }

    // =========================================================================
    // emergencyWithdraw tests
    // =========================================================================

    function test_emergencyWithdraw_succeeds_forOwnerWithStuckTokens() public {
        tokenA.mint(address(minter), 10e18);

        vm.expectEmit(true, true, false, true);
        emit NFTMinterV2.EmergencyWithdraw(address(tokenA), owner, 10e18);
        minter.emergencyWithdraw(address(tokenA));

        assertEq(tokenA.balanceOf(owner), 10e18);
        assertEq(tokenA.balanceOf(address(minter)), 0);
    }

    function test_emergencyWithdraw_revertsForNonOwner() public {
        tokenA.mint(address(minter), 10e18);

        vm.prank(user);
        vm.expectRevert();
        minter.emergencyWithdraw(address(tokenA));
    }

    function test_emergencyWithdraw_revertsWhenNoTokens() public {
        vm.expectRevert("NFTMinterV2: no tokens to withdraw");
        minter.emergencyWithdraw(address(tokenA));
    }

    // =========================================================================
    // setDispatcherActive tests
    // =========================================================================

    function _registerAndAuthorizeMinter(address dispatcher_) internal {
        minter.registerDispatcher(dispatcher_, 10e18, 0);
        ATokenDispatcherV2(dispatcher_).setMinter(address(minter));
    }

    function test_setDispatcherActive_false_pausesDispatcher() public {
        _registerAndAuthorizeMinter(address(gather));

        minter.setDispatcherActive(address(gather), false);
        assertTrue(gather.paused(), "Dispatcher should be paused");
    }

    function test_setDispatcherActive_true_unpausesDispatcher() public {
        _registerAndAuthorizeMinter(address(gather));

        minter.setDispatcherActive(address(gather), false);
        assertTrue(gather.paused());

        minter.setDispatcherActive(address(gather), true);
        assertFalse(gather.paused());
    }

    function test_setDispatcherActive_revertsForNonOwner() public {
        _registerAndAuthorizeMinter(address(gather));

        vm.prank(user);
        vm.expectRevert();
        minter.setDispatcherActive(address(gather), false);
    }

    function test_setDispatcherActive_revertsForUnregisteredDispatcher() public {
        vm.expectRevert("NFTMinterV2: dispatcher not registered");
        minter.setDispatcherActive(address(gather), false);
    }

    // =========================================================================
    // uri / metadata tests
    // =========================================================================

    function test_uri_returnsDispatcherMetadata() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMetadata("Test NFT", "https://example.com/nft.png", "A test NFT");

        string memory result = minter.uri(1);
        assertEq(result, '{"name":"Test NFT","image":"https://example.com/nft.png","description":"A test NFT"}');
    }

    function test_uri_returnsEmptyStringForUnmappedTokenId() public {
        string memory result = minter.uri(999);
        assertEq(result, "", "uri should return empty string for unmapped token ID");
    }

    // =========================================================================
    // Dispatcher Disabled Flag tests
    // =========================================================================

    function test_setDispatcherDisabled_preventsMinting() public {
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        minter.mint(1, recipient);
        assertEq(minter.balanceOf(recipient, 1), 1);

        minter.setDispatcherDisabled(1, true);

        vm.prank(user);
        vm.expectRevert("NFTMinterV2: dispatcher is disabled");
        minter.mint(1, recipient);
    }

    function test_setDispatcherDisabled_onlyOwner() public {
        minter.registerDispatcher(address(gather), 10e18, 0);

        vm.prank(user);
        vm.expectRevert();
        minter.setDispatcherDisabled(1, true);
    }

    function test_setDispatcherDisabled_revertsForUnregistered() public {
        vm.expectRevert("NFTMinterV2: index not registered");
        minter.setDispatcherDisabled(999, true);
    }

    // =========================================================================
    // Authorized Burner & Burn tests
    // =========================================================================

    address public authorizedBurnerAddr = address(0xBBBB);

    function _mintNFTToHolder(address holder) internal returns (uint256 tokenId) {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        tokenA.mint(holder, 100e18);
        vm.prank(holder);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(holder);
        minter.mint(1, holder);

        return 1;
    }

    function test_burn_authorizedBurnerCanBurnNFTs() public {
        uint256 tokenId = _mintNFTToHolder(user);
        assertEq(minter.balanceOf(user, tokenId), 1);

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);

        vm.prank(authorizedBurnerAddr);
        minter.burn(user, tokenId, 1);

        assertEq(minter.balanceOf(user, tokenId), 0);
    }

    function test_burn_unauthorizedAddressCannotBurn() public {
        uint256 tokenId = _mintNFTToHolder(user);

        vm.prank(authorizedBurnerAddr);
        vm.expectRevert("NFTMinterV2: caller is not authorized burner");
        minter.burn(user, tokenId, 1);
    }

    function test_burn_emitsClaimBurnedEvent() public {
        uint256 tokenId = _mintNFTToHolder(user);

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);

        vm.expectEmit(true, true, false, true);
        emit NFTMinterV2.ClaimBurned(user, tokenId, 1);

        vm.prank(authorizedBurnerAddr);
        minter.burn(user, tokenId, 1);
    }

    // =========================================================================
    // ERC1155Supply tests
    // =========================================================================

    function test_totalSupply_increasesByMintedAmount() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        assertEq(minter.totalSupply(1), 0, "totalSupply should be 0 before any mints");

        vm.prank(user);
        minter.mint(1, recipient);
        assertEq(minter.totalSupply(1), 1, "totalSupply should be 1 after first mint");

        vm.prank(user);
        minter.mint(1, recipient);
        assertEq(minter.totalSupply(1), 2, "totalSupply should be 2 after second mint");
    }

    function test_exists_returnsTrueAfterMintAndFalseAfterFullBurn() public {
        minter.registerDispatcher(address(gather), 10e18, 0);
        gather.setMinter(address(minter));

        assertFalse(minter.exists(1), "exists should be false before any mint");

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        minter.mint(1, user);

        assertTrue(minter.exists(1), "exists should be true after mint");

        minter.setAuthorizedBurner(authorizedBurnerAddr, true);
        vm.prank(authorizedBurnerAddr);
        minter.burn(user, 1, 1);

        assertFalse(minter.exists(1), "exists should be false after full burn");
    }

    // =========================================================================
    // Global Pauser tests
    // =========================================================================

    address public globalPauser = address(0xDA05);

    function test_setPauser_setsPauserAddress() public {
        minter.setPauser(globalPauser);
        assertEq(minter.pauser(), globalPauser);
    }

    function test_globalPause_blocksMinting() public {
        _registerAndAuthorizeMinter(address(gather));

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        minter.setPauser(globalPauser);
        vm.prank(globalPauser);
        minter.pause();

        vm.prank(user);
        vm.expectRevert("Contract is paused");
        minter.mint(1, recipient);
    }

    // =========================================================================
    // FOT token tests
    // =========================================================================

    function test_mint_FOTToken_withGather_noRevert_NFTMinted() public {
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200);

        GatherV2 fotGather = new GatherV2(address(fotToken), gatherRecipient, owner);
        fotGather.setMinter(address(minter));

        uint256 initialPrice = 100e18;
        minter.registerDispatcher(address(fotGather), initialPrice, 0);

        fotToken.mint(user, 1000e18);
        vm.prank(user);
        fotToken.approve(address(minter), type(uint256).max);

        vm.prank(user);
        bool success = minter.mint(1, recipient);

        assertTrue(success, "Mint should succeed with FOT token");
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 claim NFT");
        assertEq(fotToken.balanceOf(user), 1000e18 - initialPrice, "User should have lost exactly price from balance");
        assertEq(fotToken.balanceOf(address(minter)), 0, "Minter should have 0 balance");
    }

    // =========================================================================
    // 4-parameter mint() overload with extraData
    // =========================================================================

    function test_mint_withExtraData_transfersTokenAndMintsNFT() public {
        uint256 price = 10e18;
        minter.registerDispatcher(address(gather), price, 0);
        gather.setMinter(address(minter));

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        bytes memory extraData = abi.encode(uint256(42), uint256(100));
        vm.prank(user);
        bool success = minter.mint(1, recipient, extraData);

        assertTrue(success, "4-parameter mint should succeed");
        assertEq(tokenA.balanceOf(user), 90e18, "User should have paid 10e18");
        assertEq(minter.balanceOf(recipient, 1), 1, "Recipient should have 1 claim NFT");
    }

    // =========================================================================
    // Metadata tests
    // =========================================================================

    function test_setMetadata_setsNameImageDescription() public {
        gather.setMetadata("Gather NFT", "https://example.com/image.png", "A gather dispatcher NFT");

        assertEq(gather.name(), "Gather NFT");
        assertEq(gather.image(), "https://example.com/image.png");
        assertEq(gather.description(), "A gather dispatcher NFT");
    }
}
