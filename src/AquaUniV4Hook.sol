// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AquaHub} from "./AquaHub.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AquaUniV4Hook is AquaHub, IHooks {
    address public immutable poolManager;

    uint8 internal constant ACTION_DRAW = 0;
    uint8 internal constant ACTION_RELEASE = 1;

    constructor(address poolManager_, Currency hubAsset_, uint256 globalCapacity_) AquaHub(hubAsset_, globalCapacity_) {
        require(poolManager_ != address(0), "AquaUniV4Hook: zero PoolManager");
        poolManager = poolManager_;
    }

    modifier onlyPoolManager() {
        require(msg.sender == poolManager, "AquaUniV4Hook: caller is not PoolManager");
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length > 0) {
            (uint8 action, uint256 amount) = abi.decode(hookData, (uint8, uint256));
            if (action == ACTION_DRAW) {
                _drawHubCapacity(key, amount);
            } else if (action == ACTION_RELEASE) {
                _releaseHubCapacity(key, amount);
            } else {
                revert("AquaUniV4Hook: unknown action");
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert("AquaUniV4Hook: beforeInitialize disabled");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert("AquaUniV4Hook: afterInitialize disabled");
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("AquaUniV4Hook: beforeAddLiquidity disabled");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("AquaUniV4Hook: afterAddLiquidity disabled");
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("AquaUniV4Hook: beforeRemoveLiquidity disabled");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert("AquaUniV4Hook: afterRemoveLiquidity disabled");
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert("AquaUniV4Hook: afterSwap disabled");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("AquaUniV4Hook: beforeDonate disabled");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("AquaUniV4Hook: afterDonate disabled");
    }
}
