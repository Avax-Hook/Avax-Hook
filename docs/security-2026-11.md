# Security fixes, 2026-11-10

An outside report (HolderDividends flash fold) led to a full internal review of every contract. This page lists
what was found, what changed, and which deployed contracts run which code.

## Findings and fixes

| # | Contract | Severity | Issue | Fix | Deployed? |
|---|---|---|---|---|---|
| 1 | HolderDividendsModule | High | A trade's dividend waited unverified and was folded at the *next* reconcile, at that moment's balances. Inside `poolManager.unlock` anyone could `take()` the PoolManager's tokens, call `reconcile()`, and return them: a large cut of the last trade's dividend with zero capital. | `onTransfer` reconciles before syncing shares, so a pending credit always folds at the balances from before any move. | New module; old id deprecated. No token had launched with the old module (v2 or v3), so no funds were affected. |
| 2 | HolderDividendsModule | Low–Med | `recycle` could fold any holder's owed dividends back after 90 days of inactivity. | Only holders whose push payment failed, 90 days after the failure; keepers must forward enough gas. | Same new module. |
| 3 | PlayableSplitBuyer | Medium | A USDC split buy that completed the curve left the unused quote locked in the buyer. | Refunds everything above the pre-buy balance; owner `rescue`. | New buyer; launchpad trust moved from the old buyers (v2 and v3) to it. The old buyers never held stuck funds. |
| 4 | AlliancesModule | Low–Med | Dusting a wallet with `rivalMin` (1 wei allowed) of a rival token barred it from buying. | Per-rival threshold of at least 0.1% of the rival's supply. | New module. |
| 5 | Momentum / CoupledResonator | Low | At max swing the clamp let a buy move the cap in the same second (front-run a victim into `BuyCapExceeded`). | Cap fixed once per second, as in Resonance. | New modules. |
| 6 | ReceiverRuleBase (Allowlist, HolderGated, Plague, Alliances, ConvictionCap) | Low | Remove liquidity, re-add in the same unlock, then spend the LP allowance on a swap to a non-allowed wallet. | An add after a removal in the same tx voids the allowance (reverts if already used). | New modules. |
| 7 | ConvictionCapModule | Low | LP withdrawals counted as buys, so a large LP could not exit in one tx. | LP-removal allowance (ReceiverRuleBase). | New module. |
| 8 | GraduatedSellCapModule | Info | A dust first sell could record a tiny bag. | Bag = max(recorded, balance before the sell). | New module. |
| 9 | DynamicFeeModule | Low | Surge sized on one tx's volume; splitting across txs in a block dodged it. | Per-block volume per side. | New module. |
| 10 | AntiSnipe / AntiBundle | Low | Buy+sell in one tx filled the per-block cap / took a bundle place, locking honest buyers out. | Count net buying. | New modules. |
| 11 | StockOrders (v1 router) | Med/Low | Pots won by a StockOrders fill were credited to the contract with no claim path. | Owner `claimHookCredits`. | Source only (next deployment). |
| 12 | AvaxHookLimitOrdersV2 | Low | A partly filled sell dropped the unsold tokens. | Refund to the maker. | Source only. |
| 13 | SignedPriceFeed | Low | Future timestamps (≤60 s) accepted, then rejected by QuoteRegistry. | Future timestamps rejected. | Source only. |
| 14 | BridgeAttestor | Info | Zero threshold accepted an empty signature set before validators were set. | `threshold == 0` reverts. | Source only (live deploy sets validators in the same run). |
| 15 | StockEscrow | Info | A release that failed for good could never be redirected. | Owner `redirectRelease` (only after the original recipient fails). | Source only. |
| 16 | HookLaunchpadV2 | Low | Tokens sent to the launchpad counted as a trusted caller's deposit in `sellDeposited`. | Stray balance recorded at each curve trade and excluded (partial). | Source only. The only trusted caller using it deposits and sells in one call. |
| 17 | AvaxHookV2 | Info | A swap nested in a module callback would flip `dispatchId` parity mid-dispatch. | Nested dispatch keeps the outer mark. | Source only. No module starts a swap. |

"Source only" means the deployed contract still runs the code from commit `c3b3d6a`; the fix ships with the next
deployment of that contract. Verified sources on Routescan remain the reference for deployed bytecode.

## Deployment (v3 stack)

New module ids replace the old ones in the v3 registry; the old ids are **deprecated**: new launches cannot pick
them, pools that already use them keep running unchanged. On the v2 registry the same ids are deprecated (v2 gets
no new modules; new launches go to v3). Addresses: `script/v3-state.json` (`module:<Name>` = new,
`retired:module:<Name>` = old).

Commands: `forge script script/DeploySecurityFixes.s.sol --rpc-url $AVAX_RPC_URL --broadcast --slow`, then
`V2_STATE=script/v3-state.json node script/hooks-v2-ops.mjs security-fixes <mode>` and
`FIX_DEPRECATE_ONLY=1 OLD_PLAYABLE=0x49AD4C34B09cD9CE12803De3b5349389F2A33fdD node script/hooks-v2-ops.mjs security-fixes <mode>` (v2).

