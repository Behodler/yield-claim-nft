// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ATokenDispatcherV2} from "./ATokenDispatcherV2.sol";
import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {INudgeRatchetMintDebtHook} from "../interfaces/INudgeRatchetMintDebtHook.sol";

/// @title NudgeRatchet
/// @notice A V2 token dispatcher that forwards its USDC token to an owner-settable
///         `batchMinter` address — the nudge-reward sink. Modeled on `GatherV2`.
/// @dev Tokens arrive directly on this contract via the minter's transferFrom; `_dispatch`
///      only forwards the already-present balance with a single `safeTransfer`. The
///      `batchMinter` sink only accepts USDC, so the constructor enforces a 6-decimal
///      deploy-time guard on the token. The base `dispatch` applies the
///      `nonReentrant`/`onlyMinter`/`whenNotPaused` modifier chain.
contract NudgeRatchet is ATokenDispatcherV2 {
    using SafeERC20 for IERC20;

    /// @notice The token this dispatcher forwards. Must be USDC (6 decimals). Immutable.
    address internal immutable _token;

    /// @notice Owner-settable nudge-reward sink that receives forwarded USDC.
    address public batchMinter;

    /// @dev Must equal NudgeRatchetMintDebtHook.HOOK_TYPE_ID. Kept as a local
    ///      constant (rather than importing) to avoid a hard dependency cycle;
    ///      both derive from the same literal string and must stay in sync. (Audit M-04)
    bytes32 private constant EXPECTED_HOOK_TYPE_ID = keccak256("NudgeRatchetMintDebtHook.v1");

    /// @notice Emitted when the batchMinter address is updated.
    event BatchMinterUpdated(address indexed oldBatchMinter, address indexed newBatchMinter);

    /// @param token_ The token this dispatcher acts on — must be 6-decimal USDC.
    /// @param batchMinter_ The initial nudge-reward sink to forward tokens to.
    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address token_, address batchMinter_, address initialOwner)
        ATokenDispatcherV2(initialOwner)
    {
        require(batchMinter_ != address(0), "NudgeRatchet: zero batchMinter");
        // Deploy-time USDC guard: batchMinter only accepts USDC (6-decimal) rewards.
        require(IERC20Metadata(token_).decimals() == 6, "NudgeRatchet: token must be 6-decimal USDC");
        _token = token_;
        batchMinter = batchMinter_;
    }

    /// @inheritdoc ITokenDispatcherV2
    function primeToken() external view returns (address) {
        return _token;
    }

    /// @notice Updates the batchMinter sink. Only callable by the owner.
    /// @param newBatchMinter The new nudge-reward sink address. Must be non-zero.
    function setBatchMinter(address newBatchMinter) external onlyOwner {
        require(newBatchMinter != address(0), "NudgeRatchet: zero batchMinter");
        address old = batchMinter;
        batchMinter = newBatchMinter;
        emit BatchMinterUpdated(old, newBatchMinter);
    }

    /// @notice Forwards tokens (already on this contract) to the batchMinter.
    /// @param amount The FOT-adjusted amount of token to forward.
    function _dispatch(address, uint256 amount, bytes calldata /* extraData */) internal override {
        // Audit M-04: refuse to dispatch through a missing/wrong hook. A no-op or
        // unrelated hook lacks hookTypeId(), so this call reverts loudly.
        require(
            INudgeRatchetMintDebtHook(address(hook)).hookTypeId() == EXPECTED_HOOK_TYPE_ID,
            "NudgeRatchet: hook is not NudgeRatchetMintDebtHook"
        );
        IERC20(_token).safeTransfer(batchMinter, amount);
    }
}
