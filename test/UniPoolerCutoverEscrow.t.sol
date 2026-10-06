// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {UniPoolerCutoverEscrow} from "../src/migration/UniPoolerCutoverEscrow.sol";
import {UniPoolerV2} from "../src/dispatchers/UniPoolerV2.sol";
import {MockUniV2AmmPair, MockUniV2AmmRouter} from "./mocks/MockUniV2Amm.sol";
import {MockV3ExitRouter} from "./mocks/MockV3ExitRouter.sol";

/// @dev 18-decimal ERC20 that records every transfer OUT of one watched address (the escrow), so
///      tests can prove where escrow funds went. `mint` is open; `burn` burns the caller's own
///      balance (the BPT instance is burned by the exit mock after it pulls the tokens).
contract TrackedToken is ERC20 {
    address public watched;
    address[] internal _outTo;
    uint256[] internal _outAmount;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function watch(address account) external {
        watched = account;
    }

    function outflowCount() external view returns (uint256) {
        return _outTo.length;
    }

    function outflow(uint256 i) external view returns (address to, uint256 amount) {
        return (_outTo[i], _outAmount[i]);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == watched && from != address(0) && value != 0) {
            _outTo.push(to);
            _outAmount.push(value);
        }
        super._update(from, to, value);
    }
}

/// @dev sUSDS stand-in: a tracked ERC4626-ish vault over `asset` at a 1 share : 1.05 asset rate.
contract TrackedVault is TrackedToken {
    address public immutable asset;

    constructor(address asset_) TrackedToken("Savings USDS", "sUSDS") {
        asset = asset_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * 100) / 105;
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }
}

/// @dev Stand-in for the Balancer-era pooler: the three getters the escrow reads, a mutable
///      `pool` (as on mainnet), and the owner-only `withdrawBPT` the cutover uses.
contract MockLegacyPooler {
    address public pool;
    address public primeToken;
    address public sUSDS;
    address public owner;

    constructor(address pool_, address primeToken_, address sUSDS_, address owner_) {
        pool = pool_;
        primeToken = primeToken_;
        sUSDS = sUSDS_;
        owner = owner_;
    }

    function setPool(address newPool) external {
        require(msg.sender == owner, "not owner");
        pool = newPool;
    }

    function withdrawBPT(address recipient, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        IERC20(pool).transfer(recipient, amount);
    }
}

