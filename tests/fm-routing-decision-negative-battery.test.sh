#!/usr/bin/env bash
# Independent failure-direction and mutation battery for ROUTING_DECISION.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-routing-decision-lib.sh
. "$ROOT/bin/fm-routing-decision-lib.sh"

REAL_JQ=$(command -v jq)
REAL_PERL=$(command -v perl)
SPAWN="$ROOT/bin/fm-spawn.sh"
POST_BINDING_RECEIPT_FILTER=
POST_SNAPSHOT_SOURCE_FILTER=
POST_SNAPSHOT_CONFIG_FILTER=
POST_PENDING_DIRECTORY=0
POST_PENDING_RECREATE=0
POST_CONFIG_SYMLINK=0
POST_SNAPSHOT_DIRECTORY_RECREATE=0
POST_SNAPSHOT_AMBIGUOUS_META=0

# One authority guard is defense in depth against the receipt changing after
# its exact configuration binding is checked.
# The fixture mutates at the later source read so that guard is independently
# reachable without a production test bypass.
jq() {
  local tmp rule_filter=".rules[\$index].use"
  if [ -n "$POST_SNAPSHOT_SOURCE_FILTER" ] \
    && [ "$#" -eq 3 ] \
    && [ "$1" = -r ] \
    && [ "$2" = '.matched_profile.source' ]; then
    tmp="$TASK_DIR/routing-decision.pending.json.replacement"
    "$REAL_JQ" "$POST_SNAPSHOT_SOURCE_FILTER" "$TASK_DIR/routing-decision.pending.json" > "$tmp" || return 1
    mv "$tmp" "$TASK_DIR/routing-decision.pending.json" || return 1
    POST_SNAPSHOT_SOURCE_FILTER=
  fi
  if [ -n "$POST_SNAPSHOT_CONFIG_FILTER" ] \
    && [ "$#" -ge 1 ] \
    && [ "${!#}" != "$HOME_DIR/config/crew-dispatch.json" ] \
    && [[ "$*" == *"$rule_filter"* ]]; then
    tmp="$HOME_DIR/config/crew-dispatch.json.replacement"
    "$REAL_JQ" "$POST_SNAPSHOT_CONFIG_FILTER" "$HOME_DIR/config/crew-dispatch.json" > "$tmp" || return 1
    mv "$tmp" "$HOME_DIR/config/crew-dispatch.json" || return 1
    POST_SNAPSHOT_CONFIG_FILTER=
  fi
  if [ -n "$POST_BINDING_RECEIPT_FILTER" ] \
    && [ "$#" -eq 3 ] \
    && [ "$1" = -r ] \
    && [ "$2" = '.matched_profile.source' ]; then
    tmp="$3.post-binding"
    "$REAL_JQ" "$POST_BINDING_RECEIPT_FILTER" "$3" > "$tmp" || return 1
    mv "$tmp" "$3" || return 1
  fi
  "$REAL_JQ" "$@"
}

perl() {
  local operation=${2:-} status result snapshot_name snapshot_path
  if [ "$operation" = snapshot ] && [ "$POST_CONFIG_SYMLINK" -eq 1 ]; then
    mv "$HOME_DIR/config/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.original.json" || return 1
    ln -s "$LAB/relocated-config/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.json" || return 1
    POST_CONFIG_SYMLINK=0
  fi
  if [ "$operation" = publish ] && [ "$POST_PENDING_RECREATE" -eq 1 ]; then
    mv "$TASK_DIR/routing-decision.pending.json" "$TASK_DIR/routing-decision.original.json" || return 1
    mkdir "$TASK_DIR/routing-decision.pending.json" || return 1
    printf 'replacement directory sentinel\n' > "$TASK_DIR/routing-decision.pending.json/sentinel" || return 1
    "$REAL_PERL" "$@"
    status=$?
    POST_PENDING_RECREATE=0
    return "$status"
  fi
  if [ "$operation" = publish ] && [ "$POST_PENDING_DIRECTORY" -eq 1 ]; then
    mv "$TASK_DIR/routing-decision.pending.json" "$TASK_DIR/routing-decision.original.json" || return 1
    mkdir "$TASK_DIR/routing-decision.pending.json" || return 1
    printf 'replacement directory sentinel\n' > "$TASK_DIR/routing-decision.pending.json/sentinel" || return 1
    POST_PENDING_DIRECTORY=0
  fi
  result=$("$REAL_PERL" "$@" 2>&1)
  status=$?
  if [ "$operation" = snapshot ] \
    && [ "$status" -eq 0 ] \
    && [ "$POST_SNAPSHOT_DIRECTORY_RECREATE" -eq 1 ]; then
    snapshot_name=${result%%$'\t'*}
    snapshot_path="$3/$snapshot_name"
    mv "$snapshot_path" "$snapshot_path.original" || return 1
    mkdir "$snapshot_path" || return 1
    cp -R "$snapshot_path.original/." "$snapshot_path/" || return 1
    POST_SNAPSHOT_DIRECTORY_RECREATE=0
  fi
  if [ "$operation" = snapshot ] \
    && [ "$status" -eq 0 ] \
    && [ "$POST_SNAPSHOT_AMBIGUOUS_META" -eq 1 ]; then
    {
      printf 'routing_decision=%s\n' "$TASK_DIR/first.json"
      printf 'routing_decision=%s\n' "$TASK_DIR/second.json"
    } > "$HOME_DIR/state/t1.meta" || return 1
    cp "$HOME_DIR/state/t1.meta" "$LAB/meta.before" || return 1
    POST_SNAPSHOT_AMBIGUOUS_META=0
  fi
  printf '%s\n' "$result"
  return "$status"
}

TMP_ROOT=$(fm_test_tmproot fm-routing-decision-negative-battery)
LAB="$TMP_ROOT/lab"
HOME_DIR="$LAB/home"
TASK_DIR="$HOME_DIR/data/t1"
RAW_HARNESS_BIN="$TMP_ROOT/raw-harness-bin"
mkdir -p "$RAW_HARNESS_BIN"
for executable in claude codex opencode pi pi-signed grok kimi muse cursor-agent; do
  printf '#!/bin/sh\nexit 0\n' > "$RAW_HARNESS_BIN/$executable"
  chmod +x "$RAW_HARNESS_BIN/$executable"
done
PATH="$RAW_HARNESS_BIN:$PATH"
export PATH
RUN_HARNESS=claude
RUN_MODEL=opus
RUN_EFFORT=high
RUN_RAW=0
RUN_LAUNCH='claude verified template'
RUN_MODEL_FRAGMENT="--model 'opus' "
RUN_EFFORT_FRAGMENT="--effort 'high' "
negative_count=0
counterexample_count=0
raw_guard_counterexample_count=0
fresh_spawn_negative_count=0
fresh_spawn_counterexample_count=0
committed_handoff_negative_count=0
raw_launch_acceptance_count=0
PREEXISTING_FINAL=0
PREEXISTING_META=0
RUN_CWD=
RELAUNCH_COUNTEREXAMPLE_ROOT="$TMP_ROOT/relaunch-counterexample-root"
RELAUNCH_PROJECT=
RELAUNCH_WT=
RELAUNCH_PANE_LOG=
RELAUNCH_ENDPOINT_LOG=
RELAUNCH_LEASE_LOG=
FRESH_PROJECT=
FRESH_WT=
FRESH_PANE_LOG=
FRESH_ENDPOINT_LOG=
FRESH_TEXT_LOG=
FRESH_LEASE_LOG=
COMMITTED_HANDOFF_FAULT=

prepare_relaunch_counterexample_root() {
  mkdir -p "$RELAUNCH_COUNTEREXAMPLE_ROOT"
  cp -R "$ROOT/bin" "$RELAUNCH_COUNTEREXAMPLE_ROOT/bin"
  cat >> "$RELAUNCH_COUNTEREXAMPLE_ROOT/bin/fm-routing-decision-lib.sh" <<'SH'

# Deliberately neuter the relaunch receipt-requirement owner while retaining a
# valid launch input so each negative assertion proves that this guard fires.
fm_routing_decision_required() {
  FM_ROUTING_BRIEF_FINAL="$DATA/$ID/brief.md"
  FM_ROUTING_BRIEF_HASH=$(fm_routing_sha256_file "$FM_ROUTING_BRIEF_FINAL") || return 1
  fm_operational_verified_file_input \
    launch-brief "$FM_ROUTING_BRIEF_HASH" "$FM_ROUTING_BRIEF_FINAL" FM_ROUTING_LAUNCH_INPUT \
    || return 1
  return 1
}
SH
}

write_relaunch_tmux_stub() {
  cat > "$RAW_HARNESS_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" -eq 1 ]; then
      printf '%s\n' "$payload" >> "$FM_RELAUNCH_TEST_PANE_LOG"
      case "$payload" in
        *claude*) printf 'claude' > "$FM_RELAUNCH_TEST_COMMAND" ;;
      esac
    elif [ -n "${FM_ROUTING_TEST_TEXT_LOG:-}" ]; then
      printf '%s\n' "$payload" >> "$FM_ROUTING_TEST_TEXT_LOG"
    fi
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_current_command*) cat "$FM_RELAUNCH_TEST_COMMAND"; printf '\n'; exit 0 ;;
        *pane_current_path*) printf '%s\n' "$FM_RELAUNCH_TEST_WT"; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  list-windows)
    [ "${FM_ROUTING_TEST_RELAUNCH:-0}" -eq 0 ] || printf 'fm-t1\n'
    exit 0
    ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  new-session|new-window|split-window)
    printf '%s\n' "$*" >> "$FM_RELAUNCH_TEST_ENDPOINT_LOG"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$RAW_HARNESS_BIN/tmux"
  cat > "$RAW_HARNESS_BIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_RELAUNCH_TEST_LEASE_LOG"
exit "${FM_ROUTING_TEST_TREEHOUSE_STATUS:-1}"
SH
  chmod +x "$RAW_HARNESS_BIN/treehouse"

  cat > "$RAW_HARNESS_BIN/perl" <<'SH'
#!/usr/bin/env bash
set -u
operation=${2:-}
task_dir=${3:-}

if [ "$operation" = snapshot ] && [ "${FM_ROUTING_TEST_POST_CONFIG_SYMLINK:-0}" -eq 1 ]; then
  mv "$FM_ROUTING_TEST_HOME/config/crew-dispatch.json" \
    "$FM_ROUTING_TEST_HOME/config/crew-dispatch.original.json" || exit 1
  ln -s "$FM_ROUTING_TEST_LAB/relocated-config/crew-dispatch.json" \
    "$FM_ROUTING_TEST_HOME/config/crew-dispatch.json" || exit 1
fi
if [ "$operation" = publish ] \
  && { [ "${FM_ROUTING_TEST_POST_PENDING_RECREATE:-0}" -eq 1 ] \
    || [ "${FM_ROUTING_TEST_POST_PENDING_DIRECTORY:-0}" -eq 1 ]; }; then
  mv "$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json" \
    "$FM_ROUTING_TEST_TASK_DIR/routing-decision.original.json" || exit 1
  mkdir "$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json" || exit 1
  printf 'replacement directory sentinel\n' \
    > "$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json/sentinel" || exit 1
fi

if [ "$operation" = verify-committed-generation ]; then
  snapshot_path=$4
  generation=$8
  case "${FM_ROUTING_TEST_HANDOFF_FAULT:-}" in
    snapshot-identity)
      mv "$snapshot_path" "$snapshot_path.identity-original" || exit 1
      mkdir "$snapshot_path" || exit 1
      cp -R "$snapshot_path.identity-original/." "$snapshot_path/" || exit 1
      ;;
    generation-mismatch)
      printf '\n' >> "$snapshot_path/data/$7/routing-decision.pending.json" || exit 1
      ;;
    ledger-format)
      printf 'not-a-generation\n' >> "$task_dir/routing-generations.consumed" || exit 1
      ;;
    brief-ownership)
      chmod 0600 "$task_dir/routing-generation.$generation/brief.md" || exit 1
      ;;
    receipt-bytes)
      receipt="$task_dir/routing-generation.$generation/receipt.json"
      chmod 0600 "$receipt" || exit 1
      printf '{"tampered":true}\n' > "$receipt" || exit 1
      chmod 0400 "$receipt" || exit 1
      ;;
  esac
fi

result=$("$FM_TEST_REAL_PERL" "$@" 2>&1)
status=$?

