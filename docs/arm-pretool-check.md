# Watcher arm PreToolUse seatbelt

This page is the concise human contract for the watcher-arm command seatbelt.
`bin/fm-arm-command-policy.mjs` owns command classification and exports the shell tokenizer shared by the cd guard.
`bin/fm-arm-pretool-check.sh` owns hook transport, JSON shaping, and fail-open handling.
Tests own the executable regression matrix.

## Purpose and boundary

The seatbelt blocks a primary session from launching watcher-arm commands in shapes that hide lifecycle output, detach the cycle, or bundle unrelated work around the watcher.
The Pi extension, Claude Stop hook, OpenCode plugin, Grok hook, and Codex foreground checkpoint own ordinary watcher re-arm paths, while direct foreground diagnostics stay possible for the narrow harnesses that deliberately use them.
A human or agent must follow the current tool-specific watcher instruction rather than inventing a background shell form.
The policy is semantic rather than string-only so simple quoting, `env`, `cd`, `command`, `builtin`, `nohup`, `timeout`, nested shells, shell substitutions, redirections, pipelines, and control-flow wrappers do not bypass it.
The guard is deliberately narrow: it classifies shell commands before execution, and it does not try to supervise already-running watcher processes.

## Blocked command families

The policy denies these families when the command line would execute them from a primary shell:

- `fm-watch-arm.sh` launched in the background.
- `fm-watch-arm.sh` hidden behind a pipeline, redirection, process substitution, command substitution, nested shell, `eval`, heredoc, or variable-constructed payload.
- `fm-watch-arm.sh` bundled with unrelated commands through `;`, `&&`, `||`, newlines, loops, conditionals, or similar control flow.
- Broad watcher process kills such as `pkill -f fm-watch`, `killall fm-watch.sh`, or loop-shaped variants that target watcher process names rather than a verified PID.
- Protected watcher-arm shapes that the classifier cannot parse safely enough to distinguish from a detached, nested, or bundled launch.

The policy allows direct foreground watcher-arm forms that the active harness contract explicitly uses, read-only references, documentation greps, editor operations, terminal sends into isolated labs, and checks that mention watcher-arm strings without executing or killing them.
The blessed direct diagnostic path for Codex-style foreground checks is `bin/fm-watch-checkpoint.sh`.

## Reason codes

The command policy returns stable reason codes so tests, hooks, and operator messages can stay compact.

| Code | Meaning |
| --- | --- |
| `watcher-background` | The command would launch `fm-watch-arm.sh` in the background. |
| `watcher-pipeline` | The command would hide watcher-arm lifecycle output behind a pipeline. |
| `watcher-redirection` | The command would redirect watcher-arm lifecycle output. |
| `watcher-bundled` | The command would bundle watcher-arm with unrelated shell work. |
| `watcher-nested` | The command would execute watcher-arm through a nested or constructed shell payload. |
| `watcher-direct` | The command would use a direct protected form that is not allowed in that classifier context. |
| `broad-watcher-kill` | The command would broadly kill watcher processes by pattern or basename. |
| `unclassifiable-protected-command` | The command mentions protected watcher operations in an executable position the classifier cannot prove safe. |

The exact deny message is owned by the scripts so it can name the current safe alternative.
Do not duplicate full message text in prose.

## Hook transport

The checker accepts harness stdin payloads and command-line probes and exits with the hook semantics each harness expects.
Allow returns exit 0 with no denial object.
Deny returns the harness-shaped denial object with a watcher-specific system message.
Malformed input, missing command fields, unsupported payloads, and missing optional transport dependencies fail open so a broken hook never blocks unrelated work.

Claude Code requires empty stdout for a PreToolUse deny to be honored, so the Claude hook path writes the denial object on stderr only.
Grok consumes a stdout decision object, so the Grok hook path keeps that shape.
OpenCode and Pi use their native extension/plugin adapters to turn the same classifier result into their host-specific block response.

## Harness wiring

Tracked hook and extension wiring lives next to each harness integration.
The Grok hook command must use inline default expansions such as `${GROK_WORKSPACE_ROOT:-}` because Grok expands the raw hook command before `bash -lc` runs it.
The tracked matcher should pass every shell command to the checker and let this policy decide, rather than attempting to enumerate every unsafe spelling in hook configuration.

## Validation

Automated coverage lives in `tests/fm-arm-pretool-check.test.sh` and the shared classifier tests.
The focused validation command is:

```sh
tests/fm-arm-pretool-check.test.sh
```

Run `bin/fm-lint.sh` after changing the scripts or hook files.
Empirical harness quirks above are retained only where they affect the current contract; historical transcripts and one-off reproduction logs belong in private task evidence, not this maintained page.
