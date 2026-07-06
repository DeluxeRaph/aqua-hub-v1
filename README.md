# Aqua + Uniswap v4 Hook Prototype

A Uniswap v4 hook prototype that connects v4 pools to the real [1inch Aqua](https://github.com/1inch/aqua) shared-liquidity interface.

The current flow is intentionally simple:

```text
Register pool once -> swap normally -> hook pulls Aqua USDC for that pool -> v4 swap settles
```

## What this proves

- The hook uses the real `IAqua` interface from `@1inch/aqua`.
- The hook implements Uniswap v4 `IHooks` from `v4-core`.
- Only the configured v4 `PoolManager` can call `beforeSwap`.
- Each v4 pool can be registered with an Aqua maker strategy.
- Normal swaps use the registered pool config; swappers do not pass Aqua-specific instructions.
- USDC can act as the hub token for multiple spoke pools such as `USDC/WETH` and `USDC/HYDX`.
- Local and Base fork tests prove Aqua-funded v4 swaps settle through PoolManager.

## Current architecture

```text
AquaUniV4Hook
  ├─ stores IAqua public immutable AQUA
  ├─ stores the configured Uniswap v4 PoolManager
  ├─ implements Uniswap v4 IHooks from v4-core
  ├─ stores PoolId -> AquaPoolConfig
  └─ on beforeSwap, pulls the registered shared input token from Aqua into the v4 settlement sender
```

The core pool config is:

```solidity
struct AquaPoolConfig {
    bool enabled;
    address maker;
    bytes32 strategyHash;
    address sharedToken;
    uint256 maxPullPerSwap;
}
```

The hook imports the real Aqua and v4 interfaces:

```solidity
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
```

## Registered-pool flow

The hook owner registers each v4 pool once:

```solidity
hook.registerAquaPool(
    poolKey,
    maker,
    strategyHash,
    sharedToken,
    maxPullPerSwap
);
```

That creates this routing key:

```text
PoolId -> maker -> strategyHash -> sharedToken -> maxPullPerSwap
```

When the v4 `PoolManager` calls `beforeSwap`, the hook:

1. Looks up the pool's registered Aqua config.
2. Requires the registered `sharedToken` to be the swap input token.
3. Checks the maker's live Aqua balance:

   ```solidity
   AQUA.rawBalances(maker, address(this), strategyHash, sharedToken)
   ```

4. Enforces `maxPullPerSwap`.
5. Pulls the needed shared-token amount from Aqua into the v4 settlement sender:

   ```solidity
   AQUA.pull(maker, strategyHash, sharedToken, amountNeeded, sender)
   ```

The hook returns zero custom accounting deltas. The swap still settles through normal v4 PoolManager accounting.

## Tests

Run the suite:

```bash
forge test -vv
```

The key tests are:

| Test | What it proves |
|---|---|
| `testGivenRegisteredAquaPool_WhenPoolManagerCallsBeforeSwap_ThenHookPullsAquaFromPoolConfig` | registered pool config pulls Aqua liquidity |
| Local USDC/WETH swap proof | local `USDC -> WETH` v4 swap is funded by Aqua |
| Base fork USDC/WETH + USDC/HYDX swap proof | Base fork uses live Aqua + live v4 PoolManager + real Base USDC/WETH + local HYDX across two pools |
| Registered-routing guard | callers cannot override the pool's registered Aqua route |

## Base fork proof

The Base fork test uses:

| Component | Address/source |
|---|---|
| 1inch Aqua | `0x499943E74FB0cE105688beeE8Ef2ABec5D936d31` |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Base USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Base WETH | `0x4200000000000000000000000000000000000006` |
| HYDX | local fork ERC20 test token |

It initializes two pools in one flow:

```text
USDC / WETH
USDC / HYDX
```

Then it swaps through both pools and asserts Aqua USDC balances decrease while the taker receives WETH and HYDX.

## Important v4 deployment note

Uniswap v4 hook permissions are encoded in the hook contract address. This prototype mines/deploys suitable hook addresses in tests. A real deployment still needs address mining so the deployed hook address has the `BEFORE_SWAP_FLAG` bit set.

## Status

This is a prototype proving the Aqua-funded v4 pool flow. It is not production-ready and still needs deeper security review, deployment scripts, and production liquidity/risk controls before mainnet use.
