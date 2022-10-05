// contracts/mock/MockBatchedVAASender.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../libraries/external/BytesLib.sol";
import "../interfaces/IWormhole.sol";
import "../interfaces/ICoreRelayer.sol";

contract MockRelayerIntegration {
    using BytesLib for bytes;

    // wormhole instance on this chain
    IWormhole immutable wormhole;

    // trusted relayer contract on this chain
    ICoreRelayer immutable relayer;

    // deployer of this contract
    address immutable owner;

    // trusted mock integration contracts
    mapping(uint16 => bytes32) trustedSenders;

    // map that stores payloads from received VAAs
    mapping(bytes32 => bytes) verifiedPayloads;

    constructor(address _wormholeCore, address _coreRelayer) {
        wormhole = IWormhole(_wormholeCore);
        relayer = ICoreRelayer(_coreRelayer);
        owner = msg.sender;
    }

    function estimateRelayCosts(uint16 targetChainId, uint256 targetGasLimit) public view returns (uint256) {
        return relayer.estimateEvmCost(targetChainId, targetGasLimit);
    }

    struct RelayerArgs {
        uint32 nonce;
        uint16 targetChainId;
        address targetAddress;
        uint32 targetGasLimit;
        uint8 consistencyLevel;
        uint8[] deliveryListIndices;
    }

    function doStuff(uint32 batchNonce, bytes[] calldata payload, uint8[] calldata consistencyLevel)
        public
        payable
        returns (uint64[] memory sequences)
    {
        // cache the payload count to save on gas
        uint256 numInputPayloads = payload.length;
        require(numInputPayloads == consistencyLevel.length, "invalid input parameters");

        // Cache the wormhole fee to save on gas costs. Then make sure the user sent
        // enough native asset to cover the cost of delivery (plus the cost of generating wormhole messages).
        uint256 wormholeFee = wormhole.messageFee();
        require(msg.value >= wormholeFee * (numInputPayloads + 1));

        // Create an array to store the wormhole message sequences. Add
        // a slot for the relay message sequence.
        sequences = new uint64[](numInputPayloads + 1);

        // send each wormhole message and save the message sequence
        uint256 messageIdx = 0;
        bytes memory verifyingPayload = abi.encodePacked(wormhole.chainId(), uint8(numInputPayloads));
        for (; messageIdx < numInputPayloads;) {
            sequences[messageIdx] = wormhole.publishMessage{value: wormholeFee}(
                batchNonce, payload[messageIdx], consistencyLevel[messageIdx]
            );

            verifyingPayload = abi.encodePacked(verifyingPayload, emitterAddress(), sequences[messageIdx]);
            unchecked {
                messageIdx += 1;
            }
        }

        // encode app-relevant info regarding the input payloads.
        // all we care about is source chain id and number of input payloads
        sequences[messageIdx] = wormhole.publishMessage{value: wormholeFee}(
            batchNonce,
            verifyingPayload,
            1 // consistencyLevel
        );
    }

    function sendBatchToTargetChain(
        bytes[] calldata payload,
        uint8[] calldata consistencyLevel,
        RelayerArgs memory relayerArgs
    ) public payable returns (uint64 relayerMessageSequence) {
        uint64[] memory doStuffSequences = doStuff(relayerArgs.nonce, payload, consistencyLevel);
        uint256 numMessageSequences = doStuffSequences.length;

        // estimate the cost of sending the batch based on the user specified gas limit
        uint256 gasEstimate = estimateRelayCosts(relayerArgs.targetChainId, relayerArgs.targetGasLimit);

        // Cache the wormhole fee to save on gas costs. Then make sure the user sent
        // enough native asset to cover the cost of delivery (plus the cost of generating wormhole messages).
        uint256 wormholeFee = wormhole.messageFee();
        require(msg.value >= gasEstimate + wormholeFee * (numMessageSequences + 1));

        // encode the relay parameters
        bytes memory relayParameters =
            abi.encodePacked(uint8(1), relayerArgs.targetGasLimit, uint8(numMessageSequences), gasEstimate);

        // create the relayer params to call the relayer with
        ICoreRelayer.DeliveryParameters memory deliveryParams = ICoreRelayer.DeliveryParameters({
            targetChain: relayerArgs.targetChainId,
            targetAddress: bytes32(uint256(uint160(relayerArgs.targetAddress))),
            deliveryList: new ICoreRelayer.AllowedEmitterSequence[](0),
            relayParameters: relayParameters,
            nonce: relayerArgs.nonce,
            consistencyLevel: relayerArgs.consistencyLevel
        });

        // call the relayer contract and save the sequence.
        relayerMessageSequence = relayer.send{value: gasEstimate}(deliveryParams);
    }

    function receiveWormholeMessages(IWormhole.VM[] memory vmList) public {
        // TODO: fix signature to only take bytes

        // loop through the array of VMs and store each payload
        uint256 vmCount = vmList.length;
        for (uint256 i = 0; i < vmCount;) {
            (bool valid, string memory reason) = wormhole.verifyVM(vmList[i]);
            require(valid, reason);

            // save the payload from each VAA
            verifiedPayloads[vmList[i].hash] = vmList[i].payload;

            unchecked {
                i += 1;
            }
        }
    }

    // setters
    function registerTrustedSender(uint16 chainId, bytes32 senderAddress) public {
        require(msg.sender == owner, "caller must be the owner");
        trustedSenders[chainId] = senderAddress;
    }

    // getters
    function trustedSender(uint16 chainId) public view returns (bytes32) {
        return trustedSenders[chainId];
    }

    function getPayload(bytes32 hash) public view returns (bytes memory) {
        return verifiedPayloads[hash];
    }

    function clearPayload(bytes32 hash) public {
        delete verifiedPayloads[hash];
    }

    function parseBatchVM(bytes memory encoded) public view returns (IWormhole.VM2 memory) {
        return wormhole.parseBatchVM(encoded);
    }

    function parseVM(bytes memory encoded) public view returns (IWormhole.VM memory) {
        return wormhole.parseVM(encoded);
    }

    function emitterAddress() public view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }
}
