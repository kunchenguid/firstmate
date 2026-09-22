#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)
# A claude spawn writes workspace trust into the launching user's own store,
# and the script resolves it as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so the value
# is pinned EMPTY beside the throwaway HOME: an inherited one would beat that
# HOME and reach the developer's real store, while empty falls through to it
# and adds no launch prefix, since fm-spawn only prefixes a non-empty value.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <data-dir> <id>
  local data=$1 id=$2
  cat > "$data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Orca dispatch.

## Firstmate spec
Verify the Orca lifecycle behavior under test.
EOF
}

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

add_tmux_fake() {
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/tmux"
}

authoritative_native_context() {
  cat > "$RESP/2.out" <<'EOF'
{"schemaVersion":1,"commands":[{"path":["orchestration","run-create"],"flags":["objective"]},{"path":["orchestration","worker-start"],"flags":["task","spec","worktree","agent","terminal","run"]},{"path":["orchestration","worker-show"],"flags":["dispatch"]},{"path":["orchestration","worker-read"],"flags":["dispatch","source","cursor","limit"]},{"path":["orchestration","worker-abandon"],"flags":["dispatch"]},{"path":["orchestration","worker-stop"],"flags":["dispatch"]},{"path":["orchestration","worker-list"],"flags":["run"]},{"path":["orchestration","worker-release"],"flags":["dispatch"]},{"path":["orchestration","send"],"flags":["subject","to","body","dispatch-id"]},{"path":["orchestration","check"],"flags":["run","ack"]},{"path":["terminal","wait"],"flags":["terminal","for","timeout-ms"]},{"path":["worktree","ps"],"flags":[]}]}
EOF
}

test_supervised_capability_probe_requires_native_command_shape() {
  local out status
  orca_case supervised-capability
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  authoritative_native_context
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_capability_check claude; printf "%s" "$FM_ORCA_SUPERVISED_COMMAND_COUNT"' "$ROOT" )
  [ "$out" = 12 ] || fail "native capability probe should accept the complete command shape, got '$out'"
  orca_case supervised-capability-schema
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  printf '{"schemaVersion":2,"commands":[]}\n' > "$RESP/2.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; if fm_backend_orca_supervised_capability_check claude; then exit 2; fi; printf "%s" "$FM_ORCA_SUPERVISED_REASON"; exit 1' "$ROOT" ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "native capability probe accepted an unsupported agent-context schema"
  [ "$out" = unsupported-schema-2 ] || fail "unsupported schema reason was not preserved, got '$out'"
  pass "native Orca capability probe gates schema and required command shapes"
}

test_supervised_capability_keeps_pi_on_terminal_fallback() {
  local out status
  orca_case supervised-pi-fallback
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; if fm_backend_orca_supervised_capability_check pi; then exit 2; fi; printf "%s" "$FM_ORCA_SUPERVISED_REASON"; exit 1' "$ROOT" ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "native Orca capability probe must not claim Pi support"
  [ "$out" = agent-pi-not-supported ] || fail "Pi should be an explicit native capability skip, got '$out'"
  assert_not_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fagent-context' \
    "an unsupported Pi capability must not invoke Orca agent-context"
  pass "native Orca capability gate keeps unverified Pi on the tested terminal adapter"
}

test_supervised_worker_start_and_transcript_read() {
  local out
  orca_case supervised-transcript
  cat > "$RESP/1.out" <<'EOF'
{"ok":true,"result":{"runId":"run-1","taskId":"task-1","dispatchId":"dispatch-1","workerId":"worker-1","terminal":{"handle":"terminal-1","incarnationId":"inc-1","paneKey":"pane-1","worktreeId":"wt-1"}}}
EOF
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_worker_start run-1 "spec" wt-1 claude; printf "%s:%s:%s:%s" "$FM_ORCA_SUPERVISED_TASK_ID" "$FM_ORCA_SUPERVISED_DISPATCH_ID" "$FM_ORCA_SUPERVISED_TERMINAL_INCAR" "$FM_ORCA_SUPERVISED_PANE_KEY"' "$ROOT" )
  [ "$out" = task-1:dispatch-1:inc-1:pane-1 ] || fail "worker-start did not project native identities, got '$out'"
  cat > "$RESP/2.out" <<'EOF'
{"ok":true,"result":{"source":"transcript","sourceIdentity":"dispatch-1/transcript","nextCursor":"cursor-2","contentComplete":true,"clipping":false,"sourceExact":true,"transcript":{"messages":[{"blocks":[{"text":"first turn consumed"}]}]}}}
EOF
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_worker_read dispatch-1 cursor-1 40' "$ROOT" )
  [ "$out" = "first turn consumed" ] || fail "worker-read should prefer complete transcript text, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-read\x1f--dispatch\x1fdispatch-1\x1f--source\x1fauto\x1f--limit\x1f40\x1f--json\x1f--cursor\x1fcursor-1' \
    "worker-read did not preserve source, cursor, and clipping request semantics"
  pass "native Orca worker-start and transcript-first worker-read project stable identities"
}

test_supervised_worker_start_preserves_partial_receipt() {
  local out rc
  orca_case supervised-partial-start
  cat > "$RESP/1.out" <<'EOF'
{"ok":true,"result":{"runId":"run-partial","taskId":"task-partial","dispatchId":"dispatch-partial","workerId":"worker-partial","terminal":{"handle":"term-partial"}}}
EOF
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; if fm_backend_orca_supervised_worker_start run-partial "spec" wt-partial claude; then exit 2; fi; printf "%s:%s:%s" "$FM_ORCA_SUPERVISED_TASK_ID" "$FM_ORCA_SUPERVISED_DISPATCH_ID" "$FM_ORCA_SUPERVISED_TERMINAL"' "$ROOT" )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "incomplete worker-start receipt should be rejected while retaining returned identities"
  [ "$out" = task-partial:dispatch-partial:term-partial ] || fail "partial worker-start receipt was not retained: '$out'"
  pass "native Orca worker-start: incomplete receipts retain identities for abort reconciliation"
}

test_supervised_worker_read_marks_terminal_fallback() {
  local out
  orca_case supervised-terminal-fallback
  cat > "$RESP/1.out" <<'EOF'
{"ok":true,"result":{"source":"terminal","contentComplete":false,"clipping":true,"terminal":{"tail":["partial terminal evidence"]}}}
EOF
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_worker_read dispatch-1 "" 8' "$ROOT" )
  assert_contains "$out" "partial terminal evidence" "terminal fallback should retain the returned terminal text"
  assert_contains "$out" "transcript completeness is unproven" "terminal fallback should disclose incomplete transcript evidence"
  pass "native Orca worker-read marks terminal or clipped output as non-authoritative evidence"
}

