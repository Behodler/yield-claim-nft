// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTBonfire} from "../src/NFTBonfire.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {GatherV2} from "../src/dispatchers/GatherV2.sol";
import {INFTMinterV2} from "../src/interfaces/INFTMinterV2.sol";
import {IMintable} from "../src/interfaces/IMintable.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockMintable} from "./mocks/MockMintable.sol";

/// @dev Minimal ERC20 used only as GatherV2's token so a dispatcher can be registered.
contract BonfireMockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
}

/// @dev Mintable that tries to re-enter `NFTBonfire.burn` during `mint`.
contract ReentrantBonfireMintable is IMintable {
    NFTBonfire public target;
    uint256 public tokenId;
    bool public reentryAttempted;
    bool public reentryReverted;
    bytes public reentryRevertData;

    function setTarget(NFTBonfire target_, uint256 tokenId_) external {
        target = target_;
        tokenId = tokenId_;
    }

    function mint(address, uint256) external override {
        reentryAttempted = true;
        try target.burn(tokenId, 0) {
            reentryReverted = false;
        } catch (bytes memory reason) {
            reentryReverted = true;
            reentryRevertData = reason;
        }
    }
}

contract NFTBonfireTest is Test {
    NFTMinterV2 public nftMinter;
    MockMintable public antimatter;
    NFTBonfire public bonfire;
    GatherV2 public gather1;
    GatherV2 public gather2;
    BonfireMockERC20 public token;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public pauserAddr = address(0x9A05E);
    address public nftMintAuth = address(0x4D1);

    uint256 internal constant RATE = 2.5e18;
    uint256 internal constant ID1 = 1;
    uint256 internal constant ID2 = 2;

    event Burned(address indexed burner, uint256 indexed tokenId, uint256 payout);
    event RatePerDayUpdated(uint256 oldRate, uint256 newRate);
    event MaxPayoutUpdated(uint256 oldMax, uint256 newMax);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event ClaimBurned(address indexed holder, uint256 indexed tokenId, uint256 quantity);

    function setUp() public {
        vm.warp(1_700_000_000);

        nftMinter = new NFTMinterV2(owner);
        token = new BonfireMockERC20();
        gather1 = new GatherV2(address(token), address(0xFEED), owner);
        gather2 = new GatherV2(address(token), address(0xFEED), owner);
        nftMinter.registerDispatcher(address(gather1), 1e18, 0); // index 1
        nftMinter.registerDispatcher(address(gather2), 1e18, 0); // index 2
        nftMinter.setAuthorizedMinter(nftMintAuth, true);

        vm.startPrank(nftMintAuth);
        nftMinter.mintFor(ID1, alice);
        nftMinter.mintFor(ID1, alice);
        nftMinter.mintFor(ID1, alice);
        nftMinter.mintFor(ID2, alice);
        vm.stopPrank();

        antimatter = new MockMintable();
        bonfire = new NFTBonfire(owner, address(nftMinter), address(antimatter));
        nftMinter.setAuthorizedBurner(address(bonfire), true);
        bonfire.setPauser(pauserAddr);
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_constructor_storesState() public view {
        assertEq(address(bonfire.nftMinter()), address(nftMinter));
        assertEq(address(bonfire.antimatter()), address(antimatter));
        assertEq(bonfire.owner(), owner);
        assertEq(bonfire.lastUpdate(), block.timestamp);
        assertEq(bonfire.ratePerDay(), 0);
        assertEq(bonfire.maxPayout(), 0);
        assertEq(bonfire.accruedStored(), 0);
        assertEq(bonfire.pendingPayout(), 0);
    }

    function test_constructor_revertsOnZeroNftMinter() public {
        vm.expectRevert(NFTBonfire.NFTBonfire__ZeroAddress.selector);
        new NFTBonfire(owner, address(0), address(antimatter));
    }

    function test_constructor_revertsOnZeroAntimatter() public {
        vm.expectRevert(NFTBonfire.NFTBonfire__ZeroAddress.selector);
        new NFTBonfire(owner, address(nftMinter), address(0));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new NFTBonfire(address(0), address(nftMinter), address(antimatter));
    }

    // =========================================================================
    // Burning disabled at rate 0
    // =========================================================================

    function test_burn_revertsWhenRateZero() public {
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        vm.expectRevert(NFTBonfire.NFTBonfire__BurningDisabled.selector);
        bonfire.burn(ID1, 0);
        assertEq(nftMinter.balanceOf(alice, ID1), 3);
    }

    // =========================================================================
    // Linear accrual
    // =========================================================================

    function test_accrual_linear() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 12 hours);
        assertEq(bonfire.pendingPayout(), 1.25e18);
        vm.warp(block.timestamp + 12 hours);
        assertEq(bonfire.pendingPayout(), 2.5e18);
    }

    function test_accrual_floorsInProtocolFavour() public {
        bonfire.setRatePerDay(1e18);
        vm.warp(block.timestamp + 1);
        // 1e18 / 86400 = 11574074074074.07... -> floored
        assertEq(bonfire.pendingPayout(), uint256(1e18) / 1 days);
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_burn_happyPath() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, true, false, true, address(nftMinter));
        emit ClaimBurned(alice, ID1, 1);
        vm.expectEmit(true, true, false, true, address(bonfire));
        emit Burned(alice, ID1, RATE);

        vm.prank(alice);
        uint256 payout = bonfire.burn(ID1, RATE);

        assertEq(payout, RATE);
        assertEq(nftMinter.balanceOf(alice, ID1), 2);
        assertEq(antimatter.mintCallCount(), 1);
        (address r, uint256 amt) = antimatter.lastMint();
        assertEq(r, alice);
        assertEq(amt, RATE);
        assertEq(antimatter.balanceOf(alice), RATE);
        assertEq(bonfire.accruedStored(), 0);
        assertEq(bonfire.lastUpdate(), block.timestamp);
        assertEq(bonfire.pendingPayout(), 0);
    }

    function test_burn_accrualRestartsAfterBurn() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        bonfire.burn(ID1, 0);
        vm.warp(block.timestamp + 12 hours);
        assertEq(bonfire.pendingPayout(), 1.25e18);
    }

    // =========================================================================
    // Caller-only burn (the critical invariant)
    // =========================================================================

    function test_burn_cannotBurnAnotherHoldersToken() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, 1, ID1));
        bonfire.burn(ID1, 0);

        assertEq(nftMinter.balanceOf(alice, ID1), 3);
        assertEq(antimatter.mintCallCount(), 0);
        // Pot untouched by the failed attempt.
        assertEq(bonfire.pendingPayout(), RATE);
    }

    function test_burn_onlyBurnsFromCaller() public {
        // Give bob one token, then bob's burn must take from bob only.
        vm.prank(nftMintAuth);
        nftMinter.mintFor(ID1, bob);
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.prank(bob);
        bonfire.burn(ID1, 0);

        assertEq(nftMinter.balanceOf(bob, ID1), 0);
        assertEq(nftMinter.balanceOf(alice, ID1), 3);
        assertEq(antimatter.balanceOf(bob), RATE);
        assertEq(antimatter.balanceOf(alice), 0);
    }

    // =========================================================================
    // Same-block consecutive burns
    // =========================================================================

    function test_burn_secondBurnSameBlockPaysZero() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        bonfire.burn(ID1, 0);
        uint256 payout2 = bonfire.burn(ID1, 0);
        vm.stopPrank();

        assertEq(payout2, 0);
        assertEq(nftMinter.balanceOf(alice, ID1), 1);
        // No mint(…, 0) call.
        assertEq(antimatter.mintCallCount(), 1);
    }

    function test_burn_secondBurnSameBlockRevertsWithMinPayout() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        bonfire.burn(ID1, 0);
        vm.expectRevert(abi.encodeWithSelector(NFTBonfire.NFTBonfire__PayoutBelowMinimum.selector, 0, 1));
        bonfire.burn(ID1, 1);
        vm.stopPrank();

        assertEq(nftMinter.balanceOf(alice, ID1), 2);
    }

    function test_burn_revertsWhenPayoutBelowMinimum() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NFTBonfire.NFTBonfire__PayoutBelowMinimum.selector, RATE, RATE + 1));
        bonfire.burn(ID1, RATE + 1);
    }

    // =========================================================================
    // maxPayout
    // =========================================================================

    function test_maxPayout_defaultUnlimited() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1000 days);
        assertEq(bonfire.pendingPayout(), RATE * 1000);
        vm.prank(alice);
        uint256 payout = bonfire.burn(ID1, 0);
        assertEq(payout, RATE * 1000);
        assertEq(antimatter.balanceOf(alice), RATE * 1000);
    }

    function test_maxPayout_capsPotAndForfeitsExcess() public {
        bonfire.setRatePerDay(RATE);
        bonfire.setMaxPayout(5e18);
        vm.warp(block.timestamp + 10 days); // raw 25e18

        assertEq(bonfire.pendingPayout(), 5e18);
        vm.prank(alice);
        uint256 payout = bonfire.burn(ID1, 0);
        assertEq(payout, 5e18);
        assertEq(antimatter.balanceOf(alice), 5e18);
        assertEq(bonfire.accruedStored(), 0);
        assertEq(bonfire.pendingPayout(), 0);

        // Excess was forfeited, not carried forward.
        vm.warp(block.timestamp + 1 days);
        assertEq(bonfire.pendingPayout(), RATE);
    }

    function test_maxPayout_belowCapUnaffected() public {
        bonfire.setRatePerDay(RATE);
        bonfire.setMaxPayout(5e18);
        vm.warp(block.timestamp + 1 days);
        assertEq(bonfire.pendingPayout(), RATE);
    }

    // =========================================================================
    // Rate change checkpoints
    // =========================================================================

    function test_setRatePerDay_checkpointsAtOldRate() public {
        uint256 rateA = 2.5e18;
        uint256 rateB = 7e18;
        bonfire.setRatePerDay(rateA);
        vm.warp(block.timestamp + 3 days);
        bonfire.setRatePerDay(rateB);
        assertEq(bonfire.accruedStored(), rateA * 3);
        assertEq(bonfire.lastUpdate(), block.timestamp);
        vm.warp(block.timestamp + 2 days);
        assertEq(bonfire.pendingPayout(), rateA * 3 + rateB * 2);
    }

    function test_setRatePerDay_checkpointsFloored() public {
        uint256 rateA = 1e18;
        uint256 rateB = 3e18;
        bonfire.setRatePerDay(rateA);
        vm.warp(block.timestamp + 7777);
        bonfire.setRatePerDay(rateB);
        vm.warp(block.timestamp + 3333);
        uint256 expected = (7777 * rateA) / 1 days + (3333 * rateB) / 1 days;
        assertEq(bonfire.pendingPayout(), expected);
    }

    function test_setRatePerDay_zeroPreservesPotAndStopsAccrual() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 2 days);
        bonfire.setRatePerDay(0);
        assertEq(bonfire.pendingPayout(), RATE * 2);

        vm.warp(block.timestamp + 5 days);
        assertEq(bonfire.pendingPayout(), RATE * 2);

        vm.prank(alice);
        vm.expectRevert(NFTBonfire.NFTBonfire__BurningDisabled.selector);
        bonfire.burn(ID1, 0);

        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        assertEq(bonfire.pendingPayout(), RATE * 3);

        vm.prank(alice);
        assertEq(bonfire.burn(ID1, 0), RATE * 3);
    }

    function test_setMaxPayout_checkpointsCappedAtOldMax() public {
        bonfire.setRatePerDay(1e18);
        bonfire.setMaxPayout(2e18);
        vm.warp(block.timestamp + 5 days); // raw 5e18, capped 2e18
        bonfire.setMaxPayout(10e18);
        assertEq(bonfire.accruedStored(), 2e18);
        assertEq(bonfire.lastUpdate(), block.timestamp);
        assertEq(bonfire.pendingPayout(), 2e18);
        vm.warp(block.timestamp + 1 days);
        assertEq(bonfire.pendingPayout(), 3e18);
    }

    function test_setMaxPayout_loweringCapsStoredPot() public {
        bonfire.setRatePerDay(1e18);
        vm.warp(block.timestamp + 5 days);
        bonfire.setMaxPayout(1e18);
        assertEq(bonfire.pendingPayout(), 1e18);
        // Stored pot was checkpointed at 5e18 (old max unlimited) but reads capped at 1e18.
        assertEq(bonfire.accruedStored(), 5e18);
        bonfire.setMaxPayout(0);
        // Removing the cap checkpoints under the 1e18 cap first: the excess is forfeited.
        assertEq(bonfire.accruedStored(), 1e18);
        assertEq(bonfire.pendingPayout(), 1e18);
    }

    // =========================================================================
    // Owner-only setters and events
    // =========================================================================

    function test_setRatePerDay_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        bonfire.setRatePerDay(RATE);
    }

    function test_setMaxPayout_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        bonfire.setMaxPayout(1e18);
    }

    function test_setPauser_onlyOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        bonfire.setPauser(bob);
    }

    function test_setRatePerDay_emitsEvent() public {
        bonfire.setRatePerDay(1e18);
        vm.expectEmit(false, false, false, true, address(bonfire));
        emit RatePerDayUpdated(1e18, RATE);
        bonfire.setRatePerDay(RATE);
        assertEq(bonfire.ratePerDay(), RATE);
    }

    function test_setMaxPayout_emitsEvent() public {
        bonfire.setMaxPayout(1e18);
        vm.expectEmit(false, false, false, true, address(bonfire));
        emit MaxPayoutUpdated(1e18, 3e18);
        bonfire.setMaxPayout(3e18);
        assertEq(bonfire.maxPayout(), 3e18);
    }

    function test_setPauser_emitsEvent() public {
        vm.expectEmit(true, true, false, false, address(bonfire));
        emit PauserChanged(pauserAddr, bob);
        bonfire.setPauser(bob);
        assertEq(bonfire.pauser(), bob);
    }

    // =========================================================================
    // Pausable
    // =========================================================================

    function test_pause_onlyPauser() public {
        vm.prank(bob);
        vm.expectRevert(NFTBonfire.NFTBonfire__NotPauser.selector);
        bonfire.pause();

        // Owner is not the pauser either.
        vm.expectRevert(NFTBonfire.NFTBonfire__NotPauser.selector);
        bonfire.pause();
    }

    function test_unpause_onlyPauser() public {
        vm.prank(pauserAddr);
        bonfire.pause();
        vm.prank(bob);
        vm.expectRevert(NFTBonfire.NFTBonfire__NotPauser.selector);
        bonfire.unpause();
    }

    function test_burn_revertsWhenPaused() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(pauserAddr);
        bonfire.pause();
        assertTrue(bonfire.paused());

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bonfire.burn(ID1, 0);
        assertEq(nftMinter.balanceOf(alice, ID1), 3);
    }

    function test_pause_accrualContinuesAndUnpauseRestoresBurn() public {
        bonfire.setRatePerDay(RATE);
        vm.prank(pauserAddr);
        bonfire.pause();
        vm.warp(block.timestamp + 2 days);
        assertEq(bonfire.pendingPayout(), RATE * 2);

        vm.prank(pauserAddr);
        bonfire.unpause();
        vm.prank(alice);
        assertEq(bonfire.burn(ID1, 0), RATE * 2);
    }

    function test_pause_adminSettersWorkWhilePaused() public {
        vm.prank(pauserAddr);
        bonfire.pause();
        bonfire.setRatePerDay(RATE);
        bonfire.setMaxPayout(1e18);
        bonfire.setPauser(bob);
        assertEq(bonfire.ratePerDay(), RATE);
        assertEq(bonfire.maxPayout(), 1e18);
        assertEq(bonfire.pauser(), bob);
    }

    function test_pauser_satisfiesIPausable() public view {
        IPausable p = IPausable(address(bonfire));
        assertEq(p.pauser(), pauserAddr);
    }

    // =========================================================================
    // Reentrancy
    // =========================================================================

    function test_burn_reentrancyBlocked() public {
        ReentrantBonfireMintable evil = new ReentrantBonfireMintable();
        NFTBonfire b2 = new NFTBonfire(owner, address(nftMinter), address(evil));
        nftMinter.setAuthorizedBurner(address(b2), true);
        evil.setTarget(b2, ID1);
        b2.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        b2.burn(ID1, 0);

        assertTrue(evil.reentryAttempted());
        assertTrue(evil.reentryReverted());
        assertEq(
            evil.reentryRevertData(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(nftMinter.balanceOf(alice, ID1), 2);
    }

    // =========================================================================
    // Token IDs treated equally
    // =========================================================================

    function test_burn_differentTokenIdsSharePot() public {
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        assertEq(bonfire.burn(ID2, 0), RATE);
        assertEq(nftMinter.balanceOf(alice, ID2), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        assertEq(bonfire.burn(ID1, 0), RATE);
        assertEq(nftMinter.balanceOf(alice, ID1), 2);
        assertEq(antimatter.balanceOf(alice), RATE * 2);
    }

    // =========================================================================
    // Not an authorised burner
    // =========================================================================

    function test_burn_revertsWhenNotAuthorisedBurner() public {
        nftMinter.setAuthorizedBurner(address(bonfire), false);
        bonfire.setRatePerDay(RATE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(bytes("NFTMinterV2: caller is not authorized burner"));
        bonfire.burn(ID1, 0);
        assertEq(antimatter.mintCallCount(), 0);
    }

    // =========================================================================
    // No holder parameter anywhere
    // =========================================================================

    function test_noHolderParameter_burnSelectorIsTwoUints() public pure {
        assertEq(NFTBonfire.burn.selector, bytes4(keccak256("burn(uint256,uint256)")));
    }

    // =========================================================================
    // Fuzz: accrual never exceeds linear amount and respects cap
    // =========================================================================

    function testFuzz_pendingPayout_linearAndCapped(uint256 rate, uint256 elapsed, uint256 cap) public {
        rate = bound(rate, 0, 1e30);
        elapsed = bound(elapsed, 0, 3650 days);
        cap = bound(cap, 0, 1e33);
        bonfire.setRatePerDay(rate);
        bonfire.setMaxPayout(cap);
        vm.warp(block.timestamp + elapsed);
        uint256 raw = (elapsed * rate) / 1 days;
        uint256 expected = (cap != 0 && raw > cap) ? cap : raw;
        assertEq(bonfire.pendingPayout(), expected);
    }
}
