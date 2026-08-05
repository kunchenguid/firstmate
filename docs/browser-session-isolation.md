# Fail-closed browser-session isolation

This document is the authoritative human-readable contract for firstmate's per-task browser-session isolation.
`bin/fm-browser-session-guard.sh` is the single decision owner.
`bin/shims/chrome-devtools-axi` is a symlink onto it that puts that decision in front of a spawned agent's ordinary browser command.
`bin/fm-spawn.sh` binds each task's own session and places that shim on the agent's PATH.

## Purpose and boundary

`chrome-devtools-axi` isolates concurrent browser work by the name in `CHROME_DEVTOOLS_AXI_SESSION`, giving each distinct name its own bridge process, port, and on-disk state.
It resolves an unset name to `"default"`.
So an agent that never sets the variable does not get its own browser - it silently joins one shared instance along with every other agent that also left it unset, inheriting that instance's tabs, cookies, and signed-in accounts.

That is not a hypothetical.
A crewmate doing live browser verification saw a real production account belonging to a *different* concurrent task, because a leftover authenticated tab from that other task was present in the shared session, and it then included that account's id in its own cleanup script.

The dangerous property is the direction of the default: absent configuration, the tool shares.
firstmate cannot change that upstream default, so this guard supplies the missing refusal.
In a task-scoped context, a browser command with no per-task session aborts with a loud reason instead of running shared.

This guard is not a browser sandbox and not a permissions system.
It classifies exactly one thing: whether this invocation has a session name that actually isolates.
It makes no judgment about which sites an agent may visit or what it may do there.

## Two enforcement layers, and what each one is for

The layers are complementary; neither alone is the contract.

**1. The binding rides the launch command.**
`bin/fm-spawn.sh` prefixes the assembled launch command with `CHROME_DEVTOOLS_AXI_SESSION=<task id>` and a PATH entry for the guard shim, the same way it already prefixes `CLAUDE_CONFIG_DIR` and a secondmate's `FM_HOME`.
It also exports the same binding into the pane's own shell, so a command typed into that pane later is bound too.

This placement is the point, and it is chosen from evidence.
The first version of this protection lived *only* as a separate pre-launch pane line, beside the launch command rather than inside it.
A relaunch assembled by hand from `launch_template()` - which is how firstmate recovers a dead agent - copied the launch command, dropped that separate line, and silently reverted to the shared session, three days after the protection was introduced.
A binding that sits beside the launch command is droppable by anything that copies the launch command; a binding inside it is not.
Keeping it inside makes the launch command the complete contract, so copying it carries the protection.

**2. The shim refuses what the binding does not cover.**
The binding cannot help once something clears, empties, or overrides the variable downstream, and it cannot help a launch path that never set it.
The shim closes that class: any `chrome-devtools-axi` call that reaches it without an isolating session is refused rather than run.

## Refuse, allow, and inert

The guard **refuses** a browser-driving invocation when `CHROME_DEVTOOLS_AXI_SESSION` is unset, empty or whitespace-only, or exactly `default`.
Those are precisely the values that resolve to the shared instance.
The refusal names the missing isolation, states the consequence, and gives the exact rebinding command.

The guard **allows**:

- Any invocation whose session name actually isolates, which is every correctly launched task. A task with its own session is unaffected.
- `--help`, `-h`, `help`, `-v`, `-V`, `--version`, and `setup`, which report or install rather than drive a browser session. Keeping these open means `chrome-devtools-axi setup hooks` during bootstrap and ordinary version probes never depend on a task binding.

The guard is **inert** - identical to allow - in two contexts, so legitimate shared use keeps working:

- The working directory is a genuine firstmate primary home, detected with the shared predicate in `bin/fm-primary-scope-lib.sh`. firstmate's own session browses on the shared instance by design; only task-scoped agents must be isolated from each other. A linked task worktree is not a primary home, so a crewmate or scout working inside one is still enforced.
- `FM_BROWSER_SHARED_SESSION_OK=1` declares deliberate shared-session use, the same explicit-escape shape as `FM_ALLOW_SUBAGENT=1` in `bin/fm-subagent-pretool-check.sh`. Intent has to be stated rather than inferred from an absent variable.

