// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {INFTMinterV2} from "./interfaces/INFTMinterV2.sol";
import {IMintable} from "./interfaces/IMintable.sol";

/// @title NFTBonfire
/// @notice Burn one of your own NFTMinterV2 claim NFTs for the antimatter that has
///         accrued since the last burn. Antimatter accrues linearly at an
///         owner-set `ratePerDay`; each burn pays out the whole pot (capped at
///         `maxPayout` when set) and resets it to zero. All token IDs are equal.
/// @dev NFTBonfire must be an authorised burner on NFTMinterV2, which does not check
///      holder approvals. `burn` therefore ALWAYS burns from `msg.sender` and no
///      function takes a holder address. Pausing halts burns, not accrual; a rate
///      of 0 halts accrual and burns while preserving the pot.
contract NFTBonfire is Ownable, Pausable, ReentrancyGuard, IPausable {
    /// @notice The ERC1155 claim-NFT minter whose tokens are burned.
    INFTMinterV2 public immutable nftMinter;

    /// @notice The antimatter token minted as the burn payout.
    IMintable public immutable antimatter;

    /// @notice Antimatter (18 dp) accrued per day. `0` disables burning and accrual.
    uint256 public ratePerDay;

    /// @notice Cap on the accrued pot, and therefore on any single payout. `0` = unlimited.
    ///         Accrual above the cap is forfeited.
    uint256 public maxPayout;

    /// @notice Pot checkpointed at `lastUpdate`.
    uint256 public accruedStored;

    /// @notice Timestamp of the last checkpoint.
    uint256 public lastUpdate;

    /// @notice Address authorised to pause/unpause (typically the global Pauser).
    ///         `address(0)` disables pausing.
    address public pauser;

    /// @notice Reverted when a constructor address argument is zero.
    error NFTBonfire__ZeroAddress();
    /// @notice Reverted by `burn` while `ratePerDay == 0`.
    error NFTBonfire__BurningDisabled();
    /// @notice Reverted by `burn` when the pot is below the caller's minimum.
    /// @param payout The payout the burn would have produced.
    /// @param minPayout The caller's requested minimum.
    error NFTBonfire__PayoutBelowMinimum(uint256 payout, uint256 minPayout);
    /// @notice Reverted when a non-pauser calls `pause`/`unpause`.
    error NFTBonfire__NotPauser();

    /// @notice Emitted on every successful burn.
    /// @param burner The caller whose NFT was burned and who received the payout.
    /// @param tokenId The burned token ID.
    /// @param payout The antimatter minted to `burner` (may be 0).
    event Burned(address indexed burner, uint256 indexed tokenId, uint256 payout);
    /// @notice Emitted when the accrual rate changes.
    /// @param oldRate The previous rate per day.
    /// @param newRate The new rate per day.
    event RatePerDayUpdated(uint256 oldRate, uint256 newRate);
    /// @notice Emitted when the payout cap changes.
    /// @param oldMax The previous cap.
    /// @param newMax The new cap.
    event MaxPayoutUpdated(uint256 oldMax, uint256 newMax);
    /// @notice Emitted when the pauser changes.
    /// @param previousPauser The previous pauser.
    /// @param newPauser The new pauser.
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    /// @dev Restricts a function to the configured `pauser`.
    modifier onlyPauser() {
        if (msg.sender != pauser) revert NFTBonfire__NotPauser();
        _;
    }

    /// @notice Deploys an inert bonfire (`ratePerDay == 0`).
    /// @param initialOwner The owner (OZ `Ownable` rejects zero).
    /// @param nftMinter_ The NFTMinterV2 whose tokens are burned.
    /// @param antimatter_ The antimatter token minted as payout.
    constructor(address initialOwner, address nftMinter_, address antimatter_) Ownable(initialOwner) {
        if (nftMinter_ == address(0) || antimatter_ == address(0)) revert NFTBonfire__ZeroAddress();
        nftMinter = INFTMinterV2(nftMinter_);
        antimatter = IMintable(antimatter_);
        lastUpdate = block.timestamp;
    }

    /// @notice Burn one of the caller's own `tokenId` NFTs for the whole accrued pot.
    /// @dev Always burns from `msg.sender`. Reverts `NFTBonfire__BurningDisabled` at
    ///      rate 0 and `NFTBonfire__PayoutBelowMinimum` when the pot is below
    ///      `minPayout`. A zero payout (with `minPayout == 0`) burns the NFT and mints nothing.
    /// @param tokenId The token ID to burn (one unit).
    /// @param minPayout Slippage floor on the payout; pass 0 to opt out.
    /// @return payout The antimatter minted to the caller.
    function burn(uint256 tokenId, uint256 minPayout) external nonReentrant whenNotPaused returns (uint256 payout) {
        if (ratePerDay == 0) revert NFTBonfire__BurningDisabled();

        payout = pendingPayout();
        if (payout < minPayout) revert NFTBonfire__PayoutBelowMinimum(payout, minPayout);

        accruedStored = 0;
        lastUpdate = block.timestamp;

        nftMinter.burn(msg.sender, tokenId, 1);
        if (payout > 0) {
            antimatter.mint(msg.sender, payout);
        }

        emit Burned(msg.sender, tokenId, payout);
    }

    /// @notice The payout a burn right now would produce: the linear accrual since
    ///         the last checkpoint plus the stored pot, capped at `maxPayout` when set.
    /// @return The current pot (floored, in the protocol's favour).
    function pendingPayout() public view returns (uint256) {
        uint256 raw = accruedStored + ((block.timestamp - lastUpdate) * ratePerDay) / 1 days;
        uint256 cap = maxPayout;
        if (cap != 0 && raw > cap) return cap;
        return raw;
    }

    /// @notice Set the accrual rate per day. Checkpoints the pot at the old rate first.
    /// @dev Setting 0 preserves the pot, stops accrual and disables burning.
    /// @param newRate The new antimatter-per-day rate (18 dp).
    function setRatePerDay(uint256 newRate) external onlyOwner {
        _checkpoint();
        emit RatePerDayUpdated(ratePerDay, newRate);
        ratePerDay = newRate;
    }

    /// @notice Set the pot/payout cap. Checkpoints the pot (capped at the old max) first.
    /// @param newMax The new cap; 0 = unlimited.
    function setMaxPayout(uint256 newMax) external onlyOwner {
        _checkpoint();
        emit MaxPayoutUpdated(maxPayout, newMax);
        maxPayout = newMax;
    }

    /// @notice Set the pauser address. `address(0)` disables pausing. Callable while paused.
    /// @param newPauser The new pauser.
    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pause burns. Only callable by `pauser`. Accrual continues.
    function pause() external override onlyPauser {
        _pause();
    }

    /// @notice Resume burns. Only callable by `pauser`.
    function unpause() external override onlyPauser {
        _unpause();
    }

    /// @dev Settle the pot under the current rate and cap before a parameter change.
    function _checkpoint() internal {
        accruedStored = pendingPayout();
        lastUpdate = block.timestamp;
    }
}
