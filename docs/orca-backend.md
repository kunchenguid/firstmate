# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while Orca owns the task worktree and terminal endpoint underneath that process.
Firstmate agents operating this backend should load the agent-only [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) checklist before recovering or supervising eligible legacy Orca-backed work, testing the adapter, debugging task state, or reconciling Orca metadata.

## Eligibility

Every new task is report-required, and `backend=orca` refuses it before any owned mutation under the legacy-recovery-only policy.
Pre-existing Orca metadata can still be inspected and supervised through non-destructive helpers, but respawn and destructive teardown currently fail closed because the verified CLI evidence does not establish task/worktree/terminal binding or a complete worktree terminal inventory.
New work and legacy respawn must use tmux, Herdr, zellij, or cmux until that capability is empirically verified and the adapter gate is deliberately enabled.

## Setup

For an existing legacy task, Orca is macOS-only, explicit-only (never auto-detected), and has no secondmate support.

Prerequisites:

- The Orca app installed at `/Applications/Orca.app`, and **running**.
- The `orca` CLI: `brew install orca`.
- `node`, used by firstmate's adapter to parse Orca's JSON output and to gate spawns on runtime readiness.
- The universal firstmate prerequisites - a verified crew harness plus the required toolchain, owned by [`docs/configuration.md`](configuration.md) ("Harness support", "Toolchain") - with `orca` as the only backend-specific tool, since Orca replaces both the session multiplexer CLI and the `treehouse` worktree provider that the other backends require.

Existing legacy Orca metadata is inspection- and supervision-only until lifecycle authority is empirically verified.
Do not pass `--backend orca` or export `FM_BACKEND=orca` to respawn it; use tmux, Herdr, zellij, or cmux for any replacement generation.
Do not make Orca the durable `config/backend` for a home that launches new work.
It is never auto-detected.

Before any future eligible respawn may mutate repo or worktree state, firstmate requires both a ready runtime and the lifecycle-authority capability.
The authority gate currently fails closed before repo registration, worktree creation, or terminal creation.

Watching and attaching: Orca owns both the worktree and the terminal for its tasks, so there is nothing to attach to outside the Orca app itself - open the app and find the terminal for the task (recorded as `terminal=<handle>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: from an active firstmate session, `bin/fm-peek.sh <id>` reads a task's terminal without opening Orca, and `FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> "<text>"` steers it unless `FM_HOME` is already set to the active firstmate home (the stable `fm-<id>` alias also works; Enter and Ctrl-C are supported; Escape is not).

Do not manufacture pre-cutover metadata or spawn a trivial Orca task for an end-to-end check.
Use the focused fake-Orca suites below, or verify the recorded fields and terminal only while performing an actual eligible recovery.

Limitations: lifecycle spawn and destructive teardown are disabled pending verified authority support, `--secondmate` spawns refuse `backend=orca`, Escape is unsupported, Orca is macOS-only and explicit-only, and it exposes no stable CLI version marker.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
The verified evidence supports those terminal primitives plus create `id/path`; it does not support the stronger identity and inventory claims needed for safe lifecycle mutation.

## Task Shape

An eligible legacy Orca task is one Orca-managed git worktree plus one Orca terminal.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; it also provides the task worktree, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

The disabled Orca respawn design would record the normal task fields plus these Orca-specific fields:

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
The guarded implementation pre-arms discovery metadata before provider creation and retains every returned identity with `orca_cleanup_pending=1` if rollback cannot prove absence.
Production creation is disabled until provider-supported discovery and complete terminal inventory make that quarantine recoverable without guessing.

## Lifecycle

The disabled legacy respawn design is:

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

The guarded teardown design, exercised only in the synthetic authority lab, is:

- Eligible legacy scout teardown still requires `data/<id>/report.md`; `--force` does not bypass the report.
- [report-stack.md](report-stack.md) owns the explicit legacy archival path.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown resolves `orca_worktree_id` back through Orca and verifies it matches the inspected `worktree=` path before removing anything; mismatches or uninspectable paths preserve metadata and fail closed.
- Before close, teardown requires Orca's authoritative terminal read to bind the recorded terminal to the recorded worktree id; missing or mismatched identity preserves every resource.
- After the existing firstmate safety checks pass, teardown closes the recorded Orca terminal and requires a `terminal_handle_stale` read result before removal.
- The final project/worktree identity and landed-work checks, provider removal, and post-removal branch cleanup run under the common checkout lock.
- Provider removal also requires a fresh fail-closed filesystem-boundary proof for the exact recorded worktree root; mounted, redirected, missing, or identity-drifted paths remain quarantined.
- Missing terminal identity, a live terminal, an ambiguous read result, or a close failure retains the worktree and metadata.
- A spawn-abort quarantine without a recorded terminal can proceed only when Orca explicitly reports that the retained worktree has no terminals.
- Teardown does not raw-delete Orca worktrees.
- Until the lifecycle-authority capability is empirically verified, teardown retains all Orca resources before endpoint close or worktree removal.

## Limitations

- `--secondmate` spawns still refuse `backend=orca`; secondmate-home semantics need a separate design.
- Respawn and destructive teardown are disabled because the current verified CLI evidence cannot bind the task label, terminal, worktree, and repository or enumerate every attached terminal.
- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca currently exposes no stable CLI version or protocol marker. Unlike the herdr/zellij/cmux docs, this backend intentionally gates spawn support on runtime reachability from `orca status --json` rather than a version floor.

## Verification

Real-Orca smoke verification was run against `/usr/local/bin/orca` with `/Applications/Orca.app` reporting bundle version `1.4.116`; `orca status --json` reported `result.runtime.reachable=true` and `result.runtime.state="ready"`.
The verified terminal creation handle field is `result.terminal.handle` from `orca terminal create --json`; worktree creation returned `result.worktree.id` and `result.worktree.path` in the same smoke run.
No recorded command/output establishes `worktree.name`, a complete `worktree.terminals` inventory, or an authoritative query binding a terminal to a task label, worktree, and repository.
The adapter therefore does not claim those fields in production and fails lifecycle capability validation before creation or destructive cleanup.
Firstmate intentionally ignores speculative terminal-handle shapes such as bare `result.id` and nested `result.worktree.terminal` until a real Orca smoke run proves them.

The fake-Orca authority lab is synthetic regression scaffolding, not provider evidence. It covers:

- helper parsing for repo registration, worktree creation, verified implicit-terminal reuse, terminal creation, terminal sends, and worktree removal;
- rejection of undocumented terminal-handle result shapes;
- retention and cleanup of pathless or malformed-create quarantines, including spawn retry refusal while cleanup remains pending;
- runtime readiness gating through `orca status --json`;
- synthetic legacy `fm-spawn.sh --backend orca` metadata creation and harness launch inside the authority lab;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown releasing an Orca worktree through `orca worktree rm`;
- terminal-state classification for live reads, stale-handle absence on nonzero exit, ambiguous failures, and terminal/worktree identity drift;
- ship teardown failing closed when the recorded Orca worktree id is missing, cannot resolve to a path, or resolves to a different path than `worktree=`.

Run the focused suite with:

```sh
FM_TEST_FOCUSED=review-round-orca-authority tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
