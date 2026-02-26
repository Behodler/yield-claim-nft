// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPauser
 * @notice Interface for the Global Pauser contract
 * @dev This interface enables dependency injection in downstream projects that need pause functionality
 *      Pausable contracts can reference IPauser without depending on the concrete Pauser implementation
 */
interface IPauser {
    // ============ EVENTS ============

    /**
     * @notice Emitted when a pause is triggered
     * @param triggeredBy Address that triggered the pause
     * @param eyeBurned Amount of EYE tokens burned
     */
    event PauseTriggered(address indexed triggeredBy, uint256 eyeBurned);

    /**
     * @notice Emitted when unpause is triggered
     * @param triggeredBy Address that triggered the unpause (should be owner)
     */
    event UnpauseTriggered(address indexed triggeredBy);

    /**
     * @notice Emitted when a contract is registered
     * @param pausableContract Address of the registered contract
     */
    event ContractRegistered(address indexed pausableContract);

    /**
     * @notice Emitted when a contract is unregistered
     * @param pausableContract Address of the unregistered contract
     */
    event ContractUnregistered(address indexed pausableContract);

    /**
     * @notice Emitted when configuration is updated
     * @param newEyeBurnAmount New EYE burn amount
     * @param newEyeToken New EYE token address
     */
    event ConfigUpdated(uint256 newEyeBurnAmount, address newEyeToken);

    // ============ FUNCTIONS ============

    /**
     * @notice Trigger a pause on all registered contracts by burning EYE tokens
     * @dev Anyone can call this function if they have enough EYE tokens
     *      The EYE tokens will be burned from the caller's balance
     */
    function pause() external;

    /**
     * @notice Unpause all registered contracts
     * @dev Only the owner can call this function to ensure controlled recovery
     */
    function unpause() external;

    /**
     * @notice Register a pausable contract
     * @dev Only the owner can register contracts
     * @param pausableContract Address of the contract to register
     */
    function register(address pausableContract) external;

    /**
     * @notice Unregister a pausable contract
     * @dev Only the owner can unregister contracts
     * @param pausableContract Address of the contract to unregister
     */
    function unregister(address pausableContract) external;

    /**
     * @notice Get all registered pausable contracts
     * @return Array of pausable contract addresses
     */
    function getPausableContracts() external view returns (address[] memory);

    /**
     * @notice Get the EYE burn amount required to trigger pause
     * @return Amount of EYE tokens required
     */
    function eyeBurnAmount() external view returns (uint256);

    /**
     * @notice Get the EYE token address
     * @return Address of the EYE token contract
     */
    function eyeToken() external view returns (address);
}
