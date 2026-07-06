// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

contract MockRouter {
    MockERC20 public immutable stock;
    MockERC20 public immutable usdc;

    constructor(MockERC20 stock_, MockERC20 usdc_) {
        stock = stock_;
        usdc = usdc_;
    }

    function swapUsdcForStock(uint256 usdcAmount, uint256 minStockOut, address receiver) external returns (uint256 stockOut) {
        stockOut = usdcAmount;
        require(stockOut >= minStockOut, "MockRouter: slippage");
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        stock.transfer(receiver, stockOut);
    }

    function swapStockForUsdc(uint256 stockAmount, uint256 minUsdcOut, address receiver) external returns (uint256 usdcOut) {
        usdcOut = stockAmount;
        require(usdcOut >= minUsdcOut, "MockRouter: slippage");
        stock.transferFrom(msg.sender, address(this), stockAmount);
        usdc.transfer(receiver, usdcOut);
    }
}
