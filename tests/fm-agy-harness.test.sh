#!/usr/bin/env bash
# shellcheck disable=SC2016 # $p and $parent are jq variables bound with --arg, never shell expansions.
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
#
# Every check here is portable: it runs against real processes, real SQLite
# databases, and real captured-shape bytes, with no agy installed. The
# harness-dependent halves that only a real agy can prove - that its process is
# still named `agy`, that it still writes `Created conversation` into its log,
# and that its step rows still settle to status 3 - are covered by the opt-in
# live guard tests/fm-agy-signals-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, or Grok inherits those markers, which outrank
# the fake ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS ANTIGRAVITY_AGENT

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
JQ_BIN=$(command -v jq) || fail "test needs jq"
SQLITE_BIN=$(command -v sqlite3) || fail "test needs sqlite3"
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_agy_harness() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_agy_harness EXIT

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

# --- detection --------------------------------------------------------------

# fake_ps <fakebin> <comm-for-pid-4242>: an ancestry walk whose one non-shell
# ancestor reports <comm>. Every other pid is a plain shell, so the ONLY
# ancestry evidence in the walk is the name under test.
fake_ps() {  # <fakebin> <comm>
  local fakebin=$1 comm=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "\$@"; do
  [ "\$prev" = -o ] && field=\$arg
  [ "\$prev" = -p ] && pid=\$arg
  prev=\$arg
done
case "\$field:\$pid" in
  comm=:4242) printf '%s\n' '$comm' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
}

detect_with() {  # <fakebin> <cfg> [env assignments...]
  local fakebin=$1 cfg=$2
  shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ANTIGRAVITY_AGENT \
    "$@" PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" \
    "$ROOT/bin/fm-harness.sh"
}

test_agy_detection_survives_losing_either_signal() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detect-both"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"

  # Signal A alone: the ANTIGRAVITY_AGENT marker, with an ancestry that names
  # NO harness at all. The divergence is asserted first, so this case cannot
  # pass vacuously by the ancestry quietly supplying the verdict.
  fake_ps "$fakebin" /bin/bash
  out=$(detect_with "$fakebin" "$cfg")
  [ "$out" = unknown ] \
    || fail "control: a harness-free ancestry should be unknown, got '$out'"
  out=$(detect_with "$fakebin" "$cfg" ANTIGRAVITY_AGENT=1)
  [ "$out" = agy ] || fail "agy env-marker detection returned '$out'"

  # Signal B alone: the process name, with NO marker in the environment.
  fake_ps "$fakebin" /Users/someone/.local/bin/agy
  out=$(detect_with "$fakebin" "$cfg")
  [ "$out" = agy ] || fail "agy ancestry detection returned '$out'"

  # Marker precedence is unchanged: a verified foreign marker still outranks
  # an agy ancestry, exactly as it does for every markerless adapter.
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ANTIGRAVITY_AGENT \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: agy is detected by its marker and by ancestry independently"
}

test_agy_ancestry_match_is_anchored() {
  local dir fakebin cfg out name
  dir="$TMP_ROOT/detect-anchor"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  # `agy` is a three-letter fragment of ordinary words. An unanchored *agy*
  # match would claim every one of these as a live agent pane.
  for name in /usr/bin/magyar /opt/bin/agyness /usr/local/bin/nagy; do
    fake_ps "$fakebin" "$name"
    out=$(detect_with "$fakebin" "$cfg")
    [ "$out" = unknown ] \
      || fail "unanchored agy match claimed '$name' as harness '$out'"
  done
  # The exact name still matches, so the anchoring is not vacuously strict.
  fake_ps "$fakebin" /usr/local/bin/agy
  out=$(detect_with "$fakebin" "$cfg")
  [ "$out" = agy ] || fail "anchored agy match rejected the exact name, got '$out'"
  pass "fm-harness: the agy ancestry match is anchored, never a substring"
}

# --- busy fold --------------------------------------------------------------

