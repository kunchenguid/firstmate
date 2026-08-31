# Lean Firstmate Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow Firstmate to Ross' local coordination workflow by removing Relay, remote secondmates, non-tmux runtime backends, and no-mistakes authority while preserving local tmux workers, local secondmates, durable state, watcher supervision, and explicit approval gates.

**Architecture:** This is a subtractive plan executed from `rharriso-main`, which Ross is treating as the temporary trunk for a fork. Remove unsupported surfaces one capability at a time, keeping the tmux path as the only session-provider path and keeping local secondmate semantics intact. Watcher, wake queue, pending decision, and local secondmate lifecycle behavior stay structurally unchanged except for deleting branches that only served removed features.

**Tech Stack:** Bash scripts under `bin/`, tmux, treehouse worktrees, Markdown docs, shell-based tests under `tests/`, GitHub Actions.

**Spec:** `/Users/ross.harrison/Desktop/zettelkasten/2026-08-31-lean-firstmate/design.md`

## Global Constraints

- Work on `rharriso-main` as the fork trunk for this effort.
- Do not add support for any backend other than tmux.
- Do not preserve remote secondmates.
- Do not preserve Relay.
- Do not rely on no-mistakes as authorization, merge authority, or a required dependency.
- Do not redesign secondmates, watcher supervision, wake queue, pending decisions, or the CLI architecture in this milestone.
- Sensitive actions require explicit Ross direction: spawn work, push a branch, create a PR, merge, apply local changes to a primary checkout, discard or delete work, use credentials, and spend money.
- Validation output may support a recommendation, but validation success must not authorize push, PR creation, merge, local apply, or discard.
- Preserve local secondmates on tmux and prove they still work.
- Preserve local tmux watcher supervision and prove it still works.
- Track baseline context before removals and compare it against the final lean branch.
- Put one full sentence per physical line in tracked Markdown.
- Use plain dash characters, not em dashes.

---

## File Structure

- `AGENTS.md`: Update the operational contract to describe local-only tmux coordination, local secondmates, explicit approval gates, and the removed feature boundary.
- `README.md`: Update product positioning, setup, feature list, diagrams, and documentation links to match the lean fork.
- `CONTRIBUTING.md`: Remove no-mistakes submission requirements and backend compatibility lanes that no longer apply.
- `docs/configuration.md`: Make tmux the only runtime configuration path, remove Relay configuration, remove remote secondmate schema, and remove no-mistakes gate defaults.
- `docs/architecture.md`: Remove architecture sections for non-tmux backends, remote secondmates, Relay, and no-mistakes gate authority, while retaining watcher and local secondmate architecture.
- `docs/scripts.md`: Remove script entries for deleted Relay and remote-only scripts, and update backend wording.
- `docs/documentation-audiences.json`: Remove documentation inventory entries for deleted docs and workflows.
- `docs/documentation-audiences.md`: Keep audience definitions, but update examples only if they mention removed surfaces.
- `docs/tmux-backend.md`: Reframe tmux as the only supported backend instead of the default among several.
- `.github/workflows/ci.yml`: Remove Herdr and non-tmux backend lanes, then keep portable shell tests for lean behavior.
- `.github/workflows/no-mistakes-required.yml`: Delete this workflow.
- `.github/workflows/windows-herdr-spike.yml`: Delete this workflow.
- `bin/fm-backend.sh`: Collapse backend selection to tmux only while preserving helper APIs consumed by other scripts.
- `bin/backends/tmux.sh`: Keep as the only backend adapter.
- `bin/backends/herdr.sh`, `bin/backends/zellij.sh`, `bin/backends/orca.sh`, `bin/backends/cmux.sh`, `bin/backends/herdr-eventwait.py`, `bin/backends/herdr-workspace-move.py`: Delete after tmux-only tests protect the remaining backend interface.
- `bin/fm-spawn.sh`: Remove `--backend` selection, backend auto-detection, Orca worktree handling, Herdr presentation handling, and remote traceparent launch path, while preserving ship, scout, and local secondmate spawns on tmux.
- `bin/fm-send.sh`, `bin/fm-peek.sh`, `bin/fm-crew-state.sh`, `bin/fm-control.sh`, `bin/fm-teardown.sh`, `bin/fm-watch.sh`, `bin/fm-watch-checkpoint.sh`, `bin/fm-supervision-lib.sh`: Remove non-tmux, Relay, and remote-secondmate branches only where direct dependencies remain.
- `bin/fm-bootstrap.sh` and `bin/fm-startup-network.sh`: Remove no-mistakes dependency checks, Relay artifact writes, remote secondmate network sweeps, remote handoff retry, backend validation beyond tmux, and Herdr stale-projection cleanup.
- `bin/fm-home-seed.sh`, `bin/fm-secondmate-registry-lib.sh`, `bin/fm-secondmate-parent-lib.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-backlog-receive.sh`, `bin/fm-config-push.sh`, `bin/fm-update.sh`: Preserve local secondmates and remove remote route handling.
- `bin/fm-on.sh`, `bin/fm-remote-*.sh`, `bin/fm-procevent-remote-reply.sh`: Delete after local secondmate tests prove no remaining local dependency.
- `bin/fm-x-*.sh`, `bin/fm-public-followup*.sh`: Delete after watcher and PR-check tests no longer expect Relay.
- `bin/fm-gate-refuse-lib.sh` and `bin/fm-nm-run-lib.sh`: Delete or reduce to no-op only if no local safety contract still consumes them.
- `tests/`: Delete or rewrite removed-scope tests and keep focused coverage for tmux dispatch, watcher wake handling, local secondmates, durable state, pending decisions, and explicit approval gates.

