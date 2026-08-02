#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u
export FM_ORCA_TEST_LAB=firstmate-orca-test-lab-v1
export FM_ORCA_TEST_AUTHORITY_CAPABILITIES=verified-v1
export FM_ORCA_TEST_BOUND_REMOVAL_CAPABILITIES=verified-v1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite deliberately runs without errexit so expected failures can be
# captured and asserted. Restore that declared option state after every case.
pass() {
  printf 'ok - %s\n' "$1"
  set +e
}

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)

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
if [ "${1:-} ${2:-}" = "worktree create" ] \
  && [ "${FM_ORCA_QUARANTINE_STATE_READONLY:-0}" = 1 ] \
  && [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  chmod 500 "$FM_STATE_OVERRIDE"
fi
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.out" ]; then
  if [ "${1:-} ${2:-}" = "worktree show" ]; then
    worktree_label=
    worktree_terminal=
    if [ -n "${FM_STATE_OVERRIDE:-}" ] && [ -d "$FM_STATE_OVERRIDE" ]; then
      worktree_id=$(node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const result = data.result || {};
const worktree = result.worktree || result.item || result;
process.stdout.write(String(worktree.id || worktree.worktreeId || result.worktreeId || ""));
' "$RESP/$n.out")
      for metadata in "$FM_STATE_OVERRIDE"/*.meta; do
        [ -f "$metadata" ] || continue
        if grep -Fxq "orca_worktree_id=$worktree_id" "$metadata"; then
          worktree_label="fm-$(basename "$metadata" .meta)"
          worktree_terminal=$(sed -n 's/^terminal=//p' "$metadata" | tail -1)
          break
        fi
      done
    fi
    node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const result = data.result || {};
const worktree = result.worktree || result.item || result;
const label = process.argv[2] || "";
const terminal = process.argv[3] || "";
if (label && !worktree.name && !worktree.title && !result.worktreeName) {
  worktree.name = label;
}
if (label && !Array.isArray(worktree.terminals) && !Array.isArray(result.terminals)) {
  worktree.terminals = terminal ? [{handle: terminal, title: label}] : [];
}
process.stdout.write(JSON.stringify(data) + "\n");
' "$RESP/$n.out" "$worktree_label" "$worktree_terminal" > "$RESP/.worktree-show" || exit 1
    cat "$RESP/.worktree-show"
  elif [ "${1:-} ${2:-}" = "worktree create" ]; then
    requested_name=
    previous=
    for argument in "$@"; do
      [ "$previous" != --name ] || requested_name=$argument
      previous=$argument
    done
    node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const result = data.result || {};
const worktree = result.worktree || result.item || null;
if (worktree && !worktree.name && !worktree.title && !result.worktreeName) {
  worktree.name = process.argv[2] || "";
}
process.stdout.write(JSON.stringify(data) + "\n");
' "$RESP/$n.out" "$requested_name" || exit 1
  else
    cat "$RESP/$n.out"
  fi
  if [ -f "$RESP/$n.exit" ]; then
    exit "$(cat "$RESP/$n.exit")"
  fi
  exit 0
fi
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
case "${1:-} ${2:-}" in
  "terminal read")
    if [ -f "$RESP/.terminal-closed" ]; then
      printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n'
      exit 1
    fi
    terminal=
    previous=
    for argument in "$@"; do
      [ "$previous" != --terminal ] || terminal=$argument
      previous=$argument
    done
    if [ -f "$RESP/.terminal-worktree-override" ]; then
      worktree=$(cat "$RESP/.terminal-worktree-override")
    else
      worktree="wt-${terminal#term-}"
    fi
    if [ -n "${FM_ORCA_DEFAULT_TERMINAL_TITLE:-}" ]; then
      title=$FM_ORCA_DEFAULT_TERMINAL_TITLE
    elif [ -f "$RESP/.terminal-title" ]; then
      title=$(cat "$RESP/.terminal-title")
    elif [ -n "${FM_STATE_OVERRIDE:-}" ] && [ -d "$FM_STATE_OVERRIDE" ]; then
      title=
      for metadata in "$FM_STATE_OVERRIDE"/*.meta; do
        [ -f "$metadata" ] || continue
        if grep -Fxq "terminal=$terminal" "$metadata"; then
          title="fm-$(basename "$metadata" .meta)"
          break
        fi
      done
      [ -n "$title" ] || title="fm-${terminal#term-}"
    else
      title="fm-${terminal#term-}"
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","title":"%s","worktreeId":"%s","tail":[]}}}\n' "$terminal" "$title" "$worktree"
    ;;
  "terminal close")
    : > "$RESP/.terminal-closed"
    printf '{"ok":true,"result":{"closed":true}}\n'
    ;;
  "worktree show")
    if [ -f "$RESP/.worktree-show" ]; then
      if [ -f "$RESP/.terminal-closed" ]; then
        node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const result = data.result || {};
const worktree = result.worktree || result.item || result;
worktree.terminals = [];
process.stdout.write(JSON.stringify(data) + "\n");
' "$RESP/.worktree-show"
      else
        cat "$RESP/.worktree-show"
      fi
    fi
    ;;
  "worktree rm")
    if [ -n "${FM_ORCA_REMOVE_ERROR:-}" ]; then
      printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n'
    else
      if [ -n "${FM_ORCA_REMOVE_LOCAL_PATH:-}" ] && [ -n "${FM_ORCA_REMOVE_LOCAL_PROJECT:-}" ]; then
        rm -rf "$FM_ORCA_REMOVE_LOCAL_PATH"
        git -C "$FM_ORCA_REMOVE_LOCAL_PROJECT" worktree prune
      elif [ -n "${FM_ORCA_REMOVE_PROJECT:-}" ] && [ -n "${FM_ORCA_REMOVE_PATH:-}" ]; then
        git -C "$FM_ORCA_REMOVE_PROJECT" worktree remove --force "$FM_ORCA_REMOVE_PATH" || exit 1
      fi
      printf '{"ok":true,"result":{"removed":true}}\n'
    fi
    ;;
esac
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
  fm_git_init_commit "$root"
  printf '%s\n' "$root"
}

initialize_secondmate_home_repo() {
  local home=$1 source=$2 project source_branch source_head
  source_branch=$(git -C "$source" branch --show-current)
  [ -n "$source_branch" ] || fail "secondmate fixture source must have a checked-out branch"
  source_head=$(git -C "$source" rev-parse HEAD)
  git -C "$home" init -q
  git -C "$home" remote add origin "$source"
  git -C "$home" fetch -q origin
  git -C "$home" checkout -q -b "$source_branch" "$source_head"
  printf '/projects/\n/state/\n' > "$home/.gitignore"
  git -C "$home" add .
  git -C "$home" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid \
    commit -qm 'secondmate fixture state'
  git -C "$source" fetch -q "$home" HEAD:refs/remotes/fixture/secondmate
  git -C "$source" merge -q --ff-only refs/remotes/fixture/secondmate
  mkdir -p "$source/projects"
  for project in "$home"/projects/*; do
    [ -e "$project/.git" ] || continue
    git clone -q "$project" "$source/projects/${project##*/}"
    git -C "$source/projects/${project##*/}" remote set-url origin "$source/projects/${project##*/}"
    git -C "$project" remote add origin "$source/projects/${project##*/}"
  done
}

