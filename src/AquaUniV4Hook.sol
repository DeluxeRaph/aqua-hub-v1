// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AquaUniV4Hook is IHooks {
    using PoolIdLibrary for PoolKey;

    IAqua public immutable AQUA;
    address public immutable poolManager;
    address public immutable owner;

    struct AquaPoolConfig {
        bool enabled;
        address maker;
        bytes32 strategyHash;
        address sharedToken;
        uint256 maxPullPerSwap;
    }

    enum AquaAction {
        None,
        Pull,
        CheckBalance
    }

    mapping(PoolId poolId => AquaPoolConfig config) public aquaPoolConfigs;

    constructor(IAqua aqua_, address poolManager_) {
        require(address(aqua_) != address(0), "AquaUniV4Hook: zero Aqua");
        require(poolManager_ != address(0), "AquaUniV4Hook: zero PoolManager");
        AQUA = aqua_;
        poolManager = poolManager_;
        owner = msg.sender;
    }

    modifier onlyPoolManager() {
        require(msg.sender == poolManager, "AquaUniV4Hook: caller is not PoolManager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "AquaUniV4Hook: caller is not owner");
        _;
    }

    function registerAquaPool(
        PoolKey calldata key,
        address maker,
        bytes32 strategyHash,
        address sharedToken,
        uint256 maxPullPerSwap
    ) external onlyOwner {
        require(maker != address(0), "AquaUniV4Hook: zero maker");
        require(strategyHash != bytes32(0), "AquaUniV4Hook: zero strategy hash");
        require(sharedToken != address(0), "AquaUniV4Hook: zero shared token");
        require(maxPullPerSwap > 0, "AquaUniV4Hook: zero max pull");
        require(_isPoolCurrency(key, sharedToken), "AquaUniV4Hook: shared token not in pool");

        aquaPoolConfigs[key.toId()] = AquaPoolConfig({
            enabled: true,
            maker: maker,
            strategyHash: strategyHash,
            sharedToken: sharedToken,
            maxPullPerSwap: maxPullPerSwap
        });
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

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length > 0) {
            _handleAquaAction(hookData);
        } else {
            _handleRegisteredPool(sender, key, params);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _handleRegisteredPool(address sender, PoolKey calldata key, SwapParams calldata params) internal {
        AquaPoolConfig memory config = aquaPoolConfigs[key.toId()];
        if (!config.enabled) return;

        require(config.sharedToken == _inputToken(key, params), "AquaUniV4Hook: shared token is not input");

        uint256 amountNeeded = _abs(params.amountSpecified);
        require(amountNeeded <= config.maxPullPerSwap, "AquaUniV4Hook: max pull exceeded");

        (uint248 balance, uint8 tokensCount) =
            AQUA.rawBalances(config.maker, address(this), config.strategyHash, config.sharedToken);
        require(tokensCount > 0, "AquaUniV4Hook: inactive Aqua strategy");
        require(balance >= amountNeeded, "AquaUniV4Hook: insufficient Aqua balance");
        AQUA.pull(config.maker, config.strategyHash, config.sharedToken, amountNeeded, sender);
    }

    function _inputToken(PoolKey calldata key, SwapParams calldata params) internal pure returns (address) {
        return Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
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

    function _isPoolCurrency(PoolKey calldata key, address token) internal pure returns (bool) {
        return token == Currency.unwrap(key.currency0) || token == Currency.unwrap(key.currency1);
    }

    function _abs(int256 amount) internal pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
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
