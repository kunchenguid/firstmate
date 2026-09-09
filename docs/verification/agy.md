# Verification: the agy (Antigravity CLI) crewmate adapter

Active empirical evidence for firstmate's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.1.28` |
| Verified | 2026-09-09 |
| Platform | Linux x86_64 (CachyOS, kernel 7.2.3-1-cachyos) |

Every run below used the installed `~/.local/bin/agy` (a natively compiled ELF, 210 MB) against the operator's Google AI Pro OAuth credential, driven through real tmux panes the way firstmate drives a crewmate pane.
Model spend was kept minimal: `--model gemini-3.8-flash-low` with one-line prompts, one `sleep`-bounded tool call, and one `--continue` resume.

## Verified facts

### Print mode and model discovery

Print mode answers on the account's low-tier model, and `agy models` lists the Flash family the brief named:

```
$ agy --model gemini-3.8-flash-low --print="reply with exactly: agy-ok"
agy-ok

$ agy models
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
...
```

`--output-format json` prints one object with `conversation_id`, `status`, `response`, `duration_seconds`, `num_turns`, and `usage`.

### Launch shape

A positional prompt is rejected outright, so the brief cannot ride argv positionally:

```
$ agy --model gemini-3.8-flash-low --dangerously-skip-permissions "reply with exactly: AGY-INTERACTIVE-OK"
Error: unexpected argument "reply with exactly: AGY-INTERACTIVE-OK and nothing else".
Prompts are read only from -p/--print, -i/--prompt-interactive, or stdin, so this argument would have been ignored.
```

`--prompt-interactive="..."` starts the supervised TUI session with the prompt as its first turn and auto-submits it: the turn ran to completion with no extra Enter and the pane returned to the idle `>` composer.
`--dangerously-skip-permissions` auto-approved a real `Bash(sleep 25)` tool call with no approval gate.
Neither flag covers the workspace-trust dialog (it still appeared), which is why the spawn pre-registers trust instead.

### Workspace trust

A fresh directory meets `Do you trust the contents of this project?` with `> Yes, I trust this folder` preselected, so one Enter accepts.
Accepting appended the directory to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, and a second directory pre-registered there by hand (via `bin/fm-agy-trust.sh`'s exact merge) launched with no dialog at all.
Both directions are covered by that helper's structural scope test, and the portable suite pins its refusals.

### Hooks fire from the worktree

A `.agents/hooks.json` carrying one named hook with `PreInvocation`, `PostInvocation`, and `Stop` command handlers fired all three for one no-tool turn, in order `PREINV`, `POSTINV`, `STOP`.
An Escape interrupt mid-`sleep 30` fired only `PREINV`: neither closer fires on interrupt, so the control plane's own interrupt-idle record closes those turns exactly as it does for Claude.

### Busy token, interrupt, and exit

A running turn renders `esc to cancel` bottom-left beside the braille `Running command...` spinner; the token is gone the instant the turn ends and the idle composer shows `? for shortcuts` there instead.
A single `Escape` printed `Interrupted` and returned the composer to an empty `>` with no repolluted prompt text, so no clear key is needed.
`/help` and `/exit` each submitted with one immediate Enter (no popup swallow), and `/exit` left the pane in its shell with `Resume with -c (or command below): agy --conversation=<id>`.

### Resume

After `/exit`, `agy --continue --prompt-interactive="say exactly: RESUMED-OK"` restored the prior turn in history and answered the new prompt.
The relaunched session rendered the stored default model (`medium`) because no `--model` was passed, so a relaunch must re-pass the profile axes.

### Process identity

`ps -o comm=` reports `agy` for the live TUI and no `AGY_*` variable was observed in its environment, so detection is the anchored `agy` ancestry arm alone, with the foreign markers cleared at the launch boundary.

### Supervised end-to-end launch

A trivial supervised ship (`--harness agy --model gemini-3.8-flash-low --effort low --mode local-only --yolo off --backend tmux` from `bin/fm-spawn.sh` into a throwaway home and project) proved a worker turn through firstmate's own launch path on 2026-09-09:

```
spawned agt-e2e1 harness=agy kind=ship mode=local-only yolo=off window=firstmate:fm-agt-e2e1 worktree=<treehouse-slot>
```

The worker read its brief, wrote the required file, and reported `done:`; the busy record closed as `state=idle source=agy-hook event=stop` with the turn-end marker touched; `bin/fm-teardown.sh` retired the created `.agents/hooks.json` (the `.agents/` directory was gone from the pooled worktree afterwards) and returned the slot.
Teardown first refused while the proof branch was unmerged, which is the designed local-only landing gate rather than an adapter gap.

## What is still unproven

agy as a primary or secondmate has no supervision protocol and remains refused; the `Stop`-hook and `--conversation` resume shapes that could support one are plausible but unbuilt.
`--effort high` and `--effort medium` were not exercised live (only the `--help` enumeration and the `low` default path); the spawn passes them through natively and records `xhigh`/`max` without a flag.
Skill submission beyond the `/help` and `/exit` slash-antipattern check (no popup swallow) was not exercised against a real `/no-mistakes`-style skill.
The live guard `tests/fm-agy-signals-live-e2e.test.sh` is the command that refreshes this evidence; run it after every agy upgrade and before trusting refreshed per-harness facts.
