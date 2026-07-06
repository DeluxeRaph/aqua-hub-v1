// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AquaUniV4Hook} from "../src/AquaUniV4Hook.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

contract AquaUniV4HookTest is Test {
    using CurrencySettler for Currency;

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

    function testGivenSomeoneOtherThanPoolManager_WhenCallingBeforeSwap_ThenHookRejectsTheCall() public {
        // When / Then: direct callback access is rejected.
        vm.expectRevert("AquaUniV4Hook: caller is not PoolManager");
        hook.beforeSwap(taker, pool, _swapParams(), "");
    }

    function testGivenNonEmptyHookData_WhenPoolManagerCallsBeforeSwap_ThenHookRejectsBecauseRegisteredPoolsOwnTheFlow()
        public
    {
        // Given: the pool has a registered Aqua config and a caller tries to steer the hook with custom data.
        hook.registerAquaPool(pool, maker, strategyHash, hubAsset, 500 ether);
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 2 ether, 2);

        // When / Then: the hook rejects non-empty hookData because this prototype only supports registered-pool flow.
        vm.expectRevert("AquaUniV4Hook: hookData disabled");
        vm.prank(poolManager);
        hook.beforeSwap(taker, pool, _swapParams(), abi.encode("manual route"));
    }

    function testGivenAquaBalanceIsTooSmall_WhenPoolManagerCallsBeforeSwap_ThenHookRejectsTheSwap() public {
        // Given: the registered pool requires more hub-token input than Aqua has available.
        hook.registerAquaPool(pool, maker, strategyHash, hubAsset, 500 ether);
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 0.5 ether, 2);

        // When / Then: the hook rejects because proper Aqua balance is insufficient.
        vm.expectRevert("AquaUniV4Hook: insufficient Aqua balance");
        vm.prank(poolManager);
        hook.beforeSwap(taker, pool, _swapParams(), "");
    }

    function testGivenRegisteredAquaPool_WhenPoolManagerCallsBeforeSwap_ThenHookPullsAquaFromPoolConfig() public {
        // Given: the pool is registered once with a shared Aqua liquidity strategy.
        hook.registerAquaPool(pool, maker, strategyHash, hubAsset, 500 ether);
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 2 ether, 2);

        // When: a normal swap reaches beforeSwap with no user-supplied hookData.
        vm.prank(poolManager);
        (bytes4 selector, BeforeSwapDelta delta, uint24 feeOverride) = hook.beforeSwap(taker, pool, _swapParams(), "");

        // Then: the hook uses stored pool config to pull Aqua instead of requiring hookData instructions.
        assertEq(selector, IHooks.beforeSwap.selector, "Then beforeSwap selector is returned");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "Then V1 does not alter swap deltas");
        assertEq(feeOverride, 0, "Then V1 does not override fees");
        assertEq(aqua.lastPullToken(), hubAsset, "Then hub-side token is pulled");
        assertEq(aqua.lastPullTo(), taker, "Then PoolManager sender receives Aqua input");
    }

    function testGivenRegisteredAquaPoolWithTooLittleAqua_WhenPoolManagerCallsBeforeSwapWithEmptyHookData_ThenHookRejects()
        public
    {
        // Given: the pool is registered but Aqua has less shared-token balance than this swap needs.
        hook.registerAquaPool(pool, maker, strategyHash, hubAsset, 500 ether);
        aqua.setRawBalance(maker, address(hook), strategyHash, hubAsset, 0.5 ether, 2);

        // When / Then: normal empty-hookData swaps still enforce Aqua availability.
        vm.expectRevert("AquaUniV4Hook: insufficient Aqua balance");
        vm.prank(poolManager);
        hook.beforeSwap(taker, pool, _swapParams(), "");
    }

    function testGivenNonOwner_WhenRegisteringAquaPool_ThenHookRejects() public {
        // Given: someone other than the deployer tries to configure pool-level Aqua liquidity.
        address attacker = address(0xBAD);

        // When / Then: registration is owner-gated.
        vm.expectRevert("AquaUniV4Hook: caller is not owner");
        vm.prank(attacker);
        hook.registerAquaPool(pool, maker, strategyHash, hubAsset, 500 ether);
    }

    function testGivenSharedTokenIsNotPoolCurrency_WhenRegisteringAquaPool_ThenHookRejects() public {
        // Given: a registration tries to attach an unrelated token to this v4 pool.
        address unrelatedToken = address(0x9999);

        // When / Then: the hook refuses configs that could pull unrelated Aqua liquidity.
        vm.expectRevert("AquaUniV4Hook: shared token not in pool");
        hook.registerAquaPool(pool, maker, strategyHash, unrelatedToken, 500 ether);
    }

    function testGivenUsdcHubBacksWethPool_WhenRouterSwapsWithEmptyHookData_ThenAquaPullFundsTheV4Swap() public {
        // Given: a real local v4 pool with USDC as hub token and WETH as the spoke token.
        PoolManager manager = new PoolManager(address(this));
        MockAqua fundedAqua = new MockAqua();
        LocalAquaHookCreate2Deployer deployer = new LocalAquaHookCreate2Deployer();
        AquaUniV4Hook swapHook = deployer.deploy(
            deployer.findSalt(IAqua(address(fundedAqua)), address(manager)),
            IAqua(address(fundedAqua)),
            address(manager)
        );
        AquaFundedSwapRouter router = new AquaFundedSwapRouter(IPoolManager(address(manager)));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");
        PoolKey memory wethPool = _poolKey(address(usdc), address(weth), swapHook);
        manager.initialize(wethPool, 79228162514264337593543950336);

        usdc.mint(address(fundedAqua), 1_000 ether);
        usdc.mint(address(router), 1_000 ether);
        weth.mint(address(router), 1_000 ether);
        router.modifyLiquidity(
            wethPool, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: 0})
        );

        deployer.registerAquaPool(swapHook, wethPool, maker, strategyHash, address(usdc), 100 ether);
        fundedAqua.setRawBalance(maker, address(swapHook), strategyHash, address(usdc), 100 ether, 2);
        uint256 wethBefore = weth.balanceOf(taker);

        // When: the taker swaps with empty hookData through a router that settles from Aqua-pulled USDC.
        BalanceDelta delta = router.swap(
            wethPool,
            SwapParams({
                zeroForOne: address(usdc) < address(weth), amountSpecified: -1 ether, sqrtPriceLimitX96: 4295128740
            }),
            taker
        );

        // Then: the hook pulled USDC from Aqua into the router and the v4 pool paid WETH to the taker.
        assertEq(fundedAqua.lastPullToken(), address(usdc), "Then USDC hub token is pulled from Aqua");
        assertEq(fundedAqua.lastPullTo(), address(router), "Then Aqua funds the v4 settlement router");
        assertLt(delta.amount0(), 0, "Then swap consumed exact-input USDC side");
        assertGt(weth.balanceOf(taker), wethBefore, "Then taker receives WETH from the v4 swap");
    }

    function _poolKey(address token0, address token1) internal view returns (PoolKey memory) {
        return _poolKey(token0, token1, hook);
    }

    function _poolKey(address token0, address token1, AquaUniV4Hook hook_) internal pure returns (PoolKey memory) {
        address currency0 = token0 < token1 ? token0 : token1;
        address currency1 = token0 < token1 ? token1 : token0;
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook_))
        });
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});
    }
}