if [ "$operation" = snapshot ] && [ "$status" -eq 0 ]; then
  snapshot_name=${result%%$'\t'*}
  snapshot_path="$task_dir/$snapshot_name"
  if [ "${FM_ROUTING_TEST_POST_SNAPSHOT_RECREATE:-0}" -eq 1 ]; then
    mv "$snapshot_path" "$snapshot_path.original" || exit 1
    mkdir "$snapshot_path" || exit 1
    cp -R "$snapshot_path.original/." "$snapshot_path/" || exit 1
  fi
  if [ "${FM_ROUTING_TEST_POST_AMBIGUOUS_META:-0}" -eq 1 ]; then
    {
      printf 'routing_decision=%s\n' "$FM_ROUTING_TEST_TASK_DIR/first.json"
      printf 'routing_decision=%s\n' "$FM_ROUTING_TEST_TASK_DIR/second.json"
    } > "$FM_ROUTING_TEST_HOME/state/t1.meta" || exit 1
    cp "$FM_ROUTING_TEST_HOME/state/t1.meta" "$FM_ROUTING_TEST_META_BEFORE" || exit 1
  fi
fi

[ -z "$result" ] || printf '%s\n' "$result"
exit "$status"
SH

  cat > "$RAW_HARNESS_BIN/jq" <<'SH'
#!/usr/bin/env bash
set -u
tmp=
rule_filter='.rules[$index].use'
last=${!#}
if [ -n "${FM_ROUTING_TEST_POST_SOURCE_FILTER:-}" ] \
  && [ "$#" -eq 3 ] && [ "$1" = -r ] && [ "$2" = '.matched_profile.source' ]; then
  tmp="$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json.replacement"
  "$FM_TEST_REAL_JQ" "$FM_ROUTING_TEST_POST_SOURCE_FILTER" \
    "$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json" > "$tmp" || exit 1
  mv "$tmp" "$FM_ROUTING_TEST_TASK_DIR/routing-decision.pending.json" || exit 1
fi
if [ -n "${FM_ROUTING_TEST_POST_CONFIG_FILTER:-}" ] \
  && [ "$last" != "$FM_ROUTING_TEST_HOME/config/crew-dispatch.json" ] \
  && [[ "$*" == *"$rule_filter"* ]]; then
  tmp="$FM_ROUTING_TEST_HOME/config/crew-dispatch.json.replacement"
  "$FM_TEST_REAL_JQ" "$FM_ROUTING_TEST_POST_CONFIG_FILTER" \
    "$FM_ROUTING_TEST_HOME/config/crew-dispatch.json" > "$tmp" || exit 1
  mv "$tmp" "$FM_ROUTING_TEST_HOME/config/crew-dispatch.json" || exit 1
fi
if [ -n "${FM_ROUTING_TEST_POST_BINDING_FILTER:-}" ] \
  && [ "$#" -eq 3 ] && [ "$1" = -r ] && [ "$2" = '.matched_profile.source' ]; then
  tmp="$3.post-binding"
  "$FM_TEST_REAL_JQ" "$FM_ROUTING_TEST_POST_BINDING_FILTER" "$3" > "$tmp" || exit 1
  mv "$tmp" "$3" || exit 1
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
  chmod +x "$RAW_HARNESS_BIN/perl" "$RAW_HARNESS_BIN/jq"
}

setup_fresh_spawn_project() {
  FRESH_PROJECT="$LAB/fresh-project"
  FRESH_WT="$LAB/fresh-worktree"
  FRESH_PANE_LOG="$LAB/fresh-pane.log"
  FRESH_ENDPOINT_LOG="$LAB/fresh-endpoint.log"
  FRESH_TEXT_LOG="$LAB/fresh-text.log"
  FRESH_LEASE_LOG="$LAB/fresh-lease.log"
  fm_git_worktree "$FRESH_PROJECT" "$FRESH_WT" fresh-t1
  : > "$FRESH_PANE_LOG"
  : > "$FRESH_ENDPOINT_LOG"
  : > "$FRESH_TEXT_LOG"
  : > "$FRESH_LEASE_LOG"
  printf 'zsh' > "$LAB/fresh-command"
  mkdir -p "$LAB/worker-config/muse"
  printf '{}\n' > "$LAB/worker-config/muse/auth.json"
}

run_fresh_spawn() { # <spawn-path>
  local spawn=$1 harness_arg=$RUN_HARNESS
  [ "$RUN_RAW" -eq 0 ] || harness_arg=$RUN_LAUNCH
  fresh_spawn_command() {
    env PATH="$RAW_HARNESS_BIN:$PATH" FM_HOME="$HOME_DIR" \
      XDG_CONFIG_HOME="$LAB/worker-config" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
      FM_RELAUNCH_TEST_WT="$FRESH_WT" \
      FM_RELAUNCH_TEST_PANE_LOG="$FRESH_PANE_LOG" \
      FM_RELAUNCH_TEST_ENDPOINT_LOG="$FRESH_ENDPOINT_LOG" \
      FM_RELAUNCH_TEST_LEASE_LOG="$FRESH_LEASE_LOG" \
      FM_RELAUNCH_TEST_COMMAND="$LAB/fresh-command" \
      FM_ROUTING_TEST_TEXT_LOG="$FRESH_TEXT_LOG" FM_ROUTING_TEST_RELAUNCH=0 \
      FM_ROUTING_TEST_TREEHOUSE_STATUS=0 \
      FM_TEST_REAL_PERL="$REAL_PERL" FM_TEST_REAL_JQ="$REAL_JQ" \
      FM_ROUTING_TEST_HOME="$HOME_DIR" FM_ROUTING_TEST_TASK_DIR="$TASK_DIR" \
      FM_ROUTING_TEST_LAB="$LAB" FM_ROUTING_TEST_META_BEFORE="$LAB/meta.before" \
      FM_ROUTING_TEST_POST_BINDING_FILTER="$POST_BINDING_RECEIPT_FILTER" \
      FM_ROUTING_TEST_POST_SOURCE_FILTER="$POST_SNAPSHOT_SOURCE_FILTER" \
      FM_ROUTING_TEST_POST_CONFIG_FILTER="$POST_SNAPSHOT_CONFIG_FILTER" \
      FM_ROUTING_TEST_POST_PENDING_DIRECTORY="$POST_PENDING_DIRECTORY" \
      FM_ROUTING_TEST_POST_PENDING_RECREATE="$POST_PENDING_RECREATE" \
      FM_ROUTING_TEST_POST_CONFIG_SYMLINK="$POST_CONFIG_SYMLINK" \
      FM_ROUTING_TEST_POST_SNAPSHOT_RECREATE="$POST_SNAPSHOT_DIRECTORY_RECREATE" \
      FM_ROUTING_TEST_POST_AMBIGUOUS_META="$POST_SNAPSHOT_AMBIGUOUS_META" \
      "$spawn" t1 "$FRESH_PROJECT" --harness "$harness_arg" \
        --model "$RUN_MODEL" --effort "$RUN_EFFORT" --mode no-mistakes --yolo off 2>&1
  }
  if [ -n "$RUN_CWD" ]; then
    (cd "$RUN_CWD" && fresh_spawn_command)
  else
    fresh_spawn_command
  fi
}

exercise_raw_launch_acceptance() { # <harness> <command>
  local harness=$1 command=$2 out status
  write_fixture
  setup_raw_literal "$command"
  setup_fresh_spawn_project
  out=$(run_fresh_spawn "$SPAWN")
  status=$?
  expect_code 0 "$status" "$harness raw launch should succeed"
  [ -s "$FRESH_TEXT_LOG" ] || fail "$harness raw launch did not reach the worktree lease channel"
  [ -s "$FRESH_ENDPOINT_LOG" ] || fail "$harness raw launch did not create an endpoint"
  [ -s "$FRESH_PANE_LOG" ] || fail "$harness raw launch did not send pane input"
  assert_present "$HOME_DIR/state/t1.meta" "$harness raw launch did not publish metadata"
  assert_contains "$(cat "$FRESH_PANE_LOG")" "$command" \
    "$harness raw launch did not emit the caller command"
  case "$harness" in
    pi|pi-signed)
      assert_contains "$(cat "$FRESH_PANE_LOG")" "FM_PI_HARNESS=$harness" \
        "$harness raw launch did not emit its adapter environment"
      ;;
  esac
  raw_launch_acceptance_count=$((raw_launch_acceptance_count + 1))
  pass "$harness raw launch succeeds through fm-spawn with observed route axes"
}

assert_no_fresh_spawn_effects() {
  [ ! -s "$FRESH_TEXT_LOG" ] || fail "routing refusal entered the worktree lease channel"
  [ ! -s "$FRESH_ENDPOINT_LOG" ] || fail "routing refusal created an endpoint"
  [ ! -s "$FRESH_PANE_LOG" ] || fail "routing refusal sent pane input"
  [ ! -s "$FRESH_LEASE_LOG" ] || fail "routing refusal invoked treehouse directly"
  if [ "$PREEXISTING_META" -eq 0 ]; then
    assert_absent "$HOME_DIR/state/t1.meta" "routing refusal published task metadata"
  else
    cmp -s "$LAB/meta.before" "$HOME_DIR/state/t1.meta" \
      || fail "routing refusal changed injected task metadata"
  fi
}

setup_relaunch_task() {
  RELAUNCH_PROJECT="$LAB/relaunch-project"
  RELAUNCH_WT="$LAB/relaunch-worktree"
  RELAUNCH_PANE_LOG="$LAB/relaunch-pane.log"
  RELAUNCH_ENDPOINT_LOG="$LAB/relaunch-endpoint.log"
  RELAUNCH_LEASE_LOG="$LAB/relaunch-lease.log"
  fm_git_worktree "$RELAUNCH_PROJECT" "$RELAUNCH_WT" task-t1
  : > "$RELAUNCH_PANE_LOG"
  : > "$RELAUNCH_ENDPOINT_LOG"
  : > "$RELAUNCH_LEASE_LOG"
  printf 'zsh' > "$LAB/relaunch-command"
  printf '{}\n' > "$TASK_DIR/prior-routing-decision.json"
  {
    echo 'window=fmses:fm-t1'
    echo 'endpoint_task_id=t1'
    echo "worktree=$RELAUNCH_WT"
    echo "project=$RELAUNCH_PROJECT"
    echo 'harness=codex'
    echo 'kind=ship'
    echo 'mode=no-mistakes'
    echo 'yolo=off'
    echo 'tasktmp=/tmp/fm-t1'
    echo 'model=default'
    echo 'effort=default'
    echo "routing_decision=$TASK_DIR/prior-routing-decision.json"
  } > "$HOME_DIR/state/t1.meta"
  cp "$HOME_DIR/state/t1.meta" "$LAB/relaunch-meta.before"
}

setup_secondmate_relaunch_task() {
  local secondmate_home="$LAB/secondmate-home"
  RELAUNCH_WT=$secondmate_home
  RELAUNCH_PANE_LOG="$LAB/relaunch-pane.log"
  RELAUNCH_ENDPOINT_LOG="$LAB/relaunch-endpoint.log"
  RELAUNCH_LEASE_LOG="$LAB/relaunch-lease.log"
  mkdir -p "$secondmate_home/bin"
  printf 't1\n' > "$secondmate_home/.fm-secondmate-home"
  printf '# Secondmate fixture\n' > "$secondmate_home/AGENTS.md"
  : > "$RELAUNCH_PANE_LOG"
  : > "$RELAUNCH_ENDPOINT_LOG"
  : > "$RELAUNCH_LEASE_LOG"
  printf 'zsh' > "$LAB/relaunch-command"
  printf '{}\n' > "$TASK_DIR/prior-routing-decision.json"
  {
    echo 'window=fmses:fm-t1'
    echo 'endpoint_task_id=t1'
    echo "worktree=$secondmate_home"
    echo "project=$secondmate_home"
    echo "home=$secondmate_home"
    echo 'harness=codex'
    echo 'kind=secondmate'
    echo 'mode=secondmate'
    echo 'yolo=off'
    echo 'tasktmp=/tmp/fm-t1'
    echo 'model=default'
    echo 'effort=default'
    echo "routing_decision=$TASK_DIR/prior-routing-decision.json"
  } > "$HOME_DIR/state/t1.meta"
  cp "$HOME_DIR/state/t1.meta" "$LAB/relaunch-meta.before"
}

