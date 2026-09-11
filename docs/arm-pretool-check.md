# Watcher arm PreToolUse seatbelt

This document is the authoritative human-readable contract for the watcher arm PreToolUse seatbelt.
`bin/fm-arm-command-policy.mjs` is the single semantic owner.
`bin/fm-arm-pretool-check.sh` is only the stable harness transport and output renderer.
The tracked harness adapters forward command text without classifying it.
`bin/fm-arm-command-policy.mjs` is also the sole owner of firstmate's shell classification: it exports the tokenizer and command-position analysis, which the sibling cd-guard seatbelt (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`) reuses instead of duplicating shell lexing.

## Purpose and boundary

A firstmate primary must arm `bin/fm-watch-arm.sh` or run `bin/fm-watch-checkpoint.sh` through an observable harness call.
A shell background operator, pipeline, redirection, wrapper, or unrelated command list can hide failure or let the watcher child die with the tool call.
The seatbelt rejects those command shapes before execution.

The same classifier also refuses the known forms of a broad process kill - one that selects processes by command line or name rather than by the caller's own ancestry, process group, or session.
Worktrees are isolated but the process table is not: a match on what a process is running reaches every matching process on the host, including sibling lanes, parallel firstmate homes, and the captain's own sessions.
The watcher prohibition is the highest-severity special case of this rule; see "General broad process kill" below.
This is a denylist over shell command text, and a denylist over shell has no completeness floor: the residual list in that section names the known gaps and is not a proof that nothing else gets through.

This policy is not a post-arm liveness guarantee.
`bin/fm-guard.sh` and `bin/fm-turnend-guard.sh` apply their respective post-arm supervision predicates to the watcher lock and beacon after an allowed call.

This policy reaches only agents that load this repository's project settings.
No-mistakes gate agents run with `disable_project_settings: true` (see [`../.no-mistakes.yaml`](../.no-mistakes.yaml) and [`architecture.md`](architecture.md) "No-mistakes gate authority boundary"), so this PreToolUse seatbelt is not active inside a gate agent; for that surface the shared-process-table rule in `AGENTS.md` and the crewmate brief's shared-daemon rule in `bin/fm-brief.sh` (never stop or restart the shared no-mistakes daemon; check status and reattach instead) are the containment.

The classifier never executes, sources, evaluates, or expands any part of the submitted command.
It tokenizes the bytes and classifies lexical execution positions only.

## Transport and fail-open behavior

`bin/fm-arm-pretool-check.sh` supports these entry forms:

- Stdin JSON at `.tool_input.command` for Claude and Codex.
- Stdin JSON at `.toolInput.command` for Grok.
- `--command <exact string>` for OpenCode, Pi, pi-signed, and omp.
- `--background` as a compatibility-only field that never changes the decision.
- `--claude` to preserve Claude's stderr-only deny requirement.

The wrapper discovers the code root from its own location.
The active firstmate home is `${FM_HOME:-<code-root>}`.
It passes both roots and the exact command string to the Node policy owner.

The wrapper fast-allows a command without invoking the Node policy owner only when the command cannot contain any trigger substring even after the classifier's decoders run.
Every deniable command carries one of a small set of trigger substrings after normalization: a protected watcher execution or a broad watcher kill contains `fm-watch`, and a general broad process kill contains `kill` (`pkill`, `killall`, `fuser -k`, and a `kill` of pid `-1` all carry it), a discovery command that feeds a kill (`pgrep`, `ps`, `lsof`, `pidof`, `fuser`), or the `xargs` pipe tail that consumes one.
The fast path may allow only when both of these hold:

1. The stripped text lacks every trigger substring (`fm-watch`, `kill`, `pgrep`, `ps`, `lsof`, `pidof`, `fuser`, `xargs`), after mirroring the classifier's cheapest byte normalizations - dropping line-continuation and escape backslashes, quotes, and newlines.
2. The raw command carries no quoting-decoder marker: a `$` immediately followed by a single quote (ANSI-C `$'...'`) or a double quote (bash locale `$"..."`).

