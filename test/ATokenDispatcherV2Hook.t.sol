// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ATokenDispatcherV2} from "../src/dispatchers/ATokenDispatcherV2.sol";
import {IDispatchHook} from "../src/interfaces/IDispatchHook.sol";
import {DefaultDispatchHook} from "../src/hooks/DefaultDispatchHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    MockDispatchHook,
    RevertingDispatchHook,
    ReentrantDispatchHook,
    IReentrantDispatchTarget
} from "./mocks/MockDispatchHook.sol";

/// @dev Minimal concrete test harness that exposes `_dispatch` side effects so we can
///      assert the abstract's dispatch pipeline (modifier chain, hook callout,
///      reentrancy guard) without pulling in a real concrete dispatcher.
contract TestDispatcherV2 is ATokenDispatcherV2 {
    uint256 public dispatchCalls;
    address public lastMinter;
    uint256 public lastAmount;
    bytes public lastExtraData;

    constructor(address initialOwner) ATokenDispatcherV2(initialOwner) {}

    function primeToken() external pure returns (address) {
        return address(0);
    }

    function _dispatch(address minter, uint256 amount, bytes calldata extraData) internal override {
        dispatchCalls += 1;
        lastMinter = minter;
        lastAmount = amount;
        lastExtraData = extraData;
    }
}

contract ATokenDispatcherV2HookTest is Test {
    TestDispatcherV2 internal dispatcher;

    address internal owner = address(this);
    address internal minter = address(0xB0B);
    address internal nonOwner = address(0xDEAD);

    event HookUpdated(address indexed oldHook, address indexed newHook);

    function setUp() public {
        dispatcher = new TestDispatcherV2(owner);
        dispatcher.setMinter(minter);
    }

    // =========================================================================
    // default hook invariant
    // =========================================================================

    function test_constructor_deploysDefaultHook() public view {
        address deployedHook = address(dispatcher.hook());
        assertTrue(deployedHook != address(0), "hook should be non-zero after construction");
        assertGt(deployedHook.code.length, 0, "hook should have bytecode");
    }

    function test_defaultHook_onDispatch_doesNotRevert() public {
        // default no-op hook: dispatch should succeed with no side effects from the hook
        vm.prank(minter);
        dispatcher.dispatch(minter, 100, hex"");
        assertEq(dispatcher.dispatchCalls(), 1);
    }

    function test_defaultHook_onDispatch_emitsNoEvents() public {
        vm.recordLogs();
        vm.prank(minter);
        dispatcher.dispatch(minter, 7, hex"1234");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "default hook should not emit events");
    }

    // =========================================================================
    // setHook
    // =========================================================================

    function test_setHook_revertsWhenCalledByNonOwner() public {
        MockDispatchHook newHook = new MockDispatchHook();
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        dispatcher.setHook(IDispatchHook(address(newHook)));
    }

    function test_setHook_revertsWhenHookIsZeroAddress() public {
        vm.expectRevert("ATokenDispatcherV2: zero hook");
        dispatcher.setHook(IDispatchHook(address(0)));
    }

    function test_setHook_emitsHookUpdatedEvent() public {
        MockDispatchHook newHook = new MockDispatchHook();
        address oldHook = address(dispatcher.hook());

        vm.expectEmit(true, true, false, true);
        emit HookUpdated(oldHook, address(newHook));
        dispatcher.setHook(IDispatchHook(address(newHook)));

        assertEq(address(dispatcher.hook()), address(newHook), "hook should be updated");
    }

    // =========================================================================
    // hook call-through
    // =========================================================================

    function test_dispatch_forwardsArgsToHookVerbatim() public {
        MockDispatchHook newHook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(newHook)));

        bytes memory payload = hex"deadbeefcafe";
        vm.prank(minter);
        dispatcher.dispatch(minter, 42, payload);

        assertEq(newHook.callCount(), 1, "hook should be called exactly once");
        assertEq(newHook.lastMinter(), minter, "hook should receive minter");
        assertEq(newHook.lastAmount(), 42, "hook should receive amount");
        assertEq(newHook.lastExtraData(), payload, "hook should receive extraData verbatim");
    }

    function test_dispatch_callsHookAfter_dispatch() public {
        MockDispatchHook newHook = new MockDispatchHook();
        dispatcher.setHook(IDispatchHook(address(newHook)));

        vm.prank(minter);
        dispatcher.dispatch(minter, 1, hex"");

        assertEq(dispatcher.dispatchCalls(), 1, "_dispatch should run");
        assertEq(newHook.callCount(), 1, "hook should run");
    }

    function test_dispatch_revertsWhenHookReverts() public {
        RevertingDispatchHook bad = new RevertingDispatchHook();
        dispatcher.setHook(IDispatchHook(address(bad)));

        vm.prank(minter);
        vm.expectRevert("RevertingDispatchHook: forced revert");
        dispatcher.dispatch(minter, 1, hex"");
    }

    // =========================================================================
    // nonReentrant guard
    // =========================================================================

    function test_dispatch_blocksHookReentry() public {
        ReentrantDispatchHook attacker = new ReentrantDispatchHook();
        attacker.setTarget(IReentrantDispatchTarget(address(dispatcher)));
        dispatcher.setHook(IDispatchHook(address(attacker)));

        // The reentrant hook will try to call `dispatch` from the minter's context,
        // but since the hook is invoked synchronously inside `dispatch`, msg.sender
        // on the reentrant call is the hook — we expect the reentrancy guard, not
        // the minter check, to fire first.
        //
        // The outer call needs to pass onlyMinter; the inner call fails reentrancy.
        vm.prank(minter);
        // The revert bubbles up from the nested call. OZ v5 reverts with
        // ReentrancyGuardReentrantCall — that's what we expect inside the hook path.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        dispatcher.dispatch(minter, 1, hex"");
    }
}