test_supervised_state_rebind_and_identity_guards() {
  local out status meta worktree
  orca_case supervised-rebind
  worktree="$CASE_DIR/worktree"
  mkdir -p "$worktree"
  meta="$CASE_DIR/task.meta"
  fm_write_meta "$meta" \
    "endpoint_task_id=task-local" "worktree=$worktree" \
    "orca_dispatch_id=dispatch-1" "orca_task_id=task-1" \
    "orca_run_id=run-1" "orca_worker_id=worker-1" "orca_worktree_id=wt-1" \
    "terminal=term-old" "orca_terminal_incarnation=inc-old" "orca_pane_key=pane-old"
  cat > "$RESP/1.out" <<EOF
{"ok":true,"result":{"dispatchId":"dispatch-1","taskId":"task-1","runId":"run-1","workerId":"worker-1","worker":{"state":"running"},"terminal":{"handle":"term-new","incarnationId":"inc-new","paneKey":"pane-new","worktreeId":"wt-1","worktreePath":"$worktree"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true},"projection":{"liveness":"live"}}}
EOF
  cp "$RESP/1.out" "$RESP/2.out"
  cat > "$RESP/3.out" <<EOF
{"ok":true,"result":{"dispatchId":"dispatch-1","taskId":"task-1","runId":"run-1","workerId":"worker-1","worker":{"state":"running"},"terminal":{"handle":"term-wrong","incarnationId":"inc-wrong","paneKey":"pane-wrong","worktreeId":"wt-1","worktreePath":"$CASE_DIR/wrong"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}
EOF
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; s=$(fm_backend_orca_supervised_agent_state dispatch:dispatch-1); t=$(fm_backend_orca_supervised_rebind_meta "$1"); printf "%s:%s:%s" "$s" "$t" "$(fm_meta_get "$1" terminal)"' "$ROOT" "$meta" )
  [ "$out" = alive:term-new:term-new ] || fail "native state/rebind should project alive state and update routing evidence, got '$out'"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_rebind_meta "$1"' "$ROOT" "$meta" 2>&1 ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "native rebind should reject a mismatched worktree path"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-show\x1f--dispatch\x1fdispatch-1' \
    "native rebind should inspect the durable Dispatch"
  pass "native Orca state projection rebinds transient terminal evidence only after exact identity checks"
}

test_supervised_worker_state_maps_completion_and_unknown() {
  local out
  orca_case supervised-state-map
  cat > "$RESP/1.out" <<'EOF'
{"ok":true,"result":{"dispatchId":"dispatch-1","taskId":"task-1","runId":"run-1","workerId":"worker-1","worker":{"state":"completed"},"observation":{"exactWorker":true}}}
EOF
  cat > "$RESP/2.out" <<'EOF'
{"ok":true,"result":{"dispatchId":"dispatch-1","taskId":"task-1","runId":"run-1","workerId":"worker-1","worker":{"state":"mystery"},"observation":{"exactWorker":true},"projection":{"liveness":"uncertain"}}}
EOF
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; printf "%s:%s" "$(fm_backend_orca_supervised_agent_state dispatch:dispatch-1)" "$(fm_backend_orca_supervised_agent_state dispatch:dispatch-1)"' "$ROOT" )
  [ "$out" = dead:ambiguous ] || fail "native state mapping should distinguish settled death from unknown outcome, got '$out'"
  pass "native Orca state mapping preserves unknown outcomes"
}

test_supervised_worker_stop_and_source_change_guards() {
  local out status
  orca_case supervised-stop-read
  printf '{"ok":true,"result":{"stopped":true}}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_worker_stop dispatch-1' "$ROOT"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-stop\x1f--dispatch\x1fdispatch-1' \
    "worker-stop should use its distinct native lifecycle primitive"
  orca_case supervised-source-change
  printf '{"ok":true,"result":{"source":"terminal","fallbackReason":"source_changed","contentComplete":false,"clipping":false,"terminal":{"tail":["stale"]}}}\n' > "$RESP/1.out"
  if PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_worker_read dispatch-1 cursor-1 8 >/dev/null' "$ROOT"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 2 ] || fail "source identity changes should invalidate the existing worker-read cursor"
  pass "native Orca stop and source-change evidence keep lifecycle and cursor semantics explicit"
}

test_supervised_release_and_abandon_use_distinct_guards() {
  local out
  orca_case supervised-release
  fm_write_meta "$CASE_DIR/task.meta" \
    "endpoint_task_id=task-local" "worktree=$CASE_DIR/worktree" \
    "orca_dispatch_id=dispatch-1" "orca_task_id=task-1" \
    "orca_run_id=run-1" "orca_worker_id=worker-1" "orca_worktree_id=wt-1"
  cat > "$RESP/1.out" <<EOF
{"ok":true,"result":{"dispatchId":"dispatch-1","taskId":"task-1","runId":"run-1","workerId":"worker-1","worktreeId":"wt-1","worktreePath":"$CASE_DIR/worktree","worker":{"state":"completed"},"resource":{"ownedByCoordinator":true},"observation":{"exactWorker":true}}}
EOF
  printf '{"ok":true,"result":{"released":true}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_release "$1"' "$ROOT" "$CASE_DIR/task.meta" )
  [ -z "$out" ] || fail "worker-release should not print an unrequested response"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-release\x1f--dispatch\x1fdispatch-1\x1f--json' \
    "settled owned worker was not released through worker-release"
  orca_case supervised-abandon
  printf '{"ok":true,"result":{"abandoned":true}}\n' > "$RESP/1.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/backends/orca.sh"; fm_backend_orca_supervised_abandon dispatch-unknown' "$ROOT"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-abandon\x1f--dispatch\x1fdispatch-unknown\x1f--json' \
    "unknown-process recovery did not use worker-abandon"
  pass "native Orca release requires owned settled identity while recovery uses worker-abandon"
}

test_capture_reads_terminal_tail_json() {
  local out
  orca_case capture-tail
  printf '{"result":{"terminal":{"tail":["line one","line two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print result.terminal.tail joined by newlines, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--limit'$'\x1f''40'$'\x1f''--json' \
    "capture did not call orca terminal read with terminal/limit/json"
  pass "fm_backend_orca_capture: parses result.terminal.tail and calls terminal read"
}

test_capture_falls_back_to_text_fields() {
  local out
  orca_case capture-text
  printf '{"result":{"text":"plain text output"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-abc 5' "$ROOT" )
  [ "$out" = "plain text output" ] || fail "capture should fall back to result.text, got '$out'"
  pass "fm_backend_orca_capture: falls back to result text fields"
}

test_capture_fails_on_orca_error_json() {
  local out status
  orca_case capture-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-stale 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on Orca ok:false read JSON"
  assert_contains "$out" "terminal handle stale" "capture should surface the Orca read error message"
  pass "fm_backend_orca_capture: fails closed on Orca read error JSON"
}

test_runtime_check_accepts_ready_orca_status() {
  local out
  orca_case runtime-ready
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on ready status, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "runtime_check did not call orca status --json"
  pass "fm_backend_orca_runtime_check: accepts reachable ready runtime"
}

test_runtime_check_refuses_unready_orca_status() {
  local out status
  orca_case runtime-unready
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" "runtime_check should explain the readiness requirement"
  pass "fm_backend_orca_runtime_check: fails closed when runtime is not ready"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  orca_case send-submit
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  # The composer read is ONE bounded tail read: the old backward paging
  # (--cursor follow-ups on a limited page) is deleted, because paging into
  # scrollback is what let a stale startup banner compete with the live
  # composer (audit fm-composer-consolidation-audit-s1, section 3.3).
  assert_not_contains "$(cat "$LOG")" $'\x1f''--cursor'$'\x1f' \
    "the composer read must never page backward into scrollback"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter with one bounded read"
}

test_send_text_submit_borderless_claude_confirms() {
  # The #2029 analogue this adapter never received: a borderless claude
  # composer (bare `❯` row between horizontal rules) must confirm a submit.
  # Before consolidation orca knew only the bordered shape, so every steer to
  # a borderless harness exited unconfirmed and --resolve-key never closed.
  local out
  orca_case send-submit-borderless
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["────────────────","❯","────────────────"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless claude composer should confirm the submit, got '$out'"
  pass "fm_backend_orca_send_text_submit: a borderless claude composer confirms delivery (the missing #2029 shape)"
}

test_composer_state_stale_banner_never_wins() {
  # The audit's confidently-wrong case (section 3.3): codex's startup banner
  # (`│ permissions: YOLO mode │` inside a rounded box) classified as the
  # composer, reading `pending` for a row that is not a composer at all. With
  # the full shape catalogue the live bare row below the banner wins; with a
  # plain capture its trailing hint text is unreadable, so the verdict is
  # `unknown` (defer) - never the banner's false `pending`.
  local out
  orca_case composer-stale-banner
  printf '{"ok":true,"result":{"terminal":{"tail":["╭────────────────────────╮","│ permissions: YOLO mode │","╰────────────────────────╯","› Use /skills to list available skills"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" != pending ] || fail "a stale startup banner must never classify as pending composer text"
  [ "$out" = unknown ] || fail "the plain-capture codex hint should defer as unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a stale startup banner cannot outrank the live composer row"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ > hello captain │","╰─────────────────╯"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ >               │","╰─────────────────╯"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_orca_send_text_submit: retries Enter while composer remains pending"
}

test_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case composer-popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_orca_composer_state: a slash-command popup's argument-hint placeholder still reads pending"
}

