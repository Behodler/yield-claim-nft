// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MultiPooler} from "../src/MultiPooler.sol";
import {IUniboostPooler} from "../src/interfaces/IUniboostPooler.sol";
import {Uniboost} from "../src/dispatchers/Uniboost.sol";
import {MockERC20, MockUniV2Pair, MockUniV2Router} from "./Uniboost.t.sol";

/// @dev Mock Uniboost-pool target. Records every `pool(...)` call's four args (and call order),
///      and can be configured to revert to simulate min-out / amount / auth / paused failures.
contract MockUniboostPool is IUniboostPooler {
    struct Recorded {
        uint256 amountIn;
        uint256 minPairOut;
        uint256 minTargetOut;
        uint256 minLP;
    }

    Recorded[] public calls;
    bool public shouldRevert;
    string public revertMessage = "MockUniboostPool: forced revert";

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setRevertMessage(string calldata message) external {
        revertMessage = message;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 i) external view returns (uint256, uint256, uint256, uint256) {
        Recorded storage r = calls[i];
        return (r.amountIn, r.minPairOut, r.minTargetOut, r.minLP);
    }

    function pool(uint256 amountIn, uint256 minPairOut, uint256 minTargetOut, uint256 minLP) external override {
        require(!shouldRevert, revertMessage);
        calls.push(Recorded(amountIn, minPairOut, minTargetOut, minLP));
    }
}

