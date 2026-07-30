# Widget-cache eviction scout (synthetic fixture)

This is a synthetic fixture used only to demonstrate the compact internal-report contract owned by `.agents/skills/compact-report-format/SKILL.md`; it does not describe a real Firstmate finding.

We were asked to look into reports of intermittent latency spikes in the widget-cache service and to determine whether the eviction policy is contributing.
To answer that, we read through the eviction sweep and its configuration loader end to end, ran the service's existing benchmark harness against a synthetic high-write-volume workload, and re-ran the existing test suite to make sure nothing in the investigation itself changed behavior.
Overall, the investigation found that the eviction policy is not the primary cause of the reported spikes, but it did surface two real defects worth fixing and one credential-handling issue that needs a human decision before anything changes.
The recommendation is to fix the two defects immediately as a normal follow-up change, and to hold the credential question for the captain rather than act on it directly.

The first thing we found was that the cache eviction sweep in `src/cache/evictor.py` at line 142 runs on a fixed 30 second timer regardless of load, which under sustained high write volume causes it to fall behind and build up a backlog of expired-but-not-yet-evicted entries.
We confirmed this by running `python -m cache.bench --profile evict` locally and observing the backlog counter climb from 0 to over 12,000 entries during a 5 minute synthetic load run, which corresponds to roughly 40MB of stale memory retained past its expiry, and is a plausible contributor to secondary GC-pressure latency even though it is not the primary spike cause.

Second, we found a real off-by-one bug in `src/cache/evictor.py` at line 89, in the boundary check for the maximum entry age: the comparison uses `>` where it should use `>=`, which means an entry exactly at the configured max age survives one extra sweep cycle before eviction.
We verified this by writing a small reproduction script (`scripts/repro_offbyone.py`, included in the branch) that inserts an entry with a max-age timestamp exactly equal to the cutoff and confirms it is not evicted on the sweep where it should be, only on the following one.

Third, and most seriously, while reading `src/cache/config_loader.py` at line 34 we noticed that the Redis connection string, including what appears to be a live password, is read from a checked-in `config/cache.yaml` file rather than from an environment variable or secret store.
We did not change this file, and did not attempt to use or validate the credential, but flagged it immediately since checked-in credentials are a security-sensitive finding requiring a human decision on scope (rotate now vs. schedule a follow-up) and blast radius (whether this credential was ever pushed to a public mirror) rather than a compact one-line record.

Verification performed for the two eviction defects: ran the existing test suite (`pytest tests/cache/`) before making any change and confirmed all 42 existing tests still pass on the current branch, confirming the investigation itself made no code changes.
We also manually re-ran the synthetic load benchmark twice to confirm the backlog-growth observation was reproducible and not a one-off fluke.

Our recommendation is to ship a fix for the fixed-interval sweep (make the interval adaptive to backlog size) and the off-by-one boundary check as a normal follow-up change with regression tests added for both, and to treat the credential exposure as a decision for the captain: specifically, whether to rotate the credential immediately as a security incident, or to schedule it as a follow-up hardening task, given we don't yet know if this file was ever pushed to a fork or mirror outside this org.
That determination requires the captain's judgment on urgency and blast radius, which is why we are not proceeding further on that third finding ourselves.

To summarize: the eviction policy is not the primary cause of the reported latency spikes, but the investigation found two real, fixable defects (the fixed-interval sweep falling behind under load, and the off-by-one boundary check letting entries survive an extra sweep cycle) and one security-sensitive credential exposure that is not ours to resolve unilaterally.
We recommend shipping the two defect fixes as a normal follow-up change with regression tests, and holding the credential-rotation question open for the captain's decision on urgency and blast radius before anyone touches that file.