# Dead-shell injection safety (task fm-composer-shellglyph-safety): a pane whose
# agent has exited to a bare login shell has no bordered composer row, so the
# classifier finds nothing and reports `unknown` - NOT a safe (empty) injection
# target. Covers the same guarantee herdr/cmux/tmux tests pin for their backends.
test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  orca_case composer-bare-shell
  printf '{"ok":true,"result":{"terminal":{"tail":["some earlier output","kunchen@mac firstmate $ "]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare dead-shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a bare dead-shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local out log_text enter_count
  orca_case send-submit-popup-autocomplete
  # 1: literal send "/compact"
  # 2: Enter #1 closes the popup and fills the placeholder
  # 3: read - composer still holds real pending text
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ──────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill still reads pending, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: a slash-command popup's placeholder fill on Enter #1 does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_literal_constructs_non_enter_send() {
  orca_case send-literal
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-123 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--json' \
    "send_literal did not send text without --enter"
  assert_not_contains "$(cat "$LOG")" $'\x1f''--enter' "send_literal should not submit Enter"
  pass "fm_backend_orca_send_literal: sends text without submitting"
}

test_send_text_submit_reports_send_failed() {
  local out
  orca_case send-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Orca send should report send-failed, got '$out'"
  pass "fm_backend_orca_send_text_submit: reports send-failed when Orca send fails"
}

test_send_helpers_reject_orca_error_json() {
  local out status
  orca_case send-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line term-stale "hello"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should fail on Orca ok:false JSON"
  assert_contains "$out" "terminal handle stale" "send_text_line should surface the Orca send error"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-stale "typed"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_literal should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello" 1 0.01 0.01' "$ROOT" 2>/dev/null )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed on Orca ok:false JSON, got '$out'"
  pass "Orca send helpers: fail closed on ok:false JSON"
}

test_send_key_enter_and_interrupt() {
  orca_case send-key
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Enter; fm_backend_orca_send_key term-123 C-c' "$ROOT"
  expect_code 0 $? "send_key Enter and C-c should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_key Enter did not send empty text with --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--interrupt'$'\x1f''--json' \
    "send_key C-c did not send --interrupt"
  pass "fm_backend_orca_send_key: Enter maps to empty enter, C-c maps to interrupt"
}

test_send_key_refuses_unknown_key() {
  local out status
  orca_case send-key-unknown
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unsupported Orca keys"
  assert_contains "$out" "unsupported Orca key 'F12'" "send_key did not name the unsupported key"
  pass "fm_backend_orca_send_key: refuses unsupported keys loudly"
}

test_send_key_refuses_escape_until_supported() {
  local out status
  orca_case send-key-escape
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Escape' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse Escape until Orca exposes a real Escape primitive"
  assert_contains "$out" "unsupported Orca key 'Escape'" "send_key did not name Escape as unsupported"
  [ ! -s "$LOG" ] || fail "unsupported Escape should not call orca terminal send"
  pass "fm_backend_orca_send_key: refuses Escape instead of mapping it to interrupt"
}

test_kill_is_best_effort_close() {
  orca_case kill
  printf '1\n' > "$RESP/1.exit"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should stay best-effort when Orca close fails"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  pass "fm_backend_orca_kill: calls terminal close and stays best-effort"
}

# The paired direction - an `orca` stub present, a close command that exits
# nonzero, still 0 - is test_kill_is_best_effort_close above. This case is the
# distinction that arm exists to make, so the two are read together.
test_kill_refuses_when_the_orca_cli_is_absent() {
  local out status orca_free
  orca_case kill-no-cli
  orca_free=$(fm_test_base_path_sans "$PATH" orca)
  ! PATH="$orca_free" command -v orca >/dev/null 2>&1 \
    || fail "the orca-free search path still resolved orca"
  PATH="$orca_free" command -v bash >/dev/null 2>&1 \
    || fail "the orca-free search path lost bash, so this case would pass vacuously"
  out=$( PATH="$orca_free" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "kill reported success for a close its missing CLI never attempted"
  assert_contains "$out" "backend=orca selected but the 'orca' CLI is not installed" \
    "kill did not name the missing CLI as the reason the close never happened"
  [ ! -s "$LOG" ] || fail "kill invoked orca despite the CLI being absent"
  pass "fm_backend_orca_kill: a close its missing CLI never attempted reports the failure instead of a success"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status
  orca_case remove-error-json
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree wt-gone::/orca/wt-gone' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "remove_worktree should surface the Orca removal error"
  pass "fm_backend_orca_remove_worktree: fails closed on ok:false JSON"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123::/orca/wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_existing_worktree_refuses_ambiguous_path() {
  local folder out status
  folder="$TMP_ROOT/ambiguous-existing-worktree"
  orca_case ambiguous-existing-worktree
  printf '{"ok":true,"result":{"worktrees":[{"worktreeId":"wt-one","path":"%s"},{"worktreeId":"wt-two","path":"%s"}]}}\n' "$folder" "$folder" > "$RESP/1.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_existing_worktree "$1"' "$ROOT" "$folder" 2>&1 ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "existing Orca worktree lookup accepted an ambiguous path"
  [ -z "$out" ] || fail "ambiguous existing worktree lookup should not select an arbitrary id: $out"
  pass "fm_backend_orca_existing_worktree: refuses duplicate workspace identities for one path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path term
  orca_case parser-pruned-terminal-shapes

  set +e
  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  term=${wt_path#*$'\t'}
  wt_path=${wt_path%%$'\t'*}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ "$term" = "$wt_path" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123::/orca/wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = wt-123::/orca/wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123::/orca/wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123::/orca/wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_removes_worktree_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path::/orca/wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create did not return a path for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-no-path'$'\x1f''--json' \
    "worktree helper did not close the implicit terminal when path parsing failed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-no-path::/orca/wt-no-path'$'\x1f''--force'$'\x1f''--json' \
    "worktree helper did not remove the pathless Orca worktree"
  pass "fm_backend_orca_worktree_create: removes created worktree when path is missing"
}

test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails() {
  local proj data state config id out status
  id="orcapathlessz6"
  proj="$TMP_ROOT/pathless-cleanup-project"
  data="$TMP_ROOT/pathless-cleanup-data"
  state="$TMP_ROOT/pathless-cleanup-state"
  config="$TMP_ROOT/pathless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup::/orca/wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create did not return a path" \
    "pathless worktree failure should explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-pathless-cleanup::/orca/wt-pathless-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "pathless cleanup should attempt helper-backed worktree removal"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup::/orca/wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log staged launch
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn::/orca/wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn::/orca/wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  staged=$(tr '\037' '\n' < "$log" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] \
    || fail "spawn did not send Orca a readable staged launch command"
  launch=$(cat "$staged")
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}'" \
    "the staged launch sent through Orca did not select the Claude harness"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

test_spawn_native_mode_falls_back_to_terminal_adapter() {
  local proj wt data state config id out status
  id="orcafallbackz5"
  proj="$TMP_ROOT/native-fallback-project"
  wt="$TMP_ROOT/native-fallback-wt"
  data="$TMP_ROOT/native-fallback-data"
  state="$TMP_ROOT/native-fallback-state"
  config="$TMP_ROOT/native-fallback-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case native-fallback
  printf '1\n' > "$RESP/1.exit"
  printf '1\n' > "$RESP/2.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-native-fallback"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-native-fallback::/orca/wt-native-fallback","path":"%s"},"terminal":{"handle":"term-native-fallback"}}}\n' "$wt" > "$RESP/4.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca --orca-mode supervised 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native-mode fallback should preserve the terminal adapter: $out"
  assert_contains "$out" "native Orca supervision unavailable" \
    "native-mode fallback should explain why the terminal adapter was selected"
  assert_grep "orca_mode=terminal" "$state/$id.meta" \
    "fallback metadata should record terminal mode rather than claiming native supervision"
  assert_contains "$(cat "$LOG")" $'orca\x1frepo\x1fadd' \
    "native-mode fallback should continue through the raw Orca adapter"
  assert_not_contains "$(cat "$LOG")" $'orca\x1forchestration\x1frun-create' \
    "capability failure should not create a native Run"
  assert_not_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-start' \
    "capability failure should not start a native worker"
  pass "fm-spawn.sh --orca-mode supervised: capability failure falls back to terminal supervision"
}

test_spawn_raw_native_mode_falls_back_without_dropping_command() {
  local proj wt data state config id out status staged launch
  id="orcarawfallbackz6"
  proj="$TMP_ROOT/raw-native-fallback-project"
  wt="$TMP_ROOT/raw-native-fallback-wt"
  data="$TMP_ROOT/raw-native-fallback-data"
  state="$TMP_ROOT/raw-native-fallback-state"
  config="$TMP_ROOT/raw-native-fallback-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case raw-native-fallback
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-raw-native-fallback"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-raw-native-fallback::/orca/wt-raw-native-fallback","path":"%s"},"terminal":{"handle":"term-raw-native-fallback"}}}\n' "$wt" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" 'claude --flag=keep-me' --mode no-mistakes --yolo off --backend orca --orca-mode supervised 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "raw native Orca fallback should succeed through the terminal adapter: $out"
  assert_contains "$out" "does not accept raw/custom launch commands" \
    "raw native fallback should explain why the native path was skipped"
  staged=$(tr '\037' '\n' < "$LOG" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] || fail "raw fallback did not stage its terminal launch"
  launch=$(cat "$staged")
  assert_contains "$launch" 'claude --flag=keep-me' \
    "raw native fallback dropped the custom launch command"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --orca-mode supervised: raw launch commands use the tested terminal fallback intact"
}

