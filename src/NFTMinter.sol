// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenDispatcher} from "./interfaces/ITokenDispatcher.sol";
import {ATokenDispatcher} from "./dispatchers/ATokenDispatcher.sol";
import {ITokenMinter} from "./interfaces/ITokenMinter.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";

contract NFTMinter is ERC1155, Ownable, ITokenMinter, IPausable {
    /// @notice The single global claim NFT token ID.
    uint256 public constant CLAIM_TOKEN_ID = 1;

    /// @notice Configuration for a registered dispatcher.
    struct DispatcherConfig {
        address dispatcher; // TokenDispatcher contract address
        uint256 price; // current mint price in token units (18 decimals)
        uint256 growthBasisPoints; // price growth per mint in basis points (100 = 1%)
    }

    /// @notice Auto-incrementing dispatcher index (starts at 1 so 0 is invalid).
    uint256 public nextIndex = 1;

    /// @notice Maps dispatcher index to its configuration.
    mapping(uint256 => DispatcherConfig) public configs;

    /// @notice Maps dispatcher contract address to its index.
    mapping(address => uint256) public dispatcherToIndex;

    /// @notice Maps token address to array of dispatcher indexes registered for that token.
    mapping(address => uint256[]) internal _tokenToIndexes;

    /// @notice Emitted when a new dispatcher is registered.
    event DispatcherRegistered(
        uint256 indexed index, address indexed dispatcher, address indexed token, uint256 initialPrice, uint256 growthBasisPoints
    );

    /// @notice Emitted when a claim NFT is minted.
    event ClaimMinted(address indexed recipient, uint256 indexed dispatcherIndex, address indexed token, uint256 pricePaid);

    /// @notice Emitted when a dispatcher's price is updated.
    event PriceUpdated(uint256 indexed index, uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when a dispatcher's growth factor is updated.
    event GrowthFactorUpdated(uint256 indexed index, uint256 oldGrowthBasisPoints, uint256 newGrowthBasisPoints);

    /// @notice Emitted when the owner rescues stuck ERC20 tokens.
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a dispatcher's active state is changed.
    event DispatcherActiveChanged(address indexed dispatcher, bool active);

    /// @notice Emitted when the pauser address is changed.
    event PauserChanged(address indexed oldPauser, address indexed newPauser);

    /// @notice Emitted when the contract is paused.
    event Paused(address indexed triggeredBy);

    /// @notice Emitted when the contract is unpaused.
    event Unpaused(address indexed triggeredBy);

    /// @notice The address authorized to pause/unpause this contract via the Global Pauser.
    address public pauser;

    /// @notice Whether the contract is currently paused.
    bool public paused;

    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    /// @notice Sets the authorized pauser address. Only callable by owner.
    /// @param newPauser The new pauser address.
    function setPauser(address newPauser) external onlyOwner {
        address oldPauser = pauser;
        pauser = newPauser;
        emit PauserChanged(oldPauser, newPauser);
    }

    /// @notice Pauses the contract. Only callable by the authorized pauser.
    function pause() external {
        require(msg.sender == pauser, "Only pauser");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses the contract. Only callable by the authorized pauser.
    function unpause() external {
        require(msg.sender == pauser, "Only pauser");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc ITokenMinter
    function registerDispatcher(address dispatcher, uint256 initialPrice, uint256 growthBasisPoints) external onlyOwner {
        require(dispatcher != address(0), "NFTMinter: zero dispatcher address");
        require(dispatcherToIndex[dispatcher] == 0, "NFTMinter: dispatcher already registered");

        uint256 index = nextIndex;
        nextIndex++;

        // Read prime token from dispatcher
        address token = ITokenDispatcher(dispatcher).primeToken();

        // Store configuration
        configs[index] = DispatcherConfig({dispatcher: dispatcher, price: initialPrice, growthBasisPoints: growthBasisPoints});

        // Update mappings
        dispatcherToIndex[dispatcher] = index;
        _tokenToIndexes[token].push(index);

        emit DispatcherRegistered(index, dispatcher, token, initialPrice, growthBasisPoints);
    }

    /// @inheritdoc ITokenMinter
    function mint(address token, uint256 index, address recipient) external returns (bool) {
        require(!paused, "Contract is paused");
        DispatcherConfig storage config = configs[index];
        require(config.dispatcher != address(0), "NFTMinter: index not registered");

        // Sanity check: token address must match dispatcher's primeToken
        address dispatcherToken = ITokenDispatcher(config.dispatcher).primeToken();
        require(dispatcherToken == token, "NFTMinter: token mismatch");

        uint256 price = config.price;

        // Transfer tokens directly from user to dispatcher (balance-before/after for FOT safety)
        uint256 balanceBefore = IERC20(token).balanceOf(config.dispatcher);
        IERC20(token).transferFrom(msg.sender, config.dispatcher, price);
        uint256 actualReceived = IERC20(token).balanceOf(config.dispatcher) - balanceBefore;

        // Grow price: newPrice = oldPrice + (oldPrice * growthBasisPoints / 10000)
        // Updated before dispatch to follow checks-effects-interactions pattern
        config.price = price + (price * config.growthBasisPoints) / 10000;

        // Invoke the dispatcher with actual received amount (dispatch is on ATokenDispatcher with whenNotPaused guard)
        ATokenDispatcher(config.dispatcher).dispatch(address(this), actualReceived);

        // Mint 1 claim NFT to recipient
        _mint(recipient, CLAIM_TOKEN_ID, 1, "");

        emit ClaimMinted(recipient, index, token, price);

        return true;
    }

    /// @inheritdoc ITokenMinter
    function getFlavour(uint256 index) external view returns (string memory) {
        require(configs[index].dispatcher != address(0), "NFTMinter: index not registered");
        return ITokenDispatcher(configs[index].dispatcher).flavour();
    }

    /// @inheritdoc ITokenMinter
    function getPrice(uint256 index) external view returns (uint256) {
        require(configs[index].dispatcher != address(0), "NFTMinter: index not registered");
        return configs[index].price;
    }

    /// @inheritdoc ITokenMinter
    function getDispatchers(address token) external view returns (uint256[] memory) {
        return _tokenToIndexes[token];
    }

    /// @inheritdoc ITokenMinter
    function setPrice(uint256 index, uint256 newPrice) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinter: index not registered");
        uint256 oldPrice = configs[index].price;
        configs[index].price = newPrice;
        emit PriceUpdated(index, oldPrice, newPrice);
    }

    /// @inheritdoc ITokenMinter
    function setGrowthFactor(uint256 index, uint256 newGrowthBasisPoints) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinter: index not registered");
        uint256 oldGrowthBasisPoints = configs[index].growthBasisPoints;
        configs[index].growthBasisPoints = newGrowthBasisPoints;
        emit GrowthFactorUpdated(index, oldGrowthBasisPoints, newGrowthBasisPoints);
    }

    /// @notice Rescues any ERC20 token stuck in this contract. Only callable by owner.
    /// @param token The ERC20 token address to withdraw.
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "NFTMinter: no tokens to withdraw");
        IERC20(token).transfer(msg.sender, balance);
        emit EmergencyWithdraw(token, msg.sender, balance);
    }

    /// @notice Pauses or unpauses a registered dispatcher. Only callable by owner.
    /// @param dispatcher The dispatcher contract address.
    /// @param active If true, unpauses the dispatcher; if false, pauses it.
    function setDispatcherActive(address dispatcher, bool active) external onlyOwner {
        require(dispatcherToIndex[dispatcher] != 0, "NFTMinter: dispatcher not registered");

        ATokenDispatcher dispatcherContract = ATokenDispatcher(dispatcher);

        if (active) {
            // Only unpause if currently paused, to avoid revert from ExpectedPause()
            if (dispatcherContract.paused()) {
                dispatcherContract.unpause();
            }
        } else {
            // Only pause if currently not paused, to avoid revert from EnforcedPause()
            if (!dispatcherContract.paused()) {
                dispatcherContract.pause();
            }
        }

        emit DispatcherActiveChanged(dispatcher, active);
    }
}