contract MultiPoolerTest is Test {
    MultiPooler public multiPooler;

    address public owner = address(this);
    address public poolerAddr = address(0xD00D);
    address public nonOwner = address(0xCAFE);
    address public nonPooler = address(0xBEEF);

    function setUp() public {
        multiPooler = new MultiPooler(owner);
    }

    // =========================================================================
    // constructor
    // =========================================================================

    function test_constructor_setsOwnerAndPoolerUnset() public view {
        assertEq(multiPooler.owner(), owner, "owner set");
        assertEq(multiPooler.pooler(), address(0), "pooler starts unset");
    }

    // =========================================================================
    // setPooler
    // =========================================================================

    function test_setPooler_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        multiPooler.setPooler(poolerAddr);
    }

    function test_setPooler_updatesAndEmits() public {
        vm.expectEmit(true, true, false, false);
        emit MultiPooler.PoolerSet(address(0), poolerAddr);
        multiPooler.setPooler(poolerAddr);
        assertEq(multiPooler.pooler(), poolerAddr, "pooler updated");
    }

    function test_setPooler_zeroAddressAllowed_disablesPooling() public {
        multiPooler.setPooler(poolerAddr);

        vm.expectEmit(true, true, false, false);
        emit MultiPooler.PoolerSet(poolerAddr, address(0));
        multiPooler.setPooler(address(0));
        assertEq(multiPooler.pooler(), address(0), "pooler cleared");

        // With pooler unset, the former pooler can no longer batch.
        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](1);
        calls[0] = MultiPooler.PoolCall(address(new MockUniboostPool()), 1, 0, 0, 0);
        vm.prank(poolerAddr);
        vm.expectRevert("MultiPooler: caller not pooler");
        multiPooler.pool(calls);
    }

    // =========================================================================
    // pool gating
    // =========================================================================

    function test_pool_revertsForNonPooler() public {
        multiPooler.setPooler(poolerAddr);
        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](1);
        calls[0] = MultiPooler.PoolCall(address(new MockUniboostPool()), 1, 0, 0, 0);

        vm.prank(nonPooler);
        vm.expectRevert("MultiPooler: caller not pooler");
        multiPooler.pool(calls);
    }

    function test_pool_revertsForOwnerWhenNotPooler() public {
        // Owner is not implicitly the pooler.
        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](1);
        calls[0] = MultiPooler.PoolCall(address(new MockUniboostPool()), 1, 0, 0, 0);

        vm.expectRevert("MultiPooler: caller not pooler");
        multiPooler.pool(calls);
    }

    function test_pool_revertsOnEmptyBatch() public {
        multiPooler.setPooler(poolerAddr);
        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](0);

        vm.prank(poolerAddr);
        vm.expectRevert("MultiPooler: empty batch");
        multiPooler.pool(calls);
    }

    // =========================================================================
    // pool forwarding
    // =========================================================================

    function test_pool_forwardsPerRowArgsInOrderAndEmits() public {
        multiPooler.setPooler(poolerAddr);

        MockUniboostPool a = new MockUniboostPool();
        MockUniboostPool b = new MockUniboostPool();
        MockUniboostPool c = new MockUniboostPool();

        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](3);
        calls[0] = MultiPooler.PoolCall(address(a), 13e6, 1, 2, 3);
        calls[1] = MultiPooler.PoolCall(address(b), 87e6, 4, 5, 6);
        calls[2] = MultiPooler.PoolCall(address(c), 1e6, 7, 8, 9);

        vm.prank(poolerAddr);
        vm.expectEmit(true, false, false, true);
        emit MultiPooler.BatchPooled(poolerAddr, 3);
        multiPooler.pool(calls);

        // Each target received exactly its row's args.
        assertEq(a.callCount(), 1, "a called once");
        assertEq(b.callCount(), 1, "b called once");
        assertEq(c.callCount(), 1, "c called once");

        (uint256 aAmt, uint256 aPair, uint256 aTgt, uint256 aLP) = a.getCall(0);
        assertEq(aAmt, 13e6);
        assertEq(aPair, 1);
        assertEq(aTgt, 2);
        assertEq(aLP, 3);

        (uint256 bAmt, uint256 bPair, uint256 bTgt, uint256 bLP) = b.getCall(0);
        assertEq(bAmt, 87e6);
        assertEq(bPair, 4);
        assertEq(bTgt, 5);
        assertEq(bLP, 6);

        (uint256 cAmt, uint256 cPair, uint256 cTgt, uint256 cLP) = c.getCall(0);
        assertEq(cAmt, 1e6);
        assertEq(cPair, 7);
        assertEq(cTgt, 8);
        assertEq(cLP, 9);
    }

    function test_pool_singleRevertingTargetRevertsWholeBatch() public {
        multiPooler.setPooler(poolerAddr);

        MockUniboostPool a = new MockUniboostPool();
        MockUniboostPool bad = new MockUniboostPool();
        MockUniboostPool c = new MockUniboostPool();
        bad.setShouldRevert(true);
        bad.setRevertMessage("MockUniboostPool: row failed");

        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](3);
        calls[0] = MultiPooler.PoolCall(address(a), 1, 0, 0, 0);
        calls[1] = MultiPooler.PoolCall(address(bad), 1, 0, 0, 0);
        calls[2] = MultiPooler.PoolCall(address(c), 1, 0, 0, 0);

        vm.prank(poolerAddr);
        vm.expectRevert("MockUniboostPool: row failed");
        multiPooler.pool(calls);

        // Atomicity: no target's effect persisted (the whole tx reverted).
        assertEq(a.callCount(), 0, "a effect reverted");
        assertEq(bad.callCount(), 0, "bad never recorded");
        assertEq(c.callCount(), 0, "c effect reverted");
    }

    // =========================================================================
    // integration: real Uniboost dispatchers
    // =========================================================================

    /// @dev Stand up a real Uniboost wired to mock UniV2 router/pair, with retained prime, and
    ///      register the MultiPooler as an authorized pooler. Returns the dispatcher + its prime.
    function _deployUniboost() internal returns (Uniboost ub, MockERC20 prime, MockUniV2Pair pool) {
        prime = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 target = new MockERC20("EYE", "EYE", 18);
        MockERC20 pair = new MockERC20("Wrapped Ether", "WETH", 18);
        pool = new MockUniV2Pair(address(target), address(pair));
        MockUniV2Router router = new MockUniV2Router();
        router.setLpToken(pool);

        ub = new Uniboost(address(prime), address(router), address(pool), address(target), owner);
        address minter = address(0xBEEF);
        ub.setMinter(minter);

        // Seed retained prime via a dispatch (no donation).
        prime.mint(address(ub), 100e6);
        vm.prank(minter);
        ub.dispatch(minter, 100e6, "");
    }

    function test_integration_batchPassesUniboostAuthAndLeavesRemainder() public {
        (Uniboost ub, MockERC20 prime, MockUniV2Pair pool) = _deployUniboost();

        // Authorize the MultiPooler on the Uniboost; make this test the MultiPooler's pooler.
        ub.setAuthorizedPooler(address(multiPooler), true);
        multiPooler.setPooler(address(this));

        // Pool only part of the retained balance.
        uint256 amountIn = 13e6;
        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](1);
        calls[0] = MultiPooler.PoolCall(address(ub), amountIn, 0, 0, 0);

        multiPooler.pool(calls);

        // Forwarded call passed onlyAuthorizedPooler; partial amount left the remainder behind.
        assertEq(prime.balanceOf(address(ub)), 100e6 - amountIn, "unused prime remains on dispatcher");
        assertTrue(pool.balanceOf(address(ub)) > 0, "LP minted to dispatcher");
    }

    function test_integration_unauthorizedTargetRevertsBatch() public {
        (Uniboost ub,,) = _deployUniboost();

        // Do NOT authorize the MultiPooler on this Uniboost.
        multiPooler.setPooler(address(this));

        MultiPooler.PoolCall[] memory calls = new MultiPooler.PoolCall[](1);
        calls[0] = MultiPooler.PoolCall(address(ub), 13e6, 0, 0, 0);

        vm.expectRevert("Uniboost: caller not authorized pooler");
        multiPooler.pool(calls);
    }
}
