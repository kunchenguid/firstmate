#!/usr/bin/env bash
# Tests for bin/fm-runtime-handoff.sh and fm-spawn.sh --reuse-worktree.
#
# Guarantees under test (behavior through the public scripts, not source bytes):
#   - successful handoff preserves commits and uncommitted changes in the
#     recorded worktree and does not call treehouse get/return
#   - state/<id>.meta harness= (and model/effort when supplied) update while
#     non-owned keys such as pr= are preserved
#   - handoff refuses when the worktree cannot be reconciled
#   - handoff refuses when the endpoint is still alive / ownership is ambiguous
#   - handoff refuses an unverified target harness, an unknown option, and a
#     --backend that differs from the recorded one, all before any exit
#   - the verified-exit path really runs: the recorded harness's exit command is
#     delivered, the endpoint remains available once dead, and a harness that ignores it refuses
#   - batch dispatch refuses --reuse-worktree instead of dropping it
#   - statusline quota parse: unparseable => unknown, never exhausted, a
#     context-window reading never decides low/exhausted, and only the
#     statusline region of a capture votes - never the transcript above it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-runtime-handoff.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# shellcheck source=bin/fm-statusline-quota-lib.sh
. "$ROOT/bin/fm-statusline-quota-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-runtime-handoff)
fm_git_identity

# --- helpers ----------------------------------------------------------------

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# Record every invocation for assertions.
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    # FM_FAKE_EXIT_MARKER models a harness that actually quit on its exit
    # command: once the marker exists the pane is back at a plain shell.
    if [ -n "${FM_FAKE_EXIT_MARKER:-}" ] && [ -f "${FM_FAKE_EXIT_MARKER}" ]; then
      printf 'bash\n'
    else
      printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}"
    fi
    exit 0
    ;;
  *"list-windows"*)
    # Both create_task and agent_state inventory use window_name lines.
    # Present = print the bare window name; absent = empty.
    # FM_FAKE_WINDOW_FILE makes presence mutable so kill-window can remove it.
    if [ -n "${FM_FAKE_WINDOW_FILE:-}" ]; then
      if [ -f "${FM_FAKE_WINDOW_FILE}" ]; then
        printf '%s\n' "${FM_FAKE_EXISTING_WINDOW:-${FM_FAKE_WINDOW_NAME:-fm-task}}"
      fi
    elif [ "${FM_FAKE_WINDOW_PRESENT:-0}" = 1 ] || [ -n "${FM_FAKE_EXISTING_WINDOW:-}" ]; then
      printf '%s\n' "${FM_FAKE_EXISTING_WINDOW:-${FM_FAKE_WINDOW_NAME:-fm-task}}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  kill-window)
    [ -z "${FM_FAKE_WINDOW_FILE:-}" ] || rm -f "$FM_FAKE_WINDOW_FILE"
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#S'*) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ;;
      *'#{pane_id}'*) printf '%%1\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_PANE_CMD:-bash}" ;;
      *) printf '%s\n' "${FM_FAKE_SESSION:-firstmate}" ;;
    esac
    exit 0
    ;;
  has-session|new-session|set-window-option|send-keys) exit 0 ;;
  new-window)
    # -P -F '#{window_id}'
    printf '@9\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  # treehouse must NOT be called for a successful reuse/handoff.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
printf '%s\n' "${HOME:-}" >> "${FM_FAKE_TREEHOUSE_HOMELOG:-/dev/null}"
case "${1:-}" in
  get)
    printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:-}"
    exit 0
    ;;
  return) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  printf '%s\n' "$fakebin"
}

