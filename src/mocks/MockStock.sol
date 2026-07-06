// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Block Street-style mock stock token for the Boost Vault prototype.
/// @dev This intentionally mirrors the simple test-only idea from BlockStreet's MockStock:
/// an ERC20-like stock token with unrestricted minting for local tests.
contract MockStock is MockERC20 {
    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}
}