/// @dev Shared deployment: tracked USDS/sUSDS/phUSD/BPT, the faithful UniV2 pair+router, a real
///      UniPoolerV2 on the empty pair, the V3 exit mock holding the pool, the legacy pooler
///      holding 20k of 32k BPT, and the escrow under test (watched by all four tokens).
abstract contract EscrowFixture is Test {
    uint256 internal constant POOL_SUSDS = 29_663e18;
    uint256 internal constant POOL_PHUSD = 35_705e18;
    uint256 internal constant BPT_SUPPLY = 32_438e18;
    uint256 internal constant OLD_POOLER_BPT = 20_401e18;

    address internal constant OPERATOR = address(0xCAD1);
    address internal constant STRANGER = address(0xBAD);
    address internal constant OTHER_LP = address(0x1111);

    TrackedToken internal usds;
    TrackedVault internal sUsds;
    TrackedToken internal phusd;
    TrackedToken internal bpt;
    MockUniV2AmmPair internal pair;
    MockUniV2AmmRouter internal uniRouter;
    UniPoolerV2 internal newPooler;
    MockV3ExitRouter internal v3;
    MockLegacyPooler internal oldPooler;
    UniPoolerCutoverEscrow internal escrow;

    function _deployFixture() internal {
        usds = new TrackedToken("USDS", "USDS");
        sUsds = new TrackedVault(address(usds));
        phusd = new TrackedToken("Phoenix USD", "phUSD");
        bpt = new TrackedToken("Pool Token", "BPT");

        pair = new MockUniV2AmmPair(address(sUsds), address(phusd));
        uniRouter = new MockUniV2AmmRouter(pair);
        newPooler = new UniPoolerV2(address(sUsds), address(phusd), address(uniRouter), address(pair), address(this));

        address[] memory tokens = new address[](2);
        tokens[0] = address(sUsds); // mainnet pool order: sUSDS, phUSD
        tokens[1] = address(phusd);
        v3 = new MockV3ExitRouter(address(bpt), tokens);
        sUsds.mint(address(v3), POOL_SUSDS);
        phusd.mint(address(v3), POOL_PHUSD);

        oldPooler = new MockLegacyPooler(address(bpt), address(usds), address(sUsds), OPERATOR);
        bpt.mint(address(oldPooler), OLD_POOLER_BPT);
        bpt.mint(OTHER_LP, BPT_SUPPLY - OLD_POOLER_BPT);

        escrow = new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(oldPooler), address(v3));
        usds.watch(address(escrow));
        sUsds.watch(address(escrow));
        phusd.watch(address(escrow));
        bpt.watch(address(escrow));
    }

    function _withdrawAllToEscrow() internal returns (uint256 amount) {
        amount = bpt.balanceOf(address(oldPooler));
        vm.prank(OPERATOR);
        oldPooler.withdrawBPT(address(escrow), amount);
    }

    /// @dev Live proportional share for the escrow's BPT, less `tolBps`, floored at 1.
    function _mins(uint256 tolBps) internal view returns (uint256[] memory mins) {
        mins = v3.previewExit(bpt.balanceOf(address(escrow)));
        for (uint256 i = 0; i < mins.length; i++) {
            mins[i] = mins[i] - (mins[i] * tolBps) / 10_000;
            if (mins[i] == 0) mins[i] = 1;
        }
    }

    function _reservesSP() internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rS, rP) = pair.token0() == address(sUsds) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _isAllowedOutflow(address token, address to) internal view returns (bool) {
        if (to == address(oldPooler)) return true;
        if (token == address(bpt)) return to == address(v3); // pulled by the router, then burned
        if (token == address(sUsds) || token == address(phusd)) return to == address(pair); // seed
        if (token == address(usds)) return to == address(sUsds); // ERC4626 deposit, shares -> newPooler
        return false;
    }

    /// @dev Every transfer ever made OUT of the escrow, for all four tokens, went to an allowed
    ///      protocol destination.
    function _assertAllOutflowsAllowed() internal view {
        TrackedToken[4] memory ts = [bpt, TrackedToken(address(sUsds)), phusd, usds];
        for (uint256 t = 0; t < 4; t++) {
            uint256 n = ts[t].outflowCount();
            for (uint256 i = 0; i < n; i++) {
                (address to,) = ts[t].outflow(i);
                assertTrue(_isAllowedOutflow(address(ts[t]), to), "escrow paid a non-protocol address");
            }
        }
    }

    function _assertNoAllowances() internal view {
        assertEq(bpt.allowance(address(escrow), address(v3)), 0, "BPT allowance to V3 router");
        assertEq(sUsds.allowance(address(escrow), address(uniRouter)), 0, "sUSDS allowance to Router02");
        assertEq(phusd.allowance(address(escrow), address(uniRouter)), 0, "phUSD allowance to Router02");
        assertEq(usds.allowance(address(escrow), address(sUsds)), 0, "USDS allowance to sUSDS");
    }
}

