// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PromotionUniV2_Eth} from "../src/dispatchers/PromotionUniV2_Eth.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {IUniswapV2Router02} from "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import {MockDispatchHook} from "./mocks/MockDispatchHook.sol";
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
/// @notice The multi-protocol flow (SKY PSM + Balancer V3 + Uniswap V2 + native ETH) hardcodes live
///         mainnet addresses and cannot be faithfully mocked, so these tests run against a mainnet
///         fork. This is the repo's first fork test.
///
/// @dev RPC wiring: set `MAINNET_RPC_URL` to an ARCHIVE endpoint (Alchemy/Infura). `FORK_BLOCK`
///      pins historical state that free full-nodes do not serve; a public node fallback is used
///      only when the env var is unset (head-only). See foundry.toml `[rpc_endpoints]`.
contract PromotionUniV2_EthForkTest is Test {
    using SafeERC20 for IERC20;

    // ---- live mainnet addresses (mirror the dispatcher constants) ----
    address internal constant phUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    /// @dev Recent mainnet block where phUSD/sUSDS pool, the SKY PSM, and the UniV2 router are all
    ///      live. Requires an archive RPC to fork at this height.
    uint256 internal constant FORK_BLOCK = 25_550_000;

    PromotionUniV2_Eth internal dispatcher;
    MockPromoToken internal promo;
    address internal phusdPromoPair;

    address internal owner = address(this);
    address internal minter = address(0xBEEF);
    address internal nonOwner = address(0xCAFE);
    address internal batchMinterAddr = address(0xD011);
    address internal authorizedPooler = address(0xD00D);

    function setUp() public {
        // Fork mainnet. Prefer an archive RPC via env (accept either MAINNET_RPC_URL or the RPC_MAINNET
        // name used by the local .envrc); fall back to a public node for head runs.
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", vm.envOr("RPC_MAINNET", string("https://ethereum-rpc.publicnode.com")));
        vm.createSelectFork(rpc, FORK_BLOCK);

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

        assertEq(IERC20(USDC).balanceOf(batchMinterAddr), 500e6, "50% forwarded");
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), 500e6, "remainder retained");
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
        assertEq(IERC20(USDC).balanceOf(address(dispatcher)), amount);
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
        dispatcher.pool(amount, 0, 0, 0, 0, 0);

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
        dispatcher.pool(0, 0, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenAmountExceedsBalance() public {
        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient prime");
        dispatcher.pool(1000e6 + 1, 0, 0, 0, 0, 0);
    }

    function test_pool_revertsForNonAuthorizedPooler() public {
        _seedPrime(1000e6);
        vm.prank(nonOwner);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 0, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenMinPhusdOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // Balancer swap limitRaw floor unmet
        dispatcher.pool(5000e6, type(uint256).max, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenMinEthOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 USDC->ETH INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 0, type(uint256).max, 0, 0, 0);
    }

    function test_pool_revertsWhenMinPromoOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 ETH->promo INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 0, 0, type(uint256).max, 0, 0);
    }

    function test_pool_revertsWhenMinWbtcOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 USDC->WBTC INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 0, 0, 0, type(uint256).max, 0);
    }

    function test_pool_revertsWhenMinLPNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient LP");
        dispatcher.pool(5000e6, 0, 0, 0, 0, type(uint256).max);
    }

    function test_pool_revertsWhenPaused() public {
        _seedPrime(5000e6);
        vm.prank(minter);
        dispatcher.pause();
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        dispatcher.pool(5000e6, 0, 0, 0, 0, 0);
    }

    function test_pool_doesNotInvokeHook() public {
        MockDispatchHook hook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(hook)));
        _seedPrime(5000e6);
        assertEq(hook.callCount(), 1, "dispatch invoked hook once");

        vm.prank(authorizedPooler);
        dispatcher.pool(5000e6, 0, 0, 0, 0, 0);
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
        dispatcher.pool(1000e6, 0, 0, 0, 0, 0);
    }

    function test_incrementAuthVersion_massRevoke() public {
        dispatcher.incrementAuthVersion();
        assertEq(dispatcher.authVersion(), 2);

        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 0, 0, 0, 0, 0);

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
        dispatcher.pool(5000e6, 0, 0, 0, 0, 0);
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
        dispatcher.pool(amount, 0, 0, 0, 0, 0);
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
        dispatcher.pool(amount, 0, 0, 0, 1, 0);

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
        dispatcher.pool(amount, 0, 0, 0, 0, 0);
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