initialize_secondmate_project_repo() {
  local source_root=$1 clone=$2 worktree=$3 branch=$4 authority
  authority="$source_root/project-origins/alpha"
  mkdir -p "$source_root/projects" "$source_root/project-origins"
  fm_git_init_commit "$authority"
  git clone -q "$authority" "$source_root/projects/alpha"
  git clone -q "$source_root/projects/alpha" "$clone"
  git -C "$clone" remote set-url origin "$authority"
  git -C "$clone" worktree add --quiet -b "$branch" "$worktree"
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
case "${1:-}" in
  kill-window)
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && printf '%s\n' "$arg" >> "$LOG.killed"
      prev=$arg
    done
    ;;
  display-message)
    target=
    prev=
    for arg in "$@"; do
      [ "$prev" = -t ] && target=$arg
      prev=$arg
    done
    if [ -n "$target" ] && [ -f "$LOG.killed" ] && grep -qxF "$target" "$LOG.killed"; then
      exit 1
    fi
    printf '%%1\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

add_dead_tmux_fake() {  # <fakebin-dir>
  # A tmux whose recorded endpoint is provably gone: existence probes fail and
  # list-windows reports no windows, so fm-spawn's duplicate-endpoint check
  # resolves `absent` for a recorded legacy tmux window.
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

seed_legacy_task_meta() {  # <state-dir> <id> <project>
  # A pre-cutover task meta: no report_required marker (legacy teardown
  # contract) and a dead tmux window - the one task shape that may still
  # respawn onto backend=orca after the new-report-required spawn refusal.
  local state=$1 id=$2 proj=$3
  fm_write_meta "$state/$id.meta" \
    "window=legacy:fm-$id" "worktree=$TMP_ROOT/legacy-$id-wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
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
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"limited":true,"oldestCursor":"cursor-old"},"limited":true,"oldestCursor":"cursor-old"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"latestCursor":"cursor-new"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--cursor'$'\x1f''cursor-old'$'\x1f''--limit' \
    "send_text_submit did not follow cursor-backed reads when Orca reports a limited page"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter"
}

test_send_text_submit_keeps_current_tail_when_limited() {
  local out log_text enter_count
  orca_case send-submit-limited-current-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["noise","│ > hello captain │"],"limited":true,"oldestCursor":"cursor-old"},"limited":true,"oldestCursor":"cursor-old"}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭──╮","│ > │","╰──╯"],"latestCursor":"cursor-new"}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/5.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/6.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should keep the limited current tail and retry, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should see pending text in the current tail before older cursor text, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: preserves current tail when limited reads fetch older cursor text"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > hello captain │"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/5.out"
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
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions    │","  ╰──────────────── Composer ─────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
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
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions    │","  ╰──────────────── Composer ─────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ─────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
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

test_kill_propagates_close_failure() {
  local status
  orca_case kill-failure
  printf '1\n' > "$RESP/1.exit"
  if PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "kill should propagate an Orca close failure"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  pass "fm_backend_orca_kill: propagates terminal close failure"
}

test_terminal_state_classifies_closed_live_and_ambiguous_orca() {
  local out
  orca_case terminal-state-closed
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_state orca term-closed fm-task' "$ROOT" )
  [ "$out" = absent ] || fail "stale Orca terminal should classify absent even when read exits nonzero, got '$out'"

  orca_case terminal-state-live
  printf '{"ok":true,"result":{"terminal":{"handle":"term-live","title":"fm-task","tail":[]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_state orca term-live fm-task' "$ROOT" )
  [ "$out" = present ] || fail "valid Orca terminal read should classify present, got '$out'"

  orca_case terminal-state-ambiguous
  printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"runtime unavailable"}}\n' > "$RESP/1.out"
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_state orca term-unknown fm-task' "$ROOT" )
  [ "$out" = unknown ] || fail "ambiguous Orca read failure should classify unknown, got '$out'"
  pass "fm_backend_target_state: classifies Orca terminal absence soundly"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status token
  orca_case remove-error-json
  token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree_bound wt-gone /tmp/orca-wt "$1"' "$ROOT" "$token" 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "bound remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "bound remove_worktree should surface the Orca removal error"
  assert_contains "$(cat "$LOG")" $'--expected-path\x1f/tmp/orca-wt' \
    "bound remove_worktree omitted the provider path precondition"
  assert_contains "$(cat "$LOG")" $'--expected-boundary-token\x1f'"$token" \
    "bound remove_worktree omitted the filesystem-boundary precondition"
  pass "fm_backend_orca_remove_worktree_bound: fails closed on provider errors"
}

test_remove_worktree_requires_bound_provider_capability() {
  local out status token
  orca_case remove-boundary-capability
  token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  if out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ORCA_TEST_BOUND_REMOVAL_CAPABILITIES=unavailable \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree_bound wt-retained /tmp/orca-wt "$1"' "$ROOT" "$token" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "Orca removal proceeded without a bound provider capability"
  assert_contains "$out" "identity-bound provider capability" \
    "unbound Orca removal did not surface its provider limitation"
  [ ! -s "$LOG" ] || fail "unbound Orca removal reached the provider"
  pass "Orca removal retains worktrees without a bound provider capability"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path rest term
  orca_case parser-pruned-terminal-shapes

  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  rest=${out#*$'\t'}
  wt_path=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  term=${rest%%$'\t'*}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ -z "$term" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path rest term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  rest=${out#*$'\t'}
  wt_path=${rest%%$'\t'*}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_retains_partial_authority_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create returned incomplete or unsuccessful authority for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$out" $'wt-no-path\t\tterm-no-path\trecorded\trepo-no-path' \
    "worktree helper did not return every partial create identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "worktree helper closed a terminal before durable quarantine"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "worktree helper removed a pathless worktree before absence proof"
  pass "fm_backend_orca_worktree_create: returns partial authority without cleanup"
}

test_worktree_create_never_cleans_partial_response_inline() {
  local out status
  orca_case lifecycle-close-failure
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-close-failure"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-close-failure"},"terminal":{"handle":"term-close-failure"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"terminal_close_failed","message":"terminal close failed"}}\n' > "$RESP/4.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 ); then
    status=0
  else
    status=$?
  fi
  expect_code 2 "$status" "pathless Orca worktree partial-response status"
  assert_contains "$out" $'wt-close-failure\t\tterm-close-failure' \
    "partial response did not return durable Orca cleanup identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "worktree helper attempted cleanup before its caller durably quarantined identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "worktree helper removed a partial-response worktree"
  pass "Orca worktree creation delegates partial-response cleanup to quarantine"
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
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create returned incomplete or unsuccessful authority" \
    "pathless worktree failure should explain the missing path"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "pathless cleanup removed a worktree without terminal-absence proof"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  assert_no_grep '^worktree=' "$state/$id.meta" "preserved pathless metadata should not record an empty worktree path"
  assert_grep 'orca_cleanup_pending=1' "$state/$id.meta" "preserved pathless metadata missing cleanup quarantine"
  assert_grep 'orca_cleanup_phase=spawn-abort' "$state/$id.meta" "preserved pathless metadata missing cleanup phase"
  assert_no_grep "report_required=" "$state/$id.meta" "preserved pathless metadata must keep the legacy no-report contract"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_legacy_respawn_refuses_without_provider_task_authority() {
  local proj wt data state config id out log
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn","path":"%s","terminals":[{"handle":"term-spawn"}]}}}\n' \
    "$wt" > "$RESP/4.out"
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 ); then
    fail "legacy Orca respawn proceeded without provider task authority"
  fi
  assert_contains "$out" "Orca terminal is not authoritatively bound" \
    "legacy Orca respawn did not explain its fail-closed authority refusal"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send' \
    "refused legacy Orca respawn launched the harness"
  pass "fm-spawn.sh --backend orca: legacy respawn refuses without provider task authority"
}