---

### Task 1: Baseline Inventory and Test Map

**Files:**
- Create: `docs/superpowers/plans/lean-firstmate-baseline-notes.md`
- Modify: none
- Test: none

**Interfaces:**
- Consumes: Current `rharriso-main` checkout and the spec named above.
- Produces: A short baseline note used by later tasks to avoid deleting local-tmux or local-secondmate dependencies by mistake, plus context-size metrics for final comparison.

- [ ] **Step 1: Record current branch and cleanliness**

Run:

```bash
git branch --show-current
git status --short
```

Expected: branch is `rharriso-main`.
If status is dirty before any task edits, record the dirty files in the baseline note and do not overwrite them.

- [ ] **Step 2: Capture removed-scope file inventory**

Run:

```bash
rg -n "Relay|X mode|x-mode|fm-x|public-followup|Discord|mention|herdr|zellij|orca|cmux|codex-app|FM_BACKEND|config/backend|remote secondmate|remote-secondmate|fm-remote|no-mistakes" AGENTS.md README.md CONTRIBUTING.md docs bin tests .github .tasks.toml > docs/superpowers/plans/lean-firstmate-baseline-notes.md
```

Expected: the note lists all known removed-scope references.
This command intentionally over-selects.

- [ ] **Step 3: Capture baseline context metrics**

Append this section to `docs/superpowers/plans/lean-firstmate-baseline-notes.md`:

```markdown

## Baseline Context Metrics

```

Then run:

```bash
{
  printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Branch: %s\n' "$(git branch --show-current)"
  printf '\nTracked instruction surfaces:\n'
  for path in AGENTS.md README.md CONTRIBUTING.md docs/configuration.md docs/architecture.md docs/scripts.md docs/tmux-backend.md; do
    [ -f "$path" ] || continue
    bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ')
    lines=$(LC_ALL=C wc -l < "$path" | tr -d ' ')
    tokens=$(( (bytes + 3) / 4 ))
    printf '%s\tbytes=%s\tlines=%s\test_tokens=%s\n' "$path" "$bytes" "$lines" "$tokens"
  done
  printf '\nAgent skill surfaces:\n'
  find .agents/skills -name SKILL.md -type f -print | LC_ALL=C sort | while IFS= read -r path; do
    bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ')
    lines=$(LC_ALL=C wc -l < "$path" | tr -d ' ')
    tokens=$(( (bytes + 3) / 4 ))
    printf '%s\tbytes=%s\tlines=%s\test_tokens=%s\n' "$path" "$bytes" "$lines" "$tokens"
  done
} >> docs/superpowers/plans/lean-firstmate-baseline-notes.md
```

Expected: the note contains per-file bytes, lines, and approximate token counts.
Use the explicit approximation `ceil(bytes / 4)` so the final comparison is stable and reproducible without model-specific tokenizers.

- [ ] **Step 4: Capture representative session-start digest size**

Run the digest in a throwaway home, never in Ross' real active home:

```bash
tmp=$(mktemp -d /private/tmp/fm-context-baseline.XXXXXX)
FM_HOME="$tmp" FM_ROOT_OVERRIDE="$PWD" bin/fm-session-start.sh > "$tmp/session-start.out"
bytes=$(LC_ALL=C wc -c < "$tmp/session-start.out" | tr -d ' ')
lines=$(LC_ALL=C wc -l < "$tmp/session-start.out" | tr -d ' ')
tokens=$(( (bytes + 3) / 4 ))
{
  printf '\nRepresentative session-start digest:\n'
  printf 'bytes=%s\tlines=%s\test_tokens=%s\n' "$bytes" "$lines" "$tokens"
} >> docs/superpowers/plans/lean-firstmate-baseline-notes.md
```

Expected: the note records digest bytes, lines, and approximate token count.
If this command reports external-tool or GitHub diagnostics, keep the output file in the throwaway home and record only the size metrics plus the first diagnostic line in the baseline note.

- [ ] **Step 5: List tests that must survive**

Append this section to `docs/superpowers/plans/lean-firstmate-baseline-notes.md`:

```markdown

## Must-Survive Coverage

- tmux dispatch and endpoint state: `tests/fm-backend-tmux-smoke.test.sh`, `tests/fm-tmux-agent-liveness.test.sh`, `tests/fm-tmux-submit-busy.test.sh`, and the tmux portions of `tests/fm-backend.test.sh`.
- Local worker lifecycle: `tests/fm-spawn-worktree-settle.test.sh`, `tests/fm-spawn-batch.test.sh`, `tests/fm-control.test.sh`, `tests/fm-control-relaunch.test.sh`, and `tests/fm-teardown.test.sh`.
- Local secondmates: `tests/fm-secondmate-lifecycle-e2e.test.sh`, `tests/fm-secondmate-liveness.test.sh`, `tests/fm-secondmate-safety.test.sh`, `tests/fm-secondmate-sync.test.sh`, `tests/fm-secondmate-harness.test.sh`, `tests/fm-backlog-handoff.test.sh`, `tests/fm-shared-captain-inheritance.test.sh`, and `tests/fm-send-secondmate-marker.test.sh`.
- Watcher and decisions: `tests/fm-watch-arm.test.sh`, `tests/fm-watch-checkpoint.test.sh`, `tests/fm-wake-drain-open-decisions.test.sh`, `tests/fm-wake-drain-unread-status.test.sh`, `tests/fm-wake-queue.test.sh`, `tests/fm-pending-reply.test.sh`, and `tests/fm-decision-hold-lifecycle.test.sh`.
- Approval gates: add new coverage in this plan for validation-not-authority behavior.
```

