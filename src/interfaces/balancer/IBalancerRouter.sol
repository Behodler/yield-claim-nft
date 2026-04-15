// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBalancerRouter {
    function queryAddLiquidityUnbalanced(
        address pool,
        uint256[] memory exactAmountsIn,
        address sender,
        bytes memory userData
    ) external returns (uint256 bptAmountOut);
}