test_spawn_refuses_new_report_required_orca_task_before_mutation() {
  local proj data state config id out status
  id="orcareportrefusez3"
  proj="$TMP_ROOT/report-refusal-project"
  data="$TMP_ROOT/report-refusal-data"
  state="$TMP_ROOT/report-refusal-state"
  config="$TMP_ROOT/report-refusal-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case report-refusal
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse a new report-required task"
  assert_contains "$out" "no reliable endpoint-absence proof" \
    "report-required Orca refusal should explain the missing absence proof"
  assert_contains "$out" "report-gated teardown could never complete" \
    "report-required Orca refusal should explain the permanent teardown wedge"
  assert_contains "$out" "tmux, herdr, zellij, or cmux" \
    "report-required Orca refusal should name the supported backends"
  assert_absent "$state/$id.meta" "report-required Orca refusal must not record metadata"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "report-required Orca refusal should fire before Orca repository mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree' \
    "report-required Orca refusal should fire before Orca worktree creation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal' \
    "report-required Orca refusal should fire before Orca terminal creation"
  pass "fm-spawn.sh --backend orca: refuses new report-required tasks before any owned mutation"
}

test_spawn_refuses_orca_respawn_of_report_required_task() {
  local proj data state config id out status
  id="orcareportrespawnz5"
  proj="$TMP_ROOT/report-respawn-project"
  data="$TMP_ROOT/report-respawn-data"
  state="$TMP_ROOT/report-respawn-state"
  config="$TMP_ROOT/report-respawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=legacy:fm-$id" "project=$proj" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "report_required=1"
  orca_case report-respawn-refusal
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse respawning a report-required task"
  assert_contains "$out" "no reliable endpoint-absence proof" \
    "report-required Orca respawn refusal should explain the missing absence proof"
  assert_grep "report_required=1" "$state/$id.meta" "refused respawn must leave the recorded report marker unchanged"
  assert_no_grep "backend=orca" "$state/$id.meta" "refused respawn must not rewrite the task metadata onto Orca"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "report-required Orca respawn refusal should fire before Orca repository mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree' \
    "report-required Orca respawn refusal should fire before Orca worktree creation"
  pass "fm-spawn.sh --backend orca: refuses respawning a report-required task before any owned mutation"
}

test_spawn_refuses_malformed_legacy_orca_report_metadata() {
  local proj data state config id out status
  id="orcamalformedreportz2"
  proj="$TMP_ROOT/malformed-report-project"
  data="$TMP_ROOT/malformed-report-data"
  state="$TMP_ROOT/malformed-report-state"
  config="$TMP_ROOT/malformed-report-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  seed_legacy_task_meta "$state" "$id" "$proj"
  printf 'report_required=0\n' >> "$state/$id.meta"
  orca_case malformed-report-refusal
  if out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 ); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "malformed legacy Orca report metadata was launched"
  assert_contains "$out" "invalid report_required metadata for $id" \
    "malformed legacy Orca report metadata was not diagnosed"
  assert_grep 'report_required=0' "$state/$id.meta" \
    "malformed legacy metadata was rewritten during refusal"
  [ ! -s "$LOG" ] || fail "malformed legacy Orca metadata reached backend mutation"
  pass "Orca recovery accepts only an absent report marker"
}

test_spawn_refuses_report_required_orca_batch_pair_before_mutation() {
  local proj data state config id out status
  id="orcabatchrefusez7"
  proj="$TMP_ROOT/batch-refusal-project"
  data="$TMP_ROOT/batch-refusal-data"
  state="$TMP_ROOT/batch-refusal-state"
  config="$TMP_ROOT/batch-refusal-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case batch-report-refusal
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id=$proj" --harness claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "batch fm-spawn.sh --backend orca should refuse a new report-required pair"
  assert_contains "$out" "no reliable endpoint-absence proof" \
    "batch report-required Orca refusal should explain the missing absence proof"
  assert_contains "$out" "batch: FAILED to spawn $id" \
    "batch dispatch should surface the refused Orca pair"
  assert_absent "$state/$id.meta" "batch report-required Orca refusal must not record metadata"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "batch report-required Orca refusal should fire before Orca repository mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree' \
    "batch report-required Orca refusal should fire before Orca worktree creation"
  pass "fm-spawn.sh batch pairs: refuse new report-required Orca spawns before any owned mutation"
}

test_report_required_orca_refusal_preserves_competing_lifecycle_state() {
  local proj data state config id out status held lock_identity state_snapshot data_snapshot af_log
  id="orcareportlockz8"
  proj="$TMP_ROOT/report-lock-project"
  data="$TMP_ROOT/report-lock-data"
  state="$TMP_ROOT/report-lock-state"
  config="$TMP_ROOT/report-lock-config"
  state_snapshot="$TMP_ROOT/report-lock-state.snapshot"
  data_snapshot="$TMP_ROOT/report-lock-data.snapshot"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  printf 'trail\n' > "$data/$id/account-attempts.md"
  fm_write_meta "$state/$id.meta" \
    "window=legacy:fm-$id" "project=$proj" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "report_required=1"
  printf 'status\n' > "$state/$id.status"
  printf 'turn\n' > "$state/$id.turn-ended"
  printf 'check\n' > "$state/$id.check.sh"
  printf 'extension\n' > "$state/$id.pi-ext.ts"
  printf 'token\n' > "$state/$id.grok-turnend-token"
  for suffix in account-native-launch account-native-ready account-native-go; do
    mkdir "$state/.$id.$suffix"
    printf 'sentinel\n' > "$state/.$id.$suffix/sentinel"
  done
  orca_case report-lock-refusal
  af_log="$CASE_DIR/agent-fleet.log"
  : > "$af_log"
  cat > "$FB/agent-fleet" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ORCA_AF_LOG:?}"
