// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";

/// @title BalancerPooler
/// @notice A token dispatcher that accumulates tokens in the minter until thresholds are met,
///         then transfers both prime and matching tokens for pool donation.
/// @dev The actual pool donation (joinPool or equivalent) is a TODO stub for a future story.
contract BalancerPooler is ITokenDispatcher, Ownable {
    address private immutable _primeToken;
    address private immutable _matchingToken;
    address private immutable _pool;
    string private _flavour;

    /// @notice Minimum amount of prime token on the minter before pooling is triggered.
    uint256 public primeTokenThreshold;

    /// @notice Minimum amount of matching token on the minter before pooling is triggered.
    uint256 public matchingTokenThreshold;

    event ThresholdsUpdated(uint256 primeTokenThreshold, uint256 matchingTokenThreshold);

    constructor(address primeToken_, address matchingToken_, address pool_, string memory flavour_, address initialOwner)
        Ownable(initialOwner)
    {
        _primeToken = primeToken_;
        _matchingToken = matchingToken_;
        _pool = pool_;
        _flavour = flavour_;
    }

    /// @notice Sets the prime token threshold. Only callable by owner.
    /// @param threshold The new threshold value.
    function setPrimeTokenThreshold(uint256 threshold) external onlyOwner {
        primeTokenThreshold = threshold;
        emit ThresholdsUpdated(primeTokenThreshold, matchingTokenThreshold);
    }

    /// @notice Sets the matching token threshold. Only callable by owner.
    /// @param threshold The new threshold value.
    function setMatchingTokenThreshold(uint256 threshold) external onlyOwner {
        matchingTokenThreshold = threshold;
        emit ThresholdsUpdated(primeTokenThreshold, matchingTokenThreshold);
    }

    /// @inheritdoc ITokenDispatcher
    function tokensToApprove() external view returns (address[] memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = _matchingToken;
        return tokens;
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _primeToken;
    }

    /// @inheritdoc ITokenDispatcher
    function flavour() external view returns (string memory) {
        return _flavour;
    }

    /// @inheritdoc ITokenDispatcher
    function dispatch(address minter, uint256 amount) external {
        // Check if both thresholds are met on the minter
        uint256 primeBalance = IERC20(_primeToken).balanceOf(minter);
        uint256 matchingBalance = IERC20(_matchingToken).balanceOf(minter);

        if (primeBalance >= primeTokenThreshold && matchingBalance >= matchingTokenThreshold) {
            // Transfer both tokens from minter to this contract
            IERC20(_primeToken).transferFrom(minter, address(this), primeBalance);
            IERC20(_matchingToken).transferFrom(minter, address(this), matchingBalance);

            // TODO: Donate to Balancer pool using _pool address.
            // This will be implemented in a future story with actual Balancer integration.
            // For now, tokens are held in this contract after transfer.
        }
        // If thresholds not met, do nothing. Tokens accumulate in the minter.
    }
}