Any trigger substring or any quoting-decoder marker delegates to the classifier.
Normalizing first keeps this a strict superset: a protected watcher path obfuscated as `fm-watc\<newline>h-arm.sh` or `fm-"watch"-arm.sh`, and a kill verb obfuscated as `pk"ill"`, all still delegate, and stripping only those non-alphanumeric bytes can never destroy an existing trigger substring.
The quoting-decoder marker closes the case the byte strip cannot: `bin/fm-$'\x77'atch-arm.sh` and `bin/fm-$"watch"-arm.sh` both resolve to `bin/fm-watch-arm.sh` only after the classifier decodes the encoded character, so a cheap byte strip would otherwise lose the `fm-watch` bytes and fast-allow them.
This trigger set and marker set are coupled to the classifier in `bin/fm-arm-command-policy.mjs`: adding any new denied command family, or any new quote or expansion form the classifier decodes, requires extending these sets in the same change, or the prefilter stops being a strict superset.
The prefilter owns no semantic exception: it can only ever fast-allow a command that is definitely not a deniable command, so it never flips a classification and the classifier remains the single owner of every decision.
The bare `ps` trigger also matches ordinary commands that merely contain those two bytes (`https://`, `apps/`, `deps`), so more commands now pay the classifier's roughly 70 ms startup instead of fast-allowing; this is an accepted, correctness-neutral cost, because narrowing the trigger would risk fast-allowing a deniable command.

The seatbelt's threat model is agent mistakes: no one accidentally writes an ANSI-C- or locale-obfuscated watcher path, and deliberate obfuscation is the post-arm liveness guard's territory.
The marker guard closes the static gap anyway because it is cheap and provable per encoding class.
Tripwire: if a third strict-superset gap is ever found after this marker generalization, that falsifies the "provable per encoding class" claim and the decision flips to Option B - drop the prefilter and always invoke the classifier.
Deeper decode-required obfuscation beyond the coupled marker set stays the classifier's and the post-arm liveness guards' responsibility.

Malformed or empty stdin, invalid JSON, missing `jq` for stdin transport, missing Node, a missing classifier, or an invalid classifier response fail open with exit 0 and no output.
This transport behavior prevents a broken hook from denying every shell tool call.
Malformed or unsupported shell syntax that contains a protected command is a semantic classification result and fails closed.

## Command-position classification

The tokenizer recognizes cooked words with quote provenance, comments, heredoc bodies, shell list operators, pipelines, redirections, command and process substitutions, parenthesized subshells, brace groups, and literal nested execution payloads.
Quoted text, comments, heredoc bodies, and later argument words are data positions unless a recognized execution sink recursively executes them.

A command word in executed position is a protected execution when its normalized path suffix matches one of the protected watcher scripts:

```text
bin/fm-watch-arm.sh          (arm; blessed entry point)
bin/fm-watch-checkpoint.sh   (checkpoint; blessed entry point)
bin/fm-watch.sh              (watch; protected but never blessed)
```

The relative form, the `<code-root>`-anchored absolute form, and any word ending in `/bin/<script>` all resolve to that identity.
Suffix matching recognizes an expanded-path prefix statically, so `$FM_HOME/bin/fm-watch-arm.sh`, `$HOME/firstmate/bin/fm-watch-arm.sh`, and `~/firstmate/bin/fm-watch-arm.sh` are the arm identity.
The classifier never expands the variable or tilde; it matches the literal bytes only.
Static quote forms are cooked before the suffix match, so a command word split by ordinary quotes (`fm-"watch"-arm.sh`), ANSI-C quoting (`fm-$'\x77'atch-arm.sh`), or a bash locale string (`fm-$"watch"-arm.sh`) all resolve to the same identity; this reads the fixed literal bytes as the shell would cook them and never runs an expansion or a command.
This covers statically-visible literal words in command position; opaque dynamic dataflow such as `bash -lc "$WHOLE_COMMAND"` remains out of scope.

`bin/fm-watch.sh` is protected but is not a blessed entry point.
A direct `bin/fm-watch.sh` execution - relative, `<code-root>`-anchored, `$VAR`-prefixed, or `~`-prefixed - always denies with `watcher-direct`, whose reason points the caller at `bin/fm-watch-arm.sh` and `bin/fm-watch-checkpoint.sh`.

The same bytes in an argument, comment, assertion, documentation query, Python string, `printf`, or `tmux send-keys` payload are data and do not make the outer command relevant.

Literal `sh`, `bash`, or `zsh` `-c` payloads and literal `eval` payloads are recursively classified.
A literal nested payload that only runs a data-bearing command is allowed.
A literal nested payload that executes a protected command is denied as `watcher-nested`, even when that inner protected call would be allowed at top level.

