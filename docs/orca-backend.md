# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while Orca owns the task worktree and terminal endpoint underneath that process.
Firstmate agents operating this backend should load the agent-only [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) checklist before recovering or supervising eligible legacy Orca-backed work, testing the adapter, debugging task state, or reconciling Orca metadata.

## Eligibility

Every new task is report-required, and `backend=orca` refuses it before any owned mutation under the legacy-recovery-only policy.
Only a pre-existing task whose metadata has no `report_required` marker is eligible to recover or continue operating on Orca; new work must use tmux, Herdr, zellij, or cmux.

## Setup

For an eligible legacy task, Orca is macOS-only, explicit-only (never auto-detected), and has no secondmate support.

Prerequisites:

- The Orca app installed at `/Applications/Orca.app`, and **running**.
- The `orca` CLI: `brew install orca`.
- `node`, used by firstmate's adapter to parse Orca's JSON output and to gate spawns on runtime readiness.
- The universal firstmate prerequisites - a verified crew harness plus the required toolchain, owned by [`docs/configuration.md`](configuration.md) ("Harness support", "Toolchain") - with `orca` as the only backend-specific tool, since Orca replaces both the session multiplexer CLI and the `treehouse` worktree provider that the other backends require.

Select Orca only for an eligible legacy recovery by passing `--backend orca` or exporting `FM_BACKEND=orca` for that recovery.
Do not make Orca the durable `config/backend` for a home that launches new work.
It is never auto-detected.

Before an eligible respawn mutates any repo or worktree state, firstmate runs `orca status --json` and requires the app to report `reachable=true` and `state="ready"` - start the Orca app and wait for it to finish loading before respawning.
Spawn fails closed if the runtime is not ready.
The first eligible respawn against a given project also auto-registers that project's repo in Orca (`orca repo add --path`) if it is not already registered - no manual registration step is needed.

