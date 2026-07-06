# Aqua + Uniswap v4 Hook Prototype

This repo uses the real 1inch Aqua interface plus Uniswap v4 hook interfaces.

## Current architecture

```text
AquaUniV4Hook
  ├─ stores IAqua public immutable AQUA
  ├─ implements Uniswap v4 IHooks from v4-core
  └─ beforeSwap can route hookData into Aqua pull / balance-check actions
```

Important: the previous local `AquaHub` placeholder has been removed. The hook now imports:

```solidity
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
```

## Test command

```bash
forge test -vv
```

## V1 hook actions

`beforeSwap` decodes hook data as:

```solidity
(AquaAction action, address maker, bytes32 strategyHash, address token, uint256 amount, address recipient)
```

Supported actions:

- `Pull`: calls `AQUA.pull(maker, strategyHash, token, amount, recipient)`
- `CheckBalance`: reads `AQUA.rawBalances(maker, address(this), strategyHash, token)` and requires enough active Aqua balance

## Important v4 deployment note

Uniswap v4 hook permissions are encoded in the hook contract address. This prototype proves interface integration, callback access control, and Aqua routing behavior. A real deployment still needs address mining so the deployed hook address has the `BEFORE_SWAP_FLAG` bit set.
