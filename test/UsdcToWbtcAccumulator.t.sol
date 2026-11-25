// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {UsdcToWbtcAccumulator} from "../src/dispatchers/UsdcToWbtcAccumulator.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {IUniswapV3SwapRouter} from "../src/interfaces/uniswap/IUniswapV3SwapRouter.sol";
import {MockUniswapV3SwapRouter} from "./mocks/MockUniswapV3SwapRouter.sol";

/// @dev ERC20 with configurable decimals (USDC 6 dp, WBTC 8 dp). `mint` is open (test-only).
contract AccumulatorMockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Malicious router: on `exactInputSingle` it re-enters `buy` on the calling accumulator.
contract ReentrantV3Router is IUniswapV3SwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable override returns (uint256) {
        UsdcToWbtcAccumulator(msg.sender).buy(params.amountIn, 1, params.deadline);
        return 0;
    }
}

/// @title UsdcToWbtcAccumulator unit tests (story 054)
/// @notice Mock V3 router + mock USDC (6 dp) / WBTC (8 dp); the mint path goes through the REAL
///         NFTMinterV2. The owner is the real owner EOA so every buy/rescue asserts its balances are
///         unchanged (no funds ever touch the owner wallet).
contract UsdcToWbtcAccumulatorTest is Test {
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    uint24 internal constant FEE = 3000;
    /// @dev Mock rate: 1 BTC = $58,000 → raw sats per raw USDC unit = 1e8 / 58_000e6.
    uint256 internal constant RATE_NUM = 1e8;
    uint256 internal constant RATE_DEN = 58_000e6;
    uint256 internal constant MINT_PRICE = 10.957e6;

    AccumulatorMockToken internal usdc;
    AccumulatorMockToken internal wbtc;
    MockUniswapV3SwapRouter internal router;
    UsdcToWbtcAccumulator internal acc;

    address internal buyer = address(0xB0B);
    address internal stranger = address(0xBAD);
    address internal treasury = address(0x7EA5);
    address internal minter = address(0x1111);

    event Bought(address indexed buyer, uint256 usdcIn, uint256 wbtcOut);
    event RouterSet(address indexed oldRouter, address indexed newRouter);
    event PoolFeeSet(uint24 oldPoolFee, uint24 newPoolFee);
    event BuyerAuthorized(address indexed buyer, uint256 atAuthVersion);
    event BuyerDeauthorized(address indexed buyer);
    event AuthVersionIncremented(uint256 newAuthVersion);
    event TreasuryRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event Rescued(address indexed token, address indexed recipient, uint256 amount);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new AccumulatorMockToken("USD Coin", "USDC", 6);
        wbtc = new AccumulatorMockToken("Wrapped BTC", "WBTC", 8);
        router = new MockUniswapV3SwapRouter(FEE, RATE_NUM, RATE_DEN);
        wbtc.mint(address(router), 1_000e8);

        acc = new UsdcToWbtcAccumulator(address(usdc), address(wbtc), address(router), FEE, OWNER);
        vm.startPrank(OWNER);
        acc.setMinter(minter);
        acc.setAuthorizedBuyer(buyer, true);
        vm.stopPrank();

        usdc.mint(address(acc), 1_000e6);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _ownerBalances() internal view returns (uint256 u, uint256 w) {
        u = usdc.balanceOf(OWNER);
        w = wbtc.balanceOf(OWNER);
    }

    function _assertOwnerUnchanged(uint256 u, uint256 w) internal view {
        assertEq(usdc.balanceOf(OWNER), u, "owner USDC changed");
        assertEq(wbtc.balanceOf(OWNER), w, "owner WBTC changed");
    }

    function _buy(address caller, uint256 usdcIn) internal returns (uint256) {
        uint256 minOut = router.quote(usdcIn);
        vm.prank(caller);
        return acc.buy(usdcIn, minOut, block.timestamp + 1 hours);
    }

    // =====================================================================
    // Constructor
    // =====================================================================

    function test_constructor_setsState() public view {
        assertEq(acc.primeToken(), address(usdc));
        assertEq(acc.targetToken(), address(wbtc));
        assertEq(acc.router(), address(router));
        assertEq(acc.poolFee(), FEE);
        assertEq(acc.authVersion(), 1);
        assertEq(acc.treasuryRecipient(), address(0));
        assertEq(acc.owner(), OWNER);
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAddress.selector);
        new UsdcToWbtcAccumulator(address(0), address(wbtc), address(router), FEE, OWNER);
    }

    function test_constructor_revertsZeroWbtc() public {
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAddress.selector);
        new UsdcToWbtcAccumulator(address(usdc), address(0), address(router), FEE, OWNER);
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAddress.selector);
        new UsdcToWbtcAccumulator(address(usdc), address(wbtc), address(0), FEE, OWNER);
    }

    function test_constructor_revertsSameToken() public {
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__SameToken.selector);
        new UsdcToWbtcAccumulator(address(usdc), address(usdc), address(router), FEE, OWNER);
    }

    function test_constructor_revertsZeroFee() public {
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroPoolFee.selector);
        new UsdcToWbtcAccumulator(address(usdc), address(wbtc), address(router), 0, OWNER);
    }

    function test_primeToken_isUsdc_targetToken_isWbtc() public view {
        assertEq(acc.primeToken(), address(usdc));
        assertEq(acc.targetToken(), address(wbtc));
    }

    // =====================================================================
    // Mint through the real NFTMinterV2
    // =====================================================================

    function _deployMinterWithAccumulatorAtIndex5() internal returns (NFTMinterV2 nft, UsdcToWbtcAccumulator a) {
        nft = new NFTMinterV2(address(this));
        // Fillers so the accumulator lands at index 5, as on mainnet.
        for (uint256 i = 0; i < 4; i++) {
            nft.registerDispatcher(
                address(new UsdcToWbtcAccumulator(address(usdc), address(wbtc), address(router), FEE, OWNER)), 1e6, 0
            );
        }
        a = new UsdcToWbtcAccumulator(address(usdc), address(wbtc), address(router), FEE, OWNER);
        nft.registerDispatcher(address(a), MINT_PRICE, 200);
        vm.prank(OWNER);
        a.setMinter(address(nft));
        vm.prank(OWNER);
        a.setAuthorizedBuyer(buyer, true);
    }

    function test_mint_viaRealMinter_leavesUsdcOnDispatcher() public {
        (NFTMinterV2 nft, UsdcToWbtcAccumulator a) = _deployMinterWithAccumulatorAtIndex5();
        assertEq(nft.dispatcherToIndex(address(a)), 5);

        address alice = address(0xA11CE);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(nft), type(uint256).max);
        nft.mint(5, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100e6 - MINT_PRICE, "alice paid price");
        assertEq(usdc.balanceOf(address(a)), MINT_PRICE, "dispatcher keeps USDC");
        assertEq(usdc.balanceOf(address(nft)), 0, "minter holds nothing");
        assertEq(wbtc.balanceOf(address(a)), 0, "no swap on mint");
        assertEq(nft.balanceOf(alice, 5), 1, "NFT minted");
        assertEq(usdc.allowance(address(a), address(router)), 0, "no router allowance");
    }

    function test_mint_blockedWhenIndexDisabled() public {
        (NFTMinterV2 nft,) = _deployMinterWithAccumulatorAtIndex5();
        nft.setDispatcherDisabled(5, true);

        address alice = address(0xA11CE);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(nft), type(uint256).max);
        vm.expectRevert("NFTMinterV2: dispatcher is disabled");
        nft.mint(5, alice);
        vm.stopPrank();
    }

    function test_mint_blockedWhenDispatcherPaused_buyStillWorks() public {
        (NFTMinterV2 nft, UsdcToWbtcAccumulator a) = _deployMinterWithAccumulatorAtIndex5();
        nft.setDispatcherActive(address(a), false);
        assertTrue(a.paused());

        address alice = address(0xA11CE);
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(nft), type(uint256).max);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.mint(5, alice);
        vm.stopPrank();

        usdc.mint(address(a), 50e6);
        uint256 minOut = router.quote(50e6);
        vm.prank(buyer);
        uint256 out = a.buy(50e6, minOut, block.timestamp);
        assertEq(out, minOut);
        assertEq(wbtc.balanceOf(address(a)), minOut);
    }

    // =====================================================================
    // buy: authorisation
    // =====================================================================

    function test_buy_revertsForNonBuyer() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__NotAuthorizedBuyer.selector, stranger)
        );
        acc.buy(100e6, 1, block.timestamp);
    }

    function test_buy_revertsForOwnerWhoIsNotBuyer() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__NotAuthorizedBuyer.selector, OWNER)
        );
        acc.buy(100e6, 1, block.timestamp);
    }

    function test_buy_authorisedBuyerSucceeds() public {
        (uint256 ou, uint256 ow) = _ownerBalances();
        uint256 expected = router.quote(100e6);

        vm.expectEmit(true, false, false, true, address(acc));
        emit Bought(buyer, 100e6, expected);
        uint256 out = _buy(buyer, 100e6);

        assertEq(out, expected);
        assertEq(wbtc.balanceOf(address(acc)), expected);
        assertEq(usdc.balanceOf(address(acc)), 900e6);
        _assertOwnerUnchanged(ou, ow);
    }

    function test_setAuthorizedBuyer_falseRevokes() public {
        vm.expectEmit(true, false, false, false, address(acc));
        emit BuyerDeauthorized(buyer);
        vm.prank(OWNER);
        acc.setAuthorizedBuyer(buyer, false);
        assertEq(acc.buyerAuthVersion(buyer), 0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__NotAuthorizedBuyer.selector, buyer)
        );
        acc.buy(100e6, 1, block.timestamp);
    }

    function test_setAuthorizedBuyer_emitsAndRecordsVersion() public {
        address b2 = address(0xB2);
        vm.expectEmit(true, false, false, true, address(acc));
        emit BuyerAuthorized(b2, 1);
        vm.prank(OWNER);
        acc.setAuthorizedBuyer(b2, true);
        assertEq(acc.buyerAuthVersion(b2), 1);
    }

    function test_setAuthorizedBuyer_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.setAuthorizedBuyer(stranger, true);
    }

    function test_setAuthorizedBuyer_revertsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAddress.selector);
        acc.setAuthorizedBuyer(address(0), true);
    }

    function test_incrementAuthVersion_deauthorisesEveryBuyer_reauthWorks() public {
        address b2 = address(0xB2);
        vm.prank(OWNER);
        acc.setAuthorizedBuyer(b2, true);

        vm.expectEmit(false, false, false, true, address(acc));
        emit AuthVersionIncremented(2);
        vm.prank(OWNER);
        acc.incrementAuthVersion();
        assertEq(acc.authVersion(), 2);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__NotAuthorizedBuyer.selector, buyer)
        );
        acc.buy(100e6, 1, block.timestamp);
        vm.prank(b2);
        vm.expectRevert(
            abi.encodeWithSelector(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__NotAuthorizedBuyer.selector, b2)
        );
        acc.buy(100e6, 1, block.timestamp);

        vm.prank(OWNER);
        acc.setAuthorizedBuyer(buyer, true);
        assertEq(acc.buyerAuthVersion(buyer), 2);
        assertGt(_buy(buyer, 100e6), 0);
    }

    function test_incrementAuthVersion_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.incrementAuthVersion();
    }

    // =====================================================================
    // buy: input validation
    // =====================================================================

    function test_buy_revertsZeroMinOut() public {
        vm.prank(buyer);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroMinOut.selector);
        acc.buy(100e6, 0, block.timestamp);
    }

    function test_buy_revertsZeroAmountIn() public {
        vm.prank(buyer);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAmountIn.selector);
        acc.buy(0, 1, block.timestamp);
    }

    function test_buy_revertsPastDeadline() public {
        uint256 deadline = block.timestamp - 1;
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__DeadlinePassed.selector, deadline, block.timestamp
            )
        );
        acc.buy(100e6, 1, deadline);
    }

    function test_buy_deadlineEqualToNowSucceeds() public {
        uint256 minOut = router.quote(100e6);
        vm.prank(buyer);
        assertEq(acc.buy(100e6, minOut, block.timestamp), minOut);
    }

    function test_buy_revertsWhenFloorAboveRouterOutput() public {
        uint256 minOut = router.quote(100e6) + 1;
        vm.prank(buyer);
        vm.expectRevert("Too little received");
        acc.buy(100e6, minOut, block.timestamp);
    }

    function test_buy_revertsWhenMoreThanBalance() public {
        vm.prank(buyer);
        vm.expectRevert();
        acc.buy(1_000e6 + 1, 1, block.timestamp);
    }

    // =====================================================================
    // buy: mechanics
    // =====================================================================

    function test_buy_sendsWbtcToDispatcherItself() public {
        _buy(buyer, 100e6);
        assertEq(router.lastRecipient(), address(acc));
        assertEq(router.lastAmountIn(), 100e6);
        assertEq(wbtc.balanceOf(buyer), 0, "buyer receives nothing");
        assertEq(usdc.balanceOf(buyer), 0, "buyer receives nothing");
    }

    function test_buy_measuresByBalanceDelta_notRouterReturn() public {
        uint256 realOut = router.quote(100e6);
        router.setMisreport(true, realOut * 10);

        vm.expectEmit(true, false, false, true, address(acc));
        emit Bought(buyer, 100e6, realOut);
        uint256 out = _buy(buyer, 100e6);
        assertEq(out, realOut, "returned value is the real delta");
    }

    function test_buy_measuresByBalanceDelta_ignoresPreexistingWbtc() public {
        wbtc.mint(address(acc), 5e8);
        uint256 realOut = router.quote(100e6);
        assertEq(_buy(buyer, 100e6), realOut);
        assertEq(wbtc.balanceOf(address(acc)), 5e8 + realOut);
    }

    function test_buy_revertsWhenDeltaBelowFloor() public {
        uint256 quoted = router.quote(100e6);
        router.setShortPay(1);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__InsufficientOutput.selector, quoted - 1, quoted
            )
        );
        acc.buy(100e6, quoted, block.timestamp);
    }

    function test_buy_resetsRouterAllowanceToZero() public {
        _buy(buyer, 100e6);
        assertEq(usdc.allowance(address(acc), address(router)), 0);
    }

    function test_buy_usesConfiguredPoolFee() public {
        router.setPoolFee(500);
        vm.prank(buyer);
        vm.expectRevert("MockUniswapV3SwapRouter: no pool for fee");
        acc.buy(100e6, 1, block.timestamp);

        vm.prank(OWNER);
        acc.setPoolFee(500);
        assertGt(_buy(buyer, 100e6), 0);
    }

    function test_buy_worksWhilePaused() public {
        vm.prank(minter);
        acc.pause();
        assertTrue(acc.paused());
        assertGt(_buy(buyer, 100e6), 0);
    }

    function test_buy_reentrancyFails() public {
        ReentrantV3Router evil = new ReentrantV3Router();
        vm.startPrank(OWNER);
        acc.setRouter(address(evil));
        acc.setAuthorizedBuyer(address(evil), true); // so only the reentrancy guard can stop it
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        acc.buy(100e6, 1, block.timestamp);
    }

    // =====================================================================
    // dispatch
    // =====================================================================

    function test_dispatch_keepsTokens_forwardsNothing() public {
        uint256 before = usdc.balanceOf(address(acc));
        vm.prank(minter);
        acc.dispatch(minter, 10e6, "");
        assertEq(usdc.balanceOf(address(acc)), before);
        assertEq(usdc.allowance(address(acc), address(router)), 0);
    }

    function test_dispatch_onlyMinter() public {
        vm.prank(stranger);
        vm.expectRevert("ATokenDispatcherV2: caller is not minter");
        acc.dispatch(stranger, 10e6, "");
    }

    // =====================================================================
    // Router / fee setters
    // =====================================================================

    function test_setRouter_ownerOnly_emits() public {
        address r2 = address(0x2222);
        vm.expectEmit(true, true, false, false, address(acc));
        emit RouterSet(address(router), r2);
        vm.prank(OWNER);
        acc.setRouter(r2);
        assertEq(acc.router(), r2);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.setRouter(r2);
    }

    function test_setRouter_revertsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroAddress.selector);
        acc.setRouter(address(0));
    }

    function test_setPoolFee_ownerOnly_emits() public {
        vm.expectEmit(false, false, false, true, address(acc));
        emit PoolFeeSet(FEE, 500);
        vm.prank(OWNER);
        acc.setPoolFee(500);
        assertEq(acc.poolFee(), 500);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.setPoolFee(500);
    }

    function test_setPoolFee_revertsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__ZeroPoolFee.selector);
        acc.setPoolFee(0);
    }

    // =====================================================================
    // Treasury recipient
    // =====================================================================

    function test_setTreasuryRecipient_ownerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.setTreasuryRecipient(treasury);
    }

    function test_setTreasuryRecipient_rejectsOwner() public {
        vm.prank(OWNER);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__RecipientIsOwner.selector);
        acc.setTreasuryRecipient(OWNER);
    }

    function test_setTreasuryRecipient_acceptsNormalAndZero() public {
        vm.expectEmit(true, true, false, false, address(acc));
        emit TreasuryRecipientSet(address(0), treasury);
        vm.prank(OWNER);
        acc.setTreasuryRecipient(treasury);
        assertEq(acc.treasuryRecipient(), treasury);

        vm.expectEmit(true, true, false, false, address(acc));
        emit TreasuryRecipientSet(treasury, address(0));
        vm.prank(OWNER);
        acc.setTreasuryRecipient(address(0));
        assertEq(acc.treasuryRecipient(), address(0));
    }

    // =====================================================================
    // Rescue
    // =====================================================================

    function test_rescueERC20_onlyOwner() public {
        vm.prank(OWNER);
        acc.setTreasuryRecipient(treasury);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        acc.rescueERC20(address(usdc), 1);
    }

    function test_rescueERC20_revertsWhileRecipientUnset() public {
        vm.prank(OWNER);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__TreasuryRecipientUnset.selector);
        acc.rescueERC20(address(usdc), 1);
    }

    function test_rescueERC20_revertsAgainAfterRecipientCleared() public {
        vm.startPrank(OWNER);
        acc.setTreasuryRecipient(treasury);
        acc.setTreasuryRecipient(address(0));
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__TreasuryRecipientUnset.selector);
        acc.rescueERC20(address(usdc), 1);
        vm.stopPrank();
    }

    function test_rescueERC20_paysOnlyTreasury_wbtcAndUsdc() public {
        uint256 bought = _buy(buyer, 100e6);
        (uint256 ou, uint256 ow) = _ownerBalances();

        vm.prank(OWNER);
        acc.setTreasuryRecipient(treasury);

        vm.expectEmit(true, true, false, true, address(acc));
        emit Rescued(address(wbtc), treasury, bought);
        vm.prank(OWNER);
        acc.rescueERC20(address(wbtc), bought);
        _assertOwnerUnchanged(ou, ow);

        vm.expectEmit(true, true, false, true, address(acc));
        emit Rescued(address(usdc), treasury, 900e6);
        vm.prank(OWNER);
        acc.rescueERC20(address(usdc), 900e6);
        _assertOwnerUnchanged(ou, ow);

        assertEq(wbtc.balanceOf(treasury), bought);
        assertEq(usdc.balanceOf(treasury), 900e6);
        assertEq(wbtc.balanceOf(address(acc)), 0);
        assertEq(usdc.balanceOf(address(acc)), 0);
    }

    function test_rescueERC20_worksWhilePaused() public {
        vm.prank(minter);
        acc.pause();
        (uint256 ou, uint256 ow) = _ownerBalances();
        vm.startPrank(OWNER);
        acc.setTreasuryRecipient(treasury);
        acc.rescueERC20(address(usdc), 10e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(treasury), 10e6);
        _assertOwnerUnchanged(ou, ow);
    }

    /// @dev Defence in depth: ownership moved onto the stored recipient must not route funds to the owner.
    function test_rescueERC20_revertsWhenRecipientBecameOwner() public {
        vm.startPrank(OWNER);
        acc.setTreasuryRecipient(treasury);
        acc.transferOwnership(treasury);
        vm.stopPrank();

        vm.prank(treasury);
        vm.expectRevert(UsdcToWbtcAccumulator.UsdcToWbtcAccumulator__RecipientIsOwner.selector);
        acc.rescueERC20(address(usdc), 1);
    }
}
