// contracts/Messages.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

interface IWormhole {
    struct GuardianSet {
        address[] keys;
        uint32 expirationTime;
    }

    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct Header {
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    struct IndexedObservation {
        // Index of the observation in the batch
        uint8 index;
        // Headless VM3 parsed into the VM struct
        VM vm3;
    }

    struct VM {
        uint8 version; // version = 1 or 3
        // The following fields constitute an Observation. For compatibility
        // reasons we keep the representation inlined.
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        // End of observation

        // The following fields constitute a Header. For compatibility
        // reasons we keep the representation inlined.
        uint32 guardianSetIndex;
        Signature[] signatures;
        // Computed value
        bytes32 hash;
    }

    struct VM2 {
        uint8 version; // version = 2
        // Inlined Header
        uint32 guardianSetIndex;
        Signature[] signatures;
        // Array of Observation hashes
        bytes32[] hashes;
        // Computed batch hash - hash(hash(Observation1), hash(Observation2), ...)
        bytes32 hash;
        // Array of observations with prepended version 3
        bytes[] observations;
    }

    event LogMessagePublished(
        address indexed sender, uint64 sequence, uint32 nonce, bytes payload, uint8 consistencyLevel
    );

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence);

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VM memory vm, bool valid, string memory reason);

    function parseAndVerifyBatchVM(bytes calldata encodedVM, bool cache)
        external
        returns (VM2 memory vm, bool valid, string memory reason);

    function verifyVM(VM memory vm) external view returns (bool valid, string memory reason);

    function verifyBatchVM(VM2 memory vm, bool cache) external returns (bool valid, string memory reason);

    function verifySignatures(bytes32 hash, Signature[] memory signatures, GuardianSet memory guardianSet)
        external
        pure
        returns (bool valid, string memory reason);

    function clearBatchCache(bytes32[] memory hashesToClear) external;

    function parseVM(bytes memory encodedVM) external pure returns (VM memory vm);

    function parseBatchVM(bytes memory encodedVM) external pure returns (VM2 memory vm);

    function getGuardianSet(uint32 index) external view returns (GuardianSet memory);

    function getCurrentGuardianSetIndex() external view returns (uint32);

    function getGuardianSetExpiry() external view returns (uint32);

    function governanceActionIsConsumed(bytes32 hash) external view returns (bool);

    function isInitialized(address impl) external view returns (bool);

    function chainId() external view returns (uint16);

    function governanceChainId() external view returns (uint16);

    function governanceContract() external view returns (bytes32);

    function messageFee() external view returns (uint256);
}
