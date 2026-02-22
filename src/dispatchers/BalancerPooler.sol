// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "../interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPooler
/// @notice A token dispatcher that accumulates tokens in the minter until thresholds are met,
///         then donates both prime and matching tokens to a Balancer V3 pool at a 1:1 ratio.
///         Because tokens balances are usually not in a 1:1 ratio, there will be some leftover of 1 token. This is just left in minter to accumulate.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
contract BalancerPooler is ITokenDispatcher, IUnlockCallback, Ownable {
    address private immutable _primeToken;
    address private immutable _matchingToken;
    address private immutable _pool;
    address private immutable _vault;
    bool private immutable _primeTokenIsFirst;
    string private _flavour;

    /// @notice Minimum amount of prime token on the minter before pooling is triggered.
    uint256 public primeTokenThreshold;

    /// @notice Minimum amount of matching token on the minter before pooling is triggered.
    uint256 public matchingTokenThreshold;

    event ThresholdsUpdated(uint256 primeTokenThreshold, uint256 matchingTokenThreshold);

    constructor(
        address primeToken_,
        address matchingToken_,
        address pool_,
        address vault_,
        bool primeTokenIsFirst_,
        string memory flavour_,
        address initialOwner
    ) Ownable(initialOwner) {
        _primeToken = primeToken_;
        _matchingToken = matchingToken_;
        _pool = pool_;
        _vault = vault_;
        _primeTokenIsFirst = primeTokenIsFirst_;
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

    /// @notice Returns the Balancer vault address.
    function vault() external view returns (address) {
        return _vault;
    }

    /// @inheritdoc ITokenDispatcher
    function dispatch(address minter, uint256 amount) external {
        // Check if both thresholds are met on the minter
        uint256 primeBalance = IERC20(_primeToken).balanceOf(minter);
        uint256 matchingBalance = IERC20(_matchingToken).balanceOf(minter);

        if (primeBalance >= primeTokenThreshold && matchingBalance >= matchingTokenThreshold) {
            // 1:1 ratio: donate the minimum of both balances
            uint256 donateAmount = primeBalance < matchingBalance ? primeBalance : matchingBalance;

            // Transfer only equal amounts from minter (remainder stays in minter)
            IERC20(_primeToken).transferFrom(minter, address(this), donateAmount);
            IERC20(_matchingToken).transferFrom(minter, address(this), donateAmount);

            // Initiate Balancer V3 unlock flow for donation
            bytes memory data = abi.encode(donateAmount);
            IBalancerVault(_vault).unlock(data);
        }
        // If thresholds not met, do nothing. Tokens accumulate in the minter.
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == _vault, "BalancerPooler: caller is not vault");

        uint256 donateAmount = abi.decode(data, (uint256));

        // Build amounts array: both slots get the same donateAmount (1:1 ratio)
        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = donateAmount;
        maxAmountsIn[1] = donateAmount;

        AddLiquidityParams memory params = AddLiquidityParams({
            pool: _pool,
            to: address(this),
            maxAmountsIn: maxAmountsIn,
            minBptAmountOut: 0,
            kind: AddLiquidityKind.DONATION,
            userData: ""
        });

        IBalancerVault(_vault).addLiquidity(params);

        // Transfer tokens to vault and settle
        IERC20 primeERC20 = IERC20(_primeToken);
        IERC20 matchingERC20 = IERC20(_matchingToken);

        primeERC20.transfer(_vault, donateAmount);
        IBalancerVault(_vault).settle(primeERC20, donateAmount);

        matchingERC20.transfer(_vault, donateAmount);
        IBalancerVault(_vault).settle(matchingERC20, donateAmount);

        return "";
    }
}
