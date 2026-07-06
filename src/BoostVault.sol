// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";

contract BoostVault {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BOOST_ITERATIONS = 16;
    uint256 internal constant MAX_UNWIND_ITERATIONS = 16;

    MockERC20 public immutable stock;
    MockERC20 public immutable usdc;
    ILendingAdapter public immutable lending;
    MockRouter public immutable router;
    uint256 public immutable maxTargetLtvBps;

    struct UserPosition {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address => UserPosition) internal positions;

    constructor(
        MockERC20 stock_,
        MockERC20 usdc_,
        ILendingAdapter lending_,
        MockRouter router_,
        uint256 maxTargetLtvBps_
    ) {
        stock = stock_;
        usdc = usdc_;
        lending = lending_;
        router = router_;
        maxTargetLtvBps = maxTargetLtvBps_;
    }

    function depositAndBoostFor(address user, uint256 amount, uint256 targetLeverageBps, uint256 minStockOut) external {
        require(msg.sender == user, "BoostVault: caller is not user");
        require(amount > 0, "BoostVault: zero amount");
        require(targetLeverageBps >= BPS, "BoostVault: leverage below 1x");

        uint256 targetGrossCollateral = (amount * targetLeverageBps) / BPS;
        uint256 targetDebt = targetGrossCollateral - amount;
        uint256 targetLtvBps = targetGrossCollateral == 0 ? 0 : (targetDebt * BPS) / targetGrossCollateral;
        require(targetLtvBps <= maxTargetLtvBps, "BoostVault: target LTV too high");

        stock.transferFrom(user, address(this), amount);
        _supplyStock(amount);

        UserPosition storage p = positions[user];
        p.collateral += amount;

        uint256 remainingDebt = targetDebt;
        uint256 remainingMinStockOut = minStockOut;
        for (uint256 i = 0; remainingDebt > 0 && i < MAX_BOOST_ITERATIONS; i++) {
            uint256 borrowCapacity = _borrowCapacity();
            require(borrowCapacity > 0, "BoostVault: no borrow capacity");

            uint256 borrowAmount = remainingDebt < borrowCapacity ? remainingDebt : borrowCapacity;
            lending.borrow(borrowAmount, address(this));
            p.debt += borrowAmount;

            usdc.approve(address(router), borrowAmount);
            uint256 stepMinStockOut = remainingMinStockOut > borrowAmount ? borrowAmount : remainingMinStockOut;
            uint256 stockOut = router.swapUsdcForStock(borrowAmount, stepMinStockOut, address(this));
            remainingMinStockOut -= stepMinStockOut;

            _supplyStock(stockOut);
            p.collateral += stockOut;
            remainingDebt -= borrowAmount;
        }

        require(remainingDebt == 0, "BoostVault: max iterations reached");
        require(remainingMinStockOut == 0, "BoostVault: min stock out not met");
    }

    function unwindAllFor(address user) external {
        require(msg.sender == user, "BoostVault: caller is not user");
        UserPosition memory p = positions[user];
        require(p.collateral > 0, "BoostVault: no position");

        uint256 remainingCollateral = p.collateral;
        uint256 remainingDebt = p.debt;

        for (uint256 i = 0; remainingDebt > 0 && i < MAX_UNWIND_ITERATIONS; i++) {
            uint256 maxWithdraw = _withdrawCapacity();
            require(maxWithdraw > 0, "BoostVault: no unwind capacity");

            uint256 repayAmount = remainingDebt < maxWithdraw ? remainingDebt : maxWithdraw;
            lending.withdrawCollateral(repayAmount, address(this));
            stock.approve(address(router), repayAmount);
            uint256 usdcOut = router.swapStockForUsdc(repayAmount, repayAmount, address(this));
            usdc.approve(address(lending), usdcOut);
            lending.repay(usdcOut);

            remainingCollateral -= repayAmount;
            remainingDebt -= repayAmount;
        }

        require(remainingDebt == 0, "BoostVault: max unwind iterations reached");
        lending.withdrawCollateral(remainingCollateral, user);
        delete positions[user];
    }

    function position(address user) external view returns (uint256 collateral, uint256 debt, uint256 equity, uint256 leverageBps) {
        UserPosition memory p = positions[user];
        collateral = p.collateral;
        debt = p.debt;
        equity = collateral > debt ? collateral - debt : 0;
        leverageBps = equity == 0 ? 0 : (collateral * BPS) / equity;
    }

    function _supplyStock(uint256 amount) internal {
        stock.approve(address(lending), amount);
        lending.supplyCollateral(amount);
    }

    function _borrowCapacity() internal view returns (uint256) {
        uint256 collateral = lending.collateralBalance();
        uint256 debt = lending.debtBalance();
        uint256 maxDebt = (collateral * lending.maxLtvBps()) / BPS;
        return maxDebt > debt ? maxDebt - debt : 0;
    }

    function _withdrawCapacity() internal view returns (uint256) {
        uint256 collateral = lending.collateralBalance();
        uint256 debt = lending.debtBalance();
        if (debt == 0) return collateral;

        uint256 minCollateral = _ceilDiv(debt * BPS, lending.maxLtvBps());
        return collateral > minCollateral ? collateral - minCollateral : 0;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : ((a - 1) / b) + 1;
    }
}