# make_bin_farm <case-dir>: a bin/ directory of symlinks to the REAL scripts with
# only fm-send.sh replaced by a stub. fm-runtime-handoff.sh invokes fm-send.sh by
# "$SCRIPT_DIR/fm-send.sh" (absolute sibling path), so a PATH stub can never
# intercept it; running the handoff out of this farm can. Everything else stays
# the shipped code, so the exit path under test is the real one.
make_bin_farm() {
  local dir=$1 src farm
  farm="$dir/binfarm"
  mkdir -p "$farm/backends" "$farm/quota-sources"
  for src in "$ROOT"/bin/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/${src##*/}"
  done
  for src in "$ROOT"/bin/backends/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/backends/${src##*/}"
  done
  for src in "$ROOT"/bin/quota-sources/*; do
    [ -f "$src" ] || continue
    ln -sf "$src" "$farm/quota-sources/${src##*/}"
  done
  rm -f "$farm/fm-send.sh"   # never write THROUGH a symlink into the real bin/
  cat > "$farm/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SEND_LOG:-/dev/null}"
# Only mark the harness as exited when the case asks for a compliant harness.
[ -z "${FM_FAKE_SEND_MARKS_EXIT:-}" ] || : > "$FM_FAKE_SEND_MARKS_EXIT"
exit 0
SH
  chmod +x "$farm/fm-send.sh"
  printf '%s\n' "$farm"
}

# setup_case <name> <id> [harness]: home + project + worktree with a commit and dirty file.
# Sets CASE_DIR, CASE_HOME, CASE_PROJ, CASE_WT and exports FM_HOME + fake env
# in the CALLING shell (must not be run under command substitution).
setup_case() {
  local name=$1 id=$2 harness=${3:-codex} fakebin
  CASE_DIR="$TMP_ROOT/$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJ="$CASE_DIR/project"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/data/$id" "$CASE_HOME/config" "$CASE_HOME/projects"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "fm/$id"
  # Extra landed commit on the task branch + uncommitted change.
  printf 'commit-body\n' > "$CASE_WT/feature.txt"
  git -C "$CASE_WT" add feature.txt
  git -C "$CASE_WT" commit -qm 'task work'
  printf 'uncommitted\n' > "$CASE_WT/dirty.txt"
  printf '# brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  fakebin=$(make_fakebin "$CASE_DIR")
  export FM_HOME="$CASE_HOME"
  export FM_FAKE_PANE_PATH="$CASE_WT"
  export FM_FAKE_TREEHOUSE_WT="$CASE_WT"
  export FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  export FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log"
  export FM_FAKE_SEND_LOG="$CASE_DIR/send.log"
  export FM_FAKE_SESSION=firstmate
  export FM_FAKE_WINDOW_NAME="fm-$id"
  export FM_FAKE_WINDOW_PRESENT=0
  export FM_FAKE_PANE_CMD=bash
  export FM_FAKE_EXISTING_WINDOW=
  # Mutable-endpoint knobs stay off unless a case opts in (exports persist
  # across cases in this shell, so reset them every time).
  export FM_FAKE_WINDOW_FILE=
  export FM_FAKE_EXIT_MARKER=
  export FM_FAKE_SEND_MARKS_EXIT=
  export PATH="$fakebin:$PATH"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=$harness" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-test-$id" \
    "model=default" \
    "effort=default" \
    "pr=https://example.test/pr/1" \
    "pr_head=abc123"
}

# --- statusline quota parser ------------------------------------------------

{
  v=$(fm_statusline_quota_verdict 'garbage not a statusline')
  [ "$v" = unknown ] || fail "unparseable statusline must be unknown, got $v"
  pass "unparseable statusline => unknown (never exhausted)"
}

{
  v=$(fm_statusline_quota_verdict 'Context 100% left · weekly 21% left')
  [ "$v" = ok ] || fail "healthy codex statusline should be ok, got $v"
  pass "codex healthy statusline => ok"
}

{
  v=$(fm_statusline_quota_verdict 'Context 5% left · weekly 3% left')
  [ "$v" = low ] || fail "low codex statusline should be low, got $v"
  pass "codex low statusline => low"
}

{
  v=$(fm_statusline_quota_verdict 'weekly 0% left')
  [ "$v" = exhausted ] || fail "zero weekly should be exhausted, got $v"
  pass "codex zero weekly => exhausted"
}

{
  v=$(fm_statusline_quota_verdict '5HR 3% ↻2150 WK 5% ↻SAT@0100 SUB')
  [ "$v" = low ] || fail "claude low statusline should be low, got $v"
  pass "claude low statusline => low"
}

{
  v=$(fm_statusline_quota_verdict '5HR 0% WK 40%')
  [ "$v" = exhausted ] || fail "claude zero 5HR should be exhausted, got $v"
  pass "claude zero 5hr => exhausted"
}

{
  v=$(fm_statusline_quota_verdict 'Context 0% left · weekly 80% left')
  [ "$v" = ok ] || fail "spent context with healthy weekly quota should be ok, got $v"
  pass "zero context with healthy weekly => ok (context never votes)"
}

{
  v=$(fm_statusline_quota_verdict 'Context 5% left · weekly 90% left')
  [ "$v" = ok ] || fail "low context with healthy weekly should be ok, got $v"
  pass "low context with healthy weekly => ok"
}

{
  v=$(fm_statusline_quota_verdict 'Context 0% left')
  [ "$v" = unknown ] || fail "context-only statusline carries no quota window, got $v"
  pass "context-only statusline => unknown (never exhausted)"
}

{
  line=$(fm_statusline_quota_parse 'Context 40% left · weekly 3% left')
  assert_contains "$line" "context_pct=40" "context stays a reported field"
  assert_contains "$line" "status=low" "weekly alone drives the status"
  pass "context_pct is reported but informational"
}

# A pane capture is mostly transcript. Only the statusline region may vote, or a
# crewmate that merely printed these shapes reads as exhausted.
{
  capture=$(printf '%s\n' \
    '+  fail "zero weekly should be exhausted, got weekly 0% left"' \
    '+  pass "claude zero 5hr => exhausted"    # 5HR 0% WK 40%' \
    '' \
    '> ' \
    'Context 90% left · weekly 80% left')
  v=$(fm_statusline_quota_verdict "$capture")
  [ "$v" = ok ] || fail "transcript above the statusline must not vote, got $v"
  line=$(fm_statusline_quota_parse "$capture")
  assert_contains "$line" "weekly_pct=80" "statusline row owns the weekly value"
  pass "transcript scrollback never decides the verdict"
}

{
  capture=$(printf '%s\n' \
    'healthy earlier: 5HR 90% WK 90%' \
    'still fine: 5HR 60% WK 70%' \
    '5HR 0% WK 40%')
  v=$(fm_statusline_quota_verdict "$capture")
  [ "$v" = exhausted ] || fail "bottom-most statusline row must win, got $v"
  pass "bottom-most row of the region wins over older rows"
}

{
  capture=$(printf '%s\n' 'Context 50% left · weekly 70% left' '' '' '' '' '' '' '' '')
  v=$(fm_statusline_quota_verdict "$capture")
  [ "$v" = ok ] || fail "blank rows under the statusline must not hide it, got $v"
  pass "region skips the blank rows a pane draws under the statusline"
}

{
  capture=$(printf '%s\n' 'weekly 0% left' one two three four five six 'Context 50% left · weekly 70% left')
  v=$(fm_statusline_quota_verdict "$capture")
  [ "$v" = ok ] || fail "a row beyond the region must not vote, got $v"
  pass "rows above the statusline region are out of scope"
}

{
  region=$(fm_statusline_quota_tail "$(printf 'a\n\nb\nc\nd\ne\nf\ng\nh\n')")
  [ "$(printf '%s\n' "$region" | wc -l | tr -d ' ')" = 6 ] || fail "region should keep six lines: $region"
  case "$region" in
    a*|*b*) fail "region must drop the oldest lines: $region" ;;
  esac
  pass "statusline region defaults to the last six non-empty lines"
}