run_relaunch_spawn() { # <spawn-path>
  local spawn=$1 harness_arg=$RUN_HARNESS
  [ "$RUN_RAW" -eq 0 ] || harness_arg=$RUN_LAUNCH
  env PATH="$RAW_HARNESS_BIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_SPAWN_NO_GUARD=1 \
    FM_RELAUNCH_TEST_WT="$RELAUNCH_WT" \
    FM_RELAUNCH_TEST_PANE_LOG="$RELAUNCH_PANE_LOG" \
    FM_RELAUNCH_TEST_ENDPOINT_LOG="$RELAUNCH_ENDPOINT_LOG" \
    FM_RELAUNCH_TEST_LEASE_LOG="$RELAUNCH_LEASE_LOG" \
    FM_RELAUNCH_TEST_COMMAND="$LAB/relaunch-command" \
    FM_ROUTING_TEST_RELAUNCH=1 FM_ROUTING_TEST_TREEHOUSE_STATUS=1 \
    FM_TEST_REAL_PERL="$REAL_PERL" FM_TEST_REAL_JQ="$REAL_JQ" \
    FM_ROUTING_TEST_HOME="$HOME_DIR" FM_ROUTING_TEST_TASK_DIR="$TASK_DIR" \
    FM_ROUTING_TEST_LAB="$LAB" FM_ROUTING_TEST_META_BEFORE="$LAB/relaunch-meta.before" \
    FM_ROUTING_TEST_POST_BINDING_FILTER="$POST_BINDING_RECEIPT_FILTER" \
    FM_ROUTING_TEST_POST_SOURCE_FILTER="$POST_SNAPSHOT_SOURCE_FILTER" \
    FM_ROUTING_TEST_POST_CONFIG_FILTER="$POST_SNAPSHOT_CONFIG_FILTER" \
    FM_ROUTING_TEST_POST_PENDING_DIRECTORY="$POST_PENDING_DIRECTORY" \
    FM_ROUTING_TEST_POST_PENDING_RECREATE="$POST_PENDING_RECREATE" \
    FM_ROUTING_TEST_POST_CONFIG_SYMLINK="$POST_CONFIG_SYMLINK" \
    FM_ROUTING_TEST_POST_SNAPSHOT_RECREATE="$POST_SNAPSHOT_DIRECTORY_RECREATE" \
    FM_ROUTING_TEST_POST_AMBIGUOUS_META="$POST_SNAPSHOT_AMBIGUOUS_META" \
    "$spawn" t1 --relaunch --harness "$harness_arg" \
      --model "$RUN_MODEL" --effort "$RUN_EFFORT" 2>&1
}

assert_relaunch_refused_before_effects() {
  cmp -s "$LAB/relaunch-meta.before" "$HOME_DIR/state/t1.meta" \
    || fail "route-changing relaunch refusal changed task metadata"
  [ "$(cat "$LAB/relaunch-command")" = zsh ] \
    || fail "route-changing relaunch refusal started an agent in the endpoint"
  [ ! -s "$RELAUNCH_PANE_LOG" ] || fail "route-changing relaunch refusal sent pane input"
  [ ! -s "$RELAUNCH_ENDPOINT_LOG" ] || fail "route-changing relaunch refusal created an endpoint"
  [ ! -s "$RELAUNCH_LEASE_LOG" ] || fail "route-changing relaunch refusal leased a worktree"
}

exercise_relaunch_negative() { # <name> <predicate> <setup-function> [detail]
  local name=$1 predicate=$2 setup=$3 detail=${4:-} out status
  write_fixture
  "$setup"
  setup_relaunch_task
  out=$(run_relaunch_spawn "$SPAWN")
  status=$?
  expect_code 1 "$status" "$name should refuse"
  assert_contains "$out" "ROUTING_DECISION $predicate" "$name named the wrong predicate"
  [ -z "$detail" ] || assert_contains "$out" "$detail" "$name named the wrong refusal detail"
  assert_relaunch_refused_before_effects
  negative_count=$((negative_count + 1))
  pass "$name refuses before relaunch effects"

  write_fixture
  "$setup"
  setup_relaunch_task
  run_relaunch_spawn "$RELAUNCH_COUNTEREXAMPLE_ROOT/bin/fm-spawn.sh" >/dev/null 2>&1 || true
  [ -s "$RELAUNCH_PANE_LOG" ] \
    || fail "$name counterexample did not reach pane input after the relaunch guard was neutered"
  [ "$(cat "$LAB/relaunch-command")" = claude ] \
    || fail "$name counterexample did not start the replacement agent"
  cmp -s "$LAB/relaunch-meta.before" "$HOME_DIR/state/t1.meta" \
    && fail "$name counterexample did not reach metadata publication"
  [ ! -s "$RELAUNCH_ENDPOINT_LOG" ] \
    || fail "$name counterexample created a second endpoint instead of reusing the recorded one"
  [ ! -s "$RELAUNCH_LEASE_LOG" ] \
    || fail "$name counterexample leased a second worktree instead of reusing the recorded one"
  counterexample_count=$((counterexample_count + 1))
  pass "$name integration call-site counterexample"
}

prepare_committed_handoff_generation() {
  fm_routing_decision_validate_and_prepare \
    "$HOME_DIR/data" "$HOME_DIR/config" t1 \
    "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
    "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT" \
    || fail "committed-handoff fixture could not prepare its receipt"
  fm_routing_decision_persist_prepared \
    || fail "committed-handoff fixture could not publish its receipt"
  fm_routing_decision_consume_prepared \
    || fail "committed-handoff fixture could not consume its receipt"
  fm_routing_decision_seal_prepared \
    || fail "committed-handoff fixture could not seal its receipt"
}

run_committed_relaunch_spawn() { # <spawn-path> <output-path>
  local spawn=$1 output=$2 harness_arg=$RUN_HARNESS
  [ "$RUN_RAW" -eq 0 ] || harness_arg=$RUN_LAUNCH
  mkdir -p "$HOME_DIR/state/.control-t1.lock"
  printf '%s\n' "${BASHPID:-$$}" > "$HOME_DIR/state/.control-t1.lock/pid"
  env PATH="$RAW_HARNESS_BIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_ROUTING_COMMITTED=1 \
    FM_RELAUNCH_TEST_WT="$RELAUNCH_WT" \
    FM_RELAUNCH_TEST_PANE_LOG="$RELAUNCH_PANE_LOG" \
    FM_RELAUNCH_TEST_ENDPOINT_LOG="$RELAUNCH_ENDPOINT_LOG" \
    FM_RELAUNCH_TEST_LEASE_LOG="$RELAUNCH_LEASE_LOG" \
    FM_RELAUNCH_TEST_COMMAND="$LAB/relaunch-command" \
    FM_ROUTING_TEST_RELAUNCH=1 FM_ROUTING_TEST_TREEHOUSE_STATUS=1 \
    FM_TEST_REAL_PERL="$REAL_PERL" FM_TEST_REAL_JQ="$REAL_JQ" \
    FM_ROUTING_TEST_HOME="$HOME_DIR" FM_ROUTING_TEST_TASK_DIR="$TASK_DIR" \
    FM_ROUTING_TEST_LAB="$LAB" FM_ROUTING_TEST_META_BEFORE="$LAB/relaunch-meta.before" \
    FM_ROUTING_TEST_HANDOFF_FAULT="$COMMITTED_HANDOFF_FAULT" \
    "$spawn" t1 --relaunch --harness "$harness_arg" \
      --model "$RUN_MODEL" --effort "$RUN_EFFORT" > "$output" 2>&1
}

exercise_committed_handoff_negative() { # <name> <fault> <detail>
  local name=$1 fault=$2 detail=$3 out status
  write_fixture
  prepare_committed_handoff_generation
  setup_relaunch_task
  COMMITTED_HANDOFF_FAULT=$fault
  run_committed_relaunch_spawn "$SPAWN" "$LAB/committed-handoff.out"
  status=$?
  out=$(cat "$LAB/committed-handoff.out")
  expect_code 1 "$status" "$name should refuse through the committed handoff"
  assert_contains "$out" "ROUTING_DECISION PERSISTENCE_REFUSED" \
    "$name named the wrong refusal predicate"
  assert_contains "$out" "$detail" "$name named the wrong committed-handoff guard"
  assert_relaunch_refused_before_effects
  committed_handoff_negative_count=$((committed_handoff_negative_count + 1))
  pass "$name refuses the committed handoff before replacement effects"
}

run_committed_handoff_battery() {
  exercise_committed_handoff_negative \
    "committed handoff snapshot identity substitution" snapshot-identity SNAPSHOT_IDENTITY
  exercise_committed_handoff_negative \
    "committed handoff generation mismatch" generation-mismatch VERIFY_COMMITTED:generation-mismatch
  exercise_committed_handoff_negative \
    "committed handoff malformed ledger" ledger-format LEDGER_FORMAT:routing-generations.consumed
  exercise_committed_handoff_negative \
    "committed handoff brief ownership mismatch" brief-ownership COLLISION:brief.md:ownership
  exercise_committed_handoff_negative \
    "committed handoff receipt byte mismatch" receipt-bytes COMMITTED_RECEIPT_BYTES
}

sha_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

future_timestamp() {
  local epoch=$(( $(date -u +%s) + 120 ))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

write_fixture() {
  local brief_hash intent_hash config_hash home_hash host_hash now
  rm -rf "$LAB"
  mkdir -p "$TASK_DIR" "$HOME_DIR/config" "$HOME_DIR/state"
  printf 'exact brief bytes for t1\n' > "$TASK_DIR/brief.md"
  jq -n '{
    rules: [{when: "firstmate repo work", use: {harness: "claude", model: "opus", effort: "high"}}],
    default: [
      {harness: "codex", model: "gpt-5", effort: "high"},
      {harness: "claude", model: "opus", effort: "xhigh"}
    ]
  }' > "$HOME_DIR/config/crew-dispatch.json"
  brief_hash=$(sha_file "$TASK_DIR/brief.md")
  jq -n --arg brief_sha256 "$brief_hash" '{
    schema_version: 1,
    task_id: "t1",
    brief_sha256: $brief_sha256,
    hard_capability: "bash refactor",
    ambiguity: "LOW",
    risk: "LOCAL_FAIL_CLOSED",
    authority: "CONFIGURED_RULE",
    gate: "no-mistakes",
    forbidden_effects: ["push", "merge"]
  }' > "$TASK_DIR/routing-intent.json"
  intent_hash=$(sha_file "$TASK_DIR/routing-intent.json")
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  home_hash=$(printf '%s' "$HOME_DIR" | sha_text)
  host_hash=$(uname -n | sha_text)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg intent_hash "$intent_hash" \
    --arg config_hash "$config_hash" \
    --arg home_hash "$home_hash" \
    --arg host_hash "$host_hash" \
    --arg now "$now" '{
      schema_version: 1,
      task_id: "t1",
      intent_sha256: $intent_hash,
      dispatch_config: {kind: "present", sha256: $config_hash},
      matched_profile: {source: "rule", index: 0},
      supervisor: {kind: "current-firstmate-home", home_sha256: $home_hash},
      host: {kind: "local", identity_sha256: $host_hash},
      launch_binding: {kind: "verified_template", harness: "claude", model: "opus", effort: "high"},
      harness: "claude",
      model: "opus",
      effort: "high",
      candidates_considered: [{harness: "claude", model: "opus", effort: "high"}],
      quota: {source: "NOT_APPLICABLE_SINGLETON", observed_at: null, snapshot_sha256: null},
      quota_basis: "NOT_APPLICABLE_SINGLETON",
      fallback: "NONE",
      rationale: "only capable candidate for the matched rule",
      required_gate: "no-mistakes",
      selection_order: ["hard_capability", "ambiguity_complexity", "fresh_quota_among_capable"],
      generated_at: $now
    }' > "$TASK_DIR/routing-decision.pending.json"
  RUN_HARNESS=claude
  RUN_MODEL=opus
  RUN_EFFORT=high
  RUN_RAW=0
  RUN_LAUNCH='claude verified template'
  RUN_MODEL_FRAGMENT="--model 'opus' "
  RUN_EFFORT_FRAGMENT="--effort 'high' "
  PREEXISTING_FINAL=0
  PREEXISTING_META=0
  POST_BINDING_RECEIPT_FILTER=
  POST_SNAPSHOT_SOURCE_FILTER=
  POST_SNAPSHOT_CONFIG_FILTER=
  POST_PENDING_DIRECTORY=0
  POST_PENDING_RECREATE=0
  POST_CONFIG_SYMLINK=0
  POST_SNAPSHOT_DIRECTORY_RECREATE=0
  POST_SNAPSHOT_AMBIGUOUS_META=0
  COMMITTED_HANDOFF_FAULT=
  RUN_CWD=
}

