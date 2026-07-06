// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AquaUniV4Hook} from "../src/AquaUniV4Hook.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract AquaUniV4HookTest is Test {
    address poolManager = address(0x4444);
    address hubAsset = address(0x1000);
    address spokeAsset = address(0x2000);
    address maker = address(0xCAFE);
    address taker = address(0xBEEF);
    bytes32 strategyHash = keccak256("aqua-v4-spoke-strategy");

    MockAqua aqua;
    AquaUniV4Hook hook;
    PoolKey pool;

    function setUp() public {
        aqua = new MockAqua();
        hook = new AquaUniV4Hook(IAqua(address(aqua)), poolManager);
        pool = _poolKey(hubAsset, spokeAsset);
    }

    function testGivenAquaUniV4Hook_WhenInspectingTypes_ThenItUsesProperOneInchAquaAndUniswapV4Hooks() public view {
        // Given: the hook is deployed with the proper 1inch Aqua interface and v4 hook interface.
        IHooks asUniV4Hook = IHooks(address(hook));

        // When: the contract exposes its dependencies and permissions.
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        // Then: it points at proper 1inch Aqua, not a local AquaHub placeholder.
        assertEq(address(hook.AQUA()), address(aqua), "Then hook points at proper 1inch Aqua");
        assertEq(address(asUniV4Hook), address(hook), "Then hook is an IHooks implementation");
        assertTrue(permissions.beforeSwap, "Then beforeSwap is enabled");
        assertFalse(permissions.afterSwap, "Then afterSwap is disabled for V1");
        assertFalse(permissions.beforeSwapReturnDelta, "Then no beforeSwap return delta risk");
        assertFalse(permissions.afterSwapReturnDelta, "Then no afterSwap return delta risk");
    }

    function testGivenPoolManagerBeforeSwap_WhenHookDataRequestsAquaPull_ThenHookPullsFromProperAquaAndReturnsNoDelta() public {
        // Given: hookData requests hub-side liquidity from 1inch Aqua.
        bytes memory hookData = abi.encode(
            AquaUniV4Hook.AquaAction.Pull,
            maker,
            strategyHash,
            hubAsset,
            250 ether,
            taker
        );

        // When: Uniswap v4 PoolManager invokes beforeSwap.
        vm.prank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(taker, pool, _swapParams(), hookData);

        // Then: the hook delegates liquidity movement to Aqua, not local hub accounting.
        assertEq(selector, IHooks.beforeSwap.selector, "Then beforeSwap selector is returned");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "Then V1 does not alter swap deltas");
        assertEq(feeOverride, 0, "Then V1 does not override fees");
        assertEq(aqua.lastPullMaker(), maker, "Then Aqua maker is used");
        assertEq(aqua.lastPullApp(), address(hook), "Then hook is the Aqua app/caller");
        assertEq(aqua.lastPullStrategyHash(), strategyHash, "Then strategy hash is used");
        assertEq(aqua.lastPullToken(), hubAsset, "Then hub-side token is pulled");
        assertEq(aqua.lastPullAmount(), 250 ether, "Then requested amount is pulled");
        assertEq(aqua.lastPullTo(), taker, "Then tokens are sent to target recipient");
    }

    function testGivenPoolManagerBeforeSwap_WhenHookDataRequestsAquaBalanceCheck_ThenHookReadsProperAquaBalance() public {
        // Given: Aqua reports enough balance for the maker strategy.
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 300 ether, 2);
        bytes memory hookData = abi.encode(
            AquaUniV4Hook.AquaAction.CheckBalance,
            maker,
            strategyHash,
            hubAsset,
            250 ether,
            address(0)
        );

        // When: PoolManager invokes beforeSwap for a balance-check action.
        vm.prank(poolManager);
        hook.beforeSwap(taker, pool, _swapParams(), hookData);

        // Then: the call succeeds because the hook checked the proper Aqua balance key for this app/strategy.
    }

    function testGivenSomeoneOtherThanPoolManager_WhenCallingBeforeSwap_ThenHookRejectsTheCall() public {
        // Given: a direct caller is not the Uniswap v4 PoolManager.
        bytes memory hookData = abi.encode(
            AquaUniV4Hook.AquaAction.Pull,
            maker,
            strategyHash,
            hubAsset,
            1 ether,
            taker
        );

        // When / Then: direct callback access is rejected.
        vm.expectRevert("AquaUniV4Hook: caller is not PoolManager");
        hook.beforeSwap(taker, pool, _swapParams(), hookData);
    }

    function testGivenAquaBalanceIsTooSmall_WhenPoolManagerCallsBeforeSwap_ThenHookRejectsTheSwap() public {
        // Given: Aqua reports less available balance than the hook requires.
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 100 ether, 2);
        bytes memory hookData = abi.encode(
            AquaUniV4Hook.AquaAction.CheckBalance,
            maker,
            strategyHash,
            hubAsset,
            250 ether,
            address(0)
        );

        // When / Then: the hook rejects because proper Aqua balance is insufficient.
        vm.expectRevert("AquaUniV4Hook: insufficient Aqua balance");
        vm.prank(poolManager);
        hook.beforeSwap(taker, pool, _swapParams(), hookData);
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

contract MockAqua is IAqua {
    address public lastPullMaker;
    address public lastPullApp;
    bytes32 public lastPullStrategyHash;
    address public lastPullToken;
    uint256 public lastPullAmount;
    address public lastPullTo;


    mapping(bytes32 key => uint248 balance) internal balances;
    mapping(bytes32 key => uint8 tokensCount) internal tokenCounts;

    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        override
        returns (uint248 balance, uint8 tokensCount)
    {
        bytes32 key = _key(maker, app, strategyHash, token);
        return (balances[key], tokenCounts[key]);
    }

    function safeBalances(address, address, bytes32, address, address) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function ship(address, bytes calldata strategy, address[] calldata, uint256[] calldata)
        external
        pure
        override
        returns (bytes32 strategyHash)
    {
        return keccak256(strategy);
    }

    function dock(address, bytes32, address[] calldata) external pure override {}

    function pull(address maker, bytes32 strategyHash, address token, uint256 amount, address to) external override {
        lastPullMaker = maker;
        lastPullApp = msg.sender;
        lastPullStrategyHash = strategyHash;
        lastPullToken = token;
        lastPullAmount = amount;
        lastPullTo = to;
    }

    function push(address, address, bytes32, address, uint256) external pure override {}

    function setRawBalance(address maker, address app, bytes32 strategyHash, address token, uint248 balance, uint8 tokensCount)
        external
    {
        bytes32 key = _key(maker, app, strategyHash, token);
        balances[key] = balance;
        tokenCounts[key] = tokensCount;
    }

    function _key(address maker, address app, bytes32 strategyHash, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(maker, app, strategyHash, token));
    }
}
