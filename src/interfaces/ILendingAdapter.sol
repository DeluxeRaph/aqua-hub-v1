// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILendingAdapter {
    function supplyCollateral(uint256 amount) external;
    function withdrawCollateral(uint256 amount, address receiver) external;
    function borrow(uint256 amount, address receiver) external;
    function repay(uint256 amount) external;
    function collateralBalance() external view returns (uint256);
    function debtBalance() external view returns (uint256);
    function maxLtvBps() external view returns (uint256);
}
