# loop-constraints.md — binding rules for every loop turn

Distilled from AGENTS.md prime directives + the council specs. These are
BINDING on any autonomous firstmate turn (watcher-woken or supervise-daemon).

## Push and merge

- Never run state-changing git in `projects/` — the one exception is
  `bin/fm-merge-local.sh` (captain-approved, clean fast-forward only).
- Never merge or arm a PR poll without a trailing `approve:` in
  `state/<id>.verdict` (Quarterdeck). `FM_VERIFY_OVERRIDE=1` is captain
  authority, always loud, never silent.
- Never auto-merge a red PR, under any mode, including yolo.

## Spawning

- Never spawn a ship task without a trailing `proceed:` in `state/<id>.intake`
  (Wardroom). `FM_INTAKE_OVERRIDE=1` is captain authority, loud.
- Never launch a crewmate in the primary checkout — treehouse worktrees only.

## Loops

- The watcher stays zero-token: no LLM calls, no network, pure bash.
- Bounded retries everywhere: 3 verify rejects / 2 intake revises → escalate
  to the captain. Never spin.
- Never weaken, skip, or delete a test to make a gate green; never hand-edit
  a ledger status (the false-green guard is the point).
- Secondmates act only on routed work; no self-initiated sweeps.

## Communication

- Status channels are append-only one-liners; escalations go to the captain,
  routine churn does not.
