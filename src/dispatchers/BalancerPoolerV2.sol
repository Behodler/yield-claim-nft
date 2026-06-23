// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {ISkyPSM} from "../interfaces/ISkyPSM.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IBalancerRouter} from "../interfaces/balancer/IBalancerRouter.sol";
import {IUnlockCallback} from "../interfaces/balancer/IUnlockCallback.sol";
import {AddLiquidityParams, AddLiquidityKind} from "../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPoolerV2
/// @notice A V2 token dispatcher that wraps USDS into sUSDS on dispatch, then allows an
///         authorized pooler to add single-sided liquidity to a Balancer V3 sUSDS/phUSD pool.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
///      H-02 fix: dispatch only wraps USDS -> sUSDS. Pooling is a separate owner-triggered
///      action via pool(uint256 minBPT) callable by authorized poolers.
///
///      Story-034: The batch-donation route is rebuilt. The previous route
///      (sUSDS -> waUSDC via a Balancer V3 swap -> USDC) was structurally dead — the only
///      sUSDS/waUSDC pool on Balancer V3 is unseeded, so any swap reverts
///      `MaxImbalanceRatioExceeded()` and bricked the (atomic) pool() call. It is replaced by
///      a reserve-backed, fixed-rate Sky PSM route (USDS -> USDC via `buyGem`) that has no
///      price curve / slippage / imbalance ceiling. The donation now happens **inside
///      `_dispatch`** (where the contract already holds raw USDS), isolated in a self-gated
///      external call wrapped in try/catch so a PSM outage can never revert the mint: the
///      un-donated USDS simply parks on the contract and is re-swept on the next dispatch.
///      `pool()` becomes a pure LP add (its `minUSDC` arg is removed).
contract BalancerPoolerV2 is ATokenDispatcherV2, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @dev 1e18 fixed-point scale, matching the Sky PSM WAD used for `tout`.
    uint256 internal constant WAD = 1e18;

    address internal immutable _sUSDS;
    address internal immutable _primeToken;
    address private _pool;
    address private immutable _vault;
    address private immutable _router;
    bool private immutable _sUSDSIsFirst;

    uint256 public authVersion;
    mapping(address => uint256) public poolerAuthVersion;

    /// @notice Percentage (0..100) of each dispatched USDS amount to divert to the donation
    ///         on each dispatch. Defaults to 0 (donation disabled).
    uint256 public batchDonationSize;

    /// @notice Recipient of the donated USDC. address(0) disables the donation.
    address public batchMinter;

    /// @notice The Sky USDS↔USDC PSM (UsdsPsmWrapper). address(0) disables the donation.
    /// @dev Canonical live PSM (verify before deploy): Sky `UsdsPsmWrapper`
    ///      ("LitePSMWrapper-USDS-USDC") at 0xA188EEC8F81263234dA3622A406892F3D630f98c on
    ///      Ethereum mainnet (source: github.com/sky-ecosystem/usds-wrappers). Set via setPSM.
    address public psm;

    /// @notice WAD-scaled ceiling on the PSM `tout` (buy fee). A `tout` above this routes the
    ///         donation into the silent fallback (USDS parks) rather than ship a worse rate.
    /// @dev Defaults to 0.01e18 = 1%. Owner-settable so a legitimate Sky-governance `tout`
    ///      rise can be accommodated without redeploying. The live `tout` has historically
    ///      been ~0 (source: makerdao/dss-lite-psm; Sky PSM docs).
    uint256 public maxTout = 0.01e18;

    event PoolerAuthorized(address indexed pooler, uint256 atAuthVersion);
    event PoolerDeauthorized(address indexed pooler);
    event AuthVersionIncremented(uint256 newAuthVersion);
    event Pooled(address indexed pooler, uint256 sUSDSPooled, uint256 bptReceived, uint256 minBPT);

    event BatchDonationSizeSet(uint256 newSize);
    event BatchMinterSet(address newBatchMinter);
    event PSMSet(address newPSM);
    event MaxToutSet(uint256 newMaxTout);

    /// @notice Emitted on a successful PSM donation. `usdsSpent` is the USDS pulled by the PSM
    ///         (incl. tout fee); `usdcDonated` is the USDC delivered to `batchMinter`.
    event BatchDonatedViaPSM(uint256 usdsSpent, uint256 usdcDonated, address indexed batchMinter);

    /// @notice Emitted when a donation attempt is silently skipped (PSM outage / fee spike /
    ///         dust). `usdsParked` USDS stays on the contract for the next dispatch to retry.
    event DonationSkipped(uint256 usdsParked);

    modifier onlyAuthorizedPooler() {
        require(poolerAuthVersion[msg.sender] == authVersion, "BalancerPoolerV2: caller not authorized pooler");
        _;
    }

    constructor(
        address sUSDS_,
        address pool_,
        address vault_,
        address router_,
        bool sUSDSIsFirst_,
        address initialOwner
    ) ATokenDispatcherV2(initialOwner) {
        require(sUSDS_ != address(0), "BalancerPoolerV2: zero sUSDS");
        require(router_ != address(0), "BalancerPoolerV2: zero router");
        _sUSDS = sUSDS_;
        _primeToken = IERC4626(sUSDS_).asset();
        _pool = pool_;
        _vault = vault_;
        _router = router_;
        _sUSDSIsFirst = sUSDSIsFirst_;
        authVersion = 1;
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

    /// @notice Sets or revokes an authorized pooler. Only callable by owner.
    /// @param pooler The address to authorize or deauthorize.
    /// @param authorized True to authorize, false to deauthorize.
    function setAuthorizedPooler(address pooler, bool authorized) external onlyOwner {
        require(pooler != address(0), "BalancerPoolerV2: zero pooler");
        if (authorized) {
            poolerAuthVersion[pooler] = authVersion;
            emit PoolerAuthorized(pooler, authVersion);
        } else {
            delete poolerAuthVersion[pooler];
            emit PoolerDeauthorized(pooler);
        }
    }

    /// @notice Increments the auth version, mass-revoking all current pooler authorizations.
    function incrementAuthVersion() external onlyOwner {
        authVersion += 1;
        emit AuthVersionIncremented(authVersion);
    }

    /// @notice Sets the batch-donation percentage (0..100) of each dispatched USDS amount to
    ///         divert to the PSM donation. Setting 0 disables the donation.
    /// @param newSize The new percentage. Must be <= 100.
    function setBatchDonationSize(uint256 newSize) external onlyOwner {
        require(newSize <= 100, "BalancerPoolerV2: size > 100");
        batchDonationSize = newSize;
        emit BatchDonationSizeSet(newSize);
    }

    /// @notice Sets the recipient of the donated USDC. address(0) is allowed and disables
    ///         the donation even if batchDonationSize > 0.
    /// @param newBatchMinter The new recipient address (or address(0) to disable).
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        batchMinter = newBatchMinter;
        emit BatchMinterSet(newBatchMinter);
    }

    /// @notice Sets the Sky USDS↔USDC PSM used for the donation. Must be non-zero.
    /// @dev Mirrors the auditable, re-pointable shape of the old `setSwapConfig`.
    /// @param newPSM The PSM (UsdsPsmWrapper) address.
    function setPSM(address newPSM) external onlyOwner {
        require(newPSM != address(0), "BalancerPoolerV2: zero psm");
        psm = newPSM;
        emit PSMSet(newPSM);
    }

    /// @notice Sets the WAD-scaled ceiling on the PSM `tout` accepted for a donation.
    /// @param newMaxTout The new ceiling (1e18 == 100%).
    function setMaxTout(uint256 newMaxTout) external onlyOwner {
        maxTout = newMaxTout;
        emit MaxToutSet(newMaxTout);
    }

    /// @notice Dispatches tokens: wraps the pooling portion of USDS into sUSDS, then attempts
    ///         a silent PSM donation of the remaining raw USDS to `batchMinter`.
    /// @dev Donation is carved out **only when enabled** (batchMinter + psm set, size > 0); when
    ///      disabled the full `amount` is wrapped so nothing is stranded. The donation sweeps
    ///      `balanceOf(USDS)` — not just this dispatch's share — so USDS stranded by a prior
    ///      failed donation is automatically retried (the recovery mechanism; no separate
    ///      retry function needed). The conversion is isolated in `try this._psmDonate{} catch`
    ///      so any PSM failure (outage, fee spike, empty reserve, dust) parks the USDS instead
    ///      of reverting the mint. The base class then calls `hook.onDispatch(minter, amount)`
    ///      with the **gross** amount, so mint-debt accrues on the full dispatched USDS
    ///      regardless of donation outcome.
    /// @param amount The FOT-adjusted amount of USDS to dispatch.
    function _dispatch(
        address,
        uint256 amount,
        bytes calldata /*extraData*/
    )
        internal
        override
    {
        bool donationEnabled = batchMinter != address(0) && psm != address(0) && batchDonationSize > 0;

        uint256 donationUSDS = donationEnabled ? (amount * batchDonationSize) / 100 : 0;
        uint256 poolingUSDS = amount - donationUSDS;

        // Wrap ONLY the pooling portion -> sUSDS (this is what pool() will later consume).
        if (poolingUSDS > 0) {
            IERC20(_primeToken).forceApprove(_sUSDS, poolingUSDS);
            IERC4626(_sUSDS).deposit(poolingUSDS, address(this));
        }

        // Sweep ALL remaining raw USDS (this dispatch's donation share + any USDS stranded by
        // a previous failed donation) and attempt the PSM conversion. Silent on failure.
        if (donationEnabled) {
            uint256 remainingUSDS = IERC20(_primeToken).balanceOf(address(this));
            if (remainingUSDS > 0) {
                try this._psmDonate(remainingUSDS) {}
                catch {
                    emit DonationSkipped(remainingUSDS); // USDS parks on the contract.
                }
            }
        }
    }

    /// @notice Failure-isolated USDS->USDC donation via the Sky PSM. Self-gated `external` so
    ///         any revert (tout ceiling, empty reserve, rounding-to-zero, short reserve) rolls
    ///         back the entire approve+buyGem atomically — the `_dispatch` try/catch then
    ///         leaves the swept USDS untouched.
    /// @dev MUST be called only via `try this._psmDonate{}` from `_dispatch`.
    /// @param usdsAmount Raw USDS available to convert (this dispatch's share + any stranded).
    function _psmDonate(uint256 usdsAmount) external {
        require(msg.sender == address(this), "BalancerPoolerV2: only self");

        uint256 tout = ISkyPSM(psm).tout();
        require(tout <= maxTout, "BalancerPoolerV2: tout too high");

        // Size USDC out (6dp) from USDS in (18dp), net of tout. FLOOR -> dust accrues to
        // the protocol (never over-credits). Mirrors the real PSM buyGem math:
        //   usdsInWad = gemAmt * to18ConversionFactor; if (tout>0) usdsInWad += usdsInWad*tout/WAD
        // so the max gemAmt affordable from `usdsAmount` is:
        //   gemAmt = floor( usdsAmount * WAD / (conv * (WAD + tout)) )
        // (source: makerdao/dss-lite-psm DssLitePsm._buyGem; conv=to18ConversionFactor=1e12 USDC.)
        uint256 conv = ISkyPSM(psm).to18ConversionFactor();
        uint256 gemAmt = (usdsAmount * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "BalancerPoolerV2: donation dust");

        // Exact USDS the PSM will pull for this gemAmt (<= usdsAmount; remainder is dust).
        uint256 usdsSpent = gemAmt * conv * (WAD + tout) / WAD;

        IERC20(_primeToken).forceApprove(psm, usdsSpent);
        ISkyPSM(psm).buyGem(batchMinter, gemAmt); // USDC delivered straight to batchMinter.
        IERC20(_primeToken).forceApprove(psm, 0); // tidy allowance.

        emit BatchDonatedViaPSM(usdsSpent, gemAmt, batchMinter);
    }

    /// @notice Pools accumulated sUSDS as a single-sided Balancer V3 LP add. Only callable by
    ///         authorized poolers. Pure LP add — the donation lives in `_dispatch`.
    /// @param minBPT Slippage floor for BPT received from the LP add.
    function pool(uint256 minBPT) external onlyAuthorizedPooler whenNotPaused nonReentrant {
        uint256 sUSDSAmount = IERC20(_sUSDS).balanceOf(address(this));
        require(sUSDSAmount > 0, "BalancerPoolerV2: nothing to pool");
        bytes memory innerData = abi.encode(msg.sender, sUSDSAmount, minBPT);
        bytes memory data = abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, innerData);
        IBalancerVault(_vault).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _vault, "BalancerPoolerV2: caller is not vault");

        (address pooler, uint256 sUSDSAmount, uint256 minBPT) = abi.decode(data, (address, uint256, uint256));

        // -------- LP add-liquidity phase (unchanged behaviour) --------
        if (sUSDSAmount > 0) {
            uint256 vaultBefore = IERC20(_sUSDS).balanceOf(_vault);
            IERC20(_sUSDS).safeTransfer(_vault, sUSDSAmount);
            uint256 actualInVault = IERC20(_sUSDS).balanceOf(_vault) - vaultBefore;

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
                minBptAmountOut: minBPT,
                kind: AddLiquidityKind.UNBALANCED,
                userData: ""
            });

            (, uint256 bptAmountOut,) = IBalancerVault(_vault).addLiquidity(params);
            IBalancerVault(_vault).settle(IERC20(_sUSDS), actualInVault);

            emit Pooled(pooler, actualInVault, bptAmountOut, minBPT);
        }

        return "";
    }

    /// @notice Queries the Balancer Router for the expected BPT output from pooling current sUSDS balance.
    /// @return bptAmountOut The expected BPT amount, or 0 if sUSDS balance is 0.
    function getIdealBPT() external returns (uint256 bptAmountOut) {
        uint256 sUSDSAmount = IERC20(_sUSDS).balanceOf(address(this));
        if (sUSDSAmount == 0) return 0;

        uint256[] memory exactAmountsIn = new uint256[](2);
        if (_sUSDSIsFirst) {
            exactAmountsIn[0] = sUSDSAmount;
            exactAmountsIn[1] = 0;
        } else {
            exactAmountsIn[0] = 0;
            exactAmountsIn[1] = sUSDSAmount;
        }

        bptAmountOut = IBalancerRouter(_router).queryAddLiquidityUnbalanced(_pool, exactAmountsIn, address(this), "");
    }

    /// @notice Withdraws BPT tokens held by this contract to a recipient.
    /// @param recipient The address to receive the BPT tokens.
    /// @param amount The amount of BPT tokens to withdraw.
    function withdrawBPT(address recipient, uint256 amount) external onlyOwner {
        IERC20(_pool).safeTransfer(recipient, amount);
    }

    /// @notice Owner escape hatch. Transfers `amount` of any ERC20 token held by
    ///         this contract to `to`. Used to recover tokens stuck on the dispatcher
    ///         (e.g., accidental transfers, airdrops, or USDS parked by a skipped
    ///         donation). Not pause-gated — escape hatch must function during a pause.
    /// @dev    Does not expand the owner trust surface: the owner already holds
    ///         `withdrawBPT` and `pool(minBPT)`.
    /// @param  token  The ERC20 token to rescue.
    /// @param  to     Recipient of the rescued tokens. Must be non-zero.
    /// @param  amount Amount of `token` to transfer.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "BalancerPoolerV2: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