- [ ] **Step 6: Run a narrow unchanged baseline**

Run:

```bash
bin/fm-test-run.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-lifecycle-e2e.test.sh tests/fm-watch-checkpoint.test.sh tests/fm-wake-drain-open-decisions.test.sh
```

Expected: pass, or record exact failures before continuing.
Do not fix unrelated failures in this task unless they block understanding the baseline.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/plans/lean-firstmate-baseline-notes.md
git commit -m "docs: record lean firstmate baseline inventory"
```

### Task 2: Make Docs and Configuration State the Lean Product

**Files:**
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Modify: `docs/configuration.md`
- Modify: `docs/architecture.md`
- Modify: `docs/scripts.md`
- Modify: `docs/tmux-backend.md`
- Modify: `docs/documentation-audiences.json`
- Delete: `docs/herdr-backend.md`
- Delete: `docs/zellij-backend.md`
- Delete: `docs/orca-backend.md`
- Delete: `docs/cmux-backend.md`
- Delete: `docs/codex-app-backend.md`
- Delete: `docs/remote-secondmates.md`
- Test: `tests/fm-documentation-audiences.test.sh`

**Interfaces:**
- Consumes: The baseline inventory and current docs.
- Produces: A documentation contract that no longer advertises removed capabilities.

- [ ] **Step 1: Remove removed feature docs**

Run:

```bash
git rm docs/herdr-backend.md docs/zellij-backend.md docs/orca-backend.md docs/cmux-backend.md docs/codex-app-backend.md docs/remote-secondmates.md
```

Expected: files are staged for deletion.

- [ ] **Step 2: Update `docs/documentation-audiences.json`**

Remove entries whose `path` is one of the deleted docs.
Keep all remaining JSON valid and do not add a new audience category.

- [ ] **Step 3: Rewrite product-facing docs**

Edit `README.md` so it says:

```markdown
- Firstmate is a local coordinator for Ross' project work.
- tmux is the only supported runtime backend.
- Local secondmates are supported.
- Remote secondmates, Relay, and non-tmux backends are intentionally out of scope for this fork.
- Validation evidence supports recommendations but does not authorize sensitive actions.
```

Remove feature bullets, setup paragraphs, diagrams, and documentation links that mention Relay, X or Discord mentions, Herdr, Zellij, Orca, cmux, Codex App backend support, remote secondmates, or no-mistakes project modes.

- [ ] **Step 4: Rewrite contributor docs**

Edit `CONTRIBUTING.md` so it says normal branches and PRs are allowed for this fork, and remove the requirement that human-authored PRs target `main` through no-mistakes.
Keep the existing lint and test command references that remain true.

- [ ] **Step 5: Rewrite operator instructions**

Edit `AGENTS.md` to:

```markdown
- Treat `rharriso-main` as the temporary fork trunk until Ross changes it.
- Describe `config/backend` as removed or ignored.
- Describe tmux as the only runtime backend.
- Describe `data/secondmates.md` as local-only.
- Remove the Relay section.
- Remove no-mistakes as delivery authority.
- Keep explicit captain approval gates for sensitive actions.
```

Do not expand `AGENTS.md` with long replacement procedures.
If a procedure remains situational, keep the existing skill pointer or create a later task to update that skill.

- [ ] **Step 6: Rewrite architecture and configuration docs**

Edit `docs/configuration.md`, `docs/architecture.md`, `docs/scripts.md`, and `docs/tmux-backend.md` to remove support claims for deleted capabilities.
Keep current local tmux state formats, local secondmate registry formats, wake queue behavior, process-event behavior, and task lifecycle behavior.

- [ ] **Step 7: Run documentation verification**

Run:

```bash
bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh
bin/fm-doc-audience-check.sh
```

Expected: both pass.

- [ ] **Step 8: Commit**

```bash
git add AGENTS.md README.md CONTRIBUTING.md docs
git commit -m "docs: define lean local firstmate surface"
```

### Task 3: Collapse Runtime Backend Selection to tmux

**Files:**
- Modify: `bin/fm-backend.sh`
- Modify: `bin/fm-spawn.sh`
- Modify: `bin/fm-send.sh`
- Modify: `bin/fm-peek.sh`
- Modify: `bin/fm-crew-state.sh`
- Modify: `bin/fm-control.sh`
- Modify: `bin/fm-teardown.sh`
- Modify: `bin/fm-watch.sh`
- Modify: `bin/fm-watch-checkpoint.sh`
- Modify: `bin/fm-supervision-lib.sh`
- Delete: `bin/backends/herdr.sh`
- Delete: `bin/backends/zellij.sh`
- Delete: `bin/backends/orca.sh`
- Delete: `bin/backends/cmux.sh`
- Delete: `bin/backends/herdr-eventwait.py`
- Delete: `bin/backends/herdr-workspace-move.py`
- Delete: `bin/fm-herdr-ci-cleanup.sh`
- Delete: `bin/fm-herdr-lab.sh`
- Delete: `bin/fm-herdr-session-cleanup.sh`
- Delete: `bin/fm-install-herdr.sh`
- Test: `tests/fm-backend.test.sh`
- Test: `tests/fm-backend-tmux-smoke.test.sh`
- Test: `tests/fm-tmux-agent-liveness.test.sh`
- Test: `tests/fm-tmux-submit-busy.test.sh`
- Delete or rewrite: all `tests/fm-backend-herdr*`, `tests/fm-backend-zellij*`, `tests/fm-backend-orca*`, `tests/fm-backend-cmux*`, `tests/fm-control-herdr-smoke.test.sh`, `tests/fm-herdr-*`, `tests/herdr-test-safety.sh`, `tests/zellij-test-safety.sh`, and `tests/cmux-test-safety.sh`

**Interfaces:**
- Consumes: Existing backend helper function names.
- Produces: A tmux-only backend interface that existing callers can still source.

- [ ] **Step 1: Write the failing tmux-only backend tests**

In `tests/fm-backend.test.sh`, replace multi-backend selection assertions with these cases:

```bash
test_backend_name_is_always_tmux() {
  local cfg out
  cfg=$(mktemp -d "$TMP_ROOT/backend-config.XXXXXX")
  mkdir -p "$cfg"
  printf 'herdr\n' > "$cfg/backend"
  out=$(FM_BACKEND=herdr FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)
  [ "$out" = tmux ] || fail "backend must stay tmux even when legacy config/env names another backend, got '$out'"
  pass "backend selection is tmux-only"
}

