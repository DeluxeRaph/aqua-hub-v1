// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal Compound/Everst-style lending mock.
/// @dev It intentionally exposes bToken-like verbs (`mintCollateral`, `borrow`,
/// `repayBorrow`, `redeemUnderlying`) so the adapter maps the BoostVault's
/// generic lending calls onto an Everst-shaped backend.
contract MockEverst {
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

    function mintCollateral(uint256 amount) external returns (uint256) {
        require(amount > 0, "MockEverst: zero mint");
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateral[msg.sender] += amount;
        return 0;
    }

    function redeemUnderlying(uint256 amount, address receiver) external returns (uint256) {
        require(collateral[msg.sender] >= amount, "MockEverst: insufficient collateral");
        uint256 remainingCollateral = collateral[msg.sender] - amount;
        require(_isHealthy(remainingCollateral, debt[msg.sender]), "MockEverst: unhealthy redeem");
        collateral[msg.sender] = remainingCollateral;
        collateralToken.transfer(receiver, amount);
        return 0;
    }

    function borrow(uint256 amount) external returns (uint256) {
        require(amount > 0, "MockEverst: zero borrow");
        uint256 newDebt = debt[msg.sender] + amount;
        require(_isHealthy(collateral[msg.sender], newDebt), "MockEverst: borrow exceeds max LTV");
        debt[msg.sender] = newDebt;
        loanToken.transfer(msg.sender, amount);
        return 0;
    }

    function repayBorrow(uint256 amount) external returns (uint256) {
        require(amount > 0, "MockEverst: zero repay");
        uint256 repayAmount = amount > debt[msg.sender] ? debt[msg.sender] : amount;
        loanToken.transferFrom(msg.sender, address(this), repayAmount);
        debt[msg.sender] -= repayAmount;
        return 0;
    }

    function borrowBalanceCurrent(address account) external view returns (uint256) {
        return debt[account];
    }

    function balanceOfUnderlying(address account) external view returns (uint256) {
        return collateral[account];
    }

    function _isHealthy(uint256 collateralAmount, uint256 debtAmount) internal view returns (bool) {
        return debtAmount <= (collateralAmount * maxLtvBps) / 10_000;
    }
}