# --- refusal: unverified harness -------------------------------------------

{
  setup_case refuse-unverified task-u1
  set +e
  out=$("$HANDOFF" task-u1 --harness not-a-real-harness --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unverified harness should refuse"
  assert_contains "$out" "not a verified adapter" "unverified harness message"
  [ -f "$CASE_WT/dirty.txt" ] || fail "handoff must not touch worktree contents"
  pass "refuses unverified target harness"
}

# Every refusal below runs the LIVE-endpoint shape through the bin farm, so the
# stubbed fm-send.sh proves the destructive exit never happened.

# Verified crewmate adapters must be accepted as runtime-handoff targets.
{
  setup_case accept-new-targets task-u2
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=bash
  farm=$(make_bin_farm "$CASE_DIR")
  rm -f "$farm/fm-spawn.sh"
  cat > "$farm/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
: > "$FM_FAKE_SPAWN_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$FM_FAKE_SPAWN_LOG"; done
exit 0
SH
  chmod +x "$farm/fm-spawn.sh"
  for h in cline cursor-agent copilot agy muse; do
    : > "$CASE_DIR/spawn-$h.log"
    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_SPAWN_LOG="$CASE_DIR/spawn-$h.log" \
      "$farm/fm-runtime-handoff.sh" task-u2 --harness "$h" --skip-exit 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "harness '$h' should be accepted as a handoff target: $out"
    assert_contains "$(cat "$CASE_DIR/spawn-$h.log")" "$h" "spawn args should carry target harness $h"
  done
  [ -f "$CASE_WT/dirty.txt" ] || fail "handoff must not touch worktree contents"
  pass "accepts verified handoff target adapters"
}

# Handoff from the newly verified adapters must classify the live agent and send
# that adapter's verified exit input before relaunching.
{
  farm=
  for h in cline cursor-agent copilot agy; do
    id="task-from-${h//-}"
    recorded=$h
    case "$h" in
      cline) recorded=cline-cli ;;
      cursor-agent) recorded=cursor-agent-cli ;;
    esac
    setup_case "from-$h" "$id" "$recorded"
    export FM_FAKE_WINDOW_FILE="$CASE_DIR/window.present"
    : > "$FM_FAKE_WINDOW_FILE"
    export FM_FAKE_EXIT_MARKER="$CASE_DIR/exited"
    export FM_FAKE_SEND_MARKS_EXIT="$FM_FAKE_EXIT_MARKER"
    export FM_FAKE_PANE_CMD="$h"
    : > "$FM_FAKE_SEND_LOG"
    farm=$(make_bin_farm "$CASE_DIR")
    rm -f "$farm/fm-spawn.sh"
    cat > "$farm/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