/// @title UniPoolerCutoverEscrow unit tests
/// @notice Against a real UniPoolerV2, the faithful-maths UniV2 pair/router mocks and the V3 exit
///         mock (which burns BPT via the ROUTER's allowance, so a missing approve fails here as on
///         mainnet). Every token records transfers out of the escrow, so each test can assert that
///         funds only ever went to protocol contracts.
contract UniPoolerCutoverEscrowTest is EscrowFixture {
    function setUp() public {
        _deployFixture();
    }

    function _seed(UniPoolerCutoverEscrow.ExitMode mode) internal returns (uint256 liquidity) {
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        liquidity = escrow.exitAndSeed(mode, mins, block.timestamp + 1 hours);
    }

    function _operatorBalances() internal view returns (uint256[4] memory b) {
        b = [bpt.balanceOf(OPERATOR), sUsds.balanceOf(OPERATOR), phusd.balanceOf(OPERATOR), usds.balanceOf(OPERATOR)];
    }

    // ─────────────────────────────── Mock fidelity ───────────────────────────────

    /// @dev The fixture is not permissive: an exit with no approval to the router reverts with
    ///      the router as the spender, as on mainnet.
    function test_mock_exitWithoutRouterApprovalReverts() public {
        uint256 amt = 1_000e18;
        vm.prank(OTHER_LP);
        bpt.approve(address(0x1234), amt); // approving someone else does not help
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.prank(OTHER_LP);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(v3), 0, amt));
        v3.removeLiquidityProportional(address(bpt), amt, mins, false, "");
    }

    function test_mock_exitPaysProRataAndBurns() public {
        uint256 amt = 1_000e18;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.startPrank(OTHER_LP);
        bpt.approve(address(v3), amt);
        v3.removeLiquidityProportional(address(bpt), amt, mins, false, "");
        vm.stopPrank();
        assertEq(sUsds.balanceOf(OTHER_LP), (POOL_SUSDS * amt) / BPT_SUPPLY);
        assertEq(phusd.balanceOf(OTHER_LP), (POOL_PHUSD * amt) / BPT_SUPPLY);
        assertEq(bpt.totalSupply(), BPT_SUPPLY - amt, "burned");
    }

    // ─────────────────────────────── Constructor ───────────────────────────────

    function test_constructor_readsImmutablesFromPoolers() public view {
        assertEq(escrow.operator(), OPERATOR);
        assertEq(escrow.newPooler(), address(newPooler));
        assertEq(escrow.oldPooler(), address(oldPooler));
        assertEq(escrow.v3Router(), address(v3));
        assertEq(escrow.bpt(), address(bpt));
        assertEq(escrow.usds(), address(usds));
        assertEq(escrow.sUSDS(), address(sUsds));
        assertEq(escrow.phUSD(), address(phusd));
        assertEq(escrow.pair(), address(pair));
        assertEq(escrow.uniRouter(), address(uniRouter));
        assertEq(escrow.MAX_DEADLINE_WINDOW(), 1 days);
    }

    function test_constructor_snapshotsPoolAgainstLaterSetPool() public {
        vm.prank(OPERATOR);
        oldPooler.setPool(address(0xDEAD));
        assertEq(escrow.bpt(), address(bpt), "BPT snapshotted at construction");
    }

    function test_constructor_rejectsZeroOperator() public {
        vm.expectRevert("UniPoolerCutoverEscrow: zero operator");
        new UniPoolerCutoverEscrow(address(0), address(newPooler), address(oldPooler), address(v3));
    }

    function test_constructor_rejectsZeroNewPooler() public {
        vm.expectRevert("UniPoolerCutoverEscrow: zero newPooler");
        new UniPoolerCutoverEscrow(OPERATOR, address(0), address(oldPooler), address(v3));
    }

    function test_constructor_rejectsZeroOldPooler() public {
        vm.expectRevert("UniPoolerCutoverEscrow: zero oldPooler");
        new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(0), address(v3));
    }

    function test_constructor_rejectsZeroV3Router() public {
        vm.expectRevert("UniPoolerCutoverEscrow: zero v3Router");
        new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(oldPooler), address(0));
    }

    function test_constructor_rejectsZeroPoolOnOldPooler() public {
        MockLegacyPooler bad = new MockLegacyPooler(address(0), address(usds), address(sUsds), OPERATOR);
        vm.expectRevert("UniPoolerCutoverEscrow: zero pool");
        new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(bad), address(v3));
    }

    function test_constructor_rejectsSUSDSMismatchBetweenPoolers() public {
        TrackedVault otherVault = new TrackedVault(address(usds));
        MockLegacyPooler bad = new MockLegacyPooler(address(bpt), address(usds), address(otherVault), OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__SUSDSMismatch.selector,
                address(otherVault),
                address(sUsds)
            )
        );
        new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(bad), address(v3));
    }

    function test_constructor_rejectsPrimeTokenNotSUSDSAsset() public {
        MockLegacyPooler bad = new MockLegacyPooler(address(bpt), address(phusd), address(sUsds), OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__UsdsMismatch.selector, address(phusd), address(usds)
            )
        );
        new UniPoolerCutoverEscrow(OPERATOR, address(newPooler), address(bad), address(v3));
    }

    // ─────────────────────────────── Access ───────────────────────────────

    function testFuzz_access_nonOperatorReverts(address caller) public {
        vm.assume(caller != OPERATOR);
        _withdrawAllToEscrow();
        usds.mint(address(escrow), 1e18);
        uint256[] memory mins = _mins(1);
        bytes memory err =
            abi.encodeWithSelector(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__NotOperator.selector, caller);

        vm.prank(caller);
        vm.expectRevert(err);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);

        vm.prank(caller);
        vm.expectRevert(err);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.RECOVERY, mins, block.timestamp + 1 hours);

        vm.prank(caller);
        vm.expectRevert(err);
        escrow.wrapUsds();

        vm.prank(caller);
        vm.expectRevert(err);
        escrow.abort();
    }

    function test_access_noOwnerSurfaceAndNoEthEntry() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", STRANGER),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("acceptOwnership()"),
            abi.encodeWithSignature("setOperator(address)", STRANGER)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(OPERATOR);
            (bool ok,) = address(escrow).call(calls[i]);
            assertFalse(ok, "unexpected admin surface");
        }
        vm.deal(OPERATOR, 1 ether);
        vm.prank(OPERATOR);
        (bool sent,) = address(escrow).call{value: 1 ether}("");
        assertFalse(sent, "escrow accepted ETH");
    }

    // ─────────────────────────────── exitAndSeed happy paths ───────────────────────────────

    function _assertHappy(UniPoolerCutoverEscrow.ExitMode mode) internal {
        uint256 bptIn = _withdrawAllToEscrow();
        uint256[] memory expected = v3.previewExit(bptIn);
        uint256[4] memory opBefore = _operatorBalances();
        uint256 supplyBefore = bpt.totalSupply();

        vm.expectEmit(address(escrow));
        emit UniPoolerCutoverEscrow.Seeded(
            bptIn, expected[0], expected[1], _sqrt(expected[0] * expected[1]) - 1000, mode
        );
        uint256 liquidity = _seed(mode);

        assertEq(bpt.totalSupply(), supplyBefore - bptIn, "all escrow BPT burned");
        assertEq(liquidity, _sqrt(expected[0] * expected[1]) - 1000, "first-mint LP");
        assertEq(pair.balanceOf(address(newPooler)), liquidity, "LP minted to newPooler");
        (uint256 rS, uint256 rP) = _reservesSP();
        assertEq(rS, expected[0], "sUSDS reserve == recovered");
        assertEq(rP, expected[1], "phUSD reserve == recovered");

        assertEq(bpt.balanceOf(address(escrow)), 0);
        assertEq(sUsds.balanceOf(address(escrow)), 0);
        assertEq(phusd.balanceOf(address(escrow)), 0);
        assertEq(usds.balanceOf(address(escrow)), 0);

        uint256[4] memory opAfter = _operatorBalances();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(opAfter[i], opBefore[i], "operator balance changed");
        }
        _assertNoAllowances();
        _assertAllOutflowsAllowed();
    }

    function test_exitAndSeed_proportional() public {
        _assertHappy(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);
        assertEq(v3.proportionalCalls(), 1);
        assertEq(v3.recoveryCalls(), 0);
    }

    function test_exitAndSeed_recovery() public {
        v3.setRecoveryMode(true);
        _assertHappy(UniPoolerCutoverEscrow.ExitMode.RECOVERY);
        assertEq(v3.proportionalCalls(), 0);
        assertEq(v3.recoveryCalls(), 1);
    }

    function test_exitAndSeed_pausedPool_proportionalRevertsRecoverySucceeds() public {
        v3.setPaused(true);
        v3.setRecoveryMode(true);
        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(MockV3ExitRouter.MockV3ExitRouter__PoolPaused.selector, address(bpt)));
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);

        _seed(UniPoolerCutoverEscrow.ExitMode.RECOVERY);
        assertGt(pair.balanceOf(address(newPooler)), 0, "recovery seeded");
        assertEq(bpt.balanceOf(address(escrow)), 0);
    }

    function test_exitAndSeed_recoveryRevertsOutsideRecoveryMode() public {
        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(MockV3ExitRouter.MockV3ExitRouter__NotInRecoveryMode.selector, address(bpt))
        );
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.RECOVERY, mins, block.timestamp + 1 hours);
    }

    /// @dev The owner's pre-existing BPT (202.30 on mainnet) transferred in explicitly is exited too.
    function test_exitAndSeed_includesBptTransferredInByOperator() public {
        _withdrawAllToEscrow();
        vm.prank(OTHER_LP);
        bpt.transfer(OPERATOR, 202.3e18);
        vm.prank(OPERATOR);
        bpt.transfer(address(escrow), 202.3e18);
        uint256 bptIn = bpt.balanceOf(address(escrow));
        assertEq(bptIn, OLD_POOLER_BPT + 202.3e18);
        uint256[] memory expected = v3.previewExit(bptIn);
        _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);
        (uint256 rS, uint256 rP) = _reservesSP();
        assertEq(rS, expected[0]);
        assertEq(rP, expected[1]);
        assertEq(bpt.balanceOf(address(escrow)), 0);
    }

    function test_exitAndSeed_isOneShot() public {
        _withdrawAllToEscrow();
        _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);
        vm.prank(OTHER_LP);
        bpt.transfer(address(escrow), 100e18);
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        vm.expectPartialRevert(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__PairNotEmpty.selector);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
    }

    function test_exitAndSeed_deadlineExactlyOneDayAheadAccepted() public {
        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 days);
        assertGt(pair.balanceOf(address(newPooler)), 0);
    }

    // ─────────────────────────────── exitAndSeed reverts ───────────────────────────────

    function test_exitAndSeed_revertsOnZeroBpt() public {
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.prank(OPERATOR);
        vm.expectRevert(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__NoBPT.selector);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
    }

    function test_exitAndSeed_revertsOnZeroMinAmountOut() public {
        _withdrawAllToEscrow();
        for (uint256 i = 0; i < 2; i++) {
            uint256[] memory mins = _mins(1);
            mins[i] = 0;
            vm.prank(OPERATOR);
            vm.expectRevert(
                abi.encodeWithSelector(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__ZeroMinAmountOut.selector, i)
            );
            escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
        }
    }

    function test_exitAndSeed_revertsOnWrongLength() public {
        _withdrawAllToEscrow();
        uint256[3] memory lens = [uint256(0), 1, 3];
        for (uint256 k = 0; k < 3; k++) {
            uint256[] memory mins = new uint256[](lens[k]);
            for (uint256 i = 0; i < lens[k]; i++) {
                mins[i] = 1;
            }
            vm.prank(OPERATOR);
            vm.expectRevert(
                abi.encodeWithSelector(
                    UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__BadMinAmountsLength.selector, lens[k]
                )
            );
            escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
        }
    }

    function test_exitAndSeed_revertsOnBadDeadline() public {
        vm.warp(1_800_000_000);
        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        uint256[3] memory bad = [block.timestamp - 1, block.timestamp, block.timestamp + 1 days + 1];
        for (uint256 k = 0; k < 3; k++) {
            vm.prank(OPERATOR);
            vm.expectRevert(
                abi.encodeWithSelector(
                    UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__BadDeadline.selector, bad[k], block.timestamp
                )
            );
            escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, bad[k]);
        }
    }

    function test_exitAndSeed_revertsOnNonEmptyPairReserves() public {
        // Someone seeds the pair first (a synced position with reserves).
        sUsds.mint(STRANGER, 10e18);
        phusd.mint(STRANGER, 10e18);
        vm.startPrank(STRANGER);
        sUsds.approve(address(uniRouter), 10e18);
        phusd.approve(address(uniRouter), 10e18);
        uniRouter.addLiquidity(address(sUsds), address(phusd), 10e18, 10e18, 0, 0, STRANGER, block.timestamp);
        vm.stopPrank();

        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__PairNotEmpty.selector, 10e18, 10e18, 10e18, 10e18
            )
        );
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
    }

    function test_exitAndSeed_revertsWhenMinAmountsOutNotMet() public {
        uint256 bptIn = _withdrawAllToEscrow();
        uint256[] memory expected = v3.previewExit(bptIn);
        for (uint256 i = 0; i < 2; i++) {
            uint256[] memory mins = v3.previewExit(bptIn);
            mins[i] = expected[i] + 1;
            address token = i == 0 ? address(sUsds) : address(phusd);
            vm.prank(OPERATOR);
            vm.expectRevert(
                abi.encodeWithSelector(
                    MockV3ExitRouter.MockV3ExitRouter__AmountOutBelowMin.selector, token, expected[i], expected[i] + 1
                )
            );
            escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
        }
        // Exact share passes.
        vm.prank(OPERATOR);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, expected, block.timestamp + 1 hours);
    }

    // ─────────────────────────────── Pair donations ───────────────────────────────

    function test_unsyncedDonation_skimmedToNewPoolerNotCaller() public {
        sUsds.mint(STRANGER, 100e18);
        phusd.mint(STRANGER, 50e18);
        vm.startPrank(STRANGER);
        sUsds.transfer(address(pair), 100e18);
        phusd.transfer(address(pair), 50e18);
        vm.stopPrank();

        uint256 bptIn = _withdrawAllToEscrow();
        uint256[] memory expected = v3.previewExit(bptIn);
        uint256[4] memory opBefore = _operatorBalances();

        (address t0,) = (pair.token0(), pair.token1());
        (uint256 d0, uint256 d1) = t0 == address(sUsds) ? (100e18, 50e18) : (50e18, 100e18);
        vm.expectEmit(address(escrow));
        emit UniPoolerCutoverEscrow.PairSkimmed(address(newPooler), d0, d1);
        _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);

        assertEq(sUsds.balanceOf(address(newPooler)), 100e18, "sUSDS donation skimmed to newPooler");
        assertEq(phusd.balanceOf(address(newPooler)), 50e18, "phUSD donation skimmed to newPooler");
        uint256[4] memory opAfter = _operatorBalances();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(opAfter[i], opBefore[i], "operator received skim");
        }
        assertEq(sUsds.balanceOf(OPERATOR), 0);
        (uint256 rS, uint256 rP) = _reservesSP();
        assertEq(rS, expected[0], "reserves exclude the skimmed donation");
        assertEq(rP, expected[1]);
        assertEq(pair.balanceOf(address(newPooler)), _sqrt(expected[0] * expected[1]) - 1000);
    }

    function test_unsyncedSingleSidedDonation_skimmedToNewPooler() public {
        phusd.mint(address(pair), 7e18);
        _withdrawAllToEscrow();
        _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);
        assertEq(phusd.balanceOf(address(newPooler)), 7e18);
        assertEq(phusd.balanceOf(OPERATOR), 0);
    }

    function test_syncedDonation_reverts() public {
        sUsds.mint(address(pair), 100e18);
        phusd.mint(address(pair), 50e18);
        pair.sync();
        _withdrawAllToEscrow();
        uint256[] memory mins = _mins(1);
        vm.prank(OPERATOR);
        vm.expectPartialRevert(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__PairNotEmpty.selector);
        escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1 hours);
    }

    // ─────────────────────────────── Stray tokens ───────────────────────────────

    function test_strayTokensOnEscrow_sweptIntoSeed() public {
        sUsds.mint(STRANGER, 10e18);
        phusd.mint(STRANGER, 7e18);
        vm.startPrank(STRANGER);
        sUsds.transfer(address(escrow), 10e18);
        phusd.transfer(address(escrow), 7e18);
        vm.stopPrank();

        uint256 bptIn = _withdrawAllToEscrow();
        uint256[] memory expected = v3.previewExit(bptIn);
        uint256 liquidity = _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);

        (uint256 rS, uint256 rP) = _reservesSP();
        assertEq(rS, expected[0] + 10e18, "stray sUSDS seeded");
        assertEq(rP, expected[1] + 7e18, "stray phUSD seeded");
        assertEq(liquidity, _sqrt(rS * rP) - 1000);
        assertEq(sUsds.balanceOf(address(escrow)), 0);
        assertEq(phusd.balanceOf(address(escrow)), 0);
    }

    // ─────────────────────────────── wrapUsds ───────────────────────────────

    function test_wrapUsds_depositsToNewPooler() public {
        usds.mint(address(escrow), 1_050e18);
        uint256 before = sUsds.balanceOf(address(newPooler));
        vm.expectEmit(address(escrow));
        emit UniPoolerCutoverEscrow.UsdsWrapped(1_050e18, 1_000e18);
        vm.prank(OPERATOR);
        uint256 shares = escrow.wrapUsds();
        assertEq(shares, 1_000e18);
        assertEq(sUsds.balanceOf(address(newPooler)) - before, 1_000e18, "shares credited to newPooler");
        assertEq(usds.balanceOf(address(escrow)), 0);
        assertEq(sUsds.balanceOf(address(escrow)), 0);
        assertEq(sUsds.balanceOf(OPERATOR), 0);
        assertEq(usds.balanceOf(address(sUsds)), 1_050e18);
        _assertNoAllowances();
        _assertAllOutflowsAllowed();
    }

    function test_wrapUsds_revertsWithNoUsds() public {
        vm.prank(OPERATOR);
        vm.expectRevert(UniPoolerCutoverEscrow.UniPoolerCutoverEscrow__NoUSDS.selector);
        escrow.wrapUsds();
    }

    // ─────────────────────────────── abort ───────────────────────────────

    function test_abort_returnsAllFourTokensToOldPoolerOnly() public {
        uint256 bptAmt = _withdrawAllToEscrow();
        sUsds.mint(address(escrow), 3e18);
        phusd.mint(address(escrow), 4e18);
        usds.mint(address(escrow), 5e18);
        uint256[4] memory opBefore = _operatorBalances();

        vm.expectEmit(address(escrow));
        emit UniPoolerCutoverEscrow.Aborted(address(oldPooler), bptAmt, 3e18, 4e18, 5e18);
        vm.prank(OPERATOR);
        escrow.abort();

        assertEq(bpt.balanceOf(address(oldPooler)), bptAmt);
        assertEq(sUsds.balanceOf(address(oldPooler)), 3e18);
        assertEq(phusd.balanceOf(address(oldPooler)), 4e18);
        assertEq(usds.balanceOf(address(oldPooler)), 5e18);
        assertEq(bpt.balanceOf(address(escrow)), 0);
        assertEq(sUsds.balanceOf(address(escrow)), 0);
        assertEq(phusd.balanceOf(address(escrow)), 0);
        assertEq(usds.balanceOf(address(escrow)), 0);
        uint256[4] memory opAfter = _operatorBalances();
        for (uint256 i = 0; i < 4; i++) {
            assertEq(opAfter[i], opBefore[i]);
        }
        TrackedToken[4] memory ts = [bpt, TrackedToken(address(sUsds)), phusd, usds];
        for (uint256 t = 0; t < 4; t++) {
            assertEq(ts[t].outflowCount(), 1);
            (address to,) = ts[t].outflow(0);
            assertEq(to, address(oldPooler), "abort paid someone other than oldPooler");
        }
    }

    function test_abort_withNothingHeldIsANoOp() public {
        vm.prank(OPERATOR);
        escrow.abort();
        assertEq(bpt.outflowCount() + phusd.outflowCount() + usds.outflowCount() + sUsds.outflowCount(), 0);
    }

    // ─────────────────────────────── Fuzz ───────────────────────────────

    /// @dev Any BPT amount, stray balances and unsynced pair donations: the seed always consumes
    ///      the escrow's whole balances, LP lands on newPooler, the operator receives nothing.
    function testFuzz_exitAndSeed_wholeBalanceSeed(
        uint256 bptAmt,
        uint96 straySUSDS,
        uint96 strayPhUSD,
        uint96 donS,
        uint96 donP
    ) public {
        bptAmt = bound(bptAmt, 1e15, OLD_POOLER_BPT);
        vm.prank(OPERATOR);
        oldPooler.withdrawBPT(address(escrow), bptAmt);
        sUsds.mint(address(escrow), straySUSDS);
        phusd.mint(address(escrow), strayPhUSD);
        sUsds.mint(address(pair), donS);
        phusd.mint(address(pair), donP);

        uint256[] memory expected = v3.previewExit(bptAmt);
        _seed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL);

        (uint256 rS, uint256 rP) = _reservesSP();
        assertEq(rS, expected[0] + straySUSDS);
        assertEq(rP, expected[1] + strayPhUSD);
        assertEq(sUsds.balanceOf(address(newPooler)), donS);
        assertEq(phusd.balanceOf(address(newPooler)), donP);
        assertEq(pair.balanceOf(address(newPooler)), _sqrt(rS * rP) - 1000);
        assertEq(sUsds.balanceOf(OPERATOR) + phusd.balanceOf(OPERATOR) + bpt.balanceOf(OPERATOR), 0);
        assertEq(sUsds.balanceOf(address(escrow)) + phusd.balanceOf(address(escrow)), 0);
        _assertAllOutflowsAllowed();
        _assertNoAllowances();
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