Dynamic payloads such as `bash -lc "$WATCHER_COMMAND"` cannot be proven statically and remain the post-arm guard's responsibility.
If the submitted command first constructs a protected literal assignment and then feeds a dynamic value to a recognized shell or `eval` sink, the classifier denies conservatively as `watcher-nested`.

Comments and heredoc bodies are ignored as execution syntax.
An actual protected command with a heredoc still has a redirection and is denied.

## Blessed syntax tree

An allowed watcher program is one linear outer command list with zero or more approved setup nodes followed by exactly one direct protected node.
`bin/fm-watch-arm.sh` and `bin/fm-watch-checkpoint.sh` are the only blessed final nodes, including their expanded-path forms; a `bin/fm-watch.sh` final node is never blessed and denies with `watcher-direct`.

Approved setup nodes are:

- `cd <one path word>`.
- `export NAME=<one shell word>` with no command substitution, process substitution, or redirection.
- `source <x-mode path>` or `. <x-mode path>`.
- `[ -f <x-mode path> ] && source <x-mode path>` and the equivalent dot form.

The allowed x-mode paths are `config/x-mode.env`, `./config/x-mode.env`, and an absolute path that normalizes to `<active-firstmate-home>/config/x-mode.env`.
An absolute x-mode path outside the active home is not an approved setup node.

Approved nodes may be separated by `;`, a real newline, or `&&`.
`&&` is accepted after setup so a failed `cd`, `export`, or source prevents the protected call from running under the wrong setup.

The final protected node may have one immediate `exec` wrapper.
Its arguments are ordinary shell words and may contain quoted semicolons or watcher names.
No other wrapper is approved.

Inline environment assignments, `env`, `sudo`, `nohup`, `builtin`, a leading `!` negation, nested shells, `eval`, subshell groups, substitutions, redirections, pipelines, asynchronous lists, `disown`, unrelated list nodes, and unsupported compound syntax are not blessed.

## Broad watcher kills

An actually executed `pkill` command is denied when its parsed pattern arguments target `fm-watch`.
Path-qualified `pkill`, `command pkill`, and `sudo pkill` are recognized.

`kill "$(pgrep -f '/bin/fm-watch.sh')"` is also denied because the executed `kill` consumes an executed watcher-wide `pgrep` substitution.
A standalone read-only `pgrep` is allowed.
Quoted text such as `echo 'pkill -f fm-watch'` is data and is allowed.

Unsupported compound grammar - a loop, `case`, `if`, or other construct the classifier does not model - is failed closed for broad kills the same way it is for protected executions.
When the command carries such grammar and its raw bytes reference both a `fm-watch` target and a `pkill` or `kill` verb, the classifier cannot prove which command position the kill occupies, so it denies with `broad-watcher-kill` rather than allowing.
This backstop mirrors the protected-execution fail-closed rule and covers forms like `while true; do pkill -f fm-watch; done`, `for x in 1; do pkill -f fm-watch; done`, `case x in x) pkill -f fm-watch ;; esac`, and `until false; do kill $(pgrep -f fm-watch); done`.
It is gated on the grammar being unsupported: in grammar the classifier does model, command-position analysis is authoritative, so data mentions such as `echo 'pkill -f fm-watch'` and a loop that only names the watcher without a kill verb such as `for f in 1; do echo fm-watch; done` remain allowed.

## General broad process kill

The watcher rule above is the highest-severity case of a wider one: any kill that selects processes by command line or name reaches every match on the shared process table, not just the caller's own tree, so it can hit a sibling lane.
The classifier denies the known broad-kill forms enumerated here with `broad-process-kill`.
It is a denylist over shell command text, and a denylist over shell has no completeness floor, so the residual list below names the known gaps and is not a proof that nothing else gets through.
The shared-process-table rule in `AGENTS.md` is the containment for the no-mistakes gate-agent surface (`disable_project_settings`), which this seatbelt never reaches, and remains the containment for any bypass this list does not name.
The enumerated forms are:

