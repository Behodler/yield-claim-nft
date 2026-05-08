// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddLiquidityParams, VaultSwapParams} from "./BalancerTypes.sol";

interface IBalancerVault {
    function unlock(bytes calldata data) external returns (bytes memory result);
    function addLiquidity(AddLiquidityParams memory params)
        external
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData);
    function swap(VaultSwapParams memory params)
        external
        returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw);
    function settle(IERC20 token, uint256 amountHint) external returns (uint256 credit);
    function sendTo(IERC20 token, address to, uint256 amount) external;
}
