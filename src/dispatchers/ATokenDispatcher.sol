// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenDispatcher} from "../interfaces/ITokenDispatcher.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ATokenDispatcher
/// @notice Abstract base contract for token dispatchers with pausability support.
/// @dev Inherits ITokenDispatcher, Pausable, and Ownable. Provides a minter authorization
///      mechanism so that the NFTMinter can pause/unpause dispatchers.
abstract contract ATokenDispatcher is ITokenDispatcher, Pausable, Ownable {
    /// @notice The authorized minter address that can pause/unpause this dispatcher.
    address internal _minter;

    /// @notice Metadata fields for this dispatcher.
    string private _name;
    string private _image;
    string private _description;

    /// @notice Emitted when metadata is updated.
    event MetadataUpdated(string name, string image, string description);

    /// @notice Restricts function access to the authorized minter.
    modifier onlyMinter() {
        require(msg.sender == _minter, "ATokenDispatcher: caller is not minter");
        _;
    }

    /// @param initialOwner The initial owner of this dispatcher.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Sets the metadata for this dispatcher. Only callable by the owner.
    /// @param name_ The name metadata string.
    /// @param image_ The image metadata string (URL or data URI).
    /// @param description_ The description metadata string.
    function setMetadata(string calldata name_, string calldata image_, string calldata description_) external onlyOwner {
        _name = name_;
        _image = image_;
        _description = description_;
        emit MetadataUpdated(name_, image_, description_);
    }

    /// @inheritdoc ITokenDispatcher
    function name() external view returns (string memory) {
        return _name;
    }

    /// @inheritdoc ITokenDispatcher
    function image() external view returns (string memory) {
        return _image;
    }

    /// @inheritdoc ITokenDispatcher
    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Sets the authorized minter address. Only callable by the owner.
    /// @param minter_ The address of the NFTMinter contract.
    function setMinter(address minter_) external onlyOwner {
        _minter = minter_;
    }

    /// @notice Pauses the dispatcher. Only callable by the authorized minter.
    function pause() external onlyMinter {
        _pause();
    }

    /// @notice Unpauses the dispatcher. Only callable by the authorized minter.
    function unpause() external onlyMinter {
        _unpause();
    }

    /// @notice Executes the dispatch logic. Reverts if the dispatcher is paused.
    /// @param minter The NFTMinter contract address.
    /// @param amount The amount of prime token that was paid for this mint.
    /// @param extraData Dispatcher-specific encoded data (unused in base; reserved for future use).
    function dispatch(address minter, uint256 amount, bytes calldata extraData)
        external
        virtual
        onlyMinter
        whenNotPaused
    {}
}
