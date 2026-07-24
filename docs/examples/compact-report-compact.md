# Widget-cache eviction scout (synthetic fixture)

Synthetic fixture only; demonstrates the compact internal-report contract, not a real Firstmate finding.

## Outcome

Eviction policy is not the primary cause of the reported latency spikes; two real defects found and fixable now, one credential exposure needs a captain decision before any action.

## Findings

- [perf] src/cache/evictor.py:142 - fixed 30s sweep interval falls behind under sustained high write volume - backlog grows unbounded (12k+ entries / ~40MB stale memory in a 5min synthetic run), a plausible secondary contributor to GC-pressure latency.
- [bug] src/cache/evictor.py:89 - max-age boundary check uses `>` instead of `>=` - an entry exactly at max age survives one extra sweep cycle before eviction.
- [security] src/cache/config_loader.py:34 - live Redis credential checked into config/cache.yaml (see Full detail).

## Evidence

- Backlog growth: `python -m cache.bench --profile evict` (5min synthetic load) - backlog counter climbed from 0 to 12,000+ entries.
- Off-by-one repro: `scripts/repro_offbyone.py` (included on branch) - entry at exact max-age cutoff survives sweep N, evicted only on sweep N+1.

## Verification performed

- `pytest tests/cache/` - all 42 existing tests pass on the current branch; no code changed during the investigation.
- Synthetic load benchmark re-run twice - backlog-growth observation reproducible, not a one-off.

## Recommendation

Ship the adaptive-sweep-interval and boundary-check (`>=`) fixes as a normal follow-up change with regression tests for both.
Hold the credential finding for the captain (see Unresolved captain decisions); no other action recommended until that decision lands.

## Unresolved captain decisions

- [key=widget-cache-credential-rotation] Rotate the config/cache.yaml Redis credential now as a security incident, or schedule it as a follow-up hardening task? Blast radius (whether this file was ever pushed to a fork or mirror outside this org) is unknown and needs the captain's judgment on urgency.

### Full detail: security finding at config_loader.py:34

`src/cache/config_loader.py:34` reads the Redis connection string, including what appears to be a live password, from the checked-in `config/cache.yaml` rather than from an environment variable or secret store.
This report did not change the file and did not attempt to use or validate the credential.
Flagging only, because a checked-in live credential is a security-sensitive finding whose scope (rotate now vs. schedule later) and blast radius (whether this file was ever pushed to a public mirror) genuinely require the captain's judgment rather than a compact record or autonomous action.
