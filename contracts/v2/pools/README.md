# Pools profile (existing tokens)

`PoolCoordinatorV1`, `PoolRouterV1`, `AvaxHookPoolsV1` and the pot modules under `modules/` make up the
existing-token profile. Addresses: `script/pools-state.json` (the retired first deployment, which used the
plain `AvaxHookV2` and the launch pot modules, is kept in `script/pools-state.retired-v1.json`).

## Pools-only rules (audit fixes)

| Finding | Where | Rule |
|---|---|---|
| M-1 partial fills | `AvaxHookPoolsV1`, `PoolRouterV1` | A swap must consume its whole input: the pool's input delta must equal `amountIn - beforeSwapCut` (hook, `PartialFillNotAllowed`), and the router reverts `PartialFill` when `paid != amountIn`. Swaps in a pool without liquidity revert, so they can't move its price. |
| L-1 rescue | `modules/*PotPoolsModule` | `rescuePool(poolId)`; `rescue(token)` reverts `UseRescuePool`. |
| L-2 squatting | `PoolCoordinatorV1.openFeeFor` | `openFee * (1 + n / 10)` for a pair's n-th pool (0-based, both orientations); cap 1,000 pools per pair kept. |
| L-3 creator take | coordinator, pot modules | base LP fee <= 1% (`MAX_BASE_FEE_PIPS = 10_000`), creator fee <= 1%, pot share <= 2%, orphaned pots go to the protocol recipient (never the opener). |
| L-4 empty pools | `PoolCoordinatorV1.openPool` | both seed legs required, liquidity >= `MIN_SEED_LIQUIDITY` (1e6). |
| I-2 quote spoofing | `PoolRouterV1.quote` | `QuoteResult` must echo a per-call tag only the router knows. |
| I-5 pause | `PoolCoordinatorV1` constructor, `DeployPools` | deployed paused; the deploy script asserts it. |

## Shared sources and the live launch profile

`AvaxHookV2.sol`, `modules/LedgerModuleBase.sol`, `modules/LastBuyerPotModule.sol` and
`modules/NthBuyPotModule.sol` gained only `virtual` (and, for the hook's `beforeSwap`/`afterSwap`,
`external` -> `public virtual`) so the pools versions can extend them. Behaviour is unchanged. Compiled
with the repo settings, `AvaxHookV2`'s runtime bytecode is identical to before, apart from the metadata
hash. The live launch-profile contracts (`script/v2-state.json`) match the sources at commit **68fe6da**:
the shared files are unchanged there since 150ba9a. Use that commit to reproduce or verify
their bytecode.