exit 1
SH
  chmod +x "$FB/agent-fleet"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$state" "$id") \
    || fail "report-required Orca fixture could not acquire its competing lifecycle lock"
  lock_identity=$(fm_account_lifecycle_lock_identity "$held") \
    || fail "report-required Orca fixture could not read its lifecycle lock identity"
  cp -R "$state" "$state_snapshot"
  cp -R "$data" "$data_snapshot"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_AF_LOG="$af_log" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "report-required Orca spawn bypassed its competing-lock refusal"
  assert_contains "$out" "no reliable endpoint-absence proof" \
    "report-required Orca spawn waited on the lifecycle lock instead of refusing in preflight"
  [ "$(fm_account_lifecycle_lock_identity "$held")" = "$lock_identity" ] \
    || fail "report-required Orca refusal changed the competing lifecycle lock identity"
  diff -r "$state_snapshot" "$state" >/dev/null \
    || fail "report-required Orca refusal changed task metadata, sidecars, or launch sentinels"
  diff -r "$data_snapshot" "$data" >/dev/null \
    || fail "report-required Orca refusal changed the task-owned account trail"
  [ ! -s "$af_log" ] || fail "report-required Orca refusal called Agent Fleet"
  [ ! -s "$LOG" ] || fail "report-required Orca refusal called its backend"
  fm_account_lifecycle_lock_release "$held" \
    || fail "report-required Orca fixture could not release its competing lifecycle lock"
  pass "report-required Orca preflight leaves competing lifecycle state byte-stable"
}

test_report_required_orca_recovery_preserves_inherited_lifecycle_state() {
  local data state config id out status held lock_identity state_snapshot data_snapshot af_log
  id="orcareportrecoveryz9"
  data="$TMP_ROOT/report-recovery-data"
  state="$TMP_ROOT/report-recovery-state"
  config="$TMP_ROOT/report-recovery-config"
  state_snapshot="$TMP_ROOT/report-recovery-state.snapshot"
  data_snapshot="$TMP_ROOT/report-recovery-data.snapshot"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  printf 'trail\n' > "$data/$id/account-attempts.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-$id" "worktree=$TMP_ROOT/missing-worktree" \
    "project=$TMP_ROOT/missing-project" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "report_required=1" "backend=orca" "account_pool=claude-crew" "account_profile=claude-1" \
    "account_task=fleet-$id" "account_attempt=attempt-$id" "provider_session_id=session-$id" \
    "account_rollback_cleanup=pending" "account_predecessor_cleanup=pending"
  printf 'status\n' > "$state/$id.status"
  printf 'turn\n' > "$state/$id.turn-ended"
  printf 'check\n' > "$state/$id.check.sh"
  printf 'extension\n' > "$state/$id.pi-ext.ts"
  printf 'token\n' > "$state/$id.grok-turnend-token"
  for suffix in account-native-launch account-native-ready account-native-go; do
    mkdir "$state/.$id.$suffix"
    printf 'sentinel\n' > "$state/.$id.$suffix/sentinel"
  done
  orca_case report-recovery-refusal
  af_log="$CASE_DIR/agent-fleet.log"
  : > "$af_log"
  cat > "$FB/agent-fleet" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_ORCA_AF_LOG:?}"
exit 1
SH
  chmod +x "$FB/agent-fleet"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$state" "$id") \
    || fail "report-required recovery fixture could not acquire its inherited lifecycle lock"
  lock_identity=$(fm_account_lifecycle_lock_identity "$held") \
    || fail "report-required recovery fixture could not read its inherited lifecycle lock identity"
  cp -R "$state" "$state_snapshot"
  cp -R "$data" "$data_snapshot"

  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_AF_LOG="$af_log" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$held" \
    "$ROOT/bin/fm-spawn.sh" "$id" --resume-account 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "report-required Orca recovery bypassed its inherited-lock refusal"
  assert_contains "$out" "no reliable endpoint-absence proof" \
    "report-required Orca recovery did not refuse before inherited-lock handoff"
  [ "$(fm_account_lifecycle_lock_identity "$held")" = "$lock_identity" ] \
    || fail "report-required Orca recovery changed the inherited lifecycle lock identity"
  diff -r "$state_snapshot" "$state" >/dev/null \
    || fail "report-required Orca recovery changed metadata, sidecars, or launch sentinels"
  diff -r "$data_snapshot" "$data" >/dev/null \
    || fail "report-required Orca recovery changed the task-owned account trail"
  [ ! -s "$af_log" ] || fail "report-required Orca recovery called Agent Fleet"
  [ ! -s "$LOG" ] || fail "report-required Orca recovery called its backend"
  fm_account_lifecycle_lock_release "$held" \
    || fail "report-required recovery fixture could not release its inherited lifecycle lock"
  pass "report-required Orca recovery leaves inherited lifecycle state byte-stable"
}

test_spawn_refuses_orca_secondmate_before_home_mutation() {
  local home subhome data state config id out status
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-refusal-home"
  subhome="$TMP_ROOT/secondmate-refusal-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$config/crew-harness"
  touch "$state/.last-watcher-beat"
  out=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "backend=orca --secondmate should be refused"
  assert_contains "$out" "backend=orca does not support --secondmate spawns yet" \
    "orca secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" \
    "orca secondmate refusal should not propagate inheritable config into the secondmate home"
  pass "fm-spawn.sh --backend orca --secondmate: refuses before secondmate-home mutation"
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
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
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

test_spawn_refuses_orca_without_verified_authority_capabilities() {
  local proj data state config id out status
  id="orcacapabilityz7"
  proj="$TMP_ROOT/capability-project"
  data="$TMP_ROOT/capability-data"
  state="$TMP_ROOT/capability-state"
  config="$TMP_ROOT/capability-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case capability-absence
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"

  out=$(env -u FM_ORCA_TEST_LAB -u FM_ORCA_TEST_AUTHORITY_CAPABILITIES \
    PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted Orca without verified lifecycle authority capabilities"
  assert_contains "$out" "Orca lifecycle authority is disabled" \
    "capability refusal did not explain the unsupported authority boundary"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "capability refusal reached Orca repository mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create' \
    "capability refusal reached Orca worktree creation"
  pass "Orca spawn fails closed when lifecycle authority capabilities are unavailable"
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
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_grep "backend=orca" "$state/$id.meta" "aborted Orca spawn did not retain cleanup metadata"
  assert_grep "orca_worktree_id=wt-bad" "$state/$id.meta" "aborted Orca spawn lost the unsafe provider worktree id"
  assert_grep "terminal=term-bad" "$state/$id.meta" "aborted Orca spawn lost the unsafe terminal handle"
  assert_grep "orca_cleanup_pending=1" "$state/$id.meta" "aborted Orca spawn did not remain quarantined"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn closed a terminal whose returned worktree was the primary checkout"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "Orca spawn removed a provider worktree whose isolation was unproven"
  pass "fm-spawn.sh --backend orca: quarantines non-isolated worktree responses"
}

test_spawn_quarantines_unrelated_orca_worktree() {
  local proj unrelated data state config id out status
  id="orcaunrelatedz5"
  proj="$TMP_ROOT/unrelated-source-project"
  unrelated="$TMP_ROOT/unrelated-provider-worktree"
  data="$TMP_ROOT/unrelated-data"
  state="$TMP_ROOT/unrelated-state"
  config="$TMP_ROOT/unrelated-config"
  fm_git_init_commit "$proj"
  fm_git_init_commit "$unrelated"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case unrelated-worktree
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-unrelated"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-unrelated","path":"%s"},"terminal":{"handle":"term-unrelated"}}}\n' \
    "$unrelated" > "$RESP/3.out"

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted an Orca worktree from an unrelated repository"
  assert_contains "$out" "returned a worktree from an unrelated repository" \
    "unrelated Orca repository identity was not surfaced"
  assert_grep "orca_worktree_id=wt-unrelated" "$state/$id.meta" \
    "unrelated Orca worktree identity was not quarantined"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "spawn closed a terminal attached to an unrelated repository"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "spawn removed an unrelated provider worktree"
  pass "Orca spawn quarantines unrelated provider worktrees"
}

