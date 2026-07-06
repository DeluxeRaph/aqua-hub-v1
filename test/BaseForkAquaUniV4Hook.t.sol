// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AquaUniV4Hook} from "../src/AquaUniV4Hook.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

contract BaseForkAquaUniV4HookTest is Test {
    address constant BASE_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address constant BASE_V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function testGivenBaseFork_WhenDeployingAquaV4HookAndInitializingTwoPools_ThenItUsesLiveAquaAndUniswapV4PoolManager()
        public
    {
        // Given: a Base mainnet fork with live 1inch Aqua and Uniswap v4 PoolManager deployed.
        vm.createSelectFork("https://mainnet.base.org");
        assertEq(block.chainid, 8453, "Given Base fork");
        assertGt(BASE_AQUA.code.length, 0, "Given live Aqua code exists on Base");
        assertGt(BASE_V4_POOL_MANAGER.code.length, 0, "Given live v4 PoolManager code exists on Base");

        // Given: two local fork tokens that will be used as two connected spoke-pool assets.
        BaseForkMockERC20 usdc = new BaseForkMockERC20("Fork USDC", "fUSDC");
        BaseForkMockERC20 spokeA = new BaseForkMockERC20("Spoke A", "SPA");
        BaseForkMockERC20 spokeB = new BaseForkMockERC20("Spoke B", "SPB");

        // Given: the Aqua hook is deployed to an address whose v4 permission bits enable only beforeSwap.
        AquaHookCreate2Deployer deployer = new AquaHookCreate2Deployer();
        bytes32 salt = deployer.findSalt(IAqua(BASE_AQUA), BASE_V4_POOL_MANAGER);
        AquaUniV4Hook hook = deployer.deploy(salt, IAqua(BASE_AQUA), BASE_V4_POOL_MANAGER);
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_SWAP_FLAG,
            "Given hook address has only beforeSwap flag"
        );
        assertEq(address(hook.AQUA()), BASE_AQUA, "Given hook points at live Base Aqua");
        assertEq(hook.poolManager(), BASE_V4_POOL_MANAGER, "Given hook points at live Base PoolManager");

        // When: two Uniswap v4 pools are initialized on the Base fork using the Aqua hook.
        PoolKey memory poolA = _poolKey(address(usdc), address(spokeA), hook);
        PoolKey memory poolB = _poolKey(address(usdc), address(spokeB), hook);
        int24 tickA = IPoolManager(BASE_V4_POOL_MANAGER).initialize(poolA, SQRT_PRICE_1_1);
        int24 tickB = IPoolManager(BASE_V4_POOL_MANAGER).initialize(poolB, SQRT_PRICE_1_1);

        // Then: both pools initialize successfully at the expected 1:1 tick.
        assertEq(tickA, 0, "Then pool A initializes at tick 0");
        assertEq(tickB, 0, "Then pool B initializes at tick 0");

        // And: the hook can read an actual Aqua strategy shipped to the live Aqua contract on the fork.
        address maker = address(0xA11CE);
        bytes memory strategy = abi.encode(maker, address(hook), address(usdc), address(spokeA), "base-fork-spoke-a");
        bytes32 strategyHash = keccak256(strategy);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(spokeA);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000 ether;
        amounts[1] = 500 ether;

        usdc.mint(maker, 1_000 ether);
        spokeA.mint(maker, 500 ether);
        vm.startPrank(maker);
        usdc.approve(BASE_AQUA, type(uint256).max);
        spokeA.approve(BASE_AQUA, type(uint256).max);
        bytes32 shippedHash = IAqua(BASE_AQUA).ship(address(hook), strategy, tokens, amounts);
        vm.stopPrank();
        assertEq(shippedHash, strategyHash, "Then live Aqua records the fork strategy hash");

        deployer.registerAquaPool(hook, poolA, maker, strategyHash, address(usdc), 1_000 ether);
        deployer.registerAquaPool(hook, poolB, maker, strategyHash, address(usdc), 1_000 ether);

        // Then: direct swappers do not need to know Aqua hookData; both pools use registered config.
        vm.prank(BASE_V4_POOL_MANAGER);
        hook.beforeSwap(address(this), poolA, _exactInputParams(poolA, address(usdc), 1 ether), "");

        vm.prank(BASE_V4_POOL_MANAGER);
        hook.beforeSwap(address(this), poolB, _exactInputParams(poolB, address(usdc), 1 ether), "");
    }

    function testGivenBaseForkWithRealUsdcWethAndHydx_WhenSwappingWithEmptyHookData_ThenAquaPullFundsBothPools()
        public
    {
        // Given: a Base fork with live 1inch Aqua, live v4 PoolManager, real USDC/WETH, and local HYDX.
        vm.createSelectFork("https://mainnet.base.org");
        assertEq(block.chainid, 8453, "Given Base fork");
        assertGt(BASE_AQUA.code.length, 0, "Given live Aqua code exists on Base");
        assertGt(BASE_V4_POOL_MANAGER.code.length, 0, "Given live v4 PoolManager code exists on Base");
        assertGt(BASE_USDC.code.length, 0, "Given real Base USDC exists");
        assertGt(BASE_WETH.code.length, 0, "Given real Base WETH exists");

        BaseForkMockERC20 hydx = new BaseForkMockERC20("Hydrex", "HYDX");
        AquaHookCreate2Deployer deployer = new AquaHookCreate2Deployer();
        bytes32 salt = deployer.findSalt(IAqua(BASE_AQUA), BASE_V4_POOL_MANAGER);
        AquaUniV4Hook hook = deployer.deploy(salt, IAqua(BASE_AQUA), BASE_V4_POOL_MANAGER);
        BaseForkAquaFundedSwapRouter router = new BaseForkAquaFundedSwapRouter(IPoolManager(BASE_V4_POOL_MANAGER));

        PoolKey memory wethPool = _poolKey(BASE_USDC, BASE_WETH, hook);
        PoolKey memory hydxPool = _poolKey(BASE_USDC, address(hydx), hook);
        IPoolManager(BASE_V4_POOL_MANAGER).initialize(wethPool, SQRT_PRICE_1_1);
        IPoolManager(BASE_V4_POOL_MANAGER).initialize(hydxPool, SQRT_PRICE_1_1);

        deal(BASE_USDC, address(router), 10_000 ether);
        deal(BASE_WETH, address(router), 10_000 ether);
        hydx.mint(address(router), 10_000 ether);
        router.modifyLiquidity(
            wethPool, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: 0}), ""
        );
        router.modifyLiquidity(
            hydxPool, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: 0}), ""
        );

        address maker = address(0xA11CE);
        deal(BASE_USDC, maker, 2_000e6);
        deal(BASE_WETH, maker, 1_000 ether);
        hydx.mint(maker, 1_000 ether);
        bytes32 wethStrategyHash =
            _shipStrategy(maker, hook, BASE_USDC, BASE_WETH, 1_000e6, 100 ether, "base-real-usdc-weth");
        bytes32 hydxStrategyHash =
            _shipStrategy(maker, hook, BASE_USDC, address(hydx), 1_000e6, 100 ether, "base-real-usdc-hydx");
        deployer.registerAquaPool(hook, wethPool, maker, wethStrategyHash, BASE_USDC, 100e6);
        deployer.registerAquaPool(hook, hydxPool, maker, hydxStrategyHash, BASE_USDC, 100e6);

        (uint248 wethAquaBefore,) = IAqua(BASE_AQUA).rawBalances(maker, address(hook), wethStrategyHash, BASE_USDC);
        (uint248 hydxAquaBefore,) = IAqua(BASE_AQUA).rawBalances(maker, address(hook), hydxStrategyHash, BASE_USDC);
        uint256 takerWethBefore = IERC20Like(BASE_WETH).balanceOf(address(this));
        uint256 takerHydxBefore = hydx.balanceOf(address(this));

        // When: swaps use empty hookData; the registered Aqua config funds USDC input for each pool.
        router.swap(wethPool, _exactInputParams(wethPool, BASE_USDC, 1e6), address(this), "");
        router.swap(hydxPool, _exactInputParams(hydxPool, BASE_USDC, 1e6), address(this), "");

        // Then: live Aqua USDC balances went down and real v4 swaps paid WETH/HYDX out.
        (uint248 wethAquaAfter,) = IAqua(BASE_AQUA).rawBalances(maker, address(hook), wethStrategyHash, BASE_USDC);
        (uint248 hydxAquaAfter,) = IAqua(BASE_AQUA).rawBalances(maker, address(hook), hydxStrategyHash, BASE_USDC);
        assertEq(uint256(wethAquaBefore - wethAquaAfter), 1e6, "Then WETH pool consumed Aqua USDC");
        assertEq(uint256(hydxAquaBefore - hydxAquaAfter), 1e6, "Then HYDX pool consumed Aqua USDC");
        assertGt(IERC20Like(BASE_WETH).balanceOf(address(this)), takerWethBefore, "Then taker receives real WETH");
        assertGt(hydx.balanceOf(address(this)), takerHydxBefore, "Then taker receives HYDX");
    }

    function _shipStrategy(
        address maker,
        AquaUniV4Hook hook,
        address usdc,
        address spoke,
        uint256 usdcAmount,
        uint256 spokeAmount,
        string memory label
    ) internal returns (bytes32 strategyHash) {
        bytes memory strategy = abi.encode(maker, address(hook), usdc, spoke, label);
        strategyHash = keccak256(strategy);
        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = spoke;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = spokeAmount;

        vm.startPrank(maker);
        IERC20Like(usdc).approve(BASE_AQUA, type(uint256).max);
        IERC20Like(spoke).approve(BASE_AQUA, type(uint256).max);
        bytes32 shippedHash = IAqua(BASE_AQUA).ship(address(hook), strategy, tokens, amounts);
        vm.stopPrank();
        assertEq(shippedHash, strategyHash, "Then live Aqua records strategy hash");
    }

    function _exactInputParams(PoolKey memory key, address inputToken, int256 amountSpecified)
        internal
        pure
        returns (SwapParams memory)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == inputToken;
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? uint160(4295128740)
                : uint160(1461446703485210103287273052203988822378723970341)
        });
    }

    function _poolKey(address tokenA, address tokenB, AquaUniV4Hook hook) internal pure returns (PoolKey memory) {
        address currency0 = tokenA < tokenB ? tokenA : tokenB;
        address currency1 = tokenA < tokenB ? tokenB : tokenA;
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

contract AquaHookCreate2Deployer {
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

contract BaseForkAquaFundedSwapRouter {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, address recipient, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), key, params, recipient, hookData)), (BalanceDelta));
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(uint8(2), key, params, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "BaseForkAquaFundedSwapRouter: only manager");
        uint8 action = abi.decode(rawData[:32], (uint8));

        if (action == 2) {
            (, PoolKey memory liqKey, ModifyLiquidityParams memory liqParams, bytes memory liqHookData) =
                abi.decode(rawData, (uint8, PoolKey, ModifyLiquidityParams, bytes));
            (BalanceDelta liqDelta,) = manager.modifyLiquidity(liqKey, liqParams, liqHookData);
            _settleOrTake(liqKey, liqDelta, address(this));
            return abi.encode(liqDelta);
        }

        (, PoolKey memory swapKey, SwapParams memory swapParams, address recipient, bytes memory swapHookData) =
            abi.decode(rawData, (uint8, PoolKey, SwapParams, address, bytes));
        BalanceDelta swapDelta = manager.swap(swapKey, swapParams, swapHookData);
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

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract BaseForkMockERC20 {
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
