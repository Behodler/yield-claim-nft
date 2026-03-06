// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "../interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPooler
/// @notice A token dispatcher that adds single-sided sUSDS liquidity to a Balancer V3 pool,
///         receiving BPT in return.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
contract BalancerPooler is ATokenDispatcher, IUnlockCallback {
    address private immutable _primeToken;
    address private immutable _pool;
    address private immutable _vault;
    bool private immutable _primeTokenIsFirst;

    constructor(
        address primeToken_,
        address pool_,
        address vault_,
        bool primeTokenIsFirst_,
        address initialOwner
    ) ATokenDispatcher(initialOwner) {
        _primeToken = primeToken_;
        _pool = pool_;
        _vault = vault_;
        _primeTokenIsFirst = primeTokenIsFirst_;
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _primeToken;
    }

    /// @notice Returns the Balancer vault address.
    function vault() external view returns (address) {
        return _vault;
    }

    /// @notice Dispatches tokens (already on this contract) to the Balancer pool via unlock pattern.
    /// @param amount The FOT-adjusted amount of prime token to dispatch.
    /// @param extraData Optional ABI-encoded uint256 for minBptAmountOut slippage protection.
    function dispatch(address, uint256 amount, bytes calldata extraData) external override onlyMinter whenNotPaused {
        uint256 minBptAmountOut = extraData.length > 0 ? abi.decode(extraData, (uint256)) : 0;
        bytes memory data = abi.encode(amount, minBptAmountOut);
        IBalancerVault(_vault).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _vault, "BalancerPooler: caller is not vault");

        (uint256 primeAmount, uint256 minBptAmountOut) = abi.decode(data, (uint256, uint256));

        // Transfer primeToken to vault (balance-before/after for FOT safety)
        uint256 vaultPrimeBefore = IERC20(_primeToken).balanceOf(_vault);
        IERC20(_primeToken).transfer(_vault, primeAmount);
        uint256 actualPrimeInVault = IERC20(_primeToken).balanceOf(_vault) - vaultPrimeBefore;

        // Single-sided join: only primeToken, phUSD amount is 0
        uint256[] memory maxAmountsIn = new uint256[](2);
        if (_primeTokenIsFirst) {
            maxAmountsIn[0] = actualPrimeInVault;
            maxAmountsIn[1] = 0;
        } else {
            maxAmountsIn[0] = 0;
            maxAmountsIn[1] = actualPrimeInVault;
        }

        AddLiquidityParams memory params = AddLiquidityParams({
            pool: _pool,
            to: address(this),
            maxAmountsIn: maxAmountsIn,
            minBptAmountOut: minBptAmountOut,
            kind: AddLiquidityKind.UNBALANCED,
            userData: ""
        });

        IBalancerVault(_vault).addLiquidity(params);
        IBalancerVault(_vault).settle(IERC20(_primeToken), actualPrimeInVault);

        return "";
    }

    /// @notice Withdraws BPT tokens held by this contract to a recipient.
    /// @param recipient The address to receive the BPT tokens.
    /// @param amount The amount of BPT tokens to withdraw.
    function withdrawBPT(address recipient, uint256 amount) external onlyOwner {
        IERC20(_pool).transfer(recipient, amount);
    }
}