test_native_orca_relaunch_reuses_durable_task_and_workspace() {
  local proj wt data state config id out status log_text
  id="orcarelaunchz1"
  proj="$TMP_ROOT/native-relaunch-project"
  wt="$TMP_ROOT/native-relaunch-wt"
  data="$TMP_ROOT/native-relaunch-data"
  state="$TMP_ROOT/native-relaunch-state"
  config="$TMP_ROOT/native-relaunch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_mode=supervised" "terminal=term-old" \
    "orca_worktree_id=wt-relaunch::$wt" "orca_run_id=run-relaunch" \
    "orca_task_id=task-relaunch" "orca_dispatch_id=dispatch-old" \
    "orca_worker_id=worker-old" "orca_terminal_incarnation=inc-old" \
    "orca_pane_key=pane-old"
  orca_case native-relaunch
  authoritative_native_context
  printf '{"ok":true,"result":{"dispatchId":"dispatch-old","taskId":"task-relaunch","runId":"run-relaunch","workerId":"worker-old","worktreeId":"wt-relaunch::%s","worktreePath":"%s","worker":{"state":"completed"},"observation":{"exactWorker":true}}}\n' "$wt" "$wt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"runId":"run-relaunch","taskId":"task-relaunch","dispatchId":"dispatch-new","workerId":"worker-new","terminal":{"handle":"term-new","incarnationId":"inc-new","paneKey":"pane-new","worktreeId":"wt-relaunch::%s"},"worktree":{"id":"wt-relaunch::%s","path":"%s"}}}\n' "$wt" "$wt" "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"dispatchId":"dispatch-new","taskId":"task-relaunch","runId":"run-relaunch","workerId":"worker-new","worker":{"state":"running"},"terminal":{"handle":"term-new","incarnationId":"inc-new","paneKey":"pane-new","worktreeId":"wt-relaunch::%s","path":"%s"},"worktree":{"id":"wt-relaunch::%s","path":"%s"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$wt" "$wt" "$wt" "$wt" > "$RESP/4.out"
  printf '%s\n' '{"ok":true,"result":{"dispatchId":"dispatch-new","source":"transcript","sourceIdentity":"dispatch-new/transcript","contentComplete":true,"clipping":false,"sourceExact":true,"transcript":{"messages":[{"blocks":[{"text":"replacement consumed"}]}]}}}' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT/native-relaunch-home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Orca relaunch should replace the worker in the recorded workspace: $out log=$(cat "$LOG" 2>/dev/null || true) response=$(cat "$RESP/1.out" 2>/dev/null || true)"
  assert_grep "orca_dispatch_id=dispatch-new" "$state/$id.meta" "native relaunch should publish the replacement Dispatch"
  assert_grep "orca_task_id=task-relaunch" "$state/$id.meta" "native relaunch should preserve the durable Task identity"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-start' "native relaunch should start a replacement worker"
  assert_contains "$log_text" $'--task\x1ftask-relaunch' "native relaunch should reuse the durable Task"
  assert_contains "$log_text" $'--retry-of\x1fdispatch-old' "native relaunch should link the retry to the prior Dispatch"
  pass "fm-spawn.sh native Orca relaunch: reuses Run/Task and exact workspace while rebinding Dispatch"
}

test_spawn_native_orca_secondmate_reuses_exact_home() {
  local home subhome data state config id out status log_text
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-native-home"
  subhome="$TMP_ROOT/secondmate-native-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data/$id" "$state" "$config" "$subhome/bin" "$subhome/data/$id" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$config/crew-harness"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case native-secondmate
  authoritative_native_context
  mv "$RESP/2.out" "$RESP/1.out"
  printf '{"ok":true,"result":{"worktrees":[{"worktreeId":"wt-sm","path":"%s"}]}}\n' "$subhome" > "$RESP/2.out"
  printf '{"ok":true,"result":{"runId":"run-sm"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"runId":"run-sm","taskId":"task-sm","dispatchId":"dispatch-sm","workerId":"worker-sm","terminal":{"handle":"term-sm","incarnationId":"inc-sm","paneKey":"pane-sm","worktreeId":"wt-sm"},"worktree":{"id":"wt-sm","path":"%s"}}}\n' "$subhome" > "$RESP/4.out"
  printf '{"ok":true,"result":{"dispatchId":"dispatch-sm","taskId":"task-sm","runId":"run-sm","workerId":"worker-sm","worker":{"state":"running"},"terminal":{"handle":"term-sm","incarnationId":"inc-sm","paneKey":"pane-sm","worktreeId":"wt-sm","path":"%s"},"worktree":{"id":"wt-sm","path":"%s"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$subhome" "$subhome" > "$RESP/5.out"
  printf '{"ok":true,"result":{"dispatchId":"dispatch-sm","source":"transcript","sourceIdentity":"dispatch-sm/transcript","contentComplete":true,"clipping":false,"sourceExact":true,"transcript":{"messages":[{"blocks":[{"text":"secondmate charter consumed"}]}]}}}\n' > "$RESP/6.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Orca secondmate should launch against the exact persistent home: $out"
  assert_contains "$out" "spawned $id harness=claude kind=secondmate" \
    "native secondmate spawn should report the launched manager"
  assert_grep "orca_mode=supervised" "$state/$id.meta" "native secondmate metadata should retain supervised mode"
  assert_grep "orca_dispatch_id=dispatch-sm" "$state/$id.meta" "native secondmate metadata should retain Dispatch identity"
  assert_grep "worktree=$subhome" "$state/$id.meta" "native secondmate metadata should retain exact home path"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fworktree\x1fps\x1f--json' \
    "native secondmate should discover its pre-existing home through worktree ps"
  assert_not_contains "$log_text" $'orca\x1fworktree\x1fcreate' \
    "native secondmate should not create a replacement worktree for its persistent home"
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-start' \
    "native secondmate should start a supervised manager"
  pass "fm-spawn.sh --backend orca --secondmate: supervises a persistent exact home natively"
}

test_spawn_rejects_terminal_orca_secondmate() {
  local home subhome data state config id out status
  id="orcasmterminalz2"
  home="$TMP_ROOT/secondmate-terminal-home"
  subhome="$TMP_ROOT/secondmate-terminal-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data/$id" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case native-secondmate-terminal
  if out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate --orca-mode terminal 2>&1 ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "persistent Orca Secondmate accepted terminal mode"
  assert_contains "$out" "require --orca-mode supervised" \
    "terminal Secondmate refusal did not explain the native-only requirement"
  assert_not_contains "$(cat "$LOG")" $'orca\x1fworktree\x1fcreate' \
    "terminal Secondmate refusal mutated Orca worktrees"
  pass "fm-spawn.sh refuses terminal fallback for persistent Orca Secondmates"
}

test_spawn_refuses_orca_when_runtime_not_ready() {
  local proj data state config id out status
  id="orcaruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" \
    "runtime readiness refusal should explain the Orca requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "spawn did not probe Orca runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "spawn should fail before repo/worktree creation when runtime is not ready"
  pass "fm-spawn.sh --backend orca: refuses before mutation when Orca runtime is not ready"
}

test_spawn_refuses_orca_nonisolated_worktree() {
  local proj data state config id out status
  id="orcabadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad::/orca/wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Orca spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-bad'$'\x1f''--json' \
    "Orca spawn should close the implicit terminal after validation aborts"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-bad::/orca/wt-bad'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree after validation aborts"
  pass "fm-spawn.sh --backend orca: refuses non-isolated worktrees and closes implicit terminals"
}

test_spawn_removes_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail::/orca/wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail::/orca/wt-terminal-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree when terminal creation fails"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  pass "fm-spawn.sh --backend orca: removes worktree when terminal creation fails"
}

