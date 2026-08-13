# agy adapter consolidation - which source won, and why

Two independent agy implementations were merged into one result on
`fm/fm-agy-adapter`, rebased onto `main` at `88d0f2e`.

- **Source A** - `fm/agy-harness-adapter`, nine commits, the captain's own
  branch, in real use before this task. Treated as the authoritative base.
- **Source B** - a fresh implementation plus a live verification pass on
  agy 1.1.12 (hooks, model resolution, composer capture, lifecycle keys).

Where the two disagreed on a point of FACT about agy, the live observation on
1.1.12 decided it, and each such case is called out below rather than silently
applied.

## Summary

| Area | Winner | One-line reason |
| --- | --- | --- |
| Detection ordering | **A** | B's ordering was wrong; proven against a real leaked environment |
| Env scrub at launch | **A** | A saw a hazard B missed entirely, in both directions |
| Primary session support | **A** | B never reached it; kept, and repaired so it actually runs |
| Secondmate capability | **A** | A supplies the supervision protocol that made B's refusal unnecessary |
| Remote / session-lock / supervision routing | **A** | A-only coverage, no B counterpart |
| Launch template | **B** | `--add-dir` is mandatory for worktree isolation; A omitted it |
| Effort axis | **B** | A emits a flag that exits 1; corrected against the recorded ground truth |
| Busy/turn-end wiring | **B** | A's file path collides with this repo's own tracked hooks; A's event names do not exist |
| Composer classification | **B** | A's identity gate leaves agy unreadable on tmux and three other backends |
| Control plane (`fm-control.sh`) | **B** | A-only gap: A never taught it agy, so interrupt/exit refused |
| Model catalogue validation | **B** | A-only gap; turns a dead pane into a clean refusal |
| Composer verification record | **A** | A's byte-level capture reproduced exactly; extended, one claim corrected |
| Eight existing test updates | **A** | Kept as-is |

## Where A won

**Detection ordering (`bin/fm-harness.sh`) - and B was wrong.**
B moved `ANTIGRAVITY_AGENT` ahead of the `CLAUDECODE` check, reasoning by
analogy with cursor. That is wrong here, and the counter-example was sitting in
this very session: the Antigravity IDE's terminal exports `ANTIGRAVITY_AGENT=1`
into **every** process it starts, not just agy's own children, so a claude
worker launched from it carries the marker. Run against that real environment,
B's ordering reported `agy` for a claude session and A's reported `claude`.
A's placement (last in the marker layer) is kept, and B's change is reverted.
Cursor's marker is set only on cursor's own processes, which is why the
opposite rule is correct there; that contrast is now written down in the skill.

**The env scrub is bidirectional (`bin/fm-spawn.sh`).**
Following from the same fact, A scrubs `ANTIGRAVITY_AGENT` from every *non-agy*
launch as well as scrubbing foreign markers from agy's own. B only did the
latter. A's version is kept in full.

**Primary-session support.** `bin/fm-turnend-guard-agy.sh`,
`.agents/hooks.json`, `docs/supervision-protocols/agy.md`, the session-start
nudge, and the PreToolUse seatbelts are all A-only ground. Kept - and repaired,
see the open questions below.

**Secondmate capability.** B refused `--secondmate` on agy, on the stated
grounds that agy had no primary supervision protocol. A supplies exactly that
protocol, so the premise of B's refusal does not hold in the merged result and
the refusal is dropped. muse's refusal is untouched and still tested.

**`bin/fm-remote-doctor.sh`, `bin/fm-remote-secondmate-control.sh`,
`bin/fm-session-lock-lib.sh`, `bin/fm-supervision-instructions.sh`,
`bin/fm-bootstrap.sh`'s secondmate-liveness allowlist, and the eight updated
test files** are all A-only and kept unchanged.

## Where B won

**`--add-dir` is mandatory (`bin/fm-spawn.sh`).**
A's launch template had no `--add-dir`. Launched with only a cwd, agy reports
*no active workspace* and runs its tools in
`~/.gemini/antigravity-cli/scratch` - verified by asking a launched agent for
`pwd`, which answered with that scratch path. That is a silent worktree-isolation
break, so B's `--add-dir <absolute-worktree>` is now part of the template. It is
also what makes agy load workspace customizations at all, which is why A needed
its trust workaround (below) and B did not.

