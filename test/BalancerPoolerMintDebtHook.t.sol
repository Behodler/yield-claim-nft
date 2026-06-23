// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    BalancerPoolerMintDebtHook
} from "../src/hooks/BalancerPoolerMintDebtHook.sol";
import {IMintable} from "../src/interfaces/IMintable.sol";
import {
    MockMintable,
    ReentrantMockMintable,
    IReentrantPullTarget
} from "./mocks/MockMintable.sol";

contract BalancerPoolerMintDebtHookTest is Test {
    BalancerPoolerMintDebtHook internal hookContract;
    MockMintable internal phUSD;

    address internal owner = address(this);
    address internal nonOwner = address(0xBAD);
    address internal dispatcher = address(0xD15);
    address internal minter = address(0xB0B);
    address internal recipient = address(0xFEED);

    // Mirror the events from the hook for vm.expectEmit
    event RatioUpdated(uint8 oldRatio, uint8 newRatio);
    event RecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );
    event DebtAccrued(
        address indexed minter,
        uint256 dispatchedAmount,
        uint256 debtAdded,
        uint256 newTotalDebt
    );
    event DebtPulled(address indexed recipient, uint256 amount);
    event DispatcherUpdated(
        address indexed oldDispatcher,
        address indexed newDispatcher
    );

    function setUp() public {
        phUSD = new MockMintable();
        hookContract = new BalancerPoolerMintDebtHook(
            owner,
            dispatcher,
            address(phUSD)
        );
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_constructor_revertsOnZeroDispatcher() public {
        vm.expectRevert("dispatcher=0");
        new BalancerPoolerMintDebtHook(owner, address(0), address(phUSD));
    }

    function test_constructor_revertsOnZeroPhUSD() public {
        vm.expectRevert("phUSD=0");
        new BalancerPoolerMintDebtHook(owner, dispatcher, address(0));
    }

    function test_constructor_setsDispatcherAndPhUSD() public view {
        assertEq(
            hookContract.dispatcher(),
            dispatcher,
            "dispatcher should match ctor arg"
        );
        assertEq(
            address(hookContract.phUSD()),
            address(phUSD),
            "phUSD should match ctor arg"
        );
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
        new BalancerPoolerMintDebtHook(owner, dispatcher, address(freshPhUSD));
    }

    function test_constructor_transfersOwnershipToInitialOwner() public {
        address newOwner = address(0xCAFE);
        BalancerPoolerMintDebtHook h = new BalancerPoolerMintDebtHook(
            newOwner,
            dispatcher,
            address(phUSD)
        );
        assertEq(h.owner(), newOwner, "owner should be initialOwner");
    }

    // =========================================================================
    // setDispatcher (§8b — dispatcher is mutable, owner-repointable)
    // =========================================================================

    function test_setDispatcher_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
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
        assertEq(
            hookContract.dispatcher(),
            newDispatcher,
            "dispatcher should be updated"
        );
    }

    function test_setDispatcher_updatesOnDispatchGate() public {
        address newDispatcher = address(0xDEAD);
        hookContract.setDispatcher(newDispatcher);

        // Old dispatcher can no longer call onDispatch.
        vm.prank(dispatcher);
        vm.expectRevert(BalancerPoolerMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");

        // New dispatcher can.
        vm.prank(newDispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(
            hookContract.mintDebt(),
            500,
            "new dispatcher should accrue debt on gross amount"
        );
    }

    function test_setDispatcher_debtAccruesOnGrossAmount() public {
        // §8a-req-3: debt accrues on the GROSS dispatched amount regardless of
        // any donation carve-out. The hook only ever sees `amount` passed by the
        // dispatcher, so accrual is always ratio% of the full amount.
        address newDispatcher = address(0xDEAD);
        hookContract.setDispatcher(newDispatcher);

        uint256 grossAmount = 1000;
        vm.prank(newDispatcher);
        hookContract.onDispatch(minter, grossAmount, "");
        assertEq(
            hookContract.mintDebt(),
            (grossAmount * 50) / 100,
            "debt must be ratio% of gross amount"
        );
    }

    // =========================================================================
    // setRatio
    // =========================================================================

    function test_setRatio_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
        hookContract.setRatio(10);
    }

    function test_setRatio_49Succeeds_andEmits() public {
        vm.expectEmit(false, false, false, true);
        emit RatioUpdated(50, 49);
        hookContract.setRatio(49);
        assertEq(hookContract.ratio(), 49, "ratio should be 49");
    }

    function test_setRatio_51Reverts() public {
        vm.expectRevert(BalancerPoolerMintDebtHook.RatioTooHigh.selector);
        hookContract.setRatio(51);
    }

    function test_setRatio_200Reverts() public {
        vm.expectRevert(BalancerPoolerMintDebtHook.RatioTooHigh.selector);
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
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                nonOwner
            )
        );
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
        vm.expectRevert(BalancerPoolerMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_ownerAlsoCannotCall() public {
        vm.expectRevert(BalancerPoolerMintDebtHook.OnlyDispatcher.selector);
        hookContract.onDispatch(minter, 1000, "");
    }

    function test_onDispatch_accruesDebt_defaultRatio() public {
        uint256 amount = 1000;
        uint256 expectedAdded = 500; // 50% of 1000

        vm.expectEmit(true, false, false, true);
        emit DebtAccrued(minter, amount, expectedAdded, expectedAdded);

        vm.prank(dispatcher);
        hookContract.onDispatch(minter, amount, "");

        assertEq(
            hookContract.mintDebt(),
            expectedAdded,
            "mintDebt should be 500"
        );
    }

    function test_onDispatch_multipleCallsAccumulate() public {
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(
            hookContract.mintDebt(),
            1000,
            "mintDebt should accumulate to 1000"
        );
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
        // With ratio=50 and amount=1, (1*50)/100 = 0 -> should be silent no-op
        vm.recordLogs();
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events on zero-added rounding case");
        assertEq(hookContract.mintDebt(), 0, "mintDebt should remain 0");
    }

    function test_onDispatch_ignoresExtraData() public {
        // Any bytes payload should not affect behavior or cause reverts.
        bytes memory payload = hex"deadbeef1234";
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, payload);
        assertEq(hookContract.mintDebt(), 500, "mintDebt should still be 500");
    }

    function test_onDispatch_ratio49() public {
        hookContract.setRatio(49);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");
        assertEq(
            hookContract.mintDebt(),
            490,
            "mintDebt should be 490 at ratio=49"
        );
    }

    // =========================================================================
    // pull
    // =========================================================================

    function test_pull_revertsWhenRecipientUnset_evenForOwner() public {
        // Accrue some debt
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.expectRevert(BalancerPoolerMintDebtHook.RecipientUnset.selector);
        hookContract.pull();
    }

    function test_pull_revertsForStranger() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.prank(nonOwner);
        vm.expectRevert(
            BalancerPoolerMintDebtHook.OnlyOwnerOrRecipient.selector
        );
        hookContract.pull();
    }

    function test_pull_ownerCanPull_mintsToRecipient() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.expectEmit(true, false, false, true);
        emit DebtPulled(recipient, 500);
        hookContract.pull(); // owner = address(this)

        assertEq(
            hookContract.mintDebt(),
            0,
            "mintDebt should be zero after pull"
        );
        assertEq(
            phUSD.balanceOf(recipient),
            500,
            "phUSD should have been minted to recipient"
        );
        assertEq(phUSD.mintCallCount(), 1, "exactly one mint call");
        (address r, uint256 a) = phUSD.lastMint();
        assertEq(r, recipient, "mint recipient");
        assertEq(a, 500, "mint amount");
    }

    function test_pull_recipientCanPull() public {
        hookContract.setRecipient(recipient);
        vm.prank(dispatcher);
        hookContract.onDispatch(minter, 1000, "");

        vm.prank(recipient);
        hookContract.pull();

        assertEq(hookContract.mintDebt(), 0, "mintDebt cleared");
        assertEq(phUSD.balanceOf(recipient), 500, "phUSD minted");
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
        BalancerPoolerMintDebtHook h = new BalancerPoolerMintDebtHook(
            owner,
            dispatcher,
            address(evil)
        );
        // Make the evil contract itself the recipient so it passes the onlyOwnerOrRecipient
        // gate when re-entering pull() — this isolates the test to the ReentrancyGuard.
        h.setRecipient(address(evil));
        evil.setTarget(IReentrantPullTarget(address(h)));

        vm.prank(dispatcher);
        h.onDispatch(minter, 1000, "");

        // The outer pull() call does NOT revert — the inner re-entry reverts inside mint(),
        // which is caught by the evil mock's try/catch. Verify the re-entry happened and
        // that it reverted with ReentrancyGuardReentrantCall.
        h.pull();

        assertTrue(evil.reentryAttempted(), "reentry attempted");
        assertTrue(evil.reentryReverted(), "inner pull() should have reverted");
        bytes memory reason = evil.reentryRevertData();
        // OZ 5 reentrancy guard selector: ReentrancyGuardReentrantCall()
        assertEq(reason.length, 4, "revert reason is a 4-byte selector");
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        assertEq(
            sel,
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "selector match"
        );
    }
}