update_receipt() {
  local filter=$1 file="$TASK_DIR/routing-decision.pending.json" tmp="$TASK_DIR/routing-decision.pending.json.tmp"
  shift
  jq "$@" "$filter" "$file" > "$tmp" || return 1
  mv "$tmp" "$file"
}

update_intent() {
  local filter=$1 file="$TASK_DIR/routing-intent.json" tmp="$TASK_DIR/routing-intent.json.tmp"
  jq "$filter" "$file" > "$tmp" || return 1
  mv "$tmp" "$file"
}

write_multi_fixture() {
  local now snapshot_hash config_hash
  write_fixture
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n '{rules: [{when: "firstmate repo work", use: [
    {harness: "claude", model: "opus", effort: "high"},
    {harness: "codex", model: "gpt-5", effort: "high"}
  ]}]}' > "$HOME_DIR/config/crew-dispatch.json"
  jq -n --arg now "$now" '{
    schemaVersion: 5,
    generatedAt: $now,
    providers: [{provider: "claude", state: {}, quotaSemantics: {}}]
  }' > "$TASK_DIR/quota-snapshot.json"
  snapshot_hash=$(sha_file "$TASK_DIR/quota-snapshot.json")
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  update_receipt ".dispatch_config.sha256 = \"$config_hash\"
    | .candidates_considered = [
        {harness: \"claude\", model: \"opus\", effort: \"high\"},
        {harness: \"codex\", model: \"gpt-5\", effort: \"high\"}
      ]
    | .quota_basis = \"FRESH_QUOTA_COMPARISON\"
    | .quota = {source: \"quota-axi --json\", observed_at: \"$now\", snapshot_sha256: \"$snapshot_hash\"}"
}

run_validator() {
  fm_routing_decision_validate_and_persist \
    "$HOME_DIR/data" "$HOME_DIR/config" t1 \
    "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
    "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT"
}

run_validator_then_effects() {
  if [ -n "$RUN_CWD" ]; then
    (cd "$RUN_CWD" && run_validator) || return 1
  else
    run_validator || return 1
  fi
  mkdir -p "$LAB/worktree.lease" "$LAB/endpoint"
  printf 'published\n' > "$HOME_DIR/state/t1.meta"
}

assert_no_effects() {
  assert_absent "$LAB/worktree.lease" "routing refusal leased a worktree"
  assert_absent "$LAB/endpoint" "routing refusal created an endpoint"
  if [ "$PREEXISTING_META" -eq 0 ]; then
    assert_absent "$HOME_DIR/state/t1.meta" "routing refusal published task metadata"
  else
    cmp -s "$LAB/meta.before" "$HOME_DIR/state/t1.meta" \
      || fail "routing refusal changed pre-existing task metadata"
  fi
  if [ "$PREEXISTING_FINAL" -eq 0 ]; then
    if fm_test_existing_routing_decision_path "$HOME_DIR" t1 >/dev/null; then
      fail "invalid receipt was persisted"
    fi
  else
    assert_present "$TASK_DIR/routing-decision.pending.json" "hostile final target consumed the pending receipt"
  fi
}

exercise_negative() { # <name> <predicate> <setup-function> [exact-detail] [post-assertion]
  local name=$1 predicate=$2 setup=$3 detail=${4:-} post_assertion=${5:-} out status
  write_fixture
  "$setup"
  setup_fresh_spawn_project
  out=$(run_fresh_spawn "$SPAWN")
  status=$?
  expect_code 1 "$status" "$name should refuse"
  assert_contains "$out" "ROUTING_DECISION $predicate" "$name named the wrong predicate"
  [ -z "$detail" ] || assert_contains "$out" "$detail" "$name named the wrong refusal detail"
  assert_no_fresh_spawn_effects
  [ -z "$post_assertion" ] || "$post_assertion"
  negative_count=$((negative_count + 1))
  fresh_spawn_negative_count=$((fresh_spawn_negative_count + 1))
  pass "$name refuses in fm-spawn before lease, endpoint, pane input, and metadata"

  write_fixture
  "$setup"
  setup_fresh_spawn_project
  if run_fresh_spawn "$RELAUNCH_COUNTEREXAMPLE_ROOT/bin/fm-spawn.sh" >/dev/null 2>&1; then
    [ -s "$FRESH_TEXT_LOG" ] \
      || fail "$name counterexample did not reach the worktree lease channel"
    [ -s "$FRESH_ENDPOINT_LOG" ] \
      || fail "$name counterexample did not create an endpoint"
    [ -s "$FRESH_PANE_LOG" ] \
      || fail "$name counterexample did not send pane input"
    assert_present "$HOME_DIR/state/t1.meta" "$name counterexample did not publish metadata"
  else
    fail "$name counterexample did not fire after the fm-spawn routing requirement was neutered"
  fi
  counterexample_count=$((counterexample_count + 1))
  fresh_spawn_counterexample_count=$((fresh_spawn_counterexample_count + 1))
  pass "$name real fm-spawn integration counterexample"
}

neuter_raw_guard() { # <literal-words|trailing-environment>
  case "$1" in
    literal-words)
      # shellcheck disable=SC2329 # Invoked indirectly by fm_routing_parse_command_axes.
      fm_routing_literal_words() {
        # shellcheck disable=SC2016 # The mutation must retain the unresolved variable literally.
        FM_ROUTING_WORDS=(claude --model opus --effort high '$EXTRA')
        return 0
      }
      ;;
    trailing-environment)
      # shellcheck disable=SC2329 # Invoked indirectly by fm_routing_parse_command_axes.
      fm_routing_raw_environment_assignment() { return 1; }
      ;;
    *) fail "unknown raw guard mutation $1" ;;
  esac
}

assert_raw_guard_refusal() { # <name> <setup-function> <detail>
  local name=$1 setup=$2 detail=$3 out status
  write_fixture
  "$setup"
  out=$(run_validator_then_effects 2>&1)
  status=$?
  expect_code 1 "$status" "$name should refuse"
  assert_contains "$out" "ROUTING_DECISION RAW_LAUNCH_NOT_VERIFIABLE" \
    "$name named the wrong predicate"
  assert_contains "$out" "$detail" "$name named the wrong refusal detail"
  assert_no_effects
}

exercise_firing_raw_guard() { # <name> <setup-function> <detail> <mutation>
  local name=$1 setup=$2 detail=$3 mutation=$4
  assert_raw_guard_refusal "$name" "$setup" "$detail"
  negative_count=$((negative_count + 1))
  pass "$name refuses before lease, endpoint, and metadata"

  if (
    neuter_raw_guard "$mutation"
    assert_raw_guard_refusal "$name mutation" "$setup" "$detail"
  ) >/dev/null 2>&1; then
    fail "$name stayed green when its exact guard was neutered"
  fi

  (
    neuter_raw_guard "$mutation"
    write_fixture
    "$setup"
    run_validator_then_effects >/dev/null 2>&1
    assert_present "$LAB/worktree.lease" "$name mutation did not reach a worktree lease"
    assert_present "$LAB/endpoint" "$name mutation did not reach an endpoint"
    assert_present "$HOME_DIR/state/t1.meta" "$name mutation did not publish metadata"
  ) || fail "$name mutation did not prove the exact guard was load-bearing"
  counterexample_count=$((counterexample_count + 1))
  raw_guard_counterexample_count=$((raw_guard_counterexample_count + 1))
  pass "$name exact-guard firing counterexample"
}

