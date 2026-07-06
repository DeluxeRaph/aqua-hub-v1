# Aqua Hub v4 Hook Prototype

This repo is intentionally reset to the Aqua + Uniswap v4 shape:

- `AquaUniV4Hook` **inherits `AquaHub`** for hub/spoke liquidity accounting.
- `AquaUniV4Hook` **implements Uniswap v4 `IHooks`** from `v4-core`.
- V1 enables only `beforeSwap` and uses hook data to draw or release hub-side capacity.
- V1 returns zero custom swap delta and no fee override; it does not use risky return-delta permissions.

## Architecture

```text
AquaUniV4Hook
  ├─ is AquaHub
  │    ├─ hub asset
  │    ├─ global capacity
  │    ├─ per-pool capacity
  │    └─ per-pool usage
  └─ is Uniswap v4 IHooks
       └─ beforeSwap called by PoolManager
```

## Test command

```bash
forge test -vv
```

## Important v4 deployment note

Uniswap v4 hook permissions are encoded in the hook contract address. This prototype proves the contract inheritance, callback access control, and Aqua accounting behavior. A real deployment still needs address mining so the deployed hook address has the `BEFORE_SWAP_FLAG` bit set.
