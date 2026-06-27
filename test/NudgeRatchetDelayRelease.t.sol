// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NudgeRatchetDelayRelease} from "../src/dispatchers/NudgeRatchetDelayRelease.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {NudgeRatchetMintDebtHook} from "../src/hooks/NudgeRatchetMintDebtHook.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {MockMintable} from "./mocks/MockMintable.sol";

/// @dev USDC-like 6-decimal mock ERC20 for NudgeRatchetDelayRelease tests.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev 18-decimal mock ERC20 used to assert the constructor USDC guard rejects it,
///      and as an arbitrary non-`_token` ERC20 for the rescueERC20 test.
contract Mock18Decimals is ERC20 {
    constructor() ERC20("Eighteen", "ETN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NudgeRatchetDelayReleaseTest is Test {
    NudgeRatchetDelayRelease public ratchet;
    MockUSDC public usdc;
    NudgeRatchetMintDebtHook public mintDebtHook;
    MockMintable public phUSD;

    address public owner = address(this);
    address public minter = address(0xABCDEF);
    address public batchMinterAddr = address(0xCAFE);
    address public releaser = address(0x9E1);

    function setUp() public {
        usdc = new MockUSDC();
        ratchet = new NudgeRatchetDelayRelease(address(usdc), batchMinterAddr, owner);

        // Audit M-04: the dispatcher asserts its hook is a real NudgeRatchetMintDebtHook
        // on every dispatch. Install one so the dispatch path is valid in tests.
        phUSD = new MockMintable();
        mintDebtHook = new NudgeRatchetMintDebtHook(owner, address(ratchet), address(phUSD));
        ratchet.setHook(IDispatchHook(address(mintDebtHook)));

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
    // constructor tests
    // =========================================================================

    function test_constructor_revertsWithZeroBatchMinter() public {
        vm.expectRevert("NudgeRatchetDelayRelease: zero batchMinter");
        new NudgeRatchetDelayRelease(address(usdc), address(0), owner);
    }

    function test_constructor_revertsWithNon6DecimalToken() public {
        Mock18Decimals token18 = new Mock18Decimals();
        vm.expectRevert("NudgeRatchetDelayRelease: token must be 6-decimal USDC");
        new NudgeRatchetDelayRelease(address(token18), batchMinterAddr, owner);
    }

    function test_constructor_setsTokenAndBatchMinter() public {
        NudgeRatchetDelayRelease fresh =
            new NudgeRatchetDelayRelease(address(usdc), batchMinterAddr, owner);
        assertEq(fresh.primeToken(), address(usdc), "token should be set");
        assertEq(fresh.batchMinter(), batchMinterAddr, "batchMinter should be set");
    }

    // =========================================================================
    // dispatch tests — HOLDS USDC (does NOT forward to batchMinter)
    // =========================================================================

    /// @dev Core behavioural difference vs NudgeRatchet: after a dispatch the contract
    ///      RETAINS the USDC and batchMinter receives nothing.
    function test_dispatch_holdsTokenAndDoesNotForward() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        assertEq(usdc.balanceOf(address(ratchet)), amount, "ratchet should HOLD the dispatched USDC");
        assertEq(usdc.balanceOf(batchMinterAddr), 0, "batchMinter should receive nothing on dispatch");
    }

    /// @dev Debt logic is UNCHANGED: mint-debt accrues against the scaled `amount`
    ///      (default ratio 100%, scaled 6->18 dp) on every dispatch.
    function test_dispatch_stillAccruesMintDebt() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        assertEq(mintDebtHook.mintDebt(), amount * 1e12, "phUSD mint-debt should accrue at default ratio");
    }

    /// @dev Multiple dispatches accumulate held USDC on the contract.
    function test_dispatch_accumulatesHeldBalanceAcrossDispatches() public {
        uint256 a1 = 40e6;
        uint256 a2 = 60e6;
        usdc.mint(address(ratchet), a1 + a2);

        vm.prank(minter);
        ratchet.dispatch(minter, a1, "");
        vm.prank(minter);
        ratchet.dispatch(minter, a2, "");

        assertEq(usdc.balanceOf(address(ratchet)), a1 + a2, "held balance should accumulate");
        assertEq(usdc.balanceOf(batchMinterAddr), 0, "batchMinter still empty");
        assertEq(mintDebtHook.mintDebt(), (a1 + a2) * 1e12, "debt accrues for both dispatches");
    }

    // -------------------------------------------------------------------------
    // Audit M-04: hookTypeId() marker guard in _dispatch
    // -------------------------------------------------------------------------

    function test_dispatch_revertsWithDefaultHook() public {
        // Fresh dispatcher whose hook is still the constructor-default DefaultDispatchHook.
        NudgeRatchetDelayRelease fresh =
            new NudgeRatchetDelayRelease(address(usdc), batchMinterAddr, owner);
        fresh.setMinter(minter);

        uint256 amount = 100e6;
        usdc.mint(address(fresh), amount);

        vm.prank(minter);
        vm.expectRevert();
        fresh.dispatch(minter, amount, "");
    }

    function test_dispatch_revertsWithWrongHook() public {
        NudgeRatchetDelayRelease fresh =
            new NudgeRatchetDelayRelease(address(usdc), batchMinterAddr, owner);
        MockDispatchHook wrongHook = new MockDispatchHook();
        fresh.setHook(IDispatchHook(address(wrongHook)));
        fresh.setMinter(minter);

        uint256 amount = 100e6;
        usdc.mint(address(fresh), amount);

        vm.prank(minter);
        vm.expectRevert();
        fresh.dispatch(minter, amount, "");
    }

    // -------------------------------------------------------------------------
    // base modifiers intact: onlyMinter + whenNotPaused
    // -------------------------------------------------------------------------

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

    // =========================================================================
    // setReleaser tests
    // =========================================================================

    function test_setReleaser_whitelistsReleaser() public {
        assertFalse(ratchet.releasers(releaser), "releaser not whitelisted initially");
        ratchet.setReleaser(releaser, true);
        assertTrue(ratchet.releasers(releaser), "releaser should be whitelisted");
    }

    function test_setReleaser_emitsReleaserUpdatedEvent() public {
        vm.expectEmit(true, false, false, true);
        emit NudgeRatchetDelayRelease.ReleaserUpdated(releaser, true);
        ratchet.setReleaser(releaser, true);
    }

    function test_setReleaser_revokes() public {
        ratchet.setReleaser(releaser, true);
        assertTrue(ratchet.releasers(releaser), "should be whitelisted");
        ratchet.setReleaser(releaser, false);
        assertFalse(ratchet.releasers(releaser), "should be revoked");
    }

    function test_setReleaser_revertsWhenCalledByNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        ratchet.setReleaser(releaser, true);
    }

    // =========================================================================
    // release tests
    // =========================================================================

    function test_release_transfersExactAmountToBatchMinterAndHoldsRemainder() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        ratchet.setReleaser(releaser, true);

        uint256 releaseAmount = 30e6;
        vm.prank(releaser);
        ratchet.release(releaseAmount);

        assertEq(usdc.balanceOf(batchMinterAddr), releaseAmount, "batchMinter should receive exactly the released amount");
        assertEq(usdc.balanceOf(address(ratchet)), amount - releaseAmount, "ratchet should hold the remainder");
    }

    function test_release_emitsReleasedEvent() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        ratchet.setReleaser(releaser, true);

        vm.expectEmit(true, false, false, true);
        emit NudgeRatchetDelayRelease.Released(releaser, 50e6);
        vm.prank(releaser);
        ratchet.release(50e6);
    }

    function test_release_revertsForNonReleaser() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        vm.prank(address(0xDEAD));
        vm.expectRevert("NudgeRatchetDelayRelease: caller is not releaser");
        ratchet.release(10e6);
    }

    function test_release_revertsWhenAmountExceedsHeldBalance() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        ratchet.setReleaser(releaser, true);

        // SafeERC20 reverts when the transfer cannot move more than the held balance.
        vm.prank(releaser);
        vm.expectRevert();
        ratchet.release(amount + 1);
    }

    /// @dev Rate-control scenario: two partial releases move the cumulative amount and
    ///      conserve total backing (held + released == originally dispatched).
    function test_release_partialThenSecondRelease_conservesBacking() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        ratchet.setReleaser(releaser, true);

        vm.prank(releaser);
        ratchet.release(30e6);
        vm.prank(releaser);
        ratchet.release(45e6);

        assertEq(usdc.balanceOf(batchMinterAddr), 75e6, "batchMinter should hold cumulative releases");
        assertEq(usdc.balanceOf(address(ratchet)), 25e6, "ratchet should hold the remainder");
        // Conservation: held + released == originally dispatched.
        assertEq(
            usdc.balanceOf(batchMinterAddr) + usdc.balanceOf(address(ratchet)),
            amount,
            "total backing conserved across releases"
        );
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
        emit NudgeRatchetDelayRelease.BatchMinterUpdated(batchMinterAddr, newBatchMinter);
        ratchet.setBatchMinter(newBatchMinter);
    }

    function test_setBatchMinter_revertsWhenCalledByNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        ratchet.setBatchMinter(address(0xBEEF));
    }

    function test_setBatchMinter_revertsWithZeroAddress() public {
        vm.expectRevert("NudgeRatchetDelayRelease: zero batchMinter");
        ratchet.setBatchMinter(address(0));
    }

    // =========================================================================
    // rescueERC20 tests
    // =========================================================================

    function test_rescueERC20_recoversArbitraryToken() public {
        Mock18Decimals stray = new Mock18Decimals();
        uint256 amount = 5e18;
        stray.mint(address(ratchet), amount);

        address to = address(0xB0B);
        ratchet.rescueERC20(address(stray), to, amount);

        assertEq(stray.balanceOf(to), amount, "recipient should receive the rescued tokens");
        assertEq(stray.balanceOf(address(ratchet)), 0, "ratchet should hold none after rescue");
    }

    function test_rescueERC20_revertsForNonOwner() public {
        Mock18Decimals stray = new Mock18Decimals();
        stray.mint(address(ratchet), 1e18);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        ratchet.rescueERC20(address(stray), address(0xB0B), 1e18);
    }

    function test_rescueERC20_revertsWithZeroRecipient() public {
        Mock18Decimals stray = new Mock18Decimals();
        stray.mint(address(ratchet), 1e18);

        vm.expectRevert("NudgeRatchetDelayRelease: zero recipient");
        ratchet.rescueERC20(address(stray), address(0), 1e18);
    }

    // =========================================================================
    // Integration test: NFTMinterV2 -> NudgeRatchetDelayRelease (held) -> release
    // =========================================================================

    function test_integration_mintHoldsThenRelease() public {
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
        // USDC is HELD on the dispatcher, NOT forwarded to batchMinter on mint.
        assertEq(usdc.balanceOf(address(ratchet)), 10e6, "dispatcher should HOLD the dispatched USDC");
        assertEq(usdc.balanceOf(batchMinterAddr), 0, "batchMinter empty until release");
        assertEq(usdc.balanceOf(address(nftMinter)), 0, "NFTMinterV2 should have 0 balance");
        assertEq(nftMinter.balanceOf(nftRecipient, 1), 1, "NFT recipient should have 1 claim NFT");
        // Debt accrues for the dispatched USDC (default ratio 100%, scaled 6->18 dp).
        assertEq(mintDebtHook.mintDebt(), 10e6 * 1e12, "phUSD mint-debt should accrue for the dispatched USDC");

        // A releaser then forwards the held USDC to batchMinter.
        ratchet.setReleaser(releaser, true);
        vm.prank(releaser);
        ratchet.release(10e6);

        assertEq(usdc.balanceOf(batchMinterAddr), 10e6, "batchMinter should receive released USDC");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "dispatcher emptied after full release");
    }
}
