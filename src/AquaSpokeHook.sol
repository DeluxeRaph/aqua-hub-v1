// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AquaHub} from "./AquaHub.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AquaSpokeHook {
    AquaHub public immutable hub;
    MockERC20 public immutable hubAsset;
    MockERC20 public immutable spokeAsset;
    string public poolLabel;

    constructor(AquaHub hub_, MockERC20 hubAsset_, MockERC20 spokeAsset_, string memory poolLabel_) {
        hub = hub_;
        hubAsset = hubAsset_;
        spokeAsset = spokeAsset_;
        poolLabel = poolLabel_;
    }

    function payHubAssetTo(address to, uint256 amount) external {
        hub.allocateHubAsset(to, amount);
    }

    function receiveHubAssetFrom(address from, uint256 amount) external {
        hubAsset.transferFrom(from, address(hub), amount);
        hub.releaseHubAsset(amount);
    }
}
