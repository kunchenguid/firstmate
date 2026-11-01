#!/usr/bin/env bash
# Behavior tests for the durable session/account pin that keeps a Geris firstmate
# and a personal firstmate from ever mixing (bin/fm-home-identity.sh, and its
# gates in fm-spawn.sh, fm-send.sh, and fm-control.sh).
#
# Both directions are proved, not just one: a home pinned to the work session
# refuses a personal session, and a home pinned to the personal session refuses
# the work session. Every fixture store is a throwaway directory, so no case
# reads or depends on a real credential store.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

IDENTITY="$ROOT/bin/fm-home-identity.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-identity)

# Two throwaway "accounts" standing in for the work and personal Claude stores.
GERIS_STORE="$TMP_ROOT/store-geris"
mkdir -p "$GERIS_STORE/projects"

# identity <home> <session> <store> <args...>
identity() {
  local home=$1 session=$2 store=$3
  shift 3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    HERDR_SESSION="$session" CLAUDE_CONFIG_DIR="$store" \
    "$IDENTITY" "$@" 2>&1
}

new_home() {  # <dir>
  mkdir -p "$1/data" "$1/state" "$1/config" "$1/projects"
  printf '%s\n' "$1"
}

test_a_home_refuses_the_other_session_in_both_directions() {
  local work personal out status
  work=$(new_home "$TMP_ROOT/both/work")
  personal=$(new_home "$TMP_ROOT/both/personal")

  identity "$work" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning a fresh home from its own session must succeed"
  out=$(identity "$work" default "" ensure); status=$?
  expect_code 3 "$status" "a work-pinned home must refuse a personal session"
  assert_contains "$out" "belongs to session geris" "the refusal must name the home's own session"
  assert_contains "$out" "never migrated or merged" "the refusal must rule out migration"

  identity "$personal" default "" ensure >/dev/null \
    || fail "pinning a personal home from its own session must succeed"
  out=$(identity "$personal" geris "$GERIS_STORE" ensure); status=$?
  expect_code 3 "$status" "a personal-pinned home must refuse the work session"
  assert_contains "$out" "belongs to session default" "the refusal must name the home's own session"

  # And neither refusal rewrote anything.
  assert_grep "herdr_session=geris" "$work/data/home-identity" \
    "a refused session must not re-pin the work home"
  assert_grep "herdr_session=default" "$personal/data/home-identity" \
    "a refused session must not re-pin the personal home"
  pass "a firstmate home refuses the other session in both directions"
}

test_the_pin_survives_a_restart() {
  local home out
  home=$(new_home "$TMP_ROOT/restart/home")
  identity "$home" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning must succeed"

  # A restart is simply the next process: nothing is held in memory.
  out=$(identity "$home" geris "$GERIS_STORE" check)
  assert_contains "$out" "session=geris" "a later process must read the same pin"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$IDENTITY" store 2>&1)
  [ "$out" = "$GERIS_STORE" ] \
    || fail "the recorded account must survive a restart, got: $out"
  pass "the session and account pin survives a restart"
}

test_an_unreadable_pin_is_never_replaced() {
  local home out status
  home=$(new_home "$TMP_ROOT/corrupt/home")
  identity "$home" geris "$GERIS_STORE" ensure >/dev/null || fail "pinning must succeed"
  printf 'garbage\n' > "$home/data/home-identity"

  out=$(identity "$home" default "" ensure); status=$?
  expect_code 3 "$status" "an unreadable pin must refuse rather than re-pin"
  assert_contains "$out" "repair it deliberately" "the refusal must name the repair as deliberate"
  assert_grep "garbage" "$home/data/home-identity" \
    "a refused read must leave the recorded identity untouched"
  pass "an unreadable identity is refused, never replaced from the environment"
}

# --- real entry-point gates -------------------------------------------------

make_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != "-l" ] || printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# gate_case <name> <task-id> -> "<home>|<proj>|<wt>|<fakebin>|<launchlog>"
gate_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  new_home "$home" >/dev/null
  mkdir -p "$home/data/$id"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  printf 'Delivery contract: mode=no-mistakes\n' >> "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

