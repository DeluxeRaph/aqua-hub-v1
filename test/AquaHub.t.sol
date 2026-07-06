// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AquaHub} from "../src/AquaHub.sol";
import {AquaSpokeHook} from "../src/AquaSpokeHook.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract AquaHubTest {
    MockERC20 usdc;
    MockERC20 tokenA;
    MockERC20 tokenB;
    AquaHub hub;
    AquaSpokeHook spokeA;
    AquaSpokeHook spokeB;

    address user = address(0xBEEF);

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "USDC", 18);
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        hub = new AquaHub(usdc, 1_000 ether);
        spokeA = new AquaSpokeHook(hub, usdc, tokenA, "USDC/TKNA");
        spokeB = new AquaSpokeHook(hub, usdc, tokenB, "USDC/TKNB");

        usdc.mint(address(hub), 1_000 ether);
        tokenA.mint(address(spokeA), 1_000 ether);
        tokenB.mint(address(spokeB), 1_000 ether);
        tokenA.mint(user, 100 ether);
    }

    function testGivenAquaHubWithTwoSpokePools_WhenOneSpokePaysOutHubAsset_ThenOnlyHubSideIsAllocatedAndOtherSpokeCapacityShrinks() public {
        // Given: Aqua is a one-sided USDC hub for two connected spoke hooks.
        setUp();
        hub.connectSpoke(address(spokeA), 700 ether);
        hub.connectSpoke(address(spokeB), 500 ether);

        // When: spoke A needs USDC from the shared hub side to serve a swap.
        spokeA.payHubAssetTo(user, 250 ether);

        // Then: Aqua records shared USDC usage for spoke A only, not the spoke token side.
        require(hub.spokeUsage(address(spokeA)) == 250 ether, "Then spoke A usage increases");
        require(hub.spokeUsage(address(spokeB)) == 0, "Then spoke B usage stays zero");
        require(hub.totalUsage() == 250 ether, "Then global usage increases");
        require(hub.availableForSpoke(address(spokeA)) == 450 ether, "Then spoke A local cap shrinks");
        require(hub.availableForSpoke(address(spokeB)) == 500 ether, "Then spoke B local cap remains");
        require(hub.availableGlobal() == 750 ether, "Then all spokes see less global hub capacity");
        require(usdc.balanceOf(user) == 250 ether, "Then user receives hub-side USDC");
        require(tokenA.balanceOf(address(spokeA)) == 1_000 ether, "Then Aqua did not take spoke token A");
        require(tokenB.balanceOf(address(spokeB)) == 1_000 ether, "Then Aqua did not take spoke token B");
    }

    function testGivenSpokeHasUsedHubCapacity_WhenHubAssetFlowsBackIn_ThenTheSpokeReturnsSharedCapacity() public {
        // Given: spoke A has drawn USDC capacity from Aqua.
        setUp();
        hub.connectSpoke(address(spokeA), 700 ether);
        spokeA.payHubAssetTo(user, 250 ether);
        usdc.mint(address(this), 100 ether);
        usdc.approve(address(spokeA), 100 ether);

        // When: USDC flows back through the spoke.
        spokeA.receiveHubAssetFrom(address(this), 100 ether);

        // Then: the spoke returns capacity to the shared hub.
        require(hub.spokeUsage(address(spokeA)) == 150 ether, "Then spoke A usage decreases");
        require(hub.totalUsage() == 150 ether, "Then global usage decreases");
        require(hub.availableForSpoke(address(spokeA)) == 550 ether, "Then spoke A capacity is restored");
        require(hub.availableGlobal() == 850 ether, "Then global capacity is restored");
    }

    function testGivenGlobalHubCapIsNearlyUsed_WhenAnotherSpokeRequestsTooMuch_ThenTheHubRejectsOversubscription() public {
        // Given: two spokes are connected to one Aqua Hub and spoke A consumes most global capacity.
        setUp();
        hub.connectSpoke(address(spokeA), 900 ether);
        hub.connectSpoke(address(spokeB), 900 ether);
        spokeA.payHubAssetTo(user, 900 ether);

        // When / Then: spoke B cannot use more than the remaining global hub capacity.
        try spokeB.payHubAssetTo(user, 101 ether) {
            revert("Then expected global cap rejection");
        } catch Error(string memory reason) {
            require(_eq(reason, "AquaHub: global capacity exceeded"), reason);
        }

        require(hub.spokeUsage(address(spokeB)) == 0, "Then rejected spoke has no usage");
        require(hub.totalUsage() == 900 ether, "Then global usage unchanged");
        require(hub.availableGlobal() == 100 ether, "Then remaining global capacity unchanged");
    }

    function testGivenUnconnectedSpoke_WhenItRequestsHubAsset_ThenTheHubRejectsIt() public {
        // Given: a spoke hook exists but has not been connected to Aqua.
        setUp();

        // When / Then: Aqua rejects unconnected pool access.
        try spokeA.payHubAssetTo(user, 1 ether) {
            revert("Then expected unconnected spoke rejection");
        } catch Error(string memory reason) {
            require(_eq(reason, "AquaHub: spoke not connected"), reason);
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