setup_missing_receipt() { rm "$TASK_DIR/routing-decision.pending.json"; }
setup_missing_intent() { rm "$TASK_DIR/routing-intent.json"; }
setup_empty_receipt() { : > "$TASK_DIR/routing-decision.pending.json"; }
setup_empty_intent() { : > "$TASK_DIR/routing-intent.json"; }
setup_wrong_task() { update_receipt '.task_id = "other"'; }
setup_stale() { update_receipt '.generated_at = "2000-01-01T00:00:00Z"'; }
setup_future() { update_receipt ".generated_at = \"$(future_timestamp)\""; }
setup_model_binding_mismatch() { update_receipt '.launch_binding.model = "sonnet"'; }
setup_effort_binding_mismatch() { update_receipt '.launch_binding.effort = "low"'; }
setup_config_absent_after_receipt() { rm "$HOME_DIR/config/crew-dispatch.json"; }
setup_dynamic_raw() {
  RUN_RAW=1
  # shellcheck disable=SC2016 # the command must retain the unresolved variable literally
  RUN_LAUNCH='claude --model "$ROUTE_MODEL" --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_trailing_dynamic_raw() {
  # shellcheck disable=SC2016 # the command must retain the unresolved variable literally
  setup_raw_literal 'claude --model opus --effort high $EXTRA'
}
setup_env_raw() {
  RUN_RAW=1
  RUN_LAUNCH='MODEL=opus claude --model opus --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_trailing_env_raw() {
  setup_raw_literal 'claude MODEL=opus --model opus --effort high'
}
setup_nonstandard_raw() {
  RUN_RAW=1
  RUN_LAUNCH='claude -m opus --effort high'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding.kind = "raw_launch"'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_raw_literal() { # <command>
  local raw_head
  RUN_RAW=1
  RUN_LAUNCH=$1
  raw_head=${RUN_LAUNCH%%[[:space:]]*}
  RUN_HARNESS=$(basename -- "$raw_head")
  # shellcheck disable=SC2016 # jq expands the named argument inside this literal filter.
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .harness = $harness
    | .candidates_considered[0].harness = $harness
    | .launch_binding.kind = "raw_launch"
    | .launch_binding.harness = $harness' --arg harness "$RUN_HARNESS"
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_raw_pi_caller_environment() {
  setup_raw_literal 'pi --model opus --thinking high'
  RUN_LAUNCH='FOO=bar pi --model opus --thinking high'
}

run_raw_launch_acceptance_battery() {
  write_relaunch_tmux_stub
  while IFS='|' read -r harness command; do
    [ -n "$harness" ] || continue
    exercise_raw_launch_acceptance "$harness" "$command"
  done <<'RAW_LAUNCHES'
claude|claude --model opus --effort high
codex|codex --model opus -c model_reasoning_effort=high
grok|grok --model opus --reasoning-effort high
muse|muse --model opus --reasoning-effort high
pi|pi --model opus --thinking high
pi-signed|pi-signed --model opus --thinking high
RAW_LAUNCHES
}
RAW_PUNCTUATION=
RAW_SHAPE_COMMAND=
setup_raw_punctuation() { setup_raw_literal "claude --model a${RAW_PUNCTUATION}b --effort high"; }
setup_raw_newline() { setup_raw_literal $'claude --model opus\n--effort high'; }
setup_raw_carriage_return() { setup_raw_literal $'claude --model opus\r--effort high'; }
setup_raw_double_history() { setup_raw_literal 'claude --model "!!" --effort high'; }
setup_raw_double_backslash() { setup_raw_literal 'claude --model "a\b" --effort high'; }
setup_raw_leading_equals() { setup_raw_literal 'claude --model =ls --effort high'; }
setup_raw_single_control() { setup_raw_literal $'claude --model \'aa\027bb\' --effort high'; }
setup_raw_plain_tab() { setup_raw_literal $'claude --model opus\t--effort high'; }
setup_raw_single_tab() { setup_raw_literal $'claude --model \'aa\tbb\' --effort high'; }
setup_raw_double_tab() { setup_raw_literal $'claude --model "aa\tbb" --effort high'; }
setup_raw_plain_nonascii() { setup_raw_literal $'claude --model mod\303\250le --effort high'; }
setup_raw_single_nonascii() { setup_raw_literal $'claude --model \'mod\303\250le\' --effort high'; }
setup_raw_double_nonascii() { setup_raw_literal $'claude --model "mod\303\250le" --effort high'; }
setup_raw_flag_shape() { setup_raw_literal "$RAW_SHAPE_COMMAND"; }
setup_raw_terminator() { setup_raw_literal 'claude -- --model opus --effort high'; }
setup_raw_reserved_placeholder() {
  RUN_MODEL=__BRIEF__
  setup_raw_literal 'claude --model __BRIEF__ --effort high'
  update_receipt '.model = "__BRIEF__"
    | .candidates_considered[0].model = "__BRIEF__"
    | .launch_binding.model = "__BRIEF__"'
}
setup_raw_cross_harness_codex_config() {
  setup_raw_literal 'claude --model opus -c model_reasoning_effort=high'
}
setup_raw_unexpressible_effort() {
  setup_raw_literal 'opencode --model opus'
}
setup_raw_relative_harness_path() {
  mkdir -p "$LAB/tools"
  printf '#!/bin/sh\nexit 0\n' > "$LAB/tools/claude"
  chmod +x "$LAB/tools/claude"
  RUN_CWD=$LAB
  setup_raw_literal 'tools/claude --model opus --effort high'
}
setup_raw_absolute_harness_impostor() {
  local wrapper="$LAB/absolute-wrapper/claude"
  mkdir -p "$(dirname "$wrapper")"
  printf '#!/bin/sh\nexit 0\n' > "$wrapper"
  chmod +x "$wrapper"
  setup_raw_literal "$wrapper --model opus --effort high"
}
setup_raw_unsupported_executable() { setup_raw_literal 'not-a-harness --model opus --effort high'; }
setup_raw_harness_contradiction() {
  setup_raw_literal 'codex --model opus -c model_reasoning_effort=high'
  update_receipt '.harness = "claude"
    | .candidates_considered[0].harness = "claude"
    | .launch_binding.harness = "claude"'
}
setup_raw_model_contradiction() { setup_raw_literal 'claude --model sonnet --effort high'; }
setup_raw_effort_contradiction() { setup_raw_literal 'claude --model opus --effort low'; }
setup_unresolved_raw() {
  RUN_RAW=1
  RUN_LAUNCH='claude --model opus'
  update_receipt '.matched_profile = {source: "explicit_override", index: null}
    | .launch_binding = {kind: "raw_launch", harness: "claude", model: "opus", effort: null}'
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_intent_hash_mismatch() { update_receipt '.intent_sha256 = ("0" * 64)'; }
setup_brief_swap() { printf 'replacement brief bytes\n' > "$TASK_DIR/brief.md"; }
setup_gate_mismatch() { update_receipt '.required_gate = "direct-PR"'; }
setup_forbidden_fallback() { update_receipt '.fallback = "crew-harness"'; }
setup_supervisor_mismatch() { update_receipt '.supervisor.home_sha256 = ("0" * 64)'; }
setup_host_mismatch() { update_receipt '.host.identity_sha256 = ("0" * 64)'; }
setup_candidate_mismatch() { update_receipt '.candidates_considered[0].model = "sonnet"'; }
setup_unknown_key() { update_receipt '.bypass = true'; }
setup_missing_quota() { write_multi_fixture; rm "$TASK_DIR/quota-snapshot.json"; }
setup_stale_quota() {
  write_multi_fixture
  update_receipt '.quota.observed_at = "2000-01-01T00:00:00Z"'
  jq '.generatedAt = "2000-01-01T00:00:00Z"' "$TASK_DIR/quota-snapshot.json" > "$TASK_DIR/quota-old.json"
  mv "$TASK_DIR/quota-old.json" "$TASK_DIR/quota-snapshot.json"
  update_receipt ".quota.snapshot_sha256 = \"$(sha_file "$TASK_DIR/quota-snapshot.json")\""
}
setup_singleton_quota() {
  update_receipt '.quota_basis = "FRESH_QUOTA_COMPARISON"
    | .quota = {source: "quota-axi --json", observed_at: .generated_at, snapshot_sha256: ("0" * 64)}'
}
receipt_generation() { sha_file "$TASK_DIR/routing-decision.pending.json"; }
generation_dir() { printf '%s/routing-generation.%s\n' "$TASK_DIR" "$(receipt_generation)"; }
receipt_final() { printf '%s/receipt.json\n' "$(generation_dir)"; }
brief_final() { printf '%s/brief.md\n' "$(generation_dir)"; }
setup_final_directory() { PREEXISTING_FINAL=1; mkdir "$(generation_dir)"; chmod 0755 "$(generation_dir)"; }
setup_final_symlink() {
  PREEXISTING_FINAL=1
  mkdir "$TASK_DIR/attacker-target"
  ln -s "$TASK_DIR/attacker-target" "$(generation_dir)"
}
setup_final_directory_after_check() {
  PREEXISTING_FINAL=1
  mkdir "$(generation_dir)"
  chmod 0755 "$(generation_dir)"
}
setup_truncated_receipt() { printf '{"schema_version":1' > "$TASK_DIR/routing-decision.pending.json"; }
setup_config_byte_mutation() { printf '\n' >> "$HOME_DIR/config/crew-dispatch.json"; }
setup_pending_symlink() {
  mv "$TASK_DIR/routing-decision.pending.json" "$TASK_DIR/receipt-target.json"
  ln -s "$TASK_DIR/receipt-target.json" "$TASK_DIR/routing-decision.pending.json"
}
setup_pending_replaced_after_snapshot() {
  POST_SNAPSHOT_SOURCE_FILTER='.rationale = "replacement after validation began"'
}
setup_pending_directory_after_snapshot() { POST_PENDING_DIRECTORY=1; }
setup_pending_mutated_in_place_after_compare() {
  PREEXISTING_FINAL=1
  mkdir "$(generation_dir)"
  chmod 0700 "$(generation_dir)"
  printf '{"collision":true}\n' > "$(receipt_final)"
  chmod 0400 "$(receipt_final)"
}
setup_pending_recreated_after_relocation() {
  POST_PENDING_RECREATE=1
}
setup_snapshot_identity_substitution() {
  POST_SNAPSHOT_DIRECTORY_RECREATE=1
}
setup_malformed_consumed_ledger() {
  printf 'not-a-generation\n' > "$TASK_DIR/routing-generations.consumed"
  chmod 0600 "$TASK_DIR/routing-generations.consumed"
}
setup_ambiguous_routing_pointer() {
  POST_SNAPSHOT_AMBIGUOUS_META=1
  PREEXISTING_META=1
}
setup_config_symlink_before_snapshot() {
  mkdir -p "$LAB/relocated-config"
  cp "$HOME_DIR/config/crew-dispatch.json" "$LAB/relocated-config/crew-dispatch.json"
  POST_CONFIG_SYMLINK=1
}
setup_receipt_then_brief_collision() {
  PREEXISTING_FINAL=1
  mkdir "$(generation_dir)"
  chmod 0700 "$(generation_dir)"
  cp "$TASK_DIR/routing-decision.pending.json" "$(receipt_final)"
  printf 'collision\n' > "$(brief_final)"
  chmod 0400 "$(receipt_final)" "$(brief_final)"
}
setup_preexisting_writable_brief() {
  PREEXISTING_FINAL=1
  setup_receipt_then_brief_collision
}
setup_preexisting_hardlinked_brief() {
  PREEXISTING_FINAL=1
  mkdir "$(generation_dir)"
  chmod 0700 "$(generation_dir)"
  cp "$TASK_DIR/routing-decision.pending.json" "$(receipt_final)"
  cp "$TASK_DIR/brief.md" "$TASK_DIR/brief-hardlink-source.md"
  ln "$TASK_DIR/brief-hardlink-source.md" "$(brief_final)"
  chmod 0400 "$(receipt_final)" "$(brief_final)"
}

assert_pending_directory_preserved() {
  [ -d "$TASK_DIR/routing-decision.pending.json" ] \
    || fail "pending receipt directory replacement was not restored"
  printf 'replacement directory sentinel\n' | cmp -s - "$TASK_DIR/routing-decision.pending.json/sentinel" \
    || fail "pending receipt directory replacement contents were changed or deleted"
}
assert_pending_replacement_never_relocated() {
  [ -d "$TASK_DIR/routing-decision.pending.json" ] \
    || fail "pending receipt directory replacement left its source pathname"
  printf 'replacement directory sentinel\n' | cmp -s - "$TASK_DIR/routing-decision.pending.json/sentinel" \
    || fail "pending receipt directory replacement contents changed"
  assert_present "$TASK_DIR/routing-decision.original.json" \
    "pending replacement counterexample did not preserve the validated source inode"
}
assert_config_symlink_not_followed() {
  [ -L "$HOME_DIR/config/crew-dispatch.json" ] \
    || fail "canonical config substitution did not install its symlink counterexample"
  cmp -s "$HOME_DIR/config/crew-dispatch.original.json" "$LAB/relocated-config/crew-dispatch.json" \
    || fail "config snapshot refusal changed relocated configuration bytes"
}
setup_selection_order_tamper() { update_receipt '.selection_order |= reverse'; }
setup_quota_byte_mutation() { write_multi_fixture; printf '\n' >> "$TASK_DIR/quota-snapshot.json"; }
setup_quota_symlink() {
  write_multi_fixture
  mv "$TASK_DIR/quota-snapshot.json" "$TASK_DIR/quota-target.json"
  ln -s "$TASK_DIR/quota-target.json" "$TASK_DIR/quota-snapshot.json"
}
setup_selected_tuple_outside_candidates() {
  write_multi_fixture
  RUN_MODEL=sonnet
  RUN_MODEL_FRAGMENT="--model 'sonnet' "
}
setup_rule_index_out_of_range() { update_receipt '.matched_profile.index = 7'; }
setup_wrong_quota_schema() {
  write_multi_fixture
  jq '.schemaVersion = 4' "$TASK_DIR/quota-snapshot.json" > "$TASK_DIR/quota-wrong-schema.json"
  mv "$TASK_DIR/quota-wrong-schema.json" "$TASK_DIR/quota-snapshot.json"
  update_receipt ".quota.snapshot_sha256 = \"$(sha_file "$TASK_DIR/quota-snapshot.json")\""
}
setup_non_rfc3339_timestamp() { update_receipt '.generated_at = "not-a-timestamp"'; }
setup_wrong_multi_quota_basis() {
  write_multi_fixture
  update_receipt '.quota_basis = "NOT_APPLICABLE_SINGLETON"'
}
setup_default_base() {
  local config_hash
  jq '.default = {harness: "claude", model: "opus", effort: "high"}' \
    "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/crew-dispatch.default.json"
  mv "$HOME_DIR/config/crew-dispatch.default.json" "$HOME_DIR/config/crew-dispatch.json"
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  update_receipt ".dispatch_config.sha256 = \"$config_hash\"
    | .matched_profile = {source: \"default\", index: null}"
}
setup_default_wrong_index() {
  setup_default_base
  update_receipt '.matched_profile.index = 0'
}
setup_default_missing_profile() {
  local config_hash
  jq '.default = 42' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/crew-dispatch.nodefault.json"
  mv "$HOME_DIR/config/crew-dispatch.nodefault.json" "$HOME_DIR/config/crew-dispatch.json"
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  update_receipt ".dispatch_config.sha256 = \"$config_hash\"
    | .matched_profile = {source: \"default\", index: null}"
}
setup_static_base() {
  rm "$HOME_DIR/config/crew-dispatch.json"
  update_intent '.authority = "STATIC_HARNESS"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\"
    | .dispatch_config = {kind: \"absent\", sha256: null}
    | .matched_profile = {source: \"static_harness\", index: null}"
}
setup_static_with_config() {
  update_intent '.authority = "STATIC_HARNESS"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\"
    | .matched_profile = {source: \"static_harness\", index: null}"
}
setup_static_wrong_index() {
  setup_static_base
  update_receipt '.matched_profile.index = 0'
}
setup_static_wrong_authority() {
  setup_static_base
  update_intent '.authority = "CONFIGURED_RULE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\""
}
setup_static_non_singleton() {
  write_multi_fixture
  rm "$HOME_DIR/config/crew-dispatch.json"
  update_intent '.authority = "STATIC_HARNESS"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\"
    | .dispatch_config = {kind: \"absent\", sha256: null}
    | .matched_profile = {source: \"static_harness\", index: null}"
}
setup_explicit_base() {
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\"
    | .matched_profile = {source: \"explicit_override\", index: null}"
}
setup_explicit_wrong_index() {
  setup_explicit_base
  update_receipt '.matched_profile.index = 0'
}
setup_explicit_wrong_authority() {
  update_receipt '.matched_profile = {source: "explicit_override", index: null}'
}
setup_explicit_non_singleton() {
  write_multi_fixture
  update_intent '.authority = "EXPLICIT_RUNTIME_OVERRIDE"'
  update_receipt ".intent_sha256 = \"$(sha_file "$TASK_DIR/routing-intent.json")\"
    | .matched_profile = {source: \"explicit_override\", index: null}"
}
setup_unsupported_source() { update_receipt '.matched_profile = {source: "unregistered", index: null}'; }
setup_rule_noninteger_index() { update_receipt '.matched_profile.index = "0"'; }
setup_rule_malformed_profile() {
  local config_hash
  jq '.rules[0].use = 42' "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/crew-dispatch.badrule.json"
  mv "$HOME_DIR/config/crew-dispatch.badrule.json" "$HOME_DIR/config/crew-dispatch.json"
  config_hash=$(sha_file "$HOME_DIR/config/crew-dispatch.json")
  update_receipt ".dispatch_config.sha256 = \"$config_hash\""
}
setup_rule_binding_kind_drift() {
  POST_BINDING_RECEIPT_FILTER='.dispatch_config = {kind: "absent", sha256: null}'
}

SHELL_DIFF_DIR="$TMP_ROOT/shell-differential"
SHELL_DIFF_PROBE="$SHELL_DIFF_DIR/argv-probe"
SHELL_DIFF_ACTUAL="$SHELL_DIFF_DIR/actual.argv"
SHELL_DIFF_EXPECTED="$SHELL_DIFF_DIR/expected.argv"
shell_differential_character_count=0
shell_differential_run_count=0

write_shell_differential_probe() {
  mkdir -p "$SHELL_DIFF_DIR"
  cat > "$SHELL_DIFF_PROBE" <<'SH'
#!/bin/sh
set -u
: "${FM_ROUTING_SHELL_ARGV:?}"
printf '%s\0' "$0" "$@" > "$FM_ROUTING_SHELL_ARGV"
SH
  chmod +x "$SHELL_DIFF_PROBE"
}

byte_character() { # <decimal-code>
  local octal
  octal=$(printf '%03o' "$1")
  printf '%b' "\\$octal"
}

run_real_shell_differential() { # <state> <command>
  local state=$1 command=$2 shell_name shell_path mode status
  fm_routing_literal_words "$command" 1 \
    || fail "$state allowlist rejected a character its differential corpus accepts"
  printf '%s\0' "${FM_ROUTING_WORDS[@]}" > "$SHELL_DIFF_EXPECTED"
  for shell_name in bash zsh; do
    shell_path=$(command -v "$shell_name") \
      || fail "$state differential requires installed $shell_name"
    for mode in noninteractive interactive; do
      rm -f "$SHELL_DIFF_ACTUAL"
      if [ "$shell_name" = bash ]; then
        if [ "$mode" = interactive ]; then
          printf '%s\n%s\n%s\n' 'history -s "routing-differential-seed"' "$command" exit \
            | FM_ROUTING_SHELL_ARGV="$SHELL_DIFF_ACTUAL" \
              "$shell_path" --noprofile --norc -i >/dev/null 2>"$SHELL_DIFF_DIR/stderr"
        else
          FM_ROUTING_SHELL_ARGV="$SHELL_DIFF_ACTUAL" \
            "$shell_path" --noprofile --norc -c "$command" >/dev/null 2>"$SHELL_DIFF_DIR/stderr"
        fi
      elif [ "$mode" = interactive ]; then
        printf '%s\n%s\n%s\n' 'print -s -- "routing-differential-seed"' "$command" exit \
          | FM_ROUTING_SHELL_ARGV="$SHELL_DIFF_ACTUAL" \
            "$shell_path" -f -i >/dev/null 2>"$SHELL_DIFF_DIR/stderr"
      else
        FM_ROUTING_SHELL_ARGV="$SHELL_DIFF_ACTUAL" \
          "$shell_path" -f -c "$command" >/dev/null 2>"$SHELL_DIFF_DIR/stderr"
      fi
      status=$?
      [ "$status" -eq 0 ] \
        || fail "$state differential command failed under $shell_name $mode"
      [ -f "$SHELL_DIFF_ACTUAL" ] \
        || fail "$state differential command emitted no argv under $shell_name $mode"
      cmp -s "$SHELL_DIFF_EXPECTED" "$SHELL_DIFF_ACTUAL" \
        || fail "$state parser words differ from $shell_name $mode argv"
      shell_differential_run_count=$((shell_differential_run_count + 1))
      pass "$state parser words match $shell_name $mode argv"
    done
  done
}

exercise_shell_position_differential() { # <plain|single|double> <mid|start>
  local state=$1 position=$2 command code ch candidate fragment accepted_count=0
  command=$SHELL_DIFF_PROBE
  for ((code = 32; code <= 126; code++)); do
    ch=$(byte_character "$code")
    case "$state:$position:$code" in
      plain:mid:*) fragment=" p${ch}p" ;;
      plain:start:*) fragment=" ${ch}leading" ;;
      single:mid:*) fragment=" 's${ch}s'" ;;
      double:*:33) fragment=' "!!"' ;;
      double:mid:*) fragment=" \"d${ch}d\"" ;;
      double:start:*) fragment=" \"${ch}leading\"" ;;
      *) fail "unsupported differential state-position $state-$position" ;;
    esac
    candidate="${SHELL_DIFF_PROBE}${fragment}"
    if fm_routing_literal_words "$candidate" 1 2>/dev/null; then
      command+="$fragment"
      accepted_count=$((accepted_count + 1))
    fi
  done
  [ "$accepted_count" -gt 0 ] || fail "$state-$position differential accepted no byte cases"
  run_real_shell_differential "$state-$position" "$command"
  shell_differential_character_count=$((shell_differential_character_count + accepted_count))
}

case "${FM_ROUTING_TEST_SCOPE:-}" in
  raw-positive)
    run_raw_launch_acceptance_battery
    [ "$raw_launch_acceptance_count" -eq 6 ] \
      || fail "raw launch battery counted $raw_launch_acceptance_count adapters instead of 6"
    echo "# all 6/6 documented raw harness heads succeeded through fm-spawn"
    exit 0
    ;;
  committed-handoff)
    write_relaunch_tmux_stub
    run_committed_handoff_battery
    [ "$committed_handoff_negative_count" -eq 5 ] \
      || fail "committed-handoff battery counted $committed_handoff_negative_count guards instead of 5"
    echo "# all 5/5 committed-handoff guards refused through fm-spawn"
    exit 0
    ;;
  fresh-smoke)
    prepare_relaunch_counterexample_root
    write_relaunch_tmux_stub
    exercise_negative "fresh smoke missing receipt" missing setup_missing_receipt
    exercise_negative "fresh smoke raw expansion" RAW_LAUNCH_NOT_VERIFIABLE setup_dynamic_raw \
      "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
    exercise_negative "fresh smoke ambiguous metadata" PERSISTENCE_REFUSED setup_ambiguous_routing_pointer \
      "current routing receipt pointer is ambiguous"
    echo "# all 3 fresh smoke assertions and counterexamples exercised real fm-spawn"
    exit 0
    ;;
esac

write_shell_differential_probe
exercise_shell_position_differential plain mid
exercise_shell_position_differential plain start
exercise_shell_position_differential single mid
exercise_shell_position_differential double mid
exercise_shell_position_differential double start
[ "$shell_differential_character_count" -gt 0 ] \
  || fail "shell differential derived no accepted raw byte/state-position cases"
[ "$shell_differential_run_count" -eq 20 ] \
  || fail "shell differential ran $shell_differential_run_count shell modes instead of 20"
pass "$shell_differential_character_count parser-derived printable ASCII state-position cases match real bash and zsh argv"
run_real_shell_differential separate-option-like-axis \
  "$SHELL_DIFF_PROBE --model -p --effort -q"

run_raw_launch_acceptance_battery

prepare_relaunch_counterexample_root
write_relaunch_tmux_stub
exercise_relaunch_negative "route-changing relaunch missing receipt" missing setup_missing_receipt
exercise_relaunch_negative "route-changing relaunch mismatched receipt" LAUNCH_BINDING_MISMATCH setup_model_binding_mismatch
exercise_relaunch_negative "route-changing relaunch stale receipt" STALE setup_stale
exercise_relaunch_negative "route-changing relaunch unobserved receipt" RAW_LAUNCH_NOT_VERIFIABLE setup_dynamic_raw \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
run_committed_handoff_battery

exercise_negative "01 missing receipt" missing setup_missing_receipt
exercise_negative "02 missing intent" missing setup_missing_intent
exercise_negative "03 empty receipt" MALFORMED_SCHEMA setup_empty_receipt
exercise_negative "04 empty intent" MALFORMED_INTENT setup_empty_intent
exercise_negative "05 task mismatch" TASK_MISMATCH setup_wrong_task
exercise_negative "06 stale receipt" STALE setup_stale
exercise_negative "07 future receipt" STALE setup_future
exercise_negative "08 emitted model mismatch" LAUNCH_BINDING_MISMATCH setup_model_binding_mismatch
exercise_negative "09 emitted effort mismatch" LAUNCH_BINDING_MISMATCH setup_effort_binding_mismatch
exercise_negative "10 canonical config removed" DISPATCH_CONFIG_MISMATCH setup_config_absent_after_receipt
exercise_negative "11 raw shell expansion" RAW_LAUNCH_NOT_VERIFIABLE setup_dynamic_raw \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_firing_raw_guard "11a raw trailing shell expansion" setup_trailing_dynamic_raw \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting" literal-words
exercise_negative "12 raw environment prefix" RAW_LAUNCH_NOT_VERIFIABLE setup_env_raw \
  "raw launch environment assignments can select an unobserved runtime"
exercise_firing_raw_guard "12a raw trailing environment assignment" setup_trailing_env_raw \
  "raw launch environment assignments can select an unobserved runtime" trailing-environment
exercise_negative "13 raw non-standard model flag" RAW_LAUNCH_NOT_VERIFIABLE setup_nonstandard_raw \
  "raw launch uses a non-standard model flag spelling"
exercise_negative "14 raw missing effort" RAW_LAUNCH_UNRESOLVED setup_unresolved_raw \
  "raw launches must expose fixed literal model and effort selections"
exercise_negative "15 intent hash mismatch" INTENT_HASH_MISMATCH setup_intent_hash_mismatch
exercise_negative "16 swapped brief" BRIEF_HASH_MISMATCH setup_brief_swap
exercise_negative "17 required gate mismatch" GATE_MISMATCH setup_gate_mismatch
exercise_negative "18 forbidden fallback" FORBIDDEN_FALLBACK setup_forbidden_fallback
exercise_negative "19 supervisor mismatch" SUPERVISOR_MISMATCH setup_supervisor_mismatch
exercise_negative "20 host mismatch" HOST_MISMATCH setup_host_mismatch
exercise_negative "21 candidate set mismatch" DISPATCH_CONFIG_MISMATCH setup_candidate_mismatch
exercise_negative "22 unknown receipt key" MALFORMED_SCHEMA setup_unknown_key
exercise_negative "23 missing multi-candidate quota" 'NOT_VERIFIABLE(QUOTA)' setup_missing_quota
exercise_negative "24 stale multi-candidate quota" 'NOT_VERIFIABLE(QUOTA)' setup_stale_quota
exercise_negative "25 singleton quota laundering" MALFORMED_QUOTA_BASIS setup_singleton_quota
exercise_negative "26 hostile final directory" PERSISTENCE_REFUSED setup_final_directory
exercise_negative "27 hostile final symlink" PERSISTENCE_REFUSED setup_final_symlink
exercise_negative "28 truncated receipt" MALFORMED_SCHEMA setup_truncated_receipt
exercise_negative "29 canonical config byte mutation" DISPATCH_CONFIG_MISMATCH setup_config_byte_mutation
exercise_negative "30 pending receipt symlink" missing setup_pending_symlink
exercise_negative "31 selection order tamper" MALFORMED_SCHEMA setup_selection_order_tamper
exercise_negative "32 quota snapshot byte mutation" 'NOT_VERIFIABLE(QUOTA)' setup_quota_byte_mutation
exercise_negative "33 quota snapshot symlink" 'NOT_VERIFIABLE(QUOTA)' setup_quota_symlink
exercise_negative "34 selected tuple outside candidates" INCAPABLE_CANDIDATE setup_selected_tuple_outside_candidates
exercise_negative "35 rule index out of range" DISPATCH_CONFIG_MISMATCH setup_rule_index_out_of_range
exercise_negative "36 wrong quota schema" 'NOT_VERIFIABLE(QUOTA)' setup_wrong_quota_schema

PLAIN_FORBIDDEN_PUNCT='!#$&()*;<>?[\]^`{|}~'
for ((punct_index = 0; punct_index < ${#PLAIN_FORBIDDEN_PUNCT}; punct_index++)); do
  RAW_PUNCTUATION=${PLAIN_FORBIDDEN_PUNCT:punct_index:1}
  exercise_negative "P$((punct_index + 1)) raw plain-state punctuation" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_punctuation \
    "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
done
exercise_negative "P21 raw embedded newline" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_newline \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "P22 raw embedded carriage return" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_carriage_return \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "D1 raw double-quoted history expansion" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_double_history \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "D2 raw double-quoted backslash" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_double_backslash \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "A1 raw leading equals" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_leading_equals \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "C1 raw single-quoted control byte" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_single_control \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "C2 raw plain-state tab" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_plain_tab \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "C3 raw single-quoted tab" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_single_tab \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "C4 raw double-quoted tab" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_double_tab \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "N1 raw plain non-ASCII" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_plain_nonascii \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "N2 raw single-quoted non-ASCII" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_single_nonascii \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
exercise_negative "N3 raw double-quoted non-ASCII" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_double_nonascii \
  "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"

while IFS='|' read -r shape_label RAW_SHAPE_COMMAND shape_detail; do
  [ -n "$shape_label" ] || continue
  exercise_negative "raw flag shape $shape_label" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_flag_shape "$shape_detail"
done <<'RAW_SHAPES'
model missing value|claude --effort high --model|model flag is missing a value or duplicated
model next value is a flag|claude --model --effort high|model flag has no fixed literal value
model short option value|claude --model -p --effort high|model flag has no fixed literal value
model equals duplicate|claude --model opus --model=sonnet --effort high|model flag is duplicated
model equals empty|claude --model= --effort high|model flag has no fixed literal value
fallback model separate|claude --model opus --effort high --fallback-model sonnet|raw launch uses an unattested model or fallback selector
fallback model equals|claude --model opus --effort high --fallback-model=sonnet|raw launch uses an unattested model or fallback selector
claude settings separate|claude --model opus --effort high --settings route.json|raw launch uses an unattested model-bearing Claude configuration
claude settings equals|claude --model opus --effort high --settings=route.json|raw launch uses an unattested model-bearing Claude configuration
claude agent separate|claude --model opus --effort high --agent reviewer|raw launch uses an unattested model-bearing Claude configuration
claude agents equals|claude --model opus --effort high --agents='{}'|raw launch uses an unattested model-bearing Claude configuration
effort missing value|claude --model opus --effort|effort flag is missing a value or duplicated
effort next value is a flag|claude --model opus --effort --flag|effort flag has no fixed literal value
effort short option value|claude --model opus --effort -p|effort flag has no fixed literal value
effort equals duplicate|claude --model opus --effort high --effort=low|effort flag is duplicated
effort equals empty|claude --model opus --effort=|effort flag has no fixed literal value
config missing value|claude --model opus -c|raw launch uses an unattested configuration or session selector
config effort duplicate|codex --model opus -c model_reasoning_effort=high -c model_reasoning_effort=low|effort flag is duplicated
config effort empty|codex --model opus -c model_reasoning_effort=|effort config has no fixed literal value
config effort unmatched quote|codex --model opus -c 'model_reasoning_effort="high'|effort config quote pair is unmatched
equals config effort duplicate|codex --model opus -c=model_reasoning_effort=high -c=model_reasoning_effort=low|effort flag is duplicated
equals config effort empty|codex --model opus -c=model_reasoning_effort=|effort config has no fixed literal value
equals config effort unmatched quote|codex --model opus '-c=model_reasoning_effort="high'|effort config quote pair is unmatched
codex config model separate|codex --model opus -c model=sonnet -c model_reasoning_effort=high|raw launch uses an unattested Codex configuration override
codex config model equals|codex --model opus -c=model=sonnet -c model_reasoning_effort=high|raw launch uses an unattested Codex configuration override
codex profile separate|codex --model opus -c model_reasoning_effort=high --profile fast|raw launch uses an unattested Codex model or provider configuration
codex profile equals|codex --model opus -c model_reasoning_effort=high --profile=fast|raw launch uses an unattested Codex model or provider configuration
codex oss provider|codex --model opus -c model_reasoning_effort=high --oss --local-provider ollama|raw launch uses an unattested Codex model or provider configuration
muse provider separate|muse --model opus --reasoning-effort high --provider echo|raw launch uses an unattested provider, account, router, or backend selector
muse account equals|muse --model opus --reasoning-effort high --account=alternate|raw launch uses an unattested provider, account, router, or backend selector
muse router separate|muse --model opus --reasoning-effort high --router direct|raw launch uses an unattested provider, account, router, or backend selector
muse backend equals|muse --model opus --reasoning-effort high --backend=echo|raw launch uses an unattested provider, account, router, or backend selector
command wrapper env|env ROUTE_MODEL=sonnet claude --model opus --effort high|raw launch command head is not a supported harness executable
command wrapper arch|arch claude --model opus --effort high|raw launch command head is not a supported harness executable
command wrapper taskset|taskset -c 0 claude --model opus --effort high|raw launch command head is not a supported harness executable
command wrapper caffeinate|caffeinate claude --model opus --effort high|raw launch command head is not a supported harness executable
command wrapper xcrun|xcrun claude --model opus --effort high|raw launch command head is not a supported harness executable
claude thinking spelling|claude --model opus --thinking high|effort spelling is not supported by the selected raw harness
codex effort spelling|codex --model opus --effort high|effort spelling is not supported by the selected raw harness
opencode effort spelling|opencode --model opus --effort high|effort spelling is not supported by the selected raw harness
muse thinking spelling|muse --model opus --thinking high|effort spelling is not supported by the selected raw harness
grok unsupported value|grok --model opus --reasoning-effort xhigh|effort value is not supported by the selected raw harness
RAW_SHAPES

exercise_negative "pi caller environment prefix" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_pi_caller_environment \
  "raw launch environment assignments can select an unobserved runtime"

exercise_negative "raw option terminator" RAW_LAUNCH_UNRESOLVED setup_raw_terminator \
  "raw launches must expose fixed literal model and effort selections"
exercise_negative "raw reserved placeholder" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_reserved_placeholder \
  "raw launch contains a reserved template placeholder expanded after receipt validation"
exercise_negative "raw cross-harness codex config" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_cross_harness_codex_config \
  "raw launch uses an unattested configuration or session selector"
exercise_negative "raw relative harness path" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_relative_harness_path \
  "raw launch command head uses a relative path"
exercise_negative "raw absolute harness impostor" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_absolute_harness_impostor \
  "absolute raw harness path is not the supported executable resolved through PATH"
exercise_negative "raw harness without effort syntax" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_unexpressible_effort \
  "selected raw harness cannot express the required effort axis"

exercise_negative "42 raw launch with unsupported executable" RAW_LAUNCH_NOT_VERIFIABLE setup_raw_unsupported_executable \
  "raw launch command head is not a supported harness executable"
exercise_negative "43 raw receipt harness contradiction" INCAPABLE_CANDIDATE setup_raw_harness_contradiction \
  "selected spawn tuple is not the attested capable candidate"
exercise_negative "44 raw model contradiction" RAW_LAUNCH_MISMATCH setup_raw_model_contradiction \
  "emitted model contradicts the selected tuple"
exercise_negative "45 raw effort contradiction" RAW_LAUNCH_MISMATCH setup_raw_effort_contradiction \
  "emitted effort contradicts the selected tuple"
exercise_negative "46 non-RFC3339 receipt timestamp" STALE setup_non_rfc3339_timestamp \
  "timestamp is not RFC3339 UTC"
exercise_negative "47 wrong multi-candidate quota basis" 'NOT_VERIFIABLE(QUOTA)' setup_wrong_multi_quota_basis \
  "multi-candidate route lacks the required quota basis"
exercise_negative "48 default source with index" DISPATCH_CONFIG_MISMATCH setup_default_wrong_index \
  "default source requires canonical configuration and a null index"
exercise_negative "49 default source without profile" DISPATCH_CONFIG_MISMATCH setup_default_missing_profile \
  "default profile is absent or malformed in canonical configuration"
exercise_negative "50 static source with config" AUTHORITY_MISMATCH setup_static_with_config \
  "static harness source requires canonical configuration absence and matching intent authority"
exercise_negative "51 static source with index" AUTHORITY_MISMATCH setup_static_wrong_index \
  "static harness source requires canonical configuration absence and matching intent authority"
exercise_negative "52 static source with wrong authority" AUTHORITY_MISMATCH setup_static_wrong_authority \
  "static harness source requires canonical configuration absence and matching intent authority"
exercise_negative "53 static source with multiple candidates" MALFORMED_SCHEMA setup_static_non_singleton \
  "static harness source must be a singleton candidate set"
exercise_negative "54 explicit source with index" AUTHORITY_MISMATCH setup_explicit_wrong_index \
  "explicit runtime override is not present in the exact intent"
exercise_negative "55 explicit source with wrong authority" AUTHORITY_MISMATCH setup_explicit_wrong_authority \
  "explicit runtime override is not present in the exact intent"
exercise_negative "56 explicit source with multiple candidates" MALFORMED_SCHEMA setup_explicit_non_singleton \
  "explicit runtime override must be a singleton candidate set"
exercise_negative "57 unsupported authority source" MALFORMED_SCHEMA setup_unsupported_source \
  "matched_profile.source is unsupported"
exercise_negative "58 rule source with noninteger index" MALFORMED_SCHEMA setup_rule_noninteger_index \
  "rule match requires a non-negative integer index"

# Pin the exact rule-resolution guard rather than accepting a later refusal with
# the same broad predicate after the matched rule lookup is removed.
exercise_negative "59 rule source with malformed profile" DISPATCH_CONFIG_MISMATCH setup_rule_malformed_profile \
  "matched rule is absent or malformed in canonical configuration"
exercise_negative "60 rule source with post-binding kind drift" DISPATCH_CONFIG_MISMATCH setup_rule_binding_kind_drift \
  "rule source requires canonical dispatch configuration"
exercise_negative "61 pending receipt replaced after snapshot" PERSISTENCE_REFUSED setup_pending_replaced_after_snapshot \
  "PENDING_IDENTITY"
exercise_negative "62 pending receipt directory after snapshot" PERSISTENCE_REFUSED setup_pending_directory_after_snapshot \
  "OPEN_REGULAR:routing-decision.pending.json" assert_pending_directory_preserved
exercise_negative "63 existing generation directory has the wrong mode" PERSISTENCE_REFUSED setup_final_directory_after_check \
  "COLLISION:routing-generation"
exercise_negative "66 same-generation receipt collision" PERSISTENCE_REFUSED \
  setup_pending_mutated_in_place_after_compare \
  "COLLISION:receipt.json:bytes"
exercise_negative "67 pending replacement remains at its pathname" PERSISTENCE_REFUSED \
  setup_pending_recreated_after_relocation \
  "OPEN_REGULAR:routing-decision.pending.json" assert_pending_replacement_never_relocated
exercise_negative "68 same-generation brief collision" PERSISTENCE_REFUSED \
  setup_preexisting_writable_brief "COLLISION:brief.md:bytes"
exercise_negative "69 hard-linked generation artifact" PERSISTENCE_REFUSED \
  setup_preexisting_hardlinked_brief "COLLISION:brief.md:ownership"
exercise_negative "70 canonical config symlink before snapshot" 'NOT_VERIFIABLE(CONFIG)' \
  setup_config_symlink_before_snapshot "OPEN_REGULAR:crew-dispatch.json" assert_config_symlink_not_followed
exercise_negative "71 snapshot identity substitution" PERSISTENCE_REFUSED \
  setup_snapshot_identity_substitution "SNAPSHOT_IDENTITY"
exercise_negative "72 malformed consumed-generation ledger" PERSISTENCE_REFUSED \
  setup_malformed_consumed_ledger "LEDGER_FORMAT:routing-generations.consumed"
exercise_negative "73 ambiguous routing receipt pointer" PERSISTENCE_REFUSED \
  setup_ambiguous_routing_pointer "current routing receipt pointer is ambiguous"

write_fixture
symlinked_task_target="$LAB/symlinked-task-target"
mv "$TASK_DIR" "$symlinked_task_target"
ln -s "$symlinked_task_target" "$TASK_DIR"
mkdir "$TASK_DIR/.routing-decision.validate.firing"
assert_present "$symlinked_task_target/.routing-decision.validate.firing" \
  "final task-directory symlink counterexample did not redirect path-based creation"
rmdir "$TASK_DIR/.routing-decision.validate.firing"
symlinked_task_out=$(run_validator_then_effects 2>&1)
symlinked_task_status=$?
expect_code 1 "$symlinked_task_status" "a symlinked final task-directory component should refuse"
assert_contains "$symlinked_task_out" "ROUTING_DECISION NOT_VERIFIABLE(SNAPSHOT)" \
  "symlinked final task-directory refusal named the wrong predicate"
assert_contains "$symlinked_task_out" "OPEN_DIR:$TASK_DIR" \
  "symlinked final task-directory refusal did not come from the no-follow boundary"
symlinked_task_residue=$(find "$symlinked_task_target" -mindepth 1 -maxdepth 1 -type d -name '.routing-decision.validate.*' -print)
[ -z "$symlinked_task_residue" ] \
  || fail "symlinked final task-directory refusal created a validation directory through the link: $symlinked_task_residue"
assert_no_effects
pass "final task-directory symlink refuses before validation snapshot creation"

write_fixture
fm_routing_decision_validate_and_prepare \
  "$HOME_DIR/data" "$HOME_DIR/config" t1 \
  "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
  "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT" \
  || fail "byte-identical staging test could not prepare"
mkdir "$(generation_dir)"
chmod 0700 "$(generation_dir)"
cp "$TASK_DIR/routing-decision.pending.json" "$(receipt_final)"
cp "$TASK_DIR/brief.md" "$(brief_final)"
chmod 0400 "$(receipt_final)" "$(brief_final)"
idempotent_out="$LAB/idempotent.out"
fm_routing_decision_persist_prepared > "$idempotent_out" 2>&1 \
  || fail "byte-identical generation publication was not idempotent: $(< "$idempotent_out")"
fm_routing_decision_consume_prepared || fail "idempotent generation was not consumed"
fm_routing_decision_seal_prepared || fail "idempotent generation did not seal"
mkdir -p "$LAB/worktree.lease" "$LAB/endpoint"
printf 'published\n' > "$HOME_DIR/state/t1.meta"
assert_present "$LAB/worktree.lease" "idempotent generation did not reach the worktree lease"
cmp -s "$TASK_DIR/routing-decision.pending.json" "$(receipt_final)" \
  || fail "idempotent generation changed the receipt artifact"
pass "byte-identical generation publication is idempotent"

write_fixture
setup_final_directory
setup_secondmate_relaunch_task
secondmate_out=$(run_relaunch_spawn "$SPAWN")
secondmate_status=$?
expect_code 1 "$secondmate_status" "route-changing secondmate relaunch should refuse a hostile final receipt"
assert_contains "$secondmate_out" "ROUTING_DECISION PERSISTENCE_REFUSED" \
  "route-changing secondmate relaunch named the wrong refusal predicate"
assert_absent "$RELAUNCH_WT/state" \
  "route-changing secondmate relaunch mutated its home before receipt commitment"
assert_relaunch_refused_before_effects
pass "route-changing secondmate relaunch commits before home mutation"

write_fixture
expected_config_hash=$(jq -r '.dispatch_config.sha256' "$TASK_DIR/routing-decision.pending.json")
POST_SNAPSHOT_CONFIG_FILTER='.rules[0].use.model = "sonnet"'
run_validator_then_effects >/dev/null 2>&1 || fail "canonical config replacement escaped its validation snapshot"
[ "$(jq -r '.dispatch_config.sha256' "$(receipt_final)")" = "$expected_config_hash" ] \
  || fail "persisted receipt did not retain the validated canonical config snapshot hash"
[ "$(sha_file "$HOME_DIR/config/crew-dispatch.json")" != "$expected_config_hash" ] \
  || fail "canonical config replacement counterexample did not fire"
pass "canonical config replacement cannot change snapshotted candidate resolution"

write_fixture
expected_generation=$(receipt_generation)
fm_routing_decision_validate_and_prepare \
  "$HOME_DIR/data" "$HOME_DIR/config" t1 \
  "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
  "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT" \
  || fail "immutable generation test could not prepare a valid receipt"
MUTABLE_GENERATION_COUNTEREXAMPLE=1
fm_routing_sha256_file() {
  local source=$1 backup="$LAB/generation-source.backup" altered
  if [ "$MUTABLE_GENERATION_COUNTEREXAMPLE" -eq 0 ] \
    || [ "$source" != "$TASK_DIR/routing-decision.pending.json" ]; then
    sha_file "$source"
    return
  fi
  cp "$source" "$backup" || return 1
  altered="$source.altered"
  "$REAL_JQ" '.rationale = "mutable pathname generation counterexample"' "$source" > "$altered" || return 1
  cp "$altered" "$source" || return 1
  rm "$altered"
  sha_file "$source"
  cp "$backup" "$source" || return 1
  rm "$backup"
}
mutable_generation=$(fm_routing_sha256_file "$TASK_DIR/routing-decision.pending.json")
[ "$mutable_generation" != "$expected_generation" ] \
  || fail "mutable pathname generation counterexample did not fire"
fm_routing_decision_persist_prepared \
  || fail "generation was not derived from the immutable validated snapshot"
fm_routing_decision_consume_prepared \
  || fail "immutable snapshot generation was not consumed"
fm_routing_decision_seal_prepared \
  || fail "immutable snapshot generation did not seal"
MUTABLE_GENERATION_COUNTEREXAMPLE=0
assert_present "$TASK_DIR/routing-generation.$expected_generation/receipt.json" \
  "immutable snapshot generation was not published"
assert_absent "$TASK_DIR/routing-generation.$mutable_generation/receipt.json" \
  "mutable pending pathname selected the durable generation"
pass "generation derives from the immutable validated snapshot"

write_fixture
fm_routing_decision_validate_and_prepare \
  "$HOME_DIR/data" "$HOME_DIR/config" t1 \
  "$RUN_HARNESS" "$RUN_MODEL" "$RUN_EFFORT" "$HOME_DIR" "$RUN_RAW" "$RUN_LAUNCH" \
  "$RUN_MODEL_FRAGMENT" "$RUN_EFFORT_FRAGMENT" \
  || fail "immutable freshness test could not prepare a valid receipt"
prepared_generation=$FM_ROUTING_PREPARED_GENERATION
update_receipt '.generated_at = "2000-01-01T00:00:00Z"'
freshness_out=$(fm_routing_decision_persist_prepared 2>&1)
freshness_status=$?
expect_code 1 "$freshness_status" "mutable pending freshness bypass unexpectedly published"
assert_contains "$freshness_out" "PENDING_IDENTITY" \
  "final freshness did not come from the immutable prepared receipt"
case "$freshness_out" in
  *"ROUTING_DECISION STALE"*) fail "mutable pending timestamp controlled the final freshness verdict" ;;
esac
assert_absent "$TASK_DIR/routing-generation.$prepared_generation" \
  "freshness counterexample left a generation artifact"
pass "final freshness reads the immutable prepared receipt"

write_fixture
run_validator_then_effects >/dev/null 2>&1 \
  || fail "one-shot generation setup did not publish"
printf 'routing_decision=%s\n' "$(receipt_final)" > "$HOME_DIR/state/t1.meta"
rm -rf "$LAB/worktree.lease" "$LAB/endpoint"
reuse_out=$(run_validator_then_effects 2>&1)
reuse_status=$?
expect_code 1 "$reuse_status" "successful ordinary generation was reusable"
assert_contains "$reuse_out" "ROUTING_DECISION PERSISTENCE_REFUSED" \
  "ordinary generation reuse named the wrong predicate"
assert_contains "$reuse_out" "already authorizes the current agent" \
  "ordinary generation reuse did not name its metadata authority"
PREEXISTING_FINAL=1
assert_absent "$LAB/worktree.lease" "one-shot refusal leased a worktree"
assert_absent "$LAB/endpoint" "one-shot refusal created an endpoint"
[ "$(sed -n 's/^routing_decision=//p' "$HOME_DIR/state/t1.meta")" = "$(receipt_final)" ] \
  || fail "one-shot refusal changed authoritative task metadata"
pass "successful metadata makes its current generation one-shot"

write_fixture
generation_a=$(receipt_generation)
receipt_a="$LAB/receipt-a.json"
cp "$TASK_DIR/routing-decision.pending.json" "$receipt_a"
run_validator_then_effects >/dev/null 2>&1 \
  || fail "consumed-generation ledger could not record generation A"
rm -rf "$LAB/worktree.lease" "$LAB/endpoint"
rm "$HOME_DIR/state/t1.meta"
update_receipt '.rationale = "fresh generation B"'
generation_b=$(receipt_generation)
[ "$generation_a" != "$generation_b" ] \
  || fail "consumed-generation setup did not produce distinct generations"
run_validator_then_effects >/dev/null 2>&1 \
  || fail "consumed-generation ledger could not record generation B"
rm -rf "$LAB/worktree.lease" "$LAB/endpoint"
rm "$HOME_DIR/state/t1.meta"
cp "$receipt_a" "$TASK_DIR/routing-decision.pending.json"
reuse_out=$(run_validator_then_effects 2>&1)
reuse_status=$?
expect_code 1 "$reuse_status" "restored generation A was reusable after generation B"
assert_contains "$reuse_out" "ROUTING_DECISION PERSISTENCE_REFUSED" \
  "historical generation reuse named the wrong predicate"
assert_contains "$reuse_out" "CONSUMED_GENERATION:$generation_a" \
  "historical generation reuse did not identify the consumed generation"
assert_absent "$LAB/worktree.lease" "historical generation reuse leased a worktree"
assert_absent "$LAB/endpoint" "historical generation reuse created an endpoint"
assert_absent "$HOME_DIR/state/t1.meta" "historical generation reuse published metadata"
if (
  # shellcheck disable=SC2329 # Invoked indirectly by run_validator_then_effects.
  fm_routing_fs_boundary() {
    if [ "$1" = consume-generation ]; then
      printf '%s\n' "$3"
      return 0
    fi
    "$REAL_PERL" "$ROOT/bin/fm-routing-fs-boundary.pl" "$@"
  }
  run_validator_then_effects >/dev/null 2>&1
); then
  assert_present "$LAB/worktree.lease" \
    "historical-generation counterexample did not lease a worktree"
  assert_present "$LAB/endpoint" \
    "historical-generation counterexample did not create an endpoint"
  assert_present "$HOME_DIR/state/t1.meta" \
    "historical-generation counterexample did not publish metadata"
else
  fail "historical-generation counterexample did not fire when only the ledger guard was bypassed"
fi
pass "consumed ledger rejects restored generation A after generation B"

expected_count=$((133 + ${#PLAIN_FORBIDDEN_PUNCT}))
[ "$negative_count" -eq "$expected_count" ] \
  || fail "negative battery counted $negative_count refusals instead of $expected_count"
[ "$counterexample_count" -eq "$expected_count" ] \
  || fail "negative battery counted $counterexample_count counterexamples instead of $expected_count"
[ "$raw_guard_counterexample_count" -eq 2 ] \
  || fail "negative battery counted $raw_guard_counterexample_count exact raw-guard counterexamples instead of 2"
[ "$fresh_spawn_negative_count" -eq 147 ] \
  || fail "negative battery counted $fresh_spawn_negative_count fresh fm-spawn negatives instead of 147"
[ "$fresh_spawn_counterexample_count" -eq 147 ] \
  || fail "negative battery counted $fresh_spawn_counterexample_count fresh fm-spawn counterexamples instead of 147"
[ "$committed_handoff_negative_count" -eq 5 ] \
  || fail "negative battery counted $committed_handoff_negative_count committed-handoff guards instead of 5"
[ "$raw_launch_acceptance_count" -eq 6 ] \
  || fail "negative battery counted $raw_launch_acceptance_count raw harness heads instead of 6"
echo "# 147 fresh-dispatch negatives and 4 route-changing relaunch negatives refused through real fm-spawn"
echo "# all 147 fresh-dispatch assertions reached lease, endpoint, pane-input, and metadata effects when the fm-spawn routing requirement was neutered"
echo "# both 2/2 load-bearing raw-launch assertions went red when their exact guards were neutered"
echo "# all 5/5 committed-handoff guards refused through fm-spawn; per-guard mutation evidence is recorded by the repair validation"
echo "# all 6/6 documented raw harness heads succeeded through fm-spawn"