run_spawn_as() {  # <home> <proj> <wt> <fakebin> <launchlog> <session> <store> <args...>
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 session=$6 store=$7
  shift 7
  : > "$launchlog"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    HERDR_SESSION="$session" CLAUDE_CONFIG_DIR="$store" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" "$proj" --mode no-mistakes --yolo off 2>&1
}

captured_launch() { # <launchlog>
  local source
  source=$(<"$1")
  source=${source#". '"}
  source=${source%"'"}
  [ -f "$source" ] || fail 'the worker launch file was not staged'
  printf '%s\n' "$(<"$source")"
}

test_spawn_refuses_a_foreign_session_and_creates_nothing() {
  local home proj wt fakebin launchlog out status
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case spawn-foreign task-g)"

  out=$(run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" geris "$GERIS_STORE" task-g) \
    || fail "the first spawn from the home's own session must succeed: $out"
  assert_present "$home/state/task-g.meta" "the released spawn must publish its record"
  rm -f "$home/state/task-g.meta"

  out=$(run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" default "" task-g); status=$?
  [ "$status" -ne 0 ] || fail "a spawn from a foreign session must be refused"
  assert_contains "$out" "does not belong to the current session" \
    "the refusal must name the session mismatch"
  assert_absent "$home/state/task-g.meta" "a refused spawn must create no task record"
  [ ! -s "$launchlog" ] || fail "a refused spawn must send no launch command"
  pass "a spawn from a session the home does not belong to is refused and creates nothing"
}

test_a_foreign_session_refusal_is_not_blamed_on_a_refusing_backlog() {
  local home proj wt fakebin launchlog out status
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case spawn-foreign-backlog task-h)"

  identity "$home" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning the home must succeed"
  mkdir -p "$TMP_ROOT/spawn-foreign-backlog/outside"
  printf 'backend = "markdown"\n' > "$TMP_ROOT/spawn-foreign-backlog/outside/tasks.toml"
  ln -s "$TMP_ROOT/spawn-foreign-backlog/outside/tasks.toml" "$home/.tasks.toml"
  printf '# Backlog\n' > "$home/data/backlog.md"

  out=$(run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" default "" task-h); status=$?
  [ "$status" -ne 0 ] || fail "a spawn from a foreign session must be refused"
  assert_contains "$out" "does not belong to the current session" \
    "a refusing backlog preflight must not hide the session mismatch"
  assert_not_contains "$out" "backlog data directory is inaccessible" \
    "a session mismatch must not be blamed on the backlog data directory"
  assert_absent "$home/state/task-h.meta" "a refused spawn must create no task record"
  pass "a foreign session refusal wins over an unrelated backlog preflight refusal"
}

test_a_secondmate_spawn_from_a_foreign_session_changes_nothing() {
  local home proj wt fakebin launchlog child out status before after
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case spawn-sm-foreign sm-a)"

  # A seeded second-mate home of its own: the spawn's secondmate path would
  # fast-forward this checkout, create its state directory, and copy the
  # parent's local config into it before ever reaching the identity guard.
  child="$TMP_ROOT/spawn-sm-foreign/child"
  fm_git_worktree "$TMP_ROOT/spawn-sm-foreign/child-origin" "$child" sm-child
  mkdir -p "$child/bin" "$child/data" "$child/config" "$child/projects"
  printf 'sm-a\n' > "$child/.fm-secondmate-home"
  printf '# child home\n' > "$child/AGENTS.md"

  identity "$home" geris "$GERIS_STORE" ensure >/dev/null \
    || fail "pinning the parent home must succeed"
  printf '/some/work/store\n' > "$home/config/claude-shaped-store"

  before=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    HERDR_SESSION=default CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" sm-a "$child" --secondmate 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn from a foreign session must be refused"
  assert_contains "$out" "does not belong to the current session" \
    "the refusal must name the session mismatch"
  after=$(cd "$child" && { git rev-parse HEAD; find . -path ./.git -prune -o -print | sort; })
  [ "$before" = "$after" ] \
    || fail "a refused secondmate spawn changed the child home:"$'\n'"--- before ---"$'\n'"$before"$'\n'"--- after ---"$'\n'"$after"
  assert_absent "$child/state" "a refused secondmate spawn must create no child state directory"
  assert_absent "$child/config/claude-shaped-store" \
    "a refused secondmate spawn must copy no parent config into the child home"
  assert_absent "$child/data/home-identity" \
    "a refused secondmate spawn must not pin the child home"
  pass "a secondmate spawn from a foreign session refuses before touching the child home"
}

test_a_worker_records_the_account_its_home_is_pinned_to() {
  local home proj wt fakebin launchlog launch
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case relaunch-binding task-w)"

  run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" geris "$GERIS_STORE" task-w >/dev/null \
    || fail "the first spawn must succeed"
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/state/task-w.meta" \
    "a first launch must record the account its home is pinned to"
  launch=$(captured_launch "$launchlog")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$GERIS_STORE'" \
    "the worker must launch on its home's account"
  assert_not_contains "$launch" "-u CLAUDE_CONFIG_DIR" \
    "a work-bound worker must be given its account, not have one unset"
  pass "a worker records and launches on the account its home is pinned to"
}

