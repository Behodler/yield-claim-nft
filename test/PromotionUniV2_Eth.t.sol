// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PromotionUniV2_Eth} from "../src/dispatchers/PromotionUniV2_Eth.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {IUniswapV2Router02} from "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../src/interfaces/uniswap/IUniswapV2Pair.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {GatherV2} from "../src/dispatchers/GatherV2.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
import {NudgeStreamer} from "phoenix-nft-staking/NudgeStreamer.sol";
import {BatchNFTMinterMultiToken} from "phoenix-nft-staking/BatchNFTMinterMultiToken.sol";
import {ITokenMinterV2 as IStakingTokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Uniswap V2 factory interface — used to resolve the pair addresses the router
///      auto-creates on the first `addLiquidity`.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @dev Simple mintable ERC20 standing in for a partner's promotion token.
contract MockPromoToken is ERC20 {
    constructor() ERC20("Promo", "PROMO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title PromotionUniV2_Eth — mainnet fork tests
/// @notice The multi-protocol flow (SKY PSM + Uniswap V2 + native ETH) hardcodes live mainnet
///         addresses and cannot be faithfully mocked, so these tests run against a mainnet fork.
///         This is the repo's first fork test.
///
///         Leg A (story 049) swaps sUSDS→phUSD through the phUSD/sUSDS Uniswap V2 pair. That pair
///         does not exist on mainnet at `FORK_BLOCK`, so `setUp` creates and seeds it via the real
///         Router02 (which auto-creates it through the real factory).
///
/// @dev RPC wiring: set `MAINNET_RPC_URL` (or the `.envrc` name `RPC_MAINNET`) to an ARCHIVE
///      endpoint (Alchemy/Infura) — `FORK_BLOCK` pins historical state that free full-nodes do not
///      serve. With neither variable set the whole suite SKIPS (same convention as
///      `UniPoolerV2.fork.t.sol`); there is no public-node fallback.
contract PromotionUniV2_EthForkTest is Test {
    using SafeERC20 for IERC20;

    // ---- live mainnet addresses (mirror the dispatcher constants) ----
    address internal constant phUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address internal constant sUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    /// @dev Recent mainnet block where phUSD, sUSDS, the SKY PSM, and the UniV2 router are all
    ///      live. Requires an archive RPC to fork at this height.
    uint256 internal constant FORK_BLOCK = 25_550_000;

    PromotionUniV2_Eth internal dispatcher;
    MockPromoToken internal promo;
    address internal phusdPromoPair;
    /// @dev The phUSD/sUSDS UniV2 pair Leg A swaps through — created and seeded in `setUp`.
    address internal phusdSusdsPair;

    /// @dev Seed depth for the phUSD/sUSDS pair, in dollars per side (phUSD at $1 peg).
    uint256 internal constant PHUSD_SUSDS_SEED = 1_000_000e18;

    address internal owner = address(this);
    address internal minter = address(0xBEEF);
    address internal nonOwner = address(0xCAFE);
    address internal authorizedPooler = address(0xD00D);

    // ---- story 046: real NudgeStreamer + real MultiToken batch-minter, deployed IN-FORK ----
    // The streamer is not on mainnet, so there is no deployed address to look up.
    NudgeStreamer internal streamer;
    BatchNFTMinterMultiToken internal batch;
    NFTMinterV2 internal nftMinter;
    GatherV2 internal payDispatcher;

    /// @dev The batch-minter's own mint currency. MUST differ from the nudge token (USDC) or
    ///      `setNudgeTokenWhitelist` reverts `BatchMint__RewardTokenIsPaymentToken`.
    address internal payTokenAddr;

    uint256 internal constant STREAM_DURATION = 1000;
    uint256 internal constant NUDGE_SIZE = 5;

    /// @dev `batchMinterAddr` is the REAL `BatchNFTMinterMultiToken` deployed in `setUp`.
    address internal batchMinterAddr;

    function setUp() public {
        // Fork mainnet. Prefer an archive RPC via env (accept either MAINNET_RPC_URL or the RPC_MAINNET
        // name used by the local .envrc); fall back to a public node for head runs.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", vm.envOr("RPC_MAINNET", string("")));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // no archive RPC configured: skip the whole suite cleanly
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        // Leg A's venue: the phUSD/sUSDS UniV2 pair. Absent on mainnet at FORK_BLOCK — create it.
        require(IUniswapV2Factory(UNIV2_FACTORY).getPair(sUSDS, phUSD) == address(0), "phUSD/sUSDS pair exists");
        _seedPhusdSusdsPair(PHUSD_SUSDS_SEED);
        phusdSusdsPair = IUniswapV2Factory(UNIV2_FACTORY).getPair(sUSDS, phUSD);
        require(phusdSusdsPair != address(0), "phUSD/sUSDS pair not created");

        promo = new MockPromoToken();

        // Seed the LP-target pair (phUSD/promo) via the router (auto-creates the pair), then
        // resolve its address from the factory for the constructor.
        _seedPair(phUSD, 100_000e18, address(promo), 100_000e18);
        phusdPromoPair = IUniswapV2Factory(UNIV2_FACTORY).getPair(phUSD, address(promo));
        require(phusdPromoPair != address(0), "pair not created");

        dispatcher = new PromotionUniV2_Eth(address(promo), phusdPromoPair, owner);
        dispatcher.setMinter(minter);
        dispatcher.setAuthorizedPooler(authorizedPooler, true);

        // Seed the ETH->promo route pair (WETH/promo). USDC/WETH already has deep mainnet liquidity.
        _seedPair(WETH, 100e18, address(promo), 300_000e18);

        _deployNudgeStack();
    }

    /// @dev Story 046: stands up the REAL nudge stack in-fork and wires it in the documented
    ///      ops order. `setNudgeTokenWhitelist` derives the payment token via
    ///      `tokenMinter.configs(dispatcherIndex).dispatcher.primeToken()`, so the minter and
    ///      dispatcher index must be configured BEFORE the whitelist call, and `registerStream`
    ///      requires the whitelist entry to already exist.
    function _deployNudgeStack() internal {
        // A pay path whose prime token is NOT USDC (USDC is the nudge asset here).
        MockPromoToken payToken = new MockPromoToken();
        payTokenAddr = address(payToken);

        nftMinter = new NFTMinterV2(owner);
        payDispatcher = new GatherV2(payTokenAddr, address(0xFEE5), owner);
        payDispatcher.setMinter(address(nftMinter));
        nftMinter.registerDispatcher(address(payDispatcher), 1e18, 0); // index 1

        batch = new BatchNFTMinterMultiToken(owner);
        streamer = new NudgeStreamer(owner);
        batchMinterAddr = address(batch);

        batch.setTokenMinter(IStakingTokenMinterV2(address(nftMinter)));
        batch.setDispatcherIndex(1);
        batch.setNudgeSize(NUDGE_SIZE);
        // 1. whitelist on the batch-minter ...
        batch.setNudgeTokenWhitelist(USDC, true);
        batch.setNudgeStreamer(address(streamer));
        // 2. ... then register the stream ...
        streamer.registerStream(batchMinterAddr, USDC, STREAM_DURATION);
        // 3. ... then point the donor dispatcher at the streamer.
        dispatcher.setNudgeStreamer(address(streamer));
    }

    // =====================================================================
    // helpers
    // =====================================================================

    /// @dev Deal both tokens to this test contract and add liquidity via the router (creating the
    ///      pair on first call). WETH/phUSD are dealt via storage; promo is minted.
    function _seedPair(address tokenA, uint256 amtA, address tokenB, uint256 amtB) internal {
        _provide(tokenA, amtA);
        _provide(tokenB, amtB);
        IERC20(tokenA).forceApprove(UNIV2_ROUTER, amtA);
        IERC20(tokenB).forceApprove(UNIV2_ROUTER, amtB);
        IUniswapV2Router02(UNIV2_ROUTER).addLiquidity(
            tokenA, tokenB, amtA, amtB, 0, 0, address(this), block.timestamp
        );
    }

    /// @dev Seeds the phUSD/sUSDS pair at the $1 phUSD peg: `dollars` phUSD against the sUSDS
    ///      shares worth `dollars` USDS (sUSDS trades above $1, so fewer shares than phUSD).
    function _seedPhusdSusdsPair(uint256 dollars) internal {
        uint256 shares = IERC4626(sUSDS).convertToShares(dollars);
        _seedPair(sUSDS, shares, phUSD, dollars);
    }

    /// @dev Returns the pair's (sUSDS, phUSD) reserves, order-normalised.
    function _phusdSusdsReserves() internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(phusdSusdsPair).getReserves();
        (rS, rP) =
            IUniswapV2Pair(phusdSusdsPair).token0() == sUSDS ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _provide(address token, uint256 amount) internal {
        if (token == address(promo)) {
            promo.mint(address(this), amount);
        } else {
            deal(token, address(this), amount);
        }
    }

    /// @dev Seed retained prime USDC on the dispatcher via a real dispatch (no donation).
    function _seedPrime(uint256 amount) internal {
        deal(USDC, address(dispatcher), amount);
        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");
    }

    // =====================================================================
    // constructor / views
    // =====================================================================

    function test_constructor_revertsWithZeroPromotionToken() public {
        vm.expectRevert("PromotionUniV2_Eth: zero promotion token");
        new PromotionUniV2_Eth(address(0), phusdPromoPair, owner);
    }

    function test_constructor_revertsWhenPairMissingToken() public {
        // A phUSD/USDC pair does not contain the promotion token.
        _seedPair(phUSD, 10_000e18, USDC, 10_000e6);
        address badPair = IUniswapV2Factory(UNIV2_FACTORY).getPair(phUSD, USDC);
        vm.expectRevert("PromotionUniV2_Eth: pair missing token");
        new PromotionUniV2_Eth(address(promo), badPair, owner);
    }

    function test_constructor_authVersionInitializedToOne() public view {
        assertEq(dispatcher.authVersion(), 1);
    }

    function test_primeToken_returnsUSDC() public view {
        assertEq(dispatcher.primeToken(), USDC);
    }

    function test_constants_matchSpec() public view {
        assertEq(dispatcher.phUSD(), phUSD);
        assertEq(dispatcher.USDC(), USDC);
        assertEq(dispatcher.WETH(), WETH);
        assertEq(dispatcher.UNIV2_ROUTER(), UNIV2_ROUTER);
        assertEq(dispatcher.psm(), 0xA188EEC8F81263234dA3622A406892F3D630f98c);
        assertEq(dispatcher.maxTin(), 1e16);
        assertEq(dispatcher.promotionToken(), address(promo));
        assertEq(dispatcher.targetPool(), phusdPromoPair);
    }

    function test_ethToPromotionPath_defaultsToDirect() public view {
        address[] memory path = dispatcher.ethToPromotionPath();
        assertEq(path.length, 2);
        assertEq(path[0], WETH);
        assertEq(path[1], address(promo));
    }

    // =====================================================================
    // setPool
    // =====================================================================

    function test_setPool_repoints() public {
        // A second phUSD/promo pair to re-point at (same token set). Reuse the existing pair since
        // UniV2 has one canonical pair per token set; re-pointing to it must succeed.
        dispatcher.setPool(phusdPromoPair);
        assertEq(dispatcher.targetPool(), phusdPromoPair);
    }

    function test_setPool_revertsZero() public {
        vm.expectRevert("PromotionUniV2_Eth: zero pool");
        dispatcher.setPool(address(0));
    }

    function test_setPool_revertsBadPair() public {
        _seedPair(phUSD, 10_000e18, USDC, 10_000e6);
        address badPair = IUniswapV2Factory(UNIV2_FACTORY).getPair(phUSD, USDC);
        vm.expectRevert("PromotionUniV2_Eth: pair missing token");
        dispatcher.setPool(badPair);
    }

    function test_setPool_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setPool(phusdPromoPair);
    }

    // =====================================================================
    // setEthToPromotionPath
    // =====================================================================

    function test_setEthToPromotionPath_storesCustom() public {
        address[] memory custom = new address[](3);
        custom[0] = WETH;
        custom[1] = USDC;
        custom[2] = address(promo);
        dispatcher.setEthToPromotionPath(custom);
        address[] memory stored = dispatcher.ethToPromotionPath();
        assertEq(stored.length, 3);
        assertEq(stored[1], USDC);
    }

    function test_setEthToPromotionPath_revertsStartNotWETH() public {
        address[] memory bad = new address[](2);
        bad[0] = USDC;
        bad[1] = address(promo);
        vm.expectRevert("PromotionUniV2_Eth: path start not WETH");
        dispatcher.setEthToPromotionPath(bad);
    }

    function test_setEthToPromotionPath_revertsEndNotPromotion() public {
        address[] memory bad = new address[](2);
        bad[0] = WETH;
        bad[1] = USDC;
        vm.expectRevert("PromotionUniV2_Eth: path end not promotion");
        dispatcher.setEthToPromotionPath(bad);
    }

    function test_setEthToPromotionPath_revertsTooShort() public {
        address[] memory bad = new address[](1);
        bad[0] = WETH;
        vm.expectRevert("PromotionUniV2_Eth: path too short");
        dispatcher.setEthToPromotionPath(bad);
    }

    function test_setEthToPromotionPath_revertsForNonOwner() public {
        address[] memory custom = new address[](2);
        custom[0] = WETH;
        custom[1] = address(promo);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setEthToPromotionPath(custom);
    }

    // =====================================================================
    // owner-gated setters
    // =====================================================================

    function test_setPSM_storesAndEmits() public {
        address newPSM = address(0x1234);
        vm.expectEmit(false, false, false, true);
        emit PromotionUniV2_Eth.PSMSet(newPSM);
        dispatcher.setPSM(newPSM);
        assertEq(dispatcher.psm(), newPSM);
    }

    function test_setPSM_revertsZero() public {
        vm.expectRevert("PromotionUniV2_Eth: zero psm");
        dispatcher.setPSM(address(0));
    }

    function test_setPSM_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setPSM(address(0x1234));
    }

    function test_setMaxTin_storesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit PromotionUniV2_Eth.MaxTinSet(5e16);
        dispatcher.setMaxTin(5e16);
        assertEq(dispatcher.maxTin(), 5e16);
    }

    function test_setMaxTin_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setMaxTin(5e16);
    }

    function test_setDonationSplit_revertsAbove100() public {
        vm.expectRevert("PromotionUniV2_Eth: split > 100");
        dispatcher.setDonationSplit(101);
    }

    function test_setDonationSplit_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setDonationSplit(10);
    }

    function test_setBatchMinter_zeroAllowed() public {
        dispatcher.setBatchMinter(batchMinterAddr);
        dispatcher.setBatchMinter(address(0));
        assertEq(dispatcher.batchMinter(), address(0));
    }

    function test_setBatchMinter_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setBatchMinter(batchMinterAddr);
    }

    // =====================================================================
    // dispatch / _dispatch (donation)
    // =====================================================================

    function _enableDonation(uint256 split) internal {
        dispatcher.setBatchMinter(batchMinterAddr);
        dispatcher.setDonationSplit(split);
    }

    function test_dispatch_donationEnabled_forwardsSplitAndRetainsRemainder() public {
        _enableDonation(50);
        uint256 amount = 1000e6;
        deal(USDC, address(dispatcher), amount);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");

        // Story 046: the donation is pulled into the streamer's buffer for `batchMinter`,
        // not pushed to it. No time has elapsed, so nothing has streamed out yet.
        assertEq(IERC20(USDC).balanceOf(address(streamer)), 500e6, "50% routed into the streamer");
        assertEq(IERC20(USDC).balanceOf(batchMinterAddr), 0, "batchMinter receives it only as it streams");
        (, uint256 buffer,,) = streamer.streams(batchMinterAddr, USDC);
        assertEq(buffer, 500e6, "stream buffer equals the donation");
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), 500e6, "remainder retained");
        assertEq(IERC20(USDC).allowance(address(dispatcher), address(streamer)), 0, "no residual allowance");
    }

    function test_dispatch_donationDisabled_batchMinterZero_retainsFull() public {
        dispatcher.setDonationSplit(50); // batchMinter unset => disabled
        uint256 amount = 1000e6;
        deal(USDC, address(dispatcher), amount);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");

        assertEq(IERC20(USDC).balanceOf(batchMinterAddr), 0);
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), amount);
    }

    function test_dispatch_donationDisabled_splitZero_retainsFull() public {
        dispatcher.setBatchMinter(batchMinterAddr); // split 0 => disabled
        uint256 amount = 1000e6;
        deal(USDC, address(dispatcher), amount);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");

        assertEq(IERC20(USDC).balanceOf(batchMinterAddr), 0);
        assertEq(IERC20(USDC).balanceOf(address(streamer)), 0, "streamer untouched when donation disabled");
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), amount);
    }

    // =====================================================================
    // setNudgeStreamer / streamed donation (story 046)
    // =====================================================================

    function test_setNudgeStreamer_storesAndEmits() public {
        address newStreamer = address(0xB0B);
        vm.expectEmit(true, true, false, true);
        emit PromotionUniV2_Eth.NudgeStreamerUpdated(address(streamer), newStreamer);
        dispatcher.setNudgeStreamer(newStreamer);
        assertEq(dispatcher.nudgeStreamer(), newStreamer);
    }

    function test_setNudgeStreamer_revertsWithZeroAddress() public {
        vm.expectRevert("PromotionUniV2_Eth: zero nudgeStreamer");
        dispatcher.setNudgeStreamer(address(0));
    }

    function test_setNudgeStreamer_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setNudgeStreamer(address(0xB0B));
    }

    /// @dev The streamer requirement is scoped to the live-donation branch.
    function test_dispatch_revertsWhenDonationEnabledAndStreamerUnset() public {
        PromotionUniV2_Eth fresh = new PromotionUniV2_Eth(address(promo), phusdPromoPair, owner);
        fresh.setMinter(minter);
        fresh.setBatchMinter(batchMinterAddr);
        fresh.setDonationSplit(50);
        assertEq(fresh.nudgeStreamer(), address(0), "streamer starts unset");

        deal(USDC, address(fresh), 1000e6);
        vm.prank(minter);
        vm.expectRevert("PromotionUniV2_Eth: nudgeStreamer unset");
        fresh.dispatch(minter, 1000e6, "");
    }

    /// @dev ...so a donation-disabled deployment stays dispatchable with no streamer set.
    function test_dispatch_donationDisabled_succeedsWithNoStreamerSet() public {
        PromotionUniV2_Eth fresh = new PromotionUniV2_Eth(address(promo), phusdPromoPair, owner);
        fresh.setMinter(minter);
        assertEq(fresh.nudgeStreamer(), address(0), "streamer starts unset");

        deal(USDC, address(fresh), 1000e6);
        vm.prank(minter);
        fresh.dispatch(minter, 1000e6, "");

        assertEq(IERC20(USDC).balanceOf(address(fresh)), 1000e6, "full amount retained, no revert");
    }

    /// @dev Documented ops failure mode: streamer wired but `registerStream` forgotten.
    function test_dispatch_revertsWhenStreamNotRegistered() public {
        NudgeStreamer unregistered = new NudgeStreamer(owner);
        dispatcher.setNudgeStreamer(address(unregistered));
        _enableDonation(50);

        deal(USDC, address(dispatcher), 1000e6);
        vm.prank(minter);
        vm.expectRevert(NudgeStreamer.NudgeStreamer__NotRegistered.selector);
        dispatcher.dispatch(minter, 1000e6, "");
    }

    /// @dev The `donationAmount > 0` guard is load-bearing (`collectNudge` reverts
    ///      `NudgeStreamer__ZeroAmount()` on zero): a split that floors to zero must not brick.
    function test_dispatch_donationRoundingToZeroDoesNotRevert() public {
        _enableDonation(50);
        deal(USDC, address(dispatcher), 1);

        vm.prank(minter);
        dispatcher.dispatch(minter, 1, "");

        assertEq(IERC20(USDC).balanceOf(address(streamer)), 0, "nothing donated");
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), 1, "the whole 1 wei retained");
    }

    function test_dispatch_emitsNudgeCollectedWithDispatcherAsDonor() public {
        _enableDonation(50);
        uint256 amount = 1000e6;
        deal(USDC, address(dispatcher), amount);

        uint256 donation = amount / 2;
        uint256 expectedRate = (donation * 1e18) / STREAM_DURATION;
        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeStreamer.NudgeCollected(batchMinterAddr, USDC, address(dispatcher), donation, expectedRate);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");
    }

    /// @dev End to end against the REAL stack: the donation streams linearly and
    ///      `batchMint` (step 3.5) flushes the accrued portion into the batch-minter's pot.
    function test_dispatch_donationStreamsAndBatchMintFlushesIt() public {
        _enableDonation(50);
        uint256 amount = 1000e6;
        deal(USDC, address(dispatcher), amount);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, "");

        uint256 donation = amount / 2;
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        assertApproxEqAbs(streamer.pendingStream(batchMinterAddr, USDC), donation / 2, 1, "half accrued");

        // A qualifying batchMint flushes the stream into the pot and pays it to `recipient`.
        address batcher = address(0xBA7C);
        address nftRecipient = address(0xFACE);
        uint256 payment = NUDGE_SIZE * 1e18;
        MockPromoToken(payTokenAddr).mint(batcher, payment);
        vm.startPrank(batcher);
        IERC20(payTokenAddr).approve(address(batch), payment);
        uint256[] memory mins = new uint256[](1);
        batch.batchMint(NUDGE_SIZE, nftRecipient, payment, mins);
        vm.stopPrank();

        assertApproxEqAbs(
            IERC20(USDC).balanceOf(nftRecipient), donation / 2, 1, "flushed stream paid out as the nudge"
        );
        assertEq(streamer.pendingStream(batchMinterAddr, USDC), 0, "accrued portion consumed by the flush");
        assertApproxEqAbs(
            IERC20(USDC).balanceOf(address(streamer)), donation - donation / 2, 1, "remainder still buffered"
        );
    }

    function test_dispatch_revertsWhenCalledByNonMinter() public {
        deal(USDC, address(dispatcher), 1000e6);
        vm.prank(nonOwner);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        dispatcher.dispatch(nonOwner, 1000e6, "");
    }

    function test_dispatch_revertsWhenPaused() public {
        deal(USDC, address(dispatcher), 1000e6);
        vm.prank(minter);
        dispatcher.pause();
        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        dispatcher.dispatch(minter, 1000e6, "");
    }

    function test_dispatch_invokesHookWithGrossAmount() public {
        MockDispatchHook hook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(hook)));
        _enableDonation(50);

        uint256 amount = 1000e6;
        bytes memory payload = hex"cafebabe";
        deal(USDC, address(dispatcher), amount);

        vm.prank(minter);
        dispatcher.dispatch(minter, amount, payload);

        assertEq(hook.callCount(), 1);
        assertEq(hook.lastAmount(), amount, "hook receives gross amount, not net of donation");
        assertEq(hook.lastExtraData(), payload);
    }

    // =====================================================================
    // pool end-to-end
    // =====================================================================

    function test_pool_endToEnd_bothLegsAndLPLandsOnDispatcher() public {
        uint256 amount = 5000e6; // 5000 USDC
        _seedPrime(amount);

        uint256 lpBefore = IERC20(phusdPromoPair).balanceOf(address(dispatcher));

        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 0, 0);

        // USDC fully consumed across both legs.
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), 0, "USDC fully consumed");
        // LP minted and landed on the dispatcher.
        uint256 lpAfter = IERC20(phusdPromoPair).balanceOf(address(dispatcher));
        assertGt(lpAfter, lpBefore, "LP minted to dispatcher");
        // No native ETH stranded (Leg B fully consumed the unwrapped ETH).
        assertEq(address(dispatcher).balance, 0, "no ETH stranded");
    }

    function test_pool_revertsWhenNothingToPool() public {
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: nothing to pool");
        dispatcher.pool(0, 1, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenAmountExceedsBalance() public {
        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient prime");
        dispatcher.pool(1000e6 + 1, 1, 0, 0, 0, 0);
    }

    function test_pool_revertsForNonAuthorizedPooler() public {
        _seedPrime(1000e6);
        vm.prank(nonOwner);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 1, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenMinPhusdOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"); // Leg A V2 floor unmet
        dispatcher.pool(5000e6, type(uint256).max, 0, 0, 0, 0);
    }

    // =====================================================================
    // Leg A — sUSDS→phUSD through the phUSD/sUSDS Uniswap V2 pair (story 049)
    // =====================================================================

    /// @dev A zero phUSD floor is an unbounded-slippage swap; it must revert loudly, before any
    ///      USDC moves.
    function test_pool_revertsOnZeroPhusdFloor() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: zero phUSD floor");
        dispatcher.pool(5000e6, 0, 0, 0, 0, 0);
    }

    /// @dev Leg A buys phUSD through the seeded V2 pair: the pair's sUSDS reserve rises by the
    ///      shares paid in, its phUSD reserve falls by exactly the phUSD acquired, and that amount
    ///      is the constant-product (0.3% fee) output for those shares on the pre-swap reserves.
    function test_legA_swapsThroughPhusdSusdsV2Pair() public {
        uint256 amount = 5000e6;
        _seedPrime(amount);
        (uint256 rS0, uint256 rP0) = _phusdSusdsReserves();
        uint256 supplyBefore = IERC20(phUSD).totalSupply();

        vm.recordLogs();
        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 0, 0);
        (, uint256 phusdAcquired, uint256 phusdBurned,,) = _extractPooled(vm.getRecordedLogs());

        (uint256 rS1, uint256 rP1) = _phusdSusdsReserves();
        uint256 sharesIn = rS1 - rS0;
        assertGt(sharesIn, 0, "sUSDS paid into the phUSD/sUSDS pair");
        assertGt(phusdAcquired, 0, "phUSD received from Leg A");
        assertEq(rP0 - rP1, phusdAcquired, "pair phUSD reserve fell by exactly the phUSD acquired");

        uint256 inWithFee = sharesIn * 997;
        uint256 expectedOut = (inWithFee * rP0) / (rS0 * 1000 + inWithFee);
        assertEq(phusdAcquired, expectedOut, "Leg A output is the V2 quote on pre-swap reserves");

        // ~$3000 of USDC at the $1 seed peg, minus PSM fee and V2 fee/impact on a $1M-deep pair.
        assertGt(phusdAcquired, 2900e18, "Leg A acquired ~3000 phUSD");
        assertLt(phusdAcquired, 3000e18, "Leg A cannot beat the peg");

        // The sUSDS bought is fully spent on the swap; none is stranded on the dispatcher.
        assertEq(IERC20(sUSDS).balanceOf(address(dispatcher)), 0, "no sUSDS stranded");
        assertEq(supplyBefore - IERC20(phUSD).totalSupply(), phusdBurned, "half burned as before");
    }

    /// @dev `minPhusdOut` is honoured at the exact boundary: the precise V2 output passes, one wei
    ///      more reverts with the router's own floor error.
    function test_legA_minPhusdOutHonouredAtExactBoundary() public {
        uint256 amount = 5000e6;
        _seedPrime(amount);

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 0, 0);
        (, uint256 phusdAcquired,,,) = _extractPooled(vm.getRecordedLogs());
        vm.revertToState(snap);

        uint256 snap2 = vm.snapshotState();
        vm.prank(authorizedPooler);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        dispatcher.pool(amount, phusdAcquired + 1, 0, 0, 0, 0);
        vm.revertToState(snap2);

        vm.recordLogs();
        vm.prank(authorizedPooler);
        dispatcher.pool(amount, phusdAcquired, 0, 0, 0, 0);
        (, uint256 again,,,) = _extractPooled(vm.getRecordedLogs());
        assertEq(again, phusdAcquired, "exact floor accepted");
    }

    /// @dev Leg A no longer touches the Balancer V3 vault at all: nothing is ever approved to it
    ///      and no sUSDS reaches it.
    function test_legA_doesNotTouchBalancerVault() public {
        address balancerVault = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
        uint256 vaultSusdsBefore = IERC20(sUSDS).balanceOf(balancerVault);
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        dispatcher.pool(5000e6, 1, 0, 0, 0, 0);
        assertEq(IERC20(sUSDS).balanceOf(balancerVault), vaultSusdsBefore, "no sUSDS sent to Balancer vault");
    }

    function test_pool_revertsWhenMinEthOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 USDC->ETH INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 1, type(uint256).max, 0, 0, 0);
    }

    function test_pool_revertsWhenMinPromoOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 ETH->promo INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 1, 0, type(uint256).max, 0, 0);
    }

    function test_pool_revertsWhenMinWbtcOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 USDC->WBTC INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 1, 0, 0, type(uint256).max, 0);
    }

    function test_pool_revertsWhenMinLPNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient LP");
        dispatcher.pool(5000e6, 1, 0, 0, 0, type(uint256).max);
    }

    function test_pool_revertsWhenPaused() public {
        _seedPrime(5000e6);
        vm.prank(minter);
        dispatcher.pause();
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        dispatcher.pool(5000e6, 1, 0, 0, 0, 0);
    }

    function test_pool_doesNotInvokeHook() public {
        MockDispatchHook hook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(hook)));
        _seedPrime(5000e6);
        assertEq(hook.callCount(), 1, "dispatch invoked hook once");

        vm.prank(authorizedPooler);
        dispatcher.pool(5000e6, 1, 0, 0, 0, 0);
        assertEq(hook.callCount(), 1, "pool() must not invoke the dispatch hook");
    }

    // =====================================================================
    // pooler auth
    // =====================================================================

    function test_setAuthorizedPooler_revertsZero() public {
        vm.expectRevert("PromotionUniV2_Eth: zero pooler");
        dispatcher.setAuthorizedPooler(address(0), true);
    }

    function test_setAuthorizedPooler_deauthorizeRevokes() public {
        address p = address(0x3333);
        dispatcher.setAuthorizedPooler(p, true);
        dispatcher.setAuthorizedPooler(p, false);
        assertEq(dispatcher.poolerAuthVersion(p), 0);

        _seedPrime(1000e6);
        vm.prank(p);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 1, 0, 0, 0, 0);
    }

    function test_incrementAuthVersion_massRevoke() public {
        dispatcher.incrementAuthVersion();
        assertEq(dispatcher.authVersion(), 2);

        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 1, 0, 0, 0, 0);

        // Re-authorize at the new version works.
        dispatcher.setAuthorizedPooler(authorizedPooler, true);
        assertEq(dispatcher.poolerAuthVersion(authorizedPooler), 2);
    }

    function test_incrementAuthVersion_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.incrementAuthVersion();
    }

    // =====================================================================
    // rescue / receive
    // =====================================================================

    function test_rescueERC20_movesToken() public {
        deal(USDC, address(dispatcher), 1000e6);
        address to = address(0xBBBB);
        dispatcher.rescueERC20(USDC, to, 1000e6);
        assertEq(IERC20(USDC).balanceOf(to), 1000e6);
    }

    function test_rescueERC20_withdrawsLPWhilePaused() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        dispatcher.pool(5000e6, 1, 0, 0, 0, 0);
        uint256 lp = IERC20(phusdPromoPair).balanceOf(address(dispatcher));
        assertGt(lp, 0, "dispatcher holds LP");

        vm.prank(minter);
        dispatcher.pause();

        address to = address(0xCCCC);
        dispatcher.rescueERC20(phusdPromoPair, to, lp); // works while paused
        assertEq(IERC20(phusdPromoPair).balanceOf(to), lp);
    }

    function test_rescueERC20_revertsZeroRecipient() public {
        deal(USDC, address(dispatcher), 1000e6);
        vm.expectRevert("PromotionUniV2_Eth: zero recipient");
        dispatcher.rescueERC20(USDC, address(0), 1000e6);
    }

    function test_rescueERC20_revertsForNonOwner() public {
        deal(USDC, address(dispatcher), 1000e6);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.rescueERC20(USDC, nonOwner, 1000e6);
    }

    function test_receive_and_rescueETH() public {
        // The dispatcher's deterministic deploy address may already carry trace ETH on the fork
        // (mainnet has 1 wei sitting at it), so assert on balance deltas rather than absolutes.
        uint256 startBal = address(dispatcher).balance;

        // receive() accepts native ETH.
        vm.deal(address(this), 5 ether);
        (bool sent,) = address(dispatcher).call{value: 3 ether}("");
        assertTrue(sent, "receive() accepted ETH");
        assertEq(address(dispatcher).balance, startBal + 3 ether);

        // rescueETH moves it out (owner-gated, non-zero recipient). `to` may also carry pre-existing
        // fork ETH, so assert on its delta as well.
        address payable to = payable(address(0xEEEE));
        uint256 toStart = to.balance;
        dispatcher.rescueETH(to, 3 ether);
        assertEq(to.balance, toStart + 3 ether);
        assertEq(address(dispatcher).balance, startBal);
    }

    function test_rescueETH_revertsZeroRecipient() public {
        vm.deal(address(dispatcher), 1 ether);
        vm.expectRevert("PromotionUniV2_Eth: zero recipient");
        dispatcher.rescueETH(address(0), 1 ether);
    }

    function test_rescueETH_revertsForNonOwner() public {
        vm.deal(address(dispatcher), 1 ether);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.rescueETH(payable(nonOwner), 1 ether);
    }

    // =====================================================================
    // usdcToWbtcPath (Leg C routing)
    // =====================================================================

    function test_usdcToWbtcPath_defaultsToDirect() public view {
        address[] memory path = dispatcher.usdcToWbtcPath();
        assertEq(path.length, 2);
        assertEq(path[0], USDC);
        assertEq(path[1], WBTC);
    }

    function test_setUsdcToWbtcPath_storesCustom() public {
        address[] memory custom = new address[](3);
        custom[0] = USDC;
        custom[1] = WETH;
        custom[2] = WBTC;
        dispatcher.setUsdcToWbtcPath(custom);
        address[] memory stored = dispatcher.usdcToWbtcPath();
        assertEq(stored.length, 3);
        assertEq(stored[1], WETH);
    }

    function test_setUsdcToWbtcPath_revertsStartNotUSDC() public {
        address[] memory bad = new address[](2);
        bad[0] = WETH;
        bad[1] = WBTC;
        vm.expectRevert("PromotionUniV2_Eth: path start not USDC");
        dispatcher.setUsdcToWbtcPath(bad);
    }

    function test_setUsdcToWbtcPath_revertsEndNotWBTC() public {
        address[] memory bad = new address[](2);
        bad[0] = USDC;
        bad[1] = WETH;
        vm.expectRevert("PromotionUniV2_Eth: path end not WBTC");
        dispatcher.setUsdcToWbtcPath(bad);
    }

    function test_setUsdcToWbtcPath_revertsTooShort() public {
        address[] memory bad = new address[](1);
        bad[0] = USDC;
        vm.expectRevert("PromotionUniV2_Eth: path too short");
        dispatcher.setUsdcToWbtcPath(bad);
    }

    function test_setUsdcToWbtcPath_revertsForNonOwner() public {
        address[] memory custom = new address[](2);
        custom[0] = USDC;
        custom[1] = WBTC;
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setUsdcToWbtcPath(custom);
    }

    // =====================================================================
    // pool — 60/30/10 split, burn-half, WBTC leg (mainnet fork)
    // =====================================================================

    /// @dev Decodes the single `Pooled` event emitted by the dispatcher from the recorded logs.
    function _extractPooled(Vm.Log[] memory logs)
        internal
        view
        returns (
            uint256 primeSpent,
            uint256 phusdAcquired,
            uint256 phusdBurned,
            uint256 wbtcAcquired,
            uint256 liquidity
        )
    {
        bytes32 sig = keccak256("Pooled(address,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
        revert("Pooled event not found");
    }

    function test_pool_split_60_30_10_andBurnsHalfPhusd() public {
        uint256 amount = 5000e6;
        _seedPrime(amount);

        uint256 supplyBefore = IERC20(phUSD).totalSupply();
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(dispatcher));

        vm.recordLogs();
        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (
            uint256 primeSpent,
            uint256 phusdAcquired,
            uint256 phusdBurned,
            uint256 wbtcAcquired,
            uint256 liquidity
        ) = _extractPooled(logs);

        // Event outcome fields.
        assertEq(primeSpent, amount, "primeSpent == amountIn");
        assertGt(phusdAcquired, 0, "phUSD acquired on Leg A");
        assertEq(phusdBurned, phusdAcquired / 2, "half the acquired phUSD burned");
        assertGt(wbtcAcquired, 0, "WBTC acquired on Leg C");
        assertGt(liquidity, 0, "LP minted");

        // Burn is a real supply cut of exactly the burned half.
        uint256 supplyAfter = IERC20(phUSD).totalSupply();
        assertEq(supplyBefore - supplyAfter, phusdBurned, "totalSupply drops by the burned half");

        // WBTC (8dp) acquired and retained on the dispatcher (NOT pooled).
        uint256 wbtcAfter = IERC20(WBTC).balanceOf(address(dispatcher));
        assertEq(wbtcAfter - wbtcBefore, wbtcAcquired, "WBTC reserve rose by wbtcAcquired");

        // USDC fully consumed across the three legs (60 + 30 + 10 == 100).
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), 0, "USDC fully consumed");

        // Pooled phUSD ≈ pooled promotion: the router refund leaves only tiny phUSD/promo dust.
        assertLt(IERC20(phUSD).balanceOf(address(dispatcher)), phusdBurned / 100, "negligible phUSD dust");
    }

    function test_pool_wbtcNotAddedToLP_stillMintsLP() public {
        uint256 amount = 5000e6;
        _seedPrime(amount);
        uint256 lpBefore = IERC20(phusdPromoPair).balanceOf(address(dispatcher));

        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 1, 0);

        // The phUSD/promotion LP minted, and WBTC stayed resident (never routed into the pair).
        assertGt(IERC20(phusdPromoPair).balanceOf(address(dispatcher)), lpBefore, "LP minted");
        assertGt(IERC20(WBTC).balanceOf(address(dispatcher)), 0, "WBTC retained on dispatcher");
    }

    function test_pool_wbtcRoute_rerouteViaWETH() public {
        uint256 amount = 5000e6;
        _seedPrime(amount);

        address[] memory viaWeth = new address[](3);
        viaWeth[0] = USDC;
        viaWeth[1] = WETH;
        viaWeth[2] = WBTC;
        dispatcher.setUsdcToWbtcPath(viaWeth);

        vm.recordLogs();
        vm.prank(authorizedPooler);
        dispatcher.pool(amount, 1, 0, 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, uint256 wbtcAcquired,) = _extractPooled(logs);

        assertGt(wbtcAcquired, 0, "WBTC acquired via the WETH reroute");
        assertEq(IERC20(WBTC).balanceOf(address(dispatcher)), wbtcAcquired, "reserve holds the rerouted WBTC");
    }

    // =====================================================================
    // insurer / withdrawWBTC
    // =====================================================================

    function test_setInsurer_storesAndEmits() public {
        address ins = address(0x1571);
        vm.expectEmit(false, false, false, true);
        emit PromotionUniV2_Eth.InsurerSet(ins);
        dispatcher.setInsurer(ins);
        assertEq(dispatcher.insurer(), ins);
    }

    function test_setInsurer_revertsZero() public {
        vm.expectRevert("PromotionUniV2_Eth: zero insurer");
        dispatcher.setInsurer(address(0));
    }

    function test_setInsurer_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        dispatcher.setInsurer(address(0x1571));
    }

    function test_insurer_defaultsToZero_locksWithdraw() public {
        // Reserve funded, but no insurer set — nobody can withdraw (address(0) can never be msg.sender).
        deal(WBTC, address(dispatcher), 1e8);
        assertEq(dispatcher.insurer(), address(0));
        vm.prank(nonOwner);
        vm.expectRevert("PromotionUniV2_Eth: not insurer");
        dispatcher.withdrawWBTC(nonOwner, 1e8);
    }

    function test_withdrawWBTC_revertsForNonInsurer() public {
        address ins = address(0x1571);
        dispatcher.setInsurer(ins);
        deal(WBTC, address(dispatcher), 1e8);
        // Owner is not the insurer either.
        vm.expectRevert("PromotionUniV2_Eth: not insurer");
        dispatcher.withdrawWBTC(owner, 1e8);
    }

    function test_withdrawWBTC_insurerMovesReserveAndEmits() public {
        address ins = address(0x1571);
        address to = address(0xB70C);
        uint256 amount = 3e7; // 0.3 WBTC (8dp)
        dispatcher.setInsurer(ins);
        deal(WBTC, address(dispatcher), 1e8);

        vm.expectEmit(true, false, false, true);
        emit PromotionUniV2_Eth.WBTCWithdrawn(to, amount);
        vm.prank(ins);
        dispatcher.withdrawWBTC(to, amount);

        assertEq(IERC20(WBTC).balanceOf(to), amount, "WBTC (8dp) moved to recipient");
        assertEq(IERC20(WBTC).balanceOf(address(dispatcher)), 1e8 - amount, "reserve debited");
    }

    function test_withdrawWBTC_revertsZeroRecipient() public {
        address ins = address(0x1571);
        dispatcher.setInsurer(ins);
        deal(WBTC, address(dispatcher), 1e8);
        vm.prank(ins);
        vm.expectRevert("PromotionUniV2_Eth: zero recipient");
        dispatcher.withdrawWBTC(address(0), 1e8);
    }

    // =====================================================================
    // rescueERC20 — WBTC excluded
    // =====================================================================

    function test_rescueERC20_revertsForWBTC() public {
        deal(WBTC, address(dispatcher), 1e8);
        vm.expectRevert("PromotionUniV2_Eth: WBTC is insurer-only");
        dispatcher.rescueERC20(WBTC, owner, 1e8);
    }

    function test_rescueERC20_stillWorksForNonWBTC() public {
        // The WBTC guard does not block other tokens (e.g. the LP token / phUSD / USDC).
        deal(phUSD, address(dispatcher), 1000e18);
        address to = address(0xF00D);
        dispatcher.rescueERC20(phUSD, to, 1000e18);
        assertEq(IERC20(phUSD).balanceOf(to), 1000e18);
    }
}