test_unknown_backend_flag_is_removed_from_spawn_help() {
  local help
  help=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_not_contains "$help" "--backend" "spawn help must not advertise backend selection"
  assert_not_contains "$help" "herdr" "spawn help must not advertise removed Herdr backend"
  assert_not_contains "$help" "orca" "spawn help must not advertise removed Orca backend"
  pass "spawn help no longer advertises backend selection"
}
```

Expected before implementation: failure because backend selection still honors legacy config/env and help still mentions removed backends.

- [ ] **Step 2: Simplify `bin/fm-backend.sh`**

Set:

```bash
FM_BACKEND_KNOWN="tmux"
FM_BACKEND_SPAWN="tmux"
```

Make `fm_backend_detect` print `tmux` only when `$TMUX` is present and otherwise return 1.
Make `fm_backend_name` return `tmux` unconditionally, ignoring `FM_BACKEND` and `config/backend`.
Keep `fm_backend_of_meta` treating absent or `backend=tmux` as tmux, and make any other `backend=` value invalid.
Keep public helper names intact so callers do not need a broad API rewrite in this task.

- [ ] **Step 3: Simplify `bin/fm-spawn.sh`**

Remove `--backend` from usage and argument parsing.
Refuse any remaining `--backend` flag with:

```text
error: --backend was removed; lean firstmate supports tmux only
```

Remove Orca worktree handling and Herdr presentation handling.
Always allocate task worktrees through the existing non-Orca treehouse path.
Always create tmux windows through `bin/backends/tmux.sh`.
Do not write `backend=tmux` to metadata unless existing callers already do so.

- [ ] **Step 4: Simplify backend consumers**

For `fm-send.sh`, `fm-peek.sh`, `fm-crew-state.sh`, `fm-control.sh`, `fm-teardown.sh`, `fm-watch.sh`, `fm-watch-checkpoint.sh`, and `fm-supervision-lib.sh`, remove branches for Herdr, Zellij, Orca, and cmux.
Keep calls through `fm_backend_*` helpers where that keeps the code smaller and stable.
If a task meta contains a removed backend, fail closed with a message naming the stale metadata file.

- [ ] **Step 5: Delete removed backend scripts and tests**

Run:

```bash
git rm bin/backends/herdr.sh bin/backends/zellij.sh bin/backends/orca.sh bin/backends/cmux.sh bin/backends/herdr-eventwait.py bin/backends/herdr-workspace-move.py
git rm bin/fm-herdr-ci-cleanup.sh bin/fm-herdr-lab.sh bin/fm-herdr-session-cleanup.sh bin/fm-install-herdr.sh
git rm tests/fm-backend-herdr*.test.sh tests/fm-backend-zellij*.test.sh tests/fm-backend-orca.test.sh tests/fm-backend-cmux*.test.sh tests/fm-control-herdr-smoke.test.sh tests/fm-herdr-*.test.sh tests/herdr-test-safety.sh tests/zellij-test-safety.sh tests/cmux-test-safety.sh
```

Expected: only removed-scope scripts and tests are deleted.
If a glob matches nothing, remove the explicit existing files from `git status --short`.

- [ ] **Step 6: Run tmux backend tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-tmux-agent-liveness.test.sh tests/fm-tmux-submit-busy.test.sh
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add bin tests
git commit -m "refactor: collapse runtime backend to tmux"
```

### Task 4: Remove Relay and Public Follow-Up