test_a_personal_worker_is_never_handed_a_work_account() {
  local home proj wt fakebin launchlog launch
  IFS='|' read -r home proj wt fakebin launchlog <<< "$(gate_case personal-binding task-p)"

  # A personal home: no CLAUDE_CONFIG_DIR at all.
  run_spawn_as "$home" "$proj" "$wt" "$fakebin" "$launchlog" default "" task-p >/dev/null \
    || fail "the personal spawn must succeed"
  assert_grep "claude_config_dir=default" "$home/state/task-p.meta" \
    "a personal launch must record the default-store binding"
  launch=$(captured_launch "$launchlog")
  assert_contains "$launch" "-u CLAUDE_CONFIG_DIR" \
    "a personal worker must actively unset any inherited work account"
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "a personal worker must never be handed a work account"
  pass "a personal worker records the default account and is never handed a work one"
}

test_send_refuses_a_foreign_session() {
  local home out status
  home=$(new_home "$TMP_ROOT/send-foreign/home")
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" HERDR_SESSION=geris \
    CLAUDE_CONFIG_DIR="$GERIS_STORE" "$IDENTITY" ensure >/dev/null \
    || fail "pinning must succeed"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    HERDR_SESSION=default CLAUDE_CONFIG_DIR='' "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a message driven from a foreign session must be refused"
  assert_contains "$out" "belongs to session geris" \
    "the refusal must name the home's own session"
  pass "a message driven from a foreign session is refused"
}

