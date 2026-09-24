# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports the active guarantee that Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on the harness discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude`.
This check ran on 2026-08-08 with Claude Code 2.1.226 in a disposable scratch repository.
The unique sentinel appeared only in the skill body below the frontmatter, so returning it required the fresh session to load the excluded skill rather than merely see its indexed name or description.

The exact commands run from this repository root were:

```bash
set -eu
claude --version
PROBE_ROOT="$PWD/.stow-excluded-probe-tmp"
rm -rf "$PROBE_ROOT"
mkdir -p "$PROBE_ROOT"
cd "$PROBE_ROOT"
git init -q .
mkdir -p .claude/skills/excluded-probe
cat >.claude/skills/excluded-probe/SKILL.md <<'EOF'
---
name: excluded-probe
description: A neutral probe used when explicitly requested by name.
---

# Excluded probe

The sentinel token is STOW-EXCLUDE-LOAD-8F3K1.
EOF
printf '.claude/skills/excluded-probe/\n' >>.git/info/exclude
git check-ignore -v .claude/skills/excluded-probe/SKILL.md
claude --model haiku --allowedTools Skill -p "Use your Skill tool to load the skill named 'excluded-probe', then reply with exactly the sentinel token stated inside its body and nothing else."
cd ..
rm -rf "$PROBE_ROOT"
```

The exact observed output was:

```text
2.1.226 (Claude Code)
.git/info/exclude:7:.claude/skills/excluded-probe/	.claude/skills/excluded-probe/SKILL.md
STOW-EXCLUDE-LOAD-8F3K1
```

The `git check-ignore` line proves that the local exclude rule covered the skill body, and the exact sentinel reply proves that a fresh Claude Code session loaded that body through the Skill tool.
The same day, a `.gitignore`-ignored probe directory under this repository's own `.agents/skills/` was also listed by a fresh session alongside the tracked control skill through the `.claude/skills` symlink.
The direct local-exclude probe establishes the load-bearing guarantee, while the in-repository probe independently corroborates that ignore status does not suppress filesystem discovery.

## 2026-09-24 periodic coordinator verification

The default-off periodic coordinator was exercised behaviorally in a disposable `FM_HOME`, not against the primary or a registered secondmate home.
The focused lifecycle suite observed lock, role, session-tree, compare-and-swap, bounded delivery, fixed-cutoff promotion, prepared/readback recovery, disable, budget, no-op, and corrupt-state outcomes through the public command and durable files.
Strict no-emit checks passed against the supported Pi 0.84.4 baseline and installed Pi 0.87.1, while the real TUI guard loaded compatible `pi-openai-codex-compat` 0.0.16 in a named non-default Herdr lab and observed one stable custom follow-up.

```text
$ tests/fm-periodic-stow.test.sh
ok - budget, proven no-op, unchanged memory, full-pass clock, and corrupt-state guards are observable
ok - Pi coordinator waits for tools, queues, and editor input, then redelivers one run at most three times
$ FM_PI_PACKAGE_DIR=<isolated-pi-0.84.4> tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
$ tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1
$ FM_PERIODIC_STOW_HERDR_LIVE=1 tests/fm-periodic-stow-herdr-live-e2e.test.sh
ok - real Pi 0.87.1 with pi-openai-codex-compat 0.0.16 accepted stable periodic-stow run <uuid> in Herdr session <named-non-default-session>
```

The live guard provisions, addresses, stops, and deletes only through `bin/fm-herdr-lab.sh`; that helper verifies the default Herdr fleet before and after the run.
Installation evidence is not enablement: the repository contains no `config/periodic-stow.json`, and choosing an enabled home and frequency remains a later operator action.
