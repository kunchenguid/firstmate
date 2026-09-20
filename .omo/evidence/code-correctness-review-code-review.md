# Code correctness review

Base: `1bb72cc5f88014c86e3d03244efa0bb26c22d001`  
Target: `466e0d66175d2c98e1b345e682be8255152a4310`

Scope inspected: `bin/fm-discord-poll.js`, `bin/fm-discord-reply.js`,
`bin/fm-discord-lib.sh`, `bin/fm-bootstrap.sh`,
`bin/fm-inactive-reconcile.sh`, and backend kill dispatch/adapters. I also
traced their immediate caller paths and the added focused tests. No project
tests, linters, or type checks were run. (A read-only `git diff --check` was
run inadvertently; it produced no output.)

## Result

`codeQualityStatus: BLOCK`  
`recommendation: REQUEST_CHANGES`

## CRITICAL

None.

## HIGH

1. **Environment-only Discord configuration is disabled by bootstrap** —
   `bin/fm-bootstrap.sh:1120-1122` reads only `FM_HOME/.env`, while
   `bin/fm-discord-lib.sh:39-43` explicitly accepts an exported
   `FM_DISCORD_BOT_TOKEN` and `bin/fm-discord-poll.sh:4-5` documents that
   environment configuration is supported. Therefore an environment-only
   deployment can invoke the poller manually but bootstrap treats it as opted
   out and removes `state/discord-watch.check.sh` and `config/discord-mode.env`
   at `bin/fm-bootstrap.sh:1142-1150`. The connector will never be scheduled,
   and a prior active connector is shut off. The only activation test writes a
   `.env` token (`tests/fm-discord-selfhosted.test.sh:145-151`), so it misses
   the documented configuration path.

   Action: **auto-fix**. Resolve the token through the same configuration
   helper used by the poll/reply wrappers, then add a behavior test for an
   exported token without `.env`.

2. **Bootstrap reports a successful arm after either required artifact write
   fails** — `bin/fm-bootstrap.sh:1166` and `:1173` discard publication
   failures with `|| true`, then `:1175` unconditionally prints that the poll
   is armed. The sibling X bootstrap instead creates the directories, checks
   each write, validates the shim, and emits a failed-arm result
   (`bin/fm-bootstrap.sh:1087-1099`). For example, an unwritable or absent
   state/config destination leaves Discord polling unavailable while bootstrap
   claims it is enabled. This is misleading success output without a verified
   artifact path.

   Action: **auto-fix**. Treat either write failure as an arm failure, remove
   stale artifacts as appropriate, and verify the generated shim before
   reporting success.

## MEDIUM

None.

## LOW

None.

## Reaper review

The final two reaper commits correctly pass the Zellij tab ID and the expected
`fm-<task>` label from `reap_terminal_child_locked`
(`bin/fm-inactive-reconcile.sh:480-504`) to
`fm_backend_zellij_kill` (`bin/backends/zellij.sh:599-621`). The existing
metadata validation binds the task ID to the backend endpoint
(`bin/fm-backend.sh:407-551`). No additional correctness finding was confirmed
in the reviewed terminal-reaper change.

## Skill-perspective check

Ran: **yes**. `remove-ai-slops` and `programming` were loaded before judging
test relevance and maintainability. The production diff violates neither
perspective through needless parsing/normalization, untyped escape hatches,
or needless abstraction. The focused tests are not deletion-only,
tautological, prompt-text, or implementation-mirroring tests. Their missing
environment-only bootstrap case is evidence for HIGH finding 1, not a separate
slop finding.

## Blockers

- Make bootstrap honor the documented exported-token configuration path.
- Do not claim the Discord poll is armed unless both required artifacts were
  published and the shim is valid.
