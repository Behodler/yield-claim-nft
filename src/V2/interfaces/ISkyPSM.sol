// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ISkyPSM
/// @notice Minimal interface for the Sky USDS↔USDC Peg Stability Module, faithful to the
///         live `UsdsPsmWrapper` (which proxies the Maker `DssLitePsm`). The pooler only
///         uses `buyGem` (USDS→USDC) plus the `tout`/`to18ConversionFactor` views needed to
///         size the donation, but the rest of the surface is mirrored so a reader can
///         cross-check it against the deployed contract.
///
/// @dev Verified on-chain / from canonical source (2026-06-04):
///   - Live contract: Sky `UsdsPsmWrapper` ("LitePSMWrapper-USDS-USDC")
///         0xA188EEC8F81263234dA3622A406892F3D630f98c  (Ethereum mainnet)
///       (source: github.com/sky-ecosystem/usds-wrappers, src/UsdsPsmWrapper.sol;
///        listed in Sky docs developers.sky.money/guides/psm/litepsm).
///   - It routes USDS→USDC swaps to the underlying Maker LitePSM-DAI-USDC
///         0xf6e72Db5454dd049d0788e411b06CfAF16853042
///       by converting USDS→DAI internally; the fee/decimal conventions are identical.
///   - `buyGem(address usr, uint256 gemAmt) returns (uint256 usdsInWad)`:
///        pulls `usdsInWad` USDS (18dp) from msg.sender via transferFrom, delivers
///        `gemAmt` USDC (6dp) to `usr`. usdsInWad = gemAmt * to18ConversionFactor, plus
///        `tout` fee: if (tout > 0) usdsInWad += usdsInWad * tout / WAD  (WAD = 1e18).
///        (source: makerdao/dss-lite-psm DssLitePsm._buyGem.)
///   - `to18ConversionFactor` is an immutable = 10**(18 - gem.decimals()) = 1e12 for USDC.
///   - `tout` / `tin` are governance-settable WAD fee parameters (currently 0; raisable).
///   - `gem()`=USDC (0xA0b8...eB48), `usds()`=USDS, `dai()`=DAI (legacy bridge token).
interface ISkyPSM {
    /// @notice Buy `gemAmt` USDC (6dp) for `usr`, paying USDS pulled from msg.sender.
    /// @param  usr    Recipient of the USDC.
    /// @param  gemAmt USDC amount to receive, in gem (USDC) decimals (6dp).
    /// @return usdsInWad USDS (18dp) the caller paid (gemAmt*to18ConversionFactor + tout fee).
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsInWad);

    /// @notice Sell `gemAmt` USDC (6dp) from msg.sender, receiving USDS to `usr`.
    /// @return usdsOutWad USDS (18dp) delivered net of the `tin` fee.
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOutWad);

    /// @notice Buy-side fee, WAD-scaled (1e18 == 100%). Applied on `buyGem`.
    function tout() external view returns (uint256);

    /// @notice Sell-side fee, WAD-scaled. Applied on `sellGem`.
    function tin() external view returns (uint256);

    /// @notice 10**(18 - gem.decimals()); 1e12 for 6-decimal USDC.
    function to18ConversionFactor() external view returns (uint256);

    /// @notice The gem token bought/sold (USDC).
    function gem() external view returns (address);

    /// @notice The Sky stablecoin paid/received (USDS).
    function usds() external view returns (address);
}
