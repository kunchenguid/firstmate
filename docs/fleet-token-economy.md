# Fleet token economy

The point of federated mode is to run several operators' first mates at once **without
paying for several idle LLMs**. The whole coordination layer is **bash — zero LLM
tokens** — and each operator's expensive LLM is invoked only when it has real work.

## The one rule: the LLM is event-driven, never polling

A first-mate primary is an LLM (claude/opus, etc.). The expensive failure mode is an
always-on primary that *thinks on a timer*. Federated mode forbids that:

```
join  ──►  fm-fleet-wait.sh <op>          # BASH. blocks. 0 tokens.
             │  (heartbeats every interval, also bash)
             ▼
        a fresh claim for <op> appears     # another op routed/handed work here
             │
             ▼
        wait exits 0  ──►  wake the LLM primary ──► it does the work ──► back to wait
```

`fm-fleet-wait.sh` returns **only** when this operator has an item stamped
`claimed-by:<op> status:claimed`. Until then the primary is not running a turn, so it
costs nothing. This is the single biggest saving vs. N self-polling primaries.

## Everything coordination-related is bash (0 tokens)

| Concern | Mechanism | Tokens |
|---|---|---|
| Claim / route / handoff / reap | `fm-fleet.sh` (flock + awk) | 0 |
| Liveness | `fm-fleet.sh heartbeat` (file write, **no event line**) | 0 |
| Wait-for-work | `fm-fleet-wait.sh` (poll/block) | 0 |
| Quota headroom | `quota-axi` published into `operators.md` | 0 |
| Sync between operators | shared group-writable FS (same box) — live, no bus | 0 |

Heartbeats deliberately write **no** `events.log` line - liveness is transient, so it never bloats the audit trail or churns the lock.
The data-only KB contract is owned by the `bin/fm-fleet-lib.sh` header.

## Don't hand work to a drained account

Routing is quota-aware without any cross-user auth: each operator publishes its own
`quota-axi` min headroom into its `operators.md` row on heartbeat, and `fm-fleet.sh
route` skips any operator below the floor (falls to overflow). Before claiming, a
primary can gate on `fm-fleet.sh budget` (`fm_fleet_budget_ok`). This keeps a
near-limit account from being handed work it would fail partway through (wasted
tokens), routing it to a peer with headroom instead.

`budget` is not a raw-headroom gate alone. With a `quota-axi` new enough to report
quota-window pace, an operator whose headroom clears `FM_FLEET_QUOTA_MIN` is still
held back when a **fresh** surface is burning its window faster than the clock and
its worst reserve has fallen below `FM_FLEET_RESERVE_MIN` — that account is on
track to hit the wall mid-task, which wastes exactly the tokens the headroom floor
exists to protect. The raw floor stays dominant, the verdict always names the
headroom/pace/reserve facts behind it, and against an older payload carrying no
pace data the pace floor is skipped entirely. See
[fleet-addon.md](fleet-addon.md#per-surface-pace-quota-axi--0115-schemaversion-3).

## Fit-based model cost

`config/crew-dispatch.json` can tier crewmate dispatch (haiku for rote, sonnet for web/product, opus/codex-high for hard backend).
Firstmate's intake judgment and dispatch-profile rules own that model choice; the fleet queue only keeps idle coordination in bash.

## Knobs (env, all bash-side)

| Var | Default | Meaning |
|---|---|---|
| `FM_FLEET_WAIT_INTERVAL` | 15s | wake-watcher poll cadence |
| `FM_FLEET_HEARTBEAT_TTL` | 90s | after this with no heartbeat, routing treats an operator offline |
| `FM_FLEET_QUOTA_MIN` | 5 (%) | headroom floor below which routing/claim skips an operator |
| `FM_FLEET_RESERVE_MIN` | -25 (points) | worst tolerated pace reserve before conservation pressure alone holds `budget` back; `-100` disables the pace floor |

## Net effect

Three operators can be "online" continuously. Their **LLMs** only spend tokens while
actually executing a claimed task; the rest of the time the fleet is coordinated
entirely in bash. Idle cost across the whole fleet ≈ 0.
