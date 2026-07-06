// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockEverst} from "../mocks/MockEverst.sol";

contract MockEverstAdapter is ILendingAdapter {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable loanToken;
    MockEverst public immutable everst;
    address public immutable owner;
    address public vault;

    constructor(MockERC20 collateralToken_, MockERC20 loanToken_, MockEverst everst_) {
        collateralToken = collateralToken_;
        loanToken = loanToken_;
        everst = everst_;
        owner = msg.sender;
    }

    function setVault(address vault_) external {
        require(msg.sender == owner, "MockEverstAdapter: caller is not owner");
        require(vault == address(0), "MockEverstAdapter: vault already set");
        require(vault_ != address(0), "MockEverstAdapter: zero vault");
        vault = vault_;
    }

    function supplyCollateral(uint256 amount) external onlyVault {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateralToken.approve(address(everst), amount);
        require(everst.mintCollateral(amount) == 0, "MockEverstAdapter: mint failed");
    }

    function withdrawCollateral(uint256 amount, address receiver) external onlyVault {
        require(everst.redeemUnderlying(amount, receiver) == 0, "MockEverstAdapter: redeem failed");
    }

    function borrow(uint256 amount, address receiver) external onlyVault {
        require(everst.borrow(amount) == 0, "MockEverstAdapter: borrow failed");
        loanToken.transfer(receiver, amount);
    }

    function repay(uint256 amount) external onlyVault {
        loanToken.transferFrom(msg.sender, address(this), amount);
        loanToken.approve(address(everst), amount);
        require(everst.repayBorrow(amount) == 0, "MockEverstAdapter: repay failed");
    }

    function collateralBalance() external view returns (uint256) {
        return everst.balanceOfUnderlying(address(this));
    }

    function debtBalance() external view returns (uint256) {
        return everst.borrowBalanceCurrent(address(this));
    }

    function maxLtvBps() external view returns (uint256) {
        return everst.maxLtvBps();
    }

    modifier onlyVault() {
        require(msg.sender == vault, "MockEverstAdapter: caller is not vault");
        _;
    }
}
