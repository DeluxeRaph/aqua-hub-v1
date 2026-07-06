// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./mocks/MockERC20.sol";

contract AquaHub {
    MockERC20 public immutable hubAsset;
    uint256 public immutable globalCapacity;
    uint256 public totalUsage;

    mapping(address => bool) public isConnectedSpoke;
    mapping(address => uint256) public spokeCapacity;
    mapping(address => uint256) public spokeUsage;

    constructor(MockERC20 hubAsset_, uint256 globalCapacity_) {
        hubAsset = hubAsset_;
        globalCapacity = globalCapacity_;
    }

    function connectSpoke(address spoke, uint256 capacity) external {
        require(spoke != address(0), "AquaHub: zero spoke");
        isConnectedSpoke[spoke] = true;
        spokeCapacity[spoke] = capacity;
    }

    function allocateHubAsset(address to, uint256 amount) external {
        _requireConnectedSpoke(msg.sender);
        require(totalUsage + amount <= globalCapacity, "AquaHub: global capacity exceeded");
        require(spokeUsage[msg.sender] + amount <= spokeCapacity[msg.sender], "AquaHub: spoke capacity exceeded");

        spokeUsage[msg.sender] += amount;
        totalUsage += amount;
        hubAsset.transfer(to, amount);
    }

    function releaseHubAsset(uint256 amount) external {
        _requireConnectedSpoke(msg.sender);
        require(spokeUsage[msg.sender] >= amount, "AquaHub: release exceeds usage");

        spokeUsage[msg.sender] -= amount;
        totalUsage -= amount;
    }

    function availableGlobal() external view returns (uint256) {
        return globalCapacity > totalUsage ? globalCapacity - totalUsage : 0;
    }

    function availableForSpoke(address spoke) external view returns (uint256) {
        if (!isConnectedSpoke[spoke]) return 0;

        uint256 localAvailable = spokeCapacity[spoke] > spokeUsage[spoke]
            ? spokeCapacity[spoke] - spokeUsage[spoke]
            : 0;
        uint256 globalAvailable = globalCapacity > totalUsage ? globalCapacity - totalUsage : 0;
        return localAvailable < globalAvailable ? localAvailable : globalAvailable;
    }

    function _requireConnectedSpoke(address spoke) internal view {
        require(isConnectedSpoke[spoke], "AquaHub: spoke not connected");
    }
}