test_spawn_quarantines_unbound_orca_terminal() {
  local proj wt data state config id out status
  id="orcaunboundtermz6"
  proj="$TMP_ROOT/unbound-terminal-project"
  wt="$TMP_ROOT/unbound-terminal-wt"
  data="$TMP_ROOT/unbound-terminal-data"
  state="$TMP_ROOT/unbound-terminal-state"
  config="$TMP_ROOT/unbound-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case unbound-terminal
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-unbound"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-unbound","path":"%s"},"terminal":{"handle":"term-unbound"}}}\n' \
    "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-unbound","name":"fm-%s","path":"%s","terminals":[{"handle":"term-unbound","title":"fm-%s"}]}}}\n' \
    "$id" "$wt" "$id" > "$RESP/4.out"
  printf 'fm-another-task\n' > "$RESP/.terminal-title"
  printf 'wt-unbound\n' > "$RESP/.terminal-worktree-override"

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a terminal not bound to its expected task"
  assert_contains "$out" "terminal is not authoritatively bound" \
    "unbound Orca terminal authority was not surfaced"
  assert_grep "terminal=term-unbound" "$state/$id.meta" \
    "unbound Orca terminal was not retained in quarantine"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send' \
    "spawn sent launch commands through an unbound terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "spawn closed a terminal whose task binding was unproven"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "spawn removed a worktree while terminal authority was unproven"
  pass "Orca spawn quarantines terminals without task authority"
}

test_spawn_quarantines_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/4.out"
  printf '1\n' > "$RESP/5.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_grep "window=fm-$id" "$state/$id.meta" "terminal-create abort must retain the cleanup alias"
  assert_grep "backend=orca" "$state/$id.meta" "terminal-create abort should retain Orca cleanup metadata"
  assert_grep "orca_worktree_id=wt-terminal-fail" "$state/$id.meta" "terminal-create abort should retain the Orca worktree id"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail' \
    "Orca spawn did not remove the exact empty worktree after proving terminal absence"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  assert_grep 'orca_cleanup_pending=1' "$state/$id.meta" \
    "ambiguous terminal creation did not retain its cleanup quarantine record"
  pass "fm-spawn.sh --backend orca: removes an exact empty worktree after ambiguous terminal creation"
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
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "Orca spawn removed a worktree while terminal absence was unknown"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_retains_orca_worktree_when_abort_close_fails() {
  local proj data state config id out status
  id="orcaabortclosez4"
  proj="$TMP_ROOT/abort-close-project"
  data="$TMP_ROOT/abort-close-data"
  state="$TMP_ROOT/abort-close-state"
  config="$TMP_ROOT/abort-close-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case abort-close-failure
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-abort-close"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-abort-close","path":"%s"},"terminal":{"handle":"term-abort-close"}}}\n' "$proj" > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"terminal_close_failed","message":"terminal close failed"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail after non-isolated worktree creation"
  assert_contains "$out" "retaining Orca cleanup metadata" \
    "abort close failure did not surface durable retention"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "abort cleanup removed an Orca worktree after terminal close failed"
  assert_grep 'terminal=term-abort-close' "$state/$id.meta" \
    "abort close failure did not preserve terminal identity"
  assert_grep 'orca_worktree_id=wt-abort-close' "$state/$id.meta" \
    "abort close failure did not preserve worktree identity"
  assert_grep 'orca_cleanup_pending=1' "$state/$id.meta" \
    "abort close failure did not mark durable cleanup state"
  assert_no_grep 'report_required=' "$state/$id.meta" \
    "abort close failure changed the legacy report contract"
  pass "Orca abort cleanup retains worktrees until terminal absence is proven"
}