test_spawn_preserves_orca_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="orcacleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail::/orca/wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-cleanup-fail::/orca/wt-cleanup-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should attempt helper cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail::/orca/wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_releases_orca_resources_when_metadata_write_fails() {
  local proj wt data state config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  wt="$TMP_ROOT/meta-fail-wt"
  data="$TMP_ROOT/meta-fail-data"
  state="$TMP_ROOT/meta-fail-state"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state/$id.meta" "$config"
  write_spawn_brief "$data" "$id"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-meta-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-meta-fail::/orca/wt-meta-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail"}}}\n' > "$RESP/4.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when metadata cannot be written"
  assert_contains "$out" "task record for $id could not be published" \
    "spawn should report metadata publication failure without relying on platform-specific mv output"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-meta-fail'$'\x1f''--json' \
    "Orca spawn should close the recorded terminal when a later abort occurs"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-meta-fail::/orca/wt-meta-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the recorded worktree when a later abort occurs"
  [ ! -f "$state/$id.meta" ] || fail "metadata-write abort should not publish a regular metadata file"
  pass "fm-spawn.sh --backend orca: releases terminal and worktree on later aborts"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral record body
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case io-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":["ready"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Orca metadata, got '$out'"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello orca"
  printf '{"ok":true,"result":{"terminal":{"tail":["idle prompt"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should fall back cleanly for an idle Orca scout"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-io' \
    "peek/crew-state did not read the recorded Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f'"fm-$id" \
    "crew-state should not read the stable Orca alias as a terminal handle"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "send did not enqueue through the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello orca" ] || fail "Orca task inbox did not preserve the send body, got '$body'"
  assert_not_contains "$(cat "$LOG")" $'--text\x1fhello orca\x1f' \
    "send typed the payload instead of recording it"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f'': Firstmate instruction waiting:' \
    "send did not ring the inbox doorbell through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit the doorbell through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata and its durable inbox"
}

test_crew_state_projects_native_worker_state() {
  local wt state id out
  id="orcastatedonez3"
  wt="$TMP_ROOT/native-state-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/native-state-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native" "worktree=$wt" \
    "project=$wt" "harness=claude" "kind=scout" "backend=orca" "orca_mode=supervised" \
    "orca_worktree_id=wt-native" "orca_run_id=run-native" "orca_task_id=task-native" \
    "orca_dispatch_id=dispatch-native" "orca_worker_id=worker-native" \
    "orca_terminal_incarnation=inc-native" "orca_pane_key=pane-native"
  touch "$state/.last-watcher-beat"
  orca_case native-state
  printf '{"ok":true,"result":{"dispatchId":"dispatch-native","taskId":"task-native","runId":"run-native","workerId":"worker-native","worktreeId":"wt-native","worktreePath":"%s","worker":{"state":"completed"},"resource":{"ownedByCoordinator":true},"observation":{"exactWorker":true}}}\n' "$wt" > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  [ "$out" = "state: done · source: native-worker · native Orca worker settled" ] || fail "crew-state should project a settled native worker, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-show\x1f--dispatch\x1fdispatch-native\x1f--json' \
    "crew-state should inspect native Dispatch identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1fterminal\x1fread' \
    "native crew-state should not fall back to terminal scrollback"
  pass "fm-crew-state: projects native Orca worker state from exact Dispatch identity"
}

test_native_dispatch_and_terminal_targets_stay_distinct() {
  local state id wt meta out
  id="orcatargetcontractz5"
  wt="$TMP_ROOT/native-target-contract-wt"
  state="$TMP_ROOT/native-target-contract-state"
  mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native" "worktree=$wt" \
    "project=$wt" "harness=claude" "kind=scout" "backend=orca" "orca_mode=supervised" \
    "orca_dispatch_id=dispatch-native"
  meta="$state/$id.meta"
  out=$(bash -c '
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-classify-lib.sh"
    printf "%s\n" \
      "$(fm_backend_target_of_meta "$2")" \
      "$(fm_backend_terminal_target_of_meta "$2")" \
      "$(basename "$(fm_backend_meta_for_window dispatch:dispatch-native "$3")" .meta)" \
      "$(window_to_task dispatch:dispatch-native "$3")"
  ' _ "$ROOT" "$meta" "$state")
  [ "$out" = $'dispatch:dispatch-native\nterm-native\norcatargetcontractz5\norcatargetcontractz5' ] \
    || fail "native state and terminal target contracts were not kept distinct: $out"
  pass "native Orca state targets reverse-resolve without masquerading as terminals"
}

test_fm_send_uses_native_orca_mailbox_after_inbox_write() {
  local wt state id out status
  id="orcanativesendz4"
  wt="$TMP_ROOT/native-send-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/native-send-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native" "worktree=$wt" \
    "project=$wt" "harness=claude" "kind=scout" "backend=orca" "orca_mode=supervised" \
    "orca_worktree_id=wt-native" "orca_run_id=run-native" "orca_task_id=task-native" \
    "orca_dispatch_id=dispatch-native" "orca_worker_id=worker-native"
  touch "$state/.last-watcher-beat"
  orca_case native-send
  printf '{"ok":true,"result":{"accepted":true}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_SEND_SETTLE=0 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-send.sh" "fm-$id" "native hello" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Orca send should succeed after durable inbox write: $out"
  [ -f "$state/$id.inbox/001.msg" ] || fail "native Orca send did not write the durable inbox record"
  assert_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fsend\x1f--to\x1fdispatch:dispatch-native\x1f--subject\x1fFirstmate task instruction' \
    "native steering did not target the recorded Dispatch mailbox"
  assert_contains "$(cat "$LOG")" $'--type\x1fdispatch\x1f--dispatch-id\x1fdispatch-native' \
    "native steering did not preserve Dispatch routing identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1fterminal\x1fsend' \
    "native steering should not type a terminal doorbell after mailbox success"
  pass "fm-send: durable Firstmate inbox plus native Orca mailbox steering"
}

test_fm_send_native_key_uses_terminal_target() {
  local wt state id out status log_text
  id="orcanativekeyz6"
  wt="$TMP_ROOT/native-key-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/native-key-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native" "worktree=$wt" \
    "project=$wt" "harness=claude" "kind=scout" "backend=orca" "orca_mode=supervised" \
    "orca_dispatch_id=dispatch-native"
  touch "$state/.last-watcher-beat"
  orca_case native-key
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-send.sh" "fm-$id" --key C-c 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Orca key send should succeed: $out"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-native\x1f--interrupt\x1f--json' \
    "native key delivery should use the recorded terminal handle"
  assert_not_contains "$log_text" $'--terminal\x1fdispatch:dispatch-native' \
    "native key delivery must not pass the Dispatch state target to terminal send"
  pass "fm-send: native Orca key delivery rebinds to the terminal target"
}

test_fm_send_native_mailbox_failure_uses_terminal_fallback() {
  local wt state id out status log_text
  id="orcanativefallbackz7"
  wt="$TMP_ROOT/native-fallback-send-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/native-fallback-send-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native" "worktree=$wt" \
    "project=$wt" "harness=claude" "kind=scout" "backend=orca" "orca_mode=supervised" \
    "orca_dispatch_id=dispatch-native"
  touch "$state/.last-watcher-beat"
  orca_case native-fallback-send
  printf '%s\n' '{"ok":false,"error":{"message":"mailbox unavailable"}}' > "$RESP/1.out"
  printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":[]}}}' > "$RESP/2.out"
  printf '%s\n' '{"ok":true,"result":{"send":{"accepted":true}}}' > "$RESP/3.out"
  printf '%s\n' '{"ok":true,"result":{"terminal":{"tail":[]}}}' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "fallback hello" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Orca mailbox fallback should preserve durable send success: $out"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-native' \
    "native mailbox failure should ring the recorded terminal"
  assert_not_contains "$log_text" $'--terminal\x1fdispatch:dispatch-native' \
    "native terminal fallback must not pass the Dispatch state target to terminal send"
  pass "fm-send: native Orca mailbox failure falls back through the terminal target"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case read-error-json
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-peek should fail when Orca reports a stale terminal"
  assert_contains "$out" "terminal handle stale" "fm-peek should surface the Orca read error message"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should not treat an Orca read error as a live endpoint"
  assert_contains "$out" "backend target gone: term-stale" "crew-state should report the stale Orca terminal as gone"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-stale' \
    "fm-peek/fm-crew-state did not read the recorded Orca terminal"
  pass "fm-peek/fm-crew-state: Orca read error JSON fails closed"
}

test_target_exists_rejects_orca_error_json() {
  local status
  orca_case target-exists-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
}

test_native_orca_teardown_stops_before_release() {
  local proj wt data state config id out rc neutral log_text
  id="orcanativeteardownz8"
  proj="$TMP_ROOT/native-teardown-project"
  wt="$TMP_ROOT/native-teardown-wt"
  data="$TMP_ROOT/native-teardown-data"
  state="$TMP_ROOT/native-teardown-state"
  config="$TMP_ROOT/native-teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-native-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" "orca_mode=supervised" \
    "orca_worktree_id=wt-native-teardown::$wt" "orca_run_id=run-native-teardown" "orca_task_id=task-native-teardown" \
    "orca_dispatch_id=dispatch-native-teardown" "orca_worker_id=worker-native-teardown" \
    "orca_terminal_incarnation=inc-native-teardown" "orca_pane_key=pane-native-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case native-teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-native-teardown::%s","path":"%s"}}}\n' "$wt" "$wt" > "$RESP/1.out"
  for n in 2 3 5 6; do
    printf '{"ok":true,"result":{"dispatchId":"dispatch-native-teardown","taskId":"task-native-teardown","runId":"run-native-teardown","workerId":"worker-native-teardown","worktreeId":"wt-native-teardown::%s","worktreePath":"%s","worker":{"state":"%s"},"terminal":{"handle":"term-native-teardown","incarnationId":"inc-native-teardown","paneKey":"pane-native-teardown","worktreeId":"wt-native-teardown::%s"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$wt" "$wt" "$([ "$n" -ge 5 ] && echo completed || echo running)" "$wt" > "$RESP/$n.out"
  done
  printf '{"ok":true,"result":{"stopped":true}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"released":true}}\n' > "$RESP/7.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "native Orca teardown should stop before release: $out"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-stop\x1f--dispatch\x1fdispatch-native-teardown' \
    "native teardown should stop a live worker before release"
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-release\x1f--dispatch\x1fdispatch-native-teardown' \
    "native teardown should release only after settlement"
  assert_not_contains "$log_text" $'orca\x1fterminal\x1fclose' \
    "native teardown should not close the transient terminal directly"
  pass "fm-teardown.sh native Orca: proves stop before release and preserves Dispatch ownership"
}

