# Verification: the muse (Muse Code) crewmate adapter

Active empirical evidence for firstmate's muse adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Versions | Core adapter: `Muse Code 0.1.0 (0.1.0-R708.1)`, build sha `427a430436`; effort surface and session protocol: `Muse Code 1.3.0 (1.3.0-R3401.1)` |
| Verified | Core adapter 2026-08-05, credentialed multi-step smoke 2026-08-06, effort compatibility 2026-09-20, session protocol 2026-09-20 |
| Baseline artifact | `muse-aarch64-macos`, sha256 `4290bfafa5bbb81a6fd493aaea12f848c789b1d22edfa0c4b849151deba3e70c` |
| Platform | Core adapter and effort surface on macOS arm64 (Darwin 25.5.0); session protocol on Linux x86_64 |

### Effort compatibility refresh

The interactive effort surface was reverified 2026-09-20 on the installed Muse Code 1.3.0 build on macOS arm64.

```
$ muse --version
Muse Code 1.3.0 (1.3.0-R3401.1)

$ muse --help
      --reasoning-effort <EFFORT>
          Meta reasoning effort: none|minimal|low|medium|high|xhigh|max|ultra
          (default: high)
```

Muse 1.3 exposes distinct `max` and `ultra` values.
For `max`, the spawn queries the resolved absolute launcher with `MUSE_SYNC_UPDATE=1 muse --version`, waits through any already-held `.muse-update-lock`, and repeats resolution after that updater finishes.
The settled launcher report is the cheapest reliable source of the release selected after update handling, and requiring the named versioned executable to return the same report binds that release to the exact image preserved for launch.
It verifies the version-suffixed executable named by the settled result, publishes a unique task-attempt-owned `state/muse-bin-<id>+<token>` image, records that basename in task metadata, verifies the image, and places its exact path in the worker command.
Publication prefers a same-filesystem hard link, then a platform copy-on-write clone where supported, and uses an ordinary copy only as the portability fallback.
The task image remains executable with detectable Muse ancestry even when a later vendor update removes its source.
The `+` separator gives each task a namespace that cannot overlap a dotted task identifier, and spawn and teardown share the task lifecycle lock so teardown cannot remove an uncommitted image while spawn still owns it.
Attempt-specific ownership keeps an abort or delayed signal from removing an image already named by durable metadata or a successor image.
A successful replacement retires prior images, and successful task teardown removes every task-owned image before its metadata owner; an unlink failure refuses without discarding the discoverable identity so a relaunch, fresh retry, or teardown retry can finish cleanup.
An inherited `MUSE_NO_AUTO_UPDATE=1` remains authoritative for a deliberately pinned installation.
Muse 0.1.0 maps Firstmate `max` to its highest supported value, `ultra`, while Muse 1.3.0 and later receive the distinct `max` value unchanged.
An unparseable version, an unreadable version command, or the unverified range between 0.1.0 and 1.3.0 is refused before launch.
The spawn regression in `tests/fm-muse-harness.test.sh` exercises the Muse 1.3 shared ladder from `low` through `ultra`, proves the legacy mapping and fail-closed version boundary, and reproduces both a legacy-to-1.3 shim transition and an already-in-flight update that deletes the old binary.
It also proves process ancestry, dotted-task isolation, duplicate-spawn and abort-versus-retry isolation, spawn-versus-teardown serialization, signal-safe publication, retryable unlink failures, and relaunch composer cleanup and readiness probing without interrupting fresh shell startup, dropping relaunch environment exports, or changing the shell umask.

### Session protocol refresh

The session protocol was reverified 2026-09-20 on the installed Muse Code 1.3.0 build on Linux x86_64, after the 0.1.0 prefix matcher stopped matching real logs.

```
$ muse --version
Muse Code 1.3.0 (1.3.0-R3401.1)
```