test_teardown_rejects_symlinked_orca_task_metadata() {
  local state data config neutral out status
  state="$TMP_ROOT/orca-meta-alias-state"
  data="$TMP_ROOT/orca-meta-alias-data"
  config="$TMP_ROOT/orca-meta-alias-config"
  mkdir -p "$state" "$data" "$config"
  fm_write_meta "$state/bar.meta" \
    'window=fm-bar' 'terminal=term-bar' 'worktree=/missing/bar' 'project=/missing/project' \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'backend=orca' 'orca_worktree_id=wt-bar'
  ln -s bar.meta "$state/foo.meta"
  orca_case teardown-meta-alias
  neutral=$(neutral_fm_root "$CASE_DIR/meta-alias-neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" foo --force 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "symlinked Orca task metadata was accepted"
  assert_contains "$out" "task metadata must be a real readable file for foo" \
    "symlinked Orca task metadata was not diagnosed"
  assert_present "$state/foo.meta" "symlinked task metadata was removed"
  assert_present "$state/bar.meta" "aliased task metadata target was removed"
  [ ! -s "$LOG" ] || fail "symlinked Orca task metadata reached backend mutation"
  pass "Orca teardown binds real metadata to the requested task"
}

test_spawn_refuses_invalid_state_before_orca_resource_creation() {
  local proj data state_file config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  data="$TMP_ROOT/meta-fail-data"
  state_file="$TMP_ROOT/meta-fail-state-file"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$config"
  : > "$state_file"
  printf 'brief\n' > "$data/$id/brief.md"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state_file" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when the state path is not a directory"
  assert_contains "$out" "state directory must be a real directory" \
    "spawn should reject unsafe state during read-only preflight"
  assert_not_contains "$out" "account lifecycle lock" \
    "unsafe state validation should not attempt lifecycle-lock acquisition"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "invalid local state should be rejected before Orca repository mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree' \
    "invalid local state should be rejected before Orca worktree mutation"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal' \
    "invalid local state should be rejected before Orca terminal mutation"
  pass "fm-spawn.sh --backend orca: invalid state refuses before resource creation"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
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
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f''hello orca'$'\x1f''--json' \
    "send did not type through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit Enter through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
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
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
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
    "window=fm-$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown"
  orca_case teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown' \
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
    "window=fm-$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch"
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
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

test_teardown_refuses_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path"
  orca_case missing-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse when its worktree path is absent"
  assert_contains "$out" "teardown worktree metadata is not an exact inspectable repository root" \
    "pathless Orca teardown should surface the unprovable target identity"
  [ ! -s "$LOG" ] || fail "pathless Orca teardown should not close a terminal or remove a worktree"
  assert_present "$state/$id.meta" "pathless Orca teardown should preserve task metadata"
  pass "fm-teardown.sh backend=orca: refuses pathless provider removal"
}

test_teardown_preserves_metadata_when_orca_remove_error_json() {
  local proj wt data state config id out rc neutral
  id="orcaremoveerrz2"
  proj="$TMP_ROOT/remove-error-project"
  wt="$TMP_ROOT/remove-error-wt"
  data="$TMP_ROOT/remove-error-data"
  state="$TMP_ROOT/remove-error-state"
  config="$TMP_ROOT/remove-error-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-remove-error" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-error"
  orca_case remove-error-teardown
  printf '{"ok":true,"result":{"worktree":{"id":"wt-remove-error","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_REMOVE_ERROR=1 \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
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
    "window=fm-$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
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
    "window=fm-$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship"
  orca_case missing-ship-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "teardown worktree metadata is not an exact inspectable repository root" \
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
    "window=fm-$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match"
  orca_case ship-match
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match' \
    "teardown did not remove the matched Orca worktree"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path"
}

test_ship_teardown_rejects_orca_mounted_removal_root() {
  local proj wt data state config id out rc neutral
  id="orcamountedrootz6"
  proj="$TMP_ROOT/mounted-root-project"
  wt="$TMP_ROOT/mounted-root-wt"
  data="$TMP_ROOT/mounted-root-data"
  state="$TMP_ROOT/mounted-root-state"
  config="$TMP_ROOT/mounted-root-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-mounted-root" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-mounted-root"
  orca_case mounted-root
  printf '{"ok":true,"result":{"worktree":{"id":"wt-mounted-root","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$config" FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
    FM_TEARDOWN_TEST_MOUNT_PATH="$wt" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  rc=$?
  expect_code 1 "$rc" "mounted Orca worktree root must block provider removal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "mounted Orca worktree reached provider removal"
  assert_present "$state/$id.meta" "mounted Orca worktree removed retry metadata"
  assert_contains "$out" "crosses an untrusted filesystem boundary" \
    "mounted Orca worktree was not surfaced"
  pass "Orca removal rejects mounted worktree roots"
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
    "window=fm-$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved'$'\x1f''--json' \
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
    "window=fm-$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch'$'\x1f''--json' \
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
    "window=fm-$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca"
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
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
    "window=fm-$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal"
  orca_case no-terminal
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-terminal","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse when terminal identity is missing"
  assert_contains "$out" "missing terminal" \
    "missing Orca terminal identity was not surfaced"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "teardown removed an Orca worktree without proving endpoint absence"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "teardown should not close a terminal when no terminal handle is recorded"
  assert_present "$state/$id.meta" "unknown Orca endpoint state should retain metadata"
  pass "fm-teardown.sh backend=orca: refuses unquiesced partial metadata"
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
  orca_case secondmate-child-cleanup
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  initialize_secondmate_project_repo "$home" "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup","name":"fm-%s","path":"%s","terminals":[{"handle":"term-child-cleanup","title":"fm-%s"}]}}}\n' \
    "$child_id" "$childwt" "$child_id" > "$RESP/1.out"
  printf 'fm-%s\n' "$child_id" > "$RESP/.terminal-title"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ORCA_REMOVE_LOCAL_PATH="$childwt" FM_ORCA_REMOVE_LOCAL_PROJECT="$childproj" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup' \
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
  orca_case secondmate-child-mismatch
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  initialize_secondmate_project_repo "$home" "$childproj" "$childwt" "fm/$child_id"
  mkdir -p "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
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

test_secondmate_force_teardown_retains_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  orca_case secondmate-partial-child-cleanup
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  initialize_secondmate_project_repo "$home" "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-partial-child","path":"%s"}}}\n' "$childwt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  initialize_secondmate_home_repo "$subhome" "$neutral"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse partial Orca child state"
  assert_contains "$out" "child Orca endpoint authority or quiescence is unproven for $child_id" \
    "partial Orca child refusal did not surface missing endpoint identity"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "partial child cleanup removed an Orca worktree without quiescence proof"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "partial child cleanup should not close a terminal when no terminal handle is recorded"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: retains partial Orca secondmate children"
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

test_spawn_refuses_cleanup_pending_orca_task_before_mutation() {
  local proj data state config id out status
  id="orcacleanupblockz9"
  proj="$TMP_ROOT/cleanup-block-project"
  data="$TMP_ROOT/cleanup-block-data"
  state="$TMP_ROOT/cleanup-block-state"
  config="$TMP_ROOT/cleanup-block-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "project=$proj" "harness=claude" "kind=ship" "mode=local-only" \
    "backend=orca" "orca_worktree_id=wt-retained" "terminal=term-retained" \
    "orca_cleanup_pending=1" "orca_cleanup_phase=spawn-abort" "orca_terminal_proof=recorded"
  orca_case cleanup-pending-block

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn reused an Orca cleanup quarantine"
  assert_contains "$out" "Orca cleanup is pending for $id" \
    "cleanup-pending spawn refusal did not explain the supported cleanup path"
  assert_grep 'orca_worktree_id=wt-retained' "$state/$id.meta" \
    "cleanup-pending spawn overwrote the retained worktree identity"
  [ ! -s "$LOG" ] || fail "cleanup-pending spawn reached Orca mutation"
  pass "Orca cleanup quarantine blocks respawn without identity loss"
}

test_pathless_orca_quarantine_has_supported_cleanup() {
  local proj wt data state config id out status neutral
  id="orcapathcleanupz7"
  proj="$TMP_ROOT/path-cleanup-project"
  wt="$TMP_ROOT/path-cleanup-wt"
  data="$TMP_ROOT/path-cleanup-data"
  state="$TMP_ROOT/path-cleanup-state"
  config="$TMP_ROOT/path-cleanup-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "project=$proj" "harness=claude" "kind=ship" "mode=local-only" \
    "backend=orca" "orca_worktree_id=wt-path-cleanup" "terminal=term-path-cleanup" \
    "orca_cleanup_pending=1" "orca_cleanup_phase=spawn-abort" "orca_terminal_proof=recorded" \
    "orca_expected_task=fm-$id"
  orca_case pathless-supported-cleanup
  printf '{"ok":true,"result":{"worktree":{"id":"wt-path-cleanup","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$CASE_DIR/checkout-state" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  expect_code 0 "$status" "pathless Orca quarantine cleanup"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-path-cleanup' \
    "pathless quarantine cleanup did not quiesce the retained terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-path-cleanup' \
    "pathless quarantine cleanup did not remove the retained provider worktree"
  assert_absent "$state/$id.meta" "successful pathless quarantine cleanup retained metadata"
  pass "pathless Orca quarantine has a supported cleanup path"
}

