// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3SwapRouter} from "../../src/interfaces/uniswap/IUniswapV3SwapRouter.sol";

/// @dev Uniswap V3 SwapRouter (v1) `exactInputSingle` stand-in for unit tests.
///
///      Fidelity points that matter to the accumulator:
///      - `amountIn` of `tokenIn` is pulled from `msg.sender` with `transferFrom`, so a caller that
///        forgets to approve the router reverts exactly as on mainnet.
///      - `deadline` is enforced with the real router's message ("Transaction too old").
///      - `amountOutMinimum` is enforced with the real router's message ("Too little received").
///      - `fee` must equal the configured pool fee (the stand-in for "no such pool").
///      - `tokenOut` is paid to `recipient` from this mock's own balance at `rateNum / rateDen`
///        (units of tokenOut per unit of tokenIn, raw decimals), so the test funds the mock first.
///      - `misreport` makes the returned `amountOut` differ from what was actually paid, to prove
///        the caller measures its output by balance delta rather than trusting the return value.
///      - `shortPay` pays `shortPay` less than the amount checked against `amountOutMinimum` (a
///        router that lies about honouring the floor), to prove the caller re-checks the floor
///        against its own measured balance delta.
contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    uint24 public poolFee;
    uint256 public rateNum;
    uint256 public rateDen;

    bool public misreport;
    uint256 public misreportedAmountOut;

    uint256 public shortPay;

    uint256 public lastAmountIn;
    address public lastRecipient;

    constructor(uint24 poolFee_, uint256 rateNum_, uint256 rateDen_) {
        poolFee = poolFee_;
        rateNum = rateNum_;
        rateDen = rateDen_;
    }

    function setPoolFee(uint24 poolFee_) external {
        poolFee = poolFee_;
    }

    function setRate(uint256 rateNum_, uint256 rateDen_) external {
        rateNum = rateNum_;
        rateDen = rateDen_;
    }

    function setMisreport(bool on, uint256 reportedAmountOut) external {
        misreport = on;
        misreportedAmountOut = reportedAmountOut;
    }

    function setShortPay(uint256 shortPay_) external {
        shortPay = shortPay_;
    }

    /// @notice Quote at the configured rate (what `exactInputSingle` would pay).
    function quote(uint256 amountIn) public view returns (uint256) {
        return amountIn * rateNum / rateDen;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        require(params.fee == poolFee, "MockUniswapV3SwapRouter: no pool for fee");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        amountOut = quote(params.amountIn);
        require(amountOut >= params.amountOutMinimum, "Too little received");

        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut - shortPay);

        lastAmountIn = params.amountIn;
        lastRecipient = params.recipient;

        if (misreport) return misreportedAmountOut;
    }
}