- `pkill` or `killall` that does not select by the caller's own ancestry, process group, or session.
  The caller-scope flag set is exactly `-P`/`--parent`, `-g`/`--pgroup`, and `-s`/`--session`, as a standalone short option with an optional attached numeric or expansion value (`-P`, `-P123`, `-g0`, `-s5`, `-P$$`, `-P$pid`) or the long form (`--parent 123`, `--parent=123`).
  A signal name is never a scope flag: `pkill -HUP node`, `pkill -SIGHUP node`, `pkill -STOP -f X`, `pkill -PIPE node`, and `pkill -9 -f node` are all broad even though the signal name contains one of the letters.
  `killall` has no scope flag and is always broad, as is `-G` (a real unix group id, not a process group).
  Path-qualified forms and the prefixes `!`, `builtin`, `command`, `exec`, `env`, `nohup`, `sudo`, and `timeout`/`gtimeout` are recognized through the same wrapper unwrapping as the watcher rule (`! pkill -f node`, `! ! pkill -f node`, `builtin kill -- -1`), and `time` is routed to the raw fallback.
- `fuser -k` (or `--kill`, with any signal such as `-KILL -k`), which kills every process holding the named port or file host-wide; `fuser` without `-k` is read-only discovery.
- `kill` targeting pid `-1` (`kill -9 -1`, `kill -- -1`, `kill -s TERM -1`), directly or as the `xargs` utility (`echo x | xargs kill -- -1`), which signals every process the caller may reach; a leading `-<signal>` or `-s <sig>` is read as the signal spec, so `kill -1 1234` (SIGHUP to one pid), `kill -- -12345` and `kill -12345` (a process group), and `kill -- -$pgid` are allowed.
- `xargs pkill` or `xargs killall` whatever feeds the pipe (`echo node | xargs pkill -f`, `cat names | xargs killall`), because those select by name; an `xargs pkill` that carries a caller-scope flag is allowed.
- An executed `kill` (or `xargs kill`/`xargs pkill`) fed by an unscoped discovery command - one that selects processes by attribute rather than by a caller-owned pid: an unscoped `pgrep`, any `ps`, any `lsof`, `pidof`, or `fuser`.
  `lsof` is discovery on any invocation, like `ps`, so the table-plus-`awk` form (`lsof -i :3000 | awk 'NR>1{print $2}' | xargs kill -9`) is denied exactly as the `-t` form is.
  `ps` and `lsof` are always treated as unscoped discovery even with `--ppid`, `-s`, or `-i` selectors, so a scoped kill must use `pgrep -P`/`-g`/`-s` (or a specific pid); this is a deliberate, accepted false positive on the `ps`/`lsof` spelling of caller-scoped cleanup, because honoring their scope selectors is platform-sensitive.
  The recognized feeds are command substitution (`kill $(pgrep -f X)`, `kill $(ps aux | grep X | awk '{print $2}')`, `kill $(pidof X)`), a single variable hop (`p=$(pgrep -f X); kill $p`, `p=$(ps aux | grep X | awk '{print $2}'); kill $p`), and a pipe tail (`pgrep -f X | xargs kill`, `ps aux | grep X | awk '{print $2}' | xargs kill`, `lsof -ti :3000 | xargs kill -9`); any node between the discovery and the `xargs` in the same pipe run is fine.
  A discovery wrapped in the producer node's subshell, brace group, or substitution still counts as the feed (`(pgrep -f X) | xargs kill`, `{ pgrep -f a; pgrep -f b; } | xargs kill`, `echo $(pgrep -f X) | xargs kill`).
  The `xargs` utility is unwrapped through the same finite wrapper set as a command position (`sudo`, `env`, `command`, `nohup`, `exec`, `timeout`), so `xargs -n1 sudo kill` is still a kill, and `xargs` options with a separated value (`-n 1`, `-I {}`, `-L 1`, `--max-args 1`) or `--` do not hide the utility.
  A `pgrep` that itself selects by ancestry, group, or session (for example `pgrep -P $$`) is caller-scoped, so the kill it feeds is allowed.
  Caller-owned pid sources are not discovery: `kill $(cat pidfile)`, `kill $(jobs -p)`, `echo 123 | xargs kill`, and `cat pids | xargs kill` are allowed.
  `kill -0` sends no signal and is a liveness probe, so `kill -0 $(pgrep -f X)` and `pgrep -f X | xargs kill -0` are allowed.
  Query and help forms execute no kill and are allowed, in supported grammar and inside loop/`if`/`case` grammar alike: `command -v pkill`, `command -v killall`, `type pkill`, `which pkill`, `pkill --help`, `pkill -V`, `killall -l` (any invocation whose only arguments are `--help`, `-h`, `-V`, `--version`, `-l`, or `-L`).