exit 0
SH
    chmod +x "$farm/fm-spawn.sh"
    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HANDOFF_EXIT_POLLS=5 FM_HANDOFF_EXIT_SLEEP=0 \
      "$farm/fm-runtime-handoff.sh" "$id" --harness claude 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "handoff from '$h' should exit and relaunch: $out"
    send_log=$(cat "$FM_FAKE_SEND_LOG")
    case "$h" in
      cline) assert_contains "$send_log" "$id --key C-c" "cline exit key delivered" ;;
      cursor-agent) assert_contains "$send_log" "$id /quit" "cursor-agent exit command delivered" ;;
      copilot|agy) assert_contains "$send_log" "$id /exit" "$h exit command delivered" ;;
    esac
  done
  pass "sends verified exit input for newly verified source adapters"
}

# --- refusal: --provider is not part of the relaunch contract ---------------

{
  setup_case refuse-provider task-pv1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=codex
  : > "$FM_FAKE_SEND_LOG"
  farm=$(make_bin_farm "$CASE_DIR")
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-runtime-handoff.sh" task-pv1 --harness claude --provider grok 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--provider is unsupported and must refuse"
  assert_contains "$out" "unknown option --provider" "unknown provider option message"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "unknown option must not deliver an exit command"
  pass "refuses --provider instead of forwarding it to an unsupported spawn flag"
}

# --- refusal: --backend that differs from the recorded backend --------------

{
  setup_case refuse-backend-switch task-b1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=codex
  : > "$FM_FAKE_SEND_LOG"
  farm=$(make_bin_farm "$CASE_DIR")
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$farm/fm-runtime-handoff.sh" task-b1 --harness claude --backend herdr 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "backend switch should refuse"
  assert_contains "$out" "differs from the backend recorded" "backend switch message"
  [ ! -s "$FM_FAKE_SEND_LOG" ] || fail "backend switch must not deliver an exit command"
  [ -f "$CASE_WT/dirty.txt" ] || fail "refusal must not touch worktree"
  pass "refuses --backend that does not match the recorded backend"
}

# --- refusal: missing worktree ---------------------------------------------