test_idless_orca_quarantine_refuses_unscoped_terminal_close() {
  local proj data state config id out status neutral
  id="orcaidlesscleanupz4"
  proj="$TMP_ROOT/idless-cleanup-project"
  data="$TMP_ROOT/idless-cleanup-data"
  state="$TMP_ROOT/idless-cleanup-state"
  config="$TMP_ROOT/idless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "project=$proj" "harness=claude" "kind=ship" "mode=local-only" \
    "backend=orca" "terminal=term-idless" \
    "orca_cleanup_pending=1" "orca_cleanup_phase=spawn-abort" "orca_terminal_proof=recorded" \
    "orca_expected_task=fm-$id" "orca_discovery_label=fm-$id" "orca_provider_scope=repo-path:$proj"
  orca_case idless-unscoped-cleanup
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "idless Orca quarantine closed an unscoped terminal"
  assert_contains "$out" "refusing to close an unscoped terminal" \
    "idless Orca quarantine did not surface its missing worktree authority"
  [ ! -s "$LOG" ] || fail "idless Orca quarantine reached provider mutation"
  assert_present "$state/$id.meta" "idless Orca quarantine removed retained metadata"
  pass "idless Orca quarantines retain unscoped terminals"
}

test_teardown_refuses_orca_terminal_worktree_identity_drift() {
  local proj wt data state config id out status neutral
  id="orcatermdriftz5"
  proj="$TMP_ROOT/terminal-drift-project"
  wt="$TMP_ROOT/terminal-drift-wt"
  data="$TMP_ROOT/terminal-drift-data"
  state="$TMP_ROOT/terminal-drift-state"
  config="$TMP_ROOT/terminal-drift-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-terminal-drift" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "backend=orca" \
    "orca_worktree_id=wt-terminal-drift"
  orca_case terminal-worktree-drift
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-drift","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  printf 'wt-other\n' > "$RESP/.terminal-worktree-override"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "teardown closed a terminal bound to another Orca worktree"
  assert_contains "$out" "task Orca endpoint authority or quiescence is unproven" \
    "terminal/worktree identity drift was not surfaced"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "terminal/worktree identity drift closed the recorded terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "terminal/worktree identity drift removed the provider worktree"
  assert_present "$state/$id.meta" "terminal/worktree identity drift removed metadata"
  pass "Orca teardown rejects terminal/worktree identity drift"
}

test_spawn_quarantines_create_response_without_worktree_id() {
  local proj data state config id out status
  id="orcapartialidz8"
  proj="$TMP_ROOT/partial-id-project"
  data="$TMP_ROOT/partial-id-data"
  state="$TMP_ROOT/partial-id-state"
  config="$TMP_ROOT/partial-id-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case partial-create-id
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-partial-id"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"path":"%s"},"terminal":{"handle":"term-partial-id"}}}\n' "$proj" > "$RESP/3.out"

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted an Orca create response without a worktree id"
  assert_grep "worktree=$proj" "$state/$id.meta" \
    "partial create quarantine dropped the returned worktree path"
  assert_grep 'terminal=term-partial-id' "$state/$id.meta" \
    "partial create quarantine dropped the returned terminal"
  assert_grep 'orca_repo_id=repo-partial-id' "$state/$id.meta" \
    "partial create quarantine dropped the returned repo identity"
  assert_grep "orca_expected_task=fm-$id" "$state/$id.meta" \
    "partial create quarantine dropped expected task identity"
  assert_grep "orca_discovery_label=fm-$id" "$state/$id.meta" \
    "partial create quarantine dropped the discovery label"
  assert_grep "orca_provider_scope=repo-path:$proj" "$state/$id.meta" \
    "partial create quarantine dropped the provider scope"
  assert_no_grep '^orca_worktree_id=' "$state/$id.meta" \
    "partial create quarantine invented a missing worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "spawn closed a partial-response terminal without worktree authority"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "spawn removed a partial-response worktree without provider id"
  pass "Orca partial create responses retain every available identity"
}

test_orca_quarantine_write_failure_keeps_prearmed_blocker() {
  local proj data state config id out status
  id="orcaquarantinewritez2"
  proj="$TMP_ROOT/quarantine-write-project"
  data="$TMP_ROOT/quarantine-write-data"
  state="$TMP_ROOT/quarantine-write-state"
  config="$TMP_ROOT/quarantine-write-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case quarantine-write-failure
  seed_legacy_task_meta "$state" "$id" "$proj"
  add_dead_tmux_fake "$FB"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-quarantine-write"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-quarantine-write","path":"%s"}}}\n' "$proj" > "$RESP/3.out"

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ORCA_QUARANTINE_STATE_READONLY=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?
  chmod 700 "$state"

  [ "$status" -ne 0 ] || fail "spawn ignored an Orca quarantine update failure"
  assert_grep 'orca_cleanup_pending=1' "$state/$id.meta" \
    "quarantine write failure lost the pre-armed retry blocker"
  assert_grep 'orca_cleanup_phase=spawn-preparing' "$state/$id.meta" \
    "quarantine write failure replaced the durable pre-create phase"
  assert_grep "orca_discovery_label=fm-$id" "$state/$id.meta" \
    "quarantine write failure lost the pre-armed discovery label"
  assert_grep "orca_provider_scope=repo-path:$proj" "$state/$id.meta" \
    "quarantine write failure lost the pre-armed provider scope"
  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --backend orca 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn reused a task after quarantine publication failed"
  assert_contains "$out" "Orca cleanup is pending for $id" \
    "pre-armed quarantine did not block retry"
  pass "Orca quarantine publication failures retain a durable retry blocker"
}

test_teardown_rejects_cross_task_orca_terminal_label() {
  local proj wt data state config id out status neutral
  id="orcacrosstaskz4"
  proj="$TMP_ROOT/cross-task-project"
  wt="$TMP_ROOT/cross-task-wt"
  data="$TMP_ROOT/cross-task-data"
  state="$TMP_ROOT/cross-task-state"
  config="$TMP_ROOT/cross-task-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-cross-task" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "backend=orca" \
    "orca_worktree_id=wt-cross-task"
  orca_case cross-task-terminal
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cross-task","path":"%s"}}}\n' "$wt" > "$RESP/1.out"
  printf 'fm-other-task\n' > "$RESP/.terminal-title"
  printf 'wt-cross-task\n' > "$RESP/.terminal-worktree-override"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "teardown accepted a terminal labeled for another task"
  assert_contains "$out" "task Orca endpoint authority or quiescence is unproven" \
    "cross-task Orca terminal drift was not surfaced"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "cross-task Orca terminal drift closed another task"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "cross-task Orca terminal drift removed the provider worktree"
  pass "Orca teardown binds terminals to the expected task label"
}