test_scout_teardown_removes_orca_worktree_via_helper() {
  local proj wt data state config id out rc neutral
  id="orcateardownz3"
  proj="$TMP_ROOT/teardown-project"
  wt="$TMP_ROOT/teardown-wt"
  data="$TMP_ROOT/teardown-data"
  state="$TMP_ROOT/teardown-state"
  config="$TMP_ROOT/teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown::/orca/wt-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown::/orca/wt-teardown","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown::/orca/wt-teardown'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the Orca worktree through orca worktree rm"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: scout report gate then helper-backed worktree removal"
}

test_scout_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcascoutmismatchz5"
  proj="$TMP_ROOT/scout-mismatch-project"
  wt="$TMP_ROOT/scout-mismatch-wt"
  other_wt="$TMP_ROOT/scout-mismatch-other-wt"
  data="$TMP_ROOT/scout-mismatch-data"
  state="$TMP_ROOT/scout-mismatch-state"
  config="$TMP_ROOT/scout-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch::/orca/wt-scout-mismatch" \
    "decisions_reviewed=1" "decision_keys="
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch::/orca/wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse when id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca scout worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca scout teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca scout teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout teardown refuses id/path mismatches"
}

test_teardown_removes_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path::/orca/wt-missing-path" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca teardown should release helpers even when the path is absent"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-missing-path'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal when the path was absent"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-missing-path::/orca/wt-missing-path'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the recorded Orca worktree when the path was absent"
  assert_absent "$state/$id.meta" "successful helper cleanup should remove task metadata"
  pass "fm-teardown.sh backend=orca: releases terminal/worktree when path is absent"
}

test_teardown_preserves_metadata_when_orca_remove_error_json() {
  local proj wt data state config id out rc neutral
  id="orcaremoveerrz2"
  proj="$TMP_ROOT/remove-error-project"
  wt="$TMP_ROOT/remove-error-wt"
  data="$TMP_ROOT/remove-error-data"
  state="$TMP_ROOT/remove-error-state"
  config="$TMP_ROOT/remove-error-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-remove-error" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-error::/orca/wt-remove-error" \
    "decisions_reviewed=1" "decision_keys="
  orca_case remove-error-teardown
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should fail when worktree removal returns ok:false JSON"
  assert_contains "$out" "worktree not removed" "teardown should surface the Orca removal error"
  assert_present "$state/$id.meta" "failed Orca removal should preserve task metadata"
  pass "fm-teardown.sh backend=orca: preserves metadata on remove ok:false JSON"
}

test_scout_teardown_refuses_orca_missing_report_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcanoreportz4"
  proj="$TMP_ROOT/missing-report-project"
  wt="$TMP_ROOT/missing-report-wt"
  data="$TMP_ROOT/missing-report-data"
  state="$TMP_ROOT/missing-report-state"
  config="$TMP_ROOT/missing-report-config"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report::/orca/wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse without a report even when the path is absent"
  assert_contains "$out" "has no report" "Orca scout teardown should explain the missing report"
  [ ! -s "$LOG" ] || fail "refused Orca scout teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout report gate precedes pathless helper cleanup"
}

test_ship_teardown_refuses_orca_missing_worktree_path() {
  local proj wt data state config id out rc neutral
  id="orcashipmissingz8"
  proj="$TMP_ROOT/missing-ship-project"
  wt="$TMP_ROOT/missing-ship-wt"
  data="$TMP_ROOT/missing-ship-data"
  state="$TMP_ROOT/missing-ship-state"
  config="$TMP_ROOT/missing-ship-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship::/orca/wt-missing-ship"
  orca_case missing-ship-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "no inspectable git worktree" \
    "Orca ship teardown should explain the fail-closed worktree requirement"
  [ ! -s "$LOG" ] || fail "refused Orca ship teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when worktree path is missing"
}

test_ship_teardown_removes_orca_worktree_when_id_path_matches() {
  local proj wt data state config id out rc neutral
  id="orcashipmatchz2"
  proj="$TMP_ROOT/ship-match-project"
  wt="$TMP_ROOT/ship-match-wt"
  data="$TMP_ROOT/ship-match-data"
  state="$TMP_ROOT/ship-match-state"
  config="$TMP_ROOT/ship-match-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match::/orca/wt-ship-match"
  orca_case ship-match
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match::/orca/wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match::/orca/wt-ship-match'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the matched Orca worktree"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path"
}

test_ship_teardown_refuses_orca_unresolvable_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcashipunresolvedz1"
  proj="$TMP_ROOT/ship-unresolved-project"
  wt="$TMP_ROOT/ship-unresolved-wt"
  data="$TMP_ROOT/ship-unresolved-data"
  state="$TMP_ROOT/ship-unresolved-state"
  config="$TMP_ROOT/ship-unresolved-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved::/orca/wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved::/orca/wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved::/orca/wt-ship-unresolved'$'\x1f''--json' \
    "teardown did not attempt to resolve the Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused unresolved Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused unresolved Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused unresolved Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when id resolution fails"
}

test_ship_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcashipmismatchz9"
  proj="$TMP_ROOT/ship-mismatch-project"
  wt="$TMP_ROOT/ship-mismatch-wt"
  other_wt="$TMP_ROOT/ship-mismatch-other-wt"
  data="$TMP_ROOT/ship-mismatch-data"
  state="$TMP_ROOT/ship-mismatch-state"
  config="$TMP_ROOT/ship-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch::/orca/wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch::/orca/wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch::/orca/wt-ship-mismatch'$'\x1f''--json' \
    "teardown did not resolve the mismatched Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown refuses id/path mismatches"
}

