// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AquaUniV4Hook} from "../src/AquaUniV4Hook.sol";
import {AquaHub} from "../src/AquaHub.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AquaUniV4HookTest is Test {
    address poolManager = address(0x4444);
    address hubAsset = address(0x1000);
    address spokeAssetA = address(0x2000);
    address spokeAssetB = address(0x3000);

    AquaUniV4Hook hook;
    PoolKey poolA;
    PoolKey poolB;

    function setUp() public {
        hook = new AquaUniV4Hook(poolManager, Currency.wrap(hubAsset), 1_000 ether);
        poolA = _poolKey(hubAsset, spokeAssetA);
        poolB = _poolKey(hubAsset, spokeAssetB);
    }

    function testGivenAquaUniV4Hook_WhenInspectingTypes_ThenItInheritsAquaHubAndUniswapV4Hooks() public view {
        // Given: the hook is deployed as the contract we intend to use for connected pools.
        AquaHub asAqua = AquaHub(address(hook));
        IHooks asUniV4Hook = IHooks(address(hook));

        // When: the contract is viewed through both inherited interfaces.
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        // Then: it is both an Aqua hub and a Uniswap v4 hook with only beforeSwap enabled.
        assertEq(address(asAqua), address(hook), "Then hook is an AquaHub");
        assertEq(address(asUniV4Hook), address(hook), "Then hook is an IHooks implementation");
        assertTrue(permissions.beforeSwap, "Then beforeSwap is enabled");
        assertFalse(permissions.afterSwap, "Then afterSwap is disabled for V1");
        assertFalse(permissions.beforeSwapReturnDelta, "Then no beforeSwap return delta risk");
        assertFalse(permissions.afterSwapReturnDelta, "Then no afterSwap return delta risk");
    }

    function testGivenConnectedSpokePool_WhenPoolManagerCallsBeforeSwapToDrawHubCapacity_ThenAquaUsageIncreasesAndV4ReturnsNoDelta() public {
        // Given: pool A is connected as a spoke to the Aqua hub.
        hook.connectPool(poolA, 700 ether);

        // When: Uniswap v4 PoolManager invokes beforeSwap and hookData asks Aqua to draw capacity.
        vm.prank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(0), 250 ether));

        // Then: the v4 hook returns the expected selector and no custom swap delta.
        assertEq(selector, IHooks.beforeSwap.selector, "Then beforeSwap selector is returned");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "Then V1 does not alter swap deltas");
        assertEq(feeOverride, 0, "Then V1 does not override fees");

        // Then: Aqua hub accounting records shared hub-side capacity usage for pool A.
        bytes32 poolAId = hook.poolId(poolA);
        bytes32 poolBId = hook.poolId(poolB);
        assertEq(hook.poolUsage(poolAId), 250 ether, "Then pool A usage increases");
        assertEq(hook.poolUsage(poolBId), 0, "Then pool B usage stays zero");
        assertEq(hook.totalUsage(), 250 ether, "Then global usage increases");
        assertEq(hook.availableForPool(poolA), 450 ether, "Then pool A capacity shrinks");
        assertEq(hook.availableGlobal(), 750 ether, "Then global hub capacity shrinks");
    }

    function testGivenConnectedSpokeHasUsedCapacity_WhenPoolManagerCallsBeforeSwapToReleaseHubCapacity_ThenAquaUsageDecreases() public {
        // Given: pool A has already drawn shared Aqua capacity.
        hook.connectPool(poolA, 700 ether);
        vm.prank(poolManager);
        hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(0), 250 ether));

        // When: Uniswap v4 PoolManager invokes beforeSwap and hookData asks Aqua to release capacity.
        vm.prank(poolManager);
        hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(1), 100 ether));

        // Then: Aqua hub capacity is returned to the shared hub.
        bytes32 poolAId = hook.poolId(poolA);
        assertEq(hook.poolUsage(poolAId), 150 ether, "Then pool A usage decreases");
        assertEq(hook.totalUsage(), 150 ether, "Then global usage decreases");
        assertEq(hook.availableForPool(poolA), 550 ether, "Then pool A capacity is restored");
        assertEq(hook.availableGlobal(), 850 ether, "Then global capacity is restored");
    }

    function testGivenSomeoneOtherThanPoolManager_WhenCallingBeforeSwap_ThenHookRejectsTheCall() public {
        // Given: pool A is connected to Aqua.
        hook.connectPool(poolA, 700 ether);

        // When / Then: a direct call that does not come from PoolManager is rejected.
        vm.expectRevert("AquaUniV4Hook: caller is not PoolManager");
        hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(0), 1 ether));
    }

    function testGivenUnconnectedSpokePool_WhenPoolManagerCallsBeforeSwap_ThenAquaRejectsThePool() public {
        // Given: pool A exists but was never connected to Aqua.

        // When / Then: even the real PoolManager cannot allocate hub capacity for an unconnected pool.
        vm.expectRevert("AquaHub: pool not connected");
        vm.prank(poolManager);
        hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(0), 1 ether));
    }

    function testGivenGlobalHubCapacityIsNearlyUsed_WhenAnotherConnectedPoolDrawsTooMuch_ThenAquaRejectsOversubscription() public {
        // Given: two spoke pools share one Aqua hub and pool A consumes most global capacity.
        hook.connectPool(poolA, 900 ether);
        hook.connectPool(poolB, 900 ether);
        vm.prank(poolManager);
        hook.beforeSwap(address(this), poolA, _swapParams(), abi.encode(uint8(0), 900 ether));

        // When / Then: pool B cannot draw more than the remaining global hub capacity.
        vm.expectRevert("AquaHub: global capacity exceeded");
        vm.prank(poolManager);
        hook.beforeSwap(address(this), poolB, _swapParams(), abi.encode(uint8(0), 101 ether));
    }

    function _poolKey(address token0, address token1) internal view returns (PoolKey memory) {
        address currency0 = token0 < token1 ? token0 : token1;
        address currency1 = token0 < token1 ? token1 : token0;
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
    }
}
