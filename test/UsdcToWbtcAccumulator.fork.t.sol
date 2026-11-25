// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UsdcToWbtcAccumulator} from "../src/dispatchers/UsdcToWbtcAccumulator.sol";

/// @dev Uniswap V3 QuoterV2 (mainnet 0x61fFE014bA17989E743c5F6cB21bF9697530B21e) single-pool quote.
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @title UsdcToWbtcAccumulator — mainnet fork test against the real USDC/WBTC 0.3% V3 pool
/// @notice Proves a real `buy` through SwapRouter v1 at the QuoterV2 quote minus 50 bp (the D1 default
///         tolerance), that a floor above the live quote reverts in the router, and that the owner
///         EOA's balances never move.
/// @dev RPC wiring follows `UniPoolerV2.fork.t.sol`: `MAINNET_RPC_URL` (or the `.envrc` name
///      `RPC_MAINNET`) must point at an ARCHIVE endpoint because `FORK_BLOCK` is pinned. With neither
///      variable set every test here SKIPS.
contract UsdcToWbtcAccumulatorForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant POOL = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35;
    address internal constant SWAP_ROUTER_V1 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint24 internal constant FEE = 3000;
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    /// @dev Same pinned block as the repo's other fork suites.
    uint256 internal constant FORK_BLOCK = 25_550_000;

    /// @dev ~ one week of index-5 mints at ~$11 each, batched.
    uint256 internal constant USDC_IN = 1_000e6;
    uint256 internal constant TOLERANCE_BPS = 50;

    UsdcToWbtcAccumulator internal acc;
    bool internal forked;

    address internal buyer = address(0xB0B);
    address internal minter = address(0x1111);

    event Bought(address indexed buyer, uint256 usdcIn, uint256 wbtcOut);

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", vm.envOr("RPC_MAINNET", string("")));
        if (bytes(rpc).length == 0) return; // tests skip
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;

        require(POOL.code.length > 0, "pool missing at fork block");
        require(IERC20(USDC).balanceOf(POOL) > 100_000e6, "pool too shallow at fork block");

        acc = new UsdcToWbtcAccumulator(USDC, WBTC, SWAP_ROUTER_V1, FEE, OWNER);
        vm.startPrank(OWNER);
        acc.setMinter(minter);
        acc.setAuthorizedBuyer(buyer, true);
        vm.stopPrank();

        deal(USDC, address(acc), USDC_IN);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _quote(uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = IQuoterV2(QUOTER_V2)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: USDC, tokenOut: WBTC, amountIn: amountIn, fee: FEE, sqrtPriceLimitX96: 0
                })
            );
    }

    function test_fork_buyAtQuoteMinusTolerance_landsWbtcOnAccumulator() public onlyForked {
        uint256 quoted = _quote(USDC_IN);
        assertGt(quoted, 0, "zero quote");
        uint256 minOut = quoted * (10_000 - TOLERANCE_BPS) / 10_000;

        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);
        uint256 ownerWbtc = IERC20(WBTC).balanceOf(OWNER);
        uint256 wbtcBefore = IERC20(WBTC).balanceOf(address(acc));

        vm.recordLogs();
        vm.prank(buyer);
        uint256 out = acc.buy(USDC_IN, minOut, block.timestamp + 10 minutes);

        uint256 delta = IERC20(WBTC).balanceOf(address(acc)) - wbtcBefore;
        assertEq(out, delta, "returned == balance delta");
        assertGe(out, minOut, "floor honoured");
        assertEq(out, quoted, "same-block quote is exact");
        assertEq(IERC20(USDC).balanceOf(address(acc)), 0, "all USDC spent");
        assertEq(IERC20(USDC).allowance(address(acc), SWAP_ROUTER_V1), 0, "allowance reset");

        // Emitted wbtcOut equals the measured delta.
        bytes32 sig = keccak256("Bought(address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(acc) && logs[i].topics[0] == sig) {
                (uint256 usdcIn, uint256 wbtcOut) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(usdcIn, USDC_IN);
                assertEq(wbtcOut, delta, "emitted == balance delta");
                seen = true;
            }
        }
        assertTrue(seen, "Bought not emitted");

        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "owner USDC unchanged");
        assertEq(IERC20(WBTC).balanceOf(OWNER), ownerWbtc, "owner WBTC unchanged");
    }

    function test_fork_floorAboveQuote_reverts() public onlyForked {
        uint256 quoted = _quote(USDC_IN);
        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);
        uint256 ownerWbtc = IERC20(WBTC).balanceOf(OWNER);

        vm.prank(buyer);
        vm.expectRevert(bytes("Too little received"));
        acc.buy(USDC_IN, quoted + 1, block.timestamp + 10 minutes);

        assertEq(IERC20(USDC).balanceOf(address(acc)), USDC_IN, "USDC untouched");
        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "owner USDC unchanged");
        assertEq(IERC20(WBTC).balanceOf(OWNER), ownerWbtc, "owner WBTC unchanged");
    }
}