**The effort axis is never emitted - and the recorded ground truth was wrong.**
This is the fact-level disagreement the brief asked to be explicit about.
The prior record (A's commit message, A's code comment, and `data/learnings.md`)
says that passing `--effort` alongside a display-name model makes agy *silently
fall back to its default model*. On agy 1.1.12 that does not reproduce. Driving
the matrix directly:

| Launch | Result |
| --- | --- |
| `--model 'Gemini 3.1 Pro (High)'` | rc=0, runs `gemini-pro-agent` |
| `--model 'gemini-3.1-pro-high'` | rc=0, same backing model |
| `--model 'gemini-3.1-pro-high' --effort high` | rc=0 (flag merely restates the baked level) |
| `--model 'gemini-3.1-pro-high' --effort low` | **rc=1** `invalid model selection` |
| `--model 'Gemini 3.1 Pro (High)' --effort high` | **rc=1** |
| `--effort high` with no `--model` | **rc=1** `(--model "" --effort "high")` |

agy fails loudly and launches nothing; the observable symptom is a pane that
never starts, not a quietly wrong model. That matters for A's rule, which skips
the flag only for parenthesised display names: under it, a kebab-id model with a
mismatched effort, or any agy dispatch carrying an effort with no model, still
emits the flag and the launch dies. B's rule - never emit it for agy - is kept,
because the flag is redundant when it agrees and fatal when it does not.
Consequently `bin/fm-bootstrap.sh` now rejects a configured agy `effort` exactly
as it does for opencode, kimi, and cursor (A had allowed `low|medium|high`), and
A's `model` parameter threading through `effort_flag_for_harness` is removed as
dead code. The captain's `config/crew-dispatch.json` sets no effort on any agy
profile, so this changes nothing about current policy.

**Busy and turn-end wiring is a global plugin, not a worktree file.**
A wrote per-task wiring to `<worktree>/.agents/hooks.json`. Two concrete
problems:

1. *It collides with this repo's own tracked file.* A also adds
   `.agents/hooks.json` at the repo root as the primary hooks. They are the same
   path, so an agy crewmate working on firstmate itself would have the tracked
   primary hooks overwritten in its worktree, and teardown would then block on
   the modified tracked file. It would equally clobber any project that ships
   agy customizations of its own.
2. *Its event names do not exist.* A registered `UserPromptSubmit`,
   `StopFailure`, and `SessionEnd` - those are Claude's events. agy's are
   `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`,
   `SessionStart`, and `Notification`. Only `Stop` would ever have fired, so the
   seeded turn would close and no later turn could ever re-open: every agy
   crewmate would have read **idle while working** from its second turn onward.

The merged result installs one firstmate-owned global plugin at
`~/.gemini/config/plugins/fm-turn-end/`, guarded per task by a
`.fm-agy-turnend` worktree pointer and a private registry entry - the same
shape grok and Kimi already use. `PreInvocation` opens the turn and `Stop`
closes it. The operator's own `~/.gemini/config/hooks.json` is never touched:
on this machine it is a home-manager symlink into the read-only nix store that
already carries their `herdr-session` hook, which is precisely why a plugin is
the right surface - a plugin directory under a customization root is discovered
automatically and enabled by default with no entry in the operator's
`config.json` (verified live).

Two things were **dropped** with this change, both from A:

- The mutation of `~/.gemini/antigravity-cli/settings.json` to add each worktree
  to `trustedWorkspaces`. It is unnecessary - `--dangerously-skip-permissions`
  suppresses the trust gate, verified on a path agy had never seen, with that
  list byte-identical afterwards - and it wrote to the operator's own agy
  configuration, which firstmate should not do.
- The `^\?\? \.agents/` exemption in teardown's uncommitted-work check. With no
  firstmate file written into the worktree's `.agents/`, it would only have
  masked a project's own work product.

**agy's transcript was evaluated as a busy source and rejected**, so the hooks
are not merely the convenient choice: a tool-using turn writes several
`PLANNER_RESPONSE` rows interleaved with its tool steps, so the trailing row is
a completed model response while the turn is still in flight, and folding it
would produce a false idle. The transcript also marks an *interrupted* turn's
response `DONE`, so it cannot report interruption either.

