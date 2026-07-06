// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

contract MockMorpho {
    MockERC20 public immutable collateralToken;
    MockERC20 public immutable loanToken;
    uint256 public immutable maxLtvBps;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;

    constructor(MockERC20 collateralToken_, MockERC20 loanToken_, uint256 maxLtvBps_) {
        collateralToken = collateralToken_;
        loanToken = loanToken_;
        maxLtvBps = maxLtvBps_;
    }

    function supplyCollateral(uint256 amount) external {
        require(amount > 0, "MockMorpho: zero collateral");
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
    }

    function withdrawCollateral(uint256 amount, address receiver) external {
        require(collateral[msg.sender] >= amount, "MockMorpho: insufficient collateral");
        uint256 remainingCollateral = collateral[msg.sender] - amount;
        require(_isHealthy(remainingCollateral, debt[msg.sender]), "MockMorpho: unhealthy withdrawal");
        collateral[msg.sender] = remainingCollateral;
        collateralToken.transfer(receiver, amount);
    }

    function borrow(uint256 amount, address receiver) external {
        require(amount > 0, "MockMorpho: zero borrow");
        uint256 newDebt = debt[msg.sender] + amount;
        require(_isHealthy(collateral[msg.sender], newDebt), "MockMorpho: borrow exceeds max LTV");
        debt[msg.sender] = newDebt;
        loanToken.transfer(receiver, amount);
    }

    function repay(uint256 amount) external {
        require(amount > 0, "MockMorpho: zero repay");
        uint256 repayAmount = amount > debt[msg.sender] ? debt[msg.sender] : amount;
        loanToken.transferFrom(msg.sender, address(this), repayAmount);
        debt[msg.sender] -= repayAmount;
    }

    function _isHealthy(uint256 collateralAmount, uint256 debtAmount) internal view returns (bool) {
        return debtAmount <= (collateralAmount * maxLtvBps) / 10_000;
    }
}
