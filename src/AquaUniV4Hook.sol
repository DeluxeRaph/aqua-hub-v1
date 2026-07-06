// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AquaUniV4Hook is IHooks {
    IAqua public immutable AQUA;
    address public immutable poolManager;

    enum AquaAction {
        None,
        Pull,
        CheckBalance
    }

    constructor(IAqua aqua_, address poolManager_) {
        require(address(aqua_) != address(0), "AquaUniV4Hook: zero Aqua");
        require(poolManager_ != address(0), "AquaUniV4Hook: zero PoolManager");
        AQUA = aqua_;
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

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length > 0) {
            _handleAquaAction(hookData);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _handleAquaAction(bytes calldata hookData) internal {
        (AquaAction action, address maker, bytes32 strategyHash, address token, uint256 amount, address recipient) =
            abi.decode(hookData, (AquaAction, address, bytes32, address, uint256, address));

        if (action == AquaAction.Pull) {
            AQUA.pull(maker, strategyHash, token, amount, recipient);
        } else if (action == AquaAction.CheckBalance) {
            (uint248 balance, uint8 tokensCount) = AQUA.rawBalances(maker, address(this), strategyHash, token);
            require(tokensCount > 0, "AquaUniV4Hook: inactive Aqua strategy");
            require(balance >= amount, "AquaUniV4Hook: insufficient Aqua balance");
        } else if (action != AquaAction.None) {
            revert("AquaUniV4Hook: unknown action");
        }
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