# make_agy_db <path> <status...>: a real conversation database whose steps table
# carries the given statuses in idx order.
make_agy_db() {  # <path> <status...>
  local db=$1 idx=0 st
  shift
  "$SQLITE_BIN" "$db" 'CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, PRIMARY KEY (idx));' \
    || fail "could not create the agy steps table"
  for st in "$@"; do
    "$SQLITE_BIN" "$db" "INSERT INTO steps (idx, step_type, status) VALUES ($idx, 15, $st);" \
      || fail "could not seed an agy step row"
    idx=$((idx + 1))
  done
}

bind_agy_task() {  # <state-dir> <id> <conversations-root> <conversation-id>
  local state=$1 id=$2 root=$3 conv=$4
  mkdir -p "$state" "$root"
  printf 'ERROR: logging before google.Init: I0828 08:56:47 1 server.go:1153] Created conversation %s\n' "$conv" \
    > "$state/$id.agy-log"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'log_file=%s\n' "$state/$id.agy-log"
  } > "$state/$id.agy-session"
}

test_agy_busy_uses_every_step_not_the_last_one() {
  local dir state root conv db last unfinished
  dir="$TMP_ROOT/busy-predicate"
  state="$dir/state"
  root="$dir/conversations"
  conv=11111111-2222-3333-4444-555555555555
  bind_agy_task "$state" agy-task "$root" "$conv"
  db="$root/$conv.db"
  # The exact live shape that makes the two candidate predicates disagree: an
  # enclosing step still running at status 2, with a LATER step that already
  # settled to 3 sitting above it.
  make_agy_db "$db" 3 3 2 3

  # Assert the divergence itself, so this case can never go quietly vacuous if
  # the seeded shape stops distinguishing the two predicates.
  last=$("$SQLITE_BIN" "$db" 'SELECT status FROM steps ORDER BY idx DESC LIMIT 1;')
  unfinished=$("$SQLITE_BIN" "$db" 'SELECT COUNT(*) FROM steps WHERE status != 3;')
  [ "$last" = 3 ] || fail "fixture no longer has a settled highest-idx row, got '$last'"
  [ "$unfinished" -gt 0 ] || fail "fixture no longer has an unfinished step"

  [ "$(fm_busy_agy_run_state "$db")" = busy ] \
    || fail "a running enclosing step under a settled newer step must read busy"
  [ "$(fm_busy_classify tmux fm:agy-task agy agy-task "$state")" = "busy agy-steps" ] \
    || fail "the classifier did not report busy agy-steps mid-turn"
  pass "busy fold: a turn in flight reads busy even when the newest step has settled"
}

test_agy_busy_settles_and_refuses_to_guess() {
  local dir state root conv db out
  dir="$TMP_ROOT/busy-states"
  state="$dir/state"
  root="$dir/conversations"

  conv=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  bind_agy_task "$state" settled "$root" "$conv"
  make_agy_db "$root/$conv.db" 3 3 3
  [ "$(fm_busy_agy_run_state "$root/$conv.db")" = settled ] \
    || fail "an all-finished step table must read settled"
  [ "$(fm_busy_classify tmux fm:settled agy settled "$state")" = "idle agy-steps" ] \
    || fail "the classifier did not report idle agy-steps for a settled turn"

  # A conversation that has run no turn proves nothing about the pane, so it is
  # unknown rather than idle.
  conv=aaaaaaaa-bbbb-cccc-dddd-ffffffffffff
  bind_agy_task "$state" fresh "$root" "$conv"
  make_agy_db "$root/$conv.db"
  [ "$(fm_busy_agy_run_state "$root/$conv.db")" = none ] \
    || fail "an empty step table must read none"
  out=$(fm_busy_classify tmux fm:fresh agy fresh "$state")
  [ "$out" = "unknown agy-steps" ] \
    || fail "a turn-free conversation must be unknown, got '$out'"

  # No sidecar at all.
  out=$(fm_busy_classify tmux fm:absent agy absent "$state")
  [ "$out" = "unknown agy-steps" ] \
    || fail "an unbound agy task must be unknown, got '$out'"

  # A sidecar whose named conversation has no database on disk.
  bind_agy_task "$state" missingdb "$root" 99999999-8888-7777-6666-555555555555
  out=$(fm_busy_classify tmux fm:missingdb agy missingdb "$state")
  [ "$out" = "unknown agy-steps" ] \
    || fail "a missing conversation database must be unknown, got '$out'"
  pass "busy fold: settled reads idle while every unproven shape reads unknown"
}