**Files:**
- Modify: `bin/fm-bootstrap.sh`
- Modify: `bin/fm-watch-arm.sh`
- Modify: `bin/fm-watch-checkpoint.sh`
- Modify: `bin/fm-wake-drain.sh`
- Modify: `bin/fm-pr-check.sh`
- Modify: `bin/fm-pr-check-migrate.sh`
- Modify: `bin/fm-pr-poll.sh`
- Modify: `bin/fm-teardown.sh`
- Modify: `bin/fm-supervision-lib.sh`
- Delete: `bin/fm-x-dismiss.sh`
- Delete: `bin/fm-x-followup.sh`
- Delete: `bin/fm-x-lib.sh`
- Delete: `bin/fm-x-link.sh`
- Delete: `bin/fm-x-poll.sh`
- Delete: `bin/fm-x-reply.sh`
- Delete: `bin/fm-public-followup.sh`
- Delete: `bin/fm-public-followup-emit.sh`
- Delete: `bin/fm-public-followup-lib.sh`
- Test: `tests/fm-watch-arm.test.sh`
- Test: `tests/fm-watch-checkpoint.test.sh`
- Test: `tests/fm-wake-queue.test.sh`
- Test: `tests/fm-pr-check-security.test.sh`
- Delete: `tests/fm-x-mode.test.sh`
- Delete: `tests/fm-public-followup.test.sh`

**Interfaces:**
- Consumes: Existing watcher and PR-check behavior.
- Produces: A watcher that handles local task, PR, and process-event wakes without Relay.

- [ ] **Step 1: Write failing Relay removal tests**

In `tests/fm-bootstrap.test.sh`, add:

```bash
test_bootstrap_ignores_legacy_relay_env() {
  local home out
  home=$(make_home "$TMP_ROOT/bootstrap-relay-removed")
  printf 'FMX_PAIRING_TOKEN=legacy\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "FMX:" "bootstrap must not report Relay setup"
  [ ! -e "$home/state/x-watch.check.sh" ] || fail "bootstrap created removed Relay poll shim"
  [ ! -e "$home/config/x-mode.env" ] || fail "bootstrap created removed Relay cadence"
  pass "bootstrap ignores legacy Relay env"
}
```

Expected before implementation: failure because bootstrap still arms Relay.

- [ ] **Step 2: Remove Relay bootstrap**

In `bin/fm-bootstrap.sh`, remove sourcing `fm-x-lib.sh`, `x_mode_setup`, `x_mode_supervision_repair`, and all `FMX:` output.
Leave `.env` as a generic local file if other code uses it, but do not read `FMX_PAIRING_TOKEN`.

- [ ] **Step 3: Remove Relay watcher integration**

Delete handling for `x-watch.check.sh`, `x-mention`, `x-mode-error`, `public-followup`, and Relay-linked terminal follow-ups from watcher, wake drain, supervision, and teardown scripts.
Keep authenticated PR checks and process-event checks.

- [ ] **Step 4: Remove Relay script files and tests**

Run:

```bash
git rm bin/fm-x-dismiss.sh bin/fm-x-followup.sh bin/fm-x-lib.sh bin/fm-x-link.sh bin/fm-x-poll.sh bin/fm-x-reply.sh
git rm bin/fm-public-followup.sh bin/fm-public-followup-emit.sh bin/fm-public-followup-lib.sh
git rm tests/fm-x-mode.test.sh tests/fm-public-followup.test.sh
```

- [ ] **Step 5: Update PR-check security tests**

In `tests/fm-pr-check-security.test.sh`, remove cases whose only assertion is preserving X mode or Relay public follow-up behavior.
Keep cases that prove legacy check migration never executes untrusted check files, validates PR poll identity, and preserves process-event trust boundaries.

