// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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
        // Fork mainnet. Prefer an archive RPC via env; fall back to a public node for head runs.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
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
        dispatcher.pool(amount, 0, 0, 0, 0);

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
        dispatcher.pool(0, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenAmountExceedsBalance() public {
        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient prime");
        dispatcher.pool(1000e6 + 1, 0, 0, 0, 0);
    }

    function test_pool_revertsForNonAuthorizedPooler() public {
        _seedPrime(1000e6);
        vm.prank(nonOwner);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 0, 0, 0, 0);
    }

    function test_pool_revertsWhenMinPhusdOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // Balancer swap limitRaw floor unmet
        dispatcher.pool(5000e6, type(uint256).max, 0, 0, 0);
    }

    function test_pool_revertsWhenMinEthOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 USDC->ETH INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 0, type(uint256).max, 0, 0);
    }

    function test_pool_revertsWhenMinPromoOutNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert(); // UniV2 ETH->promo INSUFFICIENT_OUTPUT_AMOUNT
        dispatcher.pool(5000e6, 0, 0, type(uint256).max, 0);
    }

    function test_pool_revertsWhenMinLPNotMet() public {
        _seedPrime(5000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: insufficient LP");
        dispatcher.pool(5000e6, 0, 0, 0, type(uint256).max);
    }

    function test_pool_revertsWhenPaused() public {
        _seedPrime(5000e6);
        vm.prank(minter);
        dispatcher.pause();
        vm.prank(authorizedPooler);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        dispatcher.pool(5000e6, 0, 0, 0, 0);
    }

    function test_pool_doesNotInvokeHook() public {
        MockDispatchHook hook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(hook)));
        _seedPrime(5000e6);
        assertEq(hook.callCount(), 1, "dispatch invoked hook once");

        vm.prank(authorizedPooler);
        dispatcher.pool(5000e6, 0, 0, 0, 0);
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
        dispatcher.pool(1000e6, 0, 0, 0, 0);
    }

    function test_incrementAuthVersion_massRevoke() public {
        dispatcher.incrementAuthVersion();
        assertEq(dispatcher.authVersion(), 2);

        _seedPrime(1000e6);
        vm.prank(authorizedPooler);
        vm.expectRevert("PromotionUniV2_Eth: caller not authorized pooler");
        dispatcher.pool(1000e6, 0, 0, 0, 0);

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
        dispatcher.pool(5000e6, 0, 0, 0, 0);
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
        // receive() accepts native ETH.
        vm.deal(address(this), 5 ether);
        (bool sent,) = address(dispatcher).call{value: 3 ether}("");
        assertTrue(sent, "receive() accepted ETH");
        assertEq(address(dispatcher).balance, 3 ether);

        // rescueETH moves it out (owner-gated, non-zero recipient).
        address payable to = payable(address(0xEEEE));
        dispatcher.rescueETH(to, 3 ether);
        assertEq(to.balance, 3 ether);
        assertEq(address(dispatcher).balance, 0);
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
}