**Composer classification needs no identity probe.**
A routed agy through `_fm_composer_pi_verdict`, which requires `identity=1` plus
a live agent identity naming agy. `identity=1` is supplied only by herdr's
`agent get` and tmux's pi-specific foreground probe, so under A an agy pane
reads `unknown` on tmux - the reference backend and the only one CI exercises -
and on cmux, orca, and zellij. A's own verification note already states the real
proof ("agy is provable only because the rule pair contains the glyph"); the
identity gate on top of that adds no safety. The merged result classifies the
glyph-inside-a-validated-rule-pair structurally, which is the same rule that
already licenses a `>` inside a bordered box. pi is untouched: its region is
genuinely blank, so its identity conjunction remains exactly as it was, and a
test asserts that.

**Control plane.** A never taught `bin/fm-control-lib.sh` about agy, so
`fm-control.sh <id> interrupt|exit` would have refused it. B's tables are
brought across with their verified values: single Escape, no clear key needed
(the composer returns to its bare `>`), `/exit`, no cancellation acknowledgement
(agy fires no hook on interrupt, exactly like claude).

**Model catalogue validation** (`bin/fm-agy-lib.sh`) is B-only: an unrecognized
model exits 1, so validating up front turns a dead pane into a clean spawn
refusal. Both spellings agy accepts are honoured, and a catalogue that cannot be
fetched is treated as establishing nothing rather than as proof of absence.

## Repairs applied to A

These were not disagreements with B - they are places A was wrong on its own
terms, fixed rather than dropped.

**A's primary hooks were entirely inert.** All four hooks in
`.agents/hooks.json`, and `bin/fm-turnend-guard-agy.sh` itself, began with
`[ -n "${ANTIGRAVITY_PROJECT_DIR:-}" ] || exit 0`. agy sets no such variable for
hook processes - a hook's environment carries `ANTIGRAVITY_AGENT`,
`ANTIGRAVITY_CONVERSATION_ID` and friends, but not that one - so every hook
exited 0 immediately and did nothing. They now anchor on the hook's own working
directory, which agy documents and this repo verified as the directory
containing `hooks.json`. Verified after the change: the hook fires, its cwd is
`<project>/.agents`, and the payload carries `conversationId`.

**A's turn-end guard could not have worked even once repaired.** It read
`session_id` and `stop_hook_active` from the payload; agy sends neither. It then
forced continuation with `agy --continue <session_id> -p <prompt>`, but
`--continue` takes no id argument (the resume form agy prints on exit is
`agy --conversation=<id>`) and `-p` is one-shot print mode, which would have run
a separate headless agent rather than continuing the primary's own turn.
The guard is rewritten to agy's documented native contract:
`{"decision":"continue","reason":"..."}` on stdout re-enters the same execution
loop. Verified live - a Stop hook returning that object made the model perform
the injected instruction, and Stop fired a second time when the hook allowed the
stop. Loop safety, which `stop_hook_active` would have provided, is a bounded
per-conversation block budget instead.

**A's tmux change was a duplicated, unreachable case line.** A appended a second
`case` branch instead of editing the first, leaving five unreachable patterns,
and used an unanchored `*agy*` that contradicts A's own comment in
`bin/fm-harness.sh` about not claiming siblings such as `agy-helper`. Replaced
with one anchored `agy)` branch.

**A's busy-source comment** carried Claude's event names verbatim; corrected.

## Rebase conflicts

`main` gained the Cursor adapter after A was written. Three files conflicted and
all three resolved as unions, with cursor fully intact:

- `bin/fm-spawn.sh` and `bin/fm-remote-secondmate-control.sh` - `main` had
  already **promoted** cursor to a supported remote secondmate, while A still
  carried the older refusal. Main's newer position is kept and agy is added
  beside it, so neither adapter is weakened.
- `bin/fm-supervision-instructions.sh` - both adapters added a protocol name to
  the same list; unioned.

## Open questions for the captain

1. **Primary supervision is repaired but not end-to-end verified.** The hooks now
   fire and the guard's native continuation is verified, but a full agy *primary*
   session - session-start nudge, the PreToolUse seatbelts, and the watcher arm
   in `docs/supervision-protocols/agy.md` - was not exercised in this task. Given
   those hooks have been inert since they were written, none of that path has
   ever actually run. It deserves its own live pass before an agy primary or
   secondmate is trusted in the fleet.
2. **`data/learnings.md` still records the silent-fallback claim.** It is
   captain-private and out of scope for me to edit, but it is the source the code
   comments cited and it is wrong for 1.1.12.
3. **`fork/fix/agy-effort-dedup`** is superseded - its one commit is the effort
   change A already absorbed as `e556d61`, which this consolidation then replaced.