- [ ] **Step 6: Run watcher and PR tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-watch-arm.test.sh tests/fm-watch-checkpoint.test.sh tests/fm-wake-queue.test.sh tests/fm-pr-check-security.test.sh
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add bin tests
git commit -m "refactor: remove Relay integration"
```

### Task 5: Remove Remote Secondmates

**Files:**
- Modify: `bin/fm-home-seed.sh`
- Modify: `bin/fm-secondmate-registry-lib.sh`
- Modify: `bin/fm-secondmate-parent-lib.sh`
- Modify: `bin/fm-backlog-handoff.sh`
- Modify: `bin/fm-backlog-receive.sh`
- Modify: `bin/fm-config-push.sh`
- Modify: `bin/fm-update.sh`
- Modify: `bin/fm-bootstrap.sh`
- Modify: `bin/fm-startup-network.sh`
- Modify: `bin/fm-peek.sh`
- Modify: `bin/fm-crew-state.sh`
- Modify: `bin/fm-send.sh`
- Delete: `bin/fm-on.sh`
- Delete: `bin/fm-remote-delta-read.sh`
- Delete: `bin/fm-remote-doctor.sh`
- Delete: `bin/fm-remote-entrypoint.sh`
- Delete: `bin/fm-remote-file.sh`
- Delete: `bin/fm-remote-home-provision.sh`
- Delete: `bin/fm-remote-home-seed.sh`
- Delete: `bin/fm-remote-inherit-push.sh`
- Delete: `bin/fm-remote-inherit.sh`
- Delete: `bin/fm-remote-job-lib.sh`
- Delete: `bin/fm-remote-job-reap-orphans.sh`
- Delete: `bin/fm-remote-job-worker.sh`
- Delete: `bin/fm-remote-readiness-lib.sh`
- Delete: `bin/fm-remote-secondmate-control.sh`
- Delete: `bin/fm-procevent-remote-reply.sh`
- Test: local secondmate tests listed below
- Delete: `tests/fm-remote-*.test.sh`
- Delete: `tests/fm-peek-remote.test.sh`
- Delete: `tests/remote-herdr-fixture.sh`

**Interfaces:**
- Consumes: Existing local secondmate registry and lifecycle.
- Produces: Local-only secondmate orchestration with no SSH route branch.

- [ ] **Step 1: Write failing local-only registry tests**

In `tests/fm-secondmate-safety.test.sh`, add:

```bash
test_remote_secondmate_registry_record_is_refused() {
  local home out rc
  home=$(make_home "$TMP_ROOT/remote-registry-refused")
  mkdir -p "$home/data"
  printf -- '- remote-demo (host: old-mac; root: /tmp/firstmate; home: /tmp/home) - old remote route\n' > "$home/data/secondmates.md"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "remote route registry record was accepted"
  assert_contains "$out" "remote secondmates were removed" "refusal should explain removed support"
  pass "remote secondmate registry records are refused"
}
```

Expected before implementation: failure if remote records are still accepted.

- [ ] **Step 2: Remove remote registry parsing**

In `bin/fm-secondmate-registry-lib.sh`, keep the local record format only.
If a line contains `host:` or `root:`, return a parse error that includes:

```text
remote secondmates were removed; create a local secondmate instead
```

- [ ] **Step 3: Remove remote seed and launch paths**

In `bin/fm-home-seed.sh`, remove remote provisioning language and keep only local home provisioning.
In `bin/fm-spawn.sh`, remove remote traceparent handoff and any launch paths that assume a parent route on another host.

- [ ] **Step 4: Remove remote handoff and reply transport**

In `bin/fm-backlog-handoff.sh`, `bin/fm-backlog-receive.sh`, `bin/fm-config-push.sh`, `bin/fm-update.sh`, `bin/fm-bootstrap.sh`, `bin/fm-startup-network.sh`, `bin/fm-peek.sh`, `bin/fm-crew-state.sh`, and `bin/fm-send.sh`, delete branches that shell through `fm-on.sh`, `fm-remote-*`, SSH, or remote reply process events.
Keep same-filesystem local secondmate behavior.

- [ ] **Step 5: Delete remote scripts and tests**

Run:

```bash
git rm bin/fm-on.sh bin/fm-remote-delta-read.sh bin/fm-remote-doctor.sh bin/fm-remote-entrypoint.sh bin/fm-remote-file.sh bin/fm-remote-home-provision.sh bin/fm-remote-home-seed.sh bin/fm-remote-inherit-push.sh bin/fm-remote-inherit.sh bin/fm-remote-job-lib.sh bin/fm-remote-job-reap-orphans.sh bin/fm-remote-job-worker.sh bin/fm-remote-readiness-lib.sh bin/fm-remote-secondmate-control.sh bin/fm-procevent-remote-reply.sh
git rm tests/fm-remote-*.test.sh tests/fm-peek-remote.test.sh tests/remote-herdr-fixture.sh
```

- [ ] **Step 6: Run local secondmate tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-secondmate-lifecycle-e2e.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-secondmate-safety.test.sh tests/fm-secondmate-sync.test.sh tests/fm-secondmate-harness.test.sh tests/fm-backlog-handoff.test.sh tests/fm-shared-captain-inheritance.test.sh tests/fm-send-secondmate-marker.test.sh
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add bin tests
git commit -m "refactor: remove remote secondmates"
```

### Task 6: Remove no-mistakes Authority and Required Dependency

**Files:**
- Modify: `bin/fm-bootstrap.sh`
- Modify: `bin/fm-brief.sh`
- Modify: `bin/fm-home-seed.sh`
- Modify: `bin/fm-project-mode.sh`
- Modify: `bin/fm-crew-state.sh`
- Modify: `bin/fm-teardown.sh`
- Modify: `bin/fm-pr-merge.sh`
- Modify: `bin/fm-promote.sh`
- Delete: `.github/workflows/no-mistakes-required.yml`
- Delete: `bin/fm-gate-refuse-lib.sh`
- Delete: `bin/fm-nm-run-lib.sh`
- Test: `tests/fm-bootstrap.test.sh`
- Test: `tests/fm-task-delivery.test.sh`
- Test: `tests/fm-pr-merge.test.sh`
- Test: `tests/fm-teardown.test.sh`
- Delete or rewrite: `tests/fm-gate-refuse.test.sh`

**Interfaces:**
- Consumes: Current project mode and validation behavior.
- Produces: Explicit action authority independent of validation tooling.

- [ ] **Step 1: Write failing bootstrap dependency test**

In `tests/fm-bootstrap.test.sh`, add:

```bash
test_bootstrap_does_not_require_no_mistakes() {
  local home fakebin out
  home=$(make_home "$TMP_ROOT/no-mistakes-not-required")
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  make_tool "$fakebin/node" "v20.0.0"
  make_tool "$fakebin/git" "git version 2.50.0"
  make_tool "$fakebin/gh" "gh version 2.0.0"
  make_tool "$fakebin/gh-axi" "gh-axi 1.0.0"
  make_tool "$fakebin/chrome-devtools-axi" "chrome-devtools-axi 1.0.0"
  make_tool "$fakebin/lavish-axi" "lavish-axi 1.0.0"
  make_tool "$fakebin/tasks-axi" "tasks-axi 1.0.0"
  make_tool "$fakebin/quota-axi" "quota-axi 1.0.0"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: no-mistakes" "bootstrap must not require no-mistakes"
  pass "bootstrap no longer requires no-mistakes"
}
```