/// @dev Drives random sequences of operator and stranger actions against the escrow. Operator
///      calls may legitimately revert (wrong state); stranger calls must always revert.
contract EscrowHandler is Test {
    UniPoolerCutoverEscrow internal immutable escrow;
    MockLegacyPooler internal immutable oldPooler;
    MockV3ExitRouter internal immutable v3;
    MockUniV2AmmPair internal immutable pair;
    TrackedToken internal immutable bpt;
    TrackedToken internal immutable sUsds;
    TrackedToken internal immutable phusd;
    TrackedToken internal immutable usds;
    address internal immutable operator;

    uint256 public strangerSucceeded;
    uint256 public seeds;

    constructor(
        UniPoolerCutoverEscrow escrow_,
        MockLegacyPooler oldPooler_,
        MockV3ExitRouter v3_,
        MockUniV2AmmPair pair_,
        TrackedToken[4] memory tokens,
        address operator_
    ) {
        escrow = escrow_;
        oldPooler = oldPooler_;
        v3 = v3_;
        pair = pair_;
        bpt = tokens[0];
        sUsds = tokens[1];
        phusd = tokens[2];
        usds = tokens[3];
        operator = operator_;
    }

    function withdrawBpt(uint256 amount) external {
        uint256 bal = bpt.balanceOf(address(oldPooler));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(operator);
        oldPooler.withdrawBPT(address(escrow), amount);
    }

    function donateToEscrow(uint8 which, uint96 amount) external {
        TrackedToken[4] memory ts = [bpt, sUsds, phusd, usds];
        TrackedToken t = ts[which % 4];
        if (t == bpt) return; // BPT supply is backed by the mock pool; route BPT via withdrawBpt only
        t.mint(address(escrow), amount);
    }

    function donateToPair(bool sSide, uint96 amount, bool doSync) external {
        (sSide ? sUsds : phusd).mint(address(pair), amount);
        if (doSync) pair.sync();
    }

    function rescueUsdsToEscrow(uint96 amount) external {
        usds.mint(address(escrow), amount);
    }

    function setPoolFlags(bool paused, bool recovery) external {
        v3.setPaused(paused);
        v3.setRecoveryMode(recovery);
    }

    function exitAndSeed(bool recovery, uint16 tolBps, uint32 deadlineOffset, bool zeroMin) external {
        uint256 bal = bpt.balanceOf(address(escrow));
        uint256[] memory mins = new uint256[](2);
        if (bal > 0) mins = v3.previewExit(bal);
        for (uint256 i = 0; i < 2; i++) {
            mins[i] = mins[i] - (mins[i] * (tolBps % 10_001)) / 10_000;
            if (mins[i] == 0 && !zeroMin) mins[i] = 1;
        }
        uint256 deadline = block.timestamp + (deadlineOffset % (2 days));
        vm.prank(operator);
        try escrow.exitAndSeed(
            recovery ? UniPoolerCutoverEscrow.ExitMode.RECOVERY : UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL,
            mins,
            deadline
        ) {
            seeds++;
        } catch {}
    }

    function wrapUsds() external {
        vm.prank(operator);
        try escrow.wrapUsds() {} catch {}
    }

    function abort() external {
        vm.prank(operator);
        escrow.abort();
    }

    function strangerCalls(address caller, uint8 which) external {
        if (caller == operator) return;
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        bool ok;
        vm.prank(caller);
        if (which % 3 == 0) {
            try escrow.exitAndSeed(UniPoolerCutoverEscrow.ExitMode.PROPORTIONAL, mins, block.timestamp + 1) {
                ok = true;
            } catch {}
        } else if (which % 3 == 1) {
            try escrow.wrapUsds() {
                ok = true;
            } catch {}
        } else {
            try escrow.abort() {
                ok = true;
            } catch {}
        }
        if (ok) strangerSucceeded++;
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + (secs % 3 days));
    }
}

