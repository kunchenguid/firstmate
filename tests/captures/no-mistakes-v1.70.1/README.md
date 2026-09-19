# AXI run-state input captures

These files own recorded serialized CLI inputs and a persisted run-inventory projection for the `test_captured_*` cases in `../../fm-crew-state.test.sh`.
They were captured on 2026-09-14 at 22:06 UTC with `no-mistakes version v1.70.1 (9c380d4) 2026-09-07T20:47:58Z`.
They are replay inputs, not evidence that every composed scenario was driven live.

## Capture provenance

Each status file is unchanged stdout from `no-mistakes axi status --run <id>` executed from the test-phase worktree, without entering the recorded run's checkout.
The command exited zero for all five run-specific captures.
`uninitialized.toon` is unchanged stdout from `no-mistakes axi status` in that worktree, which exited one.
Update notices on stderr are not part of the captured stdout contract.

| File | Recorded run ID | Observed state |
| --- | --- | --- |
| `replacement.toon` | `01M2GAWMSDQK4B5EA9GZW35RXE` | Live CI step after a rerun |
| `superseded.toon` | `01M2FNFPK984YP0EHFTD1XEF8P` | Same-branch predecessor cancelled with `superseded by new push` |
| `parked.toon` | `01M20NDQH0G96AQYH1EHWGKT5F` | Separate branch parked at the test gate with one finding |
| `failed.toon` | `01M289YXN7V0513AKCF53MJ1BC` | Failed push step |
| `completed.toon` | `01M2FG7SEEP1VBZ3B5SX35BJ6Q` | Completed validation |

`same-branch-inventory.json` preserves all nine rows for the replacement's branch, selected in a read-only transaction from the real `state.sqlite` database.
The projection is `id, repo_id, branch, status, head_sha, created_at`, ordered by `created_at DESC, id DESC`.
The source contained 78 runs for repository `acf4a767348a`; its `runs` schema confirmed the fixture's text identity/status/head fields and integer creation times.
No branch in that repository had two recorded live runs at capture time.

`overview.toon` is the unchanged `count` and `runs` section emitted by the real `no-mistakes axi` executable against an isolated database copy of those 78 recorded runs.
Only the copy's repository `working_path` was relocated to the permitted worktree; no pipeline was initialized or controlled.
The copy omitted step data and had no daemon, so the unrelated active-run detail from that output is intentionally excluded.
The retained section demonstrates the actual ten-row cap, row order, quoting, and field layout.
Original stdout, source projections, and SHA-256 digests were retained in the test-phase evidence directory under `real-anchors/`.

## Replay transformations and limits

`captured_axi_status` substitutes only the run ID, branch, and head fields so the captures bind to disposable Git repositories.
Status, outcome, steps, findings, and gate bytes remain unchanged.
The inventory replay substitutes its disposable repository key and path, preserves every captured same-branch row, and hashes the database before and after the state read to detect writes.
Its ambiguity case explicitly changes one hidden cancelled row to running; this is a counterfactual, not a captured competing-live history.
The original review-gate, rebased-head, unrelated-metadata, and malformed-input assertions remain unchanged.

| Required shape | Real anchor used | What remains unproven live |
| --- | --- | --- |
| Superseded cancellation yields to a parked replacement | Genuine cancellation/successor history plus separately captured parked-gate output | The captured successor was in CI, and the captured gate was at test on another branch; a same-rerun replacement parked specifically at review on an unfetched rebased head was not captured |
| Competing live identities beyond the cap and beside unrelated metadata | Real capped overview and complete nine-row branch history | No real branch had two live rows; changing a hidden row to running and injecting unrelated unusual metadata are controlled fixtures |
| Newer failure outranks an older live run | Genuine failed status and genuine live status | This relative ordering with both states on one branch was composed, not observed |
| Changing or unverifiable authority | Genuine live and cancelled status formats | The transition between reads, malformed records, wrong identities, and unreadable inventory are injected; no live race or corrupt production inventory was captured |
| Uninitialized repository preserves worker reporting | Actual uninitialized stdout; earlier live lifecycle-event/pane evidence | The portable test replays stdout and uses the existing pane fake |
| Development continues after completed validation | Genuine completed status | Advancing Git and emitting worker events after completion are disposable-repository actions, not an observed recorded worker sequence |
| Optional inventory dependencies are absent | Genuine gate output and capped inventory | Missing Python/SQLite and complete-inventory compositions are simulated; the captured host had both dependencies |

Passing replay assertions establish behavior for these explicit inputs, not the absent live scenarios in the final column.
