# Mistral Vibe worker verification

Audience: maintainer verification.

Verified 2026-10-26 on macOS arm64 with `vibe 3.0.2`, its bundled `vibe-rs` TUI, and Mistral-hosted `zai-glm-5-3-flash`.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/vibe.md) owns operating guidance and supported limits.

## Refresh

Commands run from the repository root:

```sh
vibe --version
vibe --help
bash tests/fm-vibe-harness.test.sh
FM_VIBE_SIGNALS_LIVE=1 bash tests/fm-vibe-signals-live-e2e.test.sh
```

Exact live result:

```text
ok - vibe 3.0.2: real spawn, ancestry, busy/idle, draft, steer, interrupt, exit and replacement reply (model zai-glm-5-3-flash; effort unsupported)
```

The guard spends model tokens and uses `fm_live_gate` opt-in policy.
It captures the real spawn command with fixture allocation into an independent fixture repository, then runs the actual command and Firstmate steering/control paths on a private tmux server.
It retains the authenticated user's home because the OS credential lookup and account-keyed model cache otherwise disappear; Firstmate state, repositories, and tmux sockets remain private.
It verifies a new journal generation after replacement and preserves a pending composer draft until explicitly cleared by the test.

The same captured real launch was exercised in a generated non-default Herdr lab through `bin/fm-herdr-lab.sh`, including a brief running `fm-harness.sh`, a unique inbox reply and acknowledgement, interrupt with the process alive, exit to a foreground shell, and a replacement reply followed by exit.
Every Herdr operation used the guarded helper and its teardown tripwire passed.

## Native facts

`vibe --help` reports initial positional prompts, `--trust` (invocation only), `--auto-approve` (alias `--yolo`), `--continue`, `--resume`, and `--add-dir`.
It has no model or effort command-line flag.
`VIBE_ACTIVE_MODEL=zai-glm-5-3-flash` selected GLM Flash in the real TUI.
The installed account configuration listed `zai-glm-5-3` (alias `glm-5-3`) and `zai-glm-5-3-flash`, both with provider `mistral`.
Only allowlisted model/provider fields and credential-presence booleans were inspected.

The installed config's unknown model pin resets to its default, and a non-admin allowed-model filter matching nothing allows all models.
The adapter therefore validates effective configuration with the packaged Python loader before passing a model pin, and uses the resolved native name for the allowed-model filter.
Direct validation returned `zai-glm-5-3-flash`; an unknown model returned:

```text
error: Vibe model pin could not be verified with its installed Python config loader; refusing fallback
```

Sparse reasoning-model environment overrides did not apply in two real trials, and the installed environment layer ignored the unparseable override.
Effort pinning is unsupported and explicit non-default requests refuse.
The configured GLM reasoning default remained high; no effort-selection guarantee is claimed.

## Signals

The exact foreground name is `vibe-rs`; an unrelated `vibe-rs-helper` is not an agent.
Herdr's native agent catalog did not recognize Vibe, so endpoints recorded as Vibe use the shared pane-process classifier for liveness; a failed or foreign process read is unknown.
An empty foreground list uses the same descendant-process proof as a shell foreground, while unregistered endpoints recorded as another runtime keep Herdr's original catalog behavior.
The composer is a ruled `>` region below the approval label and above a cwd footer containing `[PID ...]` and token usage.
The busy hint `Generating… (Ns Esc/Ctrl+C to interrupt)` is delivery evidence only, matched only for endpoints recorded as Vibe.

Semantic state comes from the task's launch-generation journal directory and a unique session whose origin directory matches the worker.
The checkpoint alone can remain at `latestTurn: null` while a turn runs.
Committed journal `set_envelope` deltas supply `latestTurn.status=in_progress` while busy and `completed` after the reply.
Malformed, missing, ambiguous, or partial data returns unknown rather than idle.

## Unverified boundaries

One Escape was delivered and the agent remained alive; the adapter reports cancellation unconfirmed.
Native session resume, slash-skill invocation, primary supervision, secondmate operation, and other terminal backends are not verified.
No Firstmate turn-ended hook is installed.
The adapter refuses versions other than 3.0.2 until live evidence is refreshed.
