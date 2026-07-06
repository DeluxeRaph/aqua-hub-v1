// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

abstract contract AquaHub {
    using PoolIdLibrary for PoolKey;

    Currency public immutable hubAsset;
    uint256 public immutable globalCapacity;
    uint256 public totalUsage;

    mapping(bytes32 poolId => bool connected) public isConnectedPool;
    mapping(bytes32 poolId => uint256 capacity) public poolCapacity;
    mapping(bytes32 poolId => uint256 usage) public poolUsage;

    constructor(Currency hubAsset_, uint256 globalCapacity_) {
        hubAsset = hubAsset_;
        globalCapacity = globalCapacity_;
    }

    function connectPool(PoolKey memory key, uint256 capacity) public virtual {
        require(_poolContainsHubAsset(key), "AquaHub: pool missing hub asset");

        bytes32 id = poolId(key);
        isConnectedPool[id] = true;
        poolCapacity[id] = capacity;
    }

    function poolId(PoolKey memory key) public pure returns (bytes32) {
        PoolId id = key.toId();
        return PoolId.unwrap(id);
    }

    function availableGlobal() public view returns (uint256) {
        return globalCapacity > totalUsage ? globalCapacity - totalUsage : 0;
    }

    function availableForPool(PoolKey memory key) public view returns (uint256) {
        bytes32 id = poolId(key);
        if (!isConnectedPool[id]) return 0;

        uint256 localAvailable = poolCapacity[id] > poolUsage[id] ? poolCapacity[id] - poolUsage[id] : 0;
        uint256 globalAvailable = availableGlobal();
        return localAvailable < globalAvailable ? localAvailable : globalAvailable;
    }

    function _drawHubCapacity(PoolKey memory key, uint256 amount) internal {
        bytes32 id = poolId(key);
        _requireConnectedPool(id);
        require(totalUsage + amount <= globalCapacity, "AquaHub: global capacity exceeded");
        require(poolUsage[id] + amount <= poolCapacity[id], "AquaHub: pool capacity exceeded");

        poolUsage[id] += amount;
        totalUsage += amount;
    }

    function _releaseHubCapacity(PoolKey memory key, uint256 amount) internal {
        bytes32 id = poolId(key);
        _requireConnectedPool(id);
        require(poolUsage[id] >= amount, "AquaHub: release exceeds usage");

        poolUsage[id] -= amount;
        totalUsage -= amount;
    }

    function _requireConnectedPool(bytes32 id) internal view {
        require(isConnectedPool[id], "AquaHub: pool not connected");
    }

    function _poolContainsHubAsset(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == Currency.unwrap(hubAsset)
            || Currency.unwrap(key.currency1) == Currency.unwrap(hubAsset);
    }
}
