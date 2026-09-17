# Hermes harness verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the Hermes primary-harness integration.
The supervision protocol (`docs/supervision-protocols/hermes.md`), the harness-adapters skill reference (`.agents/skills/harness-adapters/references/harness/hermes.md`), and the Hermes plugin (`~/.hermes/plugins/firstmate/`) own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, and delivery transcripts remain in private reports or PR evidence.

## Plugin load verification

Verified on 2026-09-17 on Linux 7.2.3 running hermes-agent (HERMES_CLI=1):

```
$ hermes plugins list | grep firstmate
│ firstmate            │ enabled     │ 0.1.0   │ Bridge firstmate    │ user    │
```

Plugin files at `~/.hermes/plugins/firstmate/`:

| File | Purpose |
|------|---------|
| `plugin.yaml` | Declares hooks: on_session_start, on_session_reset, pre_llm_call, pre_verify |
| `__init__.py` | Registers all 4 hooks via `ctx.register_hook()` |
| `hooks.py` | Implements session-start digest caching, injection, and turn-end guard |

## Harness detection

Firstmate's harness detection runs in two layers. Both must agree for `hermes` to be the verdict.

### Marker layer

Hermes Agent sets `HERMES_CLI=1` on its CLI and every tool subprocess (verified live). `bin/fm-harness.sh` line 148:

```sh
[ "${HERMES_CLI:-}" = "1" ] && { echo hermes; return; }
```

Tested: `HERMES_CLI=1 source bin/fm-harness.sh; harness_marker` → `hermes`.

### Ancestry layer

Hermes's binary name is `hermes` (verified live). `bin/fm-harness.sh` line 239 covers the ancestry path:

```sh
hermes) echo "comm hermes"; return ;;
```

This covers a direct binary invocation without the env wrapper.

## Backend adapter

`bin/backends/hermes.sh` implements the session-provider contract:

| Function | Verified | Behavior |
|----------|----------|----------|
| `fm_backend_hermes_agent_state` | ✓ | Returns `missing` for absent pidfile, `unreadable` for garbage, `alive`/`dead` by process table |
| `fm_backend_hermes_target_exists` | ✓ | Returns false for missing pidfile |
| `fm_backend_hermes_spawn` | syntax only | Launches `hermes chat -q "<brief>" --cwd <worktree>` as background process |
| `fm_backend_hermes_steer` | syntax only | Delegates to `bin/fm-send.sh` (inbox-only; no terminal injection) |

Smoke test results (2026-09-17):

```
fm_backend_hermes_agent_state "hermes:/tmp/nonexistent"  → missing
fm_backend_hermes_agent_state "not-a-valid-target"       → unreadable
fm_backend_hermes_target_exists "hermes:/tmp/nonexistent" → false (exit 1)
```

## Dispatch integration

| File | Line | Wiring |
|------|------|--------|
| `bin/fm-backend.sh` | 913 | `hermes) fm_backend_hermes_agent_state "$target" ;;` |
| `bin/fm-spawn.sh` | 3204 | `hermes) fm_backend_hermes_steer "$1" "$2" ;;` |
| `bin/fm-spawn.sh` | 3213 | `hermes) ;;` (no-op for current_path — one-shot workers) |

## Known gaps (v1)

Documented in `docs/supervision-protocols/hermes.md`:

1. No hard turn-end block — only bounded continuation via `pre_verify` (max ~3 nudges)
2. No instruction refresh on `/compact` — CLI-side session-start hook does not fire on compact
3. Background watcher is process-local — does not survive gateway restart
4. No semantic busy-state events — worker state inferred from process presence + `state/<id>.progress`
