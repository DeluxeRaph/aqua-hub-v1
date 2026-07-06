// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoostVault} from "../src/BoostVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockMorpho} from "../src/mocks/MockMorpho.sol";
import {MockRouter} from "../src/mocks/MockRouter.sol";
import {MockMorphoAdapter} from "../src/adapters/MockMorphoAdapter.sol";

contract BoostVaultTest {
    MockStock stock;
    MockERC20 usdc;
    MockMorpho morpho;
    MockMorphoAdapter adapter;
    MockRouter router;
    BoostVault vault;

    address user = address(0xBEEF);

    function setUp() public {
        stock = new MockStock("Mock Stock", "mSTOCK");
        usdc = new MockERC20("Mock USDC", "USDC", 18);
        morpho = new MockMorpho(stock, usdc, 7_500);
        adapter = new MockMorphoAdapter(stock, usdc, morpho);
        router = new MockRouter(stock, usdc);
        vault = new BoostVault(stock, usdc, adapter, router, 6_000);
        adapter.setVault(address(vault));

        stock.mint(user, 100 ether);
        usdc.mint(address(morpho), 1_000_000 ether);
        stock.mint(address(router), 1_000_000 ether);
        usdc.mint(address(router), 1_000_000 ether);
    }

    function testDepositAndBoostLoopsBorrowedUsdcBackIntoMoreMockStock() public {
        setUp();

        _asUserApproveVault(100 ether);
        vault.depositAndBoostFor(user, 100 ether, 15_000, 1);

        (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) = vault.position(user);

        require(collateral == 150 ether, "collateral should include bought mock stock");
        require(debt == 50 ether, "debt should be borrowed USDC");
        require(equity == 100 ether, "equity should remain initial deposit value");
        require(leverageBps == 15_000, "leverage should be 1.5x");
        require(adapter.collateralBalance() == 150 ether, "vault should resupply bought stock");
        require(adapter.debtBalance() == 50 ether, "vault should owe USDC to Morpho");
    }

    function testRejectsBoostAboveVaultMaxLtv() public {
        setUp();

        _asUserApproveVault(100 ether);

        try vault.depositAndBoostFor(user, 100 ether, 30_000, 1) {
            revert("expected unsafe boost to revert");
        } catch Error(string memory reason) {
            require(_eq(reason, "BoostVault: target LTV too high"), reason);
        }
    }

    function testCanReachConfiguredMaxLtvWithIterativeLoop() public {
        setUp();

        _asUserApproveVault(100 ether);
        vault.depositAndBoostFor(user, 100 ether, 25_000, 1);

        (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) = vault.position(user);

        require(collateral == 250 ether, "collateral reaches 2.5x target");
        require(debt == 150 ether, "debt reaches 60 percent final LTV");
        require(equity == 100 ether, "equity remains initial deposit");
        require(leverageBps == 25_000, "leverage reaches 2.5x");
    }

    function testOnlyPositionOwnerCanUnwind() public {
        setUp();

        UserActor owner = new UserActor(stock, vault);
        UserActor attacker = new UserActor(stock, vault);
        stock.mint(address(owner), 100 ether);

        owner.depositAndBoost(100 ether, 15_000, 1);

        try attacker.unwindFor(address(owner)) {
            revert("expected unauthorized unwind to revert");
        } catch Error(string memory reason) {
            require(_eq(reason, "BoostVault: caller is not user"), reason);
        }

        (uint256 collateral, uint256 debt,,) = vault.position(address(owner));
        require(collateral == 150 ether, "owner collateral unchanged");
        require(debt == 50 ether, "owner debt unchanged");
    }

    function testOneUserUnwindDoesNotCorruptAnotherUserPosition() public {
        setUp();

        UserActor alice = new UserActor(stock, vault);
        UserActor bob = new UserActor(stock, vault);
        stock.mint(address(alice), 100 ether);
        stock.mint(address(bob), 100 ether);

        alice.depositAndBoost(100 ether, 15_000, 1);
        bob.depositAndBoost(100 ether, 15_000, 1);

        alice.unwind();

        (uint256 aliceCollateral, uint256 aliceDebt,,) = vault.position(address(alice));
        (uint256 bobCollateral, uint256 bobDebt, uint256 bobEquity, uint256 bobLeverageBps) = vault.position(address(bob));

        require(aliceCollateral == 0, "alice collateral cleared");
        require(aliceDebt == 0, "alice debt cleared");
        require(stock.balanceOf(address(alice)) == 100 ether, "alice receives equity back");
        require(bobCollateral == 150 ether, "bob collateral remains");
        require(bobDebt == 50 ether, "bob debt remains");
        require(bobEquity == 100 ether, "bob equity remains");
        require(bobLeverageBps == 15_000, "bob leverage remains");
        require(adapter.collateralBalance() == 150 ether, "shared collateral matches bob only");
        require(adapter.debtBalance() == 50 ether, "shared debt matches bob only");
    }

    function testRevertsWhenRouterReturnsLessThanMinStockOut() public {
        setUp();

        _asUserApproveVault(100 ether);

        try vault.depositAndBoostFor(user, 100 ether, 15_000, 51 ether) {
            revert("expected slippage revert");
        } catch Error(string memory reason) {
            require(_eq(reason, "BoostVault: min stock out not met"), reason);
        }
    }

    function testFullUnwindSellsEnoughMockStockToRepayUsdcDebtAndReturnsRemainder() public {
        setUp();

        _asUserApproveVault(100 ether);
        vault.depositAndBoostFor(user, 100 ether, 15_000, 1);

        vault.unwindAllFor(user);

        (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) = vault.position(user);

        require(collateral == 0, "collateral cleared");
        require(debt == 0, "debt cleared");
        require(equity == 0, "equity cleared");
        require(leverageBps == 0, "leverage cleared");
        require(stock.balanceOf(user) == 100 ether, "user receives remaining mock stock equity");
        require(adapter.collateralBalance() == 0, "Morpho collateral cleared");
        require(adapter.debtBalance() == 0, "Morpho debt cleared");
    }

    function testFullUnwindAtConfiguredMaxLtvDeleveragesBeforeReturningEquity() public {
        setUp();

        _asUserApproveVault(100 ether);
        vault.depositAndBoostFor(user, 100 ether, 25_000, 1);

        vault.unwindAllFor(user);

        (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) = vault.position(user);

        require(collateral == 0, "collateral cleared");
        require(debt == 0, "debt cleared");
        require(equity == 0, "equity cleared");
        require(leverageBps == 0, "leverage cleared");
        require(stock.balanceOf(user) == 100 ether, "user receives remaining mock stock equity");
        require(adapter.collateralBalance() == 0, "Morpho collateral cleared");
        require(adapter.debtBalance() == 0, "Morpho debt cleared");
    }

    function testOneMaxLtvUserCanUnwindWhileAnotherMaxLtvUserRemains() public {
        setUp();

        UserActor alice = new UserActor(stock, vault);
        UserActor bob = new UserActor(stock, vault);
        stock.mint(address(alice), 100 ether);
        stock.mint(address(bob), 100 ether);

        alice.depositAndBoost(100 ether, 25_000, 1);
        bob.depositAndBoost(100 ether, 25_000, 1);

        alice.unwind();

        (uint256 aliceCollateral, uint256 aliceDebt,,) = vault.position(address(alice));
        (uint256 bobCollateral, uint256 bobDebt, uint256 bobEquity, uint256 bobLeverageBps) = vault.position(address(bob));

        require(aliceCollateral == 0, "alice collateral cleared");
        require(aliceDebt == 0, "alice debt cleared");
        require(stock.balanceOf(address(alice)) == 100 ether, "alice receives equity back");
        require(bobCollateral == 250 ether, "bob collateral remains");
        require(bobDebt == 150 ether, "bob debt remains");
        require(bobEquity == 100 ether, "bob equity remains");
        require(bobLeverageBps == 25_000, "bob leverage remains");
        require(adapter.collateralBalance() == 250 ether, "shared collateral matches bob only");
        require(adapter.debtBalance() == 150 ether, "shared debt matches bob only");
    }

    function _asUserApproveVault(uint256 amount) internal {
        // Foundry sets msg.sender to this test contract; this helper simulates approval by minting
        // to the test contract and using it as the user-facing caller for this prototype.
        stock.mint(address(this), amount);
        stock.approve(address(vault), amount);
        user = address(this);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

contract UserActor {
    MockStock public immutable stock;
    BoostVault public immutable vault;

    constructor(MockStock stock_, BoostVault vault_) {
        stock = stock_;
        vault = vault_;
    }

    function depositAndBoost(uint256 amount, uint256 targetLeverageBps, uint256 minStockOut) external {
        stock.approve(address(vault), amount);
        vault.depositAndBoostFor(address(this), amount, targetLeverageBps, minStockOut);
    }

    function unwind() external {
        vault.unwindAllFor(address(this));
    }

    function unwindFor(address user) external {
        vault.unwindAllFor(user);
    }
}