The classifier judges the shape, not runtime identity: it permits the caller-scopeable forms without proving the argument value is the caller's own, exactly as the watcher rule permits `pkill -P <pid>` regardless of the pid.
A specific `kill <pid>` is allowed, because a literal pid carries no evidence of a foreign origin in the command text.
Read-only discovery (`pgrep -f X`, `ps aux | grep X`, `lsof -i :3000`) and quoted data (`echo 'pkill -f X'`) are never kills and are allowed.

Unsupported compound grammar (a loop, `case`, `if`, or other construct the classifier does not model) falls back to a raw byte check, the same way the watcher backstop does.
The raw check first blanks `command -v`/`type`/`which` lookup spans and help/version-only kill-tool invocations, then fires on any `killall`, on a `fuser` followed by `-k`/`--kill`, on a `kill` whose target after a signal spec or `--` is the literal `-1` within the same simple command (the span stops at `;`, `|`, `&`, parens, or a backtick, so `while kill -0 "$pid"; do tail -1 "$log"; done` is not a kill-all), on a `pkill` whose own argument span (up to the next `;`, `|`, `&`, newline, or closing paren) carries no caller-scope flag outside quotes, and - when the command also carries a `kill` or `xargs` verb - on such an unscoped `pgrep`, or on any `ps`, `lsof`, `pidof`, or `fuser`.
Quoted spans are blanked before the scope-flag test, so a pattern that merely contains scope-looking text (`while true; do pkill -f "node server.js -P 3000"; done`) is still denied, while a quoted scope value (`pkill -P "$pid"`) is still scoped.
So `while true; do pkill -f node; done`, `while true; do kill -9 -1; done`, `if true; then lsof -ti :3000 | xargs kill -9; fi`, and `for x in 1; do kill $(pidof node); done` are denied, while the recommended scoped cleanup idiom `for p in $(pgrep -P $$); do kill $p; done`, the SIGHUP form `for x in 1; do kill -1 1234; done`, and the portable probe `if command -v pkill >/dev/null 2>&1; then echo y; fi` are allowed.

Residuals - what this rule does not catch, so a reader can tell without running it:

1. A kill utility reached through a nested inner shell after `xargs` (`xargs sh -c "kill $0"`, `xargs -I{} sh -c "kill {}"`) or a consumer-side group (`pgrep -f X | (xargs kill)`) is not caught; catching these needs interpreting the inner shell or an arbitrary group, which is deliberately out of scope.
2. Discovery output routed through anything other than a command substitution or a plain `$var` reference is not tracked: a file (`ps aux | grep X > /tmp/pids; kill $(cat /tmp/pids)`), an array, a parameter transform, or an intermediate command that is not itself discovery.
   The classifier follows direct variable references (`a=$(ps ...); b=$a; kill $b` is denied), not general shell dataflow.
   In unsupported loop/`if`/`case` grammar the raw check is byte-level, so a discovery command and a `kill`/`xargs` anywhere in the same command are denied together even when the shell would not connect them.
3. A bare kill-tool token (`pkill` or `killall`, or a `pgrep`/`ps`/`lsof`/`pidof`/`fuser` alongside a `kill` or `xargs`) used as pure data inside unsupported loop/`if`/`case` grammar (`if grep -q pkill tests/x.sh; then echo y; fi`) is conservatively denied, because the raw fallback cannot tell data from command there, except for the recognized query and help forms above; the supported-grammar equivalent `grep -q pkill tests/x.sh && echo y` is allowed.
4. A discover-then-literal-kill across two commands (`pgrep -f X` now, `kill 76803` later) cannot be caught by any command-shape seatbelt, because the literal pid carries no evidence of foreign origin; the shared-process-table rule in `AGENTS.md` is the containment for it.
5. The gate-agent surface under `disable_project_settings` (see "Purpose and boundary") does not load this seatbelt at all; the `AGENTS.md` rule and the crewmate brief's shared-daemon rule are the containment there.
6. The `ps`/`lsof` spelling of caller-scoped cleanup (`ps -o pid= --ppid $$ | xargs kill`, `kill $(ps -o pid= --ppid $$)`) is denied as unscoped discovery; use `pgrep -P`/`-g`/`-s` or a specific pid instead.
7. An unrecognized exec-through utility placed in front of a kill utility (`nice`, `setsid`, `stdbuf`, `ionice`, `caffeinate`, `doas`, `chrt`, `taskset`, or any other command word the classifier does not unwrap) is not unwrapped, so `nice pkill -f node` is allowed; only `!`, `builtin`, `command`, `exec`, `env`, `nohup`, `sudo`, and `timeout`/`gtimeout` are unwrapped, and `time` is routed to the raw fallback.

