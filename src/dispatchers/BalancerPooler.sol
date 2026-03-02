// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ATokenDispatcher} from "./ATokenDispatcher.sol";
import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "../interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPooler
/// @notice A token dispatcher that mints phUSD to match incoming prime token amounts,
///         then donates both tokens to a Balancer V3 pool.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
contract BalancerPooler is ATokenDispatcher, IUnlockCallback {
    address private immutable _primeToken;
    address private immutable _phUSD;
    address private immutable _pool;
    address private immutable _vault;
    bool private immutable _primeTokenIsFirst;
    string private _flavour;

    constructor(
        address primeToken_,
        address phUSD_,
        address pool_,
        address vault_,
        bool primeTokenIsFirst_,
        string memory flavour_,
        address initialOwner
    ) ATokenDispatcher(initialOwner) {
        _primeToken = primeToken_;
        _phUSD = phUSD_;
        _pool = pool_;
        _vault = vault_;
        _primeTokenIsFirst = primeTokenIsFirst_;
        _flavour = flavour_;
    }

    /// @inheritdoc ITokenDispatcher
    function primeToken() external view returns (address) {
        return _primeToken;
    }

    /// @inheritdoc ITokenDispatcher
    function flavour() external view returns (string memory) {
        return _flavour;
    }

    /// @notice Returns the phUSD token address.
    function phUSD() external view returns (address) {
        return _phUSD;
    }

    /// @notice Returns the Balancer vault address.
    function vault() external view returns (address) {
        return _vault;
    }

    /// @notice Dispatches tokens (already on this contract) to the Balancer pool via unlock pattern.
    /// @param amount The FOT-adjusted amount of prime token to donate.
    function dispatch(address, uint256 amount) external override onlyMinter whenNotPaused {
        bytes memory data = abi.encode(amount);
        IBalancerVault(_vault).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _vault, "BalancerPooler: caller is not vault");

        uint256 primeAmount = abi.decode(data, (uint256));

        // Transfer primeToken to vault (balance-before/after for FOT safety)
        uint256 vaultPrimeBefore = IERC20(_primeToken).balanceOf(_vault);
        IERC20(_primeToken).transfer(_vault, primeAmount);
        uint256 actualPrimeInVault = IERC20(_primeToken).balanceOf(_vault) - vaultPrimeBefore;

        // Mint phUSD based on actual prime received by vault
        uint256 phUSDAmount = _normalizeToPhUSD(actualPrimeInVault);
        IMintable(_phUSD).mint(address(this), phUSDAmount);
        IERC20(_phUSD).transfer(_vault, phUSDAmount);

        uint256[] memory maxAmountsIn = new uint256[](2);
        if (_primeTokenIsFirst) {
            maxAmountsIn[0] = actualPrimeInVault;
            maxAmountsIn[1] = phUSDAmount;
        } else {
            maxAmountsIn[0] = phUSDAmount;
            maxAmountsIn[1] = actualPrimeInVault;
        }

        AddLiquidityParams memory params = AddLiquidityParams({
            pool: _pool,
            to: address(this),
            maxAmountsIn: maxAmountsIn,
            minBptAmountOut: 0,
            kind: AddLiquidityKind.DONATION,
            userData: ""
        });

        IBalancerVault(_vault).addLiquidity(params);
        IBalancerVault(_vault).settle(IERC20(_primeToken), actualPrimeInVault);
        IBalancerVault(_vault).settle(IERC20(_phUSD), phUSDAmount);

        return "";
    }

    /// @notice Normalizes a prime token amount to phUSD decimals.
    /// @param primeAmount The amount in prime token decimals.
    /// @return The equivalent amount in phUSD decimals.
    function _normalizeToPhUSD(uint256 primeAmount) internal view returns (uint256) {
        uint8 primeDecimals = IERC20Metadata(_primeToken).decimals();
        uint8 phUSDDecimals = IERC20Metadata(_phUSD).decimals();
        if (primeDecimals == phUSDDecimals) return primeAmount;
        if (primeDecimals < phUSDDecimals) {
            return primeAmount * 10 ** (phUSDDecimals - primeDecimals);
        }
        return primeAmount / 10 ** (primeDecimals - phUSDDecimals);
    }
}