Muse 1.3 keeps the run lifecycle pair but reorders its keys: the payload leads with the event object, and the terminal event leads with timing fields rather than kind.
The bracket is unchanged in meaning: top-level payload kind `run` with event kind `started` opens the turn, and the same `run_id` with event kind `terminal` closes it.
Both serializations are supported by one order-independent fold, because a vendor update mid-day can leave a single log holding both shapes.
The 1.3 started and terminal records have this shape, with identifying values redacted:

```
payload: {"event":{"kind":"started","prompt":"<text>"},"kind":"run","run_id":"<uuid>",...}
payload: {"event":{"eot_gate_ms":<n>,"kind":"terminal","reason":<null|string>,"terminal":"completed"|"cancelled",...},"kind":"run","run_id":"<uuid>",...}
```

Three 1.3 decoys share the log with the lifecycle pair: tool batch effects carry a nested `record` of kind `terminal` for the same run, model-configuration records nest a `run_stream` of kind `run`, and tool-task records run their own `started`/`completed` pairs under the same `run_id`.
None of them is a top-level run, so the fold ignores all three, along with the 0.1.0 cleanup-effect decoy it already rejected.
The one-turn-one-run relationship holds on 1.3: every surveyed real-model session held exactly one run `started` record, and every settled one held exactly one `terminal` for the same `run_id`.
An Escape interrupt closes its 1.3 run with `terminal` set to `cancelled` and a string `reason`, against `null` for a completed turn.

The live guard drives a real echo-provider turn through the interactive TUI and folds it back to back:

```
$ bin/fm-test-run.sh tests/fm-muse-signals-live-e2e.test.sh
ok - Muse's real session protocol classifies busy in flight (submit 1)
ok - Muse's real session protocol emits one matched run bracket per submitted turn
ok - Muse's real bright prompt glyph classifies as an empty composer
```

That run passed three consecutive times on 2026-09-20.
An echo turn settles about forty milliseconds after its started record reaches the log, which is why the guard submits interactively and samples with no sleep.
The guard also verifies its submit landed before folding: an Enter sent in the same tick as the typed text is evaluated against a still-empty composer and ignored, so the text must be visible plus settled before Enter goes out.
A session log of several megabytes folds in tens of milliseconds.

The binary was fetched from the published channel and its checksum matched the published manifest before any run:

```
$ curl -sS 'https://api.meta.ai/muse-code/channels/muse-stable'
{"channel":"muse-stable","version":"0.1.0-R708.1",...,"state":"public","min_version":null}

$ shasum -a 256 muse-bin
4290bfafa5bbb81a6fd493aaea12f848c789b1d22edfa0c4b849151deba3e70c  muse-bin
```

Every run below used an isolated `XDG_CONFIG_HOME` and `XDG_DATA_HOME` in a scratch directory and a throwaway git workspace, driven through tmux the way firstmate drives a crewmate pane.
`install.sh` was deliberately bypassed, so no shell profile and no `~/.local/bin` entry on the host was touched.

## What the model provider limits

