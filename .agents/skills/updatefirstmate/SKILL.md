---
name: updatefirstmate
description: >-
  Self-update a running Firstmate and its registered secondmates through the configured origin.
  Use when the captain invokes /updatefirstmate or asks to update Firstmate.
  The updater safely synchronizes an applicable GitHub fork, fast-forwards tracked runtime material, converges inherited configuration, and reports any refusal without forcing or discarding work.
user-invocable: true
metadata:
  internal: true
---

# Update Firstmate

Run the deterministic updater from the active Firstmate code root:

```sh
bin/fm-update.sh
```

The script owns origin and upstream discovery, guarded GitHub fork synchronization, local and secondmate fast-forwards, and inherited-config convergence.
Treat a nonzero result as a refusal and report its concrete reason without continuing around it.

For a downstream fork, an independent canonical advance can make fork main and its parent diverge.
Stop on that refusal.
Import canonical through a separate reviewed `upstream-integration/*` branch and pull request outside `/updatefirstmate`, then rerun the updater after that integration lands.

When the script prints `reread-firstmate: yes`, re-read `AGENTS.md` before any further work.
When it prints `reread-firstmate: no`, retain the current instructions.

For every selector on `nudge-secondmates:`, send a gentle instruction refresh through the active home:

```sh
FM_HOME=<active-home> bin/fm-send.sh <selector> 'Firstmate was updated. Re-read AGENTS.md before further work.'
```

Do nothing when the value is `none`.
Do not nudge a target the updater skipped or left current.

Report which fork, Firstmate checkout, and secondmates advanced or remained current.
Surface every refusal plainly, including dirty or divergent work, authentication failure, unsupported topology, failed fetch, and failed config convergence.
Never turn unresolved downstream divergence into an updater-owned merge, push, reset, or force operation.
