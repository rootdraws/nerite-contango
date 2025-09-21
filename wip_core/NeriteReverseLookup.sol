// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "../libraries/DataTypes.sol";
import "./dependencies/IBorrowerOperations.sol";
import "./dependencies/ITroveManager.sol";

import "./dependencies/LatestTroveData.sol"; 
import "./dependencies/LatestBatchData.sol"; 

// Add these imports to satisfy transitive dependencies:
import "./dependencies/ILiquityBase.sol";        // Required by IBorrowerOperations & ITroveManager
import "./dependencies/IAddRemoveManagers.sol";  // Required by IBorrowerOperations
import "./dependencies/IStabilityPool.sol";      // Required by ITroveManager
import "./dependencies/IInterestRouter.sol";     // Required by IActivePool (via ITroveManager)
import "./dependencies/IBoldRewardsReceiver.sol"; // Required by IActivePool (via ITroveManager)
import "./dependencies/IWETH.sol";               // Required by IBorrowerOperations
import "./dependencies/ITroveNFT.sol";           // Required by ITroveManager
import "./dependencies/ISortedTroves.sol";       // Required by ITroveManager
import "./dependencies/IBoldToken.sol";          // Required by ITroveManager
import "./dependencies/TroveChange.sol";         // Required by ITroveManager
import "./dependencies/BatchId.sol";             // Required by ISortedTroves
import "./dependencies/IActivePool.sol";         // Required by ITroveManager
import "./dependencies/IPriceFeed.sol";          // Required by IBorrowerOperations
import "./dependencies/IHintHelpers.sol";        // Required by IBorrowerOperations


/**
 * @title NeriteReverseLookup
 * @notice Maps Contango position payloads to Nerite trove IDs
 * @dev Follows the Comet/Euler/Morpho pattern since Nerite uses individual troves like individual markets
 * 
 * ARCHITECTURE:
 * - Bidirectional mapping: PositionId ↔ TroveId with O(1) lookups
 * - Sequential payload assignment for gas efficiency 
 * - Access control: OPERATOR_ROLE for Contango contracts, DEFAULT_ADMIN_ROLE for governance
 * - Integration with Nerite's batch management system
 * - Full compatibility with ContangoLens and position management
 *
 * Based on comprehensive Phase 1 & 2 analysis confirming Nerite requires reverse lookup
 * due to individual trove architecture + NFT tokenization + batch management complexity.
 */
 
