// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniPoolerCutoverEscrow} from "../src/migration/UniPoolerCutoverEscrow.sol";
import {UniPoolerV2} from "../src/dispatchers/UniPoolerV2.sol";
import {IUniswapV2Pair} from "../src/interfaces/uniswap/IUniswapV2Pair.sol";

/// @dev The admin surface of the old (Balancer-era) pooler the cutover uses.
interface IForkOldPoolerAdmin {
    function owner() external view returns (address);
    function withdrawBPT(address recipient, uint256 amount) external;
}

/// @dev The V3 Vault views and admin entry points this test needs (mainnet Vault proxies the
///      admin calls through to VaultAdmin).
interface IForkV3Vault {
    /// @dev Mirrors the Vault's per-token info struct (token type, rate provider, pays yield fees).
    struct ForkTokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }

    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            address[] memory tokens,
            ForkTokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
    function isPoolInRecoveryMode(address pool) external view returns (bool);
    function isPoolPaused(address pool) external view returns (bool);
    function pausePool(address pool) external;
    function enableRecoveryMode(address pool) external;
}

interface IForkV2Factory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
    function feeTo() external view returns (address);
}

/// @title UniPoolerCutoverEscrow — mainnet fork test
/// @notice Runs the escrow against the live old pooler, the live BPT, the real Balancer V3 Router
///         and Vault, and the real Uniswap V2 factory/Router02 (with the factory's `feeTo` LIVE).
/// @dev **No RPC means FAIL, never skip.** `setUp` reverts when neither `MAINNET_RPC_URL` nor
///      `RPC_MAINNET` is set, so a missing endpoint shows as a failing suite rather than a vacuous
///      pass (the `onlyForked`/`vm.skip` lesson). Every test additionally asserts it is running
///      on chain id 1 at `FORK_BLOCK` with live code at the old pooler. The endpoint must serve
///      archive state for `FORK_BLOCK`.
contract UniPoolerCutoverEscrowForkTest is Test {
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant sUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant phUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address internal constant BPT = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address internal constant V3_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant V3_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address internal constant OLD_POOLER = 0x7f6874332c4629429d70D15f685A8230323F11F1;
    address internal constant OWNER_EOA = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    /// @dev Sole holder (via the Vault's authorizer `0xA331D84eC860Bf466b4CdCcFb4aC09a1B43F3aE6`)
    ///      of the `pausePool` and `enableRecoveryMode` action ids at `FORK_BLOCK`; the pool has
    ///      no pause manager of its own.
    address internal constant V3_GOVERNANCE = 0xA29F61256e948F3FB707b4b3B138C5cCb9EF9888;

    /// @dev A recent block (2026-10): the old pooler still holds its ~20,401.8 BPT, the
    ///      sUSDS/phUSD V2 pair does not exist yet, and the pool is neither paused nor in Recovery.
    uint256 internal constant FORK_BLOCK = 26_136_000;

    /// @dev Exit floors are the live proportional share less 1 bp.
    uint256 internal constant TOL_BPS = 1;

    UniPoolerV2 internal newPooler;
    UniPoolerCutoverEscrow internal escrow;
    address internal pair;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", vm.envOr("RPC_MAINNET", string("")));
        require(
            bytes(rpc).length != 0,
            "UniPoolerCutoverEscrowForkTest: set MAINNET_RPC_URL or RPC_MAINNET (archive endpoint); this suite FAILS without one"
        );
        vm.createSelectFork(rpc, FORK_BLOCK);

        require(IForkV2Factory(UNIV2_FACTORY).getPair(sUSDS, phUSD) == address(0), "pair already exists");
        pair = IForkV2Factory(UNIV2_FACTORY).createPair(sUSDS, phUSD);
        newPooler = new UniPoolerV2(sUSDS, phUSD, UNIV2_ROUTER, pair, address(this));
        escrow = new UniPoolerCutoverEscrow(OWNER_EOA, address(newPooler), OLD_POOLER, V3_ROUTER);
    }

    function _assertForked() internal view {
        assertEq(block.chainid, 1, "not mainnet");
        assertEq(block.number, FORK_BLOCK, "not at FORK_BLOCK");
        assertGt(OLD_POOLER.code.length, 0, "old pooler has no code: fork did not run");
        assertEq(IForkOldPoolerAdmin(OLD_POOLER).owner(), OWNER_EOA, "old pooler owner");
        console2.log("fork chainid", block.chainid);
        console2.log("fork block", block.number);
        console2.log("fork timestamp", block.timestamp);
    }

    function _ownerBalances() internal view returns (uint256[4] memory b) {
        b = [
            IERC20(BPT).balanceOf(OWNER_EOA),
            IERC20(sUSDS).balanceOf(OWNER_EOA),
            IERC20(phUSD).balanceOf(OWNER_EOA),
            IERC20(USDS).balanceOf(OWNER_EOA)
        ];
    }

    /// @dev Pool-order (sUSDS, phUSD) proportional share of `bptIn`: `balanceRaw * bptIn / supply`,
    ///      rounded down — what the Vault pays for proportional and recovery exits of this rate-less
    ///      18-decimal pool.
    function _share(uint256 bptIn) internal view returns (uint256[] memory share) {
        (address[] memory tokens, IForkV3Vault.ForkTokenInfo[] memory info, uint256[] memory balancesRaw,) =
            IForkV3Vault(V3_VAULT).getPoolTokenInfo(BPT);
        assertEq(tokens.length, 2);
        // STANDARD tokens with no rate provider: raw balances are the live balances.
        assertEq(info[0].rateProvider, address(0));
        assertEq(info[1].rateProvider, address(0));
        assertEq(tokens[0], sUSDS, "pool token 0");
        assertEq(tokens[1], phUSD, "pool token 1");
        uint256 supply = IERC20(BPT).totalSupply();
        share = new uint256[](2);
        share[0] = (balancesRaw[0] * bptIn) / supply;
        share[1] = (balancesRaw[1] * bptIn) / supply;
    }

    function _mins(uint256[] memory share) internal pure returns (uint256[] memory mins) {
        mins = new uint256[](2);
        mins[0] = share[0] - (share[0] * TOL_BPS) / 10_000;
        mins[1] = share[1] - (share[1] * TOL_BPS) / 10_000;
    }

    function _withdrawAllToEscrow() internal returns (uint256 bal) {
        bal = IERC20(BPT).balanceOf(OLD_POOLER);
        assertGt(bal, 20_000e18, "old pooler BPT at FORK_BLOCK");
        vm.prank(OWNER_EOA);
        IForkOldPoolerAdmin(OLD_POOLER).withdrawBPT(address(escrow), bal);
        assertEq(IERC20(BPT).balanceOf(address(escrow)), bal);
    }

    function _runAndAssert(UniPoolerCutoverEscrow.ExitMode mode) internal {
        uint256[4] memory ownerBefore = _ownerBalances();
        uint256 bal = _withdrawAllToEscrow();
        uint256[] memory share = _share(bal);
        uint256[] memory mins = _mins(share);

        vm.prank(OWNER_EOA);
        uint256 liquidity = escrow.exitAndSeed(mode, mins, block.timestamp + 1 hours);

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 rS, uint256 rP) =
            IUniswapV2Pair(pair).token0() == sUSDS ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        console2.log("BPT exited", bal);
        console2.log("sUSDS recovered+seeded", rS);
        console2.log("phUSD recovered+seeded", rP);
        console2.log("LP to newPooler", liquidity);

        // Recovered amounts meet the floors and match the live share computed off the Vault.
        assertGe(rS, mins[0]);
        assertGe(rP, mins[1]);
        assertApproxEqAbs(rS, share[0], 2, "sUSDS == live share");
        assertApproxEqAbs(rP, share[1], 2, "phUSD == live share");

        // LP on newPooler. The pair is brand new (kLast == 0), so even with the factory's feeTo
        // live no protocol fee is minted on this first mint; LP == totalSupply - MINIMUM_LIQUIDITY.
        assertTrue(IForkV2Factory(UNIV2_FACTORY).feeTo() != address(0), "feeTo is live at FORK_BLOCK");
        assertGt(liquidity, 0);
        assertEq(IERC20(pair).balanceOf(address(newPooler)), liquidity, "LP on newPooler");
        assertEq(IERC20(pair).totalSupply(), liquidity + 1000, "only MINIMUM_LIQUIDITY besides newPooler");

        // Escrow empty, BPT fully exited, nothing left behind on the old pooler.
        assertEq(IERC20(BPT).balanceOf(address(escrow)), 0, "escrow BPT");
        assertEq(IERC20(sUSDS).balanceOf(address(escrow)), 0, "escrow sUSDS");
        assertEq(IERC20(phUSD).balanceOf(address(escrow)), 0, "escrow phUSD");
        assertEq(IERC20(USDS).balanceOf(address(escrow)), 0, "escrow USDS");
        assertEq(IERC20(BPT).balanceOf(OLD_POOLER), 0, "old pooler BPT");
        assertEq(IERC20(BPT).allowance(address(escrow), V3_ROUTER), 0, "no BPT allowance survives");
        assertEq(IERC20(sUSDS).allowance(address(escrow), UNIV2_ROUTER), 0, "no sUSDS allowance survives");
        assertEq(IERC20(phUSD).allowance(address(escrow), UNIV2_ROUTER), 0, "no phUSD allowance survives");

        // The owner EOA never held any of it.
        uint256[4] memory ownerAfter = _ownerBalances();
        assertEq(ownerAfter[0], ownerBefore[0], "owner BPT changed");
        assertEq(ownerAfter[1], ownerBefore[1], "owner sUSDS changed");
        assertEq(ownerAfter[2], ownerBefore[2], "owner phUSD changed");
        assertEq(ownerAfter[3], ownerBefore[3], "owner USDS changed");

        // The seeded pair is usable by the new pooler's view maths.
        (,, uint256 expectedLP) = newPooler.quotePool(1_000e18);
        assertGt(expectedLP, 0);
    }

    /// @notice Case 1: the normal proportional exit.
    function test_fork_case1_proportionalExitSeedsNewPooler() public {
        _assertForked();
        assertFalse(IForkV3Vault(V3_VAULT).isPoolPaused(BPT));
        assertFalse(IForkV3Vault(V3_VAULT).isPoolInRecoveryMode(BPT));
        _runAndAssert(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);
    }

    /// @notice Case 2: the pool is paused by Balancer governance and put into Recovery Mode. The
    ///         proportional exit then reverts on the real Vault and the recovery exit succeeds.
    function test_fork_case2_pausedPoolRecoveryExitSeedsNewPooler() public {
        _assertForked();
        vm.prank(V3_GOVERNANCE);
        IForkV3Vault(V3_VAULT).pausePool(BPT);
        assertTrue(IForkV3Vault(V3_VAULT).isPoolPaused(BPT), "pool paused");
        // Permissionless once the pool is paused.
        vm.prank(address(0xA11CE));
        IForkV3Vault(V3_VAULT).enableRecoveryMode(BPT);
        assertTrue(IForkV3Vault(V3_VAULT).isPoolInRecoveryMode(BPT), "recovery mode");

        uint256 bal = _withdrawAllToEscrow();
        uint256[] memory mins = _mins(_share(bal));
        vm.prank(OWNER_EOA);
        vm.expectRevert(abi.encodeWithSignature("PoolPaused(address)", BPT));
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);

        // Return the BPT to the old pooler (abort) and re-run from scratch through recovery, so
        // `_runAndAssert` starts from the same state as case 1.
        vm.prank(OWNER_EOA);
        escrow.abort();
        assertEq(IERC20(BPT).balanceOf(OLD_POOLER), bal, "abort returned BPT to old pooler");
        _runAndAssert(UniPoolerCutoverEscrow.ExitMode.RECOVERY);
    }

    /// @notice Without an approval the real V3 Router cannot burn the BPT: the escrow's exact
    ///         approve is load-bearing on mainnet, not just in the mock.
    function test_fork_realRouterNeedsRouterAllowance() public {
        _assertForked();
        uint256 amt = 1e18;
        vm.prank(OWNER_EOA);
        IForkOldPoolerAdmin(OLD_POOLER).withdrawBPT(address(this), amt);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", V3_ROUTER, 0, amt)
        );
        IV3RouterExitFork(V3_ROUTER).removeLiquidityProportional(BPT, amt, mins, false, "");
    }

    /// @notice abort on mainnet: the BPT goes back to the old pooler and nowhere else.
    function test_fork_abortReturnsToOldPooler() public {
        _assertForked();
        uint256[4] memory ownerBefore = _ownerBalances();
        uint256 bal = _withdrawAllToEscrow();
        vm.prank(OWNER_EOA);
        escrow.abort();
        assertEq(IERC20(BPT).balanceOf(OLD_POOLER), bal);
        assertEq(IERC20(BPT).balanceOf(address(escrow)), 0);
        uint256[4] memory ownerAfter = _ownerBalances();
        assertEq(ownerAfter[0], ownerBefore[0]);
    }
}

interface IV3RouterExitFork {
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);
}