Adapt helper names to the existing `fm-bootstrap.test.sh` fixture API.
Expected before implementation: failure because bootstrap still reports missing no-mistakes.

- [ ] **Step 2: Add explicit approval gate regression tests**

Create or extend `tests/fm-explicit-authority.test.sh` with cases that simulate successful validation evidence and assert it does not call push, PR creation, merge, local apply, or discard without an explicit command.
Use fake `git`, `gh-axi`, and validation commands that append to a log.
Assert the log contains validation commands only.

- [ ] **Step 3: Remove no-mistakes from bootstrap**

In `bin/fm-bootstrap.sh`, remove `no-mistakes` from `COMMON_TOOLS`, remove version floor checks, and remove install command reporting for it.
Keep `node`, `git`, `gh`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, and `quota-axi` checks if they still support the lean workflow.

- [ ] **Step 4: Remove no-mistakes delivery mode**

In `bin/fm-project-mode.sh`, remove `no-mistakes` and `no-mistakes-prod-only` as current modes.
Keep `direct-PR` and `local-only` if both remain useful to Ross.
If an existing registry contains `no-mistakes`, warn that it is a legacy mode and treat it as `direct-PR` only after explicit captain approval for that task.

- [ ] **Step 5: Remove no-mistakes run attribution**

In `bin/fm-crew-state.sh` and `bin/fm-teardown.sh`, remove `no-mistakes axi status`, run attribution, and abort behavior.
Current state should come from tmux endpoint state, status logs, PR checks, and explicit metadata.

- [ ] **Step 6: Remove gate refusal scripts and workflow**

Run:

```bash
git rm .github/workflows/no-mistakes-required.yml
git rm bin/fm-gate-refuse-lib.sh bin/fm-nm-run-lib.sh
git rm tests/fm-gate-refuse.test.sh
```

Remove sourcing of `fm-gate-refuse-lib.sh` from fleet lifecycle scripts.

- [ ] **Step 7: Run delivery and authority tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-task-delivery.test.sh tests/fm-pr-merge.test.sh tests/fm-teardown.test.sh tests/fm-explicit-authority.test.sh
```

Expected: pass.

- [ ] **Step 8: Commit**

```bash
git add .github bin tests
git commit -m "refactor: remove no-mistakes authority"
```

### Task 7: Prune CI and Test Runner Lanes

**Files:**
- Modify: `.github/workflows/ci.yml`
- Delete: `.github/workflows/windows-herdr-spike.yml`
- Modify: `bin/fm-test-run.sh`
- Modify: `docs/fm-test-portable-shards.md`
- Modify: `docs/verification/runtime-backends.md`
- Test: `tests/fm-test-run.test.sh`
- Test: `tests/fm-lint-workflows.test.sh`

**Interfaces:**
- Consumes: Deleted tests from Tasks 3 through 6.
- Produces: A CI suite that only covers lean local functionality.

- [ ] **Step 1: Remove non-tmux CI jobs**

Edit `.github/workflows/ci.yml` to delete Herdr install, real-Herdr lane, backend-specific optional lanes, and references to removed tests.
Keep lint, portable parallel shards, portable serial shards, and any macOS lane that still proves local tmux behavior.

- [ ] **Step 2: Delete Windows Herdr spike workflow**

Run:

```bash
git rm .github/workflows/windows-herdr-spike.yml
```

- [ ] **Step 3: Update `bin/fm-test-run.sh` families**

Remove `real-herdr-gated`, `cmux`, `zellij`, `orca`, and remote-only test family mappings.
Ensure `--list --all`, `--list-lanes`, `--check-coverage`, and portable lane selection include only files that still exist.

- [ ] **Step 4: Update verification docs**

Edit `docs/fm-test-portable-shards.md` and `docs/verification/runtime-backends.md` so they describe tmux-only verification.
Remove stale empirical claims for Herdr, Zellij, Orca, cmux, and Codex App backend boundaries.

- [ ] **Step 5: Run test-runner and workflow tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-test-run.test.sh tests/fm-lint-workflows.test.sh
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add .github bin docs tests
git commit -m "ci: prune removed backend and gate lanes"
```

### Task 8: Clean Cross-References and Stale Skills

**Files:**
- Modify: `.agents/skills/bootstrap-diagnostics/SKILL.md`
- Modify: `.agents/skills/firstmate-orca/SKILL.md` or delete if no longer referenced
- Modify: `.agents/skills/fmx-respond/SKILL.md` or delete if no longer referenced
- Modify: `.agents/skills/harness-adapters/SKILL.md`
- Modify: `.agents/skills/project-management/SKILL.md`
- Modify: `.agents/skills/secondmate-provisioning/SKILL.md`
- Modify: `.agents/skills/stuck-crewmate-recovery/SKILL.md`
- Modify: `.agents/skills/updatefirstmate/SKILL.md`
- Test: `tests/fm-documentation-audiences.test.sh`
- Test: `tests/fm-bootstrap.test.sh`
- Test: local secondmate and watcher tests

**Interfaces:**
- Consumes: New lean behavior from earlier tasks.
- Produces: Agent instructions that no longer load removed-scope skills or direct workers down deleted paths.

- [ ] **Step 1: Search for stale removed-scope references**

Run:

