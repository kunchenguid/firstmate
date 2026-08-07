# herdr — Versioning

## Active skill

`SKILL.md` is the live version. Snapshots are read-only history.

## Version history

| File        | Date       | What changed    |
| ----------- | ---------- | --------------- |
| SKILL.v1.md | 2026-07-28 | Initial merge (named `cyber-mux` at this point): replaces `herdr`, `reasonix-herdr-axi`, and `reasonix-orchestrator` with one router skill. Modeled on cyberuni/cyber-mux's engine-detection contract (env var → `$TMUX`/`$HERDR_ENV` fallback). Router decides task (pane-control vs reasonix-dispatch) and engine (herdr/tmux/none), then hands off to `references/herdr-panes.md`, `references/reasonix-herdr.md`, or `references/reasonix-headless.md`. tmux pane-control is a documented STOP, not implemented — no verified tmux command surface existed in any source skill. |
| SKILL.v2.md | 2026-07-28 | Renamed `cyber-mux` → `herdr` (matches the established trigger word and what the skill actually implements — no tmux driver exists, so the cyber-mux name overclaimed a multi-engine contract). Folded in `browser-harness-herdr-axi` as a third task branch (`browser-harness-dispatch`), Herdr-only with no headless fallback → `references/browser-harness-herdr.md`. |
| SKILL.v3.md | 2026-07-31 | Overview now mentions remote machines: `herdr --remote <ssh-target>` reaches a Herdr server on another host (e.g. `orca-ubuntu-vm`, set up the same day for Moshi phone access) — pane-control still routes through this same skill, only the target changes. Points to `references/herdr-panes.md`'s new remote-attach section and cross-references `agentbox-remote` (provisioning a new box) as the distinct concern. Battle-tested same day: `--remote` confirmed interactive (hangs with no server-side connection when run as a blocking Bash tool call, same as `agentbox claude`/`attach`) — Overview and reference both flag it as hand-to-the-user only. |
| SKILL.v4.md | 2026-08-07 | SKILL.md text unchanged; bump covers a `references/herdr-panes.md` addition (per the "reference-file changes covered by parent bump" convention): a new `binox-axi` step in "Start agents interactively" instructing the caller to inventory the target path (skills, orphaned tmp/ scripts, tool scripts, available AXI CLIs) before writing the task brief, so briefs name a skill path that actually exists on that target instead of guessing. Not yet globally installed at write time (PR #4 on subagent-factory awaiting merge) — see the dated note in the reference file. |

## Automatic activation (hooks, not skill-file changes)

Two hooks in `~/.claude/settings.json` make this skill's coverage automatic inside a Herdr session, added 2026-07-28 — deliberately as hooks, not by loosening the skill's own trigger wording (pane-control still requires an explicit "Herdr" mention by design):

- `SessionStart` → `~/.claude/hooks/herdr-skill-awareness.sh`: when `HERDR_ENV=1`, injects a context note naming this skill and its three branches, so the agent doesn't need the user to say "Herdr" before considering it.
- `PreToolUse` (matcher `Agent`) → `~/.claude/hooks/herdr-default-reasonix.sh`: when `HERDR_ENV=1`, denies Agent-tool dispatches with a reason pointing at `references/reasonix-herdr.md` instead. Global policy — every Agent tool call inside Herdr redirects to reasonix by default, including built-in specialized subagents (debugger, security-auditor, etc.), confirmed live 2026-07-28. Not a hard OS-level block: Claude reads the deny reason and can still explain/ask the user to override for a specifically-named subagent.

Both scripts live in `~/.claude/hooks/`, not inside this skill folder, since hooks are wired through `settings.json` regardless of where the script file sits. If either policy needs to change, edit the script directly — no version bump needed here unless the *skill's* own branching logic changes as a result.

## How to update

**Snapshot convention (A):** `SKILL.v<N>.md` always holds the content of version N. Edit `SKILL.md` first, then snapshot — so the version label matches what's inside it. Rollback to a prior version = `cp SKILL.v<N>.md SKILL.md`.

```bash
# 1. Find current version
ls SKILL.v*.md | sort -V | tail -1        # e.g. SKILL.v4.md

# 2. Edit SKILL.md (it becomes v5)

# 3. Snapshot the NEW content with the NEW number
cp SKILL.md SKILL.v5.md

# 4. Add a row to the table above
```

Reference-file changes (`references/*.md`) don't get their own version numbers — they're covered by the parent `SKILL.md` bump per the "Notes for future updates" section at the bottom of each reference file.

## What deserves a version bump

- New patterns/symptoms found during real use
- Corrected commands or API changes
- New workflow branches
- Step reordering from operational experience
- A real tmux driver landing in `references/tmux-panes.md`

## What does NOT need a bump

- Typos, formatting, link fixes
- Placeholder updates (`<date>`, `<server-name>`)

## Predecessor skills

Archived at `~/.claude/skills-archive/2026-07-28-cyber-mux-merge/` (not scanned as active skills — safe reference-only history):

- `herdr` (full generic pane-control vocabulary → now `references/herdr-panes.md`)
- `reasonix-herdr-axi` (Herdr-visible reasonix dispatch → now `references/reasonix-herdr.md`)
- `reasonix-orchestrator` (headless reasonix dispatch → now `references/reasonix-headless.md`, `tools-and-mcp.md` → `references/reasonix-tools-and-mcp.md`)
- `browser-harness-herdr-axi` (Herdr-visible browser automation → now `references/browser-harness-herdr.md`)
