// contracts/Bridge.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../interfaces/IWormholeRelayer.sol";
import "../interfaces/IWormholeReceiver.sol";
import "../interfaces/IDelivery.sol";
import "./CoreRelayerGovernance.sol";
import "./CoreRelayerStructs.sol";

contract CoreRelayer is CoreRelayerGovernance {

    enum DeliveryStatus {
        SUCCESS,
        RECEIVER_FAILURE,
        FORWARD_REQUEST_FAILURE,
        FORWARD_REQUEST_SUCCESS,
        INVALID_REDELIVERY
    }

    event Delivery(
        address indexed recipientContract,
        uint16 indexed sourceChain,
        uint64 indexed sequence,
        bytes32 deliveryVaaHash,
        DeliveryStatus status
    );

    function send(IWormholeRelayer.Send memory request, uint32 nonce, address relayProvider)
        public
        payable
        returns (uint64 sequence)
    {
        return multichainSend(multichainSendContainer(request, relayProvider), nonce);
    }

    function forward(IWormholeRelayer.Send memory request, uint32 nonce, address relayProvider) public payable {
        return multichainForward(multichainSendContainer(request, relayProvider), nonce);
    }

    function resend(IWormholeRelayer.ResendByTx memory request, uint32 nonce, address relayProvider)
        public
        payable
        returns (uint64 sequence)
    {
        (uint256 requestFee, uint256 maximumRefund, uint256 receiverValueTarget, bool isSufficient, uint8 reason) =
        verifyFunding(
            VerifyFundingCalculation({
                provider: IRelayProvider(relayProvider),
                sourceChain: chainId(),
                targetChain: request.targetChain,
                maxTransactionFeeSource: request.newMaxTransactionFee,
                receiverValueSource: request.newReceiverValue,
                isDelivery: false
            })
        );
        if (!isSufficient) {
            if (reason == 26) {
                revert IWormholeRelayer.MaxTransactionFeeNotEnough();
            } else {
                revert IWormholeRelayer.FundsTooMuch();
            }
        }
        IWormhole wormhole = wormhole();
        uint256 wormholeMessageFee = wormhole.messageFee();
        uint256 totalFee = requestFee + wormholeMessageFee;

        //Make sure the msg.value covers the budget they specified
        if (msg.value < totalFee) {
            revert IWormholeRelayer.MsgValueTooLow();
        }

        IRelayProvider provider = IRelayProvider(relayProvider);

        sequence = emitRedelivery(
            request,
            nonce,
            provider.getConsistencyLevel(),
            receiverValueTarget,
            maximumRefund,
            provider,
            wormhole,
            wormholeMessageFee
        );

        //Send the delivery fees to the specified address of the provider.
        pay(provider.getRewardAddress(), msg.value - wormholeMessageFee);
    }

    function emitRedelivery(
        IWormholeRelayer.ResendByTx memory request,
        uint32 nonce,
        uint8 consistencyLevel,
        uint256 receiverValueTarget,
        uint256 maximumRefund,
        IRelayProvider provider,
        IWormhole wormhole,
        uint256 wormholeMessageFee
    ) internal returns (uint64 sequence) {
        bytes memory instruction = convertToEncodedRedeliveryByTxHashInstruction(
            request, receiverValueTarget, maximumRefund, request.targetChain, request.newMaxTransactionFee, provider
        );

        sequence = wormhole.publishMessage{value: wormholeMessageFee}(nonce, instruction, consistencyLevel);
    }

    /**
     * TODO: Correct this comment
     * @dev `multisend` generates a VAA with DeliveryInstructions to be delivered to the specified target
     * contract based on user parameters.
     * it parses the RelayParameters to determine the target chain ID
     * it estimates the cost of relaying the batch
     * it confirms that the user has passed enough value to pay the relayer
     * it checks that the passed nonce is not zero (VAAs with a nonce of zero will not be batched)
     * it generates a VAA with the encoded DeliveryInstructions
     */
    function multichainSend(IWormholeRelayer.MultichainSend memory deliveryRequests, uint32 nonce)
        public
        payable
        returns (uint64 sequence)
    {
        (uint256 totalCost, bool isSufficient, uint8 cause) = sufficientFundsHelper(deliveryRequests, msg.value);
        if (!isSufficient) {
            if (cause == 26) {
                revert IWormholeRelayer.MaxTransactionFeeNotEnough();
            } else if (cause == 25) {
                revert IWormholeRelayer.MsgValueTooLow();
            } else {
                revert IWormholeRelayer.FundsTooMuch();
            }
        }
        if (nonce == 0) {
            revert IWormholeRelayer.NonceIsZero();
        }

        // encode the DeliveryInstructions
        bytes memory container = convertToEncodedDeliveryInstructions(deliveryRequests, true);

        // emit delivery message
        IWormhole wormhole = wormhole();
        IRelayProvider provider = IRelayProvider(deliveryRequests.relayProviderAddress);
        uint256 wormholeMessageFee = wormhole.messageFee();

        sequence = wormhole.publishMessage{value: wormholeMessageFee}(nonce, container, provider.getConsistencyLevel());

        //pay fee to provider
        pay(provider.getRewardAddress(), totalCost - wormholeMessageFee);
    }

    /**
     * TODO correct this comment
     * @dev `forward` queues up a 'send' which will be executed after the present delivery is complete
     * & uses the gas refund to cover the costs.
     * contract based on user parameters.
     * it parses the RelayParameters to determine the target chain ID
     * it estimates the cost of relaying the batch
     * it confirms that the user has passed enough value to pay the relayer
     * it checks that the passed nonce is not zero (VAAs with a nonce of zero will not be batched)
     * it generates a VAA with the encoded DeliveryInstructions
     */
    function multichainForward(IWormholeRelayer.MultichainSend memory deliveryRequests, uint32 nonce) public payable {
        if (!isContractLocked()) {
            revert IWormholeRelayer.NoDeliveryInProgress();
        }
        if (getForwardingRequest().isValid) {
            revert IWormholeRelayer.MultipleForwardsRequested();
        }
        if (nonce == 0) {
            revert IWormholeRelayer.NonceIsZero();
        }
        if (msg.sender != lockedTargetAddress()) {
            revert IWormholeRelayer.ForwardRequestFromWrongAddress();
        }
        bytes memory encodedMultichainSend = encodeMultichainSend(deliveryRequests);
        setForwardingRequest(
            ForwardingRequest({
                deliveryRequestsContainer: encodedMultichainSend,
                nonce: nonce,
                msgValue: msg.value,
                sender: msg.sender,
                isValid: true
            })
        );
    }

    function emitForward(uint256 refundAmount, ForwardingRequest memory forwardingRequest)
        internal
        returns (uint64, bool)
    {
        IWormholeRelayer.MultichainSend memory container =
            decodeMultichainSend(forwardingRequest.deliveryRequestsContainer);

        //Add any additional funds which were passed in to the refund amount
        refundAmount = refundAmount + forwardingRequest.msgValue;

        //make sure the refund amount covers the native gas amounts
        (uint256 totalMinimumFees, bool funded,) = sufficientFundsHelper(container, refundAmount);

        //REVISE consider deducting the cost of this process from the refund amount?

        if (funded) {
            // the rollover chain is the chain in the first request

            //calc how much budget is used by chains other than the rollover chain
            uint256 rolloverChainCostEstimate =
                container.requests[0].maxTransactionFee + container.requests[0].receiverValue;
            //uint256 nonrolloverBudget = totalMinimumFees - rolloverChainCostEstimate; //stack too deep
            uint256 rolloverBudget =
                refundAmount - (totalMinimumFees - rolloverChainCostEstimate) - container.requests[0].receiverValue;

            //overwrite the gas budget on the rollover chain to the remaining budget amount
            container.requests[0].maxTransactionFee = rolloverBudget;
        }

        //emit forwarding instruction
        bytes memory reencoded = convertToEncodedDeliveryInstructions(container, funded);
        IRelayProvider provider = IRelayProvider(container.relayProviderAddress);
        IWormhole wormhole = wormhole();
        uint64 sequence = wormhole.publishMessage{value: wormhole.messageFee()}(
            forwardingRequest.nonce, reencoded, provider.getConsistencyLevel()
        );

        // if funded, pay out reward to provider. Otherwise, the delivery code will handle sending a refund.
        if (funded) {
            pay(provider.getRewardAddress(), refundAmount);
        }

        //clear forwarding request from cache
        clearForwardingRequest();

        return (sequence, funded);
    }

    /*
    By the time this function completes, we must be certain that the specified funds are sufficient to cover
    delivery for each one of the deliveryRequests with at least 1 gas on the target chains.
    */
    function sufficientFundsHelper(IWormholeRelayer.MultichainSend memory deliveryRequests, uint256 funds)
        internal
        view
        returns (uint256 totalFees, bool isSufficient, uint8 reason)
    {
        totalFees = wormhole().messageFee();
        IRelayProvider provider = IRelayProvider(deliveryRequests.relayProviderAddress);

        for (uint256 i = 0; i < deliveryRequests.requests.length; i++) {
            IWormholeRelayer.Send memory request = deliveryRequests.requests[i];

            (uint256 requestFee, uint256 maximumRefund, uint256 receiverValueTarget, bool isSufficient, uint8 reason) =
            verifyFunding(
                VerifyFundingCalculation({
                    provider: provider,
                    sourceChain: chainId(),
                    targetChain: request.targetChain,
                    maxTransactionFeeSource: request.maxTransactionFee,
                    receiverValueSource: request.receiverValue,
                    isDelivery: true
                })
            );

            if (!isSufficient) {
                return (0, false, reason);
            }

            totalFees = totalFees + requestFee;
            if (funds < totalFees) {
                return (0, false, 25); //"Insufficient funds were provided to cover the delivery fees.");
            }
        }

        return (totalFees, true, 0);
    }

    struct VerifyFundingCalculation {
        IRelayProvider provider;
        uint16 sourceChain;
        uint16 targetChain;
        uint256 maxTransactionFeeSource;
        uint256 receiverValueSource;
        bool isDelivery;
    }

    function verifyFunding(VerifyFundingCalculation memory args)
        internal
        view
        returns (
            uint256 requestFee,
            uint256 maximumRefund,
            uint256 receiverValueTarget,
            bool isSufficient,
            uint8 reason
        )
    {
        requestFee = args.maxTransactionFeeSource + args.receiverValueSource;
        receiverValueTarget = convertApplicationBudgetAmount(args.receiverValueSource, args.targetChain, args.provider);
        uint256 overheadFeeSource = args.isDelivery
            ? args.provider.quoteDeliveryOverhead(args.targetChain)
            : args.provider.quoteRedeliveryOverhead(args.targetChain);
        uint256 overheadBudgetTarget =
            assetConversionHelper(args.sourceChain, overheadFeeSource, args.targetChain, 1, 1, true, args.provider);
        maximumRefund = args.isDelivery
            ? calculateTargetDeliveryMaximumRefund(args.targetChain, args.maxTransactionFeeSource, args.provider)
            : calculateTargetRedeliveryMaximumRefund(args.targetChain, args.maxTransactionFeeSource, args.provider);

        //Make sure the maxTransactionFee covers the minimum delivery cost to the targetChain
        if (args.maxTransactionFeeSource < overheadFeeSource) {
            isSufficient = false;
            reason = 26; //Insufficient msg.value to cover minimum delivery costs.";
        }
        //Make sure the budget does not exceed the maximum for the provider on that chain; //This added value is totalBudgetTarget
        else if (
            args.provider.quoteMaximumBudget(args.targetChain)
                < (maximumRefund + overheadBudgetTarget + receiverValueTarget)
        ) {
            isSufficient = false;
            reason = 27; //"Specified budget exceeds the maximum allowed by the provider";
        } else {
            isSufficient = true;
            reason = 0;
        }
    }

    function multichainSendContainer(IWormholeRelayer.Send memory request, address relayProvider)
        internal
        pure
        returns (IWormholeRelayer.MultichainSend memory container)
    {
        IWormholeRelayer.Send[] memory requests = new IWormholeRelayer.Send[](1);
        requests[0] = request;
        container = IWormholeRelayer.MultichainSend({relayProviderAddress: relayProvider, requests: requests});
    }

    function _executeDelivery(
        IWormhole wormhole,
        DeliveryInstruction memory internalInstruction,
        bytes[] memory encodedVMs,
        bytes32 deliveryVaaHash,
        address payable relayerRefund,
        uint16 sourceChain,
        uint64 sourceSequence
    ) internal {
        //REVISE Decide whether we want to remove the DeliveryInstructionContainer from encodedVMs.

        // lock the contract to prevent reentrancy
        if (isContractLocked()) {
            revert IDelivery.ReentrantCall();
        }
        setContractLock(true);
        setLockedTargetAddress(fromWormholeFormat(internalInstruction.targetAddress));
        // store gas budget pre target invocation to calculate unused gas budget
        uint256 preGas = gasleft();

        // call the receiveWormholeMessages endpoint on the target contract
        (bool success,) = fromWormholeFormat(internalInstruction.targetAddress).call{
            gas: internalInstruction.executionParameters.gasLimit,
            value: internalInstruction.receiverValueTarget
        }(abi.encodeCall(IWormholeReceiver.receiveWormholeMessages, (encodedVMs, new bytes[](0))));

        uint256 postGas = gasleft();
        // There's no easy way to measure the exact cost of the CALL instruction.
        // This is due to the fact that the compiler probably emits DUPN or MSTORE instructions
        // to setup the arguments for the call just after our measurement.
        // This means the refund could be off by a few units of gas.
        // Thus, we ensure the overhead doesn't cause an overflow in our refund formula here.
        uint256 gasUsed = (preGas - postGas) > internalInstruction.executionParameters.gasLimit
            ? internalInstruction.executionParameters.gasLimit
            : (preGas - postGas);

        // refund unused gas budget
        uint256 weiToRefund = internalInstruction.receiverValueTarget;
        if (success) {
            weiToRefund = (internalInstruction.executionParameters.gasLimit - gasUsed)
                * internalInstruction.maximumRefundTarget / internalInstruction.executionParameters.gasLimit;
        }

        // unlock the contract
        setContractLock(false);

        //REVISE decide if we want to always emit a VAA, or only emit a msg when forwarding
        // // emit delivery status message
        // DeliveryStatus memory status = DeliveryStatus({
        //     payloadID: 2,
        //     batchHash: internalParams.batchVM.hash,
        //     emitterAddress: internalParams.deliveryId.emitterAddress,
        //     sequence: internalParams.deliveryId.sequence,
        //     deliveryCount: uint16(stackTooDeep.attemptedDeliveryCount + 1),
        //     deliverySuccess: success
        // });
        // // set the nonce to zero so a batch VAA is not created
        // sequence =
        //     wormhole.publishMessage{value: wormhole.messageFee()}(0, encodeDeliveryStatus(status), consistencyLevel());
        ForwardingRequest memory forwardingRequest = getForwardingRequest();
        if (forwardingRequest.isValid) {
            (, success) = emitForward(weiToRefund, forwardingRequest);
            if (success) {
                emit Delivery({
                    recipientContract: fromWormholeFormat(internalInstruction.targetAddress),
                    sourceChain: sourceChain,
                    sequence: sourceSequence,
                    deliveryVaaHash: deliveryVaaHash,
                    status: DeliveryStatus.FORWARD_REQUEST_SUCCESS
                });
            } else {
                bool sent = pay(payable(fromWormholeFormat(internalInstruction.refundAddress)), weiToRefund);
                if (!sent) {
                    // if refunding fails, pay out full refund to relayer
                    weiToRefund = 0;
                }
                emit Delivery({
                    recipientContract: fromWormholeFormat(internalInstruction.targetAddress),
                    sourceChain: sourceChain,
                    sequence: sourceSequence,
                    deliveryVaaHash: deliveryVaaHash,
                    status: DeliveryStatus.FORWARD_REQUEST_FAILURE
                });
            }
        } else {
            bool sent = pay(payable(fromWormholeFormat(internalInstruction.refundAddress)), weiToRefund);
            if (!sent) {
                // if refunding fails, pay out full refund to relayer
                weiToRefund = 0;
            }

            if (success) {
                emit Delivery({
                    recipientContract: fromWormholeFormat(internalInstruction.targetAddress),
                    sourceChain: sourceChain,
                    sequence: sourceSequence,
                    deliveryVaaHash: deliveryVaaHash,
                    status: DeliveryStatus.SUCCESS
                });
            } else {
                emit Delivery({
                    recipientContract: fromWormholeFormat(internalInstruction.targetAddress),
                    sourceChain: sourceChain,
                    sequence: sourceSequence,
                    deliveryVaaHash: deliveryVaaHash,
                    status: DeliveryStatus.RECEIVER_FAILURE
                });
            }
        }

        uint256 receiverValuePaid = (success ? internalInstruction.receiverValueTarget : 0);
        uint256 wormholeFeePaid = forwardingRequest.isValid ? wormhole.messageFee() : 0;
        uint256 relayerRefundAmount = msg.value - weiToRefund - receiverValuePaid - wormholeFeePaid;
        // refund the rest to relayer
        pay(relayerRefund, relayerRefundAmount);
    }

    //REVISE, consider implementing this system into the RelayProvider.
    // function requestRewardPayout(uint16 rewardChain, bytes32 receiver, uint32 nonce)
    //     public
    //     payable
    //     returns (uint64 sequence)
    // {
    //     uint256 amount = relayerRewards(msg.sender, rewardChain);

    //     require(amount > 0, "no current accrued rewards");

    //     resetRelayerRewards(msg.sender, rewardChain);

    //     sequence = wormhole().publishMessage{value: msg.value}(
    //         nonce,
    //         encodeRewardPayout(
    //             RewardPayout({
    //                 payloadID: 100,
    //                 fromChain: chainId(),
    //                 chain: rewardChain,
    //                 amount: amount,
    //                 receiver: receiver
    //             })
    //         ),
    //         20 //REVISE encode finality
    //     );
    // }

    // function collectRewards(bytes memory encodedVm) public {
    //     (IWormhole.VM memory vm, bool valid, string memory reason) = wormhole().parseAndVerifyVM(encodedVm);

    //     require(valid, reason);
    //     require(verifyRelayerVM(vm), "invalid emitter");

    //     RewardPayout memory payout = parseRewardPayout(vm.payload);

    //     require(payout.chain == chainId());

    //     payable(address(uint160(uint256(payout.receiver)))).transfer(payout.amount);
    // }

    function verifyRelayerVM(IWormhole.VM memory vm) internal view returns (bool) {
        return registeredCoreRelayerContract(vm.emitterChainId) == vm.emitterAddress;
    }

    function getDefaultRelayProvider() public view returns (IRelayProvider) {
        return defaultRelayProvider();
    }

    function redeliverSingle(IDelivery.TargetRedeliveryByTxHashParamsSingle memory targetParams) public payable {
        //cache wormhole
        IWormhole wormhole = wormhole();

        //validate the redelivery VM
        (IWormhole.VM memory redeliveryVM, bool valid, string memory reason) =
            wormhole.parseAndVerifyVM(targetParams.redeliveryVM);
        if (!valid) {
            revert IDelivery.InvalidRedeliveryVM(reason);
        }
        if (!verifyRelayerVM(redeliveryVM)) {
            // Redelivery VM has an invalid emitter
            revert IDelivery.InvalidEmitterInRedeliveryVM();
        }

        RedeliveryByTxHashInstruction memory redeliveryInstruction =
            decodeRedeliveryByTxHashInstruction(redeliveryVM.payload);

        //validate the original delivery VM
        IWormhole.VM memory originalDeliveryVM;
        (originalDeliveryVM, valid, reason) =
            wormhole.parseAndVerifyVM(targetParams.sourceEncodedVMs[redeliveryInstruction.deliveryIndex]);
        if (!valid) {
            revert IDelivery.InvalidVaa(redeliveryInstruction.deliveryIndex);
        }
        if (!verifyRelayerVM(originalDeliveryVM)) {
            // Original Delivery VM has a invalid emitter
            revert IDelivery.InvalidEmitterInOriginalDeliveryVM(redeliveryInstruction.deliveryIndex);
        }

        DeliveryInstruction memory instruction;
        (instruction, valid) = validateRedeliverySingle(
            redeliveryInstruction,
            decodeDeliveryInstructionsContainer(originalDeliveryVM.payload).instructions[redeliveryInstruction
                .multisendIndex]
        );

        if (!valid) {
            emit Delivery({
                recipientContract: fromWormholeFormat(instruction.targetAddress),
                sourceChain: redeliveryVM.emitterChainId,
                sequence: redeliveryVM.sequence,
                deliveryVaaHash: redeliveryVM.hash,
                status: DeliveryStatus.INVALID_REDELIVERY
            });
            pay(targetParams.relayerRefundAddress, msg.value);
            return;
        }

        _executeDelivery(
            wormhole,
            instruction,
            targetParams.sourceEncodedVMs,
            originalDeliveryVM.hash,
            targetParams.relayerRefundAddress,
            originalDeliveryVM.emitterChainId,
            originalDeliveryVM.sequence
        );
    }

    function validateRedeliverySingle(
        RedeliveryByTxHashInstruction memory redeliveryInstruction,
        DeliveryInstruction memory originalInstruction
    ) internal view returns (DeliveryInstruction memory deliveryInstruction, bool isValid) {
        // All the same checks as delivery single, with a couple additional

        // The same relay provider must be specified when doing a single VAA redeliver.
        address providerAddress = fromWormholeFormat(redeliveryInstruction.executionParameters.providerDeliveryAddress);
        if (providerAddress != fromWormholeFormat(originalInstruction.executionParameters.providerDeliveryAddress)) {
            revert IDelivery.MismatchingRelayProvidersInRedelivery();
        }

        // relayer must have covered the necessary funds
        if (
            msg.value
                < redeliveryInstruction.newMaximumRefundTarget + redeliveryInstruction.newReceiverValueTarget
                    + wormhole().messageFee()
        ) {
            revert IDelivery.InsufficientRelayerFunds();
        }

        uint16 whChainId = chainId();
        // msg.sender must be the provider
        // "Relay provider differed from the specified address");
        isValid = msg.sender == providerAddress
        // redelivery must target this chain
        // "Redelivery request does not target this chain.");
        && whChainId == redeliveryInstruction.targetChain
        // original delivery must target this chain
        // "Original delivery request did not target this chain.");
        && whChainId == originalInstruction.targetChain
        // gasLimit & receiverValue must be at least as large as the initial delivery
        // "New receiver value is smaller than the original"
        && originalInstruction.receiverValueTarget <= redeliveryInstruction.newReceiverValueTarget
        // "New gasLimit is smaller than the original"
        && originalInstruction.executionParameters.gasLimit <= redeliveryInstruction.executionParameters.gasLimit;

        // Overwrite compute budget and application budget on the original request and proceed.
        deliveryInstruction = originalInstruction;
        deliveryInstruction.maximumRefundTarget = redeliveryInstruction.newMaximumRefundTarget;
        deliveryInstruction.receiverValueTarget = redeliveryInstruction.newReceiverValueTarget;
        deliveryInstruction.executionParameters = redeliveryInstruction.executionParameters;
    }

    function deliverSingle(IDelivery.TargetDeliveryParametersSingle memory targetParams) public payable {
        // cache wormhole instance
        IWormhole wormhole = wormhole();

        // validate the deliveryIndex
        (IWormhole.VM memory deliveryVM, bool valid, string memory reason) =
            wormhole.parseAndVerifyVM(targetParams.encodedVMs[targetParams.deliveryIndex]);
        if (!valid) {
            revert IDelivery.InvalidVaa(targetParams.deliveryIndex);
        }
        if (!verifyRelayerVM(deliveryVM)) {
            revert IDelivery.InvalidEmitter();
        }

        DeliveryInstructionsContainer memory container = decodeDeliveryInstructionsContainer(deliveryVM.payload);
        //ensure this is a funded delivery, not a failed forward.
        if (!container.sufficientlyFunded) {
            revert IDelivery.SendNotSufficientlyFunded();
        }

        // parse the deliveryVM payload into the DeliveryInstructions struct
        DeliveryInstruction memory deliveryInstruction = container.instructions[targetParams.multisendIndex];

        //make sure the specified relayer is the relayer delivering this message
        if (fromWormholeFormat(deliveryInstruction.executionParameters.providerDeliveryAddress) != msg.sender) {
            revert IDelivery.UnexpectedRelayer();
        }

        //make sure relayer passed in sufficient funds
        if (
            msg.value
                < deliveryInstruction.maximumRefundTarget + deliveryInstruction.receiverValueTarget + wormhole.messageFee()
        ) {
            revert IDelivery.InsufficientRelayerFunds();
        }

        //make sure this delivery is intended for this chain
        if (chainId() != deliveryInstruction.targetChain) {
            revert IDelivery.TargetChainIsNotThisChain(deliveryInstruction.targetChain);
        }

        _executeDelivery(
            wormhole,
            deliveryInstruction,
            targetParams.encodedVMs,
            deliveryVM.hash,
            targetParams.relayerRefundAddress,
            deliveryVM.emitterChainId,
            deliveryVM.sequence
        );
    }

    function toWormholeFormat(address addr) public pure returns (bytes32 whFormat) {
        return bytes32(uint256(uint160(addr)));
    }

    function fromWormholeFormat(bytes32 whFormatAddress) public pure returns (address addr) {
        return address(uint160(uint256(whFormatAddress)));
    }

    function getDefaultRelayParams() public pure returns (bytes memory relayParams) {
        return new bytes(0);
    }

    function quoteGas(uint16 targetChain, uint32 gasLimit, IRelayProvider provider)
        public
        view
        returns (uint256 deliveryQuote)
    {
        deliveryQuote = provider.quoteDeliveryOverhead(targetChain) + (gasLimit * provider.quoteGasPrice(targetChain));
    }

    function quoteGasResend(uint16 targetChain, uint32 gasLimit, IRelayProvider provider)
        public
        view
        returns (uint256 redeliveryQuote)
    {
        redeliveryQuote =
            provider.quoteRedeliveryOverhead(targetChain) + (gasLimit * provider.quoteGasPrice(targetChain));
    }

    //If the integrator pays at least nativeQuote, they should receive at least targetAmount as their application budget
    function quoteReceiverValue(uint16 targetChain, uint256 targetAmount, IRelayProvider provider)
        public
        view
        returns (uint256 nativeQuote)
    {
        (uint16 buffer, uint16 denominator) = provider.getAssetConversionBuffer(targetChain);
        nativeQuote = assetConversionHelper(
            targetChain, targetAmount, chainId(), uint256(0) + denominator + buffer, denominator, true, provider
        );
    }

    function pay(address payable receiver, uint256 amount) internal returns (bool success) {
        if (amount > 0) {
            (success,) = receiver.call{value: amount}("");
        } else {
            success = true;
        }
    }
}
