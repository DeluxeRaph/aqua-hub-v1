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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract BaseForkAquaUniV4HookTest is Test {
    address constant BASE_AQUA = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
    address constant BASE_V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
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
        MockERC20 usdc = new MockERC20("Fork USDC", "fUSDC");
        MockERC20 spokeA = new MockERC20("Spoke A", "SPA");
        MockERC20 spokeB = new MockERC20("Spoke B", "SPB");

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

        bytes memory hookData = abi.encode(
            AquaUniV4Hook.AquaAction.CheckBalance,
            maker,
            strategyHash,
            address(usdc),
            900 ether,
            address(0)
        );
        vm.prank(BASE_V4_POOL_MANAGER);
        hook.beforeSwap(address(this), poolA, _swapParams(), hookData);
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
        bytes32 bytecodeHash = keccak256(abi.encodePacked(type(AquaUniV4Hook).creationCode, abi.encode(aqua, poolManager)));
        for (uint256 i = 0; i < 300_000; i++) {
            salt = bytes32(i);
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_SWAP_FLAG) return salt;
        }
        revert("salt not found");
    }

    function deploy(bytes32 salt, IAqua aqua, address poolManager) external returns (AquaUniV4Hook hook) {
        hook = new AquaUniV4Hook{salt: salt}(aqua, poolManager);
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
