// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NudgeRatchetMintDebtHook} from "../../src/V2/hooks/NudgeRatchetMintDebtHook.sol";
import {NudgeRatchet} from "../../src/V2/dispatchers/NudgeRatchet.sol";
import {IDispatchHook} from "../../src/V2/interfaces/IDispatchHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockMintable, ReentrantMockMintable, IReentrantPullTarget} from "../mocks/MockMintable.sol";

/// @dev USDC-like 6-decimal mock ERC20 for the wiring test.
contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NudgeRatchetMintDebtHookTest is Test {
    NudgeRatchetMintDebtHook internal hookContract;
    MockMintable internal phUSD;

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
        hookContract = new NudgeRatchetMintDebtHook(owner, dispatcher, address(phUSD));
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_constructor_revertsOnZeroDispatcher() public {
        vm.expectRevert("dispatcher=0");
        new NudgeRatchetMintDebtHook(owner, address(0), address(phUSD));
    }

    function test_constructor_revertsOnZeroPhUSD() public {
        vm.expectRevert("phUSD=0");
        new NudgeRatchetMintDebtHook(owner, dispatcher, address(0));
    }

    function test_constructor_setsDispatcherAndPhUSD() public view {
        assertEq(hookContract.dispatcher(), dispatcher, "dispatcher should match ctor arg");
        assertEq(address(hookContract.phUSD()), address(phUSD), "phUSD should match ctor arg");
    }

    function test_constructor_setsDefaultRatioAndConstants() public view {
        assertEq(hookContract.ratio(), 100, "ratio should default to 100");
        assertEq(hookContract.DEFAULT_RATIO(), 100, "DEFAULT_RATIO constant should be 100");
        assertEq(hookContract.MAX_RATIO(), 200, "MAX_RATIO constant should be 200");
    }

    function test_constructor_emitsRatioUpdated() public {
        MockMintable freshPhUSD = new MockMintable();
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(0, 100);
        new NudgeRatchetMintDebtHook(owner, dispatcher, address(freshPhUSD));
    }

    function test_constructor_transfersOwnershipToInitialOwner() public {
        address newOwner = address(0xCAFE);
        NudgeRatchetMintDebtHook h = new NudgeRatchetMintDebtHook(newOwner, dispatcher, address(phUSD));
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
        vm.expectRevert(NudgeRatchetMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");

        // New dispatcher can; at default ratio 100, debt == amount.
        vm.prank(newDispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(hookContract.mintDebt(), 1000, "new dispatcher should accrue debt at 100%");
    }

    // =========================================================================
    // setRatio (inclusive bound: <= MAX_RATIO == 200)
    // =========================================================================

    function test_setRatio_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        hookContract.setRatio(10);
    }

    function test_setRatio_200Succeeds_andEmits() public {
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(100, 200);
        hookContract.setRatio(200);
        assertEq(hookContract.ratio(), 200, "ratio should be 200 (inclusive max)");
    }

    function test_setRatio_201Reverts() public {
        vm.expectRevert(NudgeRatchetMintDebtHook.RatioTooHigh.selector);
        hookContract.setRatio(201);
    }

    function test_setRatio_255Reverts() public {
        vm.expectRevert(NudgeRatchetMintDebtHook.RatioTooHigh.selector);
        hookContract.setRatio(255);
    }

    function test_setRatio_0Succeeds() public {
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(100, 0);
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
        vm.expectRevert(NudgeRatchetMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_ownerAlsoCannotCall() public {
        vm.expectRevert(NudgeRatchetMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_accruesDebt_defaultRatio_equalsAmount() public {
        uint256 amount = 1000;
        uint256 expectedAdded = 1000; // 100% of 1000

        vm.expectEmit(true, false, false, true);
        emit DebtAccrued(minter, amount, expectedAdded, expectedAdded);

        vm.prank(dispatcher);
        hookContract.onDispatch(minter, amount, "");

        assertEq(hookContract.mintDebt(), expectedAdded, "mintDebt should equal amount at default 100%");
    }

    function test_onDispatch_accruesDebt_maxRatio_doublesAmount() public {
        hookContract.setRatio(200);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(hookContract.mintDebt(), 2000, "mintDebt should be 2x amount at 200%");
    }

    function test_onDispatch_multipleCallsAccumulate() public {
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(hookContract.mintDebt(), 2000, "mintDebt should accumulate to 2000");
    }

    function test_onDispatch_zeroRatio_noDebt_noEvent() public {
        hookContract.setRatio(0);

        vm.recordLogs();
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events should be emitted at ratio=0");
        assertEq(hookContract.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_smallAmountRoundingToZero_noEvent() public {
        // With ratio=100, amount must be 0 to round added to 0; use a tiny ratio to
        // exercise the rounding no-op path: ratio=1, amount=99 -> (99*1)/100 = 0.
        hookContract.setRatio(1);
        vm.recordLogs();
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 99, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events on zero-added rounding case");
        assertEq(hookContract.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_ignoresExtraData() public {
        bytes memory payload = hex"deadbeef1234";
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, payload);
        assertEq(hookContract.mintDebt(), 1000, "mintDebt should still be 1000");
    }

    // =========================================================================
    // pull
    // =========================================================================

    function test_pull_revertsWhenRecipientUnset_evenForOwner() public {
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.expectRevert(NudgeRatchetMintDebtHook.RecipientUnset.selector);
        hookContract.pull();
    }

    function test_pull_revertsForStranger() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.prank(nonOwner);
        vm.expectRevert(NudgeRatchetMintDebtHook.OnlyOwnerOrRecipient.selector);
        hookContract.pull();
    }

    function test_pull_ownerCanPull_mintsToRecipient() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.expectEmit(true, false, false, true);
        emit DebtPulled(recipient, 1000);
        hookContract.pull(); // owner = address(this)

        assertEq(hookContract.mintDebt(), 0, "mintDebt should be zero after pull");
        assertEq(phUSD.balanceOf(recipient), 1000, "phUSD should have been minted to recipient");
        assertEq(phUSD.mintCallCount(), 1, "exactly one mint call");
        (address r, uint256 a) = phUSD.lastMint();
        assertEq(r, recipient, "mint recipient");
        assertEq(a, 1000, "mint amount");
    }

    function test_pull_recipientCanPull() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.prank(recipient);
        hookContract.pull();

        assertEq(hookContract.mintDebt(), 0, "mintDebt cleared");
        assertEq(phUSD.balanceOf(recipient), 1000, "phUSD minted");
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
        NudgeRatchetMintDebtHook h = new NudgeRatchetMintDebtHook(owner, dispatcher, address(evil));
        h.setRecipient(address(evil));
        evil.setTarget(IReentrantPullTarget(address(h)));

        vm.prank(dispatcher);
        h.onDispatch(minter, 1000, "");

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

    // =========================================================================
    // Wiring / integration: NudgeRatchet + NudgeRatchetMintDebtHook
    // =========================================================================

    function test_wiring_dispatchForwardsUSDCAndAccruesDebtAtDefaultRatio() public {
        MockUSDC6 usdc = new MockUSDC6();
        address batchMinterAddr = address(0xCAFE);
        address dispatcherMinter = address(0xB0BB1E);

        NudgeRatchet ratchet = new NudgeRatchet(address(usdc), batchMinterAddr, owner);
        NudgeRatchetMintDebtHook hook = new NudgeRatchetMintDebtHook(owner, address(ratchet), address(phUSD));

        // Wiring per story: setHook then setMinter.
        ratchet.setHook(IDispatchHook(address(hook)));
        ratchet.setMinter(dispatcherMinter);

        uint256 amount = 500e6;
        usdc.mint(address(ratchet), amount);

        vm.prank(dispatcherMinter);
        ratchet.dispatch(dispatcherMinter, amount, "");

        // USDC moved to batchMinter.
        assertEq(usdc.balanceOf(batchMinterAddr), amount, "USDC should be forwarded to batchMinter");
        assertEq(usdc.balanceOf(address(ratchet)), 0, "ratchet should hold no USDC");

        // Debt accrued at default ratio 100% == amount.
        assertEq(hook.mintDebt(), amount, "mintDebt should equal amount at default ratio 100%");
    }
}