Watching and attaching: Orca owns both the worktree and the terminal for its tasks, so there is nothing to attach to outside the Orca app itself - open the app and find the terminal for the task (recorded as `terminal=<handle>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: from an active firstmate session, `bin/fm-peek.sh <id>` reads a task's terminal without opening Orca, and `FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> "<text>"` steers it unless `FM_HOME` is already set to the active firstmate home (the stable `fm-<id>` alias also works; Enter and Ctrl-C are supported; Escape is not).

Do not manufacture pre-cutover metadata or spawn a trivial Orca task for an end-to-end check.
Use the focused fake-Orca suites below, or verify the recorded fields and terminal only while performing an actual eligible recovery.

Limitations: `--secondmate` spawns refuse `backend=orca` (secondmate-home semantics need a separate design), Escape is unsupported, Orca is macOS-only and explicit-only, and it exposes no stable CLI version marker, so spawn gates on runtime reachability instead of a version floor - see "Limitations" below for the complete list.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
This follow-up retains the full ship/scout task lifecycle for a task that meets the eligibility contract above: respawn, metadata, send/peek/watch/crew-state routing from metadata, and guarded teardown through Orca.

## Task Shape

An eligible legacy Orca task is one Orca-managed git worktree plus one Orca terminal.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; it also provides the task worktree, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

An eligible Orca respawn records the normal task fields plus these Orca-specific fields:

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute path to the Orca-created git worktree>
```

`window=` remains the shared firstmate alias used by selector-driven supervision tools after a task selector has resolved through metadata.
`fm-teardown.sh <id>` uses the same recorded fields after loading `state/<id>.meta`.
For Orca, `window=` keeps the stable firstmate alias while `terminal=` carries the stable Orca terminal handle that backend operations use.
The recorded `backend=orca` field tells shared call sites to route capture, send, interrupt, and close through `bin/backends/orca.sh` instead of tmux assumptions.

## Lifecycle

Eligible legacy respawn:

1. Ensure the project repo is registered in Orca, adding it with `orca repo add --path` when needed.
2. Create an independent Orca worktree with `orca worktree create --repo id:<repo> --name fm-<id> --no-parent --setup skip`.
3. Reuse the terminal returned by Orca worktree creation only when it appears in the verified `result.terminal.handle` shape, or create a titled terminal in that worktree when Orca returns only the worktree.
4. Install firstmate's per-harness turn-end hooks in the Orca worktree.
5. Write metadata, then send `GOTMPDIR` export and the selected harness launch through the recorded Orca terminal.

Operation routing:

- `fm-peek.sh` captures with `orca terminal read`.
- `fm-send.sh` types text with `orca terminal send --text ...`, submits with Enter, and verifies the composer row cleared before returning; when Orca reports a limited page, the verifier follows `oldestCursor` and preserves the current tail so older text cannot hide still-pending composer input.
  A slash-command popup that closes by filling an argument-hint placeholder still reads as pending, so the retry loop sends the required second Enter rather than treating the first Enter as a submission.
  The bordered row is classified through the shared composer classifier; a bare shell prompt has no genuine composer row and reads `unknown`, not confirmed empty.
- `fm-send.sh --key Enter` and `--key C-c` are supported.
- `fm-watch.sh` treats Orca as a pull backend with no native busy-state primitive, so it falls back to the same terminal-tail busy regex used for tmux, zellij, and cmux.
- `fm-crew-state.sh` reads the recorded Orca terminal when no no-mistakes run-step applies.

Teardown:

- Eligible legacy scout teardown still requires `data/<id>/report.md` unless `--force` explicitly discards it; it does not automatically publish that pre-cutover report to the machine-global stack.
- [report-stack.md](report-stack.md) owns the explicit legacy archival path.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown resolves `orca_worktree_id` back through Orca and verifies it matches the inspected `worktree=` path before removing anything; mismatches or uninspectable paths preserve metadata and fail closed.
- After the existing firstmate safety checks pass, teardown closes the recorded Orca terminal and requires a `terminal_handle_stale` read result before removal.
- The final project/worktree identity and landed-work checks, provider removal, and post-removal branch cleanup run under the common checkout lock.
- Missing terminal identity, a live terminal, an ambiguous read result, or a close failure retains the worktree and metadata.
- Teardown does not raw-delete Orca worktrees.

## Limitations

- `--secondmate` spawns still refuse `backend=orca`; secondmate-home semantics need a separate design.
- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca currently exposes no stable CLI version or protocol marker. Unlike the herdr/zellij/cmux docs, this backend intentionally gates spawn support on runtime reachability from `orca status --json` rather than a version floor.

## Verification

Real-Orca smoke verification was run against `/usr/local/bin/orca` with `/Applications/Orca.app` reporting bundle version `1.4.116`; `orca status --json` reported `result.runtime.reachable=true` and `result.runtime.state="ready"`.
The verified terminal creation handle field is `result.terminal.handle` from `orca terminal create --json`; worktree creation returned `result.worktree.id` and `result.worktree.path` in the same smoke run.
Firstmate intentionally ignores speculative terminal-handle shapes such as bare `result.id` and nested `result.worktree.terminal` until a real Orca smoke run proves them.

Fake-Orca tests cover:

- helper parsing for repo registration, worktree creation, verified implicit-terminal reuse, terminal creation, terminal sends, and worktree removal;
- rejection of undocumented terminal-handle result shapes;
- runtime readiness gating through `orca status --json`;
- eligible legacy `fm-spawn.sh --backend orca` metadata creation and harness launch;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown releasing an Orca worktree through `orca worktree rm`;
- terminal-state classification for live reads, stale-handle absence on nonzero exit, and ambiguous failures;
- ship teardown failing closed when the recorded Orca worktree id is missing, cannot resolve to a path, or resolves to a different path than `worktree=`.

Run the focused suite with:

```sh
FM_TEST_FOCUSED=review-round-orca-quiescence tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
