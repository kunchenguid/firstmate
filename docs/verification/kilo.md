# Verification: the kilo (Kilo Code CLI) adapter

Active empirical facts for firstmate's kilo adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/kilo.md`](../../.agents/skills/harness-adapters/references/harness/kilo.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `kilo 7.8.8` |
| Verified | 2026-10-10 |
| Binary | `/opt/homebrew/Cellar/kilo/7.8.8/libexec/kilo` (a ~206 MB Bun-compiled single executable); `/opt/homebrew/bin/kilo` is a wrapper that execs it |
| Platform | macOS (darwin, Homebrew) |
| Backend | A local `script(1)` PTY and a small `python3` `pty.fork` driver in a throwaway `/tmp/kilo` directory |

Every command below ran in the throwaway directory.
No captain fleet state was touched.

## Detection: ancestry only, no marker

```
$ ps -o comm= -p <kilo pid>
/opt/homebrew/Cellar/kilo/7.8.8/libexec/kilo
```

`basename` of that comm is `kilo`, so `bin/fm-harness.sh` matches the anchored process name `kilo` alone.
Kilo Code is an OpenCode fork and its binary embeds `packages/opencode/src/...` strings; it exports `OPENCODE=1` from that lineage, which is deliberately NOT registered as a marker because it would rename every markerless child a genuine kilo started.
`FM_KILO_HARNESS=kilo` is Firstmate's launch marker, established by `bin/fm-spawn.sh` at the launch boundary, which also clears the inherited foreign markers (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `FM_OMP_HARNESS`, `GEMINI_CLI`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, `ATLASSIAN_AGENT_TYPE`, `ROVODEV_CLI`).
`tests/fm-kilo-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `kilo` ancestor once the spawn clears it.

## Launch: `--auto --prompt`, no trust dialog

`kilo --help` (7.8.8) documents `--auto`, `--prompt`, `-m/--model`, `--agent`, `-c/--continue`, `-s/--session`, `--worktree`, and `--mini`.
The base TUI exposes no reasoning-effort flag; only the separate `kilo run` subcommand has `--variant`.
`--worktree` is deliberately never passed, because kilo would create its own git worktree and break Firstmate's isolation.

A launch in the throwaway directory rendered its composer immediately with no folder-trust dialog:

```
Ask anything... "Fix a TODO in the codebase"   Code   DeepSeek: DeepSeek V4.1 Flash   Kilo Gateway   ctrl+t variants  tab agents  ctrl+p commands
```

kilo auto-upgrades in the background; this record is scoped to 7.8.8.

## Busy state: the `esc interrupt` footer, unknown on absence

A live turn was driven through the `pty.fork` driver: the driver wrote a prompt, waited, and captured the rendered frames.
Mid-turn the footer carried:

```
... Kilo Gateway  max                    esc interrupt       ctrl+t variants  tab agents  ctrl+p commands
```

After the turn completed the footer dropped the token and showed the elapsed/cost cells (`4.8s 31.7K (3%)`) instead.
`fm_busy_kilo_tail_busy` and the delivery guard in `bin/fm-composer-lib.sh` match the `esc interrupt` token alone.
Kilo exposes no hook surface, so this is a rendered-tail fallback, not a recorded state writer; `fm_busy_classify` reports `unknown kilo-regex` when the token is absent, because a long turn can scroll the marker out of the captured tail.
The free-floating word `interrupt` alone is deliberately not a signal.
`FM_DELIVERY_KILO_BUSY_REGEX_DEFAULT` is declared separately so a supplied `harness=kilo` can never borrow another harness's token.

## Interrupt and exit

A long turn was driven (a `sleep 40` bash command) and Escape was sent mid-turn through the PTY.
The first press changed the footer to `esc again to interrupt`, so kilo requires a double Escape exactly like OpenCode:

```
after-prompt   ['esc interrupt']
after-esc1     ['esc again to interrupt', 'esc interrupt']
```

`bin/fm-control-lib.sh` records `Escape` sent twice, no clear key, no ack source, and `/exit` for kilo.
Kilo intercepts Ctrl+C for its own two-press exit confirmation, which is why C-c is deliberately NOT its interrupt key.
Sending `/exit` plus Enter exited the process (the PTY master read failed with EIO as the child exited).

## What is still unproven

The plugin runtime contract (`.kilo/plugin/` discovery path and the `client.session.promptAsync` injection call) is taken from the Kilo plugin documentation and its OpenCode lineage and is NOT yet re-verified live, so the plugin stack is shipped as parity, not as a live-verified primary.
`tests/fm-kilo-primary-live-e2e.test.sh` is the opt-in live gate that settles it: it loads the tracked plugin stack into an isolated clone, proves the arm plugin starts a singleton successor on an actionable close, proves the `promptAsync` follow-up reaches the model, and proves the plugins stay silent in a linked child worktree.
Until that gate is recorded here as passing, treat primary and secondmate kilo as supported-but-parity.
Kilo is NOT a verified supervision-host engine, so a kilo primary always runs the plain watcher arm; host support is a deferred follow-up.
No slash-skill invocation form was verified, so skill invocation stays natural language.
No `--continue` or `--session` resume was exercised; recovery uses deterministic relaunch from the brief on disk.
No secondmate run was exercised; secondmate support rests on the same launch/control/interrupt/exit facts as a crewmate.

## Refreshing this record

Run the portable suite and the live guards after any kilo upgrade, because the process name, marker set, and rendered busy/interrupt/exit text are all vendor-controlled surfaces that the spawn and the busy fallback match verbatim:

```
bin/fm-test-run.sh tests/fm-kilo-harness.test.sh
FM_KILO_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-kilo-signals-live-e2e.test.sh
FM_KILO_PRIMARY_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-kilo-primary-live-e2e.test.sh
```
