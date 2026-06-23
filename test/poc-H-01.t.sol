// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTMinterV2} from "../src/NFTMinterV2.sol";
import {GatherV2} from "../src/dispatchers/GatherV2.sol";
import {ITokenDispatcherV2} from "../src/interfaces/ITokenDispatcherV2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockFOTToken} from "./mocks/MockFOTToken.sol";

/// @dev MaliciousERC20 whose balanceOf returns 0 and transferFrom returns true without moving tokens.
/// This is the token an attacker would use in the H-01 exploit path.
contract MaliciousERC20 is ERC20 {
    constructor() ERC20("Malicious", "MAL") {}

    function balanceOf(address) public pure override returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return true;
    }
}

/// @dev Legitimate ERC20 for testing positive paths.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title H01RegressionTest
/// @notice Proves that the H-01 exploit (arbitrary token spoofing) is structurally impossible
///         after the primeToken invariant was restored.
contract H01RegressionTest is Test {
    NFTMinterV2 public minter;
    GatherV2 public gather;
    MockERC20 public legitimateToken;
    MaliciousERC20 public maliciousToken;

    address public owner = address(this);
    address public attacker = address(0xDEAD);
    address public gatherRecipient = address(0xFEED);

    function setUp() public {
        minter = new NFTMinterV2(owner);
        legitimateToken = new MockERC20("Legit", "LGT");
        maliciousToken = new MaliciousERC20();

        gather = new GatherV2(address(legitimateToken), gatherRecipient, owner);
        gather.setMinter(address(minter));
        minter.registerDispatcher(address(gather), 10e18, 0);
    }

    /// @notice The H-01 exploit is structurally impossible: mint() no longer accepts a token parameter.
    /// The attacker cannot pass a malicious token. The dispatcher's primeToken() is always used.
    /// Here we verify that an attacker who only has malicious tokens and no legitimate tokens
    /// cannot mint, because the minter always pulls the legitimate prime token.
    function test_H01_attackerCannotMintWithMaliciousToken() public {
        // Attacker has no legitimate tokens, only malicious tokens
        assertEq(legitimateToken.balanceOf(attacker), 0);

        // Attacker approves the minter for the legitimate token (but has 0 balance)
        vm.prank(attacker);
        legitimateToken.approve(address(minter), type(uint256).max);

        // The mint will revert because the minter fetches legitimateToken from the dispatcher
        // and tries safeTransferFrom — attacker has 0 balance of the legitimate token.
        vm.prank(attacker);
        vm.expectRevert(); // ERC20InsufficientBalance
        minter.mint(1, attacker);
    }

    /// @notice The mint function signature no longer accepts a token address parameter.
    /// This test verifies that the old 3-parameter mint(address,uint256,address) signature
    /// does not exist — calling it would be a compile error. We verify the new signature works.
    function test_H01_mintSignatureDropsTokenParameter() public {
        // Give user legitimate tokens and approve
        legitimateToken.mint(attacker, 100e18);
        vm.prank(attacker);
        legitimateToken.approve(address(minter), type(uint256).max);

        // New signature: mint(uint256 index, address recipient) — no token parameter
        vm.prank(attacker);
        bool success = minter.mint(1, attacker);
        assertTrue(success, "mint with new signature should succeed");
        assertEq(minter.balanceOf(attacker, 1), 1, "Attacker should have 1 NFT (paid legitimately)");
    }

    /// @notice Positive test: ClaimMinted event emits the dispatcher's primeToken, not a user-supplied one.
    function test_H01_claimMintedEmitsDispatcherPrimeToken() public {
        legitimateToken.mint(attacker, 100e18);
        vm.prank(attacker);
        legitimateToken.approve(address(minter), type(uint256).max);

        // The ClaimMinted event should emit address(legitimateToken) as the token
        vm.expectEmit(true, true, true, true);
        emit NFTMinterV2.ClaimMinted(attacker, 1, address(legitimateToken), 10e18);

        vm.prank(attacker);
        minter.mint(1, attacker);
    }

    /// @notice Verify that the dispatcher's primeToken matches what the minter uses.
    function test_H01_dispatcherPrimeTokenIsUsed() public {
        address dispatcherPrime = ITokenDispatcherV2(address(gather)).primeToken();
        assertEq(dispatcherPrime, address(legitimateToken), "Dispatcher primeToken should be the legitimate token");
    }

    /// @notice FOT accounting still works correctly after the fix.
    function test_H01_FOTAccountingWorksPostFix() public {
        // Create FOT token and a new gather dispatcher for it
        MockFOTToken fotToken = new MockFOTToken("FOT Token", "FOT", 200); // 2% fee
        GatherV2 fotGather = new GatherV2(address(fotToken), gatherRecipient, owner);
        fotGather.setMinter(address(minter));
        minter.registerDispatcher(address(fotGather), 100e18, 0);

        // Give user FOT tokens and approve
        fotToken.mint(attacker, 1000e18);
        vm.prank(attacker);
        fotToken.approve(address(minter), type(uint256).max);

        // Mint — the minter fetches fotToken from the dispatcher's primeToken()
        vm.prank(attacker);
        bool success = minter.mint(2, attacker);
        assertTrue(success, "FOT mint should succeed");
        assertEq(minter.balanceOf(attacker, 2), 1, "Attacker should have 1 NFT");

        // FOT accounting: user loses exactly price (100e18), but dispatcher receives less due to fee
        assertEq(fotToken.balanceOf(attacker), 1000e18 - 100e18, "User should have lost exactly price");

        // The gather recipient should have received the tokens (minus both transfer fees)
        // Transfer 1: user -> gather (2% fee on 100e18 = 2e18 burned, 98e18 arrives at gather)
        // Transfer 2: gather -> gatherRecipient (2% fee on 98e18 = 1.96e18 burned, 96.04e18 arrives)
        assertEq(fotToken.balanceOf(gatherRecipient), 96.04e18, "Recipient should have received FOT-adjusted amount");
    }
}