## Stable reason codes

Every semantic deny includes one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `watcher-background` | A protected execution is in an asynchronous list or uses `nohup` or `disown`. |
| `watcher-pipeline` | A protected execution participates in any pipeline. |
| `watcher-redirection` | A protected execution uses shell redirection. |
| `watcher-bundled` | The outer command list is not the blessed setup-plus-final tree. |
| `watcher-nested` | A wrapper, group, substitution, nested shell, `eval`, or constructed dynamic payload executes the protected command. |
| `broad-watcher-kill` | An actual broad process kill targets the watcher. |
| `broad-process-kill` | An actual `pkill`/`killall`/`fuser -k` selects by command line, name, or port rather than by the caller's own ancestry, process group, or session; a `kill` (direct or as the `xargs` utility) targets pid `-1`; or a `kill`/`xargs kill` is fed by an unscoped discovery command (`pgrep`, `ps`, `lsof`, `pidof`, `fuser`) through a substitution, one variable hop, or a pipe tail, so it can reach a sibling lane on the shared process table. |
| `unclassifiable-protected-command` | Malformed or unsupported syntax contains a protected command and cannot be safely classified. |
| `watcher-direct` | A direct `bin/fm-watch.sh` execution; the watcher must be reached through `bin/fm-watch-arm.sh` or `bin/fm-watch-checkpoint.sh`. |

Reason codes are the stable contract for tests and adapters.
Prose may improve without changing adapter behavior.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[code] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi, pi-signed, and omp return `{block: true}` only when the checker exits 2.

## Harness wiring

| Harness | Exact command field | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Codex | `.tool_input.command` | The `.codex/hooks.json` command forwards the complete stdin payload and Codex blocks on exit 2. |
| Claude | `.tool_input.command` | `.claude/settings.json` forwards stdin with `--claude`, leaving stdout empty and returning the stderr deny object. |
| Grok | `.toolInput.command` | `.grok/hooks/fm-primary-pretool-check.json` forwards stdin and Grok consumes the stdout `decision=deny` object. |
| OpenCode | `output.args.command` | `.opencode/plugins/fm-primary-pretool-check.js` passes one `--command` argument and throws only for exit 2. |
| Pi / pi-signed | `event.input.command` | `.pi/extensions/fm-primary-turnend-guard.ts` passes one `--command` argument and returns `{block: true}` only for exit 2. |
| omp | `event.input.command` | `.omp/extensions/fm-primary-turnend-guard.ts` passes one `--command` argument and returns `{block: true, reason}` only for exit 2; omp surfaces the reason verbatim to the model (verified 18.1.2). |
| Cursor | `.tool_input.command` | `.cursor/hooks.json` matches `tool_name` `Shell` and forwards stdin with `--cursor`. Cursor reads the RETURNED object rather than the exit status, so `--cursor` prints `{"permission":"deny","user_message":"[code] reason"}` on stdout and exits 0; only that rendering is verified to block the command and surface the reason. |

Cursor also loads `<project>/.claude/settings.json`, so the tracked Claude entry receives the same event. Without `--cursor` a Cursor-delivered payload is that duplicate and allows without re-classifying, decided from the payload's own `cursor_version` by `bin/fm-hook-host-lib.sh`; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns why that predicate reads the payload rather than the environment.

Grok project hooks require folder trust.
Cursor project hooks require the workspace to be launched with `--trust`.
Every shell variable reference in a Grok hook command must carry an inline default such as `${GROK_WORKSPACE_ROOT:-}` because Grok expands the raw hook command before `bash -lc` runs it.
The tracked Grok adapter therefore references `${GROK_WORKSPACE_ROOT:-}` directly instead of assigning and later reading a shell-local `$root` variable.

## Live validation record, 2026-07-09

Validation ran in a git-initialized scratch firstmate-shaped project under this task worktree.
The scratch project contained copies of the modified checker and policy, unchanged tracked adapters, a dummy checkpoint, a dummy arm script, a harmless `tmux` argument-capture fixture, and a private sentinel path.
No modified file was installed into the primary checkout or a live harness configuration.
No live watcher, fleet state, or herdr lifecycle command was used.
The OpenCode interactive check used the dedicated tmux socket `fm-pretool-smoke`.