Note the deliberate asymmetry with the primary-session guards (`docs/cd-guard.md`, `docs/arm-pretool-check.md`, `docs/subagent-guard.md`): those fire only in the primary home and are inert in task worktrees.
This one is the mirror image, because the hazard is the reverse.

## Fail-closed, including when the guard cannot decide

Where the primary-session guards prioritize zero false blocks and fail open, this guard fails closed.
If `bin/fm-primary-scope-lib.sh` is missing or unreadable, the scope question cannot be answered, and an unisolated command is refused rather than allowed.
A missing real `chrome-devtools-axi` is reported as an error rather than passed off as success.
A blocked browser command costs one rebinding step; a wrongly shared browser session has already cost a production account.

## Exit contract

| Exit | Meaning |
| --- | --- |
| `0` | Allowed: isolation present, a sessionless subcommand, or an inert context. In shim mode the real `chrome-devtools-axi` is `exec`'d and its own status is returned. |
| `1` | Refused. The reason is on stderr; the real tool is never run. |
| `2` | Usage error, or the real `chrome-devtools-axi` could not be resolved on PATH. |

## Entry shapes

- `bin/shims/chrome-devtools-axi <args>...` - the transparent shim. It enforces, then `exec`s the first real `chrome-devtools-axi` on PATH that does not resolve back to itself, so a shim directory that appears anywhere on PATH cannot make it call itself. `FM_BROWSER_GUARD_ACTIVE=1` is a second stop against re-entry.
- `bin/fm-browser-session-guard.sh check [<args>...]` - decide only, never run the tool. This is the preflight form.
- `bin/fm-browser-session-guard.sh exec <args>...` - enforce, then run.

The shim is a symlink rather than a second script so the decision has exactly one owner, and so `bin/fm-lint.sh`'s existing `bin/*.sh` file set already covers the code behind it.

## The residual gap, stated plainly

This is not an unconditional guarantee, and it should not be described as one.

The guard is reached because firstmate puts its shim on the agent's PATH.
Two things therefore get past it.
A launch that bypasses firstmate's tooling entirely - not the launch command, not the pane exports, not the shim PATH entry - reaches the real `chrome-devtools-axi` directly and shares the default session, exactly as before.
An invocation by absolute path, such as `/opt/homebrew/bin/chrome-devtools-axi`, also skips PATH resolution and so skips the shim; in a correctly launched task that is harmless, because the binding on the launch command is still in the environment, but it is not independently enforced.
Closing either completely would require the upstream tool to refuse an unset session itself, which is not a change firstmate can make.

A remote secondmate is a third case, of a different kind.
Its launch command is not assembled here at all: `bin/fm-spawn.sh` hands a marked remote route to the configured host, which runs its own `bin/fm-spawn.sh` there ([`remote-secondmates.md`](remote-secondmates.md), [`trace-context.md`](trace-context.md)).
So the binding and the shim PATH entry are the remote checkout's own, resolved against the remote code root, and a remote secondmate launched from an up-to-date host gets both layers exactly as a local one does.
The residual condition there is version skew rather than a missing shim: a remote code root that predates this change adds neither layer, because it is that host's `bin/fm-spawn.sh` that would have to add them.
`bin/fm-update.sh` is what closes that skew.

What the two layers do change is the realistic failure mode.
The documented incident and the documented near-miss both came from firstmate-managed launches: one from no isolation existing at all, one from a hand-built relaunch dropping a separate setup line.
Layer 1 removes the second by making the launch command self-contained, and layer 2 turns any remaining unisolated call that still reaches the shim from a silent share into a loud refusal.

## Automated validation

`tests/fm-browser-session-guard.test.sh` owns the acceptance matrix: the refusal cases (unset, blank, `default`), the allow cases (an isolated session, the sessionless subcommands, a primary home, a declared shared use), the linked-worktree enforcement, the fail-closed refusal when the scope predicate is unreadable, the `check` CLI, the usage-versus-refusal exit split, the shim's anti-recursion and missing-tool behavior, the spawn wiring proven on the launch command `bin/fm-spawn.sh` actually sends, and the generated briefs' statement of the contract.
No agent is spawned and no browser is launched; a stub stands in for `chrome-devtools-axi`.

Run:

```sh
bin/fm-lint.sh bin/fm-browser-session-guard.sh tests/fm-browser-session-guard.test.sh
tests/fm-browser-session-guard.test.sh
```
