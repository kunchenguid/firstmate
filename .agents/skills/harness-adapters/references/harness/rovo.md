# Rovo CLI

Verified 2026-09-02 on Rovo CLI 202609.1.2 for crewmate/scout work only.
Not verified, and not naturally verifiable, as a secondmate or primary: rovo has no turn-end hook and no primary supervision protocol, the same gap that scopes muse to crewmate/scout.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_rovo_binary` in `../../../bin/fm-spawn.sh` resolves `PATH`, then falls back to `$HOME/.local/bin/rovo`; spawning refuses if neither is executable. |
| Launch | Bare `rovo run --yolo` (no positional brief), the kimi launch-then-send shape: a readiness gate on the `Welcome to Rovo!` banner, then a typed absolute brief pointer, then a delivery-confirmation gate. A positional brief is dead-on-arrival (see "Launch and readiness" below). |
| Models | `--model <model>`, discovered from the in-session `/models` command or ACP `session/new`; the observed live list (GPT-5.6 Terra/Sol/Luna, GPT-5.5, GPT-5.4, several Claude Sonnet/Opus/Haiku ids, Gemini 3 ids) is per-account and must never be hardcoded. |
| Busy state | Rendered-tail fallback, isolated to rovo like Grok's - the animated `Rovo is thinking...` line, matched by `fm_busy_rovo_tail_busy` in `../../../bin/fm-busy-lib.sh` - because rovo's `eventHooks` fire at tool granularity only (`on_tool_start`/`on_tool_end`), never at turn-end, so no semantic writer exists to arm. |
| Exit command | `/exit` (also `/quit`, and a single idle Ctrl-C); prints `Run rovo --restore <session-id> to resume your conversation`. |
| Interrupt | Single Escape is the cancel key and prints `Agent cancelled`; `../../../bin/fm-control-lib.sh` records its acknowledgement source as `none` (see "Interrupt: confirmed under real tmux" below), the same conservative choice as claude/codex/grok/kimi/cursor. |
| Skill invocation | `/<skill>`, the Claude/Grok form, but see "Skill-loading interop gap" below - a rovo worker cannot invoke a firstmate skill until that gap is resolved. |
| Autonomy | `--disable-permission-checks` (alias `--yolo`) runs every file CRUD operation and bash command without confirmation, though its own printed caveat keeps permission checks on tools accessing Atlassian data and user-provided MCP servers, which crew/scout tasks never touch. |
| File access | rovo confines every file-tool operation to its launch worktree by default, so the standard instructions/steering/status/report loop - whose files live in the firstmate home outside the worktree - fails until granted. `../../../bin/fm-spawn.sh`'s `rovo_config_override_flag` grants `toolPermissions.allowedExternalPaths` at launch, folded into the single `--config-override` (see Effort), for exactly this task's brief directory, steering inbox, and status file. The grant lifts the file tools only; rovo's bash tool stays worktree-confined regardless, so the crewmate status line's `echo ... >> status` lands only because the worker falls back to its own file tool for the append. See `../../../../docs/verification/rovo.md`. |
| Trust dialog | None observed on a clean launch in a fresh worktree; `--yolo` clears crew/scout's confirmation prompts, but it is not the only launch grant the standard flow needs - see File access for the required `allowedExternalPaths` grant. |
| Environment marker | `ATLASSIAN_AGENT_TYPE=rovo` (most specific) and `ROVODEV_CLI=1`, both set on rovo's tool subprocesses alongside `AGENT=rovodev_cli`, none of which rovo scrubs from an inherited `CLAUDECODE`/`CURSOR_AGENT`/etc - so `../../../bin/fm-harness.sh` tests rovo's markers before the `CLAUDECODE` line (the same ordering hazard cursor already documents, issue #3517) and `../../../bin/fm-spawn.sh` clears foreign markers at the launch boundary too. |
| Process name | `comm=rovo` on the tool subprocess and the `rovo run` process itself, because the installed wrapper execs the generation's `rovo` shim so argv[0] stays `rovo` even though the on-disk binary is `atlassian_cli_rovodev`. |
| Composer | The existing bordered `box` shape family (`╭─╮ │ │ ╰─╯`) `../../../bin/fm-composer-lib.sh` already reads, with an empty composer showing de-emphasized suggestion chips and a `? for shortcuts.` hint, and a busy footer reading `Enter to queue, Ctrl+Enter to steer`. |
| Effort | `agent.efficiencyLevel`, accepted `low\|medium\|high\|max` (default `medium`, no CLI `--effort` flag), set live through rovo's single `--config-override` flag - folded into the SAME JSON object as the mandatory `allowedExternalPaths` grant, never emitted as a standalone override, because `--config-override` is single-value (see `../../../../docs/verification/rovo.md`) - with an `xhigh` request recorded in task metadata but omitted from that object per `../../../references/common/model-and-effort.md`'s record-and-omit contract because rovo has no `xhigh`. |

## Detection

`../../../bin/fm-harness.sh` checks `ATLASSIAN_AGENT_TYPE=rovo` and `ROVODEV_CLI=1` before the `CLAUDECODE` line, then falls back to ancestry (`rovo)` case, beside `kimi)`).
Both layers matter for the same reason cursor's do: marker ordering covers a rovo session a human started by hand under an inherited foreign marker, while `../../../bin/fm-spawn.sh`'s launch-boundary `env -u` clearing covers every firstmate-launched worker regardless of ordering.

## Launch and readiness

The launch template clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` inline (rovo's own foreign-marker exposure), and the shared outer wrap clears `CURSOR_AGENT`/`CURSOR_INVOKED_AS` like every other non-cursor harness.
rovo launches BARE (`rovo run --yolo`, plus any `--model`/`--config-override` flags) and takes its brief only after the TUI comes up - the same launch-then-send shape as kimi, wired through the same shared readers (`fm_backend_capture`, `fm_backend_composer_state`, `fm_backend_send_text_submit`):

1. **Readiness gate** (`rovo_wait_for_ready` in `../../../bin/fm-spawn.sh`): poll for the fresh-launch `Welcome to Rovo!` ASCII banner, falling back to composer-empty. The banner is the primary signal because the composer-empty fallback is weaker for rovo than for kimi - rovo's idle composer renders an inline placeholder chip whose luminance sits above the ghost-strip threshold (see "Composer ghost text" below), so it can read non-empty.
2. **Typed pointer**: `Read the brief at <absolute-path> and follow it exactly.`, submitted through `fm_backend_send_text_submit` (the exact wording and mechanism kimi uses).
3. **Delivery gate** (`rovo_wait_for_delivery`): composer empty AND either the echoed pointer text (`Read the brief at`) has scrolled into view or rovo's `Context:` footer percentage has advanced off zero. rovo's real footer is `Context: <bar> N.N% NN.NK/NNNK` (e.g. `Context: ▎ 3.3% 30.1K/922K`); the delivery regex tolerates the bar glyph and arbitrary spacing but anchors to the digits before the `%`, so the always-nonzero denominator (`.../922K`) can never masquerade as usage.

A positional brief is dead-on-arrival: `rovo run --yolo "<brief>"` loads, never enters a working state, and drops back to an idle shell within about 10-15 seconds - confirmed independently four times over a raw PTY and once under real tmux 3.6a with the exact `fm-spawn.sh` send-keys shape. `--startup-receipt` cannot rescue that shape either: it requires "prompt-free interactive mode" (`Invalid value: --startup-receipt requires prompt-free interactive mode in a terminal`), so it cannot gate a launch that will have a message typed into it. The launch-then-send shape, by contrast, is confirmed live end to end (bare launch -> `Welcome to Rovo!` -> typed pointer -> `Rovo is thinking` for a real bash tool call -> clean `/exit`); see `../../../../docs/verification/rovo.md`.
rovo leaves no worktree-resident artifact and no firstmate-owned sidecar at all, and has no readiness receipt or session-id to record.

## Composer ghost text: a known, unfixed gap

rovo's empty composer renders an inline placeholder chip (e.g. `Summarize my open tasks`) directly inside the bordered content row, not merely as a separate suggestion list below it.
Measured live, that placeholder's foreground is `38;2;162;163;165` (luminance ~163), while real typed text in the same box is `38;2;206;207;210` (luminance ~207) - a real gap, but one that sits entirely above `../../../bin/fm-composer-lib.sh`'s default `FM_COMPOSER_GHOST_LUMA_MAX` of 128, so `fm_composer_strip_ghost` does not strip it and a fresh rovo composer can misclassify as `pending` instead of `empty`.
Raising the shared default to catch it is not safe: muse's own real, must-not-be-stripped prompt glyph measures luminance ~149.9, below rovo's ghost luminance, so no single global threshold can keep muse's real glyph while dropping rovo's ghost chip.
This is deliberately left unfixed rather than patched with a threshold change that would risk muse's already-verified behavior; a real fix needs a harness-scoped signal the shared composer classifier does not currently carry.
The practical consequence is bounded to composer-emptiness consumers - steering into an idle rovo pane may see a non-empty verdict and retry through the normal doorbell ladder rather than deliver on the first try.
It does not block the launch-then-send gates: readiness leads with the `Welcome to Rovo!` banner (not composer-empty), and while the delivery gate does require composer-empty as one conjunct, it runs while rovo is actively processing the just-delivered brief - the placeholder chip renders only at idle rest, not mid-turn - so the composer reads genuinely empty during the delivery window.

## Interrupt: confirmed under real tmux

The original verification scout (`fm-rovo-smoke-s1`, PTY smoke) observed a single Escape print `Agent cancelled` during a running tool call.
A follow-up live check under real tmux 3.6a - an isolated `tmux -L <private-socket>` session/window, not the shared fleet session - reproduced the scout's exact finding: a single Escape sent during a genuine mid-flight bash tool call printed `Agent cancelled` in the captured pane.
The launch-then-send live guard (`../../../../tests/fm-rovo-signals-live-e2e.test.sh`) now reproduces it over a raw PTY too: an earlier single fixed-timer Escape landed unreliably (the interrupt instant is timing-sensitive over a bare PTY), so the guard sends Escape across the live tool-call window until the cancel renders - a deterministic way to reproduce a timing-sensitive interrupt, and confirmed to print `Agent cancelled` every run.
Escape is the interrupt key and is what `fm_control_interrupt_key` returns.
`fm_control_interrupt_ack_source` still records `none` for rovo - the same conservative choice already made for claude/codex/grok/kimi/cursor, a control-plane fact independent of whether the render happens to appear - so the control plane sends the key and lets its own postcondition, not a parsed string, decide whether the agent actually stopped.
The interrupt key and its rendered evidence are now fully corroborated rather than in tension with the code.

## OAuth token lifetime

The access token lasts about one hour, but `rovo` refreshes it silently and non-interactively from a stored refresh token (about four weeks' lifetime) with no browser prompt and no visible interruption - this is standing captain-corrected guidance, not this task's own discovery, and this task's own live checks corroborated it empirically: `rovo auth status` showed `Access token expired ... but a refresh token is present`, then a plain `rovo run` completed successfully and a follow-up `rovo auth status` showed a freshly valid token with no interactive step in between.
Treat the ~1h access-token lifetime as an ordinary operational fact, not a non-negotiable-safety blocker: a rovo worker does not need to be scoped short to survive it.
`rovo auth login` (interactive browser OAuth) is needed only after roughly four weeks of disuse or if the refresh token itself is invalidated.

## Skill-loading interop gap

rovo's skill loader rejects every firstmate skill: `Invalid skill definition in .../SKILL.md: 'metadata -> internal': Input should be a valid string`, because firstmate's `metadata.internal` is a boolean and rovo's schema wants a string.
This blocks `/no-mistakes` and every other firstmate skill invocation inside a rovo worker until firstmate's `SKILL.md` frontmatter is made rovo-compatible (a separate, deferred follow-up - it touches every skill file and the installer contract, per `../../firstmate-coding-guidelines/SKILL.md`).
A `no-mistakes`-mode rovo ship crewmate is blocked by this gap; a rovo scout, which invokes no skill, is unaffected.

## ACP as a future upgrade

`rovo acp` (Agent Client Protocol) and `rovo serve --non-interactive` expose a fully structured, machine-readable turn lifecycle: `session/prompt` returns a real `{"stopReason":"end_turn"}`, and `session/cancel` is a protocol-native interrupt.
This is a cleaner done-signal than any current adapter has, but consuming it means firstmate runs a JSON-RPC client and owns the session lifecycle itself - a new backend-shaped surface, not a drop-in TUI adapter - so it is out of scope here.
It remains a deliberate future upgrade for a rovo-as-structured-backend follow-up, not a near-term path; do not build it as part of this TUI-path adapter.