contract NeriteReverseLookup is AccessControl {
    using DataTypes for PositionId;

    // Add role definition:
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Sequential payload assignment
    uint40 public nextPayload = 1;

    // Bidirectional mapping between Contango positions and Nerite troves
    mapping(Payload payload => uint256 troveId) public troveIds;
    mapping(uint256 troveId => Payload payload) public payloads;

    // Nerite protocol contracts for validation
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;

    // Events
    event TroveSet(Payload indexed payload, uint256 indexed troveId);
    event TroveUnset(Payload indexed payload, uint256 indexed troveId);

    // Errors
    error TroveAlreadySet(uint256 troveId);
    error PayloadAlreadySet(Payload payload);
    error TroveNotFound(Payload payload);
    error InvalidTroveId(uint256 troveId);
    error TroveNotActive(uint256 troveId);
    error InvalidPayload(Payload payload);

    /**
     * @notice Constructor
     * @param _borrowerOperations Nerite BorrowerOperations contract
     * @param _troveManager Nerite TroveManager contract
     * @param _timelock Timelock contract for admin role
     */
    constructor(
        IBorrowerOperations _borrowerOperations,
        ITroveManager _troveManager,
        address _timelock
    ) {
        borrowerOperations = _borrowerOperations;
        troveManager = _troveManager;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _timelock);
        _grantRole(OPERATOR_ROLE, _timelock);
    }

    /**
     * ╔══════════════════════════════════════════════════════════════════════════════════╗
     * ║                        POST-DEPLOYMENT ROLE ASSIGNMENT                          ║
     * ╚══════════════════════════════════════════════════════════════════════════════════╝
     * 
     * After deploying NeriteMoneyMarket, grant OPERATOR_ROLE:
     * 
     * reverseLookup.grantRole(OPERATOR_ROLE, address(neriteMoneyMarket));
     * 
     * This allows the MoneyMarket contract to call setTrove() during position creation.
     */

    /**
     * @notice Maps a Nerite trove ID to a new Contango position payload
     * @param _troveId The Nerite trove ID to map
     * @return payload The assigned payload for the trove
     * @dev Only callable by operators (typically Contango contracts)
     */
    function setTrove(uint256 _troveId) external onlyRole(OPERATOR_ROLE) returns (Payload payload) {
        // Validate trove exists and is active
        ITroveManager.Status status = troveManager.getTroveStatus(_troveId);
        if (status == ITroveManager.Status.nonExistent) {
            revert InvalidTroveId(_troveId);
        }
        if (status != ITroveManager.Status.active && status != ITroveManager.Status.zombie) {
            revert TroveNotActive(_troveId);
        }

        // Check if trove is already mapped
        if (payloads[_troveId] != Payload.wrap(0)) {
            revert TroveAlreadySet(_troveId);
        }

        // Assign next available payload
        payload = Payload.wrap(nextPayload++);
        
        // Check for payload collision (extremely unlikely but safe)
        if (troveIds[payload] != 0) {
            revert PayloadAlreadySet(payload);
        }

        // Create bidirectional mapping
        troveIds[payload] = _troveId;
        payloads[_troveId] = payload;

        emit TroveSet(payload, _troveId);
    }

    /**
     * @notice Gets the Nerite trove ID for a given Contango position payload
     * @param _payload The Contango position payload
     * @return troveId The corresponding Nerite trove ID
     */
    function troveId(Payload _payload) external view returns (uint256 troveId) {
        troveId = troveIds[_payload];
        if (troveId == 0) {
            revert TroveNotFound(_payload);
        }
    }

    /**
     * @notice Gets the Contango position payload for a given Nerite trove ID
     * @param _troveId The Nerite trove ID
     * @return payload The corresponding Contango position payload
     */
    function payload(uint256 _troveId) external view returns (Payload payload) {
        payload = payloads[_troveId];
        // Note: Returns Payload.wrap(0) if not found, which is valid for checking
    }

    /**
     * @notice Checks if a trove ID is mapped to a payload
     * @param _troveId The Nerite trove ID to check
     * @return mapped True if the trove is mapped
     */
    function isTroveMapped(uint256 _troveId) external view returns (bool mapped) {
        return payloads[_troveId] != Payload.wrap(0);
    }

    /**
     * @notice Checks if a payload is mapped to a trove ID
     * @param _payload The Contango position payload to check
     * @return mapped True if the payload is mapped
     */
    function isPayloadMapped(Payload _payload) external view returns (bool mapped) {
        return troveIds[_payload] != 0;
    }

    /**
     * @notice Gets the current number of mapped troves
     * @return count The number of mapped troves
     */
    function getMappedTroveCount() external view returns (uint256 count) {
        // nextPayload starts at 1, so count is nextPayload - 1
        return nextPayload - 1;
    }

    /**
     * @notice Gets the Contango position ID for a given Nerite trove ID
     * @param _troveId The Nerite trove ID
     * @return positionId The corresponding Contango position ID
     */
    function positionId(uint256 _troveId) external view returns (PositionId positionId) {
        Payload payload = payloads[_troveId];
        if (payload == Payload.wrap(0)) {
            return PositionId.wrap(0);
        }
        return PositionId.wrap(bytes32(uint256(payload)));
    }

    /**
     * @notice Gets the trove ID for a position ID (convenience function)
     * @param _positionId The Contango position ID
     * @return troveId The corresponding Nerite trove ID
     */
    function getTroveId(PositionId _positionId) external view returns (uint256 troveId) {
        Payload payload = Payload.wrap(_positionId.getPayload());
        return troveIds[payload];
    }

    /**
     * @notice Gets batch information for a trove
     * @param _troveId The Nerite trove ID
     * @return batchManager The batch manager address (address(0) if not in batch)
     */
    function getBatchManager(uint256 _troveId) external view returns (address batchManager) {
        batchManager = borrowerOperations.interestBatchManagerOf(_troveId);
    }

    /**
     * @notice Checks if trove is in a batch
     * @param _troveId The Nerite trove ID
     * @return inBatch True if trove is in a batch
     */
    function isTroveInBatch(uint256 _troveId) external view returns (bool inBatch) {
        return borrowerOperations.interestBatchManagerOf(_troveId) != address(0);
    }

    /**
     * @notice Validates trove exists and is active
     * @param _troveId The trove ID to validate
     * @return isValid True if trove is valid and active
     */
    function validateTrove(uint256 _troveId) external view returns (bool isValid) {
        ITroveManager.Status status = troveManager.getTroveStatus(_troveId);
        return (status != ITroveManager.Status.nonExistent && status == ITroveManager.Status.active);
    }

    /**
     * @notice Emergency function to remove a mapping (admin only)
     * @param _troveId The trove ID to unmap
     * @dev Should only be used in extreme circumstances
     */
    function removeTroveMapping(uint256 _troveId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Payload payload = payloads[_troveId];
        if (payload == Payload.wrap(0)) {
            revert TroveNotFound(payload);
        }

        delete troveIds[payload];
        delete payloads[_troveId];

        emit TroveUnset(payload, _troveId);
    }

    // ========================================
    // INTEGRATION UTILITY FUNCTIONS
    // ========================================

    /**
     * @notice Checks if a trove mapping is valid and trove is still active
     * @param _troveId The Nerite trove ID
     * @return isValid True if mapping exists and trove is active
     */
    function isValidMapping(uint256 _troveId) external view returns (bool isValid) {
        if (payloads[_troveId] == Payload.wrap(0)) {
            return false; // No mapping exists
        }
        return validateTrove(_troveId);
    }

    /**
     * @notice Gets all mapping information for a trove ID
     * @param _troveId The Nerite trove ID
     * @return payload The mapped payload
     * @return positionId The corresponding position ID
     * @return isValid Whether the mapping is valid
     * @return inBatch Whether the trove is in a batch
     * @return batchManager The batch manager address (if in batch)
     */
    function getMappingInfo(uint256 _troveId) 
        external 
        view 
        returns (
            Payload payload,
            PositionId positionId,
            bool isValid,
            bool inBatch,
            address batchManager
        )
    {
        payload = payloads[_troveId];
        
        if (payload == Payload.wrap(0)) {
            return (Payload.wrap(0), PositionId.wrap(0), false, false, address(0));
        }
        
        positionId = PositionId.wrap(bytes32(uint256(payload)));
        isValid = validateTrove(_troveId);
        batchManager = borrowerOperations.interestBatchManagerOf(_troveId);
        inBatch = batchManager != address(0);
    }
}
