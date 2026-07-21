---
name: update-tools
description: >-
  Check and drive updates for the live firstmate home, Nix agentic tools, and
  harness CLIs. Use when the captain invokes /update-tools (e.g. "/update-tools",
  "update tools", "update harnesses", "check for tool updates", "update no-mistakes
  and claude", "are our agent tools current"). Inventory is bin/fm-tool-versions.sh;
  firstmate home updates reuse /updatefirstmate; agentic pins and nixpkgs harness
  bumps ship through a dotfiles project change, then activate after green merge.
user-invocable: true
metadata:
  internal: true
---

# update-tools

Captain-invocable skill for **fleet tooling awareness and updates**.

This is broader than `/updatefirstmate`.

| Concern | Owner |
| --- | --- |
| Live firstmate home + secondmates (tracked `AGENTS.md` / `bin/` / skills) | `/updatefirstmate` and `bin/fm-update.sh` only - do not invent a second firstmate updater |
| Agentic Nix pins (no-mistakes, treehouse, `*-axi`, lavish-axi, firstmate flake pin) | Dotfiles `scripts/agentic-tools-check-updates.sh` / `agentic-tools-bump.sh` |
| Harness CLIs (claude-code, codex, grok-build, opencode, pi-coding-agent) | Dotfiles **nixpkgs** pin (`nixos-unstable`), not `agentic-tools-bump` today |

`bin/fm-tool-versions.sh` is the read-only inventory owner (installed, locked nixpkgs package versions, agentic pin status, fail-soft upstream tips, exit codes).
Its header and `--help` own flags, tool sources, and classification (`current` / `behind` / `ahead` / `unknown` / `error`).

## When to load

Load when the captain says `/update-tools`, "update tools", "update harnesses", "check for tool updates", "update no-mistakes and claude", or similar language about keeping agent CLIs current.

## Procedure (firstmate, not a crewmate)

### 1. Check

Run from the firstmate code root (absolute path; no persistent primary `cd`):

```sh
bin/fm-tool-versions.sh
```

Optional flags: `--installed-only`, `--no-network`, `--skip-agentic`, `--skip-nix`, `--dotfiles PATH` (defaults to `$FM_HOME/projects/dotfiles`).

Present a captain-facing table of installed vs locked pin vs upstream, using `AGENTS.md` section 9 translation.
Do not dump internal exit-code jargon; say what is behind, what is current, and what could not be checked.

### 2. Firstmate home

If the live firstmate (or a secondmate home) is behind origin on its tracked instruction surface, run the existing **`/updatefirstmate`** path only:

- `bin/fm-update.sh`
- re-read `AGENTS.md` when the updater says to
- nudge updated secondmates

Do not restate that skill's procedure body here; load and follow `/updatefirstmate`.

### 3. Dotfiles bumps when agentic pins or harnesses are behind

Firstmate does **not** hand-edit `projects/dotfiles` (project-write boundary).

When agentic pins or harnesses (via nixpkgs) are behind, prefer dispatching a **dotfiles** ship task (that project is no-mistakes + yolo when so registered) whose brief requires the worker to:

1. Bump selected agentic tools with `scripts/agentic-tools-bump.sh <tools...>` (pin semantics stay in that script; do not reimplement).
2. Advance the **nixpkgs** input toward current `nixos-unstable` and re-evaluate harness package versions (`claude-code`, `codex`, `grok-build`, `opencode`, `pi-coding-agent`) until they match or exceed known upstream tips where nixpkgs has caught up.
3. If nixpkgs still lags upstream after a fresh pin, document the lag in the PR and list options: wait for nixpkgs, maintain an overlay, or temporary non-nix install.
   Escalate to the captain when policy is unclear; do not silently leave the fleet on a permanent non-nix path.
4. Run repo tests, no-mistakes, and open a PR.

### 4. Activate after green merge

After the captain (or yolo authority) lands the dotfiles PR and the local clone is refreshed via the guarded fleet-sync path:

1. From the primary `projects/dotfiles` checkout, with absolute paths and no persistent primary `cd`:
   - `scripts/rebuild.sh --locked --agentic-tools`
   - `setup-agentic-tools`
2. Re-run `bin/fm-tool-versions.sh`.
3. If `setup-agentic-tools` resets the firstmate pin (known hazard), run `/updatefirstmate` again so the live home is not left on a stale checkout.

### 5. Safety

- Never force-discard unlanded work.
- Never kill or restart the shared no-mistakes daemon with `--force` while foreign runs are active without explicit captain OK.
- Never mutate pins or packages from this skill's check step; inventory is read-only.
- Report what stayed behind and why (nixpkgs lag, probe offline, dirty home skipped by fast-forward update, and so on).

## Cross-links

- **Firstmate-only tracked-code refresh:** `/updatefirstmate` (`bin/fm-update.sh`).
- **Full fleet tooling check and drive:** this skill (`/update-tools`, `bin/fm-tool-versions.sh`).
- **Agentic pin mechanics:** captain's dotfiles `scripts/agentic-tools-*.sh` and `scripts/lib/agentic-tools-lib.sh`.
- **Harness package ownership:** nixpkgs attrs listed in the dotfiles home profile; inventory header in `bin/fm-tool-versions.sh`.