{
  setup_case refuse-missing-wt task-m1
  rm -rf "$CASE_WT"
  set +e
  out=$("$HANDOFF" task-m1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing worktree should refuse"
  assert_contains "$out" "does not exist" "missing worktree message"
  pass "refuses when recorded worktree is missing"
}

# --- refusal: primary checkout as worktree ---------------------------------

{
  setup_case refuse-primary task-p1
  fm_write_meta "$CASE_HOME/state/task-p1.meta" \
    "window=firstmate:fm-task-p1" \
    "endpoint_task_id=task-p1" \
    "worktree=$CASE_PROJ" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  set +e
  out=$("$HANDOFF" task-p1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "primary worktree should refuse"
  assert_contains "$out" "primary checkout" "primary checkout message"
  pass "refuses when worktree is the project primary"
}

# --- refusal: live endpoint without successful exit ------------------------

{
  setup_case refuse-alive task-a1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=codex
  set +e
  out=$("$SPAWN" task-a1 --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "alive endpoint should refuse reuse-worktree"
  assert_contains "$out" "endpoint reads 'alive'" "alive endpoint message"
  pass "refuses --reuse-worktree while endpoint is alive"
}

# --- refusal: ambiguous endpoint ownership ---------------------------------

{
  setup_case refuse-ambiguous task-q1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=something-unknown
  set +e
  out=$("$SPAWN" task-q1 --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ambiguous endpoint should refuse"
  assert_contains "$out" "endpoint reads 'ambiguous'" "ambiguous ownership message"
  pass "refuses when endpoint ownership cannot be reconciled"
}

# --- success: reuse-worktree preserves commits, dirt, meta keys ------------

{
  setup_case success-reuse task-s1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=bash
  : > "$FM_FAKE_TREEHOUSE_LOG"
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_before=$(cat "$CASE_WT/dirty.txt")
  branch_before=$(git -C "$CASE_WT" rev-parse --abbrev-ref HEAD)

  set +e
  out=$(FM_SPAWN_SETTLE_POLLS=2 "$SPAWN" task-s1 --reuse-worktree --harness claude --model sonnet --effort high 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "reuse-worktree should succeed: $out"

  head_after=$(git -C "$CASE_WT" rev-parse HEAD)
  dirty_after=$(cat "$CASE_WT/dirty.txt")
  branch_after=$(git -C "$CASE_WT" rev-parse --abbrev-ref HEAD)
  [ "$head_before" = "$head_after" ] || fail "HEAD must be preserved"
  [ "$dirty_before" = "$dirty_after" ] || fail "uncommitted changes must be preserved"
  [ "$branch_before" = "$branch_after" ] || fail "branch must be preserved"

  meta=$(cat "$CASE_HOME/state/task-s1.meta")
  assert_contains "$meta" "harness=claude" "meta harness updated"
  assert_contains "$meta" "model=sonnet" "meta model updated"
  assert_contains "$meta" "effort=high" "meta effort updated"
  assert_contains "$meta" "pr=https://example.test/pr/1" "pr= preserved"
  assert_contains "$meta" "pr_head=abc123" "pr_head= preserved"
  assert_contains "$meta" "worktree=$CASE_WT" "worktree preserved"
  assert_contains "$meta" "mode=no-mistakes" "mode preserved"

  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "treehouse must not be invoked on reuse-worktree; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  assert_contains "$out" "spawned task-s1 harness=claude" "spawn success line"
  pass "successful reuse preserves commits, dirt, and non-owned meta"
}

# --- success: handoff end-to-end with skip-exit (agent-free endpoint) -------

{
  setup_case success-handoff task-h1
  export FM_FAKE_WINDOW_PRESENT=1
  export FM_FAKE_PANE_CMD=bash
  : > "$FM_FAKE_TREEHOUSE_LOG"
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)
  printf 'uncommitted\n' > "$CASE_WT/dirty.txt"

  set +e
  out=$(
    FM_SPAWN_SETTLE_POLLS=2 \
    "$HANDOFF" task-h1 --harness claude --skip-exit \
      --progress-note "Codex quota exhausted mid-pipeline; 1 commit + dirty fix remain." \
      --model opus 2>&1
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "handoff should succeed: $out"
  assert_contains "$out" "handed-off task-h1" "handoff success line"
  assert_contains "$out" "to harness=claude" "handoff target harness"

  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "handoff must preserve HEAD"
  [ -f "$CASE_WT/dirty.txt" ] || fail "handoff must preserve dirty file"
  meta=$(cat "$CASE_HOME/state/task-h1.meta")
  assert_contains "$meta" "harness=claude" "handoff meta harness"
  assert_contains "$meta" "pr=https://example.test/pr/1" "handoff preserves pr="
  [ -f "$CASE_HOME/data/task-h1/brief.md" ] || fail "original brief must remain"
  [ -f "$CASE_HOME/state/task-h1.handoff-prompt" ] || fail "handoff prompt should be written"
  prompt=$(cat "$CASE_HOME/state/task-h1.handoff-prompt")
  assert_contains "$prompt" "Codex quota exhausted" "progress note in handoff prompt"
  assert_contains "$prompt" "no-mistakes axi status" "pipeline re-attach instruction"
  assert_contains "$prompt" "brief for task-h1" "original brief content embedded"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "handoff must not call treehouse; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "successful handoff preserves work, updates meta, reuses brief"
}

# --- success: verified exit path (alive -> exit command -> dead) ------------

{
  setup_case exit-path task-x1
  export FM_FAKE_WINDOW_FILE="$CASE_DIR/window.present"
  : > "$FM_FAKE_WINDOW_FILE"
  export FM_FAKE_EXIT_MARKER="$CASE_DIR/exited"
  export FM_FAKE_SEND_MARKS_EXIT="$FM_FAKE_EXIT_MARKER"
  export FM_FAKE_PANE_CMD=codex
  : > "$FM_FAKE_SEND_LOG"
  : > "$FM_FAKE_TREEHOUSE_LOG"
  farm=$(make_bin_farm "$CASE_DIR")
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)

  set +e
  out=$(
    FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_SETTLE_POLLS=2 \
    FM_HANDOFF_EXIT_POLLS=5 FM_HANDOFF_EXIT_SLEEP=0 \
    "$farm/fm-runtime-handoff.sh" task-x1 --harness claude \
      --progress-note "Exited codex cleanly; work is unlanded." 2>&1
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "handoff over the live exit path should succeed: $out"
  assert_contains "$out" "handed-off task-x1" "handoff success line"

  send_log=$(cat "$FM_FAKE_SEND_LOG")
  assert_contains "$send_log" "task-x1 /quit" "codex exit command delivered via fm-send"
  [ -f "$FM_FAKE_EXIT_MARKER" ] || fail "exit command should have been sent"
  [ -f "$FM_FAKE_WINDOW_FILE" ] || fail "agent-free endpoint should remain available for reuse"

  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "exit path must preserve HEAD"
  [ -f "$CASE_WT/dirty.txt" ] || fail "exit path must preserve uncommitted changes"
  meta=$(cat "$CASE_HOME/state/task-x1.meta")
  assert_contains "$meta" "harness=claude" "meta harness updated over the exit path"
  assert_contains "$meta" "pr=https://example.test/pr/1" "pr= preserved over the exit path"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "exit path must not call treehouse; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  status_log=$(cat "$CASE_HOME/state/task-x1.status")
  assert_contains "$status_log" "working: runtime handoff to claude" "handoff logs a 'working' status verb"
  case "$status_log" in
    *"status: working:"*) fail "status line must not double-prefix the verb: $status_log" ;;
  esac
  pass "sends the recorded harness's exit command and completes once the pane is dead"
}

# --- refusal: harness ignores the exit command and stays alive --------------

{
  setup_case exit-refuses task-x2
  export FM_FAKE_WINDOW_FILE="$CASE_DIR/window.present"
  : > "$FM_FAKE_WINDOW_FILE"
  # No FM_FAKE_SEND_MARKS_EXIT: the send lands but the harness never exits.
  export FM_FAKE_PANE_CMD=codex
  : > "$FM_FAKE_SEND_LOG"
  farm=$(make_bin_farm "$CASE_DIR")
  head_before=$(git -C "$CASE_WT" rev-parse HEAD)

  set +e
  out=$(
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HANDOFF_EXIT_POLLS=2 FM_HANDOFF_EXIT_SLEEP=0 \
    "$farm/fm-runtime-handoff.sh" task-x2 --harness claude 2>&1
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a still-alive endpoint after exit must refuse"
  assert_contains "$out" "still 'alive' after exit attempt" "still-alive refusal message"

  send_log=$(cat "$FM_FAKE_SEND_LOG")
  assert_contains "$send_log" "task-x2 /quit" "exit command was attempted before refusing"
  [ -f "$FM_FAKE_WINDOW_FILE" ] || fail "refusal must not kill a live endpoint"
  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$head_before" ] || fail "refusal must preserve HEAD"
  [ -f "$CASE_WT/dirty.txt" ] || fail "refusal must preserve uncommitted changes"
  meta=$(cat "$CASE_HOME/state/task-x2.meta")
  assert_contains "$meta" "harness=codex" "refusal leaves the recorded harness alone"
  pass "refuses when the endpoint is still alive after the exit command"
}

# --- refusal: batch dispatch never silently drops --reuse-worktree ----------

{
  setup_case refuse-batch task-c1
  set +e
  out=$("$SPAWN" "task-c1=$CASE_PROJ" --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "batch dispatch with --reuse-worktree should refuse"
  assert_contains "$out" "--relaunch is single-task only" "batch reuse refusal message"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "batch refusal must not lease a worktree; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "refuses --reuse-worktree in batch dispatch instead of leasing a second worktree"
}

# --- refusal: secondmate identity ------------------------------------------

{
  setup_case refuse-secondmate task-m1
  fm_write_meta "$CASE_HOME/state/task-m1.meta" \
    "window=firstmate:fm-task-m1" \
    "endpoint_task_id=task-m1" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=no-mistakes" \
    "yolo=off"
  : > "$FM_FAKE_TREEHOUSE_LOG"
  set +e
  out=$("$HANDOFF" task-m1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "secondmate handoff should refuse"
  assert_contains "$out" "is a secondmate" "secondmate refusal message"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "secondmate refusal must not touch treehouse; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "refuses a secondmate task instead of handing its identity to another runtime"
}

# --- refusal: orca backend owns its own worktree lifecycle ------------------

{
  setup_case refuse-orca task-o1
  # The orca backend validates that its CLI exists before the reuse guard runs;
  # stub it so the refusal under test is the reuse guard, not a missing binary.
  cat > "$CASE_DIR/fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
fi
exit 0
SH
  chmod +x "$CASE_DIR/fakebin/orca"
  fm_write_meta "$CASE_HOME/state/task-o1.meta" \
    "window=firstmate:fm-task-o1" \
    "endpoint_task_id=task-o1" \
    "worktree=$CASE_WT" \
    "project=$CASE_PROJ" \
    "harness=codex" \
    "kind=ship" \
    "backend=orca" \
    "mode=no-mistakes" \
    "yolo=off"
  : > "$FM_FAKE_TREEHOUSE_LOG"
  set +e
  out=$("$SPAWN" task-o1 --reuse-worktree --harness claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "orca-backed reuse should refuse"
  assert_contains "$out" "missing terminal" "orca refusal message"
  if [ -s "$FM_FAKE_TREEHOUSE_LOG" ]; then
    fail "orca refusal must not lease a worktree; log=$(cat "$FM_FAKE_TREEHOUSE_LOG")"
  fi
  pass "refuses reuse on an orca-backed task rather than re-creating its worktree"
}

# --- refusal: missing original brief ---------------------------------------

{
  setup_case refuse-brief task-b1
  rm -f "$CASE_HOME/data/task-b1/brief.md"
  set +e
  out=$("$HANDOFF" task-b1 --harness claude --skip-exit 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing brief should refuse"
  assert_contains "$out" "original brief missing" "missing brief message"
  pass "refuses when original brief is missing"
}

printf 'All fm-runtime-handoff tests passed.\n'
