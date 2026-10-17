---
name: firstmate-doctor
description: >-
  Check whether this firstmate home is set up and working with the read-only bin/fm-doctor.sh.
  Use when the captain invokes /firstmate-doctor or asks whether the home, its tools, or its setup are healthy; after installing, upgrading, or reinstalling a tool firstmate depends on; after relaunching the primary agent or its terminal; and when a spawn refuses on a missing tool, a toolchain floor, or a launcher pane.
user-invocable: true
metadata:
  internal: true
---

# firstmate-doctor

Run `bin/fm-doctor.sh` from this home (`--network` adds a fresh GitHub auth probe and the last network report; `--area <name>` narrows the run).
The command owns every check and its fix hint through `docs/doctor-checks.json`; this skill holds no rules.

Act on its `findings`, worst first:

- Apply each `fix` through the owner command it names, under the usual consent rules: never install a tool the captain has not approved, and never edit a captain-owned file (`config/*-account`, `.claude/settings.local.json`, `~/.no-mistakes/config.yaml`) to clear a finding - give the captain the exact change instead.
- A finding that is a bootstrap line follows the `bootstrap-diagnostics` playbook for that line.
- A `doctor/` finding is a problem with the doctor or its inventory, not with the home; a `skip` is unknown, not healthy.

Report the outcome to the captain as plain consequences and the decisions they need to make, per `AGENTS.md` section 9, not as raw check ids.
