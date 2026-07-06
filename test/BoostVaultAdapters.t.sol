// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoostVault} from "../src/BoostVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockStock} from "../src/mocks/MockStock.sol";
import {MockRouter} from "../src/mocks/MockRouter.sol";
import {MockMorpho} from "../src/mocks/MockMorpho.sol";
import {MockMorphoAdapter} from "../src/adapters/MockMorphoAdapter.sol";
import {MockEverst} from "../src/mocks/MockEverst.sol";
import {MockEverstAdapter} from "../src/adapters/MockEverstAdapter.sol";

contract BoostVaultAdaptersTest {
    MockStock stock;
    MockERC20 usdc;
    MockRouter router;

    function testMorphoAdapterBoostAndUnwindMatchesCoreVaultBehavior() public {
        (BoostVault vault, MockMorphoAdapter adapter) = _deployMorphoAdapterVault();

        stock.mint(address(this), 100 ether);
        stock.approve(address(vault), 100 ether);
        vault.depositAndBoostFor(address(this), 100 ether, 15_000, 1);

        _assertPosition(vault, address(this), 150 ether, 50 ether, 100 ether, 15_000);
        require(adapter.collateralBalance() == 150 ether, "morpho adapter collateral");
        require(adapter.debtBalance() == 50 ether, "morpho adapter debt");

        vault.unwindAllFor(address(this));

        _assertPosition(vault, address(this), 0, 0, 0, 0);
        require(stock.balanceOf(address(this)) == 100 ether, "morpho adapter unwind returns equity");
        require(adapter.collateralBalance() == 0, "morpho adapter collateral cleared");
        require(adapter.debtBalance() == 0, "morpho adapter debt cleared");
    }

    function testEverstAdapterBoostAndUnwindMatchesCoreVaultBehavior() public {
        (BoostVault vault, MockEverstAdapter adapter) = _deployEverstAdapterVault();

        stock.mint(address(this), 100 ether);
        stock.approve(address(vault), 100 ether);
        vault.depositAndBoostFor(address(this), 100 ether, 15_000, 1);

        _assertPosition(vault, address(this), 150 ether, 50 ether, 100 ether, 15_000);
        require(adapter.collateralBalance() == 150 ether, "everst adapter collateral");
        require(adapter.debtBalance() == 50 ether, "everst adapter debt");

        vault.unwindAllFor(address(this));

        _assertPosition(vault, address(this), 0, 0, 0, 0);
        require(stock.balanceOf(address(this)) == 100 ether, "everst adapter unwind returns equity");
        require(adapter.collateralBalance() == 0, "everst adapter collateral cleared");
        require(adapter.debtBalance() == 0, "everst adapter debt cleared");
    }

    function testEverstAdapterCanReachAndUnwindConfiguredMaxLtv() public {
        (BoostVault vault, MockEverstAdapter adapter) = _deployEverstAdapterVault();

        stock.mint(address(this), 100 ether);
        stock.approve(address(vault), 100 ether);
        vault.depositAndBoostFor(address(this), 100 ether, 25_000, 1);

        _assertPosition(vault, address(this), 250 ether, 150 ether, 100 ether, 25_000);
        require(adapter.collateralBalance() == 250 ether, "everst max collateral");
        require(adapter.debtBalance() == 150 ether, "everst max debt");

        vault.unwindAllFor(address(this));

        _assertPosition(vault, address(this), 0, 0, 0, 0);
        require(stock.balanceOf(address(this)) == 100 ether, "everst max unwind returns equity");
        require(adapter.collateralBalance() == 0, "everst max collateral cleared");
        require(adapter.debtBalance() == 0, "everst max debt cleared");
    }

    function testMorphoAdapterRejectsExternalBorrowAndWithdraw() public {
        (BoostVault vault, MockMorphoAdapter adapter) = _deployMorphoAdapterVault();
        AdapterAttacker attacker = new AdapterAttacker();

        stock.mint(address(this), 100 ether);
        stock.approve(address(vault), 100 ether);
        vault.depositAndBoostFor(address(this), 100 ether, 15_000, 1);

        try attacker.borrowMorpho(adapter, 1 ether) {
            revert("expected external borrow to fail");
        } catch Error(string memory reason) {
            require(_eq(reason, "MockMorphoAdapter: caller is not vault"), reason);
        }

        try attacker.withdrawMorpho(adapter, 1 ether) {
            revert("expected external withdraw to fail");
        } catch Error(string memory reason) {
            require(_eq(reason, "MockMorphoAdapter: caller is not vault"), reason);
        }

        require(adapter.collateralBalance() == 150 ether, "morpho collateral unchanged");
        require(adapter.debtBalance() == 50 ether, "morpho debt unchanged");
        require(stock.balanceOf(address(attacker)) == 0, "attacker got no stock");
        require(usdc.balanceOf(address(attacker)) == 0, "attacker got no usdc");
    }

    function testEverstAdapterRejectsExternalBorrowAndWithdraw() public {
        (BoostVault vault, MockEverstAdapter adapter) = _deployEverstAdapterVault();
        AdapterAttacker attacker = new AdapterAttacker();

        stock.mint(address(this), 100 ether);
        stock.approve(address(vault), 100 ether);
        vault.depositAndBoostFor(address(this), 100 ether, 15_000, 1);

        try attacker.borrowEverst(adapter, 1 ether) {
            revert("expected external borrow to fail");
        } catch Error(string memory reason) {
            require(_eq(reason, "MockEverstAdapter: caller is not vault"), reason);
        }

        try attacker.withdrawEverst(adapter, 1 ether) {
            revert("expected external withdraw to fail");
        } catch Error(string memory reason) {
            require(_eq(reason, "MockEverstAdapter: caller is not vault"), reason);
        }

        require(adapter.collateralBalance() == 150 ether, "everst collateral unchanged");
        require(adapter.debtBalance() == 50 ether, "everst debt unchanged");
        require(stock.balanceOf(address(attacker)) == 0, "attacker got no stock");
        require(usdc.balanceOf(address(attacker)) == 0, "attacker got no usdc");
    }

    function _deployMorphoAdapterVault() internal returns (BoostVault vault, MockMorphoAdapter adapter) {
        _deploySharedTokens();
        MockMorpho morpho = new MockMorpho(stock, usdc, 7_500);
        adapter = new MockMorphoAdapter(stock, usdc, morpho);
        vault = new BoostVault(stock, usdc, adapter, router, 6_000);
        adapter.setVault(address(vault));
        usdc.mint(address(morpho), 1_000_000 ether);
    }

    function _deployEverstAdapterVault() internal returns (BoostVault vault, MockEverstAdapter adapter) {
        _deploySharedTokens();
        MockEverst everst = new MockEverst(stock, usdc, 7_500);
        adapter = new MockEverstAdapter(stock, usdc, everst);
        vault = new BoostVault(stock, usdc, adapter, router, 6_000);
        adapter.setVault(address(vault));
        usdc.mint(address(everst), 1_000_000 ether);
    }

    function _deploySharedTokens() internal {
        stock = new MockStock("Mock Stock", "mSTOCK");
        usdc = new MockERC20("Mock USDC", "USDC", 18);
        router = new MockRouter(stock, usdc);
        stock.mint(address(router), 1_000_000 ether);
        usdc.mint(address(router), 1_000_000 ether);
    }

    function _assertPosition(
        BoostVault vault,
        address user,
        uint256 expectedCollateral,
        uint256 expectedDebt,
        uint256 expectedEquity,
        uint256 expectedLeverageBps
    ) internal view {
        (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) = vault.position(user);
        require(collateral == expectedCollateral, "collateral mismatch");
        require(debt == expectedDebt, "debt mismatch");
        require(equity == expectedEquity, "equity mismatch");
        require(leverageBps == expectedLeverageBps, "leverage mismatch");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

contract AdapterAttacker {
    function borrowMorpho(MockMorphoAdapter adapter, uint256 amount) external {
        adapter.borrow(amount, address(this));
    }

    function withdrawMorpho(MockMorphoAdapter adapter, uint256 amount) external {
        adapter.withdrawCollateral(amount, address(this));
    }

    function borrowEverst(MockEverstAdapter adapter, uint256 amount) external {
        adapter.borrow(amount, address(this));
    }

    function withdrawEverst(MockEverstAdapter adapter, uint256 amount) external {
        adapter.withdrawCollateral(amount, address(this));
    }
}
