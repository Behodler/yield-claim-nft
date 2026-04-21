// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMintable} from "../../src/interfaces/IMintable.sol";

/// @dev Recording mock implementing `IMintable`. Captures each `mint(recipient, amount)`
///      call and maintains a cumulative balance per recipient for assertions.
contract MockMintable is IMintable {
    struct MintCall {
        address recipient;
        uint256 amount;
    }

    MintCall[] public mintCalls;
    mapping(address => uint256) public balanceOf;

    function mint(address recipient, uint256 amount) external virtual override {
        mintCalls.push(MintCall({recipient: recipient, amount: amount}));
        balanceOf[recipient] += amount;
    }

    function mintCallCount() external view returns (uint256) {
        return mintCalls.length;
    }

    function lastMint() external view returns (address recipient, uint256 amount) {
        require(mintCalls.length > 0, "MockMintable: no mint calls");
        MintCall memory c = mintCalls[mintCalls.length - 1];
        return (c.recipient, c.amount);
    }
}

/// @dev Reentrant mock implementing `IMintable`. On each `mint` call, attempts to
///      re-enter `pull()` on a configured target. Used to verify that `pull()` is
///      protected by a reentrancy guard.
interface IReentrantPullTarget {
    function pull() external;
}

contract ReentrantMockMintable is IMintable {
    IReentrantPullTarget public target;
    bool public reentryAttempted;
    bytes public reentryRevertData;
    bool public reentryReverted;

    function setTarget(IReentrantPullTarget target_) external {
        target = target_;
    }

    function mint(address, uint256) external override {
        reentryAttempted = true;
        try target.pull() {
            // If pull() succeeds on re-entry, the guard is broken.
            reentryReverted = false;
        } catch (bytes memory reason) {
            reentryReverted = true;
            reentryRevertData = reason;
        }
    }
}