test_agy_conversation_binding_ignores_unrelated_uuids() {
  local dir state root conv wrong
  dir="$TMP_ROOT/busy-binding"
  state="$dir/state"
  root="$dir/conversations"
  conv=12121212-3434-5656-7878-909090909090
  wrong=deadbeef-0000-1111-2222-333333333333
  mkdir -p "$state" "$root"
  # A worktree path can itself contain a UUID, and agy logs the workspace it
  # opened. Only the `Created conversation` line may name the conversation.
  {
    printf 'ERROR: logging before google.Init: I0828 08:56:45 1 server.go:1487] workspace /tmp/scratch/%s/wt\n' "$wrong"
    printf 'ERROR: logging before google.Init: I0828 08:56:47 1 server.go:1153] Created conversation %s\n' "$conv"
  } > "$state/bind.agy-log"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'log_file=%s\n' "$state/bind.agy-log"
  } > "$state/bind.agy-session"
  [ "$(fm_busy_agy_conversation_id "$state" bind)" = "$conv" ] \
    || fail "an unrelated UUID in the log was mistaken for the conversation"

  # A log with no Created-conversation line at all binds nothing.
  printf 'ERROR: some unrelated line with %s in it\n' "$wrong" > "$state/none.agy-log"
  {
    printf 'conversations_root=%s\n' "$root"
    printf 'log_file=%s\n' "$state/none.agy-log"
  } > "$state/none.agy-session"
  fm_busy_agy_conversation_id "$state" none >/dev/null 2>&1 \
    && fail "a log naming no conversation must not resolve one"
  pass "busy fold: the conversation binding matches agy's own token, not any UUID"
}

test_agy_busy_reads_a_checkpointed_database() {
  local dir state root conv db
  dir="$TMP_ROOT/busy-wal"
  state="$dir/state"
  root="$dir/conversations"
  conv=abcdabcd-1111-2222-3333-444444444444
  bind_agy_task "$state" wal "$root" "$conv"
  db="$root/$conv.db"
  make_agy_db "$db" 3 2
  # agy keeps the database in WAL mode and removes the sidecars when it
  # checkpoints. A read-only open cannot create the -shm it would need at that
  # point, so the fold must still answer through its second open mode rather
  # than degrading to unknown on every settled conversation.
  "$SQLITE_BIN" "$db" 'PRAGMA journal_mode=WAL;' >/dev/null \
    || fail "could not put the fixture database into WAL mode"
  "$SQLITE_BIN" "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
  rm -f "$db-wal" "$db-shm"
  [ "$(fm_busy_agy_run_state "$db")" = busy ] \
    || fail "a checkpointed WAL-mode database must still fold"
  # The fold must not have resurrected the sidecars inside the operator's own
  # conversation store.
  [ ! -e "$db-wal" ] || fail "the busy fold created a -wal file beside the operator's database"
  [ ! -e "$db-shm" ] || fail "the busy fold created a -shm file beside the operator's database"
  pass "busy fold: a checkpointed database still folds and stays untouched"
}

test_agy_busy_never_borrows_another_adapters_source() {
  local dir state root conv out
  dir="$TMP_ROOT/busy-scope"
  state="$dir/state"
  root="$dir/conversations"
  conv=55555555-6666-7777-8888-999999999999
  bind_agy_task "$state" scope "$root" "$conv"
  make_agy_db "$root/$conv.db" 3 3
  # The same on-disk binding must classify NOTHING for another harness: a
  # source is only ever read for the adapter that owns it.
  out=$(fm_busy_classify tmux fm:scope cursor scope "$state")
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "an agy binding classified a cursor task, got '$out'"
  pass "busy fold: agy's source never classifies another adapter"
}

# --- composer ---------------------------------------------------------------

DIM=$'\033[90m'
BLUE=$'\033[94m'
FAINT=$'\033[2m'
OFF=$'\033[m'
DEFAULT=$'\033[39m'
RULE=$(printf '─%.0s' $(seq 1 60))

