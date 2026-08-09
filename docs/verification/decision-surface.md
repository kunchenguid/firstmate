# Decision-surface verification

Audience: maintainer verification.

This record holds reusable evidence for two active guarantees of `bin/fm-decision-surface.sh`: that the platform seam's wiring state is measured rather than assumed, and that the claim checks can actually fail.
`bin/fm-decision-surface.sh`'s header owns the command contract, [`../configuration.md`](../configuration.md) "Platform decision-surface seam" owns the seam configuration, and `.agents/skills/decision-surface/SKILL.md` owns the handling procedure.

Verified on 2026-08-09 on Linux 6.18.33.2-microsoft-standard-WSL2 with jq 1.8.1.

## The platform seam is reachable and still not wired

The deterministic platform publishes `FirstMateDecisionSurface` through its own AXI launcher.
Reachability and wiring are separate facts, and only the second decides whether the fleet may consume it.

Probed against the platform at commit `f0da880` ("Add capability binding authority law"), which carries the D8 projection landed at `4d995ff`:

```sh
$ FM_DECISION_SURFACE_PLATFORM="<platform>/platform.sh" \
    bin/fm-decision-surface.sh platform-seam --probe-platform --json \
    | jq -c '{configured,reachable,fleet_identities_resolved,wiring}'
{"configured":"present","reachable":"true","fleet_identities_resolved":0,"wiring":"not-wired"}
```

The launcher answers, so the command is not missing or broken.
It resolves none of this home's fleet task ids, because the projection is keyed by platform work identities and its registry is fixture-backed:

```sh
$ "<platform>/platform.sh" decision-surface --fleet | head -3
schema_version: 1.0.0
kind: FirstMateDecisionSurfaceFleetView
generated_at: "2026-08-08T00:00:00Z"
$ "<platform>/platform.sh" decision-surface WRK-E82FCC2002D0 | grep state_snapshot_id
  state_snapshot_id: fixture-state-v1
```

That is why the fleet-side surface composes the fleet's own landed owners instead of consuming the platform projection, and why `wiring` stays `not-wired`.
Re-run the probe above after any platform change that claims to resolve fleet task identities; a `fleet_identities_resolved` above zero is the condition that retires the marker.

## The claim checks are red-capable

A check that only ever answers "contradicted" enforces nothing, so each guarantee was confirmed by breaking it and watching the suite fail.
Each mutation was applied to `bin/fm-decision-surface.sh`, the suite run, and the file restored:

| Mutation | Failure observed |
|---|---|
| capacity check never refuses an admitting fleet | `not ok - a capacity claim against an admitting fleet must be refused: expected exit 3, got 0` |
| a ruled decision reads as still open | `not ok - reporting a ruled decision as pending must be refused: expected exit 3, got 0` |
| duplicate check ignores live tasks | `not ok - the refusal must say the work exists, not merely that a record matched` |
| `unevaluable` returns the success status | `not ok - an undecidable admission must be unevaluable, never a quiet pass: expected exit 4, got 0` |
| seam always reports wired | `not ok - an unconfigured seam is not wired` |
| an incoherent inventory is ignored | `not ok - an incoherent inventory must not answer the duplicate question: expected exit 4, got 0` |
| the probe runs unbounded when no bounding tool exists | `not ok - with no bounding tool the probe must report unreachable, never run unbounded` |

Refresh this evidence with `bin/fm-test-run.sh tests/fm-decision-surface.test.sh`, which passes twelve cases against canned `fm-fleet-snapshot.v1` documents and needs no live fleet, worker, or platform.