/// @title Property: no escrow token ever leaves to a non-protocol address
/// @notice For any sequence of operator calls (interleaved with stranger calls, donations to the
///         escrow and the pair, pool pause/recovery toggles and time jumps), every transfer out of
///         the escrow — of BPT, sUSDS, phUSD or USDS — goes to `newPooler`'s pair (seed), the V3
///         router (BPT pull, then burned), the sUSDS vault (USDS deposit, shares to `newPooler`)
///         or `oldPooler` (abort). The operator never receives anything and no allowance survives.
contract UniPoolerCutoverEscrowInvariantTest is EscrowFixture {
    EscrowHandler internal handler;

    function setUp() public {
        _deployFixture();
        handler =
            new EscrowHandler(escrow, oldPooler, v3, pair, [bpt, TrackedToken(address(sUsds)), phusd, usds], OPERATOR);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_outflowsOnlyToProtocol() public view {
        _assertAllOutflowsAllowed();
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_operatorNeverReceivesAndNoAllowanceSurvives() public view {
        assertEq(bpt.balanceOf(OPERATOR), 0, "operator BPT");
        assertEq(sUsds.balanceOf(OPERATOR), 0, "operator sUSDS");
        assertEq(phusd.balanceOf(OPERATOR), 0, "operator phUSD");
        assertEq(usds.balanceOf(OPERATOR), 0, "operator USDS");
        assertEq(handler.strangerSucceeded(), 0, "a stranger moved escrow funds");
        assertLe(handler.seeds(), 1, "seeded more than once");
        _assertNoAllowances();
    }
}
