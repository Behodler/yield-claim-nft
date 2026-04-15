// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ITokenDispatcherV2} from "./interfaces/ITokenDispatcherV2.sol";
import {ATokenDispatcherV2} from "./dispatchers/ATokenDispatcherV2.sol";
import {INFTMinterV2} from "./interfaces/INFTMinterV2.sol";
import {ITokenMinterV2} from "./interfaces/ITokenMinterV2.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";

contract NFTMinterV2 is ERC1155Supply, Ownable, INFTMinterV2, IPausable {
    using SafeERC20 for IERC20;

    /// @notice Configuration for a registered dispatcher.
    struct DispatcherConfig {
        address dispatcher; // TokenDispatcher contract address
        uint256 price; // current mint price in token units (18 decimals)
        uint256 growthBasisPoints; // price growth per mint in basis points (100 = 1%)
        bool disabled; // if true, new mints are blocked but existing NFTs remain valid
    }

    /// @notice Auto-incrementing dispatcher index (starts at 1 so 0 is invalid).
    uint256 public nextIndex = 1;

    /// @notice Maps dispatcher index to its configuration.
    mapping(uint256 => DispatcherConfig) public configs;

    /// @notice Maps dispatcher contract address to its index.
    mapping(address => uint256) public dispatcherToIndex;

    /// @notice Reverse lookup: maps token ID to the dispatcher address that produces it.
    mapping(uint256 => address) public tokenIdToDispatcher;

    /// @notice Maps addresses to whether they are authorized to burn NFTs.
    mapping(address => bool) public authorizedBurners;

    /// @notice Maps addresses to whether they are authorized to mint NFTs via mintFor().
    mapping(address => bool) public authorizedMinters;

    /// @notice Emitted when a new dispatcher is registered.
    event DispatcherRegistered(
        uint256 indexed index, address indexed dispatcher, uint256 initialPrice, uint256 growthBasisPoints
    );

    /// @notice Emitted when a claim NFT is minted.
    event ClaimMinted(
        address indexed recipient, uint256 indexed dispatcherIndex, address indexed token, uint256 pricePaid
    );

    /// @notice Emitted when a claim NFT is minted via mintFor().
    event ClaimMintedFor(address indexed recipient, uint256 indexed dispatcherIndex, address indexed minter);

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

    /// @notice Emitted when a dispatcher's disabled state is changed.
    event DispatcherDisabledChanged(uint256 indexed index, bool disabled);

    /// @notice Emitted when an authorized burner is set or unset.
    event AuthorizedBurnerSet(address indexed burner, bool authorized);

    /// @notice Emitted when an authorized minter is set or unset.
    event AuthorizedMinterSet(address indexed minter, bool authorized);

    /// @notice Emitted when a claim NFT is burned.
    event ClaimBurned(address indexed holder, uint256 indexed tokenId, uint256 quantity);

    /// @notice Emitted when a dispatcher is replaced at an existing index.
    event DispatcherReplaced(uint256 indexed index, address indexed oldDispatcher, address indexed newDispatcher);

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

    /// @inheritdoc ITokenMinterV2
    function registerDispatcher(address dispatcher, uint256 initialPrice, uint256 growthBasisPoints)
        external
        onlyOwner
    {
        require(dispatcher != address(0), "NFTMinterV2: zero dispatcher address");
        require(dispatcherToIndex[dispatcher] == 0, "NFTMinterV2: dispatcher already registered");

        uint256 index = nextIndex;
        nextIndex++;

        // Store configuration
        configs[index] = DispatcherConfig({
            dispatcher: dispatcher, price: initialPrice, growthBasisPoints: growthBasisPoints, disabled: false
        });

        // Update mappings
        dispatcherToIndex[dispatcher] = index;

        // Set default token ID mapping (index -> dispatcher)
        tokenIdToDispatcher[index] = dispatcher;

        emit DispatcherRegistered(index, dispatcher, initialPrice, growthBasisPoints);
    }

    /// @notice Enables or disables minting for a dispatcher. Only callable by owner.
    /// @param index The dispatcher index.
    /// @param disabled If true, new mints are blocked; if false, mints are re-enabled.
    function setDispatcherDisabled(uint256 index, bool disabled) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");
        configs[index].disabled = disabled;
        emit DispatcherDisabledChanged(index, disabled);
    }

    /// @inheritdoc ITokenMinterV2
    function mint(uint256 index, address recipient) external returns (bool) {
        return _executeMint(index, recipient, "");
    }

    /// @inheritdoc ITokenMinterV2
    function mint(uint256 index, address recipient, bytes calldata extraData) external returns (bool) {
        return _executeMint(index, recipient, extraData);
    }

    /// @dev Shared internal implementation for both mint() overloads.
    /// Fetches the authoritative prime token from the dispatcher to prevent token spoofing (H-01 fix).
    function _executeMint(uint256 index, address recipient, bytes memory extraData) internal returns (bool) {
        require(!paused, "Contract is paused");
        DispatcherConfig storage config = configs[index];
        require(config.dispatcher != address(0), "NFTMinterV2: index not registered");
        require(!config.disabled, "NFTMinterV2: dispatcher is disabled");

        // Fetch the authoritative prime token from the dispatcher (H-01 fix: caller cannot specify token)
        address token = ITokenDispatcherV2(config.dispatcher).primeToken();

        uint256 price = config.price;

        // Transfer tokens directly from user to dispatcher (balance-before/after for FOT safety)
        uint256 balanceBefore = IERC20(token).balanceOf(config.dispatcher);
        IERC20(token).safeTransferFrom(msg.sender, config.dispatcher, price);
        uint256 actualReceived = IERC20(token).balanceOf(config.dispatcher) - balanceBefore;

        // Grow price: newPrice = oldPrice + (oldPrice * growthBasisPoints / 10000)
        // Updated before dispatch to follow checks-effects-interactions pattern
        config.price = price + (price * config.growthBasisPoints) / 10000;

        // Invoke the dispatcher with actual received amount (dispatch is on ATokenDispatcherV2 with whenNotPaused guard)
        ATokenDispatcherV2(config.dispatcher).dispatch(address(this), actualReceived, extraData);

        uint256 resolvedTokenId = index;

        // Mint 1 claim NFT to recipient
        _mint(recipient, resolvedTokenId, 1, "");

        emit ClaimMinted(recipient, index, token, price);

        return true;
    }

    /// @notice Mints a claim NFT to a recipient without payment or dispatch. Only callable by authorized minters.
    /// @param index The dispatcher index (must be registered).
    /// @param recipient The address that receives the claim NFT.
    function mintFor(uint256 index, address recipient) external {
        require(authorizedMinters[msg.sender], "NFTMinterV2: caller is not authorized minter");
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");

        // Mint 1 claim NFT to recipient — no payment, no dispatch, no price update
        _mint(recipient, index, 1, "");

        emit ClaimMintedFor(recipient, index, msg.sender);
    }

    /// @notice Sets or removes an address as an authorized minter. Only callable by owner.
    /// @param minter The address to authorize or deauthorize.
    /// @param authorized Whether the address is authorized to mint via mintFor().
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
        emit AuthorizedMinterSet(minter, authorized);
    }

    /// @notice Replaces the dispatcher at an existing index. Only callable by owner.
    /// @param index The dispatcher index (must already be registered).
    /// @param newDispatcher The new dispatcher contract address.
    function replaceDispatcher(uint256 index, address newDispatcher) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");
        require(
            dispatcherToIndex[newDispatcher] == 0 || dispatcherToIndex[newDispatcher] == index,
            "NFTMinterV2: new dispatcher already registered elsewhere"
        );

        address oldDispatcher = configs[index].dispatcher;

        // Update config
        configs[index].dispatcher = newDispatcher;

        // Update dispatcherToIndex: clear old, set new
        delete dispatcherToIndex[oldDispatcher];
        dispatcherToIndex[newDispatcher] = index;

        // Update tokenIdToDispatcher
        tokenIdToDispatcher[index] = newDispatcher;

        emit DispatcherReplaced(index, oldDispatcher, newDispatcher);
    }

    /// @notice Returns metadata JSON for a given token ID by looking up its mapped dispatcher.
    /// @param id The token ID.
    /// @return The metadata JSON string, or empty string if no dispatcher is mapped.
    function uri(uint256 id) public view override returns (string memory) {
        address dispatcher = tokenIdToDispatcher[id];
        if (dispatcher == address(0)) {
            return "";
        }

        string memory dispatcherName = ITokenDispatcherV2(dispatcher).name();
        string memory dispatcherImage = ITokenDispatcherV2(dispatcher).image();
        string memory dispatcherDescription = ITokenDispatcherV2(dispatcher).description();

        return string(
            abi.encodePacked(
                '{"name":"',
                dispatcherName,
                '","image":"',
                dispatcherImage,
                '","description":"',
                dispatcherDescription,
                '"}'
            )
        );
    }

    /// @inheritdoc ITokenMinterV2
    function getPrice(uint256 index) external view returns (uint256) {
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");
        return configs[index].price;
    }

    /// @inheritdoc ITokenMinterV2
    function setPrice(uint256 index, uint256 newPrice) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");
        uint256 oldPrice = configs[index].price;
        configs[index].price = newPrice;
        emit PriceUpdated(index, oldPrice, newPrice);
    }

    /// @inheritdoc ITokenMinterV2
    function setGrowthFactor(uint256 index, uint256 newGrowthBasisPoints) external onlyOwner {
        require(configs[index].dispatcher != address(0), "NFTMinterV2: index not registered");
        uint256 oldGrowthBasisPoints = configs[index].growthBasisPoints;
        configs[index].growthBasisPoints = newGrowthBasisPoints;
        emit GrowthFactorUpdated(index, oldGrowthBasisPoints, newGrowthBasisPoints);
    }

    /// @notice Rescues any ERC20 token stuck in this contract. Only callable by owner.
    /// @param token The ERC20 token address to withdraw.
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "NFTMinterV2: no tokens to withdraw");
        IERC20(token).transfer(msg.sender, balance);
        emit EmergencyWithdraw(token, msg.sender, balance);
    }

    /// @notice Pauses or unpauses a registered dispatcher. Only callable by owner.
    /// @param dispatcher The dispatcher contract address.
    /// @param active If true, unpauses the dispatcher; if false, pauses it.
    function setDispatcherActive(address dispatcher, bool active) external onlyOwner {
        require(dispatcherToIndex[dispatcher] != 0, "NFTMinterV2: dispatcher not registered");

        ATokenDispatcherV2 dispatcherContract = ATokenDispatcherV2(dispatcher);

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

    /// @notice Sets or removes an address as an authorized burner. Only callable by owner.
    /// @param burner The address to authorize or deauthorize.
    /// @param authorized Whether the address is authorized to burn.
    function setAuthorizedBurner(address burner, bool authorized) external onlyOwner {
        authorizedBurners[burner] = authorized;
        emit AuthorizedBurnerSet(burner, authorized);
    }

    /// @notice Burns claim NFTs from a holder. Only callable by authorized burners.
    /// @param holder The address holding the NFTs to burn.
    /// @param tokenId The token ID to burn.
    /// @param quantity The number of tokens to burn.
    function burn(address holder, uint256 tokenId, uint256 quantity) external {
        require(authorizedBurners[msg.sender], "NFTMinterV2: caller is not authorized burner");
        _burn(holder, tokenId, quantity);
        emit ClaimBurned(holder, tokenId, quantity);
    }
}