test_a_phantom_home_is_never_pinned() {
  local out status missing rel
  missing="$TMP_ROOT/phantom/never-created"

  out=$(FM_HOME="$missing" HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$IDENTITY" ensure 2>&1); status=$?
  expect_code 3 "$status" "a home directory that does not exist must not be pinned"
  assert_absent "$missing" "a refused pin must not materialize the home"

  out=$(FM_HOME="$missing" FM_STATE_OVERRIDE="$missing/state" \
    HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a send against a non-existent home must be refused"
  assert_contains "$out" "is not a directory" \
    "the refusal must be the home-directory error, not an identity pin"
  assert_absent "$missing" "a refused send must not materialize the home"

  # A relative FM_HOME would otherwise pin a phantom home under the caller's
  # working directory.
  rel=$TMP_ROOT/phantom/cwd
  mkdir -p "$rel"
  out=$(cd "$rel" && FM_HOME=not-a-home FM_STATE_OVERRIDE=not-a-home/state \
    HERDR_SESSION=geris CLAUDE_CONFIG_DIR="$GERIS_STORE" \
    "$SEND" some-task "hello" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a send against a relative non-home must be refused"
  assert_absent "$rel/not-a-home" \
    "a relative FM_HOME must leave no identity record in the working directory"
  pass "an FM_HOME that is not an existing home is refused and never pinned"
}

test_a_home_pins_itself_on_first_use() {
  local home out
  home=$(new_home "$TMP_ROOT/firstuse/home")
  assert_absent "$home/data/home-identity" "a fresh home starts unpinned"
  out=$(identity "$home" geris "$GERIS_STORE" ensure)
  assert_contains "$out" "pinned now" "a fresh home must be pinned by its first session"
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/data/home-identity" \
    "the pin must record the account the session uses"
  pass "an unpinned home takes the identity of the session that first uses it"
}

test_rebind() {
  local home child out status pid mode
  home=$(new_home "$TMP_ROOT/rebind/home")
  child=$(new_home "$TMP_ROOT/rebind/child")
  mkdir -p "$TMP_ROOT/rebind/empty" "$TMP_ROOT/rebind/new-store"
  touch "$TMP_ROOT/rebind/new-store/.credentials.json"
  identity "$home" personal "$GERIS_STORE" ensure >/dev/null || fail 'initial pin'
  identity "$child" personal "$GERIS_STORE" ensure >/dev/null || fail 'child pin'
  printf 'claude_config_dir=%s\n' "$GERIS_STORE" > "$home/state/running.meta"
  printf -- '- child - Local mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$child" > "$home/data/secondmates.md"
  printf -- '- remote - Remote mate. (host: example; root: /code; home: /remote; scope: test; projects: none; added 2026-11-01)\n' >> "$home/data/secondmates.md"
  printf -- '- missing - Missing mate. (home: /nonexistent-fm-rebind-test; scope: test; projects: none; added 2026-11-01)\n' >> "$home/data/secondmates.md"
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$TMP_ROOT/rebind/new-store"); status=$?
  expect_code 2 "$status" 'rebind requires confirmation'
  assert_absent "$home/data/home-identity.history" 'no history on refusal'
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$TMP_ROOT/rebind/empty" --confirm); status=$?
  expect_code 3 "$status" 'credential-free store refuses'
  cp "$(command -v sleep)" "$TMP_ROOT/rebind/claude"
  "$TMP_ROOT/rebind/claude" 120 & pid=$!
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$TMP_ROOT/rebind/new-store" --confirm); status=$?
  kill "$pid"; wait "$pid" 2>/dev/null || true
  expect_code 3 "$status" 'live harness lock refuses'
  assert_contains "$out" 'exit the live harness session first' 'actionable refusal'
  assert_grep "$pid" "$home/state/.lock" 'live lock was not deleted'
  assert_absent "$home/data/home-identity.history" 'no history on live-lock refusal'
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$TMP_ROOT/rebind/new-store" --confirm) || fail "rebind: $out"
  assert_contains "$out" 'old identity: session=personal' 'old identity printed'
  assert_contains "$out" "new identity: session=personal store=$TMP_ROOT/rebind/new-store" 'session preserved'
  assert_contains "$out" 'secondmate child: re-pinned' 'local child propagated'
  assert_contains "$out" 'secondmate remote: skipped (remote)' 'remote reported'
  assert_contains "$out" 'secondmate missing: skipped (unreachable:' 'missing reported'
  grep -Eq '^# rebound at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$home/data/home-identity.history" || fail 'UTC timestamp recorded'
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/data/home-identity.history" 'old pin archived'
  assert_grep "claude_config_dir=$GERIS_STORE" "$child/data/home-identity.history" 'child old pin archived'
  assert_grep "claude_config_dir=$GERIS_STORE" "$home/state/running.meta" 'running task unchanged'
  assert_grep "$pid" "$home/state/.lock" 'stale lock left for next session'
  mode=$(stat -c %a "$home/data/home-identity" 2>/dev/null || stat -f %Lp "$home/data/home-identity")
  [ "$mode" = 600 ] || fail 'pin must be 0600'
  identity "$child" personal "$TMP_ROOT/rebind/new-store" check >/dev/null || fail 'child new identity'
  out=$(identity "$home" geris "$TMP_ROOT/rebind/new-store" check); status=$?
  expect_code 3 "$status" 'mismatched session still refuses after rebind'
  out=$(identity "$home" personal "$GERIS_STORE" check); status=$?
  expect_code 3 "$status" 'old account still refuses after rebind'
  identity "$home" personal "$GERIS_STORE" rebind --store "$TMP_ROOT/rebind/new-store" --session personal --confirm >/dev/null || fail 'explicit session'
  # Back to the first subscription without changing the terminal session.
  touch "$GERIS_STORE/.credentials.json"
  identity "$home" personal "$TMP_ROOT/rebind/new-store" rebind --store "$GERIS_STORE" --confirm >/dev/null || fail 'switch back'
  identity "$home" personal "$GERIS_STORE" check >/dev/null || fail 'original account restored'
  out=$(REBIND_SEED=1 identity "$home" personal "$GERIS_STORE" seed "$child" personal "$TMP_ROOT/rebind/new-store"); status=$?
  expect_code 3 "$status" 'seed cannot gain replacement authority from the environment'
  mkdir -p "$TMP_ROOT/rebind/user/.claude"
  touch "$TMP_ROOT/rebind/user/.claude/.credentials.json"
  HOME="$TMP_ROOT/rebind/user" identity "$home" personal "$GERIS_STORE" rebind --store default --confirm >/dev/null || fail 'default store rebind'
  HOME="$TMP_ROOT/rebind/user" identity "$home" personal '' check >/dev/null || fail 'default binding unsets account variable'
  pass 'rebind confirmation, credentials, live lock, history, local propagation, and session isolation'
}

test_rebind_skips_a_live_secondmate_and_its_subtree_until_rerun() {
  local base home child nested new pid out history_lines
  base="$TMP_ROOT/rebind-live"
  home=$(new_home "$base/home"); child=$(new_home "$base/child"); nested=$(new_home "$base/nested")
  new="$base/new-store"
  mkdir -p "$new"; touch "$new/.credentials.json"
  identity "$home" personal "$GERIS_STORE" ensure >/dev/null || fail 'home pin'
  identity "$child" personal "$GERIS_STORE" ensure >/dev/null || fail 'child pin'
  identity "$nested" personal "$GERIS_STORE" ensure >/dev/null || fail 'nested pin'
  printf -- '- child - Local mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$child" > "$home/data/secondmates.md"
  printf -- '- nested - Nested mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$nested" > "$child/data/secondmates.md"
  # A registry cycle must terminate instead of recursing forever.
  printf -- '- back - Cycle. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$home" > "$nested/data/secondmates.md"

  cp "$(command -v sleep)" "$base/claude"
  "$base/claude" 120 & pid=$!
  printf '%s\n' "$pid" > "$child/state/.lock"
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$new" --confirm) \
    || { kill "$pid"; fail "a live second mate must not fail the rebind: $out"; }
  assert_contains "$out" 'secondmate child: skipped (live session)' 'the live mate is reported as skipped'
  assert_not_contains "$out" 'secondmate child: re-pinned' 'the live mate is not reported as moved'
  identity "$child" personal "$GERIS_STORE" check >/dev/null || fail 'the live mate keeps its identity'
  identity "$nested" personal "$GERIS_STORE" check >/dev/null || fail 'a live mate keeps its subtree on the matching identity'
  identity "$home" personal "$new" check >/dev/null || fail 'the home itself still moved'
  assert_absent "$child/state/.lock.acquire" 'the startup claim on the mate is released'
  assert_grep "$pid" "$child/state/.lock" 'the live lock is untouched'
  kill "$pid"; wait "$pid" 2>/dev/null || true

  history_lines=$(grep -c '^# rebound at' "$home/data/home-identity.history")
  out=$(identity "$home" personal "$new" rebind --store "$new" --confirm) || fail "re-run: $out"
  assert_contains "$out" 'secondmate child: re-pinned' 'a re-run moves the exited mate'
  assert_contains "$out" 'secondmate nested: re-pinned' 'a re-run reaches the nested mate'
  identity "$child" personal "$new" check >/dev/null || fail 'child on the new identity'
  identity "$nested" personal "$new" check >/dev/null || fail 'nested mate on the new identity'
  [ "$history_lines" = "$(grep -c '^# rebound at' "$home/data/home-identity.history")" ] \
    || fail 'a re-run to the same identity must not archive a move that did not happen'

  out=$(identity "$home" personal "$new" rebind --store "$new" --confirm) || fail "second re-run: $out"
  assert_contains "$out" 'secondmate child: already on the new identity' 'a settled mate is not reported as moved'
  pass 'rebind skips a live second mate with its subtree and a re-run moves them'
}

test_rebind_keeps_a_worker_pinned_secondmate_acceptable_to_spawn_verify() {
  local base home child new worker out
  base="$TMP_ROOT/rebind-worker-pin"
  home=$(new_home "$base/home"); child=$(new_home "$base/child")
  new="$base/new-store"; worker="$base/worker-store"
  mkdir -p "$new" "$worker"; touch "$new/.credentials.json"
  identity "$home" personal "$GERIS_STORE" ensure >/dev/null || fail 'home pin'
  identity "$child" personal "$worker" ensure >/dev/null || fail 'child pin'
  printf -- '- child - Local mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$child" > "$home/data/secondmates.md"
  printf '%s\n' "$worker" > "$home/config/claude-account"
  printf 'claude\n' > "$home/config/secondmate-harness"
  out=$(identity "$home" personal "$GERIS_STORE" rebind --store "$new" --confirm) || fail "rebind: $out"
  identity "$home" personal "$new" verify "$child" personal "$worker" >/dev/null \
    || fail 'the store spawn binds a worker-pinned mate to must stay accepted'

  printf 'codex\n' > "$home/config/secondmate-harness"
  out=$(identity "$home" personal "$new" rebind --store "$GERIS_STORE" --confirm) || fail "rebind back: $out"
  identity "$home" personal "$GERIS_STORE" verify "$child" personal "$GERIS_STORE" >/dev/null \
    || fail 'a Claude worker pin does not bind a second mate on another harness'
  pass 'rebind pins a second mate to the store its launch selects'
}

test_rebind_decides_an_undetectable_harness_from_the_recorded_launch() {
  local base home mate other orphan new worker out harness h
  base="$TMP_ROOT/rebind-unknown-harness"
  home=$(new_home "$base/home"); mate=$(new_home "$base/mate")
  other=$(new_home "$base/other"); orphan=$(new_home "$base/orphan")
  new="$base/new-store"; worker="$base/worker-store"
  mkdir -p "$new" "$worker" "$base/blind"; touch "$new/.credentials.json"
  printf '#!/bin/sh\nexit 0\n' > "$base/blind/ps"; chmod +x "$base/blind/ps"
  for h in "$home" "$mate" "$other" "$orphan"; do
    identity "$h" personal "$GERIS_STORE" ensure >/dev/null || fail "pin $h"
  done
  {
    printf -- '- mate - Claude mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$mate"
    printf -- '- other - Codex mate. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$other"
    printf -- '- orphan - No record. (home: %s; scope: test; projects: none; added 2026-11-01)\n' "$orphan"
  } > "$home/data/secondmates.md"
  printf '%s\n' "$worker" > "$home/config/claude-account"
  printf 'harness=claude\n' > "$home/state/mate.meta"
  printf 'harness=codex\n' > "$home/state/other.meta"

  plain_shell() {
    env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u CURSOR_AGENT \
      -u CURSOR_INVOKED_AS -u FM_SUPERVISION_ACTOR -u FM_SUPERVISION_PRIMARY_HARNESS \
      PATH="$base/blind:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      HERDR_SESSION=personal CLAUDE_CONFIG_DIR="$GERIS_STORE" "$@"
  }
  harness=$(plain_shell "$ROOT/bin/fm-harness.sh" secondmate)
  [ "$harness" = unknown ] || fail "the fixture must be undetectable, got '$harness'"
  out=$(plain_shell "$IDENTITY" rebind --store "$new" --confirm 2>&1) || fail "rebind: $out"

  identity "$home" personal "$new" verify "$mate" personal "$worker" >/dev/null \
    || fail 'a recorded Claude mate must stay on the store spawn binds it to'
  identity "$home" personal "$new" verify "$other" personal "$new" >/dev/null \
    || fail 'a recorded non-Claude mate must follow the home'
  assert_contains "$out" 'secondmate orphan: skipped (harness undecidable' 'an undecidable mate is reported'
  identity "$home" personal "$new" verify "$orphan" personal "$GERIS_STORE" >/dev/null \
    || fail 'an undecidable mate keeps its identity'
  pass 'rebind in a plain shell pins by recorded harness and skips an undecidable mate'
}

# Throwaway HOME with both stub logins, a home pinned to personal, and a stub
# claude that records what it was started with. Sets OPEN_* for open_home.
open_case() {  # <name>
  OPEN_BASE="$TMP_ROOT/$1"
  OPEN_USER="$OPEN_BASE/user"
  OPEN_HOME=$(new_home "$OPEN_BASE/home")
  OPEN_LOG="$OPEN_BASE/launch"
  mkdir -p "$OPEN_USER/.claude" "$OPEN_USER/.claude-geris" "$OPEN_BASE/bin"
  touch "$OPEN_USER/.claude/.credentials.json" "$OPEN_USER/.claude-geris/.credentials.json"
  OPEN_USER=$(cd "$OPEN_USER" && pwd -P)
  OPEN_HOME=$(cd "$OPEN_HOME" && pwd -P)
  cat > "$OPEN_BASE/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'store=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
  printf 'session=%s\n' "${HERDR_SESSION-unset}"
  printf 'api_key=%s\n' "${ANTHROPIC_API_KEY-unset}"
  printf 'args=%s\n' "$*"
} > "$FM_OPEN_TEST_LOG"
STUB
  cat > "$OPEN_BASE/bin/herdr" <<'STUB'
#!/bin/sh
touch "$FM_OPEN_TEST_LOG.herdr"
STUB
  chmod +x "$OPEN_BASE/bin/claude" "$OPEN_BASE/bin/herdr"
  identity "$OPEN_HOME" personal "$OPEN_USER/.claude" ensure >/dev/null || fail 'open home pin'
}

open_home() {  # <session> <fm-open args...>
  local session=$1
  shift
  HOME="$OPEN_USER" FM_HOME="$OPEN_HOME" HERDR_SESSION="$session" \
    CLAUDE_CONFIG_DIR="$OPEN_USER/.claude" ANTHROPIC_API_KEY=ambient \
    PATH="$OPEN_BASE/bin:$PATH" FM_OPEN_TEST_LOG="$OPEN_LOG" \
    "$ROOT/bin/fm-open.sh" "$@" 2>&1
}

test_fm_open_starts_the_same_home_on_either_subscription() {
  local out log
  open_case open-both
  out=$(open_home personal geris --model opus --continue) || fail "geris launch: $out"
  log=$(cat "$OPEN_LOG")
  assert_contains "$log" "cwd=$OPEN_HOME" 'Claude starts from the home'
  assert_contains "$log" "store=$OPEN_USER/.claude-geris" 'Claude gets the chosen store'
  assert_contains "$log" 'session=personal' 'the Herdr session stays personal'
  assert_contains "$log" 'api_key=unset' 'an ambient credential cannot outrank the chosen store'
  assert_contains "$log" 'args=--dangerously-skip-permissions --model opus --continue' 'the cc posture and caller args reach Claude'
  identity "$OPEN_HOME" personal "$OPEN_USER/.claude-geris" check >/dev/null || fail 'the pin follows the launch'
  assert_absent "$OPEN_LOG.herdr" 'the launcher never runs Herdr'

  out=$(open_home personal personal) || fail "personal launch: $out"
  assert_contains "$(cat "$OPEN_LOG")" "store=$OPEN_USER/.claude" 'the same home starts back on personal'
  identity "$OPEN_HOME" personal "$OPEN_USER/.claude" check >/dev/null || fail 'the pin moved back'
  identity "$OPEN_HOME" personal "$OPEN_USER/.claude-geris" check >/dev/null && fail 'the previous store is refused'
  [ "$(grep -c '^# rebound at' "$OPEN_HOME/data/home-identity.history")" = 2 ] || fail 'each move is kept in history'

  out=$(open_home personal personal) || fail "repeat launch: $out"
  [ "$(grep -c '^# rebound at' "$OPEN_HOME/data/home-identity.history")" = 2 ] || fail 'the same account adds no history'

  out=$(HOME="$OPEN_USER" FM_HOME="$OPEN_HOME" HERDR_SESSION=personal "$IDENTITY" rebind --store default --confirm 2>&1) \
    || fail "default restore: $out"
  identity "$OPEN_HOME" personal '' check >/dev/null || fail 'a default pin accepts an unset CLAUDE_CONFIG_DIR'
  identity "$OPEN_HOME" personal "$OPEN_USER/.claude" check >/dev/null && fail 'a default pin refuses the explicit path'
  [ "$(grep -c '^# rebound at' "$OPEN_HOME/data/home-identity.history")" = 3 ] || fail 'the restore keeps history'
  pass 'fm-open starts one home on either subscription, reversibly'
}

test_fm_open_refuses_without_starting_claude() {
  local out rc pid before
  open_case open-refuse
  before=$(cat "$OPEN_HOME/data/home-identity")

  out=$(open_home personal); expect_code 2 $? "no account: $out"
  out=$(open_home personal work); expect_code 2 $? "unknown account: $out"
  out=$(open_home geris geris); rc=$?
  expect_code 3 "$rc" "another session: $out"

  mkdir -p "$OPEN_BASE/sleeper"
  cp "$(command -v sleep)" "$OPEN_BASE/sleeper/claude"
  "$OPEN_BASE/sleeper/claude" 120 & pid=$!
  printf '%s\n' "$pid" > "$OPEN_HOME/state/.lock"
  out=$(open_home personal geris); rc=$?
  expect_code 3 "$rc" "live lock: $out"
  assert_contains "$out" 'its session lock is held' 'the live lock is named'
  assert_grep "$pid" "$OPEN_HOME/state/.lock" 'the live lock is untouched'
  kill "$pid"; wait "$pid" 2>/dev/null || true
  rm -f "$OPEN_HOME/state/.lock"

  rm "$OPEN_USER/.claude-geris/.credentials.json"
  out=$(open_home personal geris); rc=$?
  expect_code 3 "$rc" "missing login: $out"
  [ "$before" = "$(cat "$OPEN_HOME/data/home-identity")" ] || fail 'a refused launch keeps the pin'

  printf 'fm-home-identity-v1\nherdr_session=work\nclaude_config_dir=%s\n' "$OPEN_USER/.claude" > "$OPEN_HOME/data/home-identity"
  out=$(open_home personal personal); rc=$?
  expect_code 3 "$rc" "home of another session: $out"
  assert_absent "$OPEN_LOG" 'no refusal starts Claude'
  pass 'fm-open refuses a live lock, another session, or a missing login without starting Claude'
}

test_rebind
test_rebind_skips_a_live_secondmate_and_its_subtree_until_rerun
test_rebind_keeps_a_worker_pinned_secondmate_acceptable_to_spawn_verify
test_rebind_decides_an_undetectable_harness_from_the_recorded_launch
test_fm_open_starts_the_same_home_on_either_subscription
test_fm_open_refuses_without_starting_claude
test_a_home_refuses_the_other_session_in_both_directions
test_the_pin_survives_a_restart
test_an_unreadable_pin_is_never_replaced
test_a_home_pins_itself_on_first_use
test_a_phantom_home_is_never_pinned
test_spawn_refuses_a_foreign_session_and_creates_nothing
test_a_foreign_session_refusal_is_not_blamed_on_a_refusing_backlog
test_a_secondmate_spawn_from_a_foreign_session_changes_nothing
test_a_worker_records_the_account_its_home_is_pinned_to
test_a_personal_worker_is_never_handed_a_work_account
test_send_refuses_a_foreign_session
