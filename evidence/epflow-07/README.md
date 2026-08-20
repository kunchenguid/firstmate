# evidence/epflow-07 - optional `delivery:` story frontmatter key

Captures each story's intended delivery mode at scaffold/review time, when context is freshest, instead of re-classifying it by judgment at dispatch (report G-mode).
A story may now carry an OPTIONAL `delivery:` key (`no-mistakes` | `direct-PR` | `local-only`) in its frontmatter; absence resolves the mode at dispatch by the existing rules, unchanged.

## What changed

- **Contract (`bin/fm-epic-lint.sh`).** `delivery:` is now an allowed optional key (the seven required keys are unchanged). When present, its value must be one of the three known modes or the lint fails with the exact reason. A `direct-PR` story on a `no-mistakes-prod-only` repo is WARNED, never failed, because that mode is valid only for an internal-only surface and firstmate keeps the surface classification at dispatch (the mode is never a hard lock). The posture word is read through the one owner of registered posture, `bin/fm-project-mode.sh --raw`.
- **Dispatch (`bin/fm-epic-dispatch-plan.sh`).** Already honored `delivery:` when present (the status model `bin/fm-epic-status-lib.sh` parses it into `ST_DELIVERY`, landed with epflow-05); a story's key wins over the repo's registered posture, and an absent key falls back to the posture exactly as before. This story only formalizes the key the dispatch plan was already reading.
- **Docs.** The "Required story frontmatter" block in the `epic-scaffold` and `epic-review` skills (kept byte-identical) now documents the optional `delivery:` key and its semantics; `epic-review`'s executable-gate description names the new validation.

`docs/epic-convention.md` is a per-home doc seeded by the gflow epic, not tracked in this repo, so the tracked owners of the frontmatter contract - the two skills - carry the documentation here.

## Run

- `evidence/epflow-07/demo.sh` - a hermetic fixture epic that proves the four Definition-of-done cases end to end: a valid `delivery:` passes lint AND its dispatch-plan line shows that mode; a conflicting value (`direct-PR` on a `no-mistakes-prod-only` repo) is flagged as a warning while the lint still passes; an invalid value fails the lint with the exact reason; an absent key produces no finding and leaves dispatch to resolve the mode from posture as before.
- `transcript.txt` - the demo output.

## What the transcript proves matches the DoD

- **Valid + intent wins.** `demo-02` carries `delivery: direct-PR`; lint is `epic lint OK` and the dispatch plan emits `--mode direct-PR`. `demo-03` also marks `direct-PR` and its plan line shows `direct-PR` (the key wins over the repo's prod-only posture).
- **Conflict flagged, not locked.** `demo-03` (prod-only repo, `direct-PR`) raises a `WARNINGS` line naming the `no-mistakes-prod-only` posture, and the epic still exits 0 - the warning is advisory.
- **Invalid rejected.** `delivery: yolo-ship` fails with `must be no-mistakes, direct-PR, or local-only` (exit 1).
- **Absent = unchanged.** With every `delivery:` line stripped, the epic passes and the output never mentions `delivery`; the plan resolves the prod-only repo's mode at dispatch by surfacing both candidate modes (`demo-04`), exactly as before this story.

## Tests

`tests/fm-epic-lint.test.sh` adds five cases (family `pure-contract-unit`): absent key GREEN and unmentioned, a valid mode GREEN, a posture conflict that WARNS without failing, `direct-PR` on a non-prod-only repo silent, and an unknown value RED.
`tests/fm-epic-status.test.sh` (epflow-05) already proves the dispatch plan honors a `delivery:` key over the registered posture.
