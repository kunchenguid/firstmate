# Review standards for this repository

Rules the reviewer asked to have written down, recorded here so that a decision
already argued out on one pull request is not re-litigated on the next one. Each
rule states the conditions it depends on, because a rule with its conditions
dropped stops being a decision and becomes a blind spot.

## A captain-facing surface is not automatically a `VISION.md` violation

This is the first mate's working interpretation rather than settled repository policy; whether `VISION.md` itself should be reconciled remains an open question belonging to the captain; and the conditions listed below are what this interpretation depends on.

`VISION.md` says "The captain talks to the first mate and to nobody else; every
worker reports through the first mate and never addresses the captain directly."
That line protects who is answerable for work. Read alongside the sentence it
shares a paragraph with, it governs workers reporting outward, not the surfaces
the captain reaches inward through, so a front end the captain chooses to speak
or type into is not by itself a breach of it.

Do not flag a captain-facing front end as violating that line while **all** of
these hold:

- it never claims to be the first mate, and says so in its own instructions;
- it has no tool that can change a project, merge, discard work, or grant
  authority;
- work that is not answering from existing records is handed to the first mate
  and announced as a handover, rather than performed or claimed.

Any one of those failing is worth flagging, and flagging loudly: a front end that
gains a write tool, drops the disclaimer, or reports work as its own is the case
this line exists to catch.

The known tension is not a defect either, and is already on the record: such a
front end may hold read access to the captain's records, so the captain does
sometimes get a substantive answer from something that is not the first mate.
Whether `VISION.md` should be reconciled to describe that is the captain's call
and is not settled by any single pull request. Raising it as new is what this rule
is here to stop; `bin/fm-voice-relay.py` is the surface it was decided on.

## A harness's own tool-approval bypass flag is not a missing autonomy grant

`VISION.md` says "autonomy exists only as an explicit grant, never as a
default." That grant is the captain's decision to spawn the task at all:
`bin/fm-spawn.sh` refuses every ship spawn without an explicit `--mode` and
`--yolo` contract, refuses a scout anything beyond a report, and hardcodes a
secondmate's posture rather than letting it vary — three different shapes of
the same rule, that no task reaches a worker pane without its contract
already settled. That settled contract is what authorizes the worker to act
unsupervised inside its own isolated worktree. The launch flag that disables a
harness's in-session approval prompts (`--dangerously-skip-permissions`,
`--dangerously-bypass-approvals-and-sandbox`, `--always-approve`, `--yolo`, or
equivalent) is the mechanical means of exercising a grant already made, not a
second decision point that needs its own later check.

Do not flag a harness's unconditional approval-bypass flag as an unauthorized
autonomy bypass while **all** of these hold:

- the flag only takes effect inside the task's own isolated worktree, never
  against the captain's original checkout or another task's worktree;
- the harness is reachable only through `bin/fm-spawn.sh`'s task contract for
  its kind (ship's `--mode`/`--yolo`, scout's report-only bound, or
  secondmate's hardcoded posture), never launched around it;
- every other verified harness in `launch_template()` composes the same kind
  of flag unconditionally, so the pattern is established, not novel to the
  harness under review.

Any one of those failing is worth flagging: a flag that reaches outside the
task's worktree, a launch path that bypasses the spawn contract, or a harness
that invents its own looser rule than its siblings is the case this line
exists to catch. `bin/fm-spawn.sh`'s `launch_template()` is where this was
decided, across the claude, codex, cursor, muse, and grok adapters before agy.