# agy_screen <composer-body>: the verified agy pane shape - a bare separated
# composer between two dim-gray horizontal rules, a bright-blue `>` prompt
# glyph, and a dim footer BELOW the closing rule (verified live, agy 1.1.22).
agy_screen() {  # <composer-body>
  printf '%s\n' "  Antigravity CLI 1.1.22"
  printf '%s\n' ""
  printf '%s%s%s\n' "$DIM" "$RULE" "$OFF"
  printf '%s>%s%s\n' "$BLUE" "$DEFAULT" "$1"
  printf '%s%s%s\n' "$DIM" "$RULE" "$OFF"
  printf '%s? for shortcuts%s   %sGemini 3.6 Flash · high%s\n' "$DIM" "$DEFAULT" "$FAINT" "$OFF"
}

AGY_CAPS=$(printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n')

test_agy_composer_needs_its_own_identity() {
  local screen out
  screen=$(agy_screen "")
  # Row 3 holds the prompt glyph; the composer sits between rows 2 and 4.
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$screen" 3)
  [ "$out" = need-identity ] \
    || fail "an agy composer should ask for identity, got '$out'"
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$screen" 3 probe-absent)
  [ "$out" = unknown ] \
    || fail "an agy shape with no live agent must be unknown, got '$out'"
  # The shape alone must never be enough: another agent's identity over the
  # same bytes stays unknown, so agy's rule cannot classify a foreign pane.
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$screen" 3 "$(printf 'claude\tidle')")
  [ "$out" = unknown ] \
    || fail "an agy shape under a foreign identity must be unknown, got '$out'"
  pass "composer: the agy separated shape is unreadable without agy's own identity"
}

test_agy_composer_reads_empty_and_pending() {
  local out
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$(agy_screen "")" 3 "$(printf 'agy\tidle')")
  [ "$out" = empty ] \
    || fail "an idle agy composer should read empty, got '$out'"
  # agy draws NO ghost or placeholder text inside its composer, so anything
  # after the glyph is real typed input.
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$(agy_screen " hello there")" 3 "$(printf 'agy\tidle')")
  [ "$out" = pending ] \
    || fail "typed agy composer text should read pending, got '$out'"
  # A working agent is not a safe injection target even with an empty composer.
  out=$(fm_composer_classify_screen "$AGY_CAPS" "$(agy_screen "")" 3 "$(printf 'agy\tworking')")
  [ "$out" = unknown ] \
    || fail "a working agy pane should not read empty, got '$out'"
  pass "composer: agy's prompt glyph reads empty while typed text reads pending"
}

test_agy_delivery_footer_is_scoped() {
  # agy's busy footer must acknowledge an agy submit and must NOT be borrowed
  # by another harness, nor another harness's footer by agy.
  printf 'esc to cancel\n' | fm_busy_lines_match agy \
    || fail "agy's own busy footer did not match"
  printf '? for shortcuts\n' | fm_busy_lines_match agy \
    && fail "agy's idle footer was read as busy"
  printf 'esc to cancel\n' | fm_busy_lines_match grok \
    && fail "grok borrowed agy's busy footer"
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match agy \
    && fail "agy borrowed grok's busy footer"
  pass "composer: agy's delivery footer is scoped to agy"
}

# --- control mechanics ------------------------------------------------------

test_agy_control_mechanics_are_declared() {
  local out
  fm_control_harness_supported agy || fail "agy is not a supported control harness"
  out=$(fm_control_harness_family agy) || fail "agy has no control family"
  [ "$out" = agy ] || fail "agy control family resolved to '$out'"
  [ "$(fm_control_interrupt_key agy)" = Escape ] \
    || fail "agy interrupt key changed"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] \
    || fail "agy interrupt repeat changed"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] \
    || fail "agy should need no composer clear key after an interrupt"
  [ "$(fm_control_exit_command agy)" = /exit ] \
    || fail "agy exit command changed"
  # agy is a crewmate/scout adapter only.
  fm_control_harness_supports_kind agy ship || fail "agy should run a ship task"
  fm_control_harness_supports_kind agy scout || fail "agy should run a scout task"
  pass "control: agy's verified interrupt, exit, and kind support are declared"
}

