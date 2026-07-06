// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorpho} from "../mocks/MockMorpho.sol";

contract MockMorphoAdapter is ILendingAdapter {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable loanToken;
    MockMorpho public immutable morpho;
    address public immutable owner;
    address public vault;

    constructor(MockERC20 collateralToken_, MockERC20 loanToken_, MockMorpho morpho_) {
        collateralToken = collateralToken_;
        loanToken = loanToken_;
        morpho = morpho_;
        owner = msg.sender;
    }

    function setVault(address vault_) external {
        require(msg.sender == owner, "MockMorphoAdapter: caller is not owner");
        require(vault == address(0), "MockMorphoAdapter: vault already set");
        require(vault_ != address(0), "MockMorphoAdapter: zero vault");
        vault = vault_;
    }

    function supplyCollateral(uint256 amount) external onlyVault {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateralToken.approve(address(morpho), amount);
        morpho.supplyCollateral(amount);
    }

    function withdrawCollateral(uint256 amount, address receiver) external onlyVault {
        morpho.withdrawCollateral(amount, receiver);
    }

    function borrow(uint256 amount, address receiver) external onlyVault {
        morpho.borrow(amount, address(this));
        loanToken.transfer(receiver, amount);
    }

    function repay(uint256 amount) external onlyVault {
        loanToken.transferFrom(msg.sender, address(this), amount);
        loanToken.approve(address(morpho), amount);
        morpho.repay(amount);
    }

    function collateralBalance() external view returns (uint256) {
        return morpho.collateral(address(this));
    }

    function debtBalance() external view returns (uint256) {
        return morpho.debt(address(this));
    }

    function maxLtvBps() external view returns (uint256) {
        return morpho.maxLtvBps();
    }

    modifier onlyVault() {
        require(msg.sender == vault, "MockMorphoAdapter: caller is not vault");
        _;
    }
}