test_teardown_rejects_cross_task_orca_worktree_label() {
  local proj wt data state config id out status neutral
  id="orcaworktreetaskz7"
  proj="$TMP_ROOT/worktree-task-project"
  wt="$TMP_ROOT/worktree-task-wt"
  data="$TMP_ROOT/worktree-task-data"
  state="$TMP_ROOT/worktree-task-state"
  config="$TMP_ROOT/worktree-task-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-worktree-task" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "backend=orca" \
    "orca_worktree_id=wt-worktree-task"
  orca_case cross-task-worktree
  printf '{"ok":true,"result":{"worktree":{"id":"wt-worktree-task","name":"fm-other-task","path":"%s","terminals":[{"handle":"term-worktree-task","title":"fm-%s"}]}}}\n' \
    "$wt" "$id" > "$RESP/1.out"
  printf "fm-%s\n" "$id" > "$RESP/.terminal-title"
  printf 'wt-worktree-task\n' > "$RESP/.terminal-worktree-override"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "teardown accepted an Orca worktree labeled for another task"
  assert_contains "$out" "task Orca endpoint authority or quiescence is unproven" \
    "cross-task Orca worktree drift was not surfaced"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "cross-task Orca worktree drift closed a terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "cross-task Orca worktree drift removed the provider worktree"
  pass "Orca teardown binds worktrees to the expected task label"
}

test_teardown_quiesces_unrecorded_orca_terminals() {
  local proj wt data state config id out status neutral
  id="orcaunrecordedz3"
  proj="$TMP_ROOT/unrecorded-project"
  wt="$TMP_ROOT/unrecorded-wt"
  data="$TMP_ROOT/unrecorded-data"
  state="$TMP_ROOT/unrecorded-state"
  config="$TMP_ROOT/unrecorded-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-recorded-stale" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "backend=orca" \
    "orca_worktree_id=wt-unrecorded"
  orca_case unrecorded-terminal
  printf '{"ok":true,"result":{"worktree":{"id":"wt-unrecorded","path":"%s","terminals":[{"handle":"term-unrecorded","title":"fm-%s"}]}}}\n' \
    "$wt" "$id" > "$RESP/1.out"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  printf '1\n' > "$RESP/2.exit"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  printf '1\n' > "$RESP/4.exit"
  printf "fm-%s\n" "$id" > "$RESP/.terminal-title"
  printf 'wt-unrecorded\n' > "$RESP/.terminal-worktree-override"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?

  expect_code 0 "$status" "unrecorded Orca terminal cleanup"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-unrecorded' \
    "teardown did not quiesce the unrecorded terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-unrecorded' \
    "teardown did not remove the terminal-free worktree"
  pass "Orca teardown quiesces every terminal attached to the worktree"
}

test_teardown_rejects_live_recorded_terminal_missing_from_inventory() {
  local proj wt data state config id out status neutral
  id="orcaomittedterminalz8"
  proj="$TMP_ROOT/omitted-terminal-project"
  wt="$TMP_ROOT/omitted-terminal-wt"
  data="$TMP_ROOT/omitted-terminal-data"
  state="$TMP_ROOT/omitted-terminal-state"
  config="$TMP_ROOT/omitted-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "terminal=term-omitted" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "backend=orca" \
    "orca_worktree_id=wt-omitted"
  orca_case omitted-live-terminal
  printf '{"ok":true,"result":{"worktree":{"id":"wt-omitted","name":"fm-%s","path":"%s","terminals":[]}}}\n' \
    "$id" "$wt" > "$RESP/1.out"
  printf "fm-%s\n" "$id" > "$RESP/.terminal-title"
  printf 'wt-omitted\n' > "$RESP/.terminal-worktree-override"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")

  out=$(PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "teardown accepted a live recorded terminal omitted from the worktree inventory"
  assert_contains "$out" "task Orca endpoint authority or quiescence is unproven" \
    "recorded-terminal inventory disagreement was not surfaced"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "inventory disagreement closed the recorded terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "inventory disagreement removed the provider worktree"
  assert_present "$state/$id.meta" "inventory disagreement removed task metadata"
  pass "Orca teardown rejects a live recorded terminal omitted from inventory"
}

if [ "${FM_TEST_FOCUSED:-}" = review-round-orca-quiescence ]; then
  test_kill_propagates_close_failure
  test_terminal_state_classifies_closed_live_and_ambiguous_orca
  test_scout_teardown_removes_orca_worktree_via_helper
  test_teardown_refuses_orca_worktree_without_terminal_handle
  test_secondmate_force_teardown_removes_orca_child_via_orca
  test_secondmate_force_teardown_retains_partial_orca_child
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-orca-final ]; then
  test_worktree_create_retains_partial_authority_when_path_missing
  test_worktree_create_never_cleans_partial_response_inline
  test_spawn_refuses_malformed_legacy_orca_report_metadata
  test_spawn_retains_orca_worktree_when_abort_close_fails
  test_teardown_rejects_symlinked_orca_task_metadata
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-orca-quarantine ]; then
  test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
  test_spawn_quarantines_orca_worktree_when_terminal_create_fails
  test_spawn_refuses_cleanup_pending_orca_task_before_mutation
  test_pathless_orca_quarantine_has_supported_cleanup
  test_teardown_refuses_orca_terminal_worktree_identity_drift
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-orca-authority ]; then
  test_spawn_refuses_orca_without_verified_authority_capabilities
  test_worktree_create_retains_partial_authority_when_path_missing
  test_spawn_refuses_orca_nonisolated_worktree
  test_spawn_quarantines_unrelated_orca_worktree
  test_spawn_quarantines_unbound_orca_terminal
  test_spawn_quarantines_create_response_without_worktree_id
  test_orca_quarantine_write_failure_keeps_prearmed_blocker
  test_idless_orca_quarantine_refuses_unscoped_terminal_close
  test_teardown_rejects_cross_task_orca_terminal_label
  test_teardown_rejects_cross_task_orca_worktree_label
  test_teardown_quiesces_unrecorded_orca_terminals
  test_teardown_rejects_live_recorded_terminal_missing_from_inventory
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13-safety ]; then
  test_ship_teardown_rejects_orca_mounted_removal_root
  test_remove_worktree_requires_bound_provider_capability
  exit 0
fi

test_capture_reads_terminal_tail_json
test_capture_falls_back_to_text_fields
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_keeps_current_tail_when_limited
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
test_kill_propagates_close_failure
test_terminal_state_classifies_closed_live_and_ambiguous_orca
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_remove_worktree_requires_bound_provider_capability
test_worktree_path_resolves_id
test_dispatcher_sources_orca_and_routes_primitives
test_spawn_refuses_cleanup_pending_orca_task_before_mutation
test_pathless_orca_quarantine_has_supported_cleanup
test_teardown_refuses_orca_terminal_worktree_identity_drift
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_retains_partial_authority_when_path_missing
test_worktree_create_never_cleans_partial_response_inline
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_legacy_respawn_refuses_without_provider_task_authority
test_spawn_refuses_new_report_required_orca_task_before_mutation
test_spawn_refuses_orca_respawn_of_report_required_task
test_spawn_refuses_malformed_legacy_orca_report_metadata
test_spawn_refuses_report_required_orca_batch_pair_before_mutation
test_report_required_orca_refusal_preserves_competing_lifecycle_state
test_report_required_orca_recovery_preserves_inherited_lifecycle_state
test_spawn_refuses_orca_secondmate_before_home_mutation
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_without_verified_authority_capabilities
# docs/orca-backend.md "Eligibility" disables Orca spawn and destructive
# lifecycle work; their retained reference cases run only through focused modes.
test_peek_send_and_crew_state_route_through_orca_meta
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
