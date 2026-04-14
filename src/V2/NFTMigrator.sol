// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INFTMinter} from "../interfaces/INFTMinter.sol";
import {INFTMinterV2} from "./interfaces/INFTMinterV2.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NFTMigrator
/// @notice Allows users to convert V1 NFTs (ERC1155) to V2 NFTs in a single transaction.
/// @dev Owner must configure V1→V2 index mappings and initialize before migrations can occur.
contract NFTMigrator is Ownable {
    INFTMinter public v1;
    INFTMinterV2 public v2;
    bool public initialized;
    mapping(uint256 => uint256) public indexMapping;

    event MappingSet(uint256 v1Index, uint256 v2Index);
    event Initialized();
    event Migrated(address indexed user, uint256 v1Index, uint256 quantity, uint256 v2Index);

    /// @param v1Minter The V1 NFTMinter contract address.
    /// @param v2Minter The V2 NFTMinterV2 contract address.
    /// @param initialOwner The initial owner of this contract.
    constructor(address v1Minter, address v2Minter, address initialOwner) Ownable(initialOwner) {
        v1 = INFTMinter(v1Minter);
        v2 = INFTMinterV2(v2Minter);
    }

    /// @notice Sets a single V1→V2 index mapping. Only callable by owner.
    /// @param v1Index The V1 dispatcher index.
    /// @param v2Index The V2 dispatcher index.
    function setMapping(uint256 v1Index, uint256 v2Index) external onlyOwner {
        indexMapping[v1Index] = v2Index;
        emit MappingSet(v1Index, v2Index);
    }

    /// @notice Sets multiple V1→V2 index mappings in batch. Only callable by owner.
    /// @param v1Indexes Array of V1 dispatcher indexes.
    /// @param v2Indexes Array of V2 dispatcher indexes.
    function setMappings(uint256[] calldata v1Indexes, uint256[] calldata v2Indexes) external onlyOwner {
        require(v1Indexes.length == v2Indexes.length, "NFTMigrator: array length mismatch");
        for (uint256 i = 0; i < v1Indexes.length; i++) {
            indexMapping[v1Indexes[i]] = v2Indexes[i];
            emit MappingSet(v1Indexes[i], v2Indexes[i]);
        }
    }

    /// @notice Validates all V1 indexes have non-zero mappings and sets initialized to true.
    ///         Reverts if any V1 index has no mapping configured.
    function setInitialized() external onlyOwner {
        uint256 upperBound = v1.nextIndex();
        for (uint256 i = 1; i < upperBound; i++) {
            require(indexMapping[i] != 0, "NFTMigrator: missing mapping");
        }
        initialized = true;
        emit Initialized();
    }

    /// @notice Migrates all V1 NFTs held by the caller to V2 NFTs.
    /// @dev Burns V1 NFTs and mints equivalent V2 NFTs based on configured index mappings.
    function migrate() external {
        require(initialized, "NFTMigrator: not initialized");
        uint256 upperBound = v1.nextIndex();
        for (uint256 i = 1; i < upperBound; i++) {
            uint256 balance = IERC1155(address(v1)).balanceOf(msg.sender, i);
            if (balance > 0) {
                v1.burn(msg.sender, i, balance);
                uint256 v2Index = indexMapping[i];
                for (uint256 j = 0; j < balance; j++) {
                    v2.mintFor(v2Index, msg.sender);
                }
                emit Migrated(msg.sender, i, balance, v2Index);
            }
        }
    }
}