test_agy_secondmate_is_refused_before_anything_is_stopped() {
  # This gate is asked BEFORE the control plane stops the running agent, so an
  # adapter the launch owner will refuse must be refused HERE too. Missing it
  # stops a live secondmate and only then fails the relaunch, leaving the task
  # with no agent at all.
  fm_control_harness_supports_kind agy secondmate \
    && fail "agy must be refused for kind=secondmate on the pre-stop side of a relaunch"
  # muse is the established precedent for the same rule; assert it too so a
  # future edit cannot quietly drop either name.
  fm_control_harness_supports_kind muse secondmate \
    && fail "muse must be refused for kind=secondmate"
  # The refusal is kind-scoped, not a blanket rejection of the adapter.
  fm_control_harness_supports_kind agy ship \
    || fail "the secondmate refusal must not also block an agy ship task"
  pass "control: agy is refused for a secondmate before the running agent is stopped"
}

test_agy_wiring_paths_are_retired_on_relaunch() {
  local out
  out=$(fm_control_harness_wiring_paths agy /wt /state task1)
  assert_contains "$out" "/state/task1.agy-session" "agy sidecar is not retired on relaunch"
  assert_contains "$out" "/state/task1.agy-log" "agy log is not retired on relaunch"
  # agy installs no global turn-end hook, so it mints no registry token.
  out=$(fm_control_harness_turnend_token_path agy /state task1)
  [ -z "$out" ] || fail "agy should mint no turn-end registry token, got '$out'"
  pass "control: agy's per-task wiring is retired when a task changes harness"
}

# --- spawn: trust grant, sidecar, and launch flags ---------------------------

make_agy_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    [ -z "$literal" ] || printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
    exit 0
    ;;
  capture-pane) printf 'shell starting\n$ \n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  ln -s "$SQLITE_BIN" "$fakebin/sqlite3"
  printf '%s\n' "$fakebin"
}

make_agy_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_agy_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy dispatch.

## Firstmate spec
Verify agy harness behavior under test.
EOF
  printf 'agy\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_agy_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6 settings=$7
  shift 7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_AGY_SETTINGS_OVERRIDE="$settings" \
    AGY_CONVERSATIONS_ROOT_OVERRIDE="$case_dir/conversations" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness agy --mode no-mistakes --yolo off "$@" 2>&1
}

