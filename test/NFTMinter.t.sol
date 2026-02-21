// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {NFTMinter} from "../src/NFTMinter.sol";
import {Accumulator} from "../src/dispatchers/Accumulator.sol";
import {Burner} from "../src/dispatchers/Burner.sol";
import {BalancerPooler} from "../src/dispatchers/BalancerPooler.sol";
import {ITokenDispatcher} from "../src/interfaces/ITokenDispatcher.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
        // Register burner dispatcher - it will pull tokens from minter
        minter.registerDispatcher(address(burner), 10e18, 0);

        tokenA.mint(user, 100e18);
        vm.prank(user);
        tokenA.approve(address(minter), type(uint256).max);

        vm.prank(user);
        minter.mint(address(tokenA), 1, recipient);

        // Burner should have pulled tokens from minter
        assertEq(tokenA.balanceOf(address(burner)), 10e18);
        assertEq(tokenA.balanceOf(address(minter)), 0);
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
}