Harness versions were:

```text
Claude Code 2.1.206
codex-cli 0.144.0
grok 0.2.93 (f00f96316d4b)
OpenCode 1.17.15
Pi 0.80.5
```

Every harness was instructed to issue these exact shell command strings as separate tool calls:

```sh
printf 'UNRELATED_EXECUTED\n'
pgrep -fl '/bin/fm-watch.sh' || true
source '<scratch-project>/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180
tmux send-keys -t isolated-pi-lab "printf '%s\n' 'bin/fm-watch-arm.sh &'"; tmux send-keys -t isolated-pi-lab Enter
bin/fm-watch-arm.sh &
```

The real harness launch commands were:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
GROK_HOME="$SCRATCH_GROK_HOME" RUST_LOG=xai_grok_hooks=debug GROK_LOG_FILE="$SCRATCH_LOG" grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
```

Observed output for the four allowed calls was `UNRELATED_EXECUTED`, a successful read-only `pgrep`, `CHECKPOINT_EXECUTED`, and two `TMUX_ARGS:` lines that preserved the watcher text as data.
Each harness blocked the final command with exit 2 mapped through its native adapter behavior.
The stable reason was `[watcher-background] a protected watcher command cannot run in an asynchronous shell list or through nohup/disown`.
The dummy arm body would have created `<harness>.sentinel` if the denied command executed.
All five sentinel files remained absent.

The Codex transcript showed `PreToolUse Completed` for all three originally reported false-positive shapes and `PreToolUse Blocked` only for the backgrounded arm.
The Grok debug transcript showed four exit-0 results from `project/fm-primary-pretool-check`, then exit 2 with 145 stdout bytes, 214 stderr bytes, and `hook denied` for the backgrounded arm.
OpenCode displayed the four allowed command outputs and then `bin/fm-watch-arm.sh & failed` with the stderr deny object.
Claude and Pi both reported that calls one through four ran and the final call was blocked.

Native supervision paths were also validated in the same scratch project:

- Claude ran `bin/fm-watch-arm.sh --restart` with its native tracked background option and produced `watcher: started pid=<scratch> (scratch)`.
- Grok ran the same exact command with `background: true`, its hook returned exit 0, and the dummy arm produced the same started line.
- Codex ran the foreground checkpoint above and produced `CHECKPOINT_EXECUTED`.
- OpenCode ran in an interactive TUI on `tmux -L fm-pretool-smoke`, reached `session.idle`, and its unchanged watch-arm plugin created the scratch automatic-arm marker.
- Pi loaded both primary extensions, called `fm_watch_arm_pi`, and created the scratch automatic-arm marker.

Every native-path automatic marker was present and every deny sentinel remained absent.

## Automated validation

`tests/fm-arm-pretool-check.test.sh` owns the adversarial acceptance matrix.
Every row runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms, so the harness adapter wiring - unchanged in mechanism since the 2026-07-09 live record above - carries the broad-process-kill deny exactly as it carries the watcher denies.
The matrix `K` series and the `test_broad_process_kill_contract` direct assertions cover the general broad-process-kill class, including the exact 2026-09-10 cross-lane incident shape (a kill fed by an unscoped `pgrep -f <phrase>`), the `pkill`/`killall`/pipe variants, signal-name options, separated-value `xargs` options, wrapped `xargs` utilities, `xargs pkill` by name, `ps`/`lsof`/`pidof`/`fuser` discovery feeds (direct or wrapped in the producer node), `fuser -k`, `kill` of pid `-1`, and the paired caller-scoped, caller-owned-pid, negative-process-group, `kill -0`, query/help, and scoped-loop forms that must remain allowed.
The suite also verifies the widened transport prefilter delegates the `kill`/`pgrep`/`ps`/`lsof`/`pidof`/`fuser`/`xargs` trigger substrings, real newline bytes, direct classifier reason codes, comments, heredoc data, malformed and unsupported protected syntax, constructed dynamic payloads, malformed transport fail-open behavior, missing runtime fail-open behavior, output shapes, and exact adapter field forwarding plus exit-2 mapping.

Run:

```sh
bash -n bin/fm-arm-pretool-check.sh
shellcheck bin/fm-arm-pretool-check.sh tests/fm-arm-pretool-check.test.sh
node --check bin/fm-arm-command-policy.mjs
tests/fm-arm-pretool-check.test.sh
bin/fm-test-run.sh --all
```
