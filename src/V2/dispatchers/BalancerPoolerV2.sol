// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IBalancerVault} from "../../interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "../../interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPoolerV2
/// @notice A V2 token dispatcher that adds single-sided liquidity to a Balancer V3 sUSDS/phUSD pool.
///         Users pay in USDS (the prime token); the dispatcher wraps USDS into sUSDS via ERC4626
///         deposit before adding single-sided liquidity.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
///      V2 changes: _pool is mutable (settable by owner), primeToken() returns USDS (derived from sUSDS).
///      Retains the unlockCallback selector wrapping fix from story 021.
contract BalancerPoolerV2 is ATokenDispatcherV2, IUnlockCallback {
    address internal immutable _sUSDS;
    address internal immutable _primeToken;
    address private _pool;
    address private immutable _vault;
    bool private immutable _sUSDSIsFirst;

    constructor(address sUSDS_, address pool_, address vault_, bool sUSDSIsFirst_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(sUSDS_ != address(0), "BalancerPoolerV2: zero sUSDS");
        _sUSDS = sUSDS_;
        _primeToken = IERC4626(sUSDS_).asset();
        _pool = pool_;
        _vault = vault_;
        _sUSDSIsFirst = sUSDSIsFirst_;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view override returns (address) {
        return _primeToken;
    }

    /// @notice Returns the sUSDS (ERC4626 wrapper) address.
    function sUSDS() external view returns (address) {
        return _sUSDS;
    }

    /// @notice Returns the Balancer vault address.
    function vault() external view returns (address) {
        return _vault;
    }

    /// @notice Returns the current pool address.
    function pool() external view returns (address) {
        return _pool;
    }

    /// @notice Sets the Balancer pool address. Only callable by owner.
    /// @param newPool The new pool address.
    function setPool(address newPool) external onlyOwner {
        require(newPool != address(0), "BalancerPoolerV2: zero pool address");
        _pool = newPool;
    }

    /// @notice Dispatches tokens (already on this contract) to the Balancer pool via unlock pattern.
    /// @param amount The FOT-adjusted amount of USDS to dispatch.
    /// @param extraData Optional ABI-encoded uint256 for minBptAmountOut slippage protection.
    function dispatch(address, uint256 amount, bytes calldata extraData) external override onlyMinter whenNotPaused {
        uint256 minBptAmountOut = extraData.length > 0 ? abi.decode(extraData, (uint256)) : 0;
        bytes memory innerData = abi.encode(amount, minBptAmountOut);
        bytes memory data = abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, innerData);
        IBalancerVault(_vault).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _vault, "BalancerPoolerV2: caller is not vault");

        (uint256 usdsAmount, uint256 minBptAmountOut) = abi.decode(data, (uint256, uint256));

        // 1. Wrap USDS -> sUSDS via ERC4626 deposit
        IERC20(_primeToken).approve(_sUSDS, usdsAmount);
        uint256 sUSDSShares = IERC4626(_sUSDS).deposit(usdsAmount, address(this));

        // 2. Transfer sUSDS to Balancer vault (balance-before/after for safety)
        uint256 vaultBefore = IERC20(_sUSDS).balanceOf(_vault);
        IERC20(_sUSDS).transfer(_vault, sUSDSShares);
        uint256 actualInVault = IERC20(_sUSDS).balanceOf(_vault) - vaultBefore;

        // 3. Single-sided add of sUSDS to the sUSDS/phUSD pool
        uint256[] memory maxAmountsIn = new uint256[](2);
        if (_sUSDSIsFirst) {
            maxAmountsIn[0] = actualInVault;
            maxAmountsIn[1] = 0;
        } else {
            maxAmountsIn[0] = 0;
            maxAmountsIn[1] = actualInVault;
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
        IBalancerVault(_vault).settle(IERC20(_sUSDS), actualInVault);

        return "";
    }

    /// @notice Withdraws BPT tokens held by this contract to a recipient.
    /// @param recipient The address to receive the BPT tokens.
    /// @param amount The amount of BPT tokens to withdraw.
    function withdrawBPT(address recipient, uint256 amount) external onlyOwner {
        IERC20(_pool).transfer(recipient, amount);
    }
}
