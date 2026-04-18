// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenDispatcherV2} from "../interfaces/ITokenDispatcherV2.sol";
import {IDispatchHook} from "../interfaces/IDispatchHook.sol";
import {DefaultDispatchHook} from "../hooks/DefaultDispatchHook.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ATokenDispatcherV2
/// @notice Abstract base contract for V2 token dispatchers with pausability support.
/// @dev Inherits ITokenDispatcherV2, Pausable, Ownable, and ReentrancyGuard. Provides a
///      minter authorization mechanism so that the NFTMinterV2 can pause/unpause dispatchers.
///      V2 removes primeToken() from the interface.
///
///      Dispatch uses a template-method split: the external `dispatch` entry point is
///      non-virtual and applies the full modifier chain (`nonReentrant`, `onlyMinter`,
///      `whenNotPaused`), calls the concrete implementation via internal virtual
///      `_dispatch`, then calls `hook.onDispatch(...)` with the same arguments. `hook` is
///      initialized to a freshly deployed `DefaultDispatchHook` in the constructor and
///      is never the zero address, so the dispatch path is branch-free.
abstract contract ATokenDispatcherV2 is ITokenDispatcherV2, Pausable, Ownable, ReentrancyGuard {
    /// @notice The authorized minter address that can pause/unpause this dispatcher.
    address internal _minter;

    /// @notice Metadata fields for this dispatcher.
    string private _name;
    string private _image;
    string private _description;

    /// @notice Pluggable hook invoked after every successful `_dispatch`.
    /// @dev Never the zero address. Defaults to a `DefaultDispatchHook` deployed in the
    ///      constructor. Owner may swap via `setHook`.
    IDispatchHook public hook;

    /// @notice Emitted when metadata is updated.
    event MetadataUpdated(string name, string image, string description);

    /// @notice Emitted when the dispatch hook is replaced via `setHook`.
    event HookUpdated(address indexed oldHook, address indexed newHook);

    /// @notice Restricts function access to the authorized minter.
    modifier onlyMinter() {
        require(msg.sender == _minter, "ATokenDispatcherV2: caller is not minter");
        _;
    }

    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address initialOwner) Ownable(initialOwner) {
        hook = new DefaultDispatchHook();
    }

    /// @notice Sets the metadata for this dispatcher. Only callable by the owner.
    /// @param name_ The name metadata string.
    /// @param image_ The image metadata string (URL or data URI).
    /// @param description_ The description metadata string.
    function setMetadata(string calldata name_, string calldata image_, string calldata description_)
        external
        onlyOwner
    {
        _name = name_;
        _image = image_;
        _description = description_;
        emit MetadataUpdated(name_, image_, description_);
    }

    /// @inheritdoc ITokenDispatcherV2
    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc ITokenDispatcherV2
    function image() external view returns (string memory) {
        return _image;
    }

    /// @inheritdoc ITokenDispatcherV2
    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Sets the authorized minter address. Only callable by the owner.
    /// @param minter_ The address of the NFTMinterV2 contract.
    function setMinter(address minter_) external onlyOwner {
        _minter = minter_;
    }

    /// @notice Replaces the dispatch hook. Only callable by the owner.
    /// @dev    Reverts if `newHook` is the zero address — the `hook` invariant is that it
    ///         must never be null so the dispatch path stays branch-free. A misbehaving
    ///         hook will revert `dispatch`; swap it out before dispatching can resume.
    /// @param  newHook The replacement `IDispatchHook` implementation.
    function setHook(IDispatchHook newHook) external onlyOwner {
        require(address(newHook) != address(0), "ATokenDispatcherV2: zero hook");
        address oldHook = address(hook);
        hook = newHook;
        emit HookUpdated(oldHook, address(newHook));
    }

    /// @notice Pauses the dispatcher. Only callable by the authorized minter.
    function pause() external onlyMinter {
        _pause();
    }

    /// @notice Unpauses the dispatcher. Only callable by the authorized minter.
    function unpause() external onlyMinter {
        _unpause();
    }

    /// @notice Executes the dispatch logic and invokes the hook.
    /// @dev Non-virtual entry point. Concrete dispatchers override `_dispatch`, not this
    ///      function. Applies `nonReentrant` so that a reentrant hook cannot re-enter
    ///      `dispatch` via the abstract.
    /// @param minter The NFTMinterV2 contract address.
    /// @param amount The amount of token that was paid for this mint.
    /// @param extraData Dispatcher-specific encoded data.
    function dispatch(address minter, uint256 amount, bytes calldata extraData)
        external
        nonReentrant
        onlyMinter
        whenNotPaused
    {
        _dispatch(minter, amount, extraData);
        hook.onDispatch(minter, amount, extraData);
    }

    /// @notice Internal dispatch extension point overridden by concrete dispatchers.
    /// @dev Default implementation is a no-op so the abstract is test-harness friendly.
    ///      Concrete dispatchers MUST NOT re-declare `onlyMinter`, `whenNotPaused`, or
    ///      `nonReentrant` — those modifiers live on the external `dispatch`.
    function _dispatch(address minter, uint256 amount, bytes calldata extraData) internal virtual {}
}