### Live addresses (v3, 2026-11-10)

| Contract | New | Module id | Replaces (deprecated id) |
|---|---|---|---|
| AlliancesModule | `0x95b81e92c0Ad1449FEEB1dEC342217dB9C612374` | 56 | 31 |
| AllowlistModule | `0x9beEC6F5233fF1630c9C94C8E4Bd84F508187e0f` | 57 | 32 |
| AntiBundleModule | `0xd6322F06f45Ca2235578Bc987548B5B2e674414d` | 58 | 33 |
| AntiSnipeModule | `0x0104970C7B3BD17E6D555A0944413a44A2EA420D` | 59 | 1 |
| ConvictionCapModule | `0x21e830E6566abf80436477AC2a5CFd34d7Dc68A2` | 60 | 38 |
| CoupledResonatorModule | `0x419C8324bB5917DD711a819F4e15b9FADb36eD20` | 61 | 39 |
| DynamicFeeModule | `0x2840Fe8FbB3aB10Fe8db56EC9D3eC8EE723264c7` | 62 | 8 |
| GraduatedSellCapModule | `0xDf7c08eDba7BD03B57A451Dfa7e607CaE9355E79` | 63 | 41 |
| HolderDividendsModule | `0x2167DaC4D886d6E98AB592e0e3F1A9e32D43945e` | 64 | 28 |
| HolderGatedModule | `0x61df1E875EDEE2D015eeDE083A89B05FD5e450a5` | 65 | 43 |
| MomentumModule | `0x5C90d00b9AdF5590a9E59F38966EF41bC6c59437` | 66 | 18 |
| PlagueModule | `0x6555954D5da9855fBC1f3D33dc76e8b10BeE2784` | 67 | 48 |
| PlayableSplitBuyer | `0xe396F0b1C8dE17618fBD8fCEa9a51316CCFab5C5` | – | `0x7137…f285` (v3), `0x49AD…3fdD` (v2), both untrusted |

All verified on Routescan. Safe txs: v3 nonces 61–64, v2 nonce 65 (ids 1, 8, 18, 28, 31, 32, 33, 38, 39, 41,
43, 48 deprecated on both registries).

## Router-only transfer rules, 2026-11-12

| # | Contract | Severity | Issue | Fix | Deployed? |
|---|---|---|---|---|---|
| 18 | Transfer-rule modules (below) | High (vesting) / Medium (caps, lists) | Swaps made directly on the PoolManager, outside the AvaxHook router, could keep a position without the token's transfer rules seeing it. | While the rule is active, the module refuses pool swaps whose trader is unknown (not through the AvaxHook router) with `RouterOnly()` (`contracts/v2/modules/lib/RouterOnlyGuard.sol`, called from `onBeforeSwap`; BEFORE_SWAP added to the capabilities). Buys only for receiver rules; buys and sells for the BLOCKS_SELLS rules (vesting, graduated sell caps), whose sell-side revert stops the swap. The curve is untouched. | New modules; old ids deprecated (v3 and v2). |

Trade-off: while a rule is active, aggregators and bots that swap on the PoolManager directly are refused for that
token. The site, the Zap, limit orders and every contract that trades through `AvaxHookRouterV2` keep working (the
router delivers and pulls ERC-20s, so the rule sees every move).

| Module | Active (direct pool swaps refused) | Sides |
|---|---|---|
| HolderVesting | while buys vest (`earlyWindow`, 0 = forever) | buys + sells |
| GraduatedSellCap | `duration` after the pool opens (0 = forever) | buys + sells |
| MaxPerWallet | `duration` after the pool opens (0 = forever) | buys |
| Blocklist | always | buys |
| Grudge | while any grudge of the pool is live (`grudgeLiveUntil`) | buys |
| Chapters | while there is a cap | buys |
| RisingMaxWallet | while there is a cap | buys |
| ConvictionCap / Allowlist / HolderGated / Plague | `duration` after the pool opens (0 = forever) | buys |
| Alliances | while the pact has a rival or a holding cap | buys |

Not affected: dividends, KotH, jackpot, buyer rewards, underwater (claims holders only forfeit rewards: shares and
tickets follow ERC-20 balances / a known trader), LockEarn and HotPotato (they lock ERC-20 balances; turning those
into claims is a transfer to the PoolManager, which the rule refuses), DexOnly (a claims hand-off is one more
contract in the path, the documented contract bypass; no swap is involved).

Commands: `forge script script/DeployClaimsFix.s.sol --rpc-url $AVAX_RPC_URL --broadcast --slow | tee cache/claims-fix.log`,
`node script/record-security-fixes.mjs cache/claims-fix.log` (new = `module:<Name>`, old = `retired-claims:module:<Name>`),
`V2_STATE=script/v3-state.json node script/hooks-v2-ops.mjs claims-fix <mode>` (v3) and
`FIX_DEPRECATE_ONLY=1 node script/hooks-v2-ops.mjs claims-fix <mode>` (v2).
