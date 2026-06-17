// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NudgeRatchet} from "../../src/V2/dispatchers/NudgeRatchet.sol";
import {NFTMinterV2} from "../../src/V2/NFTMinterV2.sol";
import {IDispatchHook} from "../../src/V2/interfaces/IDispatchHook.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockDispatchHook} from "../mocks/MockDispatchHook.sol";

/// @dev USDC-like 6-decimal mock ERC20 for NudgeRatchet tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev 18-decimal mock ERC20 used to assert the constructor USDC guard rejects it.
contract Mock18Decimals is ERC20 {
    constructor() ERC20("Eighteen", "ETN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NudgeRatchetTest is Test {
    NudgeRatchet public ratchet;
    MockUSDC public usdc;

    address public owner = address(this);
    address public minter = address(0xABCDEF);
    address public batchMinterAddr = address(0xCAFE);

    function setUp() public {
        usdc = new MockUSDC();
        ratchet = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        ratchet.setMinter(minter);
    }

    // =========================================================================
    // primeToken / batchMinter getters
    // =========================================================================

    function test_primeToken_returnsToken() public view {
        assertEq(ratchet.primeToken(), address(usdc));
    }

    function test_batchMinter_returnsInitialBatchMinter() public view {
        assertEq(ratchet.batchMinter(), batchMinterAddr);
    }

    // =========================================================================
    // dispatch tests (tokens already on ratchet, just forward to batchMinter)
    // =========================================================================

    function test_dispatch_transfersTokenToBatchMinter() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        assertEq(usdc.balanceOf(batchMinterAddr), amount, "batchMinter should have received the tokens");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet should have 0 balance after forwarding");
    }

    function test_dispatch_revertsWhenPaused() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.pause();

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ratchet.dispatch(minter, amount, "");
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(address(0xDEAD));
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        ratchet.dispatch(address(0xDEAD), amount, "");
    }

    function test_dispatch_invokesHookWithForwardedArgs() public {
        MockDispatchHook hook = new MockDispatchHook();
        ratchet.setHook(IDispatchHook(address(hook)));

        uint256 amount = 100e6;
        bytes memory payload = hex"cafebabe";
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, payload);

        assertEq(hook.callCount(), 1, "hook should be called once");
        assertEq(hook.lastMinter(), minter, "hook should receive minter");
        assertEq(hook.lastAmount(), amount, "hook should receive amount");
        assertEq(hook.lastExtraData(), payload, "hook should receive extraData verbatim");
    }

    // =========================================================================
    // setBatchMinter tests
    // =========================================================================

    function test_setBatchMinter_updatesBatchMinterAddress() public {
        address newBatchMinter = address(0xBEEF);
        ratchet.setBatchMinter(newBatchMinter);
        assertEq(ratchet.batchMinter(), newBatchMinter, "batchMinter should be updated");
    }

    function test_setBatchMinter_emitsBatchMinterUpdatedEvent() public {
        address newBatchMinter = address(0xBEEF);
        vm.expectEmit(true, true, false, true);
        emit NudgeRatchet.BatchMinterUpdated(batchMinterAddr, newBatchMinter);
        ratchet.setBatchMinter(newBatchMinter);
    }

    function test_setBatchMinter_revertsWhenCalledByNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        ratchet.setBatchMinter(address(0xBEEF));
    }

    function test_setBatchMinter_revertsWithZeroAddress() public {
        vm.expectRevert("NudgeRatchet: zero batchMinter");
        ratchet.setBatchMinter(address(0));
    }

    // =========================================================================
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroBatchMinter() public {
        vm.expectRevert("NudgeRatchet: zero batchMinter");
        new NudgeRatchet(address(usdc), address(0), owner);
    }

    function test_constructor_revertsWithNon6DecimalToken() public {
        Mock18Decimals token18 = new Mock18Decimals();
        vm.expectRevert("NudgeRatchet: token must be 6-decimal USDC");
        new NudgeRatchet(address(token18), batchMinterAddr, owner);
    }

    // =========================================================================
    // Integration test: NFTMinterV2 -> NudgeRatchet -> batchMinter
    // =========================================================================

    function test_integration_mintNFTWithNudgeRatchetDispatcher() public {
        NFTMinterV2 nftMinter = new NFTMinterV2(owner);

        uint256 initialPrice = 10e6;
        nftMinter.registerDispatcher(address(ratchet), initialPrice, 0);
        ratchet.setMinter(address(nftMinter));

        address user = address(0xBEEF);
        usdc.mint(user, 100e6);
        vm.prank(user);
        usdc.approve(address(nftMinter), type(uint256).max);

        address nftRecipient = address(0xFACE);
        vm.prank(user);
        bool success = nftMinter.mint(1, nftRecipient);

        assertTrue(success, "Mint should succeed");
        assertEq(usdc.balanceOf(user), 90e6, "User should have paid 10e6");
        assertEq(usdc.balanceOf(batchMinterAddr), 10e6, "batchMinter should have received the tokens");
        assertEq(usdc.balanceOf(address(nftMinter)), 0, "NFTMinterV2 should have 0 balance");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "NudgeRatchet should have 0 balance");
        assertEq(nftMinter.balanceOf(nftRecipient, 1), 1, "NFT recipient should have 1 claim NFT");
    }
}