test_teardown_refuses_orca_missing_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcamissingidz5"
  proj="$TMP_ROOT/missing-id-project"
  wt="$TMP_ROOT/missing-id-wt"
  data="$TMP_ROOT/missing-id-data"
  state="$TMP_ROOT/missing-id-state"
  config="$TMP_ROOT/missing-id-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse missing orca_worktree_id"
  assert_contains "$out" "missing orca_worktree_id" "teardown did not explain the missing Orca worktree id"
  assert_present "$state/$id.meta" "failed teardown must preserve task metadata"
  [ ! -s "$LOG" ] || fail "teardown should fail before closing terminals or removing worktrees without an Orca worktree id"
  pass "fm-teardown.sh backend=orca: refuses missing worktree ids before cleanup"
}

test_teardown_refuses_orca_worktree_without_terminal_handle() {
  local proj wt data state config id out rc neutral
  id="orcanotermz0"
  proj="$TMP_ROOT/no-terminal-project"
  wt="$TMP_ROOT/no-terminal-wt"
  data="$TMP_ROOT/no-terminal-data"
  state="$TMP_ROOT/no-terminal-state"
  config="$TMP_ROOT/no-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal::/orca/wt-no-terminal" \
    "decisions_reviewed=1" "decision_keys="
  orca_case no-terminal
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted metadata without a terminal handle"
  assert_contains "$out" "missing terminal" "teardown did not explain the incomplete Orca endpoint"
  [ ! -s "$LOG" ] || fail "teardown dispatched to Orca before rejecting the incomplete endpoint"
  assert_present "$state/$id.meta" "missing-terminal refusal removed task metadata"
  pass "fm-teardown.sh backend=orca: refuses incomplete worktree-only endpoint metadata before runtime dispatch"
}

test_secondmate_force_teardown_settles_native_orca_child() {
  local home subhome childproj childwt child_id neutral out rc log_text
  home="$TMP_ROOT/native-orca-child-parent"
  subhome="$TMP_ROOT/native-orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/native-orca-child-worktree"
  child_id="orcanativechildz7"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Native Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" "terminal=term-native-child" \
    "worktree=$childwt" "project=$childproj" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "backend=orca" "orca_mode=supervised" \
    "orca_worktree_id=wt-native-child::$childwt" "orca_run_id=run-native-child" \
    "orca_task_id=task-native-child" "orca_dispatch_id=dispatch-native-child" \
    "orca_worker_id=worker-native-child" "orca_terminal_incarnation=inc-native-child" \
    "orca_pane_key=pane-native-child"
  orca_case secondmate-native-child
  printf '{"ok":true,"result":{"worktree":{"id":"wt-native-child::%s","path":"%s"}}}\n' "$childwt" "$childwt" > "$RESP/1.out"
  cp "$RESP/1.out" "$RESP/2.out"
  for n in 3 4 6 7; do
    printf '{"ok":true,"result":{"dispatchId":"dispatch-native-child","taskId":"task-native-child","runId":"run-native-child","workerId":"worker-native-child","worktreeId":"wt-native-child::%s","worktreePath":"%s","worker":{"state":"%s"},"terminal":{"handle":"term-native-child","incarnationId":"inc-native-child","paneKey":"pane-native-child","worktreeId":"wt-native-child::%s"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$childwt" "$childwt" "$([ "$n" -ge 6 ] && echo completed || echo running)" "$childwt" > "$RESP/$n.out"
  done
  printf '{"ok":true,"result":{"stopped":true}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"released":true}}\n' > "$RESP/8.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/9.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should settle the native Orca child before removal"$'\n'"$out"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-stop\x1f--dispatch\x1fdispatch-native-child' \
    "native child cleanup should stop a live Dispatch"
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-release\x1f--dispatch\x1fdispatch-native-child' \
    "native child cleanup should release the settled Dispatch"
  assert_not_contains "$log_text" $'orca\x1fterminal\x1fclose' \
    "native child cleanup should not close a transient terminal directly"
  assert_contains "$log_text" $'orca\x1fworktree\x1frm\x1f--worktree\x1fid:wt-native-child::' \
    "native child cleanup should remove the exact Orca worktree after release"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after native child cleanup"
  pass "fm-teardown.sh --force: settles native Orca children before worktree removal"
}

test_secondmate_force_teardown_removes_orca_child_via_orca() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-child-parent"
  subhome="$TMP_ROOT/orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-worktree"
  child_id="orcachildz6"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup::/orca/wt-child-cleanup"
  orca_case secondmate-child-cleanup
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/1.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup::/orca/wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/2.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/4.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup::/orca/wt-child-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "child cleanup did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f'"fm-$child_id" \
    "child cleanup closed the stable alias instead of the Orca terminal"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after forced teardown"
  pass "fm-teardown.sh --force: removes Orca secondmate children through Orca"
}

test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch() {
  local home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-child-mismatch-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-mismatch-worktree"
  other_wt="$TMP_ROOT/orca-child-mismatch-other-worktree"
  child_id="orcachildmismatchz1"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch::/orca/wt-child-mismatch"
  orca_case secondmate-child-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch::/orca/wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse mismatched Orca child id/path"
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca child worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca child cleanup should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca child cleanup should not remove worktrees"
  assert_present "$home/state/domain.meta" "refused forced secondmate teardown should preserve parent metadata"
  pass "fm-teardown.sh --force: refuses Orca child id/path mismatches"
}

test_secondmate_force_teardown_refuses_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child::/orca/wt-partial-child"
  orca_case secondmate-partial-child-cleanup
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a child with no terminal identity"
  assert_contains "$out" "missing terminal" "partial child refusal did not explain the incomplete endpoint"
  [ ! -s "$LOG" ] || fail "partial child refusal dispatched to Orca or tmux"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: refuses partial Orca secondmate children before runtime dispatch"
}

test_native_orca_secondmate_relaunch_rebinds_manager_dispatch() {
  local home subhome data state config id out status log_text
  id="orcamanagerelaunchz2"
  home="$TMP_ROOT/native-manager-parent"
  subhome="$TMP_ROOT/native-manager-home"
  data="$TMP_ROOT/native-manager-data"
  state="$TMP_ROOT/native-manager-state"
  config="$TMP_ROOT/native-manager-config"
  mkdir -p "$data/$id" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$subhome" "project=$subhome" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home=$subhome" \
    "backend=orca" "orca_mode=supervised" "terminal=term-manager-old" \
    "orca_worktree_id=wt-manager::$subhome" "orca_run_id=run-manager" \
    "orca_task_id=task-manager" "orca_dispatch_id=dispatch-manager-old" \
    "orca_worker_id=worker-manager-old" "orca_terminal_incarnation=inc-manager-old" \
    "orca_pane_key=pane-manager-old"
  orca_case native-secondmate-relaunch
  authoritative_native_context
  printf '{"ok":true,"result":{"dispatchId":"dispatch-manager-old","taskId":"task-manager","runId":"run-manager","workerId":"worker-manager-old","worktreeId":"wt-manager::%s","worktreePath":"%s","worker":{"state":"completed"},"observation":{"exactWorker":true}}}\n' "$subhome" "$subhome" > "$RESP/1.out"
  printf '{"ok":true,"result":{"runId":"run-manager","taskId":"task-manager","dispatchId":"dispatch-manager-new","workerId":"worker-manager-new","terminal":{"handle":"term-manager-new","incarnationId":"inc-manager-new","paneKey":"pane-manager-new","worktreeId":"wt-manager::%s"},"worktree":{"id":"wt-manager::%s","path":"%s"}}}\n' "$subhome" "$subhome" "$subhome" > "$RESP/3.out"
  printf '{"ok":true,"result":{"dispatchId":"dispatch-manager-new","taskId":"task-manager","runId":"run-manager","workerId":"worker-manager-new","worker":{"state":"running"},"terminal":{"handle":"term-manager-new","incarnationId":"inc-manager-new","paneKey":"pane-manager-new","worktreeId":"wt-manager::%s","path":"%s"},"worktree":{"id":"wt-manager::%s","path":"%s"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$subhome" "$subhome" "$subhome" "$subhome" > "$RESP/4.out"
  printf '%s\n' '{"ok":true,"result":{"dispatchId":"dispatch-manager-new","source":"transcript","sourceIdentity":"dispatch-manager-new/transcript","contentComplete":true,"clipping":false,"sourceExact":true,"transcript":{"messages":[{"blocks":[{"text":"manager replacement consumed"}]}]}}}' > "$RESP/5.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Secondmate relaunch should rebind its manager Dispatch in the persistent home: $out"
  assert_grep "orca_dispatch_id=dispatch-manager-new" "$state/$id.meta" "native Secondmate relaunch should publish the replacement manager Dispatch"
  assert_grep "orca_task_id=task-manager" "$state/$id.meta" "native Secondmate relaunch should preserve the durable manager Task"
  assert_grep "home=$subhome" "$state/$id.meta" "native Secondmate relaunch should preserve the persistent home"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'--task\x1ftask-manager' "native Secondmate relaunch should reuse the manager Task"
  assert_contains "$log_text" $'--retry-of\x1fdispatch-manager-old' "native Secondmate relaunch should link the old manager Dispatch"
  pass "fm-spawn.sh native Orca Secondmate relaunch: rebinds one manager in its persistent home"
}

