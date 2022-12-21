// contracts/Setters.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";

import "./GasOracleState.sol";

contract GasOracleSetters is Context, GasOracleState {
    function setChainId(uint16 oracleChainId) internal {
        _state.chainId = oracleChainId;
    }


    function setOwner(address owner) internal {
        _state.owner = owner;
    }

    function setPendingOwner(address pendingOwner) internal {
        _state.pendingOwner = pendingOwner;
    }

    function setDeliverGasOverhead(uint16 chainId, uint32 deliverGasOverhead) internal {
        _state.deliverGasOverhead[chainId] = deliverGasOverhead;
    }

    function setWormholeFee(uint16 chainId, uint32 wormholeFee) internal {
        _state.wormholeFee[chainId] = wormholeFee;
    }

    //TODO rename to capture that this is the dedicated reward address
    function setRelayerAddressInternal(uint16 chainId, bytes32 relayerAddress) internal {
        _state.relayerAddressMap[chainId] = relayerAddress;
    }
    
    function setPriceInfo(uint16 updateChainId, uint128 updateGasPrice, uint128 updateNativeCurrencyPrice) internal {
        _state.data[updateChainId].gasPrice = updateGasPrice;
        _state.data[updateChainId].nativeCurrencyPrice = updateNativeCurrencyPrice;
    }
}