Live TUI and session behavior below was observed against the built-in `--provider echo` startup provider, except for the provider-authentication prompt.
The credential paths and unauthenticated wait were probed separately against the default `meta` provider.
Turn-boundary structure, the trust dialog, interrupt, exit, composer rendering, credential behavior, and the event-log schema are real and verified.
Busy-state behavior under a genuine multi-step, real-model tool loop was verified separately on 2026-08-06 against the default `meta` provider with a live model, and is recorded under [the credentialed multi-step smoke](#the-credentialed-multi-step-smoke-verified-2026-08-06).
The turn-to-run relationship itself was re-established on 1.3.0 as recorded under [the session protocol refresh](#session-protocol-refresh).

## Verified facts

### Process identity

For an ordinary launch, the published launcher `exec`s a version-suffixed binary, so the live process name changes on every auto-update:

```
$ grep -nE 'muse-bin|exec ' launcher.sh
969:  candidate="$work/muse-bin"
977:  target="$dir/muse-bin-$version"
1035:  printf '%s/muse-bin-%s\n' "$dir" "$version"
1135:  exec "$binary" "$@"
```

`ps -o comm= -p <pid>` returns the full executable path, whose basename is `muse-bin-<version>` for an ordinary launch and `muse-bin-<id>+<token>` for a pinned `max` launch.
That is why both `bin/fm-harness.sh` and `bin/backends/tmux.sh` match the anchored prefix `muse-bin-*` rather than an exact name, and why neither can rely on an install-path component.
The Muse launch clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, and `CURSOR_INVOKED_AS` before the worker starts, which is the verified launch behavior rather than what detection depends on.
[Harness detection precedence](runtime-backends.md#harness-detection-precedence) owns why a retained foreign marker cannot override the versioned ancestry.

[`runtime-backends.md`](runtime-backends.md#agent-liveness-name-sources) owns the resulting tmux liveness verdict and its relationship to the portable decoy regression.

### Turn lifecycle

On Muse 0.1, a two-turn session produced exactly two run brackets, the second closed by an Escape interrupt:

```
9  {"kind":"run","run_id":"d352a097-...","event":{"kind":"started","prompt":"hello from firstmate"}}
45 {"kind":"run","run_id":"d352a097-...","event":{"kind":"terminal","terminal":"completed","turn_duration_ms":8152}}
49 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"started","prompt":"second turn to interrupt"}}
78 {"kind":"run","run_id":"b50dac92-...","event":{"kind":"terminal","terminal":"cancelled","reason":"cancelled during model step"}}
```

Muse 1.3 writes the same pair with the payload keys reordered, as recorded under [the session protocol refresh](#session-protocol-refresh).

Muse 0.1 writes the workspace binding metadata as the first record.
Muse 1.3 writes a retained permission transaction first and the same `runtime.session.metadata` record immediately after it, so the resolver scans the bounded opening records rather than assuming the first line is metadata:

```
"payload_type": "runtime.session.metadata",
"payload": {"kind":"metadata","record":{"workspace_root":".../muselab/ws1","provider_id":"echo",...}}
```

The fold transitions live, sampled on 0.1.0 during a 25-second in-flight turn:

```
T+ 5s fold=busy
T+10s fold=busy
T+15s fold=busy
T+20s fold=busy
T+25s fold=busy
T+30s fold=settled
```

On 1.3 the same transition is shown by the live guard, whose exact output is recorded under [the session protocol refresh](#session-protocol-refresh).

Two decoys were observed in real 0.1.0 logs and are pinned by regressions in `tests/fm-muse-harness.test.sh`:
a nested `"record":{"kind":"terminal"}` cleanup-effect payload that is not a run terminal, and independent sub-agent run lifecycles under `subagent/<child-session-id>/session.jsonl`.
Three more decoys were observed on 1.3: a tool batch effect with a nested terminal record for the same run, a model-configuration record with a nested run stream, and tool-task lifecycle records under the same run identity.
The same regression suite pins all of them, plus mixed-shape logs holding both serializations, prompt text that embeds forged lifecycle fragments, and corrupt lines that must fold to unknown rather than idle.
The same regression suite verifies that unique resolution is cached, a changed current-day main-session namespace restores ambiguity to unknown, a replacement spawn binding selects its fresh main log, missing cached logs fail closed, and cached sub-agent paths are rejected.

### Autonomy, trust, and sandbox

A fresh untrusted workspace shows the trust dialog with option 1 preselected:

```
Do you trust this workspace?
> 1  Trust and continue
  2  Quit
Use Up/Down or 1/2, then Enter. Esc quits.
```

`--yolo` suppresses it entirely and the status bar reports `echo · <workspace> · YOLO`.
This matters because approval and the sandbox are ON by default and `--sandbox-network` defaults to `proxy-only`, which the binary reports as requiring managed shell sandboxing - a crewmate needs ordinary git and network access.

### Credentials

`muse auth set --provider` accepts only `meta`.
An unauthenticated launch does not exit; it waits indefinitely:

```
  Sign in at this page:
    https://auth.meta.com/oauth/device/?code=DGXZ-NRPR
  Waiting for approval…
  Esc cancel
```

That is why `bin/fm-spawn.sh` preflights worker-reachable `META_API_KEY` or `<config>/muse/auth.json` and refuses before creating an endpoint.
A caller-only `META_API_KEY` is refused because a long-lived backend daemon does not inherit it, while the non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` roots are resolved to absolute paths before preflight and forwarding so the stored credential and session-log binding reach the same worker environment.

### Foreign personal context

The interactive TUI rejects the `exec`-only flag:

```
$ muse --no-foreign-personal-context --provider echo hi
invalid TUI options: error: unexpected argument '--no-foreign-personal-context' found
  tip: a similar argument exists: '--no-session-log'
```

`MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL` is the control that works in TUI mode.
Comparing the `context_block_diagnostic` block ids emitted by otherwise identical runs, with the operator's real `~/.claude` rules present and no project `AGENTS.md`:

```
base     blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
killon   blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
kill1    blocks=workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

Repeating the comparison with a project `AGENTS.md` present confirms the kill switch drops only the FOREIGN rules:

```
a4base   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
a4kill   blocks=rules_file,workspace_identity,security_mode,skills_catalog,session_identity,subagent_delegation
```

The `tui.foreign_context_notice_shown` flag in `settings.json` suppresses only the notice, never the loading, so a quiet later launch is not evidence of a clean context.

### Composer rendering

Captured with `tmux capture-pane -p -e`:

```
^[[38;2;90;160;255m^[[48;2;38;56;84m⟩ ^[[38;2;204;211;219mhello from firstmate^[[39m
^[[0m^[[38;2;90;160;255m⟩ ^[[39m
```

Those captures are Muse 0.1, whose prompt glyph is `⟩` (U+27E9) at luminance ~149.9 against the 128 default ghost threshold; typed text at ~209.8.
After a single Escape the interrupted prompt is restored into the composer at the same bright ~209.8, and `C-u` clears it.
Muse 1.3 renders its composer marker as `❯` (U+276F) with a 256-color foreground, observed as `38;5;75` for a luminance of about 160.2 against the same 128 threshold.
The live guard accepts either glyph and verifies both truecolor and fixed-palette brightness, rejecting theme-dependent base colors and malformed sequences through its self-test controls.

## The credentialed multi-step smoke (verified 2026-08-06)

This was the one item deferred until a `META_API_KEY` was available, because it is what decides whether a settled log may classify `idle`.
An open run was always positive proof of a turn in flight, but a settled log only proves no run is open at that instant, so the classifier held idle behind an opt-in in case a real turn spanned several runs.
The smoke below answered that: one run brackets a whole multi-step turn, and an Escape interrupt closes that run with `terminal=cancelled` rather than leaving the turn to continue in another run.
The credentialed result gives a settled Muse log the same idle trust as the Claude and Pi push sources, so the opt-in was removed and `bin/fm-busy-lib.sh` classifies a settled log `idle` outright.
Muse auto-updates its vendor binary underneath the fleet, firstmate normalizes the versioned process identity to the `muse` harness before busy classification, and the session log's own metadata carries semver `0.1.0` plus a build SHA that cannot be matched to that normalized identity.
A verified-build allowlist against this coarse identity would be false precision because it could not distinguish the running build, as well as a maintenance treadmill against the auto-updating binary.

Both runs below used the default `meta` provider with model `muse-spark-1.2-contributor`, on a real firstmate-launched crewmate pane, authenticated through the stored `~/.config/muse/auth.json` written by `muse auth set --provider meta --api-key-stdin` so the key never entered `argv`.

### One turn stays inside one run

A single 8-step tool loop (shell, file reads, a file write, a shell append) ran as one submitted turn in session `629b3bc1-5dd7-4a0d-a901-69701850922c`, log `~/.local/share/muse/sessions/2026/08/06/629b3bc1-5dd7-4a0d-a901-69701850922c/session.jsonl`.
The whole 828-record turn is bracketed by exactly one run pair, 23 tool batches deep:

```
$ grep -cE '"kind":"run","run_id":"[^"]*","event":\{"kind":"started"' session.jsonl
1
$ grep -cE '"kind":"run","run_id":"[^"]*","event":\{"kind":"terminal"' session.jsonl
1
$ grep -c '"payload_type":"tool_batch.effect.started"' session.jsonl
23

10  {"kind":"run","run_id":"db5869ed-...","event":{"kind":"started","prompt":"...launch-brief..."
827 {"kind":"run","run_id":"db5869ed-...","event":{"kind":"terminal","terminal":"completed",
      "reason":null,"turn_duration_ms":75243,"time_to_first_token_ms":69583,"eot_gate_ms":3907}
```

Scope the count to `"kind":"run"` as above.
A bare `grep -c '"event":{"kind":"started"'` returns 56 on the same log, because every tool batch effect reuses that inner event shape.

### Busy sampling and interrupt

Session `e4e0b4f4-38d0-46dc-b669-dfb5de92e0e0` sampled the fold while a multi-step turn was in flight, then interrupted it with Escape mid tool loop.
Five consecutive samples of `fm_busy_muse_run_state` on the bound log returned `busy`, and `fm_busy_classify` returned `busy muse-session-log` for the same samples; the fold settled immediately after the interrupt.
Its run closed as cancelled rather than staying open:

```
10  {"kind":"run","run_id":"a098d532-...","event":{"kind":"started","prompt":"...launch-brief..."
103 {"kind":"run","run_id":"a098d532-...","event":{"kind":"terminal","terminal":"cancelled",
      "reason":"cancelled during model step","turn_duration_ms":7849}
```

That is the same terminal shape the `echo`-provider interrupt produced, now confirmed against a live model mid tool loop.

`tests/fm-muse-harness.test.sh` pins the resulting classifier behavior: a log settled by either terminal reads `idle`, an open run reads `busy`, and only a resolution failure reads `unknown`.

## Refreshing this record

Run both live guards after any muse upgrade, because the version-suffixed process name, session protocol, and styled composer are vendor-controlled surfaces:

```
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
bin/fm-test-run.sh tests/fm-muse-signals-live-e2e.test.sh
```

The Muse signals guard requires a real `muse` binary and tmux but uses `--provider echo`, so it does not require `META_API_KEY` and cannot re-check the real-model turn-to-run relationship on its own.
The guard runs by default wherever its tools are installed, while an absent tool reports a skip naming it; setting `FM_MUSE_SIGNALS_LIVE=1` forces the guard on and fails when a tool is absent.
The guard follows SGR state through the final prompt glyph in either the truecolor or the fixed-palette encoding and rejects dark, malformed, out-of-range, and theme-dependent negative controls before accepting that glyph's effective luminance.

muse's launcher can replace the running binary underneath the fleet, so an upgrade that changes the session protocol also invalidates the credentialed evidence above.
Repeat that smoke after a protocol-affecting upgrade: run one real multi-step tool-loop turn with credentials in place, confirm the run-scoped `started`/`terminal` counts are still exactly one each, and confirm an Escape still yields `terminal` with `cancelled`.
The 1.3 key reorder was such a change for the old prefix matcher, and the turn-to-run relationship itself was re-established on 1.3 as recorded under [the session protocol refresh](#session-protocol-refresh).
A build that ever split one turn across several runs would make a settled log ambiguous, which is a classifier change rather than a note in this file.

The portable counterparts that run in ordinary CI are `tests/fm-muse-harness.test.sh`, `tests/fm-tmux-agent-liveness.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-composer-ghost.test.sh`.
