// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The burn hook the exit mock calls on its pool token after pulling it from the caller.
interface IMockBurnableBpt {
    function burn(uint256 amount) external;
}

/// @dev Minimal mintable/burnable pool token (BPT stand-in). `mint` is open (test-only); `burn`
///      burns the caller's own balance, so the exit router must first pull the BPT to itself.
contract MockBPT is ERC20 {
    constructor() ERC20("Mock Pool Token", "mBPT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Balancer V3 Router exit subset for unit tests, for ONE pool whose underlying balances the
///      mock itself holds (it plays both the Router and the Vault).
///
///      Fidelity points that matter to the escrow:
///      - The BPT is pulled with `transferFrom(caller, this, amount)`, which spends the caller's
///        allowance TO THIS ROUTER. A caller that forgets to approve the router reverts
///        `ERC20InsufficientAllowance(router, 0, amount)`, exactly like mainnet, where the Vault
///        burns the BPT by spending the router's allowance.
///      - Payout is pro rata in pool-token order: `amountsOut[i] = balance[i] * bptIn / totalSupply`
///        (rounded down, total supply read before the burn), the formula the real Vault applies to
///        raw balances for both proportional and recovery exits of a rate-less pool.
///      - Every `minAmountsOut[i]` is enforced, and the array length must equal the token count.
///      - `paused`: `removeLiquidityProportional` reverts `MockV3ExitRouter__PoolPaused`.
///      - `recoveryMode`: `removeLiquidityRecovery` reverts `MockV3ExitRouter__NotInRecoveryMode`
///        unless it is set. Recovery ignores `paused`, as on mainnet. The two flags are
///        independent; a test reproducing "paused pool, recovery enabled" sets both.
///      - Both entry points are `payable` like the real router; the mock rejects any ETH.
contract MockV3ExitRouter {
    using SafeERC20 for IERC20;

    address public immutable pool;
    address[] internal _tokens;

    bool public paused;
    bool public recoveryMode;

    uint256 public proportionalCalls;
    uint256 public recoveryCalls;

    error MockV3ExitRouter__UnknownPool(address pool);
    error MockV3ExitRouter__PoolPaused(address pool);
    error MockV3ExitRouter__NotInRecoveryMode(address pool);
    error MockV3ExitRouter__LengthMismatch(uint256 expected, uint256 actual);
    error MockV3ExitRouter__AmountOutBelowMin(address token, uint256 amountOut, uint256 minAmountOut);
    error MockV3ExitRouter__ValueSent();

    /// @param pool_ The BPT (must expose `burn(uint256)` on the caller's own balance).
    /// @param tokens_ The pool tokens in pool order. The mock's own balances of them are the pool.
    constructor(address pool_, address[] memory tokens_) {
        pool = pool_;
        _tokens = tokens_;
    }

    function getTokens() external view returns (address[] memory) {
        return _tokens;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setRecoveryMode(bool recoveryMode_) external {
        recoveryMode = recoveryMode_;
    }

    /// @dev Read-only preview of the pro-rata payout for `bptIn`.
    function previewExit(uint256 bptIn) public view returns (uint256[] memory amountsOut) {
        uint256 supply = IERC20(pool).totalSupply();
        amountsOut = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            amountsOut[i] = (IERC20(_tokens[i]).balanceOf(address(this)) * bptIn) / supply;
        }
    }

    function removeLiquidityProportional(
        address pool_,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool,
        bytes memory
    ) external payable returns (uint256[] memory amountsOut) {
        if (paused) revert MockV3ExitRouter__PoolPaused(pool_);
        proportionalCalls++;
        amountsOut = _exit(pool_, exactBptAmountIn, minAmountsOut);
    }

    function removeLiquidityRecovery(address pool_, uint256 exactBptAmountIn, uint256[] memory minAmountsOut)
        external
        payable
        returns (uint256[] memory amountsOut)
    {
        if (!recoveryMode) revert MockV3ExitRouter__NotInRecoveryMode(pool_);
        recoveryCalls++;
        amountsOut = _exit(pool_, exactBptAmountIn, minAmountsOut);
    }

    function _exit(address pool_, uint256 bptIn, uint256[] memory minAmountsOut)
        internal
        returns (uint256[] memory amountsOut)
    {
        if (msg.value != 0) revert MockV3ExitRouter__ValueSent();
        if (pool_ != pool) revert MockV3ExitRouter__UnknownPool(pool_);
        if (minAmountsOut.length != _tokens.length) {
            revert MockV3ExitRouter__LengthMismatch(_tokens.length, minAmountsOut.length);
        }
        amountsOut = previewExit(bptIn);
        // Spends the caller's allowance to THIS router: no approve, no exit.
        IERC20(pool).safeTransferFrom(msg.sender, address(this), bptIn);
        IMockBurnableBpt(pool).burn(bptIn);
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (amountsOut[i] < minAmountsOut[i]) {
                revert MockV3ExitRouter__AmountOutBelowMin(_tokens[i], amountsOut[i], minAmountsOut[i]);
            }
            IERC20(_tokens[i]).safeTransfer(msg.sender, amountsOut[i]);
        }
    }
}
