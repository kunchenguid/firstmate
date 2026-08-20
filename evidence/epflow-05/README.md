# evidence/epflow-05 - `fm-epic-status` + `fm-epic-dispatch-plan`

Closes the signed->crew cliff (report G-dispatch/G-route): after handoff the operator no longer hand-derives whether an epic is signed, which epic branches are cut, which stories are dispatchable, and which home dispatches.
Two read-only commands do it: `bin/fm-epic-status.sh <slug>` SHOWs readiness, `bin/fm-epic-dispatch-plan.sh <slug>` PRINTS the ordered cut-branch + dispatch commands. Neither cuts a branch or spawns anything - dispatch stays firstmate judgment.

## Run

- `evidence/epflow-05/demo.sh` - a hermetic fixture epic exercising every case (done / dispatchable / blocked / unseeded story, a delivery-key override, a scout story, and a story whose base branch has drifted from the epic slug), including the print-only proof that the epic-branch tool is only ever asked to `verify`, never `create`.
- `transcript.txt` - the demo output plus BOTH commands run against two live epics: this repo's own `epflow` engine epic and the live aimica `lh` epic (the incident that motivated epflow).

## What the transcript proves matches reality

- **Signed status.** `epflow` and `lh` both read `signed: yes` from their `signed_off` + `status: active` frontmatter.
- **Epic branches per repo.** The check keys off each story's real `pr_base`, not a nominal `epic/<slug>`. `lh`'s three repos show `epic/aimica-learning-hub` cut 3/3 (the epic is already in flight); `epflow`'s stories base on `main`, so it correctly reports no epic branch gates dispatch. Because `lh`'s epic slug (`lh`) differs from the branch its stories base on (`aimica-learning-hub`), both commands surface a **DRIFT** line - exactly the authoring drift `fm-epic-lint` (epflow-04) targets.
- **Per-story dispatchability.** Computed from story `depends:` against backlog `- [x]` (merged) state: `epflow-02/04/05` dispatchable, `epflow-07/08` blocked-by `epflow-04`, `epflow-01/03/06` done - matching the live backlog. `lh` shows `lh-02` + `lh-scout-app-layering` dispatchable, the rest blocked behind their chains.
- **Resolved delivery mode.** A story `delivery:` key wins (epflow-07); otherwise the repo's registered posture is used. `epflow`/firstmate resolves to `local-only`; `lh`'s `no-mistakes-prod-only` repo surfaces BOTH candidate modes for firstmate to classify by surface (kept as a decision, not guessed). Scout stories dispatch with `--scout` (no mode/base).
- **Dispatch owner.** `this home` when no registered secondmate matches; a secondmate whose clone list names an involved repo is surfaced as a candidate to confirm by scope (never a hard route).
- **Print-only.** The demo's call log shows the epic-branch tool invoked only with `verify`; nothing is cut or spawned.

## Test

`tests/fm-epic-status.test.sh` (family `pure-contract-unit`) proves the same model end to end against a fixture home, with the network `verify` served through the `FM_EPIC_BRANCH_BIN` seam.