contract LocalAquaHookCreate2Deployer {
    function findSalt(IAqua aqua, address poolManager) external view returns (bytes32 salt) {
        bytes32 bytecodeHash =
            keccak256(abi.encodePacked(type(AquaUniV4Hook).creationCode, abi.encode(aqua, poolManager)));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_SWAP_FLAG) return salt;
        }
        revert("salt not found");
    }

    function deploy(bytes32 salt, IAqua aqua, address poolManager) external returns (AquaUniV4Hook hook) {
        hook = new AquaUniV4Hook{salt: salt}(aqua, poolManager);
    }

    function registerAquaPool(
        AquaUniV4Hook hook,
        PoolKey calldata key,
        address maker,
        bytes32 strategyHash,
        address sharedToken,
        uint256 maxPullPerSwap
    ) external {
        hook.registerAquaPool(key, maker, strategyHash, sharedToken, maxPullPerSwap);
    }
}

contract AquaFundedSwapRouter {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, address recipient)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), key, params, recipient)), (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(uint8(2), key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "AquaFundedSwapRouter: only manager");
        uint8 action = abi.decode(rawData[:32], (uint8));

        if (action == 2) {
            (, PoolKey memory liqKey, ModifyLiquidityParams memory liqParams) =
                abi.decode(rawData, (uint8, PoolKey, ModifyLiquidityParams));
            (BalanceDelta delta,) = manager.modifyLiquidity(liqKey, liqParams, "");
            _settleOrTake(liqKey, delta, address(this));
            return abi.encode(delta);
        }

        (, PoolKey memory swapKey, SwapParams memory swapParams, address recipient) =
            abi.decode(rawData, (uint8, PoolKey, SwapParams, address));
        BalanceDelta swapDelta = manager.swap(swapKey, swapParams, "");
        _settleOrTake(swapKey, swapDelta, recipient);
        return abi.encode(swapDelta);
    }

    function _settleOrTake(PoolKey memory key, BalanceDelta delta, address recipient) internal {
        if (delta.amount0() < 0) {
            key.currency0.settle(manager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(manager, address(this), uint256(uint128(-delta.amount1())), false);
        }
        if (delta.amount0() > 0) key.currency0.take(manager, recipient, uint256(uint128(delta.amount0())), false);
        if (delta.amount1() > 0) key.currency1.take(manager, recipient, uint256(uint128(delta.amount1())), false);
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
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

    function safeBalances(address, address, bytes32, address, address)
        external
        pure
        override
        returns (uint256, uint256)
    {
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

        bytes32 key = _key(maker, msg.sender, strategyHash, token);
        require(balances[key] >= amount, "MockAqua: insufficient raw balance");
        balances[key] -= uint248(amount);
        if (token.code.length > 0) require(MockERC20(token).transfer(to, amount), "MockAqua: transfer failed");
    }

    function push(address, address, bytes32, address, uint256) external pure override {}

    function setRawBalance(
        address maker,
        address app,
        bytes32 strategyHash,
        address token,
        uint248 balance,
        uint8 tokensCount
    ) external {
        bytes32 key = _key(maker, app, strategyHash, token);
        balances[key] = balance;
        tokenCounts[key] = tokensCount;
    }

    function _key(address maker, address app, bytes32 strategyHash, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(maker, app, strategyHash, token));
    }
}
