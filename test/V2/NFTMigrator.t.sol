// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMigrator} from "../../src/V2/NFTMigrator.sol";
import {NFTMinter} from "../../src/NFTMinter.sol";
import {NFTMinterV2} from "../../src/V2/NFTMinterV2.sol";
import {Gather} from "../../src/dispatchers/Gather.sol";
import {GatherV2} from "../../src/V2/dispatchers/GatherV2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Simple mock ERC20 for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NFTMigratorTest is Test {
    NFTMigrator public migrator;
    NFTMinter public v1;
    NFTMinterV2 public v2;
    MockERC20 public token;

    Gather public gatherV1_1;
    Gather public gatherV1_2;
    Gather public gatherV1_3;
    GatherV2 public gatherV2_1;
    GatherV2 public gatherV2_2;
    GatherV2 public gatherV2_3;

    address public owner = address(this);
    address public user = address(0xBEEF);
    address public user2 = address(0xDEAD);
    address public nonOwner = address(0xBAD);
    address public gatherRecipient = address(0xFEED);

    uint256 public constant MINT_PRICE = 10e18;

    function setUp() public {
        // Deploy tokens
        token = new MockERC20("Test Token", "TKN");

        // Deploy V1 and V2 minters
        v1 = new NFTMinter(owner);
        v2 = new NFTMinterV2(owner);

        // Deploy V1 dispatchers (need primeToken)
        gatherV1_1 = new Gather(address(token), gatherRecipient, owner);
        gatherV1_2 = new Gather(address(token), gatherRecipient, owner);
        gatherV1_3 = new Gather(address(token), gatherRecipient, owner);

        // Deploy V2 dispatchers
        gatherV2_1 = new GatherV2(address(token), gatherRecipient, owner);
        gatherV2_2 = new GatherV2(address(token), gatherRecipient, owner);
        gatherV2_3 = new GatherV2(address(token), gatherRecipient, owner);

        // Register V1 dispatchers (indexes 1, 2, 3) and set minter
        gatherV1_1.setMinter(address(v1));
        gatherV1_2.setMinter(address(v1));
        gatherV1_3.setMinter(address(v1));
        v1.registerDispatcher(address(gatherV1_1), MINT_PRICE, 0);
        v1.registerDispatcher(address(gatherV1_2), MINT_PRICE, 0);
        v1.registerDispatcher(address(gatherV1_3), MINT_PRICE, 0);

        // Register V2 dispatchers (indexes 1, 2, 3) and set minter
        gatherV2_1.setMinter(address(v2));
        gatherV2_2.setMinter(address(v2));
        gatherV2_3.setMinter(address(v2));
        v2.registerDispatcher(address(gatherV2_1), MINT_PRICE, 0);
        v2.registerDispatcher(address(gatherV2_2), MINT_PRICE, 0);
        v2.registerDispatcher(address(gatherV2_3), MINT_PRICE, 0);

        // Deploy migrator
        migrator = new NFTMigrator(address(v1), address(v2), owner);

        // Authorize migrator as burner on V1 and as minter on V2
        v1.setAuthorizedBurner(address(migrator), true);
        v2.setAuthorizedMinter(address(migrator), true);
    }

    /// @dev Helper: mint V1 NFTs for a user at a given index, quantity times.
    function _mintV1(address recipient, uint256 index, uint256 quantity) internal {
        token.mint(recipient, MINT_PRICE * quantity);
        vm.startPrank(recipient);
        token.approve(address(v1), type(uint256).max);
        for (uint256 i = 0; i < quantity; i++) {
            v1.mint(address(token), index, recipient);
        }
        vm.stopPrank();
    }

    // =========================================================================
    // 1. Constructor stores V1 and V2 references correctly
    // =========================================================================

    function test_constructor_storesV1AndV2References() public view {
        assertEq(address(migrator.v1()), address(v1));
        assertEq(address(migrator.v2()), address(v2));
    }

    // =========================================================================
    // 2. initialized defaults to false
    // =========================================================================

    function test_initializedDefaultsToFalse() public view {
        assertFalse(migrator.initialized());
    }

    // =========================================================================
    // 3. setMapping sets individual mappings correctly
    // =========================================================================

    function test_setMapping_setsIndividualMapping() public {
        migrator.setMapping(1, 5);
        assertEq(migrator.indexMapping(1), 5);

        migrator.setMapping(2, 10);
        assertEq(migrator.indexMapping(2), 10);
    }

    // =========================================================================
    // 4. setMappings sets batch mappings correctly
    // =========================================================================

    function test_setMappings_setsBatchMappings() public {
        uint256[] memory v1Indexes = new uint256[](3);
        uint256[] memory v2Indexes = new uint256[](3);
        v1Indexes[0] = 1;
        v1Indexes[1] = 2;
        v1Indexes[2] = 3;
        v2Indexes[0] = 1;
        v2Indexes[1] = 2;
        v2Indexes[2] = 3;

        migrator.setMappings(v1Indexes, v2Indexes);

        assertEq(migrator.indexMapping(1), 1);
        assertEq(migrator.indexMapping(2), 2);
        assertEq(migrator.indexMapping(3), 3);
    }

    // =========================================================================
    // 5. setMappings reverts on array length mismatch
    // =========================================================================

    function test_setMappings_revertsOnLengthMismatch() public {
        uint256[] memory v1Indexes = new uint256[](2);
        uint256[] memory v2Indexes = new uint256[](3);
        v1Indexes[0] = 1;
        v1Indexes[1] = 2;
        v2Indexes[0] = 1;
        v2Indexes[1] = 2;
        v2Indexes[2] = 3;

        vm.expectRevert("NFTMigrator: array length mismatch");
        migrator.setMappings(v1Indexes, v2Indexes);
    }

    // =========================================================================
    // 6. setInitialized reverts when any mapping is missing
    // =========================================================================

    function test_setInitialized_revertsWhenMappingMissing() public {
        // Only set 2 of 3 mappings
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        // index 3 has no mapping

        vm.expectRevert("NFTMigrator: missing mapping");
        migrator.setInitialized();
    }

    // =========================================================================
    // 7. setInitialized succeeds when all V1 indexes have non-zero mappings
    // =========================================================================

    function test_setInitialized_succeedsWhenAllMapped() public {
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        migrator.setMapping(3, 3);

        migrator.setInitialized();

        assertTrue(migrator.initialized());
    }

    // =========================================================================
    // 8. migrate reverts when not initialized
    // =========================================================================

    function test_migrate_revertsWhenNotInitialized() public {
        vm.prank(user);
        vm.expectRevert("NFTMigrator: not initialized");
        migrator.migrate();
    }

    // =========================================================================
    // 9. migrate burns all V1 NFTs and mints correct V2 NFTs
    // =========================================================================

    function test_migrate_burnsV1AndMintsV2() public {
        // Mint 1 V1 NFT at index 1 for user
        _mintV1(user, 1, 1);
        assertEq(v1.balanceOf(user, 1), 1);

        // Configure migrator
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        migrator.setMapping(3, 3);
        migrator.setInitialized();

        // Migrate
        vm.prank(user);
        migrator.migrate();

        // V1 NFT burned
        assertEq(v1.balanceOf(user, 1), 0);
        // V2 NFT minted
        assertEq(v2.balanceOf(user, 1), 1);
    }

    // =========================================================================
    // 10. migrate handles user with balance > 1 at a single index
    // =========================================================================

    function test_migrate_handlesMultipleAtSingleIndex() public {
        // Mint 3 V1 NFTs at index 2 for user
        _mintV1(user, 2, 3);
        assertEq(v1.balanceOf(user, 2), 3);

        // Configure migrator (map V1 index 2 -> V2 index 2)
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        migrator.setMapping(3, 3);
        migrator.setInitialized();

        // Migrate
        vm.prank(user);
        migrator.migrate();

        // V1 burned
        assertEq(v1.balanceOf(user, 2), 0);
        // V2 minted 3 times (mintFor called 3 times)
        assertEq(v2.balanceOf(user, 2), 3);
    }

    // =========================================================================
    // 11. migrate handles user with NFTs at multiple indexes simultaneously
    // =========================================================================

    function test_migrate_handlesMultipleIndexes() public {
        // Mint V1 NFTs at indexes 1, 2, and 3
        _mintV1(user, 1, 2);
        _mintV1(user, 2, 1);
        _mintV1(user, 3, 3);

        // Configure migrator (remap: V1:1->V2:3, V1:2->V2:1, V1:3->V2:2)
        migrator.setMapping(1, 3);
        migrator.setMapping(2, 1);
        migrator.setMapping(3, 2);
        migrator.setInitialized();

        // Migrate
        vm.prank(user);
        migrator.migrate();

        // V1 all burned
        assertEq(v1.balanceOf(user, 1), 0);
        assertEq(v1.balanceOf(user, 2), 0);
        assertEq(v1.balanceOf(user, 3), 0);

        // V2 minted according to mapping
        assertEq(v2.balanceOf(user, 3), 2); // V1:1 (qty 2) -> V2:3
        assertEq(v2.balanceOf(user, 1), 1); // V1:2 (qty 1) -> V2:1
        assertEq(v2.balanceOf(user, 2), 3); // V1:3 (qty 3) -> V2:2
    }

    // =========================================================================
    // 12. migrate skips indexes where user has zero balance
    // =========================================================================

    function test_migrate_skipsZeroBalanceIndexes() public {
        // Mint V1 NFT only at index 2 (indexes 1 and 3 have zero balance)
        _mintV1(user, 2, 1);

        // Configure migrator
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        migrator.setMapping(3, 3);
        migrator.setInitialized();

        // Migrate
        vm.prank(user);
        migrator.migrate();

        // Index 2 migrated
        assertEq(v1.balanceOf(user, 2), 0);
        assertEq(v2.balanceOf(user, 2), 1);

        // Indexes 1 and 3 untouched (no V2 minted)
        assertEq(v2.balanceOf(user, 1), 0);
        assertEq(v2.balanceOf(user, 3), 0);
    }

    // =========================================================================
    // 13. migrate with user who has no V1 NFTs at all (no-op)
    // =========================================================================

    function test_migrate_noOpWhenUserHasNoNFTs() public {
        // Configure migrator
        migrator.setMapping(1, 1);
        migrator.setMapping(2, 2);
        migrator.setMapping(3, 3);
        migrator.setInitialized();

        // User has no V1 NFTs — migrate should not revert
        vm.prank(user2);
        migrator.migrate();

        // No V2 NFTs minted
        assertEq(v2.balanceOf(user2, 1), 0);
        assertEq(v2.balanceOf(user2, 2), 0);
        assertEq(v2.balanceOf(user2, 3), 0);
    }

    // =========================================================================
    // 14. Only owner can call setMapping, setMappings, setInitialized
    // =========================================================================

    function test_setMapping_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        migrator.setMapping(1, 1);
    }

    function test_setMappings_revertsForNonOwner() public {
        uint256[] memory v1Indexes = new uint256[](1);
        uint256[] memory v2Indexes = new uint256[](1);
        v1Indexes[0] = 1;
        v2Indexes[0] = 1;

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        migrator.setMappings(v1Indexes, v2Indexes);
    }

    function test_setInitialized_revertsForNonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        migrator.setInitialized();
    }

    // =========================================================================
    // 15. All tests pass with forge test (meta — validated by running forge test)
    // =========================================================================
    // This is validated by running `forge test` successfully.
}
