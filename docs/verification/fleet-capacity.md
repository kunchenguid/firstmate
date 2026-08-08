# Fleet capacity verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the shared fleet-capacity projection (`fm-fleet-capacity.v1`) and its shadow-stage guarantees.
Current facts, not task chronology: the integration base, the cron-sentinel quarantine, and the shadow-only latency measurement.

## Integration base

The reviewed reconciliation base is commit `454b10d` (`reconcile(fleet): merge origin/main onto the fleet-refill integration base`), created on 2026-08-08.
It merges local `main` tip `d40fd7f` and `origin/main` tip `833a9a2`, whose common ancestor is `2cf0283b`.
Both histories are preserved: local `main` owns `bin/fm-fleet-refill.sh` and the accepted fleet lifecycle design, while upstream owns its own five commits, and the twelve duplicated PRs resolve as identical content with the refill script preserved from the local side.

The integration branch passed the canonical review pass before any runtime work.
Review verdict: panel `7d94ba3c...` with routes `minimax.minimax-m3` and `qwen.qwen3.7-max`, verdict `2xPASS`, closure-satisfied, on 2026-08-08.

Ancestry proofs, run from the branch under verification:

```sh
git log --format='%H %P' -1 454b10d
git merge-base d40fd7f 833a9a2
git merge-base --is-ancestor d40fd7f 454b10d && echo 'local main contained'
git merge-base --is-ancestor 833a9a2 454b10d && echo 'origin main contained'
```

Verified:

```text
454b10d7fe3233c256047f16be1658dd3ac762d6 d40fd7f6b74c064744b903601b2fce3e1ba730e1 833a9a25bcf2ae522d6f93dbbd9911a6d8e7c409
2cf0283b811e81a821cddf5b7f74e1f7de8e2881
local main contained
origin main contained
```

## Cron sentinel quarantine

The fleet-depth cron sentinel was quarantined to alert-only on 2026-08-08 (commit `9e7247b`).
The decision: legacy capacity arithmetic is never authoritative during the shadow stage, no dispatch decision depends on it, and the shadow object is measured independently of it.

The private half lives in the real home and was completed and verified by firstmate.
The real home's `data/fleet-depth-check.sh` was replaced with a narrow alert-only unknown-capacity sentinel.
Firstmate-verified facts: the sentinel passes `bash -n`, is mode `775`, its real query log shows `open_beads=180` with `capacity=unknown`, no wake was appended, `dispatch-staged.flag` is unchanged, and no legacy manifest, output, or stager symbols remain.

The tracked half: `bin/fm-fleet-refill.sh` is quarantined so it always reports `capacity=unknown`, never emits a dispatch verdict, and never stages work; the serialization-debt safety probe and the authoritative bead-query diagnostic remain.
The shadow recording added on top of the quarantine (this task) never changes that verdict.

Removal is scheduled after the post-parity cutover: the private sentinel and its crontab entry are removed at cutover after the parity proof, and their removal is verified afterwards with home-aware `rg -uu` plus crontab inspection.

## Latency (shadow)

Measured on 2026-08-08 against integration base `454b10d`.

`/usr/bin/time` (GNU time) is not installed on this host, so the measurement used the bash `time` keyword with `TIMEFORMAT='count-json wall=%R s'`, which emits the same output shape:

```sh
TIMEFORMAT='count-json wall=%R s'
time bin/fm-fleet-refill.sh --count-json >/dev/null
```

Exact output, worktree empty-fleet baseline:

```text
count-json wall=0.068 s
```

Real-fleet-size read-only measurement, projecting the real home's state without modifying it:

```sh
TIMEFORMAT='count-json wall=%R s'
time FM_STATE_OVERRIDE=/home/holu/fmate/firstmate/state bin/fm-fleet-refill.sh --count-json >/dev/null
```

Exact output:

```text
count-json wall=7.898 s
```

The projection only reads the real home's state: git status remained clean, `state/attempts` gained no files, and the 16 meta records were unchanged before and after.
The real-fleet run exceeds the 2000 ms expectation with the default per-read timeout (2 s) at the current fleet size, so the Task 13 cutover gate owns the accepted latency posture (parallel reads and the total deadline are configurable before consumers switch).

## Decision OS contract

Audience: maintainer verification. Version-scoped evidence for the attended Decision OS main-steward adapter (`bin/fm-br-receipt.sh`, Task 5 of the fleet-refill implementation) and its live contract guard (`tests/live-decision-os-contract.test.sh`).

Pinned installed contracts, verified on 2026-08-08 against the real registered clone `/home/holu/decision-os` and the installed CLIs:

- `br --version` = `0.2.19`.
- `br comments add <ID> -m <MESSAGE>` (alias `--content`); `br comments list <ID> --json` returns a JSON array whose items carry `.text`; there is NO `br comments show` (`br comments show` exits 2 with the parent help).
- `br show --json <id>` returns a JSON ARRAY (one element per issue), never an object; the adapter's jq requires an array and fails closed on any other shape (`br show --json ""` returns an INVALID_ID error object, which is not an array).
- `br ready --json` returns an array when run from inside a clone (`.beads/*.db` discovery is cwd-based) and a NOT_INITIALIZED error object otherwise.
- `br close`, `br update --status`, and `br ready --help`/`br show --help` accept `--no-auto-flush`; br reads default to auto-flushing the tracked `.beads/issues.jsonl` export, so read-only br invocations in the guard pass `--no-auto-flush` and never write the tracked JSONL.
- `scripts/br_worktree_storage.py` subcommands and shapes: `verify-session --repo <path> [--agent <name>]` (prints `verify-session: OK (storage=...)`; best-effort `[session]` repair writes nothing when no bead id resolves from the checkout), `preflight --repo <path> --status-out <path> --br-bin <path>` (writes only to the isolated evidence copy under the status-out parent and fails if source store hashes change), `claim <issue_id> --repo <path> --agent <name> --br-bin <path>`. `PYTHONPATH=src .venv/bin/python` is the installed invocation.

Live guard run, once with the env gate on, 2026-08-08:

```sh
cd /home/holu/.treehouse/firstmate-b8697d/1/firstmate
FM_LIVE_DECISION_OS=1 bash tests/live-decision-os-contract.test.sh
```

Exact output (exit 0):

```text
ok - verify-session --repo --agent works
ok - br show --json returns an array
ok - br comments list exists and comments show does not
ok - preflight requires and accepts --repo --status-out --br-bin
```

Run again without the env gate it self-skips: `skip: FM_LIVE_DECISION_OS not set (live Decision OS contract guard)`, exit 0.

No failure was observed. Note: the registered clone is a live store with active tracker-writing lanes; a dirty `.beads/issues.jsonl` working tree observed during the run is live lane traffic (an unrelated no-mistakes lane was actively writing `.beads` at the time), not output of the guard, and was left untouched.
