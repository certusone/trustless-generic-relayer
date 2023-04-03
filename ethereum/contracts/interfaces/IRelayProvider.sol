// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

interface IRelayProvider {
    function quoteDeliveryOverhead(uint16 targetChain) external view returns (uint256 deliveryOverhead);

    function quoteGasPrice(uint16 targetChain) external view returns (uint256 gasPriceSource);

    function quoteAssetPrice(uint16 chainId) external view returns (uint256 usdPrice);

    // should this have source chain as a parameter, or default to current chain id?
    function getAssetConversionBuffer(uint16 targetChain)
        external
        view
        returns (uint16 tolerance, uint16 toleranceDenominator);

    //In order to be compliant, this must return an amount larger than both
    // quoteDeliveryOverhead(targetChain) 
    function quoteMaximumBudget(uint16 targetChain) external view returns (uint256 maximumTargetBudget);

    function getRewardAddress() external view returns (address payable rewardAddress);

    function getConsistencyLevel() external view returns (uint8 consistencyLevel);
}