test_native_orca_secondmate_retirement_releases_dispatch_before_home() {
  local home subhome data state config id neutral out status log_text
  id="orcamanageretirez3"
  home="$TMP_ROOT/native-retire-parent"
  subhome="$TMP_ROOT/native-retire-home"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$home/projects" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf '%s\n' "- $id - Native manager retirement (home: $subhome; scope: native; projects: native; added 2026-07-03)" > "$data/secondmates.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$subhome" "project=$subhome" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home=$subhome" \
    "backend=orca" "orca_mode=supervised" "terminal=term-manager" \
    "orca_worktree_id=wt-manager::$subhome" "orca_run_id=run-manager" \
    "orca_task_id=task-manager" "orca_dispatch_id=dispatch-manager" \
    "orca_worker_id=worker-manager" "orca_terminal_incarnation=inc-manager" \
    "orca_pane_key=pane-manager"
  orca_case native-secondmate-retirement
  for n in 1 2 3; do
    printf '{"ok":true,"result":{"dispatchId":"dispatch-manager","taskId":"task-manager","runId":"run-manager","workerId":"worker-manager","worktreeId":"wt-manager::%s","worktreePath":"%s","worker":{"state":"completed"},"observation":{"exactWorker":true},"resource":{"ownedByCoordinator":true}}}\n' "$subhome" "$subhome" > "$RESP/$n.out"
  done
  printf '{"ok":true,"result":{"released":true}}\n' > "$RESP/4.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  status=$?
  [ "$status" -eq 0 ] || fail "native Secondmate retirement should release the settled manager before removing its home: $out"
  [ ! -e "$subhome" ] || fail "native Secondmate retirement should remove the persistent home after release"
  assert_absent "$state/$id.meta" "native Secondmate retirement should remove the parent manager record"
  assert_not_contains "$(cat "$LOG")" $'orca\x1forchestration\x1fworker-stop' "settled native Secondmate retirement should not stop an already-dead manager"
  log_text=$(cat "$LOG")
  assert_contains "$log_text" $'orca\x1forchestration\x1fworker-release\x1f--dispatch\x1fdispatch-manager' "native Secondmate retirement should release its exact Dispatch"
  pass "fm-teardown.sh native Orca Secondmate retirement: release precedes persistent-home removal"
}

test_dispatcher_sources_orca_and_routes_primitives() {
  local out
  orca_case dispatch
  printf '{"result":{"terminal":{"tail":["via dispatch"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate orca; fm_backend_capture orca term-123 9' "$ROOT" )
  [ "$out" = "via dispatch" ] || fail "dispatcher should route capture to the Orca adapter, got '$out'"
  pass "fm-backend dispatcher: accepts orca and routes capture through bin/backends/orca.sh"
}

test_supervised_capability_probe_requires_native_command_shape
test_supervised_capability_keeps_pi_on_terminal_fallback
test_supervised_worker_start_and_transcript_read
test_supervised_worker_start_preserves_partial_receipt
test_supervised_worker_read_marks_terminal_fallback
test_supervised_state_rebind_and_identity_guards
test_supervised_worker_state_maps_completion_and_unknown
test_supervised_worker_stop_and_source_change_guards
test_supervised_release_and_abandon_use_distinct_guards
test_capture_reads_terminal_tail_json
test_capture_falls_back_to_text_fields
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_borderless_claude_confirms
test_composer_state_stale_banner_never_wins
test_send_text_submit_retries_when_composer_stays_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_bare_shell_prompt_is_unknown
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_literal_constructs_non_enter_send
test_send_text_submit_reports_send_failed
test_send_helpers_reject_orca_error_json
test_send_key_enter_and_interrupt
test_send_key_refuses_unknown_key
test_send_key_refuses_escape_until_supported
test_kill_is_best_effort_close
test_kill_refuses_when_the_orca_cli_is_absent
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_worktree_path_resolves_id
test_existing_worktree_refuses_ambiguous_path
test_dispatcher_sources_orca_and_routes_primitives
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_removes_worktree_when_path_missing
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_spawn_writes_orca_metadata_and_launches_harness
test_spawn_native_mode_falls_back_to_terminal_adapter
test_spawn_raw_native_mode_falls_back_without_dropping_command
test_native_orca_relaunch_reuses_durable_task_and_workspace
test_native_orca_secondmate_relaunch_rebinds_manager_dispatch
test_spawn_native_orca_secondmate_reuses_exact_home
test_spawn_rejects_terminal_orca_secondmate
test_native_orca_secondmate_retirement_releases_dispatch_before_home
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_nonisolated_worktree
test_spawn_removes_orca_worktree_when_terminal_create_fails
test_spawn_preserves_orca_metadata_when_abort_cleanup_fails
test_spawn_releases_orca_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_orca_meta
test_crew_state_projects_native_worker_state
test_native_dispatch_and_terminal_targets_stay_distinct
test_fm_send_uses_native_orca_mailbox_after_inbox_write
test_fm_send_native_key_uses_terminal_target
test_fm_send_native_mailbox_failure_uses_terminal_fallback
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
test_native_orca_teardown_stops_before_release
test_scout_teardown_removes_orca_worktree_via_helper
test_scout_teardown_refuses_orca_id_path_mismatch
test_teardown_removes_orca_worktree_when_path_missing
test_teardown_preserves_metadata_when_orca_remove_error_json
test_scout_teardown_refuses_orca_missing_report_when_path_missing
test_ship_teardown_refuses_orca_missing_worktree_path
test_ship_teardown_removes_orca_worktree_when_id_path_matches
test_ship_teardown_refuses_orca_unresolvable_worktree_id
test_ship_teardown_refuses_orca_id_path_mismatch
test_teardown_refuses_orca_missing_worktree_id
test_teardown_refuses_orca_worktree_without_terminal_handle
test_secondmate_force_teardown_settles_native_orca_child
test_secondmate_force_teardown_removes_orca_child_via_orca
test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch
test_secondmate_force_teardown_refuses_partial_orca_child

test_live_native_capability_probe() {
  local harness checked=0
  fm_live_gate default-on FM_ORCA_SUPERVISED_LIVE orca node
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source orca || fail "native Orca backend adapter could not be loaded"
  for harness in claude codex cursor; do
    case "$harness" in
      cursor) command -v cursor-agent >/dev/null 2>&1 || { printf '# %s absent, not verified here\n' "$harness"; continue; } ;;
      *) command -v "$harness" >/dev/null 2>&1 || { printf '# %s absent, not verified here\n' "$harness"; continue; } ;;
    esac
    checked=$((checked + 1))
    if ! fm_backend_orca_supervised_capability_check "$harness"; then
      fail "native Orca capability gate failed for installed $harness: ${FM_ORCA_SUPERVISED_REASON:-unknown}"
    fi
    pass "native Orca 1.4.206 capability gate: $harness schema=$FM_ORCA_SUPERVISED_SCHEMA commands=$FM_ORCA_SUPERVISED_COMMAND_COUNT"
  done
  [ "$checked" -gt 0 ] || fail "native Orca capability guard checked no installed agent harness"
}

test_live_native_capability_probe
