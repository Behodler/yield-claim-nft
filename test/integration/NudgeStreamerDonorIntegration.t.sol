// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NFTMinterV2} from "../../src/NFTMinterV2.sol";
import {NudgeRatchet} from "../../src/dispatchers/NudgeRatchet.sol";
import {Uniboost} from "../../src/dispatchers/Uniboost.sol";
import {GatherV2} from "../../src/dispatchers/GatherV2.sol";
import {NudgeRatchetMintDebtHook} from "../../src/hooks/NudgeRatchetMintDebtHook.sol";
import {IDispatchHook} from "../../src/interfaces/IDispatchHook.sol";
import {MockMintable} from "../mocks/MockMintable.sol";

import {NudgeStreamer} from "phoenix-nft-staking/NudgeStreamer.sol";
import {BatchNFTMinterMultiToken} from "phoenix-nft-staking/BatchNFTMinterMultiToken.sol";
import {ITokenMinterV2 as IStakingTokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

/// @dev 6-decimal USDC stand-in — the nudge asset. The streamer performs NO decimal
///      normalisation (`PRECISION` is an internal fixed-point multiplier that cancels out),
///      so every buffer value and transfer below is in native 6-dp units.
contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev 18-decimal token the batch-minter's own mint path charges in. It MUST differ from the
///      nudge token or `setNudgeTokenWhitelist` reverts `BatchMint__RewardTokenIsPaymentToken`.
contract MockPayToken is ERC20 {
    constructor() ERC20("Pay", "PAY") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal UniV2 pair stub. `Uniboost`'s constructor only reads `token0()`/`token1()`;
///      this suite never calls `pool()`, so no router behaviour is needed.
contract MockUniV2PairStub {
    address public token0;
    address public token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }
}

/// @title NudgeStreamerDonorIntegration
/// @notice End-to-end integration of the story-046 donors against the REAL nudge stack:
///         a real `NudgeStreamer`, a real `BatchNFTMinterMultiToken`, a real `NFTMinterV2`
///         and the real `NudgeRatchet` / `Uniboost` dispatchers.
///
/// @dev There is deliberately **no `MockNudgeDonor`** here — the production dispatchers are
///      the donors, which is the whole point of the story. The only mocks are the two ERC20s
///      and a UniV2 pair stub that `Uniboost`'s constructor validates against.
///
///      `PromotionUniV2_Eth` hardcodes mainnet addresses and is therefore exercised against
///      the same real stack inside its own fork suite (`test/PromotionUniV2_Eth.t.sol`).
///
///      Wiring order matters and mirrors the ops runbook:
///        1. `batch.setTokenMinter` / `setDispatcherIndex` — `setNudgeTokenWhitelist` calls
///           `_resolvePaymentPath()`, which reads `configs(dispatcherIndex).dispatcher.primeToken()`.
///        2. `batch.setNudgeTokenWhitelist(usdc, true)`.
///        3. `streamer.registerStream(batch, usdc, duration)` — reverts
///           `NudgeStreamer__NotWhitelisted` if step 2 has not happened.
///        4. `dispatcher.setNudgeStreamer(streamer)` on each donor.
contract NudgeStreamerDonorIntegrationTest is Test {
    // ---- real contracts under test ----
    NudgeStreamer internal streamer;
    BatchNFTMinterMultiToken internal batch;
    NFTMinterV2 internal nftMinter;
    NudgeRatchet internal ratchet;
    Uniboost internal uniboost;
    GatherV2 internal payDispatcher;
    NudgeRatchetMintDebtHook internal ratchetHook;

    // ---- mocks ----
    MockUSDC6 internal usdc;
    MockPayToken internal payToken;
    MockMintable internal phUSD;
    MockUniV2PairStub internal uniPool;
    ERC20 internal boostTarget;

    address internal owner = address(this);
    address internal batcher = address(0xBA7C);
    address internal nftRecipient = address(0xFACE);
    address internal treasury = address(0xFEE5);
    address internal constant ROUTER_STUB = address(0x2011);

    /// @dev Non-zero index the batch-minter is pinned to; it must resolve to a real dispatcher.
    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant NUDGE_SIZE = 5;
    uint256 internal constant STREAM_DURATION = 1000;
    uint256 internal constant MINT_PRICE = 1e18;

    function setUp() public {
        usdc = new MockUSDC6();
        payToken = new MockPayToken();
        phUSD = new MockMintable();
        boostTarget = new MockPayToken();

        nftMinter = new NFTMinterV2(owner);

        // ---- the two real donors ----
        ratchet = new NudgeRatchet(address(usdc), address(0xDEAD), owner);
        ratchetHook = new NudgeRatchetMintDebtHook(owner, address(ratchet), address(phUSD));
        ratchet.setHook(IDispatchHook(address(ratchetHook)));
        ratchet.setMinter(address(nftMinter));

        uniPool = new MockUniV2PairStub(address(boostTarget), address(payToken));
        // The router is stored but never called: this suite exercises `_dispatch`, not `pool()`.
        uniboost = new Uniboost(address(usdc), ROUTER_STUB, address(uniPool), address(boostTarget), owner);
        uniboost.setMinter(address(nftMinter));

        // ---- the batch-minter's own (non-USDC) mint path ----
        payDispatcher = new GatherV2(address(payToken), treasury, owner);
        payDispatcher.setMinter(address(nftMinter));

        // NFTMinterV2 hands out sequential indices from 1. Register throwaway dispatchers so
        // the pay path lands on the non-trivial DISPATCHER_INDEX the reference suite uses.
        nftMinter.registerDispatcher(address(ratchet), 10e6, 0); // index 1
        nftMinter.registerDispatcher(address(uniboost), 10e6, 0); // index 2
        for (uint256 i = 3; i < DISPATCHER_INDEX; ++i) {
            nftMinter.registerDispatcher(address(uint160(0x1000 + i)), 1, 0);
        }
        nftMinter.registerDispatcher(address(payDispatcher), MINT_PRICE, 0); // index 7
        (address resolved,,,) = nftMinter.configs(DISPATCHER_INDEX);
        assertEq(resolved, address(payDispatcher), "pay dispatcher must sit on DISPATCHER_INDEX");

        // ---- the real nudge stack, wired in the documented order ----
        batch = new BatchNFTMinterMultiToken(owner);
        streamer = new NudgeStreamer(owner);

        batch.setTokenMinter(IStakingTokenMinterV2(address(nftMinter)));
        batch.setDispatcherIndex(DISPATCHER_INDEX);
        batch.setNudgeSize(NUDGE_SIZE);
        batch.setNudgeTokenWhitelist(address(usdc), true);
        batch.setNudgeStreamer(address(streamer));

        streamer.registerStream(address(batch), address(usdc), STREAM_DURATION);

        ratchet.setNudgeStreamer(address(streamer));
        ratchet.setBatchMinter(address(batch));
        uniboost.setNudgeStreamer(address(streamer));
        uniboost.setRecipient(address(batch));
        uniboost.setDonationSplit(50);
    }

    // =====================================================================
    // helpers
    // =====================================================================

    /// @dev Drives a REAL mint through `NFTMinterV2` so the ratchet donates exactly the way it
    ///      does in production: USDC is pulled from the user onto the dispatcher, then
    ///      `dispatch` sweeps it into the streamer.
    function _mintThroughRatchet(address user, uint256 price) internal {
        usdc.mint(user, price);
        vm.startPrank(user);
        usdc.approve(address(nftMinter), price);
        nftMinter.mint(1, user);
        vm.stopPrank();
    }

    function _mintThroughUniboost(address user, uint256 price) internal {
        usdc.mint(user, price);
        vm.startPrank(user);
        usdc.approve(address(nftMinter), price);
        nftMinter.mint(2, user);
        vm.stopPrank();
    }

    function _mins(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    /// @dev A qualifying batch mint through the batch-minter's pay path.
    function _qualifyingBatchMint(uint256 minReward) internal {
        uint256 payment = NUDGE_SIZE * MINT_PRICE;
        payToken.mint(batcher, payment);
        vm.startPrank(batcher);
        payToken.approve(address(batch), payment);
        batch.batchMint(NUDGE_SIZE, nftRecipient, payment, _mins(minReward));
        vm.stopPrank();
    }

    // =====================================================================
    // NudgeRatchet -> real streamer
    // =====================================================================

    function test_ratchetDispatch_updatesBufferAndRate_donorIsTheRatchet() public {
        uint256 price = 10e6;
        usdc.mint(address(ratchet), price);

        uint256 expectedRate = (price * 1e18) / STREAM_DURATION;
        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeStreamer.NudgeCollected(address(batch), address(usdc), address(ratchet), price, expectedRate);

        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), price, "");

        (uint256 duration, uint256 buffer, uint256 rewardPerSecond, uint256 lastUpdate) =
            streamer.streams(address(batch), address(usdc));
        assertEq(duration, STREAM_DURATION, "duration unchanged by a deposit");
        assertEq(buffer, price, "buffer holds the full donation");
        assertEq(rewardPerSecond, expectedRate, "rate recomputed over the full window");
        assertEq(lastUpdate, block.timestamp, "settle stamped");
        assertEq(usdc.balanceOf(address(streamer)), price, "streamer custodies the donation");
        assertEq(usdc.balanceOf(address(batch)), 0, "batch-minter is paid only as the stream releases");
    }

    /// @dev The full production path: user pays USDC to NFTMinterV2, which forwards it to the
    ///      ratchet, whose `dispatch` streams it toward the batch-minter.
    function test_realMintThroughRatchet_reachesTheStreamer() public {
        _mintThroughRatchet(address(0xA11CE), 10e6);

        assertEq(usdc.balanceOf(address(streamer)), 10e6, "mint payment reached the streamer");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet fully swept");
        assertEq(nftMinter.balanceOf(address(0xA11CE), 1), 1, "claim NFT minted");
        assertEq(ratchetHook.mintDebt(), 10e6 * 1e12, "mint-debt still accrues independently");
    }

    // =====================================================================
    // Linear release
    // =====================================================================

    function test_halfWindowElapsed_pendingStreamIsHalfTheDonation() public {
        uint256 donation = 100e6;
        usdc.mint(address(ratchet), donation);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), donation, "");

        vm.warp(block.timestamp + STREAM_DURATION / 2);

        // Integer division floors and dust stays in the buffer (protocol-favouring), so assert
        // with a tolerance rather than exact equality.
        assertApproxEqAbs(
            streamer.pendingStream(address(batch), address(usdc)), donation / 2, 1, "half the donation accrued"
        );
        assertEq(usdc.balanceOf(address(batch)), 0, "nothing settled until someone touches the stream");
    }

    // =====================================================================
    // batchMint flushes the stream (step 3.5)
    // =====================================================================

    function test_batchMint_flushesAccruedStreamIntoThePotAndPaysIt() public {
        uint256 donation = 100e6;
        usdc.mint(address(ratchet), donation);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), donation, "");

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 accrued = streamer.pendingStream(address(batch), address(usdc));
        assertGt(accrued, 0, "something must have accrued");

        _qualifyingBatchMint(0);

        // The flush pulled the accrued stream into the pot, which the qualifying batch then
        // paid out to `recipient` — so streamed funds counted for THIS mint.
        assertEq(usdc.balanceOf(nftRecipient), accrued, "flushed stream paid out as the nudge");
        assertEq(streamer.pendingStream(address(batch), address(usdc)), 0, "accrued portion consumed");
        assertEq(usdc.balanceOf(address(streamer)), donation - accrued, "remainder still buffered");
        assertEq(nftMinter.balanceOf(nftRecipient, DISPATCHER_INDEX), NUDGE_SIZE, "batch NFTs minted");
    }

    function test_batchMint_belowThreshold_flushesButDoesNotPayOut() public {
        uint256 donation = 100e6;
        usdc.mint(address(ratchet), donation);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), donation, "");

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 accrued = streamer.pendingStream(address(batch), address(usdc));

        uint256 count = NUDGE_SIZE - 1;
        uint256 payment = count * MINT_PRICE;
        payToken.mint(batcher, payment);
        vm.startPrank(batcher);
        payToken.approve(address(batch), payment);
        batch.batchMint(count, nftRecipient, payment, _mins(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(nftRecipient), 0, "no payout below the nudge threshold");
        assertEq(usdc.balanceOf(address(batch)), accrued, "flushed stream retained in the pot");
    }

    // =====================================================================
    // Uniboost -> the same real stack
    // =====================================================================

    function test_uniboostDispatch_reachesTheSameStream() public {
        uint256 amount = 20e6;
        usdc.mint(address(uniboost), amount);
        uint256 donation = amount / 2; // 50% split

        uint256 expectedRate = (donation * 1e18) / STREAM_DURATION;
        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeStreamer.NudgeCollected(address(batch), address(usdc), address(uniboost), donation, expectedRate);

        vm.prank(address(nftMinter));
        uniboost.dispatch(address(nftMinter), amount, "");

        (, uint256 buffer,,) = streamer.streams(address(batch), address(usdc));
        assertEq(buffer, donation, "half the dispatched prime streamed");
        assertEq(usdc.balanceOf(address(uniboost)), amount - donation, "the rest is retained for pool()");
    }

    function test_realMintThroughUniboost_reachesTheStreamer() public {
        _mintThroughUniboost(address(0xB0B), 10e6);
        assertEq(usdc.balanceOf(address(streamer)), 5e6, "50% of the mint payment streamed");
        assertEq(usdc.balanceOf(address(uniboost)), 5e6, "50% retained");
    }

    // =====================================================================
    // Two donors, one stream
    // =====================================================================

    function test_twoDispatchersAccumulateOneBufferAndRecomputeTheRate() public {
        uint256 ratchetDonation = 100e6;
        usdc.mint(address(ratchet), ratchetDonation);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), ratchetDonation, "");

        (, uint256 bufferAfterFirst, uint256 rateAfterFirst,) = streamer.streams(address(batch), address(usdc));
        assertEq(bufferAfterFirst, ratchetDonation, "first buffer");
        assertEq(rateAfterFirst, (ratchetDonation * 1e18) / STREAM_DURATION, "first rate");

        uint256 uniAmount = 60e6;
        uint256 uniDonation = uniAmount / 2;
        usdc.mint(address(uniboost), uniAmount);
        vm.prank(address(nftMinter));
        uniboost.dispatch(address(nftMinter), uniAmount, "");

        (, uint256 buffer, uint256 rate,) = streamer.streams(address(batch), address(usdc));
        assertEq(buffer, ratchetDonation + uniDonation, "buffer accumulates across donors");
        assertEq(rate, ((ratchetDonation + uniDonation) * 1e18) / STREAM_DURATION, "rate recomputed on deposit");
        assertGt(rate, rateAfterFirst, "second deposit raised the rate");
        assertEq(usdc.balanceOf(address(streamer)), ratchetDonation + uniDonation, "streamer holds both");
    }

    /// @dev A second deposit lands mid-window: the streamer settles the accrued portion to the
    ///      batch-minter at the OLD rate first, then buffers the new funds and recomputes.
    function test_secondDonationMidWindow_settlesFirstAtOldRate() public {
        uint256 first = 100e6;
        usdc.mint(address(ratchet), first);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), first, "");

        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 accrued = streamer.pendingStream(address(batch), address(usdc));

        uint256 uniAmount = 60e6;
        usdc.mint(address(uniboost), uniAmount);
        vm.prank(address(nftMinter));
        uniboost.dispatch(address(nftMinter), uniAmount, "");

        assertEq(usdc.balanceOf(address(batch)), accrued, "accrued settled to the batch-minter on deposit");
        (, uint256 buffer,,) = streamer.streams(address(batch), address(usdc));
        assertEq(buffer, first - accrued + uniAmount / 2, "buffer = unsettled remainder + new donation");
    }

    // =====================================================================
    // 6-decimal fidelity
    // =====================================================================

    /// @dev USDC is 6-dp and `PRECISION` is NOT decimal normalisation: every figure below is a
    ///      native 6-dp amount. The whole donation must be recoverable once the window closes.
    function test_sixDecimalAmountsStreamWithoutNormalisation() public {
        uint256 donation = 1_234_567; // 1.234567 USDC, deliberately not a round number
        usdc.mint(address(ratchet), donation);
        vm.prank(address(nftMinter));
        ratchet.dispatch(address(nftMinter), donation, "");

        (, uint256 buffer, uint256 rate,) = streamer.streams(address(batch), address(usdc));
        assertEq(buffer, donation, "buffer is the raw 6-dp amount, unscaled");
        // Sub-unit-per-second rate survives thanks to the 1e18 fixed point.
        assertEq(rate, (donation * 1e18) / STREAM_DURATION, "rate keeps sub-unit precision");
        assertGt(rate, 0, "rate must not truncate to zero for a 6-dp token");

        // Quarter window: floors in the protocol's favour, never over-pays.
        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 quarter = streamer.pendingStream(address(batch), address(usdc));
        assertLe(quarter, donation / 4, "floors downward, never over-pays");
        assertApproxEqAbs(quarter, donation / 4, 1, "quarter of the donation accrued");

        // Full window: the entire donation is claimable, no dust stranded by scaling.
        vm.warp(block.timestamp + STREAM_DURATION);
        assertEq(streamer.pendingStream(address(batch), address(usdc)), donation, "whole donation claimable");

        _qualifyingBatchMint(0);
        assertEq(usdc.balanceOf(nftRecipient), donation, "every native unit delivered");
        assertEq(usdc.balanceOf(address(streamer)), 0, "streamer fully drained");
    }

    // =====================================================================
    // Ops ordering
    // =====================================================================

    /// @dev Reversing whitelist and registerStream reverts `NudgeStreamer__NotWhitelisted`.
    function test_registerStreamBeforeWhitelist_reverts() public {
        BatchNFTMinterMultiToken fresh = new BatchNFTMinterMultiToken(owner);
        fresh.setTokenMinter(IStakingTokenMinterV2(address(nftMinter)));
        fresh.setDispatcherIndex(DISPATCHER_INDEX);

        vm.expectRevert(
            abi.encodeWithSelector(NudgeStreamer.NudgeStreamer__NotWhitelisted.selector, address(fresh), address(usdc))
        );
        streamer.registerStream(address(fresh), address(usdc), STREAM_DURATION);
    }
}