```bash
rg -n "Relay|X mode|x-mode|fm-x|public-followup|Discord|herdr|zellij|orca|cmux|codex-app|remote secondmate|remote-secondmate|fm-remote|no-mistakes|config/backend|FM_BACKEND" AGENTS.md README.md CONTRIBUTING.md docs bin tests .agents/skills .github .tasks.toml
```

Expected: results are either compatibility warnings for stale metadata or places to edit.

- [ ] **Step 2: Delete or reduce dead skills**

If `firstmate-orca` and `fmx-respond` have no remaining load trigger, delete their skill directories.
If a skill still applies to local tmux work, patch it instead of deleting it.

- [ ] **Step 3: Update retained skill instructions**

In retained skills, remove remote route, Relay, no-mistakes, and non-tmux backend procedures.
Keep local secondmate provisioning, local recovery, harness launch, and explicit captain approval rules.

- [ ] **Step 4: Re-run stale reference search**

Run:

```bash
rg -n "Relay|X mode|x-mode|fm-x|public-followup|Discord|herdr|zellij|orca|cmux|codex-app|remote secondmate|remote-secondmate|fm-remote|no-mistakes|config/backend|FM_BACKEND" AGENTS.md README.md CONTRIBUTING.md docs bin tests .agents/skills .github .tasks.toml
```

Expected: only intentional migration or stale-metadata refusal text remains.

- [ ] **Step 5: Run docs and local behavior tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh tests/fm-bootstrap.test.sh tests/fm-watch-checkpoint.test.sh tests/fm-secondmate-lifecycle-e2e.test.sh
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md docs .agents/skills bin tests
git commit -m "docs: remove stale removed-scope agent paths"
```

### Task 9: Final Lean Verification

**Files:**
- Modify: any file with final stale references found in this task
- Test: complete lean test set

**Interfaces:**
- Consumes: All previous tasks.
- Produces: Evidence that Milestone 1 is complete enough to use as Ross' lean fork.

- [ ] **Step 1: Run stale reference search**

Run:

```bash
rg -n "Relay|X mode|x-mode|fm-x|public-followup|Discord|herdr|zellij|orca|cmux|codex-app|remote secondmate|remote-secondmate|fm-remote|no-mistakes|config/backend|FM_BACKEND" AGENTS.md README.md CONTRIBUTING.md docs bin tests .agents/skills .github .tasks.toml
```

Expected: no support claims remain for removed features.
Intentional stale-metadata refusal messages are acceptable.

- [ ] **Step 2: Run lint**

Run:

```bash
bin/fm-lint.sh
```

Expected: pass.

- [ ] **Step 3: Run lean core tests**

Run:

```bash
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-tmux-agent-liveness.test.sh tests/fm-tmux-submit-busy.test.sh tests/fm-spawn-worktree-settle.test.sh tests/fm-control.test.sh tests/fm-control-relaunch.test.sh tests/fm-teardown.test.sh tests/fm-watch-arm.test.sh tests/fm-watch-checkpoint.test.sh tests/fm-wake-drain-open-decisions.test.sh tests/fm-wake-drain-unread-status.test.sh tests/fm-wake-queue.test.sh tests/fm-pending-reply.test.sh tests/fm-decision-hold-lifecycle.test.sh tests/fm-secondmate-lifecycle-e2e.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-secondmate-safety.test.sh tests/fm-secondmate-sync.test.sh tests/fm-secondmate-harness.test.sh tests/fm-backlog-handoff.test.sh tests/fm-shared-captain-inheritance.test.sh tests/fm-send-secondmate-marker.test.sh tests/fm-bootstrap.test.sh tests/fm-session-start.test.sh tests/fm-startup-network.test.sh tests/fm-test-run.test.sh tests/fm-lint-workflows.test.sh
```

Expected: pass.

- [ ] **Step 4: Run local tmux smoke**

Run:

```bash
bin/fm-test-run.sh tests/fm-backend-tmux-smoke.test.sh
```

Expected: pass and create no persistent task state in the real home.

- [ ] **Step 5: Review diff against spec**

Run:

```bash
git diff --stat origin/main...HEAD
git diff --name-status origin/main...HEAD
```

Confirm:

```markdown
- Startup instructions are materially smaller.
- Baseline context metrics show smaller static instruction surfaces and a smaller representative session-start digest.
- Non-tmux backend support is gone.
- Relay support is gone.
- Remote secondmate support is gone.
- no-mistakes is no longer a required dependency or authority layer.
- Local tmux workers still work.
- Local secondmates still work.
- Watcher and supervision still work for local tmux work.
- Sensitive actions require explicit Ross direction.
```

- [ ] **Step 6: Commit final cleanup**

```bash
git add AGENTS.md README.md CONTRIBUTING.md docs bin tests .github .agents/skills
git commit -m "chore: finish lean firstmate milestone one"
```

## Execution Notes

- Prefer deleting removed code over leaving hidden optional modes.
- If a local secondmate test fails after deleting remote code, inspect whether the failure is from shared local semantics before deleting more.
- If a watcher test fails after deleting Relay, keep the local wake behavior and delete only the removed Relay wake path.
- If a tmux test fails after collapsing backends, restore the old tmux behavior first and only then simplify helper shape.
- Do not run networked or credentialed commands unless Ross explicitly authorizes that action.
- Do not push, open a PR, merge, apply local changes to another checkout, discard work, or delete persistent homes without explicit Ross direction.
