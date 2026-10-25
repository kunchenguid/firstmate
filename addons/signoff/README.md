# signoff

The sign-off event handler: the adapter that turns sign-off board answers into
hold answers and merge-gate events. It runs through the process-event runner and
the keyed-answer intake, both owned by the Firstmate checkout.

## Status

- 0 copied upstream lines: no whole line of `bin/fm-procevent-signoff.sh` or
  `tests/fm-procevent-signoff.test.sh` matches kunchenguid/firstmate main.
- Dormant until the fork dispatch hook lands. Nothing here runs the adapter yet:
  the fork still ships and dispatches its own copy.
- The adapter resolves the runner, the intake and the libraries from the Firstmate
  checkout (`FM_CODE_ROOT`, defaulting to `FM_HOME`), not from its own directory.

## Seam (for the hook slice)

Upstream main has no sign-off source, its runner resolves adapters only under its
own `bin/`, and it does not call the adapter's `ack` after the intake. The fork
does all three. The hook slice has to exec this adapter with the fork's argv
(`poll`, `answers`, `ack`, `raise`) and keep the `ack` step. The full table and
the decision are in the seam record kept with the evidence.

## Feedback trail: Read

Each `poll` round marks Read, with `sign-off-axi feedback <card> <board.json> --read` on the board `sign-off-axi status` names, every card in a captured result that this home's handler (Main, or the lead in a secondmate home) has concluded with `bin/fm-procevent.sh handled signoff <sequence>`: that is the pickup of the note carrying the owner's answer. It reads the captured results because the runner runs `answers` and `ack` from the Firstmate checkout's own adapter. A card is marked once per result (`state/signoff-read-marked`); NOT_FOUND counts as done and a sign-off-axi older than 0.6.1 skips with one log line. Like the rest of this adapter it runs only where this adapter's `poll` is the registered one. The merge side (Acted or Replied with the PR link) is in `merge-card post`.

## Firstmate owner engagement route

`engage-route/bin/fm-engage-route.sh dispatch <board.json>` forwards each open Go deeper request only to the Firstmate task named by its filer, or to an explicit `config/engage-owners` binding.
Firstmate-home producers must post with `--filer <task-id>` (or set `SIGN_OFF_FILER=<task-id>`); use `bind <filer> <task-id>` only when they differ.
Missing or finished owners remain queued with a reason.
The adapter reads deeper requests only and never consumes captain-hold answers.

## Tests

`tests/fm-procevent-signoff.test.sh` sources `tests/lib.sh` from the Firstmate
checkout and needs `FM_CODE_ROOT` set to it. It runs the adapter journey through
the real runner. The real-hold section is skipped when no beads-capable tasks-axi
and bd are installed.
