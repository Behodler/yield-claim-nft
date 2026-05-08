// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IBalancerVault} from "../../interfaces/balancer/IBalancerVault.sol";
import {IBalancerRouter} from "../../interfaces/balancer/IBalancerRouter.sol";
import {IUnlockCallback} from "../../interfaces/balancer/IUnlockCallback.sol";
import {
    AddLiquidityParams,
    AddLiquidityKind,
    VaultSwapParams,
    SwapKind
} from "../../interfaces/balancer/BalancerTypes.sol";

/// @title BalancerPoolerV2
/// @notice A V2 token dispatcher that wraps USDS into sUSDS on dispatch, then allows an
///         authorized pooler to add single-sided liquidity to a Balancer V3 sUSDS/phUSD pool.
/// @dev Implements IUnlockCallback to interact with the Balancer V3 vault's unlock pattern.
///      H-02 fix: dispatch only wraps USDS -> sUSDS. Pooling is a separate owner-triggered action
///      via pool(uint256 minBPT, uint256 minUSDC) callable by authorized poolers.
///      Story-031: Adds an optional batch-donation phase that diverts a configurable percentage
///      of the sUSDS balance into a Balancer V3 swap (sUSDS -> waUSDC), unwraps waUSDC -> USDC,
///      and transfers the resulting USDC to a configurable batchMinter recipient.
contract BalancerPoolerV2 is ATokenDispatcherV2, IUnlockCallback {
    using SafeERC20 for IERC20;

    address internal immutable _sUSDS;
    address internal immutable _primeToken;
    address private _pool;
    address private immutable _vault;
    address private immutable _router;
    bool private immutable _sUSDSIsFirst;

    uint256 public authVersion;
    mapping(address => uint256) public poolerAuthVersion;

    /// @notice Percentage (0..100) of the sUSDS share balance to divert to the donation
    ///         phase on each pool() call. Defaults to 0 (donation disabled).
    uint256 public batchDonationSize;

    /// @notice Recipient of the donated USDC. address(0) disables the donation phase.
    address public batchMinter;

    /// @notice Balancer V3 pool used for the sUSDS -> waUSDC swap.
    address public swapPool;

    /// @notice Wrapped Aave USDC (ERC4626 over USDC). Intermediate token returned by the swap.
    address public waUsdc;

    /// @notice Underlying USDC, transferred to batchMinter after the waUSDC unwrap.
    address public usdc;

    event PoolerAuthorized(address indexed pooler, uint256 atAuthVersion);
    event PoolerDeauthorized(address indexed pooler);
    event AuthVersionIncremented(uint256 newAuthVersion);
    event Pooled(address indexed pooler, uint256 sUSDSPooled, uint256 bptReceived, uint256 minBPT);

    event BatchDonationSizeSet(uint256 newSize);
    event BatchMinterSet(address newBatchMinter);
    event SwapConfigSet(address swapPool, address waUsdc, address usdc);
    event BatchDonated(
        address indexed pooler,
        uint256 sUSDSSwapped,
        uint256 waUsdcReceived,
        uint256 usdcSent,
        address indexed batchMinter
    );

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

    /// @notice Sets the batch-donation percentage (0..100) of the sUSDS balance to divert
    ///         to the donation phase on each pool() call. Setting 0 disables the donation.
    /// @param newSize The new percentage. Must be <= 100.
    function setBatchDonationSize(uint256 newSize) external onlyOwner {
        require(newSize <= 100, "BalancerPoolerV2: size > 100");
        batchDonationSize = newSize;
        emit BatchDonationSizeSet(newSize);
    }

    /// @notice Sets the recipient of the donated USDC. address(0) is allowed and disables
    ///         the donation phase even if batchDonationSize > 0.
    /// @param newBatchMinter The new recipient address (or address(0) to disable).
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        batchMinter = newBatchMinter;
        emit BatchMinterSet(newBatchMinter);
    }

    /// @notice Sets the swap configuration: the Balancer V3 swap pool, the waUSDC wrapper,
    ///         and the underlying USDC token. All three must be non-zero.
    /// @param swapPool_ The Balancer V3 pool used for the sUSDS -> waUSDC swap.
    /// @param waUsdc_   The wrapped Aave USDC (ERC4626) intermediate token.
    /// @param usdc_     The underlying USDC token transferred to batchMinter.
    function setSwapConfig(address swapPool_, address waUsdc_, address usdc_) external onlyOwner {
        require(swapPool_ != address(0), "BalancerPoolerV2: zero swapPool");
        require(waUsdc_ != address(0), "BalancerPoolerV2: zero waUsdc");
        require(usdc_ != address(0), "BalancerPoolerV2: zero usdc");
        swapPool = swapPool_;
        waUsdc = waUsdc_;
        usdc = usdc_;
        emit SwapConfigSet(swapPool_, waUsdc_, usdc_);
    }

    /// @notice Dispatches tokens: wraps USDS into sUSDS. Does NOT pool into Balancer.
    /// @param amount The FOT-adjusted amount of USDS to dispatch.
    function _dispatch(address, uint256 amount, bytes calldata /*extraData*/)
        internal
        override
    {
        IERC20(_primeToken).forceApprove(_sUSDS, amount);
        IERC4626(_sUSDS).deposit(amount, address(this));
    }

    /// @notice Pools accumulated sUSDS, optionally diverting a configurable share to a batch
    ///         donation. Only callable by authorized poolers.
    /// @param minBPT  Slippage floor for BPT received from the LP add (existing behaviour).
    /// @param minUSDC Slippage floor for USDC delivered to batchMinter from the donation swap.
    ///                Ignored if the donation phase is skipped.
    function pool(uint256 minBPT, uint256 minUSDC) external onlyAuthorizedPooler whenNotPaused nonReentrant {
        uint256 sUSDSAmount = IERC20(_sUSDS).balanceOf(address(this));
        require(sUSDSAmount > 0, "BalancerPoolerV2: nothing to pool");
        bytes memory innerData = abi.encode(msg.sender, sUSDSAmount, minBPT, minUSDC);
        bytes memory data = abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, innerData);
        IBalancerVault(_vault).unlock(data);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _vault, "BalancerPoolerV2: caller is not vault");

        (address pooler, uint256 sUSDSAmount, uint256 minBPT, uint256 minUSDC) =
            abi.decode(data, (address, uint256, uint256, uint256));

        // -------- Donation phase (optional) --------
        uint256 donationSUSDS = (sUSDSAmount * batchDonationSize) / 100;
        bool donationActive = donationSUSDS > 0
            && batchMinter != address(0)
            && swapPool != address(0)
            && waUsdc != address(0)
            && usdc != address(0);

        if (donationActive) {
            // 1. Send donation sUSDS to the vault, swap to waUSDC, settle.
            IERC20(_sUSDS).safeTransfer(_vault, donationSUSDS);
            VaultSwapParams memory swapParams = VaultSwapParams({
                kind: SwapKind.EXACT_IN,
                pool: swapPool,
                tokenIn: IERC20(_sUSDS),
                tokenOut: IERC20(waUsdc),
                amountGivenRaw: donationSUSDS,
                limitRaw: 0, // final slippage enforced on USDC after unwrap
                userData: ""
            });
            (, , uint256 waUsdcReceived) = IBalancerVault(_vault).swap(swapParams);
            IBalancerVault(_vault).settle(IERC20(_sUSDS), donationSUSDS);

            // 2. Unwrap waUSDC -> USDC (ERC4626 redeem).
            uint256 usdcReceived =
                IERC4626(waUsdc).redeem(waUsdcReceived, address(this), address(this));

            // 3. Slippage check on the final delivered token (USDC).
            require(usdcReceived >= minUSDC, "BalancerPoolerV2: USDC slippage");

            // 4. Transfer USDC to BatchMinter.
            IERC20(usdc).safeTransfer(batchMinter, usdcReceived);

            emit BatchDonated(pooler, donationSUSDS, waUsdcReceived, usdcReceived, batchMinter);

            sUSDSAmount -= donationSUSDS;
        }

        // -------- LP add-liquidity phase (existing behaviour, on remaining sUSDS) --------
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

        bptAmountOut = IBalancerRouter(_router).queryAddLiquidityUnbalanced(
            _pool, exactAmountsIn, address(this), ""
        );
    }

    /// @notice Withdraws BPT tokens held by this contract to a recipient.
    /// @param recipient The address to receive the BPT tokens.
    /// @param amount The amount of BPT tokens to withdraw.
    function withdrawBPT(address recipient, uint256 amount) external onlyOwner {
        IERC20(_pool).safeTransfer(recipient, amount);
    }

    /// @notice Owner escape hatch. Transfers `amount` of any ERC20 token held by
    ///         this contract to `to`. Used to recover tokens stuck on the dispatcher
    ///         (e.g., accidental transfers, airdrops). Not pause-gated — escape
    ///         hatch must function during a pause.
    /// @dev    Does not expand the owner trust surface: the owner already holds
    ///         `withdrawBPT` and (post-026) `pool(minBPT)`.
    /// @param  token  The ERC20 token to rescue.
    /// @param  to     Recipient of the rescued tokens. Must be non-zero.
    /// @param  amount Amount of `token` to transfer.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "BalancerPoolerV2: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