test_agy_spawn_pre_trusts_the_worktree_without_disturbing_settings() {
  local id rec case_dir home proj wt fakebin settings out rc launch wt_abs
  id="agy-trust-$$"
  rec=$(make_agy_spawn_case trust "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  # A realistic pre-existing settings file: other keys, and a trusted entry the
  # spawn must not disturb. The worktree's PARENT is already trusted, which agy
  # does NOT honour - its matching is exact - so the exact path must still be
  # added.
  "$JQ_BIN" -n --arg parent "$(dirname "$wt")" '{
    allowNonWorkspaceAccess: true,
    model: "Gemini 3.6 Flash (High)",
    permissions: {allow: ["command(unzip)"]},
    trustedWorkspaces: ["/Users/someone", $parent]
  }' > "$settings"

  out=$(run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings")
  rc=$?
  expect_code 0 "$rc" "an agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  # The grant must name the path the PANE is launched in, byte for byte. agy
  # normalizes redundant separators but does NOT resolve symlinks (verified
  # live, agy 1.1.22), so re-deriving a physical path here would assert the
  # wrong invariant: what has to match is the worktree fm-spawn recorded and
  # launched in, which is what the meta carries.
  wt_abs=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" | head -1)
  [ -n "$wt_abs" ] || fail "the spawn recorded no worktree to compare the trust grant against"
  "$JQ_BIN" -e --arg p "$wt_abs" '(.trustedWorkspaces // []) | index($p) != null' \
    "$settings" >/dev/null || fail "the launched worktree was not added to trustedWorkspaces"
  # Nothing else moved: every pre-existing key and entry survives.
  "$JQ_BIN" -e '.allowNonWorkspaceAccess == true and .model == "Gemini 3.6 Flash (High)"
      and (.permissions.allow | index("command(unzip)") != null)' \
    "$settings" >/dev/null || fail "an unrelated agy setting was dropped or changed"
  "$JQ_BIN" -e '(.trustedWorkspaces | index("/Users/someone")) != null' \
    "$settings" >/dev/null || fail "an existing trusted workspace was removed"

  # The launch carries the three flags the adapter depends on.
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" -- "--dangerously-skip-permissions" \
    "the agy launch is missing its autonomy flag"
  assert_contains "$launch" -- "--log-file" \
    "the agy launch is missing its per-task log binding"
  assert_contains "$launch" " -i " \
    "the agy launch does not deliver the brief interactively"

  # The busy binding sidecar is written and points at that same log.
  assert_present "$home/state/$id.agy-session" "the agy busy sidecar was not written"
  assert_grep "log_file=$home/state/$id.agy-log" "$home/state/$id.agy-session" \
    "the agy sidecar does not bind this task's own log"
  assert_grep "conversations_root=$case_dir/conversations" "$home/state/$id.agy-session" \
    "the agy sidecar does not record the resolved conversations root"
  pass "spawn: agy pre-trusts its exact worktree and binds its own conversation log"
}

test_agy_spawn_refuses_to_rewrite_unparseable_settings() {
  local id rec case_dir home proj wt fakebin settings out rc before
  id="agy-badjson-$$"
  rec=$(make_agy_spawn_case badjson "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  printf '{ "trustedWorkspaces": [ "/a", \n' > "$settings"
  before=$(cat "$settings")

  out=$(run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an agy spawn onto unparseable settings should refuse"
  assert_contains "$out" "not valid JSON" "the refusal did not name the settings problem"
  [ "$(cat "$settings")" = "$before" ] \
    || fail "an unparseable agy settings file was rewritten anyway"
  pass "spawn: agy refuses a spawn rather than clobbering unreadable settings"
}

test_agy_spawn_trust_write_is_idempotent() {
  local id rec case_dir home proj wt fakebin settings wt_abs count
  id="agy-idem-$$"
  rec=$(make_agy_spawn_case idem "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  "$JQ_BIN" -n --arg p "$wt" '{trustedWorkspaces: [$p]}' > "$settings"
  run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings" >/dev/null 2>&1
  wt_abs=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" | head -1)
  [ -n "$wt_abs" ] || fail "the spawn recorded no worktree to compare the trust grant against"
  count=$("$JQ_BIN" --arg p "$wt_abs" '[.trustedWorkspaces[] | select(. == $p)] | length' "$settings")
  [ "$count" = 1 ] \
    || fail "re-trusting an already-trusted worktree duplicated the entry ($count copies)"
  pass "spawn: re-spawning into a trusted worktree adds no duplicate grant"
}

test_agy_detection_survives_losing_either_signal
test_agy_ancestry_match_is_anchored
test_agy_secondmate_is_refused_before_anything_is_stopped
test_agy_busy_uses_every_step_not_the_last_one
test_agy_busy_settles_and_refuses_to_guess
test_agy_conversation_binding_ignores_unrelated_uuids
test_agy_busy_reads_a_checkpointed_database
test_agy_busy_never_borrows_another_adapters_source
test_agy_composer_needs_its_own_identity
test_agy_composer_reads_empty_and_pending
test_agy_delivery_footer_is_scoped
test_agy_control_mechanics_are_declared
test_agy_wiring_paths_are_retired_on_relaunch
test_agy_spawn_pre_trusts_the_worktree_without_disturbing_settings
test_agy_spawn_refuses_to_rewrite_unparseable_settings
test_agy_spawn_trust_write_is_idempotent

test_agy_trust_write_preserves_order_and_duplicates() {
  local id rec case_dir home proj wt fakebin settings before after wt_abs
  id="agy-order-$$"
  rec=$(make_agy_spawn_case order "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  # Deliberately UNSORTED, WITH a duplicate: jq's `unique` would sort this array
  # and drop the repeat, which is exactly what the captain's constraint forbids
  # for a file he also edits by hand.
  "$JQ_BIN" -n '{
    allowNonWorkspaceAccess: true,
    trustedWorkspaces: ["/z/one", "/a/two", "/a/two", "/m/three"],
    model: "Gemini 3.6 Flash (High)"
  }' > "$settings"
  before=$("$JQ_BIN" -c '.trustedWorkspaces' "$settings")

  run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings" >/dev/null 2>&1
  wt_abs=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" | head -1)
  [ -n "$wt_abs" ] || fail "the spawn recorded no worktree"

  # The grant is APPENDED and everything that was there keeps its exact position.
  after=$("$JQ_BIN" -c --arg p "$wt_abs" '.trustedWorkspaces | map(select(. != $p))' "$settings")
  [ "$after" = "$before" ] \
    || fail "the trust write reordered or dropped existing entries: $before -> $after"
  "$JQ_BIN" -e --arg p "$wt_abs" '.trustedWorkspaces[-1] == $p' "$settings" >/dev/null \
    || fail "the new grant was not appended at the end"
  "$JQ_BIN" -e '[.trustedWorkspaces[] | select(. == "/a/two")] | length == 2' \
    "$settings" >/dev/null || fail "the trust write de-duplicated an existing repeated entry"
  pass "spawn: the trust write appends without reordering or de-duplicating"
}

test_agy_teardown_retires_only_the_grant_it_added() {
  local id rec case_dir home proj wt fakebin settings wt_abs
  id="agy-retire-$$"
  rec=$(make_agy_spawn_case retire "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  "$JQ_BIN" -n '{trustedWorkspaces: ["/z/keep", "/a/keep"], other: 1}' > "$settings"

  run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings" >/dev/null 2>&1 \
    || fail "the agy spawn should succeed before teardown"
  wt_abs=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" | head -1)
  [ -n "$wt_abs" ] || fail "the spawn recorded no worktree"
  "$JQ_BIN" -e --arg p "$wt_abs" '(.trustedWorkspaces | index($p)) != null' "$settings" >/dev/null \
    || fail "the spawn did not add the grant this case is about to retire"

  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_AGY_SETTINGS_OVERRIDE="$settings" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 \
    || fail "the agy teardown failed"

  # The task's own grant is reclaimed, so a recreated worktree path does not
  # inherit trust, and nothing else in the file is disturbed.
  "$JQ_BIN" -e --arg p "$wt_abs" '(.trustedWorkspaces | index($p)) == null' "$settings" >/dev/null \
    || fail "teardown did not reclaim the trust grant the spawn added"
  "$JQ_BIN" -e '.trustedWorkspaces == ["/z/keep", "/a/keep"] and .other == 1' "$settings" >/dev/null \
    || fail "teardown disturbed entries or keys it did not add"
  assert_absent "$home/state/$id.agy-session" "the agy sidecar survived teardown"
  assert_absent "$home/state/$id.agy-log" "the agy log survived teardown"
  pass "teardown: the task's trust grant is reclaimed and nothing else is touched"
}

test_agy_teardown_keeps_a_grant_the_operator_already_had() {
  local id rec case_dir home proj wt fakebin settings wt_abs
  id="agy-preowned-$$"
  rec=$(make_agy_spawn_case preowned "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  settings="$case_dir/settings.json"
  # Pre-trust the exact worktree, so the spawn's write is a no-op and the grant
  # belongs to the operator rather than to firstmate.
  "$JQ_BIN" -n --arg p "$wt" '{trustedWorkspaces: [$p]}' > "$settings"

  run_agy_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" "$settings" >/dev/null 2>&1 \
    || fail "the agy spawn should succeed before teardown"
  wt_abs=$(sed -n 's/^worktree=//p' "$home/state/$id.meta" | head -1)
  [ -n "$wt_abs" ] || fail "the spawn recorded no worktree"
  assert_grep 'trust_added=0' "$home/state/$id.agy-session" \
    "the spawn should record that it added no grant for an already-trusted worktree"

  HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_AGY_SETTINGS_OVERRIDE="$settings" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 \
    || fail "the agy teardown failed"

  "$JQ_BIN" -e --arg p "$wt_abs" '(.trustedWorkspaces | index($p)) != null' "$settings" >/dev/null \
    || fail "teardown revoked a workspace the operator had trusted themselves"
  pass "teardown: a grant firstmate did not add is left alone"
}

test_agy_trust_write_preserves_order_and_duplicates
test_agy_teardown_retires_only_the_grant_it_added
test_agy_teardown_keeps_a_grant_the_operator_already_had
