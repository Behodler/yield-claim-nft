// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NudgeRatchet} from "../src/dispatchers/NudgeRatchet.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {NudgeRatchetMintDebtHook} from "../src/hooks/NudgeRatchetMintDebtHook.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {MockMintable} from "./mocks/MockMintable.sol";
import {MockNudgeBatchMinter} from "./mocks/MockNudgeBatchMinter.sol";
import {NudgeStreamer} from "phoenix-nft-staking/NudgeStreamer.sol";

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
    NudgeRatchetMintDebtHook public mintDebtHook;
    MockMintable public phUSD;

    /// @dev Story 046: donations no longer land on the sink directly — they are pulled into
    ///      the `NudgeStreamer` and released linearly to `batchMinter`. The sink must
    ///      therefore be a contract exposing `isNudgeToken` (an EOA cannot be registered).
    NudgeStreamer public streamer;
    MockNudgeBatchMinter public batchMinterMock;

    uint256 internal constant STREAM_DURATION = 1000;

    address public owner = address(this);
    address public minter = address(0xABCDEF);
    address public batchMinterAddr;

    function setUp() public {
        usdc = new MockUSDC();

        // Ops order: whitelist the token on the batch-minter FIRST, then register the
        // stream, then point the dispatcher at the streamer. Reversing the first two
        // reverts NudgeStreamer__NotWhitelisted.
        batchMinterMock = new MockNudgeBatchMinter();
        batchMinterMock.setNudgeToken(address(usdc), true);
        batchMinterAddr = address(batchMinterMock);

        streamer = new NudgeStreamer(owner);
        streamer.registerStream(batchMinterAddr, address(usdc), STREAM_DURATION);

        ratchet = new NudgeRatchet(address(usdc), batchMinterAddr, owner);

        // Audit M-04: NudgeRatchet asserts its hook is a real NudgeRatchetMintDebtHook
        // on every dispatch. Install one so the dispatch path is valid in tests.
        phUSD = new MockMintable();
        mintDebtHook = new NudgeRatchetMintDebtHook(owner, address(ratchet), address(phUSD));
        ratchet.setHook(IDispatchHook(address(mintDebtHook)));

        ratchet.setMinter(minter);
        ratchet.setNudgeStreamer(address(streamer));
    }

    /// @dev Deploys a second, fully wired ratchet so tests can prove two independent donors
    ///      accumulate into the same `(batchMinter, token)` stream.
    function _freshWiredRatchet() internal returns (NudgeRatchet fresh) {
        fresh = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        NudgeRatchetMintDebtHook freshHook = new NudgeRatchetMintDebtHook(owner, address(fresh), address(phUSD));
        fresh.setHook(IDispatchHook(address(freshHook)));
        fresh.setMinter(minter);
        fresh.setNudgeStreamer(address(streamer));
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

        // Story 046: the donation is pulled into the streamer's buffer, not pushed to the
        // sink. No time has elapsed, so nothing has streamed out to the batchMinter yet.
        assertEq(usdc.balanceOf(address(streamer)), amount, "streamer should hold the donation");
        assertEq(usdc.balanceOf(batchMinterAddr), 0, "batchMinter receives the donation only as it streams");
        (, uint256 buffer,,) = streamer.streams(batchMinterAddr, address(usdc));
        assertEq(buffer, amount, "stream buffer should equal the donation");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet should have 0 balance after forwarding");
        assertEq(usdc.allowance(address(ratchet), address(streamer)), 0, "no residual allowance lingers");
        // Audit M-04: with a real hook installed, phUSD mint-debt accrues (100% default ratio,
        // scaled 6->18 dp). This is the path that silently accrued no debt before the guard.
        assertEq(mintDebtHook.mintDebt(), amount * 1e12, "phUSD mint-debt should accrue at default ratio");
    }

    /// @dev Story 038: _dispatch sweeps the FULL token balance, not the `amount`
    ///      argument. With stray USDC present (balance > amount), the entire balance
    ///      is forwarded to batchMinter, the ratchet is left at 0, and mint-debt
    ///      accrues against `amount` ONLY (the surplus is protocol-favouring over-backing).
    function test_dispatch_sweepsFullBalanceWhenStrayTokensPresent() public {
        uint256 amount = 100e6;
        uint256 stray = 30e6;
        // Deposit the honest amount plus stray USDC sent out-of-band.
        usdc.mint(address(ratchet), amount + stray);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        assertEq(
            usdc.balanceOf(address(streamer)),
            amount + stray,
            "streamer should receive the FULL swept balance, not just amount"
        );
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet should be swept to 0 balance");
        // Debt accrues against `amount` only (scaled 6->18 dp), NOT the swept balance.
        assertEq(mintDebtHook.mintDebt(), amount * 1e12, "mint-debt should accrue against amount only");
    }

    /// @dev Story 038: defense-in-depth guard. If the contract holds less than `amount`,
    ///      dispatch reverts so unbacked phUSD can never accrue in the hook.
    function test_dispatch_revertsWhenBalanceBelowAmount() public {
        uint256 amount = 100e6;
        // Contract holds strictly less than the claimed amount.
        usdc.mint(address(ratchet), amount - 1);

        vm.prank(minter);
        vm.expectRevert("NudgeRatchet: insufficient balance for dispatch");
        ratchet.dispatch(minter, amount, "");
    }

    // -------------------------------------------------------------------------
    // Audit M-04: hookTypeId() marker guard in _dispatch
    // -------------------------------------------------------------------------

    /// @dev Dispatch succeeds and accrues debt when the installed hook is a real
    ///      NudgeRatchetMintDebtHook (installed in setUp). Also guards against keccak
    ///      literal drift between the hook's HOOK_TYPE_ID and NudgeRatchet's expected id:
    ///      if they diverged the require would revert and no debt would accrue.
    function test_dispatch_succeedsWithRealHook_andAccruesDebt() public {
        uint256 amount = 250e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        assertEq(usdc.balanceOf(address(streamer)), amount, "USDC routed to the streamer for the batchMinter");
        assertEq(mintDebtHook.mintDebt(), amount * 1e12, "mint-debt accrued through the real hook");
        // Sanity: the literals must match for the dispatch above to have succeeded.
        assertEq(
            mintDebtHook.HOOK_TYPE_ID(),
            keccak256("NudgeRatchetMintDebtHook.v1"),
            "HOOK_TYPE_ID must match the shared literal"
        );
    }

    /// @dev The "forgot to call setHook" case: with the constructor-default
    ///      DefaultDispatchHook (which lacks hookTypeId()), dispatch must revert.
    function test_dispatch_revertsWithDefaultHook() public {
        // Fresh ratchet whose hook is still the constructor-default DefaultDispatchHook.
        NudgeRatchet freshRatchet = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        freshRatchet.setMinter(minter);

        uint256 amount = 100e6;
        usdc.mint(address(freshRatchet), amount);

        vm.prank(minter);
        vm.expectRevert();
        freshRatchet.dispatch(minter, amount, "");
    }

    /// @dev Any other IDispatchHook lacking the marker (e.g. MockDispatchHook) also reverts.
    function test_dispatch_revertsWithWrongHook() public {
        NudgeRatchet freshRatchet = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        MockDispatchHook wrongHook = new MockDispatchHook();
        freshRatchet.setHook(IDispatchHook(address(wrongHook)));
        freshRatchet.setMinter(minter);

        uint256 amount = 100e6;
        usdc.mint(address(freshRatchet), amount);

        vm.prank(minter);
        vm.expectRevert();
        freshRatchet.dispatch(minter, amount, "");
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

    /// @dev With the M-04 guard, NudgeRatchet only accepts a NudgeRatchetMintDebtHook.
    ///      Verify the forwarded `amount` reaches the real hook by asserting the accrued
    ///      mint-debt corresponds to it (arbitrary extraData is ignored by the hook).
    function test_dispatch_invokesHookWithForwardedArgs() public {
        uint256 amount = 100e6;
        bytes memory payload = hex"cafebabe";
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, payload);

        // Debt accrual proves onDispatch ran with the forwarded amount (default ratio 100%).
        assertEq(mintDebtHook.mintDebt(), amount * 1e12, "real hook should accrue debt for forwarded amount");
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
    // setNudgeStreamer tests (story 046)
    // =========================================================================

    function test_setNudgeStreamer_updatesAddress() public {
        address newStreamer = address(0xB0B);
        ratchet.setNudgeStreamer(newStreamer);
        assertEq(ratchet.nudgeStreamer(), newStreamer, "nudgeStreamer should be updated");
    }

    function test_setNudgeStreamer_emitsNudgeStreamerUpdatedEvent() public {
        address newStreamer = address(0xB0B);
        vm.expectEmit(true, true, false, true);
        emit NudgeRatchet.NudgeStreamerUpdated(address(streamer), newStreamer);
        ratchet.setNudgeStreamer(newStreamer);
    }

    function test_setNudgeStreamer_revertsWhenCalledByNonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        ratchet.setNudgeStreamer(address(0xB0B));
    }

    function test_setNudgeStreamer_revertsWithZeroAddress() public {
        vm.expectRevert("NudgeRatchet: zero nudgeStreamer");
        ratchet.setNudgeStreamer(address(0));
    }

    /// @dev The streamer is unconditionally mandatory on this contract (no donation-disable
    ///      switch), so a freshly deployed ratchet with a balance cannot dispatch until an
    ///      owner wires the streamer.
    function test_dispatch_revertsWhenStreamerUnset() public {
        NudgeRatchet fresh = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        NudgeRatchetMintDebtHook freshHook = new NudgeRatchetMintDebtHook(owner, address(fresh), address(phUSD));
        fresh.setHook(IDispatchHook(address(freshHook)));
        fresh.setMinter(minter);
        assertEq(fresh.nudgeStreamer(), address(0), "streamer starts unset");

        uint256 amount = 100e6;
        usdc.mint(address(fresh), amount);

        vm.prank(minter);
        vm.expectRevert("NudgeRatchet: nudgeStreamer unset");
        fresh.dispatch(minter, amount, "");
    }

    /// @dev Documented ops failure mode: streamer wired but `registerStream` forgotten.
    function test_dispatch_revertsWhenStreamNotRegistered() public {
        NudgeStreamer unregistered = new NudgeStreamer(owner);
        ratchet.setNudgeStreamer(address(unregistered));

        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(minter);
        vm.expectRevert(NudgeStreamer.NudgeStreamer__NotRegistered.selector);
        ratchet.dispatch(minter, amount, "");
    }

    /// @dev The `bal > 0` guard is load-bearing: `collectNudge` reverts
    ///      `NudgeStreamer__ZeroAmount()` on zero, so a zero-balance dispatch must skip it
    ///      entirely rather than bricking.
    function test_dispatch_zeroBalanceDoesNotRevert() public {
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet starts empty");

        vm.prank(minter);
        ratchet.dispatch(minter, 0, "");

        assertEq(usdc.balanceOf(address(streamer)), 0, "nothing donated");
        assertEq(mintDebtHook.mintDebt(), 0, "no debt accrued for a zero dispatch");
    }

    /// @dev A zero-balance dispatch must also survive with NO streamer configured — the
    ///      guard short-circuits before the require.
    function test_dispatch_zeroBalanceDoesNotRequireStreamer() public {
        NudgeRatchet fresh = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        NudgeRatchetMintDebtHook freshHook = new NudgeRatchetMintDebtHook(owner, address(fresh), address(phUSD));
        fresh.setHook(IDispatchHook(address(freshHook)));
        fresh.setMinter(minter);

        vm.prank(minter);
        fresh.dispatch(minter, 0, "");
    }

    function test_dispatch_emitsNudgeCollectedWithRatchetAsDonor() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);

        // rewardPerSecond = buffer * PRECISION / duration.
        uint256 expectedRate = (amount * 1e18) / STREAM_DURATION;
        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeStreamer.NudgeCollected(batchMinterAddr, address(usdc), address(ratchet), amount, expectedRate);

        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");
    }

    /// @dev Half the window elapses -> half the donation is claimable by the batchMinter.
    ///      Integer division floors, so assert with a tolerance in the protocol's favour.
    function test_dispatch_donationStreamsLinearlyToBatchMinter() public {
        uint256 amount = 100e6;
        usdc.mint(address(ratchet), amount);
        vm.prank(minter);
        ratchet.dispatch(minter, amount, "");

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 pending = streamer.pendingStream(batchMinterAddr, address(usdc));
        assertApproxEqAbs(pending, amount / 2, 1, "half the donation accrued");

        batchMinterMock.flush(address(streamer), address(usdc));
        assertApproxEqAbs(usdc.balanceOf(batchMinterAddr), amount / 2, 1, "flush delivers the accrued half");
    }

    /// @dev Two independent NudgeRatchet donors accumulate into one (batchMinter, token)
    ///      stream; the rate is recomputed over the FULL window on each deposit.
    function test_twoDonors_accumulateBufferAndRecomputeRate() public {
        uint256 first = 100e6;
        usdc.mint(address(ratchet), first);
        vm.prank(minter);
        ratchet.dispatch(minter, first, "");

        NudgeRatchet second = _freshWiredRatchet();
        uint256 secondAmount = 50e6;
        usdc.mint(address(second), secondAmount);
        vm.prank(minter);
        second.dispatch(minter, secondAmount, "");

        (, uint256 buffer, uint256 rewardPerSecond,) = streamer.streams(batchMinterAddr, address(usdc));
        assertEq(buffer, first + secondAmount, "buffer accumulates across donors");
        assertEq(rewardPerSecond, ((first + secondAmount) * 1e18) / STREAM_DURATION, "rate recomputed on deposit");
        assertEq(usdc.balanceOf(address(streamer)), first + secondAmount, "streamer custodies both donations");
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

    /// @dev Audit M-04 smoking gun: previously this exercised dispatch through the
    ///      constructor-default no-op hook and asserted ONLY the USDC flow, so the
    ///      silent zero-debt path passed undetected. The real NudgeRatchetMintDebtHook
    ///      is now installed (in setUp) and we assert phUSD mint-debt accrues, so the
    ///      unwired zero-debt path can no longer pass silently.
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
        assertEq(usdc.balanceOf(address(streamer)), 10e6, "streamer should have received the tokens");
        assertEq(usdc.balanceOf(address(nftMinter)), 0, "NFTMinterV2 should have 0 balance");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "NudgeRatchet should have 0 balance");
        assertEq(nftMinter.balanceOf(nftRecipient, 1), 1, "NFT recipient should have 1 claim NFT");
        // Audit M-04: phUSD mint-debt must accrue for the 10e6 USDC dispatched
        // (default ratio 100%, scaled 6->18 dp). This assertion would have failed
        // under the old no-op default hook, exposing the zero-debt leak.
        assertEq(mintDebtHook.mintDebt(), 10e6 * 1e12, "phUSD mint-debt should accrue for the dispatched USDC");
    }
}
