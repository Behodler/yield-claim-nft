// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {UniboostMintDebtHook} from "../src/hooks/UniboostMintDebtHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockMintable, ReentrantMockMintable, IReentrantPullTarget} from "./mocks/MockMintable.sol";

/// @dev ERC20 with a configurable `decimals()` for exercising the hook's scale logic.
contract MockERC20Decimals is ERC20 {
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) ERC20("Mock", "MOCK") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UniboostMintDebtHookTest is Test {
    UniboostMintDebtHook internal hookContract;
    MockMintable internal phUSD;
    MockERC20Decimals internal prime6; // 6-decimal prime (USDC-like)

    address internal owner = address(this);
    address internal nonOwner = address(0xBAD);
    address internal dispatcher = address(0xD15);
    address internal minter = address(0xB0B);
    address internal recipient = address(0xFEED);

    // Mirror the events from the hook for vm.expectEmit
    event RatioUpdated(uint8 oldRatio, uint8 newRatio);
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DebtAccrued(address indexed minter, uint256 dispatchedAmount, uint256 debtAdded, uint256 newTotalDebt);
    event DebtPulled(address indexed recipient, uint256 amount);
    event DispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);

    function setUp() public {
        phUSD = new MockMintable();
        prime6 = new MockERC20Decimals(6);
        hookContract = new UniboostMintDebtHook(owner, dispatcher, address(phUSD), address(prime6));
    }

    function _new18dpHook() internal returns (UniboostMintDebtHook) {
        MockERC20Decimals prime18 = new MockERC20Decimals(18);
        return new UniboostMintDebtHook(owner, dispatcher, address(phUSD), address(prime18));
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_constructor_revertsOnZeroDispatcher() public {
        vm.expectRevert("dispatcher=0");
        new UniboostMintDebtHook(owner, address(0), address(phUSD), address(prime6));
    }

    function test_constructor_revertsOnZeroPhUSD() public {
        vm.expectRevert("phUSD=0");
        new UniboostMintDebtHook(owner, dispatcher, address(0), address(prime6));
    }

    function test_constructor_revertsOnZeroPrimeToken() public {
        vm.expectRevert("primeToken=0");
        new UniboostMintDebtHook(owner, dispatcher, address(phUSD), address(0));
    }

    function test_constructor_revertsOnDecimalsAbove18() public {
        MockERC20Decimals prime19 = new MockERC20Decimals(19);
        vm.expectRevert("decimals>18");
        new UniboostMintDebtHook(owner, dispatcher, address(phUSD), address(prime19));
    }

    function test_constructor_setsScale1e12For6dp() public view {
        assertEq(hookContract.scale(), 1e12, "scale should be 1e12 for a 6-decimal prime");
    }

    function test_constructor_setsScale1For18dp() public {
        UniboostMintDebtHook h = _new18dpHook();
        assertEq(h.scale(), 1, "scale should be 1 for an 18-decimal prime");
    }

    function test_constructor_setsDispatcherAndPhUSD() public view {
        assertEq(hookContract.dispatcher(), dispatcher, "dispatcher should match ctor arg");
        assertEq(address(hookContract.phUSD()), address(phUSD), "phUSD should match ctor arg");
    }

    function test_constructor_setsDefaultRatio() public view {
        assertEq(hookContract.ratio(), 50, "ratio should default to 50");
        assertEq(hookContract.DEFAULT_RATIO(), 50, "DEFAULT_RATIO constant");
        assertEq(hookContract.MAX_RATIO(), 50, "MAX_RATIO constant");
    }

    function test_constructor_emitsRatioUpdated() public {
        MockMintable freshPhUSD = new MockMintable();
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(0, 50);
        new UniboostMintDebtHook(owner, dispatcher, address(freshPhUSD), address(prime6));
    }

    function test_constructor_transfersOwnershipToInitialOwner() public {
        address newOwner = address(0xCAFE);
        UniboostMintDebtHook h = new UniboostMintDebtHook(newOwner, dispatcher, address(phUSD), address(prime6));
        assertEq(h.owner(), newOwner, "owner should be initialOwner");
    }

    // =========================================================================
    // setDispatcher
    // =========================================================================

    function test_setDispatcher_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        hookContract.setDispatcher(address(0xDEAD));
    }

    function test_setDispatcher_revertsOnZeroAddress() public {
        vm.expectRevert("dispatcher=0");
        hookContract.setDispatcher(address(0));
    }

    function test_setDispatcher_updatesStorageAndEmits() public {
        address newDispatcher = address(0xDEAD);
        vm.expectEmit(true, true, false, false);
        emit DispatcherUpdated(dispatcher, newDispatcher);
        hookContract.setDispatcher(newDispatcher);
        assertEq(hookContract.dispatcher(), newDispatcher, "dispatcher should be updated");
    }

    function test_setDispatcher_updatesOnDispatchGate() public {
        address newDispatcher = address(0xDEAD);
        hookContract.setDispatcher(newDispatcher);

        // Old dispatcher can no longer call onDispatch.
        vm.prank(dispatcher);
        vm.expectRevert(UniboostMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");

        // New dispatcher can; at default ratio 50, debt == amount * 1e12 * 50 / 100.
        vm.prank(newDispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(hookContract.mintDebt(), 1000 * 1e12 * 50 / 100, "new dispatcher should accrue scaled debt");
    }

    // =========================================================================
    // setRatio (exclusive-ish bound: > MAX_RATIO == 50 reverts; 50 ok)
    // =========================================================================

    function test_setRatio_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        hookContract.setRatio(10);
    }

    function test_setRatio_50Succeeds_andEmits() public {
        // No-op value-wise (default is already 50) but exercises the inclusive bound.
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(50, 50);
        hookContract.setRatio(50);
        assertEq(hookContract.ratio(), 50, "ratio should be 50 (inclusive max)");
    }

    function test_setRatio_49Succeeds_andEmits() public {
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(50, 49);
        hookContract.setRatio(49);
        assertEq(hookContract.ratio(), 49, "ratio should be 49");
    }

    function test_setRatio_51Reverts() public {
        vm.expectRevert(UniboostMintDebtHook.RatioTooHigh.selector);
        hookContract.setRatio(51);
    }

    function test_setRatio_200Reverts() public {
        vm.expectRevert(UniboostMintDebtHook.RatioTooHigh.selector);
        hookContract.setRatio(200);
    }

    function test_setRatio_0Succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(50, 0);
        hookContract.setRatio(0);
        assertEq(hookContract.ratio(), 0, "ratio should be 0");
    }

    // =========================================================================
    // setRecipient
    // =========================================================================

    function test_setRecipient_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        hookContract.setRecipient(recipient);
    }

    function test_setRecipient_ownerCanSetNonZero() public {
        vm.expectEmit(true, true, false, false);
        emit RecipientUpdated(address(0), recipient);
        hookContract.setRecipient(recipient);
        assertEq(hookContract.recipient(), recipient, "recipient should match");
    }

    function test_setRecipient_ownerCanResetToZero() public {
        hookContract.setRecipient(recipient);
        vm.expectEmit(true, true, false, false);
        emit RecipientUpdated(recipient, address(0));
        hookContract.setRecipient(address(0));
        assertEq(hookContract.recipient(), address(0), "recipient should be 0");
    }

    // =========================================================================
    // onDispatch
    // =========================================================================

    function test_onDispatch_revertsWhenCallerIsNotDispatcher() public {
        vm.prank(nonOwner);
        vm.expectRevert(UniboostMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_ownerAlsoCannotCall() public {
        vm.expectRevert(UniboostMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_scales10USDCToFivePhUSDAtDefaultRatio() public {
        // 10 USDC (10e6) at ratio 50% -> 5 phUSD (5e18).
        uint256 amount = 10e6;
        uint256 expected = 5e18; // 10e6 * 1e12 * 50 / 100

        vm.expectEmit(true, false, false, true);
        emit DebtAccrued(minter, amount, expected, expected);

        vm.prank(dispatcher);
        hookContract.onDispatch(minter, amount, "");

        assertEq(hookContract.mintDebt(), expected, "10 USDC at 50% -> 5 phUSD");
    }

    function test_onDispatch_scales_generalFormula() public {
        uint256 amount = 1000;
        uint256 expected = amount * 1e12 * 50 / 100;

        vm.expectEmit(true, false, false, true);
        emit DebtAccrued(minter, amount, expected, expected);

        vm.prank(dispatcher);
        hookContract.onDispatch(minter, amount, "");

        assertEq(hookContract.mintDebt(), expected, "mintDebt == amount * 1e12 * 50 / 100");
    }

    function test_onDispatch_18dpBehavesLikeBalancerHook() public {
        // For an 18-dp prime, scale == 1, so accrual == (amount * ratio) / 100, exactly
        // like BalancerPoolerMintDebtHook (no scaling).
        UniboostMintDebtHook h = _new18dpHook();
        uint256 amount = 1000;
        uint256 expected = 500; // 50% of 1000, no scaling

        vm.expectEmit(true, false, false, true);
        emit DebtAccrued(minter, amount, expected, expected);

        vm.prank(dispatcher);
        h.onDispatch(minter, amount, "");

        assertEq(h.mintDebt(), expected, "18-dp prime: mintDebt == (amount * 50)/100, unscaled");
    }

    function test_onDispatch_multipleCallsAccumulate() public {
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");
        assertEq(hookContract.mintDebt(), 10e18, "mintDebt should accumulate to 10 phUSD");
    }

    function test_onDispatch_zeroRatio_noDebt_noEvent() public {
        hookContract.setRatio(0);

        vm.recordLogs();
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events should be emitted at ratio=0");
        assertEq(hookContract.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_zeroAmount_noDebt_noEvent() public {
        // Post-scaling, the only way `added` rounds to 0 (besides ratio=0) is amount=0:
        // `(0 * 1e12 * ratio) / 100 == 0`. Exercises the `added == 0` no-op guard.
        vm.recordLogs();
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 0, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events on zero-added case");
        assertEq(hookContract.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_18dp_smallAmountRoundingToZero_noEvent() public {
        // For an 18-dp prime (scale==1), ratio=50 and amount=1: (1*1*50)/100 = 0 -> no-op.
        UniboostMintDebtHook h = _new18dpHook();

        vm.recordLogs();
        vm.prank(dispatcher);
        h.onDispatch(minter, 1, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events on zero-added rounding case");
        assertEq(h.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_ignoresExtraData() public {
        bytes memory payload = hex"deadbeef1234";
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, payload);
        assertEq(hookContract.mintDebt(), 5e18, "mintDebt should still be 5 phUSD");
    }

    function test_onDispatch_ratio49() public {
        hookContract.setRatio(49);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 100e6, "");
        assertEq(hookContract.mintDebt(), 100e6 * 1e12 * 49 / 100, "mintDebt at ratio=49");
    }

    // =========================================================================
    // pull
    // =========================================================================

    function test_pull_revertsWhenRecipientUnset_evenForOwner() public {
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");

        vm.expectRevert(UniboostMintDebtHook.RecipientUnset.selector);
        hookContract.pull();
    }

    function test_pull_revertsForStranger() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");

        vm.prank(nonOwner);
        vm.expectRevert(UniboostMintDebtHook.OnlyOwnerOrRecipient.selector);
        hookContract.pull();
    }

    function test_pull_ownerCanPull_mintsScaledPhUSDToRecipient() public {
        hookContract.setRecipient(recipient);
        uint256 amount = 10e6; // 10 USDC
        uint256 expectedMint = 5e18; // amount * 1e12 * 50 / 100
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, amount, "");

        vm.expectEmit(true, false, false, true);
        emit DebtPulled(recipient, expectedMint);
        hookContract.pull(); // owner = address(this)

        assertEq(hookContract.mintDebt(), 0, "mintDebt should be zero after pull");
        assertEq(phUSD.balanceOf(recipient), expectedMint, "scaled phUSD should have been minted to recipient");
        assertEq(phUSD.mintCallCount(), 1, "exactly one mint call");
        (address r, uint256 a) = phUSD.lastMint();
        assertEq(r, recipient, "mint recipient");
        assertEq(a, expectedMint, "mint amount is scaled phUSD debt, not raw prime");
    }

    function test_pull_recipientCanPull() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 10e6, "");

        vm.prank(recipient);
        hookContract.pull();

        assertEq(hookContract.mintDebt(), 0, "mintDebt cleared");
        assertEq(phUSD.balanceOf(recipient), 5e18, "scaled phUSD minted");
    }

    function test_pull_noOpWhenDebtIsZero_afterRecipientSet() public {
        hookContract.setRecipient(recipient);

        vm.recordLogs();
        hookContract.pull();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event when debt is 0");
        assertEq(phUSD.mintCallCount(), 0, "no mint call");
    }

    function test_pull_nonReentrant() public {
        ReentrantMockMintable evil = new ReentrantMockMintable();
        UniboostMintDebtHook h = new UniboostMintDebtHook(owner, dispatcher, address(evil), address(prime6));
        // Make the evil contract itself the recipient so it passes the onlyOwnerOrRecipient
        // gate when re-entering pull() — this isolates the test to the ReentrancyGuard.
        h.setRecipient(address(evil));
        evil.setTarget(IReentrantPullTarget(address(h)));

        vm.prank(dispatcher);
        h.onDispatch(minter, 10e6, "");

        h.pull();

        assertTrue(evil.reentryAttempted(), "reentry attempted");
        assertTrue(evil.reentryReverted(), "inner pull() should have reverted");
        bytes memory reason = evil.reentryRevertData();
        assertEq(reason.length, 4, "revert reason is a 4-byte selector");
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        assertEq(sel, bytes4(keccak256("ReentrancyGuardReentrantCall()")), "selector match");
    }
}
