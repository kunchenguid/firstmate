#!/usr/bin/env bash
# Deterministic Agent Fleet integration tests for spawn, recovery, and rollback.
# A fake Agent Fleet and fake tmux capture every command; no profile home,
# credential, real endpoint, global config, or live worker is touched.
set -u
export FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1
export FM_ACCOUNT_ROUTING_LEGACY_NEW_LAUNCH_TEST=firstmate-remove-fleet-routing-deadcode-fixture-v1
export FM_ORCA_TEST_LAB=firstmate-orca-test-lab-v1
export FM_ORCA_TEST_AUTHORITY_CAPABILITIES=verified-v1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SESSION_SYNC="$ROOT/bin/fm-account-session-sync.sh"
CONTINUATION="$ROOT/bin/fm-account-continuation.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-routing-tests)

assert_not_grep() {
  local pattern=$1 file=$2 label=$3
  grep -Eq "$pattern" "$file" 2>/dev/null && fail "$label"
  return 0
}

assert_regex() {
  local pattern=$1 file=$2 label=$3
  grep -Eq "$pattern" "$file" 2>/dev/null || fail "$label"
}

write_continuation_ancestor_swap_hook() {
  mkdir -p "$1"
  cat > "$1/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == os.path.basename(os.environ["FM_CONTINUATION_SWAP_TARGET"]):
        swapped = True
        os.rename(os.environ["FM_CONTINUATION_SWAP_PARENT"], os.environ["FM_CONTINUATION_SWAP_MOVED"])
        os.symlink(os.environ["FM_CONTINUATION_SWAP_OUTSIDE"], os.environ["FM_CONTINUATION_SWAP_PARENT"], target_is_directory=True)
        with open(os.environ["FM_CONTINUATION_SWAP_MARKER"], "w", encoding="utf-8") as marker:
            marker.write("swapped\n")
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  display-message*"#{session_name}"*"#{window_name}"*)
    printf '%s\t' "${FM_FAKE_TMUX_SESSION:-firstmate}"
    if [ "${FM_FAKE_TMUX_RENAMED:-0}" = 1 ]; then
      printf 'fm-renamed-task\n'
    else
      cat "${FM_FAKE_TMUX_LABEL_FILE:-/nonexistent}"
    fi
    exit $?
    ;;
  display-message*"#{window_name}"*)
    if [ "${FM_FAKE_TMUX_RENAMED:-0}" = 1 ]; then
      printf 'fm-renamed-task\n'
    else
      cat "${FM_FAKE_TMUX_LABEL_FILE:-/nonexistent}"
    fi
    exit $?
    ;;
  display-message*"#{pane_id}"*)
    case "${FM_FAKE_TARGET_STATE:-auto}" in
      present) exit 0 ;;
      absent|unknown) exit 1 ;;
    esac
    if [ "${FM_FAKE_TMUX_RENAMED:-0}" = 1 ]; then
      case "$*" in *'%77'*) [ -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}" ]; exit $? ;; *) exit 1 ;; esac
    fi
    [ -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}" ]; exit $?
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf '│ │\n'; exit 0 ;;
  list-panes) [ "${FM_FAKE_TARGET_STATE:-auto}" != unknown ]; exit $? ;;
  list-windows)
    [ "${FM_FAKE_TMUX_LIST_WINDOWS_UNKNOWN:-0}" != 1 ] || exit 1
    exit 0
    ;;
  has-session|new-session|set-window-option) exit 0 ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" != 1 ] || exit 71
    rm -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"
    exit 0
    ;;
  new-window)
    case "$*" in *"${FM_FAKE_TMUX_FAIL_LABEL:-__never__}"*) exit 41 ;; esac
    prev=
    for arg in "$@"; do
      if [ "$prev" = -n ]; then
        printf '%s\n' "$arg" > "${FM_FAKE_TMUX_LABEL_FILE:-/nonexistent}"
        break
      fi
      prev=$arg
    done
    [ -z "${FM_FAKE_TMUX_NEW_WINDOW_MARKER:-}" ] || touch "$FM_FAKE_TMUX_NEW_WINDOW_MARKER"
    if [ -n "${FM_FAKE_TMUX_NEW_WINDOW_GATE:-}" ]; then
      while [ ! -f "$FM_FAKE_TMUX_NEW_WINDOW_GATE" ]; do sleep 0.05; done
    fi
    touch "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"
    printf '%%77\n'
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_TMUX_GATE_SEND_MATCH:-}" ]; then
      case "$*" in
        *"$FM_FAKE_TMUX_GATE_SEND_MATCH"*)
          [ -z "${FM_FAKE_TMUX_GATE_SEND_MARKER:-}" ] || touch "$FM_FAKE_TMUX_GATE_SEND_MARKER"
          while [ -n "${FM_FAKE_TMUX_GATE_SEND_RELEASE:-}" ] \
            && [ ! -f "$FM_FAKE_TMUX_GATE_SEND_RELEASE" ]; do
            sleep 0.05
          done
          ;;
      esac
    fi
    if [ -n "${FM_FAKE_TMUX_FAIL_SEND_MATCH:-}" ]; then
      case "$*" in *"$FM_FAKE_TMUX_FAIL_SEND_MATCH"*) exit 72 ;; esac
    fi
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for arg in "$@"; do
        if [ "$prev" = -l ]; then
          printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
          case "$arg" in
            *' resume --task '*) [ -z "${FM_FAKE_AF_RESUME_ARM:-}" ] || touch "$FM_FAKE_AF_RESUME_ARM" ;;
            *'account-native-launch'*)
              [ -z "${FM_FAKE_AF_RESUME_ARM:-}" ] || touch "$FM_FAKE_AF_RESUME_ARM"
              native_path=${arg#*\'}
              native_path=${native_path%%\'*}
              [ -z "${FM_FAKE_AF_RESUME_ARM:-}" ] || printf '%s\n' "${native_path%/account-native-launch}" > "$FM_FAKE_AF_RESUME_ARM.native-dir"
              [ -z "${FM_FAKE_NATIVE_LAUNCH_LOG:-}" ] || cat "$native_path" >> "$FM_FAKE_NATIVE_LAUNCH_LOG"
              ;;
          esac
        fi
        prev=$arg
      done
    fi
    case "$*" in
      *' Enter')
        if [ -n "${FM_FAKE_AF_RESUME_ARM:-}" ] && [ -f "$FM_FAKE_AF_RESUME_ARM" ]; then
          rm -f "$FM_FAKE_AF_RESUME_ARM"
          resume_ready=${FM_FAKE_AF_RESUME_READY:-}
          resume_go=${FM_FAKE_AF_RESUME_GO:-}
          if [ -f "$FM_FAKE_AF_RESUME_ARM.native-dir" ]; then
            native_dir=$(cat "$FM_FAKE_AF_RESUME_ARM.native-dir")
            resume_ready="$native_dir/ready"
            resume_go="$native_dir/go"
          fi
          [ -z "$resume_ready" ] || touch "$resume_ready"
          (
            for _ in $(seq 1 200); do
              [ -n "$resume_go" ] && [ -f "$resume_go" ] && break
              sleep 0.05
            done
            if [ -n "$resume_go" ] && [ -f "$resume_go" ] \
              && [ "${FM_FAKE_AF_RESUME_NO_REFRESH:-0}" != 1 ] && [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ]; then
              touch "$FM_FAKE_AF_SESSION_REFRESHED"
            fi
          ) </dev/null >/dev/null 2>&1 &
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
[ -z "${FM_FAKE_TREEHOUSE_SLEEP:-}" ] || sleep "$FM_FAKE_TREEHOUSE_SLEEP"
if [ "${1:-}" = return ] && [ -n "${FM_EXPECT_CHECKOUT_LOCK:-}" ]; then
  [ -e "$FM_EXPECT_CHECKOUT_LOCK" ] || [ -L "$FM_EXPECT_CHECKOUT_LOCK" ] || exit 91
  lock_pid=$(cat "$FM_EXPECT_CHECKOUT_LOCK/pid" 2>/dev/null || true)
  kill -0 "$lock_pid" 2>/dev/null || exit 92
  [ -z "${FM_EXPECT_CHECKOUT_LOCK_MARKER:-}" ] || touch "$FM_EXPECT_CHECKOUT_LOCK_MARKER"
fi
if [ "${1:-}" = return ] && [ -n "${FM_FAKE_TREEHOUSE_RETURN_CHILD_PID_FILE:-}" ]; then
  [ -z "${FM_FAKE_TREEHOUSE_RETURN_MARKER:-}" ] || : > "$FM_FAKE_TREEHOUSE_RETURN_MARKER"
  (
    trap '' HUP TERM
    while :; do sleep 0.1; done
  ) &
  printf '%s\n' "$!" > "$FM_FAKE_TREEHOUSE_RETURN_CHILD_PID_FILE"
fi
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_PATH:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_ORCA_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ORCA_LOG"
case "$*" in
  'status --json') printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'; exit 0 ;;
esac
echo "unexpected fake orca command: $*" >&2
exit 64
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_AF_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'agent-fleet %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
task=
pool=
profile=${FM_FAKE_AF_PROFILE:-claude-2}
provider=${FM_FAKE_AF_PROVIDER:-claude}
workspace=
prev=
for arg in "$@"; do
  case "$prev" in
    --task) task=$arg ;;
    --pool) pool=$arg ;;
    --profile) profile=$arg ;;
    --provider) provider=$arg ;;
    --workspace) workspace=$arg ;;
  esac
  prev=$arg
done
case "$*" in
  '--format json contract')
    [ -z "${FM_FAKE_AF_CONTRACT_SLEEP:-}" ] || sleep "$FM_FAKE_AF_CONTRACT_SLEEP"
    printf '{"contract_version":%s}\n' "${FM_FAKE_AF_CONTRACT_VERSION:-2}"
    ;;
  *" choose "*|*" lease choose "*|*" lease acquire "*|*" lease recover "*)
    if [ -n "${FM_FAKE_AF_REQUIRE_PRELEASE_META:-}" ]; then
      grep -qxF "account_task=$task" "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        && grep -qxF 'account_rollback_cleanup=pending' "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        && grep -qxF 'tmux_window_id=%77' "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        || { echo "managed account identity was not durable before lease mutation" >&2; exit 91; }
    fi
    [ -z "${FM_FAKE_AF_SELECT_MUTATE_FILE:-}" ] || printf 'replacement-state\n' > "$FM_FAKE_AF_SELECT_MUTATE_FILE"
    if [ -n "${FM_FAKE_AF_REPLACE_LOCK_OWNER_FILE:-}" ]; then
      printf '%s\n%s\n' "${FM_FAKE_AF_REPLACE_LOCK_OWNER_PID:?}" \
        "${FM_FAKE_AF_REPLACE_LOCK_OWNER_START:?}" > "$FM_FAKE_AF_REPLACE_LOCK_OWNER_FILE"
    fi
    [ "${FM_FAKE_AF_SELECT_FAIL:-0}" != 1 ] || exit 42
    if [ "${FM_FAKE_AF_BAD_SELECTION:-0}" = 1 ]; then printf '{bad json\n'; exit 0; fi
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    case "$*" in
      *" lease recover "*)
        [ "${FM_FAKE_AF_RECOVER_FAIL:-0}" != 1 ] || exit "${FM_FAKE_AF_RECOVER_FAIL_STATUS:-42}"
        if [ -n "${FM_FAKE_AF_RECOVER_FAIL_ONCE_FILE:-}" ] && [ ! -e "$FM_FAKE_AF_RECOVER_FAIL_ONCE_FILE" ]; then
          : > "$FM_FAKE_AF_RECOVER_FAIL_ONCE_FILE"
          exit "${FM_FAKE_AF_RECOVER_FAIL_STATUS:-42}"
        fi
        [ -z "${FM_FAKE_AF_RECOVER_SLEEP:-}" ] || sleep "$FM_FAKE_AF_RECOVER_SLEEP"
        [ -z "${FM_FAKE_AF_RECOVER_TASK:-}" ] || task=$FM_FAKE_AF_RECOVER_TASK
        [ "${FM_FAKE_AF_STALE_REFRESH_ON_RECOVER:-0}" != 1 ] || touch "${FM_FAKE_AF_SESSION_REFRESHED:?}"
        ;;
      *" lease choose "*|*" lease acquire "*)
        [ -z "${FM_FAKE_AF_CHOOSE_FAIL_STATUS:-}" ] || exit "$FM_FAKE_AF_CHOOSE_FAIL_STATUS"
        [ -z "${FM_FAKE_AF_SELECT_SLEEP:-}" ] || sleep "$FM_FAKE_AF_SELECT_SLEEP"
        ;;
    esac
    [ -z "${FM_FAKE_AF_SELECTION_WORKSPACE:-}" ] || workspace=$FM_FAKE_AF_SELECTION_WORKSPACE
    printf '{"schema":1,"task":"%s","pool":"%s","profile":"%s","provider":"%s","workspace":"%s","decision_reason":"fake","quota_fresh":true,"headroom_percent":5,"active_lease_count":0,"degraded":false}\n' "$task" "$pool" "$profile" "$provider" "$workspace"
    ;;
  *" session status "*)
    [ "${FM_FAKE_AF_SESSION_MISSING:-0}" != 1 ] || exit 1
    resume_go=${FM_FAKE_AF_RESUME_GO:-}
    if [ -n "${FM_FAKE_AF_RESUME_ARM:-}" ] && [ -f "$FM_FAKE_AF_RESUME_ARM.native-dir" ]; then
      resume_go="$(cat "$FM_FAKE_AF_RESUME_ARM.native-dir")/go"
    fi
    if [ -n "$resume_go" ] && [ -f "$resume_go" ] \
      && [ "${FM_FAKE_AF_RESUME_NO_REFRESH:-0}" != 1 ] && [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ]; then
      touch "$FM_FAKE_AF_SESSION_REFRESHED"
    fi
    [ -z "${FM_FAKE_AF_SESSION_MARKER:-}" ] || touch "$FM_FAKE_AF_SESSION_MARKER"
    if [ -n "${FM_FAKE_AF_SESSION_CHILD_PID_FILE:-}" ]; then
      (
        trap '' HUP INT TERM
        while :; do sleep 1; done
      ) &
      printf '%s\n' "$!" > "$FM_FAKE_AF_SESSION_CHILD_PID_FILE"
      wait "$!"
    fi
    if [ -n "${FM_FAKE_AF_SESSION_SLEEP:-}" ] \
      && { [ -z "${FM_FAKE_AF_SESSION_SLEEP_TASK:-}" ] || [ "$task" = "$FM_FAKE_AF_SESSION_SLEEP_TASK" ]; }; then
      sleep "$FM_FAKE_AF_SESSION_SLEEP"
    fi
    if [ -n "${FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_FILE:-}" ]; then
      printf '%s\n%s\n' "${FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_PID:?}" \
        "${FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_START:?}" > "$FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_FILE"
    fi
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    updated_at=${FM_FAKE_AF_UPDATED_AT_BEFORE:-2026-07-13T00:00:00Z}
    session_schema=${FM_FAKE_AF_SESSION_SCHEMA_BEFORE:-2}
    session_event_seq=${FM_FAKE_AF_SESSION_EVENT_SEQ_BEFORE:-1}
    if [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ] && [ -f "$FM_FAKE_AF_SESSION_REFRESHED" ]; then
      updated_at=${FM_FAKE_AF_UPDATED_AT_AFTER:-2026-07-13T00:00:01Z}
      session_schema=${FM_FAKE_AF_SESSION_SCHEMA_AFTER:-2}
      session_event_seq=${FM_FAKE_AF_SESSION_EVENT_SEQ_AFTER:-2}
    fi
    workspace=${FM_FAKE_AF_WORKSPACE:-}
    if [ -z "$workspace" ] && [ -n "${FM_STATE_OVERRIDE:-}" ]; then
      for candidate in "$FM_STATE_OVERRIDE"/*.meta; do
        [ -f "$candidate" ] || continue
        [ "$(sed -n 's/^account_task=//p' "$candidate" | tail -1)" = "$task" ] || continue
        workspace=$(sed -n 's/^worktree=//p' "$candidate" | tail -1)
        break
      done
    fi
    printf '{"schema":%s,"task":"%s","profile":"%s","provider":"%s","pool":"%s","workspace":"%s","session_id":"sess-%s","session_event_seq":%s,"updated_at":"%s"}\n' "$session_schema" "$task" "$profile" "$provider" "$pool" "$workspace" "$task" "$session_event_seq" "$updated_at"
    ;;
  *" lease release "*)
    [ -z "${FM_FAKE_AF_RELEASE_SLEEP:-}" ] || sleep "$FM_FAKE_AF_RELEASE_SLEEP"
    [ -z "${FM_FAKE_AF_RELEASE_MARKER:-}" ] || touch "$FM_FAKE_AF_RELEASE_MARKER"
    [ "${FM_FAKE_AF_RELEASE_FAIL:-0}" != 1 ] || exit 43
    if [ -n "${FM_FAKE_AF_RELEASE_FAIL_ONCE:-}" ] && [ ! -f "$FM_FAKE_AF_RELEASE_FAIL_ONCE" ]; then
      touch "$FM_FAKE_AF_RELEASE_FAIL_ONCE"
      exit 43
    fi
    if [ -n "${FM_FAKE_AF_RELEASE_SWAP_BACKUP:-}" ]; then
      rm -f "$FM_FAKE_AF_RELEASE_SWAP_BACKUP"
      ln -s "${FM_FAKE_AF_RELEASE_SWAP_TARGET:?}" "$FM_FAKE_AF_RELEASE_SWAP_BACKUP"
    fi
    printf '{"ok":true}\n'
    ;;
  *" session remove "*)
    [ -z "${FM_FAKE_AF_SESSION_REMOVE_SLEEP:-}" ] || sleep "$FM_FAKE_AF_SESSION_REMOVE_SLEEP"
    [ "${FM_FAKE_AF_SESSION_REMOVE_FAIL:-0}" != 1 ] || exit 44
    if [ -n "${FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE:-}" ] && [ ! -f "$FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE" ]; then
      touch "$FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE"
      exit 44
    fi
    printf '{"ok":true}\n'
    ;;
  *) echo "unexpected fake agent-fleet command: $*" >&2; exit 64 ;;
esac
SH
  chmod +x "$fakebin/agent-fleet"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$wt" checkout --quiet --detach
  fm_git_add_origin "$proj" "$case_dir/origin.git"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  AF_LOG="$CASE_DIR/agent-fleet.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  LIFECYCLE_LOG="$CASE_DIR/lifecycle.log"
  ORCA_LOG="$CASE_DIR/orca.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  NATIVE_LAUNCH_LOG="$CASE_DIR/native-launch.log"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
  : > "$LIFECYCLE_LOG"
  : > "$ORCA_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="${FM_TEST_PANE_PATH:-$WT_DIR}" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_LIFECYCLE_LOG="$LIFECYCLE_LOG" \
    FM_EXPECT_CHECKOUT_LOCK="${FM_EXPECT_CHECKOUT_LOCK:-}" \
    FM_EXPECT_CHECKOUT_LOCK_MARKER="${FM_EXPECT_CHECKOUT_LOCK_MARKER:-}" \
    FM_FAKE_TREEHOUSE_PATH="$WT_DIR" FM_TREEHOUSE_ROOT="$CASE_DIR/treehouse-pools" \
    FM_FAKE_TREEHOUSE_SLEEP="${FM_FAKE_TREEHOUSE_SLEEP:-}" \
    FM_FAKE_TREEHOUSE_RETURN_CHILD_PID_FILE="${FM_FAKE_TREEHOUSE_RETURN_CHILD_PID_FILE:-}" \
    FM_FAKE_TREEHOUSE_RETURN_MARKER="${FM_FAKE_TREEHOUSE_RETURN_MARKER:-}" \
    FM_TEST_REAL_PS="${FM_TEST_REAL_PS:-}" \
    FM_TREEHOUSE_ACQUIRE_TIMEOUT="${FM_TREEHOUSE_ACQUIRE_TIMEOUT:-60}" \
    FM_FAKE_ORCA_LOG="$ORCA_LOG" \
    FM_FAKE_TMUX_FAIL_SEND_MATCH="${FM_FAKE_TMUX_FAIL_SEND_MATCH:-}" \
    FM_FAKE_TMUX_GATE_SEND_MATCH="${FM_FAKE_TMUX_GATE_SEND_MATCH:-}" \
    FM_FAKE_TMUX_GATE_SEND_MARKER="${FM_FAKE_TMUX_GATE_SEND_MARKER:-}" \
    FM_FAKE_TMUX_GATE_SEND_RELEASE="${FM_FAKE_TMUX_GATE_SEND_RELEASE:-}" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$CASE_DIR/checkout-refresh-state" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$CASE_DIR/checkout-refresh-locks" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
    FM_FAKE_AF_RESUME_ARM="$CASE_DIR/resume-arm" FM_FAKE_AF_SESSION_REFRESHED="$CASE_DIR/session-refreshed" \
    FM_FAKE_AF_RESUME_READY="$HOME_DIR/state/.$id.account-native-ready" FM_FAKE_AF_RESUME_GO="$HOME_DIR/state/.$id.account-native-go" \
    FM_FAKE_NATIVE_LAUNCH_LOG="$NATIVE_LAUNCH_LOG" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_ACCOUNT_SESSION_WAIT_SECONDS=0 \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" "$@" 2>&1
}

run_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$@"
}

run_send() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$SEND" "$@"
}

meta_account_task() {
  sed -n 's/^account_task=//p' "$HOME_DIR/state/$1.meta" | tail -1
}

logged_account_task() {
  sed -n 's/.*--task \([^ ]*\).*/\1/p' "$AF_LOG" | head -1
}

clear_case_logs() {
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
  : > "$LIFECYCLE_LOG"
  : > "$ORCA_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
  rm -f "$CASE_DIR/resume-arm" "$CASE_DIR/resume-arm.native-dir" "$CASE_DIR/session-refreshed"
}

use_named_fake_tmux_target() {
  local id=$1 meta="$HOME_DIR/state/$1.meta" staged
  staged=$(mktemp "$HOME_DIR/state/.named-target-$id.XXXXXX") || fail "could not stage fake tmux target metadata"
  grep -v '^tmux_window_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
}

test_off_is_byte_compatible_and_never_calls_agent_fleet() {
  local id rec out status launch expected
  id=account-off-z1
  rec=$(make_case off claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -eq 0 ] || fail "default-off spawn should succeed (exit $status): $out"
  [ ! -s "$AF_LOG" ] || fail "routing off invoked Agent Fleet: $(cat "$AF_LOG")"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "routing off changed the launch bytes"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "routing off wrote account metadata"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" "routing off wrote session metadata"
  assert_regex '^generation_id=spawn:a[0-9a-f]{15}$' "$HOME_DIR/state/$id.meta" "routing off did not record a stable spawn generation"
  assert_grep 'report_required=1' "$HOME_DIR/state/$id.meta" "post-cutover spawn did not activate the report gate"
  assert_grep '# Completion report' "$HOME_DIR/data/$id/brief.md" "post-cutover spawn did not upgrade a legacy unspawned brief"
  assert_grep "Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups" "$HOME_DIR/data/$id/brief.md" "upgraded brief omitted the completion-report sections"
  assert_contains "$out" "spawned $id" "default-off spawn did not complete"
  pass "routing off makes no Agent Fleet call and preserves launch/meta bytes"
}

test_failed_freshness_proof_rolls_back_unmanaged_resources() {
  local id rec out status default_branch
  id=checkout-freshness-rollback-z1a
  rec=$(make_case checkout-freshness-rollback claude "$id")
  read_case "$rec"
  default_branch=$(git -C "$PROJ_DIR" branch --show-current)
  printf '%s\n' upstream > "$PROJ_DIR/upstream.txt"
  git -C "$PROJ_DIR" add upstream.txt
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm upstream
  git -C "$PROJ_DIR" push -q -u origin "$default_branch"

  if out=$(run_spawn "$id" "$PROJ_DIR"); then
    status=0
  else
    status=$?
  fi

  [ "$status" -ne 0 ] || fail "stale acquired worktree passed the spawn freshness proof"
  assert_contains "$out" "acquired worktree is stale" \
    "failed freshness proof did not identify the stale acquired worktree"
  assert_not_grep '^new-window ' "$TMUX_LOG" \
    "failed unmanaged freshness proof created an endpoint before verification"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" \
    "failed unmanaged freshness proof force-returned an unverified acquired worktree"
  assert_contains "$out" "retained unsafe acquired worktree" \
    "failed unmanaged freshness proof did not surface retain-only cleanup"
  assert_absent "$CASE_DIR/endpoint-live" \
    "failed unmanaged freshness proof left its endpoint alive"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "failed unmanaged freshness proof published task metadata"
  pass "failed freshness proofs unwind endpoints and retain unverified worktrees"
}

test_local_only_spawn_uses_local_default_tip() {
  local id rec out status
  id=checkout-local-only-z1b
  rec=$(make_case checkout-local-only claude "$id")
  read_case "$rec"
  git -C "$PROJ_DIR" remote remove origin
  printf '%s\n' '- project [local-only] - local project (added 2026-07-23)' \
    > "$HOME_DIR/data/projects.md"

  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?

  [ "$status" -eq 0 ] || fail "remote-free local-only spawn failed its local freshness proof: $out"
  assert_contains "$out" "spawned $id" "remote-free local-only spawn did not complete"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" \
    "successful remote-free local-only spawn returned its acquired worktree"
  pass "remote-free local-only spawns prove the local default tip"
}

test_dirty_acquisition_is_retained_without_force_return() {
  local id rec draft out status
  id=checkout-dirty-retain-z1c
  rec=$(make_case checkout-dirty-retain claude "$id")
  read_case "$rec"
  draft="$WT_DIR/.agents/skills/unlanded/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# unlanded work' > "$draft"

  if out=$(run_spawn "$id" "$PROJ_DIR"); then
    status=0
  else
    status=$?
  fi

  [ "$status" -ne 0 ] || fail "spawn accepted a dirty acquired pool worktree"
  assert_contains "$out" "acquired worktree is dirty" \
    "dirty acquisition refusal did not identify the retained worktree"
  assert_contains "$out" "retained unsafe acquired worktree" \
    "dirty acquisition cleanup did not surface its retain-only action"
  assert_grep 'get --lease --lease-holder firstmate-checkout-dirty-retain-z1c' "$TREEHOUSE_LOG" \
    "dirty acquisition was not durably leased before verification"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" \
    "dirty acquisition was returned through the destructive Treehouse path"
  grep -Fq '# unlanded work' "$draft" || fail "dirty acquisition cleanup changed its draft"
  assert_absent "$CASE_DIR/endpoint-live" \
    "dirty acquisition refusal left its prepared endpoint alive"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "dirty acquisition refusal published task metadata"
  pass "dirty pool acquisitions are diagnosed and retained untouched"
}

test_treehouse_acquisition_timeout_is_bounded_before_endpoint_creation() {
  local id rec out status
  id=checkout-acquire-timeout-z1f
  rec=$(make_case checkout-acquire-timeout claude "$id")
  read_case "$rec"

  if out=$(FM_FAKE_TREEHOUSE_SLEEP=3 FM_TREEHOUSE_ACQUIRE_TIMEOUT=1 run_spawn "$id" "$PROJ_DIR"); then
    status=0
  else
    status=$?
  fi

  [ "$status" -ne 0 ] || fail "hung Treehouse acquisition unexpectedly completed"
  assert_contains "$out" "Treehouse worktree acquisition timed out after 1s" \
    "bounded Treehouse acquisition did not surface its distinct timeout"
  assert_not_grep '^new-window ' "$TMUX_LOG" \
    "timed-out Treehouse acquisition created an endpoint"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" \
    "timed-out Treehouse acquisition returned a path it never acquired"
  pass "Treehouse acquisition is process-tree bounded before endpoint creation"
}

test_changed_acquisition_is_retained_during_unmanaged_rollback() {
  local id rec marker release out_file spawn_pid
  id=checkout-changed-rollback-z1g
  rec=$(make_case checkout-changed-rollback pi "$id")
  read_case "$rec"
  marker="$CASE_DIR/gotmp-send-started"
  release="$CASE_DIR/gotmp-send-release"
  out_file="$CASE_DIR/spawn.out"

  FM_FAKE_TMUX_GATE_SEND_MATCH=GOTMPDIR \
    FM_FAKE_TMUX_GATE_SEND_MARKER="$marker" \
    FM_FAKE_TMUX_GATE_SEND_RELEASE="$release" \
    FM_FAKE_TMUX_FAIL_SEND_MATCH=GOTMPDIR \
    run_spawn "$id" "$PROJ_DIR" > "$out_file" &
  spawn_pid=$!
  for _ in $(seq 1 100); do [ -f "$marker" ] && break; sleep 0.05; done
  [ -f "$marker" ] \
    || { kill "$spawn_pid" 2>/dev/null || true; fail "changed-acquisition test never reached the post-install failure"; }
  printf '%s\n' retained-commit > "$WT_DIR/retained-commit.txt"
  git -C "$WT_DIR" add retained-commit.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm retained-commit
  touch "$release"
  if wait "$spawn_pid"; then
    fail "changed-acquisition rollback unexpectedly succeeded"
  fi

  assert_not_grep 'return --force' "$TREEHOUSE_LOG" \
    "rollback force-returned an acquired worktree whose detached tip changed"
  assert_grep 'retained-commit' "$WT_DIR/retained-commit.txt" \
    "rollback changed work committed after acquisition"
  assert_grep 'expected detached tip' "$out_file" \
    "rollback did not diagnose the changed acquired tip"
  pass "unmanaged rollback retains acquisitions whose detached tip changed"
}

test_unmanaged_postinstall_failure_restores_prior_state() {
  local id rec expected out status artifact common key expected_lock lock_marker
  id=checkout-unmanaged-restore-z1d
  rec=$(make_case checkout-unmanaged-restore pi "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=pi" \
    "kind=ship" \
    "mode=no-mistakes" \
    "custom_extension=retain-me"
  expected="$CASE_DIR/original.meta"
  common=$(git -C "$WT_DIR" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$WT_DIR/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  expected_lock="$CASE_DIR/checkout-refresh-locks/$key.lock"
  lock_marker="$CASE_DIR/checkout-return-held-lock"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'prior-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done

  if out=$(FM_EXPECT_CHECKOUT_LOCK="$expected_lock" \
      FM_EXPECT_CHECKOUT_LOCK_MARKER="$lock_marker" \
      FM_FAKE_TMUX_FAIL_SEND_MATCH=GOTMPDIR run_spawn "$id" "$PROJ_DIR"); then
    status=0
  else
    status=$?
  fi

  [ "$status" -ne 0 ] || fail "post-metadata unmanaged launch failure unexpectedly succeeded"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" \
    || fail "post-metadata unmanaged failure did not restore prior metadata"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "prior-$artifact" ] \
      || fail "post-metadata unmanaged failure did not restore prior $artifact state"
  done
  assert_absent "$CASE_DIR/endpoint-live" \
    "post-metadata unmanaged failure left its endpoint alive"
  assert_grep "return --force $WT_DIR" "$TREEHOUSE_LOG" \
    "post-metadata unmanaged failure did not return its clean worktree"
  assert_present "$lock_marker" \
    "spawn rollback did not hold the common checkout lock during Treehouse return"
  [ -n "$out" ] || true
  pass "unmanaged post-install failures restore prior lifecycle state transactionally"
}

test_spawn_rollback_relays_unverified_treehouse_cleanup() {
  local id rec out status real_ps common key lock group owner child_pid
  id=checkout-unverified-return-z1h
  rec=$(make_case checkout-unverified-return pi "$id")
  read_case "$rec"
  real_ps=$(command -v ps)
  cat > "$FAKEBIN_DIR/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "${FM_FAKE_TREEHOUSE_RETURN_MARKER:-/nonexistent}" ] \
  && [ "$*" = "-axo pid=,pgid=" ]; then
  exit 1
fi
exec "${FM_TEST_REAL_PS:?}" "$@"
SH
  chmod +x "$FAKEBIN_DIR/ps"

  if out=$(FM_TEST_REAL_PS="$real_ps" \
      FM_FAKE_TREEHOUSE_RETURN_CHILD_PID_FILE="$CASE_DIR/treehouse-return-child.pid" \
      FM_FAKE_TREEHOUSE_RETURN_MARKER="$CASE_DIR/treehouse-return-started" \
      FM_FAKE_TMUX_FAIL_SEND_MATCH=GOTMPDIR run_spawn "$id" "$PROJ_DIR"); then
    status=0
  else
    status=$?
  fi

  [ "$status" -ne 0 ] || fail "spawn with unverified rollback cleanup unexpectedly succeeded"
  common=$(git -C "$WT_DIR" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$WT_DIR/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  lock="$CASE_DIR/checkout-refresh-locks/$key.lock"
  assert_present "$CASE_DIR/treehouse-return-child.pid" \
    "spawn rollback did not exercise a surviving Treehouse descendant"
  assert_present "$lock" "spawn rollback released an unverified checkout lock"
  assert_present "$lock/process-group" "spawn rollback lost the guarded process-group identity"
  assert_contains "$out" "bounded command process cleanup could not be verified for anchored group" \
    "spawn rollback suppressed the bounded supervisor diagnostic"
  assert_contains "$out" "Treehouse return process cleanup could not be verified" \
    "spawn rollback suppressed the locked-return cleanup diagnostic"
  assert_contains "$out" "retained rollback worktree $WT_DIR" \
    "spawn rollback did not provide actionable retain-only recovery guidance"
  group=$(cat "$lock/process-group")
  child_pid=$(cat "$CASE_DIR/treehouse-return-child.pid")
  kill -0 "$child_pid" 2>/dev/null \
    || fail "unverified Treehouse descendant exited before retention could be inspected"
  owner=$(readlink "$lock")
  kill -KILL -- "-$group" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$group" 2>/dev/null || break
    sleep 0.02
  done
  ! kill -0 "$group" 2>/dev/null || fail "test cleanup could not terminate retained anchored group $group"
  rm -f "$lock"
  rm -rf "$owner"
  pass "spawn rollback relays unverified cleanup and retains guarded resources"
}

test_unmanaged_rollback_waits_for_metadata_lock() {
  local id rec marker release out_file spawn_pid held
  id=checkout-unmanaged-rollback-lock-z1e
  rec=$(make_case checkout-unmanaged-rollback-lock pi "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=pi" \
    "kind=ship" \
    "mode=no-mistakes" \
    "custom_extension=retain-me"
  marker="$CASE_DIR/gotmp-send-started"
  release="$CASE_DIR/gotmp-send-release"
  out_file="$CASE_DIR/spawn.out"

  FM_FAKE_TMUX_GATE_SEND_MATCH=GOTMPDIR \
    FM_FAKE_TMUX_GATE_SEND_MARKER="$marker" \
    FM_FAKE_TMUX_GATE_SEND_RELEASE="$release" \
    FM_FAKE_TMUX_FAIL_SEND_MATCH=GOTMPDIR \
    run_spawn "$id" "$PROJ_DIR" > "$out_file" &
  spawn_pid=$!
  for _ in $(seq 1 100); do [ -f "$marker" ] && break; sleep 0.05; done
  [ -f "$marker" ] \
    || { kill "$spawn_pid" 2>/dev/null || true; fail "unmanaged rollback-lock test never reached the post-install failure"; }
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_meta_lock_acquire "$HOME_DIR/state" "$id") \
    || { kill "$spawn_pid" 2>/dev/null || true; fail "unmanaged rollback-lock test could not acquire the writer lock"; }
  touch "$release"
  sleep 0.1
  printf '%s\n' 'x_request=req-concurrent-rollback' >> "$HOME_DIR/state/$id.meta"
  fm_account_meta_lock_release "$held" \
    || { kill "$spawn_pid" 2>/dev/null || true; fail "unmanaged rollback-lock test could not release the writer lock"; }
  if wait "$spawn_pid"; then
    fail "unmanaged rollback-lock failure unexpectedly succeeded"
  fi
  assert_grep 'custom_extension=retain-me' "$HOME_DIR/state/$id.meta" \
    "unmanaged rollback lost the prior metadata generation"
  assert_grep 'x_request=req-concurrent-rollback' "$HOME_DIR/state/$id.meta" \
    "unmanaged rollback discarded an extension written under the metadata lock"
  pass "unmanaged rollback serializes generation restoration with metadata writers"
}

test_completion_contract_upgrade_is_contained_nonfollowing_and_atomic() {
  local id rec brief before after outside out status heading_count real_node hook raced_size
  local ready proceed original_task swapped_task spawn_pid spawn_rc

  id=contract-atomic-z1b
  rec=$(make_case contract-atomic claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  before=$(stat -f '%d:%i' "$brief" 2>/dev/null || stat -c '%d:%i' "$brief")
  run_spawn "$id" "$PROJ_DIR" >/dev/null || fail "normal completion-contract upgrade failed"
  after=$(stat -f '%d:%i' "$brief" 2>/dev/null || stat -c '%d:%i' "$brief")
  [ "$before" != "$after" ] || fail "completion-contract upgrade modified the brief in place instead of replacing it atomically"
  assert_grep '# Completion report' "$brief" "atomic completion-contract upgrade omitted the contract"
  if find "$(dirname "$brief")" -maxdepth 1 -name '.brief-contract.*' -print -quit | grep -q .; then
    fail "completion-contract upgrade leaked its staging file"
  fi

  id=contract-fenced-example-z1ba
  rec=$(make_case contract-fenced-example claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task

Preserve this custom brief.

````markdown
# Completion report
```
Example only.
```
````
EOF
  run_spawn "$id" "$PROJ_DIR" >/dev/null || fail "fenced completion-report example blocked contract injection"
  heading_count=$(grep -c '^# Completion report$' "$brief")
  [ "$heading_count" -eq 2 ] || fail "fenced completion-report example suppressed the real contract"

  id=contract-list-fenced-example-z1bb
  rec=$(make_case contract-list-fenced-example claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task

Preserve this custom brief.

- ```markdown
  # Completion report
  Example only.
  ```
EOF
  run_spawn "$id" "$PROJ_DIR" >/dev/null || fail "list-fenced completion-report example blocked contract injection"
  heading_count=$(grep -c '^# Completion report$' "$brief")
  [ "$heading_count" -eq 1 ] || fail "list-fenced completion-report example suppressed the real contract"

  id=contract-file-symlink-z1c
  rec=$(make_case contract-file-symlink claude "$id")
  read_case "$rec"
  outside="$CASE_DIR/outside-brief"
  printf 'outside sentinel\n' > "$outside"
  rm "$HOME_DIR/data/$id/brief.md"
  ln -s "$outside" "$HOME_DIR/data/$id/brief.md"
  if out=$(run_spawn "$id" "$PROJ_DIR"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "symlinked task brief unexpectedly accepted a completion-contract write"
  [ "$(cat "$outside")" = 'outside sentinel' ] || fail "completion-contract write followed a task brief symlink"
  assert_contains "$out" "task brief must be a real regular file inside" "brief symlink refusal was not actionable"

  id=contract-parent-symlink-z1d
  rec=$(make_case contract-parent-symlink claude "$id")
  read_case "$rec"
  outside="$CASE_DIR/outside-task"
  mkdir -p "$outside"
  printf 'outside parent sentinel\n' > "$outside/brief.md"
  rm -rf "$HOME_DIR/data/$id"
  ln -s "$outside" "$HOME_DIR/data/$id"
  if out=$(run_spawn "$id" "$PROJ_DIR"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "task-directory symlink unexpectedly accepted a completion-contract write"
  [ "$(cat "$outside/brief.md")" = 'outside parent sentinel' ] || fail "completion-contract write escaped through the task directory"
  assert_contains "$out" "task directory must resolve directly inside" "task-directory containment refusal was not actionable"

  id=contract-open-race-z1e
  rec=$(make_case contract-open-race claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  outside="$CASE_DIR/outside-open-race"
  printf 'outside open-race sentinel\n' > "$outside"
  real_node=$(command -v node)
  cat > "$FAKEBIN_DIR/node" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = - ] && [ "${2:-}" = ensure ]; then
  rm -f -- "$FM_TEST_SWAP_BRIEF"
  ln -s "$FM_TEST_SWAP_TARGET" "$FM_TEST_SWAP_BRIEF"
fi
exec "$FM_TEST_REAL_NODE" "$@"
SH
  chmod +x "$FAKEBIN_DIR/node"
  export FM_TEST_REAL_NODE="$real_node" FM_TEST_SWAP_BRIEF="$brief" FM_TEST_SWAP_TARGET="$outside"
  if out=$(run_spawn "$id" "$PROJ_DIR"); then status=0; else status=$?; fi
  unset FM_TEST_REAL_NODE FM_TEST_SWAP_BRIEF FM_TEST_SWAP_TARGET
  [ "$status" -ne 0 ] || fail "brief symlink swap before descriptor open unexpectedly succeeded"
  [ "$(cat "$outside")" = 'outside open-race sentinel' ] || fail "descriptor open followed a raced brief symlink"

  id=contract-parent-race-z1ea
  rec=$(make_case contract-parent-race claude "$id")
  read_case "$rec"
  original_task="$HOME_DIR/data/$id"
  swapped_task="$CASE_DIR/pinned-original-task"
  outside="$CASE_DIR/outside-parent-race"
  ready="$CASE_DIR/brief-parent-ready"
  proceed="$CASE_DIR/brief-parent-proceed"
  mkdir -p "$outside"
  printf 'outside parent-race sentinel\n' > "$outside/brief.md"
  FM_FILE_TRANSACTION_TEST_READY="$ready" FM_FILE_TRANSACTION_TEST_PROCEED="$proceed" \
    run_spawn "$id" "$PROJ_DIR" > "$CASE_DIR/parent-race.out" 2>&1 &
  spawn_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  if [ ! -e "$ready" ]; then
    kill "$spawn_pid" 2>/dev/null || true
    wait "$spawn_pid" 2>/dev/null || true
    fail "completion-contract transaction never pinned its task directory"
  fi
  mv "$original_task" "$swapped_task"
  ln -s "$outside" "$original_task"
  : > "$proceed"
  set +e
  wait "$spawn_pid"
  spawn_rc=$?
  set -e
  [ "$spawn_rc" -ne 0 ] || fail "completion-contract transaction accepted a replaced task parent"
  [ "$(cat "$outside/brief.md")" = 'outside parent-race sentinel' ] \
    || fail "completion-contract transaction wrote through a raced task parent"
  assert_no_grep '# Completion report' "$swapped_task/brief.md" \
    "failed parent-race transaction changed the pinned original brief"

  id=contract-content-race-z1f
  rec=$(make_case contract-content-race claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  raced_size=$(wc -c < "$brief" | tr -d ' ')
  hook="$CASE_DIR/mutate-after-read.cjs"
  cat > "$hook" <<'JS'
const fs = require('fs');
const original = fs.readFileSync;
let mutated = false;
fs.readFileSync = function (...args) {
  const content = original.apply(this, args);
  if (!mutated && typeof args[0] === 'number') {
    mutated = true;
    const target = process.env.FM_TEST_MUTATE_BRIEF;
    const stat = fs.statSync(target);
    const prefix = Buffer.from('# Concurrent replacement\n');
    const replacement = Buffer.alloc(Number(process.env.FM_TEST_MUTATE_SIZE), 120);
    prefix.copy(replacement);
    fs.writeFileSync(target, replacement);
    fs.utimesSync(target, stat.atime, stat.mtime);
  }
  return content;
};
JS
  export NODE_OPTIONS="--require=$hook" FM_TEST_MUTATE_BRIEF="$brief" FM_TEST_MUTATE_SIZE="$raced_size"
  if out=$(run_spawn "$id" "$PROJ_DIR"); then status=0; else status=$?; fi
  unset NODE_OPTIONS FM_TEST_MUTATE_BRIEF FM_TEST_MUTATE_SIZE
  [ "$status" -ne 0 ] || fail "same-size same-second brief edit during descriptor copy unexpectedly succeeded"
  assert_grep '# Concurrent replacement' "$brief" "failed brief upgrade overwrote the concurrent edit"
  assert_no_grep '# Completion report' "$brief" "failed brief upgrade installed the contract over a concurrent edit"
  pass "completion-contract upgrades are contained, non-following, and atomic"
}

test_completion_contract_ignores_raw_html_headings() {
  local id rec brief heading_count
  id=contract-html-comment-example-z1bc
  rec=$(make_case contract-html-comment-example claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task

<!--
# Completion report
-->
EOF
  run_spawn "$id" "$PROJ_DIR" >/dev/null || fail "commented completion-report example blocked contract injection"
  heading_count=$(grep -c '^# Completion report$' "$brief")
  [ "$heading_count" -eq 2 ] || fail "commented completion-report example suppressed the real contract"

  id=contract-html-block-example-z1bd
  rec=$(make_case contract-html-block-example claude "$id")
  read_case "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task

<div>
# Completion report
</div>

Continue.
EOF
  run_spawn "$id" "$PROJ_DIR" >/dev/null || fail "raw HTML completion-report example blocked contract injection"
  heading_count=$(grep -c '^# Completion report$' "$brief")
  [ "$heading_count" -eq 2 ] || fail "raw HTML completion-report example suppressed the real contract"
  pass "completion-contract injection ignores raw HTML headings"
}

test_observe_is_dry_run_only() {
  local id rec out status launch
  id=account-observe-z2
  rec=$(make_case observe claude "$id")
  read_case "$rec"
  out=$(FM_ACCOUNT_ROUTING=observe run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "observe spawn should preserve legacy launch"
  assert_regex "choose --pool claude-crew --task fm-[0-9a-f]+-account-observe-z2-a[0-9a-f]+ --provider claude --workspace $WT_DIR --dry-run" "$AF_LOG" "observe did not use the task worktree for its namespaced dry-run choice"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "observe created a lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ' claude --dangerously-skip-permissions ' "observe changed the provider command"
  assert_not_contains "$launch" 'agent-fleet' "observe wrapped the provider launch"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "observe wrote account metadata"
  assert_contains "$out" 'observe pool=claude-crew provider=claude profile=claude-2' "observe did not surface its non-secret shadow choice"
  pass "observe performs only a dry run and leaves launch/meta unchanged"
}

test_enforce_pool_wraps_backend_and_records_real_session() {
  local id rec out status launch meta account_task account_attempt af_bin
  id=account-enforce-z3
  rec=$(make_case enforce claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  expect_code 0 "$status" "explicit pool spawn should enforce routing"
  account_task=$(meta_account_task "$id")
  account_attempt=$(sed -n 's/^account_attempt=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  af_bin="$(cd "$FAKEBIN_DIR" && pwd -P)/agent-fleet"
  assert_grep "lease choose --pool claude-crew --task $account_task --provider claude" "$AF_LOG" "enforce did not atomically choose a namespaced lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$af_bin' --format json exec --profile 'claude-2' --task '$account_task' --pool 'claude-crew' --workspace '$WT_DIR'" "enforce did not build the task-worktree-bound Agent Fleet wrapper"
  assert_contains "$launch" "-- --dangerously-skip-permissions" "enforce did not preserve provider arguments after the Agent Fleet wrapper"
  meta="$HOME_DIR/state/$id.meta"
  grep -q '^account_pool=' "$meta" || fail "meta missing account pool; contents: $(tr '\n' '|' < "$meta")"
  assert_grep 'account_pool=claude-crew' "$meta" "meta missing account pool"
  assert_grep 'account_profile=claude-2' "$meta" "meta missing selected profile"
  assert_grep "account_task=$account_task" "$meta" "meta missing namespaced Agent Fleet task"
  assert_grep "generation_id=account:$account_task:$account_attempt" "$meta" "managed meta did not bind the report generation to its account attempt"
  assert_grep "provider_session_id=sess-$account_task" "$meta" "meta missing real provider session id"
  assert_contains "$out" "spawned $id" "enforced spawn did not complete"
  pass "enforce leases before spawn, wraps any backend launch, and records the real session id"
}

test_explicit_profile_uses_explicit_pool() {
  local id rec out status account_task
  id=account-profile-z4
  rec=$(make_case profile claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_POOL=explicit FM_FAKE_AF_PROFILE=claude-3 run_spawn "$id" "$PROJ_DIR" --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "explicit profile spawn should succeed: $out"
  account_task=$(meta_account_task "$id")
  assert_grep "lease acquire --profile claude-3 --task $account_task --pool explicit" "$AF_LOG" "explicit profile did not use explicit acquire"
  assert_grep 'account_pool=explicit' "$HOME_DIR/state/$id.meta" "explicit profile meta missing explicit pool"
  assert_grep 'account_profile=claude-3' "$HOME_DIR/state/$id.meta" "explicit profile meta mismatch"
  pass "an explicit profile is acquired and persisted without a silent default account"
}

test_enforce_failure_rolls_back_prepared_endpoint() {
  local id rec out status
  id=account-select-fail-z5
  rec=$(make_case select-fail claude "$id")
  read_case "$rec"
  if out=$(FM_FAKE_AF_BAD_SELECTION=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "failed Agent Fleet selection should block spawn"
  assert_regex '^new-window ' "$TMUX_LOG" "selection did not happen after endpoint preparation"
  assert_regex '^kill-window ' "$TMUX_LOG" "selection failure did not remove its prepared endpoint"
  assert_grep 'return --force' "$TREEHOUSE_LOG" \
    "selection failure did not return its prepared worktree (spawn: $out; lifecycle: $(tr '\n' '|' < "$LIFECYCLE_LOG"))"
  assert_absent "$HOME_DIR/state/$id.meta" "selection failure wrote task meta"
  [ -n "$out" ] || true
  pass "enforce reserves immediately before binding and rolls back prepared runtime state"
}

test_pane_failure_happens_before_account_reservation() {
  local id rec out status
  id=account-pane-fail-z6
  rec=$(make_case pane-fail claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_TMUX_FAIL_LABEL="fm-$id" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "pane creation failure should fail spawn"
  [ ! -s "$AF_LOG" ] || fail "pane failure touched Agent Fleet before endpoint preparation completed: $(cat "$AF_LOG")"
  assert_absent "$HOME_DIR/state/$id.meta" "pane failure left task meta"
  [ -n "$out" ] || true
  pass "endpoint preparation failures happen before any Agent Fleet reservation"
}

test_batch_partial_failure_releases_only_failed_item() {
  local id1 id2 rec out status
  id1=account-batch-ok-z7
  id2=account-batch-fail-z8
  rec=$(make_case batch claude "$id1" "$id2")
  read_case "$rec"
  out=$(FM_FAKE_TMUX_FAIL_LABEL="fm-$id2" run_spawn "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "partial batch failure should exit non-zero"
  assert_regex "lease choose --pool claude-crew --task .*-$id1-" "$AF_LOG" "batch first item was not leased"
  assert_not_grep "lease choose --pool claude-crew --task .*-$id2-" "$AF_LOG" "failed batch item reserved before endpoint preparation"
  assert_not_grep 'lease release' "$AF_LOG" "batch pane failure released another task's lease"
  assert_present "$HOME_DIR/state/$id1.meta" "successful batch item lost its meta"
  assert_absent "$HOME_DIR/state/$id2.meta" "failed batch item left meta"
  assert_contains "$out" "batch: FAILED to spawn $id2" "partial batch failure was not reported"
  pass "partial batch failure retains launched leases and releases every unconsumed reservation"
}

test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure() {
  local id rec status launch before_session out account_task
  id=account-resume-z9
  rec=$(make_case resume claude "$id")
  read_case "$rec"
  FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null
  status=$?
  expect_code 0 "$status" "initial managed spawn for resume should succeed"
  assert_grep 'report_required=1' "$HOME_DIR/state/$id.meta" "fresh spawn did not require a completion report"
  before_session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  account_task=$(meta_account_task "$id")
  grep -v '^report_required=' "$HOME_DIR/state/$id.meta" > "$HOME_DIR/state/$id.meta.precutover"
  mv "$HOME_DIR/state/$id.meta.precutover" "$HOME_DIR/state/$id.meta"
  rm -f "$CASE_DIR/endpoint-live"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -eq 0 ] || fail "managed resume should succeed (exit $status): $out"
  assert_grep "lease recover --task $account_task" "$AF_LOG" "resume used new-task selection instead of sticky recovery reservation"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "resume ran the new-task quota path"
  launch=$(cat "$LAUNCH_LOG" "$NATIVE_LAUNCH_LOG")
  assert_contains "$launch" "--format json resume --task '$account_task' --workspace '$WT_DIR'" "resume did not use Agent Fleet's fail-closed task and worktree mapping"
  assert_contains "$launch" "-- \"\$@\"" "resume did not preserve provider arguments after the Agent Fleet wrapper"
  assert_contains "$launch" "account-native-launch' --dangerously-skip-permissions" "resume did not pass provider arguments through its launch gate"
  assert_contains "$launch" "#!$ROOT/bin/fm-herdr-worker-shell" "native resume did not scrub inherited startup state before Bash"
  assert_not_contains "$launch" '#!/bin/bash' "native resume reintroduced an unsanitized Bash shebang"
  assert_not_contains "$launch" 'cat ' "resume started a fresh prompted conversation"
  [ "$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)" = "$before_session" ] || fail "resume changed provider session identity"
  assert_not_grep '^report_required=' "$HOME_DIR/state/$id.meta" "pre-cutover recovery silently activated the report gate"

  : > "$AF_LOG"
  : > "$TMUX_LOG"
  rm -f "$CASE_DIR/endpoint-live"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_POOL=claude-crew run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "resume without a session mapping should fail closed"
  assert_not_grep '^new-window ' "$TMUX_LOG" "missing session mapping still created an endpoint"
  assert_not_grep 'session remove' "$AF_LOG" "failed resume removed the durable session mapping"
  assert_contains "$out" 'no Agent Fleet provider-session mapping' "missing mapping blocker was not explicit"
  pass "resume uses below-reserve sticky recovery and never deletes mapping on a failed attempt"
}

test_recovered_secondmate_kind_blocks_unsupported_cmux_backend_early() {
  local id rec meta replacement out status
  id=acct-cmux-sm-z9b
  rec=$(make_case recovered-cmux-secondmate claude "$id")
  read_case "$rec"
  mkdir -p "$CASE_DIR/treehouse-pools"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -eq 0 ] || fail "recovered cmux secondmate precondition spawn failed: $out"
  meta="$HOME_DIR/state/$id.meta"
  replacement="$meta.replacement"
  sed 's/^kind=.*/kind=secondmate/;/^backend=/d' "$meta" > "$replacement"
  printf 'backend=cmux\n' >> "$replacement"
  mv "$replacement" "$meta"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "metadata-recovered cmux secondmate launched"
  assert_contains "$out" "backend=cmux does not support --secondmate spawns yet" \
    "metadata-recovered secondmate missed the cmux backend guard"
  assert_not_grep 'lease recover\|lease choose\|lease acquire' "$AF_LOG" \
    "unsupported recovered secondmate reached account mutation"
  assert_not_grep '^new-window ' "$TMUX_LOG" \
    "unsupported recovered secondmate created an endpoint"
  pass "metadata kind recovery precedes unsupported secondmate backend checks"
}

test_managed_recovery_accepts_inherited_lifecycle_lock() {
  local id rec out status held account_task
  id=account-inherited-recovery-z9d
  rec=$(make_case inherited-recovery claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "inherited-lock recovery precondition spawn failed"
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$HOME_DIR/state" "$id") \
    || fail "inherited-lock recovery could not acquire the bootstrap-owned lock"
  out=$(FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$held" run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -eq 0 ] || fail "managed recovery rejected its inherited lifecycle lock: $out"
  assert_absent "$held" "successful inherited recovery did not release its handed-off lifecycle lock"
  assert_grep "account_task=$account_task" "$HOME_DIR/state/$id.meta" \
    "inherited-lock recovery did not complete metadata installation"
  assert_not_grep '^account_rollback_cleanup=' "$HOME_DIR/state/$id.meta" \
    "inherited-lock recovery did not commit its managed generation"
  pass "managed secondmate-style recovery installs metadata under its inherited lifecycle lock"
}

test_inherited_lifecycle_handoff_releases_on_child_abort() {
  local id rec held out status
  id=account-inherited-handoff-abort-z9h
  rec=$(make_case inherited-handoff-abort claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "inherited handoff abort precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$HOME_DIR/state" "$id") \
    || fail "inherited handoff abort test could not acquire the parent lock"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$held" run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "inherited handoff abort test unexpectedly resumed"
  assert_absent "$held" "aborting spawn did not trap-release its handed-off lifecycle lock"
  assert_contains "$out" "no Agent Fleet provider-session mapping" \
    "inherited handoff abort did not reach the expected post-handoff refusal"
  pass "inherited lifecycle ownership transfers to the child and trap-releases on abort"
}

test_off_metadata_merge_waits_for_metadata_lock() {
  local id rec marker gate out_file spawn_pid held
  id=account-off-meta-lock-z9i
  rec=$(make_case off-meta-lock claude "$id")
  read_case "$rec"
  marker="$CASE_DIR/new-window-started"
  gate="$CASE_DIR/new-window-go"
  out_file="$CASE_DIR/spawn.out"
  FM_FAKE_TMUX_NEW_WINDOW_MARKER="$marker" FM_FAKE_TMUX_NEW_WINDOW_GATE="$gate" \
    run_spawn "$id" "$PROJ_DIR" > "$out_file" &
  spawn_pid=$!
  for _ in $(seq 1 100); do [ -f "$marker" ] && break; sleep 0.05; done
  [ -f "$marker" ] || { kill "$spawn_pid" 2>/dev/null || true; fail "off metadata-lock test never reached endpoint creation"; }
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_meta_lock_acquire "$HOME_DIR/state" "$id") \
    || { kill "$spawn_pid" 2>/dev/null || true; fail "off metadata-lock test could not acquire the competing writer lock"; }
  touch "$gate"
  sleep 0.1
  fm_write_meta "$HOME_DIR/state/$id.meta" "x_request=req-concurrent-off"
  fm_account_meta_lock_release "$held" || fail "off metadata-lock test could not release the competing writer lock"
  wait "$spawn_pid" || fail "off spawn failed after serialized metadata rewrite: $(cat "$out_file")"
  assert_grep 'x_request=req-concurrent-off' "$HOME_DIR/state/$id.meta" \
    "off-mode spawn discarded a metadata extension written under the metadata lock"
  pass "off-mode metadata merge-and-replace serializes with extension writers"
}

test_inherited_lifecycle_lock_rejects_owner_aba() {
  local id sync_id rec held owner original replacement_pid replacement_start out status meta_tmp
  id=account-inherited-aba-z9f
  sync_id=account-sync-aba-z9g
  rec=$(make_case inherited-aba claude "$id" "$sync_id")
  read_case "$rec"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$HOME_DIR/state" "$id") \
    || fail "inherited-lock ABA test could not acquire the parent lock"
  owner=$held
  [ ! -d "$held" ] || owner="$held/owner"
  original=$(fm_account_lifecycle_lock_identity "$held") \
    || fail "inherited-lock ABA test could not read the parent identity"
  sleep 30 &
  replacement_pid=$!
  replacement_start=$(fm_account_process_start_time "$replacement_pid") \
    || { kill "$replacement_pid" 2>/dev/null || true; fail "inherited-lock ABA test could not read the replacement identity"; }

  out=$(FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$held" \
    FM_FAKE_AF_REPLACE_LOCK_OWNER_FILE="$owner" \
    FM_FAKE_AF_REPLACE_LOCK_OWNER_PID="$replacement_pid" \
    FM_FAKE_AF_REPLACE_LOCK_OWNER_START="$replacement_start" \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  printf '%s\n' "$original" > "$owner"
  fm_account_lifecycle_lock_release "$held" \
    || fail "inherited-lock ABA test could not release the restored parent lock"
  kill "$replacement_pid" 2>/dev/null || true
  wait "$replacement_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "spawn accepted a lifecycle lock reclaimed by another live owner"
  assert_contains "$out" 'managed lifecycle lock was lost before metadata install' \
    "spawn did not use the lost-lock failure path after inherited-lock ABA"
  assert_absent "$CASE_DIR/endpoint-live" "lost inherited lock left a prepared endpoint alive"

  run_spawn "$sync_id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "session-sync ABA precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$sync_id.meta.aba"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$sync_id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$sync_id.meta"
  held=$(fm_account_lifecycle_lock_acquire "$HOME_DIR/state" "$sync_id") \
    || fail "session-sync ABA test could not acquire the parent lock"
  owner=$held
  [ ! -d "$held" ] || owner="$held/owner"
  original=$(fm_account_lifecycle_lock_identity "$held") \
    || fail "session-sync ABA test could not read the parent identity"
  sleep 30 &
  replacement_pid=$!
  replacement_start=$(fm_account_process_start_time "$replacement_pid") \
    || { kill "$replacement_pid" 2>/dev/null || true; fail "session-sync ABA test could not read the replacement identity"; }
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_FILE="$owner" \
    FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_PID="$replacement_pid" \
    FM_FAKE_AF_SESSION_REPLACE_LOCK_OWNER_START="$replacement_start" \
    FM_ACCOUNT_LIFECYCLE_LOCK_HELD="$held" PATH="$FAKEBIN_DIR:$PATH" \
    "$SESSION_SYNC" "$sync_id" --require 2>&1)
  status=$?
  printf '%s\n' "$original" > "$owner"
  fm_account_lifecycle_lock_release "$held" \
    || fail "session-sync ABA test could not release the restored parent lock"
  kill "$replacement_pid" 2>/dev/null || true
  wait "$replacement_pid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "session sync accepted a lifecycle lock reclaimed by another live owner"
  assert_contains "$out" 'managed lifecycle lock was lost before session synchronization' \
    "session sync did not fail closed after inherited-lock ABA"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$sync_id.meta" \
    "session sync published metadata after inherited-lock ABA"
  pass "inherited lifecycle locks remain pinned to one live owner identity"
}

test_unmanaged_spawn_refuses_while_teardown_lifecycle_is_held() {
  local id rec held out status
  id=account-unmanaged-lifecycle-z9e
  rec=$(make_case unmanaged-lifecycle claude "$id")
  read_case "$rec"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  held=$(fm_account_lifecycle_lock_acquire "$HOME_DIR/state" "$id") \
    || fail "unmanaged lifecycle test could not model teardown's held lifecycle lock"
  out=$(FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 run_spawn "$id" "$PROJ_DIR")
  status=$?
  fm_account_lifecycle_lock_release "$held" \
    || fail "unmanaged lifecycle test could not release its blocker lock"
  [ "$status" -ne 0 ] || fail "default-off spawn bypassed a held task lifecycle lock"
  assert_contains "$out" "timed out waiting for account lifecycle lock for $id" \
    "default-off lifecycle-lock refusal was not actionable"
  assert_absent "$HOME_DIR/state/$id.meta" "refused default-off spawn installed metadata"
  assert_absent "$CASE_DIR/endpoint-live" "refused default-off spawn created an endpoint"
  pass "default-off spawns refuse while teardown's lifecycle lock is held"
}

test_unmanaged_respawn_preserves_report_cutover_state() {
  local id rec out status
  id=account-legacy-respawn-z9b
  rec=$(make_case legacy-respawn claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=418" \
    "x_request=req-legacy" \
    "custom_extension=preserve-success"
  out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -eq 0 ] || fail "pre-cutover unmanaged respawn should succeed (exit $status): $out"
  assert_not_grep '^report_required=' "$HOME_DIR/state/$id.meta" "pre-cutover unmanaged respawn silently activated the report gate"
  assert_grep 'pr=418' "$HOME_DIR/state/$id.meta" "managed respawn dropped the existing PR pointer"
  assert_grep 'x_request=req-legacy' "$HOME_DIR/state/$id.meta" "managed respawn dropped the existing X-mode link"
  assert_grep 'custom_extension=preserve-success' "$HOME_DIR/state/$id.meta" "managed respawn dropped extension metadata"
  pass "unmanaged respawn preserves a legacy task's report cutover state"
}

test_failed_managed_respawn_restores_unmanaged_metadata() {
  local id rec expected out status artifact
  id=account-unmanaged-rollback-z9c
  rec=$(make_case unmanaged-rollback claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=417" \
    "custom_extension=preserve-me"
  expected="$CASE_DIR/original.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'prior-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done
  out=$(FM_FAKE_AF_SESSION_MISSING=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "managed respawn without a session mapping unexpectedly succeeded"
  if ! cmp -s "$HOME_DIR/state/$id.meta" "$expected"; then
    printf '%s\n' "$out" >&2
    sed 's/^/agent-fleet: /' "$AF_LOG" >&2
    diff -u "$expected" "$HOME_DIR/state/$id.meta" >&2 || true
    fail "failed managed respawn did not restore the original unmanaged metadata"
  fi
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "prior-$artifact" ] \
      || fail "failed managed respawn did not restore prior $artifact state"
  done
  assert_grep 'lease release ' "$AF_LOG" "failed managed respawn leaked its acquired reservation"
  [ -n "$out" ] || true
  pass "failed managed respawn restores every field from existing unmanaged metadata"
}

test_preinstall_managed_failure_restores_artifact_snapshot() {
  local id rec expected out status artifact
  id=account-preinstall-rollback-z9f
  rec=$(make_case preinstall-rollback claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  artifact="$HOME_DIR/state/$id.pi-ext.ts"
  printf 'prior-state\n' > "$artifact"
  expected="$CASE_DIR/original.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  out=$(FM_FAKE_AF_SELECT_MUTATE_FILE="$artifact" FM_FAKE_AF_BAD_SELECTION=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "pre-install account selection failure unexpectedly spawned"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" || fail "pre-install failure changed retained unmanaged metadata"
  [ "$(cat "$artifact" 2>/dev/null)" = prior-state ] || fail "pre-install failure discarded the retained artifact snapshot"
  [ -n "$out" ] || true
  pass "pre-install managed failures restore retained task artifacts"
}

test_session_sync_bounds_agent_fleet_queries() {
  local id rec meta_tmp started elapsed out status
  id=account-sync-timeout-z9d
  rec=$(make_case sync-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session timeout precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  started=$(date +%s)
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_SLEEP=10 FM_ACCOUNT_SESSION_QUERY_TIMEOUT=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --wait 0 --require 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "timed-out session query unexpectedly succeeded"
  [ "$elapsed" -lt 5 ] || fail "session query exceeded its command timeout (${elapsed}s)"
  assert_absent "$HOME_DIR/state/.account-meta-$id.lock" "timed-out session query retained the metadata lock"
  [ -n "$out" ] || true
  pass "session synchronization bounds every Agent Fleet query"
}

test_session_sync_rejects_workspace_mismatch_without_metadata_change() {
  local id rec meta_tmp expected out status
  id=account-sync-workspace-z9e
  rec=$(make_case sync-workspace claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "workspace mismatch precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  expected="$CASE_DIR/meta-before-workspace-mismatch"
  cp "$HOME_DIR/state/$id.meta" "$expected"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_LOG="$AF_LOG" FM_FAKE_AF_WORKSPACE="$CASE_DIR/wrong-worktree" \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "session sync accepted a mismatched Agent Fleet workspace"
  assert_contains "$out" "session workspace mismatch" \
    "session sync did not report the mismatched workspace"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" \
    || fail "session workspace mismatch changed task metadata"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" \
    "session workspace mismatch published a provider session id"
  pass "session synchronization validates the exact worktree before metadata commit"
}

test_session_sync_all_bounds_each_task_and_reaches_later_mappings() {
  local first later rec out status started elapsed
  first=account-sync-all-a1
  later=account-sync-all-z9
  rec=$(make_case sync-all-fair claude "$first" "$later")
  read_case "$rec"
  for id in "$first" "$later"; do
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$WT_DIR" \
      "project=$PROJ_DIR" \
      "harness=claude" \
      "kind=ship" \
      "account_pool=claude-crew" \
      "account_profile=claude-2" \
      "account_task=$id" \
      "account_attempt=attempt-$id"
  done
  started=$(date +%s)
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_LOG="$AF_LOG" FM_FAKE_AF_SESSION_SLEEP=10 FM_FAKE_AF_SESSION_SLEEP_TASK="$first" \
    FM_ACCOUNT_SESSION_QUERY_TIMEOUT=1 FM_ACCOUNT_SESSION_TASK_TIMEOUT=2 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" --all 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "sync-all hid the timed-out first mapping"
  [ "$elapsed" -lt 5 ] || fail "sync-all did not bound the slow mapping (${elapsed}s)"
  assert_grep "session status --task $first" "$AF_LOG" "sync-all never attempted the slow first mapping"
  assert_grep "session status --task $later" "$AF_LOG" "sync-all starved the later mapping"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$later.meta" \
    "sync-all did not publish the later mapping after the first timed out"
  [ -n "$out" ] || true
  pass "sync-all gives every task an independent bounded mapping attempt"
}

test_session_sync_all_has_one_total_task_timeout_budget() {
  local rec out status started elapsed id
  rec=$(make_case sync-all-total-bound claude account-sync-batch-a1 account-sync-batch-d4)
  read_case "$rec"
  for id in account-sync-batch-a1 account-sync-batch-b2 account-sync-batch-c3 account-sync-batch-d4; do
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$WT_DIR" \
      "project=$PROJ_DIR" \
      "harness=claude" \
      "kind=ship" \
      "account_pool=claude-crew" \
      "account_profile=claude-2" \
      "account_task=$id" \
      "account_attempt=attempt-$id"
  done
  started=$(date +%s)
  if out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_LOG="$AF_LOG" FM_FAKE_AF_SESSION_SLEEP=10 \
    FM_ACCOUNT_SESSION_QUERY_TIMEOUT=1 FM_ACCOUNT_SESSION_TASK_TIMEOUT=2 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" --all 2>&1); then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "fully timed-out sync sweep unexpectedly succeeded"
  [ "$elapsed" -lt 5 ] || fail "sync-all multiplied its timeout across tasks (${elapsed}s)"
  for id in account-sync-batch-a1 account-sync-batch-b2 account-sync-batch-c3 account-sync-batch-d4; do
    assert_grep "session status --task $id" "$AF_LOG" "sync-all did not fairly attempt $id"
  done
  [ -n "$out" ] || true
  pass "sync-all bounds the fair sweep to one task timeout window"
}

test_session_sync_all_rotates_a_bounded_parallel_batch() {
  local rec id attempt count
  rec=$(make_case sync-all-rotating claude account-sync-rotate-a1 account-sync-rotate-e5)
  read_case "$rec"
  for id in account-sync-rotate-a1 account-sync-rotate-b2 account-sync-rotate-c3 account-sync-rotate-d4 account-sync-rotate-e5; do
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$WT_DIR" \
      "project=$PROJ_DIR" \
      "harness=claude" \
      "kind=ship" \
      "account_pool=claude-crew" \
      "account_profile=claude-2" \
      "account_task=$id" \
      "account_attempt=attempt-$id"
  done
  for attempt in 1 2 3; do
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
      FM_FAKE_AF_LOG="$AF_LOG" FM_FAKE_AF_SESSION_SLEEP=10 \
      FM_ACCOUNT_SESSION_QUERY_TIMEOUT=1 FM_ACCOUNT_SESSION_TASK_TIMEOUT=2 \
      FM_ACCOUNT_SESSION_MAX_PARALLEL=2 PATH="$FAKEBIN_DIR:$PATH" \
      "$SESSION_SYNC" --all >/dev/null 2>&1 || true
    count=$(grep -c 'session status --task account-sync-rotate-' "$AF_LOG" || true)
    case "$attempt" in
      1) [ "$count" -eq 2 ] || fail "first sync batch launched $count mappings instead of two" ;;
      2) [ "$count" -eq 4 ] || fail "second sync batch did not advance the rotating cursor (count=$count)" ;;
      3) [ "$count" -eq 6 ] || fail "third sync batch did not preserve its bounded size (count=$count)" ;;
    esac
  done
  for id in account-sync-rotate-a1 account-sync-rotate-b2 account-sync-rotate-c3 account-sync-rotate-d4 account-sync-rotate-e5; do
    assert_grep "session status --task $id" "$AF_LOG" "rotating sync batches never reached $id"
  done
  pass "sync-all limits fanout and rotates fairly across managed tasks"
}

test_session_sync_all_signals_terminate_worker_groups() {
  local rec id sync_pid child_pid status marker child_state
  id=account-sync-signal-a1
  rec=$(make_case sync-all-signal claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "account_pool=claude-crew" \
    "account_profile=claude-2" \
    "account_task=$id" \
    "account_attempt=attempt-$id"
  marker="$CASE_DIR/session-child.pid"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_CHILD_PID_FILE="$marker" FM_ACCOUNT_SESSION_TASK_TIMEOUT=30 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" --all >/dev/null 2>&1 &
  sync_pid=$!
  for _ in $(seq 1 100); do
    [ -s "$marker" ] && break
    sleep 0.05
  done
  [ -s "$marker" ] || { kill "$sync_pid" 2>/dev/null || true; fail "sync worker descendant never started"; }
  child_pid=$(cat "$marker")
  kill -TERM "$sync_pid"
  wait "$sync_pid"
  status=$?
  [ "$status" -eq 143 ] || fail "TERM did not stop the sync sweep with signal status (exit $status)"
  for _ in $(seq 1 40); do
    child_state=$(ps -p "$child_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
    case "$child_state" in ''|Z*) break ;; esac
    sleep 0.05
  done
  child_state=$(ps -p "$child_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
  case "$child_state" in ''|Z*) ;; *) fail "sync sweep left its Agent Fleet descendant running (state $child_state)" ;; esac
  assert_absent "$HOME_DIR/state/.account-meta-session-sync-all.lock" "signaled sync sweep retained its sweep lock"
  pass "sync-all signals terminate and reap complete worker groups"
}

test_session_sync_removes_reaped_workers_from_cleanup_state() {
  local rec id sync_pid ready proceed worker_log first_pid second_pid status
  rec=$(make_case sync-reaped-workers claude account-sync-reap-a1 account-sync-reap-z9)
  read_case "$rec"
  for id in account-sync-reap-a1 account-sync-reap-z9; do
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$WT_DIR" \
      "project=$PROJ_DIR" \
      "harness=claude" \
      "kind=ship" \
      "account_pool=claude-crew" \
      "account_profile=claude-2" \
      "account_task=$id" \
      "account_attempt=attempt-$id"
  done
  ready="$CASE_DIR/reaped-workers.active"
  proceed="$CASE_DIR/reaped-workers.proceed"
  worker_log="$CASE_DIR/reaped-workers.launched"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_SLEEP=10 FM_FAKE_AF_SESSION_SLEEP_TASK=account-sync-reap-z9 \
    FM_ACCOUNT_SESSION_QUERY_TIMEOUT=5 FM_ACCOUNT_SESSION_TASK_TIMEOUT=8 \
    FM_ACCOUNT_SESSION_MAX_PARALLEL=2 FM_ACCOUNT_SESSION_WORKER_TEST_LOG="$worker_log" \
    FM_ACCOUNT_SESSION_REAP_TEST_READY="$ready" FM_ACCOUNT_SESSION_REAP_TEST_PROCEED="$proceed" \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" --all >/dev/null 2>&1 &
  sync_pid=$!
  for _ in $(seq 1 100); do
    [ -s "$ready" ] && [ "$(wc -l < "$worker_log" 2>/dev/null | tr -d ' ')" -eq 2 ] && break
    sleep 0.05
  done
  [ -s "$ready" ] || { kill -TERM "$sync_pid" 2>/dev/null || true; fail "sync-all never exposed post-reap active state"; }
  first_pid=$(sed -n '1p' "$worker_log")
  second_pid=$(sed -n '2p' "$worker_log")
  ! grep -Fxq "$first_pid" "$ready" || fail "reaped worker remained eligible for cleanup"
  grep -Fxq "$second_pid" "$ready" || fail "live worker disappeared from cleanup state"
  touch "$proceed"
  kill -TERM "$sync_pid"
  wait "$sync_pid"
  status=$?
  [ "$status" -eq 143 ] || fail "post-reap sync cleanup did not exit on TERM (exit $status)"
  pass "sync-all removes each worker from cleanup state immediately after reaping"
}

test_session_sync_releases_metadata_lock_during_provider_query() {
  local id rec meta_tmp marker sync_pid sync_rc
  id=account-sync-lock-z9e
  rec=$(make_case sync-lock claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session lock precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  marker="$CASE_DIR/session-query-started"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_MARKER="$marker" FM_FAKE_AF_SESSION_SLEEP=2 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require > "$CASE_DIR/sync.out" 2>&1 &
  sync_pid=$!
  for _ in $(seq 1 50); do
    [ -f "$marker" ] && break
    sleep 0.05
  done
  [ -f "$marker" ] || { kill "$sync_pid" 2>/dev/null || true; fail "session query did not start"; }
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 bash -c '
    . "$1"
    held=$(fm_account_meta_lock_acquire "$2" "$3")
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$HOME_DIR/state" "$id" \
    || { kill "$sync_pid" 2>/dev/null || true; fail "provider query retained the metadata lock"; }
  wait "$sync_pid"
  sync_rc=$?
  expect_code 0 "$sync_rc" "session sync should complete after the unlocked provider query"
  pass "session queries hold lifecycle ownership without blocking metadata writers"
}

test_continuation_rejects_symlinked_charter_ancestor() {
  local id rec outside out status
  id=account-charter-escape-z9e
  rec=$(make_case charter-escape claude "$id")
  read_case "$rec"
  outside="$CASE_DIR/outside-data"
  mkdir -p "$outside"
  printf 'outside charter\n' > "$outside/charter.md"
  ln -s "$outside" "$WT_DIR/data"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=secondmate" \
    "home=$WT_DIR" \
    "account_pool=claude-crew" \
    "account_profile=claude-2" \
    "account_task=$id" \
    "account_attempt=legacy"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" safe-attempt 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted a charter through a symlinked ancestor"
  assert_contains "$out" "charter is present but unsafe" "unsafe charter rejection was unclear"
  assert_absent "$HOME_DIR/data/$id/continuation-safe-attempt.md" "unsafe charter was copied into a continuation packet"
  pass "secondmate continuation requires a contained charter path"
}

test_continuation_rejects_present_empty_charter() {
  local id rec out status
  id=account-empty-charter-z9f
  rec=$(make_case empty-charter claude "$id")
  read_case "$rec"
  mkdir -p "$WT_DIR/data"
  : > "$WT_DIR/data/charter.md"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=secondmate" \
    "home=$WT_DIR" \
    "account_pool=claude-crew" \
    "account_profile=claude-2" \
    "account_task=$id" \
    "account_attempt=legacy"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" empty-charter-attempt 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation silently replaced an empty present charter with the task brief"
  assert_contains "$out" "secondmate charter is empty" "empty charter rejection was unclear"
  assert_absent "$HOME_DIR/data/$id/continuation-empty-charter-attempt.md" \
    "empty charter fallback published a continuation packet"
  pass "secondmate continuation falls back only when the charter is absent"
}

test_recovered_reservations_are_owned_only_after_validated_recovery() {
  local id rec out status account_task session lineage
  id=account-recover-owned-z9b
  rec=$(make_case recover-owned claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "recovered reservation precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_RECOVER_TASK=wrong-recovery-task run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched recovery response unexpectedly succeeded"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "mismatched recovery did not release its cleanup-owned reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "mismatched recovery removed the durable session mapping"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "mismatched recovery changed durable session metadata"

  clear_case_logs
  out=$(FM_FAKE_AF_SELECTION_WORKSPACE="$CASE_DIR/wrong-recovery-workspace" \
    run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "cross-workspace recovery response unexpectedly succeeded"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" \
    "cross-workspace recovery did not release its exact cleanup-owned reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" \
    "cross-workspace recovery removed durable session state"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" \
    "cross-workspace recovery changed durable session metadata"

  clear_case_logs
  lineage="$HOME_DIR/data/$id/account-attempts.md"
  rm -f "$lineage"
  mkdir "$lineage"
  out=$(run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "post-recovery pre-bind failure unexpectedly succeeded"
  assert_grep "lease recover --task $account_task" "$AF_LOG" "post-recovery failure never acquired the sticky reservation"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "post-recovery failure leaked its owned reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "post-recovery rollback removed the durable session mapping"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "post-recovery rollback lost durable session metadata"
  [ -n "$out" ] || true
  pass "sticky recovery mutations remain rollback-owned while preserving durable session truth"
}

test_native_resume_requires_fresh_sessionstart_evidence() {
  local id rec out status account_task session
  id=account-resume-fresh-z9c
  rec=$(make_case resume-fresh claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "fresh resume precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_RESUME_NO_REFRESH=1 run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "native resume accepted a stale SessionStart mapping"
  assert_contains "$out" "no fresh Agent Fleet SessionStart update" "stale native resume did not report its missing launch evidence"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "stale native resume leaked its recovered reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "stale native resume removed its durable mapping"
  assert_regex '^kill-window ' "$TMUX_LOG" "stale native resume retained its failed endpoint"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "stale native resume changed session truth"
  pass "native resume commits only after a fresh SessionStart update"
}

test_native_resume_rejects_prelaunch_sessionstart_evidence() {
  local id rec out status account_task session
  id=account-resume-launch-z9d
  rec=$(make_case resume-launch claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "launch-specific resume precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_STALE_REFRESH_ON_RECOVER=1 FM_FAKE_AF_RESUME_NO_REFRESH=1 run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "native resume accepted SessionStart evidence produced before its launch gate"
  assert_contains "$out" "no fresh Agent Fleet SessionStart update" "prelaunch SessionStart evidence was not rejected"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "prelaunch evidence failure leaked its recovered reservation"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "prelaunch evidence failure changed durable session truth"
  pass "native resume requires SessionStart evidence after its own launch gate"
}

test_native_resume_accepts_same_wallclock_sessionstart_evidence() {
  local id rec out status timestamp
  id=account-resume-whole-second-z9e
  rec=$(make_case resume-whole-second claude "$id")
  read_case "$rec"
  if out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "whole-second resume precondition spawn failed: $out"
  rm -f "$CASE_DIR/endpoint-live" "$CASE_DIR/session-refreshed"
  clear_case_logs
  timestamp=2026-07-13T00:00:00Z

  if out=$(FM_FAKE_AF_UPDATED_AT_BEFORE="$timestamp" FM_FAKE_AF_UPDATED_AT_AFTER="$timestamp" \
    run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "same-wallclock SessionStart evidence was rejected after its event sequence advanced: $out"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$id.meta" "same-wallclock native resume lost its provider session binding"
  pass "native resume freshness is independent of wall-clock timestamp granularity"
}

test_native_resume_migrates_legacy_session_mapping_after_launch_gate() {
  local id rec out status
  id=account-resume-legacy-seq-z9g
  rec=$(make_case resume-legacy-seq claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "legacy-sequence resume precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live" "$CASE_DIR/session-refreshed"
  clear_case_logs

  if out=$(FM_FAKE_AF_SESSION_SCHEMA_BEFORE=1 FM_FAKE_AF_SESSION_EVENT_SEQ_BEFORE=0 \
    FM_FAKE_AF_SESSION_SCHEMA_AFTER=2 FM_FAKE_AF_SESSION_EVENT_SEQ_AFTER=1 \
    run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] \
    || fail "legacy schema-1 native resume did not accept its same-binding 0 -> 1 SessionStart migration: $out"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$id.meta" \
    "legacy schema-1 native resume lost its provider session binding"
  pass "native resume accepts legacy sequence zero only as the baseline for a fresh same-binding SessionStart migration"
}

test_native_resume_rejects_zero_sequence_on_current_schema() {
  local id rec out status
  id=account-resume-current-zero-z9h
  rec=$(make_case resume-current-zero claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "current-schema zero-sequence precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live" "$CASE_DIR/session-refreshed"
  clear_case_logs

  if out=$(FM_FAKE_AF_SESSION_SCHEMA_BEFORE=2 FM_FAKE_AF_SESSION_EVENT_SEQ_BEFORE=0 \
    run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "schema-2 native resume accepted reserved legacy sequence zero"
  assert_contains "$out" "event sequence does not match mapping schema" \
    "schema-2 zero-sequence refusal was not explicit"
  assert_not_grep '^new-window ' "$TMUX_LOG" \
    "schema-2 zero-sequence refusal created an endpoint"
  pass "session event sequence zero is accepted only for a legacy schema-1 baseline"
}

test_native_resume_accepts_agent_fleet_utc_offset_timestamps() {
  local id rec out status before after
  id=account-resume-offset-z9f
  rec=$(make_case resume-offset claude "$id")
  read_case "$rec"
  before=2026-07-13T00:00:00.100000+00:00
  after=2026-07-13T00:00:00.200000+00:00
  FM_FAKE_AF_UPDATED_AT_BEFORE="$before" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "Agent Fleet timestamp resume precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  if out=$(FM_FAKE_AF_UPDATED_AT_BEFORE="$before" FM_FAKE_AF_UPDATED_AT_AFTER="$after" \
    run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] \
    || fail "real Agent Fleet +00:00 SessionStart timestamp was rejected: $out"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$id.meta" \
    "Agent Fleet timestamp resume lost its provider session binding"
  pass "native resume remains compatible with Agent Fleet's RFC3339 +00:00 metadata"
}

test_native_resume_uses_private_launch_directory_and_cleans_it() {
  local id rec out status sentinel launch wrapper native_dir
  id=account-resume-private-z9e
  rec=$(make_case resume-private claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "private resume precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  sentinel="$CASE_DIR/native-launch-sentinel"
  printf 'sentinel\n' > "$sentinel"
  ln -s "$sentinel" "$HOME_DIR/state/.$id.account-native-launch"
  ln -s "$sentinel" "$HOME_DIR/state/.$id.account-native-ready"
  ln -s "$sentinel" "$HOME_DIR/state/.$id.account-native-go"

  out=$(run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -eq 0 ] || fail "private native resume failed (exit $status): $out"
  launch=$(grep 'account-native-launch' "$LAUNCH_LOG" | tail -1)
  wrapper=$(printf '%s\n' "$launch" | sed -n "s/.*'\([^']*\/account-native-launch\)'.*/\1/p")
  [ -n "$wrapper" ] || fail "native resume did not launch a private wrapper: $launch"
  native_dir=${wrapper%/account-native-launch}
  [ "$native_dir" != "$HOME_DIR/state" ] || fail "native resume reused the predictable state-root wrapper"
  assert_absent "$native_dir" "successful native resume retained its private launch directory"
  assert_absent "$HOME_DIR/state/.$id.account-native-launch" "native resume retained the legacy launch path"
  assert_absent "$HOME_DIR/state/.$id.account-native-ready" "native resume retained the legacy ready path"
  assert_absent "$HOME_DIR/state/.$id.account-native-go" "native resume retained the legacy go path"
  [ "$(cat "$sentinel")" = sentinel ] || fail "legacy native launch symlinks clobbered their target"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(FM_FAKE_AF_RESUME_NO_REFRESH=1 run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "failed-resume cleanup precondition unexpectedly succeeded"
  if find "$HOME_DIR/state" -mindepth 1 -maxdepth 1 -type d -name ".$id.account-native-launch.*" -print -quit | grep -q .; then
    fail "failed native resume retained its private launch directory"
  fi
  pass "native resume uses private launch directories and cleans every exit path"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/bin/fm-account-routing-lib.sh" "$home/bin/fm-account-routing-lib.sh"
  cp "$ROOT/bin/fm-spawn.sh" "$home/bin/fm-spawn.sh"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

test_secondmate_pool_is_nonactivating_and_noninherited() {
  local id rec sm out status
  id=account-secondmate-off-z10
  rec=$(make_case secondmate-off claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"

  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "pool-only secondmate spawn should stay legacy/off (exit $status): $out"
  [ ! -s "$AF_LOG" ] || fail "secondmate pool activated Agent Fleet while routing was off: $(cat "$AF_LOG")"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "off secondmate wrote account metadata"
  assert_absent "$sm/config/secondmate-account-pool" "secondmate account pool leaked into the child home"
  pass "the primary secondmate pool is non-inherited and does not activate routing by itself"
}

test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits() {
  local id rec sm out status
  id=account-secondmate-enforce-z11
  rec=$(make_case secondmate-enforce claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"

  out=$(FM_ACCOUNT_ROUTING_LEGACY_NEW_LAUNCH_TEST='' \
    FM_FAKE_AF_POOL=claude-captains FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "enforced secondmate spawn should succeed (exit $status): $out"
  assert_regex "lease choose --pool claude-captains --task .*-$id-.* --provider claude" "$AF_LOG" "secondmate did not use its primary-owned account pool"
  assert_grep 'account_pool=claude-captains' "$HOME_DIR/state/$id.meta" "secondmate meta lost its account pool"
  assert_not_grep '^account_home=' "$HOME_DIR/state/$id.meta" "secondmate entered direct account-directory routing"
  [ "$(cat "$sm/config/account-routing-mode" 2>/dev/null)" = enforce ] || fail "account routing mode did not inherit into the secondmate home"
  assert_absent "$sm/config/secondmate-account-pool" "primary-only secondmate pool leaked into the child home"
  pass "secondmate routing uses the primary pool while the mode, but not that pool, inherits"
}

test_explicit_secondmate_route_preserves_ambient_primary_enforce() {
  local id rec sm out status
  id=account-secondmate-explicit-env-z11c
  rec=$(make_case secondmate-explicit-env claude | tail -1)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(FM_ACCOUNT_ROUTING=enforce FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-profile claude-2)
  status=$?
  [ "$status" -ne 0 ] || fail "explicit secondmate routing hid the primary's ambient enforce policy"
  assert_contains "$out" "$sm" "ambient-enforce refusal omitted the offending secondmate home"
  assert_contains "$out" "primary's enforce routing mode is not authoritative in the home" \
    "ambient-enforce refusal omitted the inherited-policy mismatch"
  assert_contains "$out" "Run bin/fm-config-push.sh and retry" \
    "ambient-enforce refusal omitted the durable reconciliation action"
  assert_not_grep '^new-window ' "$TMUX_LOG" "ambient-enforce refusal created an endpoint"
  pass "explicit secondmate routes preserve the ambient primary enforce policy"
}

test_enforced_secondmate_requires_routing_inheritance_and_capable_home() {
  local id rec sm out status
  id=account-secondmate-inherit-refuse-z11d
  rec=$(make_case secondmate-inherit-refuse claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  mkdir "$sm/config/account-routing-mode"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "enforced secondmate launched after routing-mode inheritance failed"
  assert_contains "$out" "secondmate-home" "inheritance refusal omitted the offending secondmate home"
  assert_contains "$out" "run bin/fm-config-push.sh" "inheritance refusal omitted the manual reconciliation step"
  assert_not_grep '^new-window ' "$TMUX_LOG" "inheritance refusal created an endpoint"

  id=account-secondmate-incapable-refuse-z11e
  rec=$(make_case secondmate-incapable-refuse claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  rm -f "$sm/bin/fm-account-routing-lib.sh"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "enforced secondmate launched from a pre-Agent-Fleet home"
  assert_contains "$out" "secondmate-home" "capability refusal omitted the offending secondmate home"
  assert_contains "$out" "lacks Agent Fleet routing support" "capability refusal omitted its reason"
  assert_contains "$out" "run bin/fm-config-push.sh" "capability refusal omitted the manual reconciliation step"
  assert_not_grep '^new-window ' "$TMUX_LOG" "capability refusal created an endpoint"
  pass "enforced secondmates require inherited routing policy and Agent Fleet-capable homes"
}

test_secondmate_routing_inheritance_is_authoritative_for_every_mode() {
  local id rec sm out status
  id=account-secondmate-observe-inherit-z11f
  rec=$(make_case secondmate-observe-inherit claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  printf 'observe\n' > "$HOME_DIR/config/account-routing-mode"
  mkdir "$sm/config/account-routing-mode"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "observe secondmate launched without authoritative routing inheritance"
  assert_contains "$out" "config inheritance failed" "observe convergence failure was not warned"
  assert_contains "$out" "account-routing-mode inheritance did not succeed" "observe convergence failure did not block on policy authority"
  assert_not_grep '^new-window ' "$TMUX_LOG" "observe convergence failure created an endpoint"

  id=account-secondmate-off-stale-z11h
  rec=$(make_case secondmate-off-stale claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  mkdir "$sm/config/account-routing-mode"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "off downgrade launched while stale child routing policy could not be removed"
  assert_contains "$out" "account-routing-mode inheritance did not succeed" "off downgrade did not block on policy authority"
  assert_not_grep '^new-window ' "$TMUX_LOG" "off downgrade convergence failure created an endpoint"

  id=account-secondmate-off-incapable-z11g
  rec=$(make_case secondmate-off-incapable claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  rm -f "$sm/bin/fm-account-routing-lib.sh"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "off secondmate did not preserve warn-and-launch behavior: $out"
  assert_contains "$out" "lacks Agent Fleet routing support" "off capability gap was not warned"
  assert_regex '^new-window ' "$TMUX_LOG" "off capability warning blocked launch"
  pass "secondmate launches require authoritative routing policy in every mode"
}

test_managed_shared_namespace_secondmate_uses_primary_endpoint_scope() {
  local id rec sm zellij_log out status scope
  id=account-secondmate-zellij-z11a
  rec=$(make_case secondmate-zellij claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  zellij_log="$CASE_DIR/zellij.log"
  make_seeded_secondmate_home "$sm" "$id"
  : > "$zellij_log"
  cat > "$FAKEBIN_DIR/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s|%s|%s\n' "${FM_HOME:-}" "${FM_ROOT:-}" "$*" >> "$FM_FAKE_ZELLIJ_LOG"
case "$*" in
  '--version') printf 'zellij 0.44.0\n'; exit 0 ;;
  'list-sessions --short --no-formatting') printf 'firstmate\n'; exit 0 ;;
  *' action new-tab '*)
    prev=
    for arg in "$@"; do
      [ "$prev" != --name ] || printf '%s\n' "$arg" > "$FM_FAKE_ZELLIJ_TITLE"
      prev=$arg
    done
    touch "$FM_FAKE_ZELLIJ_ENDPOINT"
    printf '7\n'
    exit 0
    ;;
  *' action list-panes --json'*)
    if [ -f "$FM_FAKE_ZELLIJ_ENDPOINT" ]; then
      printf '[{"id":9,"tab_id":7,"is_plugin":false,"pane_cwd":"%s"}]\n' "$FM_FAKE_ZELLIJ_CWD"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action list-tabs --json'*)
    if [ -f "$FM_FAKE_ZELLIJ_ENDPOINT" ]; then
      printf '[{"tab_id":7,"name":"%s","active":true}]\n' "$(cat "$FM_FAKE_ZELLIJ_TITLE")"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action close-tab-by-id 7'*) rm -f "$FM_FAKE_ZELLIJ_ENDPOINT"; exit 0 ;;
  *' action paste '*|*' action write-chars '*|*' action send-keys '*|*' action dump-screen '*) exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/zellij"

  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_ZELLIJ_LOG="$zellij_log" \
    FM_FAKE_ZELLIJ_ENDPOINT="$CASE_DIR/zellij-endpoint" FM_FAKE_ZELLIJ_TITLE="$CASE_DIR/zellij-title" \
    FM_FAKE_ZELLIJ_CWD="$sm" FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --backend zellij --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "unbound managed zellij secondmate unexpectedly succeeded"
  assert_absent "$CASE_DIR/zellij-endpoint" "zellij secondmate rollback left its live endpoint"
  assert_not_grep "^$sm\\|" "$zellij_log" "zellij secondmate switched endpoint label scope during rollback"
  assert_regex "^$HOME_DIR\\|" "$zellij_log" "zellij secondmate never used the primary endpoint label scope"
  assert_grep 'lease release ' "$AF_LOG" "zellij secondmate rollback did not release after confirmed endpoint removal"
  scope=$(FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" bash -c '. "$1"; fm_backend_endpoint_home cmux secondmate "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$HOME_DIR" "$sm")
  [ "$scope" = "$HOME_DIR" ] || fail "cmux secondmate endpoint scope drifted from its primary owner"
  scope=$(FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" bash -c '. "$1"; fm_backend_endpoint_home herdr secondmate "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$HOME_DIR" "$sm")
  [ "$scope" = "$sm" ] || fail "herdr secondmate endpoint scope lost its child workspace owner"
  pass "managed secondmates keep backend-specific endpoint ownership across cleanup"
}

test_unused_secondmate_pool_never_blocks_unmanaged_spawn() {
  local id rec sm out status
  id=account-secondmate-malformed-off-z11b
  rec=$(make_case secondmate-malformed-off claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-one\nclaude-two\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed unused secondmate pool blocked default-off spawn: $out"
  [ ! -s "$AF_LOG" ] || fail "default-off malformed pool invoked Agent Fleet"

  id=account-secondmate-malformed-optout-z11c
  rec=$(make_case secondmate-malformed-optout claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  printf 'claude-one\nclaude-two\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --no-account-routing)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed unused secondmate pool blocked explicit opt-out: $out"
  [ ! -s "$AF_LOG" ] || fail "opted-out malformed pool invoked Agent Fleet"
  assert_contains "$out" 'WARNING: emergency --no-account-routing bypass is active' "emergency bypass was not surfaced"
  assert_grep 'account_routing_emergency_bypass=1' "$HOME_DIR/state/$id.meta" "emergency bypass was not audited in task metadata"
  pass "unused secondmate pool policy is not parsed by unmanaged spawns"
}

test_agent_fleet_task_keys_are_namespaced_by_home_and_attempt() {
  local id rec task_one task_two
  id=account-namespace-z12
  rec=$(make_case namespace-one claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "first namespaced spawn failed"
  task_one=$(meta_account_task "$id")
  rec=$(make_case namespace-two claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "second namespaced spawn failed"
  task_two=$(meta_account_task "$id")
  [ "$task_one" != "$task_two" ] || fail "two firstmate homes shared Agent Fleet task key $task_one"
  assert_contains "$task_one" "-$id-a" "first Agent Fleet task did not retain local task identity"
  assert_contains "$task_two" "-$id-a" "second Agent Fleet task did not retain local task identity"
  pass "Agent Fleet task keys namespace every home-local task and launch generation"
}

test_duplicate_spawn_preserves_original_endpoint_and_lease() {
  local id rec out status artifact
  id=account-duplicate-z13
  rec=$(make_case duplicate claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "initial duplicate test spawn failed"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'existing-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate managed spawn unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "duplicate managed spawn touched the original lease: $(cat "$AF_LOG")"
  assert_not_grep '^kill-window ' "$TMUX_LOG" "duplicate managed spawn killed the original endpoint"
  assert_present "$CASE_DIR/endpoint-live" "duplicate managed spawn removed the original endpoint marker"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "existing-$artifact" ] \
      || fail "duplicate managed spawn removed the existing $artifact sidecar"
  done
  assert_contains "$out" "managed metadata already exists" "duplicate managed spawn did not fail at ownership guard"
  pass "duplicate spawn cannot release or kill an existing managed task"
}

test_reservation_occurs_after_worktree_preparation() {
  local id rec treehouse_line lease_line
  id=account-order-z14
  rec=$(make_case order claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "reservation order spawn failed"
  treehouse_line=$(grep -n '^treehouse get --lease --lease-holder firstmate-account-order-z14$' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1)
  lease_line=$(grep -n 'agent-fleet .* lease choose ' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1)
  [ -n "$treehouse_line" ] && [ -n "$lease_line" ] && [ "$lease_line" -gt "$treehouse_line" ] \
    || fail "Agent Fleet reservation did not follow worktree preparation: $(tr '\n' '|' < "$LIFECYCLE_LOG")"
  pass "account capacity is reserved only when the prepared endpoint can bind"
}

test_reserved_generation_is_durable_before_lease_mutation() {
  local id rec real_mv marker gate installed_marker installed_gate spawn_pid status meta task
  id=account-durable-lease-z14b
  rec=$(make_case durable-lease claude "$id")
  read_case "$rec"
  real_mv=$(command -v mv)
  marker="$CASE_DIR/provisional-meta-persisted"
  gate="$CASE_DIR/continue-after-provisional-meta"
  installed_marker="$CASE_DIR/endpoint-meta-installed"
  installed_gate="$CASE_DIR/continue-after-endpoint-meta"
  cat > "$FAKEBIN_DIR/mv" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  *.meta.rollback-pending.*)
    "$FM_FAKE_REAL_MV" "$@" || exit $?
    touch "$FM_FAKE_PROVISIONAL_META_MARKER"
    while [ ! -f "$FM_FAKE_PROVISIONAL_META_GATE" ]; do sleep 0.05; done
    exit 0
    ;;
  *.meta.*)
    "$FM_FAKE_REAL_MV" "$@" || exit $?
    touch "$FM_FAKE_INSTALLED_META_MARKER"
    while [ ! -f "$FM_FAKE_INSTALLED_META_GATE" ]; do sleep 0.05; done
    exit 0
    ;;
esac
exec "$FM_FAKE_REAL_MV" "$@"
SH
  chmod +x "$FAKEBIN_DIR/mv"

  FM_FAKE_REAL_MV="$real_mv" FM_FAKE_PROVISIONAL_META_MARKER="$marker" \
    FM_FAKE_PROVISIONAL_META_GATE="$gate" FM_FAKE_INSTALLED_META_MARKER="$installed_marker" \
    FM_FAKE_INSTALLED_META_GATE="$installed_gate" FM_FAKE_AF_REQUIRE_PRELEASE_META="$HOME_DIR/state/$id.meta" \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew \
    > "$CASE_DIR/spawn-stdout" 2> "$CASE_DIR/spawn-stderr" &
  spawn_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$marker" ] && break
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$marker" ] || { touch "$gate"; wait "$spawn_pid" 2>/dev/null || true; fail "spawn never persisted provisional managed metadata"; }
  meta="$HOME_DIR/state/$id.meta"
  task=$(meta_account_task "$id")
  assert_grep 'account_rollback_cleanup=pending' "$meta" "provisional metadata was not marked for rollback recovery"
  assert_grep "account_task=$task" "$meta" "provisional metadata lost the pending Agent Fleet task"
  assert_not_grep '^account_profile=' "$meta" "provisional metadata invented a profile before Agent Fleet selection"
  assert_grep "window=firstmate:fm-$id" "$meta" "provisional metadata lost the prepared endpoint"
  assert_regex '^tmux_window_id=%77$' "$meta" "provisional metadata lost the stable replacement endpoint identity"
  assert_grep "tmux_session_target=firstmate:fm-$id" "$meta" \
    "provisional metadata lost the scoped tmux session identity"
  touch "$gate"
  for _ in $(seq 1 100); do
    [ -f "$installed_marker" ] && break
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$installed_marker" ] || { touch "$installed_gate"; wait "$spawn_pid" 2>/dev/null || true; fail "spawn never installed endpoint metadata"; }
  assert_grep 'account_rollback_cleanup=pending' "$meta" "endpoint metadata cleared rollback recovery before launch commit"
  assert_grep 'account_profile=claude-2' "$meta" "endpoint metadata lost the selected account profile"
  assert_grep "tmux_session_target=firstmate:fm-$id" "$meta" \
    "endpoint metadata lost the scoped tmux session identity"
  touch "$installed_gate"
  status=0
  wait "$spawn_pid" || status=$?
  expect_code 0 "$status" "spawn should continue after its provisional generation is durable"
  assert_not_grep 'account_rollback_cleanup=pending' "$meta" "committed metadata retained the provisional rollback marker"
  pass "managed account identity is durable before lease mutation and through launch commit"
}

test_raw_enforced_launch_is_rejected_before_mutation() {
  local id rec out status
  id=account-raw-z15
  rec=$(make_case raw claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR" --harness 'claude --dangerously-skip-permissions' --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "raw enforced launch unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "raw enforced launch touched Agent Fleet"
  assert_not_grep '^new-window ' "$TMUX_LOG" "raw enforced launch created an endpoint"
  assert_contains "$out" "does not accept raw launch commands" "raw enforced launch blocker was unclear"
  pass "raw launch commands cannot bypass enforced account wrapping"
}

test_global_enforce_refuses_unsupported_harnesses() {
  local first second rec out status
  first=account-enforce-opencode-z15b
  second=account-enforce-raw-z15c
  rec=$(make_case enforce-unsupported opencode "$first" "$second")
  read_case "$rec"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"

  out=$(run_spawn "$first" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "global enforce unexpectedly admitted opencode"
  assert_contains "$out" "enforced account routing requires a claude or codex harness" "unsupported enforced harness blocker was unclear"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unsupported enforced harness created an endpoint"
  assert_absent "$HOME_DIR/state/$first.meta" "unsupported enforced harness wrote task metadata"

  clear_case_logs
  out=$(run_spawn "$second" "$PROJ_DIR" --harness 'custom-agent --unsafe')
  status=$?
  [ "$status" -ne 0 ] || fail "global enforce unexpectedly admitted a raw unsupported harness"
  assert_contains "$out" "enforced account routing requires a claude or codex harness" "raw unsupported enforced harness blocker was unclear"
  assert_not_grep '^new-window ' "$TMUX_LOG" "raw unsupported enforced harness created an endpoint"
  assert_absent "$HOME_DIR/state/$second.meta" "raw unsupported enforced harness wrote task metadata"
  pass "global enforced routing refuses unsupported and raw harnesses before mutation"
}

test_malformed_routing_mode_fails_closed() {
  local id rec out status
  id=account-mode-z16
  rec=$(make_case mode claude "$id")
  read_case "$rec"
  printf 'enforce\noff\n' > "$HOME_DIR/config/account-routing-mode"
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "multi-value routing mode silently fell back to off"
  assert_not_grep '^new-window ' "$TMUX_LOG" "invalid routing mode created an endpoint"
  assert_contains "$out" "must contain exactly one value" "invalid routing mode error was suppressed"
  printf 'en force\n' > "$HOME_DIR/config/account-routing-mode"
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "internally spaced routing mode silently activated enforce"
  assert_not_grep '^new-window ' "$TMUX_LOG" "internally spaced routing mode created an endpoint"
  assert_contains "$out" "invalid account routing mode 'en force'" "internal policy whitespace was not preserved for validation"
  rm -f "$HOME_DIR/config/account-routing-mode"
  mkdir "$HOME_DIR/config/account-routing-mode"
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "unreadable routing mode silently fell back to off"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unreadable routing mode created an endpoint"
  assert_contains "$out" "cannot read" "unreadable routing mode error was suppressed"
  pass "malformed or unreadable account-routing policy never collapses to default-off"
}

test_invalid_selection_response_releases_reservation() {
  local id rec out status task release_count retained_id retained_rec retained_task
  id=account-invalid-select-z17
  rec=$(make_case invalid-select claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep "lease release --task $task --force" "$AF_LOG" "malformed lease response leaked its reservation"
  assert_absent "$HOME_DIR/state/$id.meta" "malformed lease response left managed metadata"
  [ -n "$out" ] || true
  : > "$AF_LOG"
  rm -f "$CASE_DIR/release-failed-once"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 FM_FAKE_AF_RELEASE_FAIL_ONCE="$CASE_DIR/release-failed-once" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response with a transient release failure unexpectedly succeeded"
  release_count=$(grep -c 'lease release .* --force' "$AF_LOG" || true)
  [ "$release_count" -eq 2 ] || fail "malformed lease rollback did not retry the owned reservation after release failure"

  retained_id=account-invalid-select-retained-z17b
  retained_rec=$(make_case invalid-select-retained claude "$retained_id")
  read_case "$retained_rec"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$retained_id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response with persistent release failure unexpectedly succeeded"
  retained_task=$(logged_account_task)
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$retained_id.meta" \
    "unreleased invalid selection did not persist rollback metadata"
  assert_grep "account_task=$retained_task" "$HOME_DIR/state/$retained_id.meta" \
    "unreleased invalid selection lost its Agent Fleet task identity"
  pass "post-acquisition response validation always releases the reservation"
}

test_fresh_launch_requires_session_binding_and_fully_rolls_back() {
  local id rec out status task
  id=account-bind-z18
  rec=$(make_case bind claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "managed launch without SessionStart mapping unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep "lease release --task $task --force" "$AF_LOG" "unbound launch did not release its lease"
  assert_grep "session remove --task $task" "$AF_LOG" "unbound launch did not remove its attempt mapping"
  assert_regex '^kill-window ' "$TMUX_LOG" "unbound launch did not kill its endpoint"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "unbound launch did not return its worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "unbound launch left phantom recovery metadata"
  assert_contains "$out" "did not bind a fresh SessionStart mapping" "unbound launch did not report its binding failure"
  pass "fresh managed launches commit only after provider binding and otherwise unwind"
}

test_failed_cleanup_persists_retryable_metadata() {
  local id rec out status task
  id=account-rollback-retry-z18b
  rec=$(make_case rollback-retry claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed launch with failed cleanup unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed cleanup did not persist a retry marker"
  assert_grep "account_task=$task" "$HOME_DIR/state/$id.meta" "failed cleanup lost its Agent Fleet task identity"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" "failed cleanup recycled its retained worktree"

  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "teardown could not retry failed Agent Fleet cleanup"
  assert_grep "lease release --task $task --force" "$AF_LOG" "teardown did not retry the failed lease release"
  assert_grep "session remove --task $task" "$AF_LOG" "teardown did not retry the failed session cleanup"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "teardown did not recycle the worktree after account cleanup"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown left failed-attempt metadata after cleanup"
  pass "failed Agent Fleet cleanup leaves durable teardown-retry state"
}

test_unknown_spawn_endpoint_retains_lease_for_retry() {
  local id rec out status task
  id=account-unknown-rollback-z18c
  rec=$(make_case unknown-rollback claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_TARGET_STATE=unknown FM_FAKE_TMUX_LIST_WINDOWS_UNKNOWN=1 FM_FAKE_TMUX_KILL_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "unknown failed endpoint unexpectedly committed"
  task=$(logged_account_task)
  assert_not_grep "lease release --task $task" "$AF_LOG" "unknown endpoint state released its lease"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "unknown endpoint state lost retry metadata"
  assert_contains "$out" "endpoint state is unknown" "unknown endpoint retention was not reported"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "unknown endpoint retry state could not be torn down after absence was confirmed"
  pass "spawn rollback retains leases while endpoint state is unknown"
}

test_rollback_retry_rechecks_live_endpoint_before_release() {
  local id rec out status task
  id=account-live-rollback-retry-z18d
  rec=$(make_case live-rollback-retry claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback retry precondition unexpectedly succeeded"
  task=$(logged_account_task)
  touch "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(FM_FAKE_TMUX_KILL_FAIL=1 run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback retry released a live endpoint"
  assert_not_grep "lease release --task $task" "$AF_LOG" "rollback retry released the lease before killing the endpoint"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "live rollback retry lost retry metadata"
  assert_contains "$out" "endpoint is still alive" "live rollback retry blocker was unclear"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "live rollback retry state could not be torn down after endpoint removal"
  pass "rollback cleanup retries prove the retained endpoint is dead"
}

test_failed_secondmate_rollback_preserves_home_for_relaunch() {
  local id rec sm out status
  id=account-secondmate-rollback-z18e
  rec=$(make_case secondmate-rollback claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed secondmate rollback precondition unexpectedly succeeded"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed secondmate attempt lost cleanup metadata"

  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup-only secondmate retry claimed to relaunch"
  assert_absent "$HOME_DIR/state/$id.meta" "cleaned secondmate attempt still poisoned ordinary respawn"
  assert_present "$sm/.fm-secondmate-home" "secondmate cleanup retired the persistent home"
  assert_contains "$out" "retry the secondmate spawn without tearing down its home" "secondmate retry guidance was unclear"

  clear_case_logs
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -eq 0 ] || fail "cleaned secondmate home could not relaunch: $out"
  assert_present "$sm/.fm-secondmate-home" "secondmate relaunch lost its home marker"
  pass "failed secondmate rollback clears task state without retiring its home"
}

test_secondmate_rollback_refuses_unsafe_tasktmp() {
  local id rec sm sentinel meta_tmp out status
  id=account-secondmate-tasktmp-z18ea
  rec=$(make_case secondmate-tasktmp claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  sentinel="$CASE_DIR/must-survive"
  make_seeded_secondmate_home "$sm" "$id"
  mkdir -p "$sentinel"
  printf 'preserve\n' > "$sentinel/marker"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "unsafe tasktmp precondition unexpectedly succeeded"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^tasktmp=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  printf 'tasktmp=%s\n' "$sentinel" >> "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"

  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback accepted an unsafe metadata tasktmp"
  assert_present "$sentinel/marker" "rollback deleted a metadata-selected arbitrary directory"
  assert_not_grep 'lease release' "$AF_LOG" "unsafe tasktmp validation ran after lease release"
  assert_contains "$out" "unsafe task temp path" "unsafe rollback tasktmp refusal was unclear"
  pass "secondmate rollback only removes its exact task temp root"
}

test_rollback_backup_rejects_symlink_and_rechecks_under_lock() {
  local id rec sm expected backup_name backup target out status
  id=account-secondmate-backup-z18eb
  rec=$(make_case secondmate-backup claude "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$sm" \
    "project=$sm" \
    "home=$sm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate"
  expected="$CASE_DIR/original.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback backup precondition unexpectedly succeeded"
  backup_name=$(sed -n 's/^account_rollback_backup=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  backup="$HOME_DIR/state/$backup_name"
  assert_present "$backup" "rollback backup precondition did not create metadata backup"

  rm -f "$backup"
  ln -s "$expected" "$backup"
  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback accepted a symlinked metadata backup"
  assert_not_grep 'lease release' "$AF_LOG" "initial symlinked backup validation ran after lease release"
  assert_contains "$out" "rollback backup is missing" "symlinked rollback backup refusal was unclear"

  rm -f "$backup"
  cp "$expected" "$backup"
  target="$CASE_DIR/swap-target.meta"
  cp "$expected" "$target"
  clear_case_logs
  out=$(FM_FAKE_AF_RELEASE_SWAP_BACKUP="$backup" FM_FAKE_AF_RELEASE_SWAP_TARGET="$target" \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback followed a backup swapped to a symlink after validation"
  [ -L "$backup" ] || fail "rollback backup swap test did not install its symlink"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" \
    "post-validation backup swap restored unrelated metadata"
  assert_contains "$out" "rollback backup is missing" "under-lock backup recheck refusal was unclear"
  pass "rollback metadata backups reject symlinks before and under lock"
}

test_failed_secondmate_respawn_rollback_restores_prior_state() {
  local id rec sm expected out status artifact
  id=account-secondmate-restore-z18f
  rec=$(make_case secondmate-restore claude "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$sm" \
    "project=$sm" \
    "home=$sm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "custom_extension=preserve-secondmate"
  expected="$CASE_DIR/original-secondmate.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'prior-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done

  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed secondmate respawn precondition unexpectedly succeeded"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed secondmate respawn lost cleanup metadata"

  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate rollback cleanup continued through a restored generation"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" || fail "secondmate rollback cleanup deleted or changed restored metadata"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "prior-$artifact" ] \
      || fail "secondmate rollback cleanup deleted restored $artifact state"
  done
  assert_contains "$out" "previous task state was restored" "secondmate rollback restoration guidance was unclear"
  assert_present "$sm/.fm-secondmate-home" "secondmate rollback cleanup retired the persistent home"
  pass "failed secondmate respawn rollback preserves restored metadata and sidecars"
}

test_observe_invalid_response_remains_advisory() {
  local id rec out status launch
  id=account-observe-invalid-z19
  rec=$(make_case observe-invalid claude "$id")
  read_case "$rec"
  out=$(FM_ACCOUNT_ROUTING=observe FM_FAKE_AF_BAD_SELECTION=1 run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "invalid observe response should preserve legacy spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ' claude --dangerously-skip-permissions ' "invalid observe response changed launch"
  assert_not_grep 'lease release' "$AF_LOG" "observe response attempted lease cleanup"
  assert_contains "$out" "observe decision invalid" "observe validation failure was not surfaced"
  pass "observe mode remains non-blocking on malformed decisions"
}

test_explicit_secondmate_profile_ignores_configured_pool() {
  local id rec sm out status
  id=account-secondmate-profile-z20
  rec=$(make_case secondmate-profile claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_FAKE_AF_POOL=explicit FM_FAKE_AF_PROFILE=claude-9 FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --account-profile claude-9)
  status=$?
  [ "$status" -eq 0 ] || fail "explicit secondmate profile failed: $out"
  assert_regex 'lease acquire --profile claude-9 --task .* --pool explicit' "$AF_LOG" "explicit secondmate profile inherited the configured pool"
  assert_regex '^account_pool=explicit$' "$HOME_DIR/state/$id.meta" "explicit secondmate profile meta retained the configured pool"
  pass "an explicit secondmate profile fully overrides pool policy"
}

test_enforced_orca_is_rejected_before_owned_resource_creation() {
  local id rec out status
  id=account-orca-z20b
  rec=$(make_case orca claude "$id")
  read_case "$rec"
  mkdir -p "$CASE_DIR/legacy-wt"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=legacy:fm-$id" \
    "worktree=$CASE_DIR/legacy-wt" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  out=$(run_spawn "$id" "$PROJ_DIR" --backend orca --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "enforced Orca spawn unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "enforced Orca spawn acquired an Agent Fleet lease"
  assert_not_grep '^worktree ' "$ORCA_LOG" "enforced Orca spawn created a worktree"
  assert_contains "$out" "does not support backend=orca" "enforced Orca blocker was unclear"
  pass "enforced account routing refuses Orca before creating owned resources"
}

test_cross_profile_continuation_for_harness() {
  local harness=$1 old_profile=$2 new_profile=$3 provider=$4 id rec old_task new_task new_attempt packet canonical out status launch source_model
  id="account-continue-$harness-z21"
  rec=$(make_case "continue-$harness" "$harness" "$id")
  read_case "$rec"
  source_model="$harness-source-model"
  out=$(FM_FAKE_AF_PROVIDER="$provider" FM_FAKE_AF_PROFILE="$old_profile" FM_FAKE_AF_POOL="$harness-crew" \
    run_spawn "$id" "$PROJ_DIR" --account-pool "$harness-crew" --model "$source_model" --effort high)
  status=$?
  [ "$status" -eq 0 ] || fail "$harness initial managed spawn failed: $out"
  old_task=$(meta_account_task "$id")
  printf 'done: external side effect alpha; do not rerun\nnext: verify beta\n' > "$HOME_DIR/state/$id.status"
  printf '# Completion\n\nShip completion evidence for %s.\n' "$harness" > "$HOME_DIR/data/$id/completion.md"
  printf '# Decisions\n\n- Keep the existing branch.\n' > "$HOME_DIR/data/$id/decisions.md"
  printf '# Steering trail\n\n- 2026-07-15T00:00:00Z\n\n> Preserve the verified next action for %s.\n' \
    "$harness" > "$HOME_DIR/data/$id/steering.md"
  assert_grep "Preserve the verified next action for $harness." "$HOME_DIR/data/$id/steering.md" "$harness managed steering was not recorded"
  printf '# Pending steering audit\n\n- Preserve pending delivery for %s.\n' "$harness" > "$HOME_DIR/data/$id/steering-pending.md"
  printf '# Steering journal\n\n- Preserve journal delivery for %s.\n' "$harness" > "$HOME_DIR/data/$id/steering-journal.md"
  printf '# Unconfirmed steering\n\n- 2026-07-15T00:00:00Z (delivery unconfirmed)\n\n> Preserve unconfirmed delivery for %s.\n' \
    "$harness" > "$HOME_DIR/data/$id/steering-unconfirmed.md"
  printf '# Completed side effects\n\n- Preserve completed side effects for %s.\n' "$harness" > "$HOME_DIR/data/$id/side-effects.md"
  printf '# Do not rerun\n\n- Preserve do-not-rerun state for %s.\n' "$harness" > "$HOME_DIR/data/$id/do-not-rerun.md"
  printf '# Next action\n\n- Preserve next action for %s.\n' "$harness" > "$HOME_DIR/data/$id/next-action.md"
  printf '# Checkpoint\n\n- Preserve checkpoint for %s.\n' "$harness" > "$HOME_DIR/data/$id/checkpoint.md"
  printf '# Handoff\n\n- Preserve handoff for %s.\n' "$harness" > "$HOME_DIR/data/$id/handoff.md"
  printf '# Recalled context\n\n- Preserve recalled context for %s.\n' "$harness" > "$HOME_DIR/data/$id/recalled.md"
  printf '# Provider transcript summary\n\n- Preserve transcript summary for %s.\n' "$harness" > "$HOME_DIR/data/$id/transcript-summary.md"
  printf '\n- Preserve account lineage for %s.\n' "$harness" >> "$HOME_DIR/data/$id/account-attempts.md"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(FM_FAKE_AF_PROVIDER="$provider" FM_FAKE_AF_PROFILE="$new_profile" FM_FAKE_AF_POOL=explicit run_spawn "$id" --continue-account --account-profile "$new_profile")
  status=$?
  [ "$status" -eq 0 ] || fail "$harness cross-profile continuation failed: $out"
  new_task=$(meta_account_task "$id")
  new_attempt=$(sed -n 's/^account_attempt=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  [ "$new_task" != "$old_task" ] || fail "$harness continuation reused a stale launch generation"
  packet=$(sed -n 's/^continuation_packet=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  assert_present "$packet" "$harness continuation packet was not persisted"
  canonical="$HOME_DIR/data/$id/continuation-$new_attempt.md"
  [ "$packet" != "$canonical" ] || fail "$harness continuation launch retained the replaceable canonical packet path"
  case "${packet##*/}" in
    "continuation-$new_attempt.generation-"*.md) ;;
    *) fail "$harness continuation did not pin an immutable launch generation" ;;
  esac
  assert_grep 'done: external side effect alpha; do not rerun' "$packet" "$harness continuation packet lost completed side-effect state"
  assert_grep "Ship completion evidence for $harness." "$packet" "$harness continuation packet lost ship completion evidence"
  assert_grep 'Keep the existing branch' "$packet" "$harness continuation packet lost decisions"
  assert_grep "Preserve the verified next action for $harness." "$packet" "$harness continuation packet lost steering"
  assert_grep "Preserve pending delivery for $harness." "$packet" "$harness continuation packet lost pending steering audit"
  assert_regex '^## Unconfirmed steering$' "$packet" "$harness continuation did not separate unconfirmed steering"
  assert_grep "Preserve unconfirmed delivery for $harness." "$packet" "$harness continuation lost unconfirmed steering"
  python3 - "$packet" "$harness" <<'PY' \
    || fail "$harness continuation snapshot sections no longer match their source artifacts"
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
harness = sys.argv[2]
sections = {
    match.group(1): match.group(2)
    for match in re.finditer(r"^## ([^\n]+)\n(.*?)(?=^## |\Z)", source, re.MULTILINE | re.DOTALL)
}
expected = {
    "Steering journal": f"Preserve journal delivery for {harness}.",
    "Unconfirmed steering": f"Preserve unconfirmed delivery for {harness}.",
    "Completed side effects": f"Preserve completed side effects for {harness}.",
    "Do not rerun": f"Preserve do-not-rerun state for {harness}.",
    "Next action": f"Preserve next action for {harness}.",
    "Checkpoint": f"Preserve checkpoint for {harness}.",
    "Handoff": f"Preserve handoff for {harness}.",
    "Recalled context": f"Preserve recalled context for {harness}.",
    "Provider transcript summary": f"Preserve transcript summary for {harness}.",
    "Account attempt lineage": f"Preserve account lineage for {harness}.",
}
for heading, marker in expected.items():
    if marker not in sections.get(heading, ""):
        raise SystemExit(f"{heading} omitted or contains the wrong source")
PY
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "$new_profile" "$harness continuation did not use the new profile"
  assert_contains "$launch" "$new_task" "$harness continuation did not use the new launch generation"
  assert_contains "$launch" "fm-prompt-exec.py" \
    "$harness continuation did not use the verified provider-native prompt launcher"
  assert_not_contains "$launch" "__fm_continuation_prompt" \
    "$harness continuation still round-tripped prompt bytes through a shell variable"
  assert_not_contains "$launch" "cat '$packet'" \
    "$harness continuation launch still rereads its generation by pathname"
  printf 'replacement generation\n' > "$canonical.replacement"
  mv "$canonical.replacement" "$canonical"
  assert_grep 'done: external side effect alpha; do not rerun' "$packet" \
    "$harness continuation launch snapshot changed with its canonical audit path"
  printf 'replacement launch generation\n' > "$packet.replacement"
  mv "$packet.replacement" "$packet"
  assert_not_contains "$launch" 'replacement launch generation' \
    "$harness launch consumed replacement bytes from its generation pathname"
  assert_contains "$launch" "$source_model" "$harness same-provider continuation lost its inherited model"
  assert_regex '^effort=high$' "$HOME_DIR/state/$id.meta" "$harness same-provider continuation lost its inherited effort"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "$harness continuation did not release its predecessor after binding"
  assert_grep "session remove --task $old_task" "$AF_LOG" "$harness continuation did not remove its predecessor mapping"
  assert_grep "agent_fleet_task=$new_task" "$HOME_DIR/data/$id/account-attempts.md" "$harness continuation lineage lost the new attempt"
  pass "$harness can continue safely under a different account profile"
}

test_cross_provider_continuation_uses_target_default_pool() {
  local source=$1 target=$2 id rec old_task out status source_model launch
  id="account-continue-$source-to-$target-z21a"
  rec=$(make_case "continue-$source-to-$target" "$source" "$id")
  read_case "$rec"
  source_model="$source-source-model"
  out=$(FM_FAKE_AF_PROVIDER="$source" FM_FAKE_AF_PROFILE="$source-2" FM_FAKE_AF_POOL="$source-crew" \
    run_spawn "$id" "$PROJ_DIR" --account-pool "$source-crew" --model "$source_model" --effort high)
  status=$?
  [ "$status" -eq 0 ] || fail "$source initial managed spawn failed: $out"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_PROVIDER="$target" FM_FAKE_AF_PROFILE="$target-2" FM_FAKE_AF_POOL="$target-crew" \
    run_spawn "$id" --continue-account --harness "$target")
  status=$?
  [ "$status" -eq 0 ] || fail "$source-to-$target continuation failed: $out"
  assert_regex "lease choose --pool $target-crew --task .*-$id-.* --provider $target" "$AF_LOG" \
    "$source-to-$target continuation did not select the target provider's default pool"
  assert_not_grep "lease choose --pool $source-crew" "$AF_LOG" \
    "$source-to-$target continuation inherited the predecessor provider's pool"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "$source_model" "$source-to-$target continuation inherited the source provider's model"
  assert_regex '^model=default$' "$HOME_DIR/state/$id.meta" "$source-to-$target continuation did not restore the target model default"
  assert_regex '^effort=default$' "$HOME_DIR/state/$id.meta" "$source-to-$target continuation did not restore the target effort default"
  assert_grep "predecessor=$old_task" "$HOME_DIR/data/$id/account-attempts.md" \
    "$source-to-$target continuation lost predecessor lineage"
  pass "$source-to-$target continuation resolves the target provider pool"
}

test_continuation_refuses_unknown_endpoint_state() {
  local id rec old_task out status meta_tmp
  id=account-continuation-unknown-z21aa
  rec=$(make_case continuation-unknown claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "unknown continuation precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_TARGET_STATE=unknown FM_FAKE_TMUX_LIST_WINDOWS_UNKNOWN=1 FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" direct-unknown 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation packet builder accepted an unknown predecessor endpoint"
  assert_contains "$out" "endpoint state is unknown" "packet builder's unknown endpoint blocker was unclear"

  out=$(FM_FAKE_TARGET_STATE=unknown FM_FAKE_TMUX_LIST_WINDOWS_UNKNOWN=1 run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted an unknown predecessor endpoint"
  assert_contains "$out" "endpoint state is unknown" "unknown continuation blocker was unclear"
  assert_not_grep 'lease choose\|lease acquire\|lease release' "$AF_LOG" "unknown continuation mutated Agent Fleet state"
  assert_grep "account_task=$old_task" "$HOME_DIR/state/$id.meta" "unknown continuation changed predecessor metadata"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unknown continuation created a replacement endpoint"

  meta_tmp="$HOME_DIR/state/.$id.meta.missing-target"
  grep -Ev '^(window|tmux_window_id)=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  clear_case_logs
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" direct-missing 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation packet builder accepted missing endpoint metadata"
  assert_contains "$out" "endpoint state is unknown" "missing continuation endpoint did not fail closed"

  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted missing endpoint metadata"
  assert_contains "$out" "endpoint state is unknown" "managed recovery skipped its missing endpoint"
  assert_not_grep 'lease choose\|lease acquire\|lease release' "$AF_LOG" "missing endpoint recovery mutated Agent Fleet state"
  assert_not_grep '^new-window ' "$TMUX_LOG" "missing endpoint recovery created a replacement endpoint"
  pass "continuation requires a recorded endpoint with confirmed absence"
}

test_missing_endpoint_target_retains_managed_lease() {
  local id rec out status meta_tmp account_task
  id=account-missing-endpoint-z21ab
  rec=$(make_case missing-endpoint claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "missing endpoint teardown precondition spawn failed"
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  meta_tmp="$HOME_DIR/state/.$id.meta.missing-target"
  grep -Ev '^(window|tmux_window_id)=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  clear_case_logs

  out=$(run_teardown "$id" --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "managed teardown released a lease with missing endpoint metadata"
  assert_contains "$out" "endpoint state for $id is unknown" "missing teardown endpoint did not report its blocker"
  assert_not_grep "lease release --task $account_task" "$AF_LOG" "missing teardown endpoint released its Agent Fleet lease"
  assert_present "$HOME_DIR/state/$id.meta" "missing teardown endpoint lost retry metadata"
  pass "managed teardown retains leases when endpoint identity is missing"
}

test_predecessor_cleanup_failure_preserves_replacement_for_retry() {
  local id rec old_task new_task fail_once out status
  id=account-predecessor-retry-z21b
  rec=$(make_case predecessor-retry claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "predecessor cleanup precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  fail_once="$CASE_DIR/session-remove-failed"

  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE="$fail_once" \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "predecessor session cleanup failure was hidden"
  new_task=$(meta_account_task "$id")
  [ "$new_task" != "$old_task" ] || fail "replacement attempt was not installed before predecessor cleanup"
  assert_present "$CASE_DIR/endpoint-live" "predecessor cleanup failure killed the healthy replacement endpoint"
  assert_grep 'account_predecessor_cleanup=pending' "$HOME_DIR/state/$id.meta" "predecessor cleanup failure lost its retry marker"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "predecessor lease release was not attempted"
  assert_not_grep "lease release --task $new_task --force" "$AF_LOG" "predecessor cleanup failure rolled back the healthy replacement lease"
  assert_contains "$out" "cleanup remains pending" "predecessor cleanup failure was not explicit"

  clear_case_logs
  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE="$fail_once" \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "predecessor cleanup retry failed: $out"
  assert_contains "$out" "completed predecessor Agent Fleet cleanup" "predecessor cleanup retry did not report completion"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "predecessor cleanup retry created another replacement generation"
  assert_not_grep '^new-window ' "$TMUX_LOG" "predecessor cleanup retry created another endpoint"
  assert_not_grep '^account_predecessor_' "$HOME_DIR/state/$id.meta" "predecessor cleanup retry left pending metadata"
  assert_grep "account_task=$new_task" "$HOME_DIR/state/$id.meta" "predecessor cleanup retry changed the healthy replacement"
  pass "predecessor cleanup retries without destroying the verified replacement"
}

test_failed_continuation_cleanup_restores_predecessor_for_retry() {
  local id rec old_task failed_task final_task out status
  id=account-continuation-rollback-z21c
  rec=$(make_case continuation-rollback claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation rollback precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "unbound continuation with failed cleanup unexpectedly succeeded"
  failed_task=$(meta_account_task "$id")
  [ "$failed_task" != "$old_task" ] || fail "failed continuation never installed its cleanup generation"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed continuation cleanup lost its retry marker"
  assert_grep "account_predecessor_task=$old_task" "$HOME_DIR/state/$id.meta" "failed continuation cleanup lost predecessor identity"

  clear_case_logs
  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "continuation retry could not clean and replace its failed generation: $out"
  final_task=$(meta_account_task "$id")
  [ "$final_task" != "$old_task" ] && [ "$final_task" != "$failed_task" ] || fail "continuation retry did not create a fresh generation"
  assert_grep "lease release --task $failed_task --force" "$AF_LOG" "continuation retry did not clean its failed lease"
  assert_grep "session remove --task $failed_task" "$AF_LOG" "continuation retry did not clean its failed mapping"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "continuation retry did not clean its restored predecessor"
  assert_not_grep '^account_rollback_' "$HOME_DIR/state/$id.meta" "continuation retry retained rollback metadata"
  pass "failed continuation cleanup restores predecessor state before retry"
}

test_concurrent_continuations_serialize_before_mutation() {
  local id rec marker gate first_pid second_pid first_rc second_rc lease_count endpoint_count second_lock_waiter
  id=account-continuation-race-z21d
  rec=$(make_case continuation-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  marker="$CASE_DIR/first-endpoint-started"
  gate="$CASE_DIR/allow-first-endpoint"

  FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_TMUX_NEW_WINDOW_MARKER="$marker" FM_FAKE_TMUX_NEW_WINDOW_GATE="$gate" \
    run_spawn "$id" --continue-account --account-profile claude-3 > "$CASE_DIR/first.out" 2>&1 &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$marker" ] && break
    sleep 0.05
  done
  [ -f "$marker" ] || { kill "$first_pid" 2>/dev/null || true; fail "first continuation never reached endpoint creation"; }
  FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit \
    run_spawn "$id" --continue-account --account-profile claude-3 > "$CASE_DIR/second.out" 2>&1 &
  second_pid=$!
  second_lock_waiter=
  for _ in $(seq 1 100); do
    second_lock_waiter=$(find "$HOME_DIR/state" -maxdepth 1 -type f \
      -name ".account-lifecycle-$id.owner.*" -print -quit)
    [ -n "$second_lock_waiter" ] && break
    sleep 0.05
  done
  if [ -z "$second_lock_waiter" ]; then
    touch "$gate"
    kill "$first_pid" "$second_pid" 2>/dev/null || true
    fail "second continuation never waited behind the first lifecycle owner"
  fi
  touch "$gate"
  wait "$first_pid"
  first_rc=$?
  wait "$second_pid"
  second_rc=$?
  [ "$first_rc" -eq 0 ] || fail "first serialized continuation failed: $(cat "$CASE_DIR/first.out")"
  [ "$second_rc" -ne 0 ] || fail "second concurrent continuation also launched"
  assert_grep 'managed recovery endpoint is still alive' "$CASE_DIR/second.out" "concurrent continuation did not revalidate the serialized replacement endpoint"
  lease_count=$(grep -Ec 'lease choose|lease acquire' "$AF_LOG" || true)
  endpoint_count=$(grep -c '^new-window ' "$TMUX_LOG" || true)
  [ "$lease_count" -eq 1 ] || fail "concurrent continuations acquired $lease_count leases"
  [ "$endpoint_count" -eq 1 ] || fail "concurrent continuations created $endpoint_count endpoints"
  pass "continuation generation locking serializes before endpoint and lease mutation"
}

test_live_secondmate_recovery_precedes_home_convergence() {
  local id rec sm out status
  id=account-secondmate-live-recovery-z21e
  rec=$(make_case secondmate-live-recovery claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  run_spawn "$id" "$sm" --secondmate --account-pool claude-crew >/dev/null \
    || fail "live secondmate recovery precondition spawn failed"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = claude ] \
    || fail "secondmate recovery precondition did not inherit the initial config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  clear_case_logs

  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "live secondmate recovery unexpectedly created a duplicate"
  assert_contains "$out" "managed recovery endpoint is still alive" "live secondmate recovery did not fail at endpoint validation"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = claude ] \
    || fail "live secondmate recovery converged child config before endpoint validation"
  pass "managed secondmate recovery validates liveness before home convergence"
}

test_continuation_fails_closed_without_original_brief() {
  local id rec out status
  id=account-continue-nobrief-z22
  rec=$(make_case continue-nobrief claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "account_pool=claude-crew" \
    "account_profile=claude-2" \
    "account_task=$id" \
    "account_attempt=legacy" \
    "provider_session_id=sess-$id"
  rm -f "$HOME_DIR/data/$id/brief.md"
  clear_case_logs
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" missing-brief 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation without original brief unexpectedly succeeded"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unsafe continuation created an endpoint"
  [ ! -s "$AF_LOG" ] || fail "unsafe continuation acquired a lease"
  assert_contains "$out" "no safe non-empty original brief" "unsafe continuation blocker was unclear"
  pass "provider-neutral continuation fails closed without a safe task packet"
}

test_session_sync_cannot_recreate_metadata_after_teardown() {
  local id rec release_marker sync_pid teardown_pid sync_rc teardown_rc meta_tmp
  id=account-sync-race-z23
  rec=$(make_case sync-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session sync race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  release_marker="$CASE_DIR/lease-released"
  FM_FAKE_AF_RELEASE_MARKER="$release_marker" FM_FAKE_TREEHOUSE_SLEEP=1 \
    run_teardown "$id" --force > "$CASE_DIR/teardown-stdout" 2> "$CASE_DIR/teardown-stderr" &
  teardown_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$release_marker" ] && break
    sleep 0.1
  done
  [ -f "$release_marker" ] || { kill "$teardown_pid" 2>/dev/null || true; fail "session sync race never reached managed account cleanup"; }
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require > "$CASE_DIR/sync-stdout" 2> "$CASE_DIR/sync-stderr" &
  sync_pid=$!
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  wait "$sync_pid"
  sync_rc=$?
  set -e
  expect_code 0 "$teardown_rc" "session sync race teardown should succeed while holding the metadata lock"
  [ "$sync_rc" -ne 0 ] || fail "late SessionStart sync unexpectedly succeeded after teardown"
  assert_absent "$HOME_DIR/state/$id.meta" "late SessionStart sync recreated metadata after teardown"
  assert_absent "$HOME_DIR/state/.account-meta-$id.lock" "session sync race left the metadata lock behind"
  pass "session synchronization cannot recreate metadata after teardown"
}

test_managed_steering_audit_failure_does_not_reclassify_delivery() {
  local id rec out status
  id=account-steering-audit-z24
  rec=$(make_case steering-audit claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "steering audit precondition spawn failed"
  mkdir "$HOME_DIR/data/$id/steering.md"
  clear_case_logs
  touch "$CASE_DIR/endpoint-live"

  out=$(run_send "$id" "This delivered steer must not be retried." 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "unconfirmed steering delivery returned an unsafe retry signal: $out"
  assert_contains "$out" "could not be confirmed" "audit failure warning overstated delivery truth"
  assert_grep 'This delivered steer must not be retried' "$LAUNCH_LOG" "steering text was not submitted before confirmation failed"
  assert_grep 'This delivered steer must not be retried' "$HOME_DIR/data/$id/steering-unconfirmed.md" \
    "unconfirmed steering was not durably recorded for reconciliation"
  pass "unconfirmed steering is durably spooled without returning a retry signal"
}

test_managed_tmux_identity_survives_window_rename() {
  local id rec out status
  id=account-tmux-identity-z25
  rec=$(make_case tmux-identity claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "stable tmux identity precondition spawn failed"
  assert_regex '^window=firstmate:fm-account-tmux-identity-z25$' "$HOME_DIR/state/$id.meta" "managed tmux metadata lost its user-facing window label"
  assert_regex '^tmux_window_id=%77$' "$HOME_DIR/state/$id.meta" "managed tmux metadata did not persist the stable window id"
  clear_case_logs

  set +e
  out=$(FM_FAKE_TMUX_RENAMED=1 FM_FAKE_TMUX_KILL_FAIL=1 run_teardown "$id" --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "renamed live tmux endpoint allowed managed teardown"
  assert_not_grep 'lease release' "$AF_LOG" "renamed live tmux endpoint released its Agent Fleet lease"
  assert_present "$HOME_DIR/state/$id.meta" "renamed live tmux endpoint lost its recovery metadata"
  [ -n "$out" ] || true
  pass "managed tmux lifecycle uses rename-stable endpoint identity"
}

test_native_resume_accepts_regressed_wallclock_when_event_sequence_advances() {
  local id rec out status
  id=account-resume-regressed-z26
  rec=$(make_case resume-regressed claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "regressed resume precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  if out=$(FM_FAKE_AF_UPDATED_AT_BEFORE=2026-07-13T00:00:01Z FM_FAKE_AF_UPDATED_AT_AFTER=2026-07-13T00:00:00Z \
    run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "native resume rejected an advanced event sequence because its diagnostic timestamp regressed: $out"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$id.meta" \
    "regressed-wallclock native resume lost its provider session binding"
  pass "native resume freshness depends only on the monotonic SessionStart event sequence"
}

test_session_sync_metadata_publish_failure_is_closed() {
  local id rec meta_tmp before_lineage after_lineage failbin out status
  id=account-sync-publish-z27
  rec=$(make_case sync-publish claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session publish precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  before_lineage=$(grep -c 'event=session-bound' "$HOME_DIR/data/$id/account-attempts.md")
  failbin="$CASE_DIR/failbin"
  mkdir -p "$failbin"
  cat > "$failbin/mv" <<'SH'
#!/usr/bin/env bash
case "$*" in *'.meta.sync.'*) exit 71 ;; esac
exec /bin/mv "$@"
SH
  chmod +x "$failbin/mv"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    FM_ACCOUNT_TEST_HOOKS=firstmate-account-tests-v1 FM_TEST_ACCOUNT_MV_BIN="$failbin/mv" \
    PATH="$failbin:$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "session sync reported success after metadata replacement failed"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" "failed session publication changed durable metadata"
  after_lineage=$(grep -c 'event=session-bound' "$HOME_DIR/data/$id/account-attempts.md")
  [ "$after_lineage" -eq "$before_lineage" ] || fail "failed session publication appended lineage before durable metadata"
  [ -n "$out" ] || true
  pass "session synchronization fails closed on metadata publication"
}

test_session_sync_lineage_failure_restores_unbound_metadata() {
  local id rec meta_tmp lineage saved before_lineage after_lineage out status
  id=account-sync-lineage-z27a
  rec=$(make_case sync-lineage claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session lineage precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  lineage="$HOME_DIR/data/$id/account-attempts.md"
  saved="$CASE_DIR/account-attempts.saved"
  before_lineage=$(grep -c 'event=session-bound' "$lineage")
  mv "$lineage" "$saved"
  mkdir "$lineage"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "session sync reported success after lineage publication failed"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" "failed lineage publication left durable session binding"
  assert_contains "$out" 'restored unbound metadata' "failed lineage publication did not report metadata rollback"

  rmdir "$lineage"
  mv "$saved" "$lineage"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require >/dev/null \
    || fail "session sync retry could not publish binding and lineage"
  assert_regex '^provider_session_id=' "$HOME_DIR/state/$id.meta" "session sync retry did not restore durable binding"
  after_lineage=$(grep -c 'event=session-bound' "$lineage")
  [ "$after_lineage" -eq $((before_lineage + 1)) ] || fail "session sync retry did not append exactly one lineage event"
  pass "session synchronization rolls back binding when lineage publication fails"
}

test_oversized_continuation_stops_before_mutation() {
  local id rec out status later_source
  id=account-continuation-size-z28
  rec=$(make_case continuation-size claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation size precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"

  # Sentinel control: the wake-status source is assembled after the brief, and
  # a symlink planted there is refused with an observable error while the
  # packet budget still has room, so the ordering probe below can rely on that
  # error's absence.
  later_source="$CASE_DIR/later-source"
  printf 'later source\n' > "$later_source"
  ln -s "$later_source" "$HOME_DIR/state/$id.status"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" ordering-control 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "symlinked wake-status continuation source was accepted"
  assert_contains "$out" 'refusing symlinked continuation source' "sentinel wake-status refusal was not observable"
  assert_absent "$HOME_DIR/data/$id/continuation-ordering-control.md" "sentinel control run installed a continuation packet"

  # Ordering probe: the brief section is assembled before the wake-status
  # source, so once an oversized brief already exhausts the packet budget the
  # later wake-status sentinel must never be opened or inspected.
  dd if=/dev/zero bs=70000 count=1 2>/dev/null | tr '\0' b > "$HOME_DIR/data/$id/brief.md"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" ordering-probe 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "oversized continuation packet was accepted by the ordering probe"
  assert_contains "$out" 'maximum is 65536' "ordering probe rejection did not report its bound"
  assert_not_contains "$out" 'symlinked continuation source' "continuation inspected later artifacts after the packet budget was already exhausted"
  assert_absent "$HOME_DIR/data/$id/continuation-ordering-probe.md" "ordering probe installed a packet after the budget was exhausted"

  # Full spawn path: an oversized wake-status is rejected before any external
  # mutation.
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  rm -f "$HOME_DIR/state/$id.status"
  dd if=/dev/zero bs=70000 count=1 2>/dev/null | tr '\0' x > "$HOME_DIR/state/$id.status"
  clear_case_logs

  set +e
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "oversized continuation packet was accepted"
  assert_contains "$out" 'maximum is 65536' "oversized continuation rejection did not report its bound"
  assert_not_grep '^new-window ' "$TMUX_LOG" "oversized continuation created a replacement endpoint"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "oversized continuation acquired an Agent Fleet lease"
  pass "continuation packet size is bounded before external mutation"
}

test_continuation_bounds_no_mistakes_status_snapshot() {
  local id rec out status started finished elapsed_ms packet
  id=account-continuation-status-timeout-z28a
  rec=$(make_case continuation-status-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation timeout precondition spawn failed"
  cat > "$FAKEBIN_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'partial status that must not survive timeout\n'
trap '' TERM
sleep 10
SH
  chmod +x "$FAKEBIN_DIR/no-mistakes"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  started=$(python3 -c 'import time; print(time.monotonic_ns())')
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" status-timeout 2>&1)
  status=$?
  finished=$(python3 -c 'import time; print(time.monotonic_ns())')
  elapsed_ms=$(( (finished - started) / 1000000 ))
  [ "$status" -eq 0 ] || fail "continuation failed instead of degrading a timed-out no-mistakes snapshot: $out"
  [ "$elapsed_ms" -lt 6000 ] \
    || fail "continuation no-mistakes snapshot exceeded its bounded path (elapsed ${elapsed_ms}ms)"
  packet=$(printf '%s\n' "$out" | tail -1)
  assert_present "$packet" "timed-out status continuation packet was not persisted"
  assert_grep '## No-mistakes state' "$packet" "timed-out continuation packet lost the no-mistakes section"
  if ! grep -qxF unavailable "$packet"; then
    sed -n '/## No-mistakes state/,+6p' "$packet" >&2
    fail "timed-out no-mistakes snapshot did not degrade to unavailable"
  fi
  pass "continuation bounds no-mistakes status collection and degrades on timeout"
}

test_continuation_caps_informational_snapshots_only() {
  local id rec out status packet packet_bytes brief_bytes
  id=account-continuation-snapshot-cap-z28b
  rec=$(make_case continuation-snapshot-cap claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation snapshot cap precondition spawn failed"
  cat > "$FAKEBIN_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
trap '' PIPE
head -c 100000 /dev/zero | tr '\0' s
exit 42
SH
  chmod +x "$FAKEBIN_DIR/no-mistakes"
  rm -f "$CASE_DIR/endpoint-live"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" capped-snapshot 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "oversized informational snapshot was not capped: $out"
  packet=$out
  assert_present "$packet" "capped informational snapshot packet was not installed"
  assert_grep '[Snapshot truncated at 8192 bytes.]' "$packet" "capped informational snapshot had no visible truncation marker"
  packet_bytes=$(wc -c < "$packet" | tr -d '[:space:]')
  [ "$packet_bytes" -le 65536 ] || fail "capped informational snapshot exceeded the packet budget ($packet_bytes bytes)"

  dd if=/dev/zero bs=70000 count=1 2>/dev/null | tr '\0' b > "$HOME_DIR/data/$id/brief.md"
  brief_bytes=$(wc -c < "$HOME_DIR/data/$id/brief.md" | tr -d '[:space:]')
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" oversized-brief 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "oversized task-owned continuation source was truncated instead of rejected"
  assert_contains "$out" 'maximum is 65536' "oversized task-owned continuation rejection did not report its bound"
  assert_absent "$HOME_DIR/data/$id/continuation-oversized-brief.md" "oversized task-owned continuation source installed a truncated packet"
  [ "$(wc -c < "$HOME_DIR/data/$id/brief.md" | tr -d '[:space:]')" = "$brief_bytes" ] \
    || fail "oversized task-owned continuation source was modified"
  pass "continuation caps informational snapshots and rejects task-owned overflow"
}

test_continuation_rejects_symlinked_packet_destination() {
  local id rec outside packet out status
  id=account-continuation-destination-z28c
  rec=$(make_case continuation-destination claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation destination precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  outside="$CASE_DIR/outside-packets"
  packet="$HOME_DIR/data/$id/continuation-symlink-destination.md"
  mkdir "$outside"
  ln -s "$outside" "$packet"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" symlink-destination 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "continuation accepted a symlinked packet destination"
  assert_contains "$out" 'unsafe continuation packet destination' "symlinked packet destination refusal was unclear"
  assert_present "$packet" "continuation replaced the unsafe destination symlink"
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "continuation moved its packet through the destination symlink"
  pass "continuation rejects symlinked packet destinations"
}

test_continuation_pins_packet_destination_directory() {
  local id rec ready proceed output moved outside packet_pid status
  id=account-continuation-destination-race-z28f
  rec=$(make_case continuation-destination-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation destination-race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-destination.ready"
  proceed="$CASE_DIR/continuation-destination.proceed"
  output="$CASE_DIR/continuation-destination.out"
  moved="$HOME_DIR/data/$id.original"
  outside="$CASE_DIR/continuation-outside"
  mkdir "$outside"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" destination-race > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "continuation destination race gate did not open"; }
  mv "$HOME_DIR/data/$id" "$moved"
  ln -s "$outside" "$HOME_DIR/data/$id"
  touch "$proceed"
  wait "$packet_pid"
  status=$?
  [ "$status" -ne 0 ] || fail "continuation installed a packet after its task directory was replaced"
  assert_contains "$(cat "$output")" 'continuation task directory changed' "destination replacement refusal was unclear"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail "continuation redirected packet bytes outside the pinned task directory"
  assert_absent "$moved/continuation-destination-race.md" "continuation left a packet in a disconnected task generation"
  rm "$HOME_DIR/data/$id"
  mv "$moved" "$HOME_DIR/data/$id"
  pass "continuation stages and installs packets through one pinned task directory"
}

test_continuation_revalidates_repository_anchor_before_install() {
  local id rec ready proceed output packet_pid status packet worktree
  id=account-continuation-repository-race-z28g
  rec=$(make_case continuation-repository-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "continuation repository-race precondition spawn failed"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-repository.ready"
  proceed="$CASE_DIR/continuation-repository.proceed"
  output="$CASE_DIR/continuation-repository.out"
  packet="$HOME_DIR/data/$id/continuation-repository-race.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" repository-race > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "continuation repository race gate did not open"; }
  git -C "$worktree" checkout -q -b continuation-replacement-anchor
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation installed a packet after its repository anchor changed"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "repository anchor replacement refusal was unclear"
  assert_absent "$packet" "repository anchor replacement installed a stale continuation packet"
  pass "continuation revalidates worktree identity, branch, and HEAD before installation"
}

test_continuation_revalidates_exact_repository_status_before_install() {
  local id rec ready proceed output packet_pid status packet worktree
  id=account-continuation-status-race-z28h
  rec=$(make_case continuation-status-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "continuation status-race precondition spawn failed"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-status.ready"
  proceed="$CASE_DIR/continuation-status.proceed"
  output="$CASE_DIR/continuation-status.out"
  packet="$HOME_DIR/data/$id/continuation-status-race.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" status-race > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "continuation status race gate did not open"; }
  printf 'late uncommitted bytes\n' > "$worktree/late-uncommitted.txt"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation installed a packet after repository status changed"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "repository status replacement refusal was unclear"
  assert_absent "$packet" "repository status replacement installed a stale continuation packet"
  pass "continuation revalidates the exact index and worktree status before installation"
}

test_continuation_revalidates_dirty_tracked_content_before_install() {
  local id rec ready proceed output packet_pid status packet worktree
  id=account-cont-tracked-z28k
  rec=$(make_case continuation-tracked-content claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "tracked-content continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  printf 'first dirty tracked generation\n' > "$worktree/README.md"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-tracked-content.ready"
  proceed="$CASE_DIR/continuation-tracked-content.proceed"
  output="$CASE_DIR/continuation-tracked-content.out"
  packet="$HOME_DIR/data/$id/continuation-tracked-content.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" tracked-content > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "tracked-content continuation gate did not open: $(cat "$output")"; }
  printf 'second dirty tracked generation\n' > "$worktree/README.md"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted changed bytes for an already-dirty tracked file"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "tracked content replacement refusal was unclear"
  assert_absent "$packet" "tracked content replacement installed a stale continuation packet"
  pass "continuation identity includes bytes of already-dirty tracked files"
}

test_continuation_revalidates_dirty_untracked_content_before_install() {
  local id rec ready proceed output packet_pid status packet worktree dirty
  id=account-cont-untracked-z28m
  rec=$(make_case continuation-untracked-content claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "untracked-content continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  dirty="$worktree/already-untracked.txt"
  printf 'first dirty untracked generation\n' > "$dirty"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-untracked-content.ready"
  proceed="$CASE_DIR/continuation-untracked-content.proceed"
  output="$CASE_DIR/continuation-untracked-content.out"
  packet="$HOME_DIR/data/$id/continuation-untracked-content.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" untracked-content > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "untracked-content continuation gate did not open: $(cat "$output")"; }
  printf 'second dirty untracked generation\n' > "$dirty"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted changed bytes for an already-dirty untracked file"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "untracked content replacement refusal was unclear"
  assert_absent "$packet" "untracked content replacement installed a stale continuation packet"
  pass "continuation identity includes bytes of already-dirty untracked files"
}

test_continuation_accepts_stable_tracked_deletion() {
  local id rec packet worktree
  id=account-cont-deleted-z28q
  rec=$(make_case continuation-deleted claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "deleted-file continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm "$worktree/README.md" "$CASE_DIR/endpoint-live"

  packet=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" tracked-deletion) \
    || fail "continuation rejected a stable tracked deletion"
  assert_present "$packet" "stable tracked deletion did not produce a continuation packet"
  assert_absent "$worktree/README.md" "continuation altered the stable tracked deletion"
  pass "continuation identity represents stable tracked deletions explicitly"
}

test_continuation_revalidates_dirty_submodule_content() {
  local id rec ready proceed output packet_pid status packet worktree subrepo
  id=account-cont-submodule-z29a
  rec=$(make_case continuation-submodule claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "submodule continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  subrepo="$CASE_DIR/submodule-source"
  fm_git_init_commit "$subrepo"
  git -C "$worktree" -c protocol.file.allow=always submodule add -q "$subrepo" nested-submodule
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam 'add submodule'
  printf 'first dirty nested generation\n' > "$worktree/nested-submodule/README.md"
  ln -s README.md "$worktree/nested-submodule/untracked-link"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-submodule.ready"; proceed="$CASE_DIR/continuation-submodule.proceed"
  output="$CASE_DIR/continuation-submodule.out"; packet="$HOME_DIR/data/$id/continuation-submodule.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" submodule > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "submodule continuation gate did not open: $(cat "$output")"; }
  printf 'second dirty nested generation\n' > "$worktree/nested-submodule/README.md"
  touch "$proceed"
  set +e
  wait "$packet_pid"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "continuation accepted changed bytes in an already-dirty submodule"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "dirty submodule replacement refusal was unclear"
  assert_absent "$packet" "dirty submodule replacement installed a stale continuation packet"
  pass "continuation accepts untracked submodule symlinks and fingerprints dirty nested bytes"
}

test_continuation_submodule_fingerprint_excludes_ignored_caches() {
  local id rec ready proceed output packet_pid status packet worktree subrepo paths budget_output
  id=account-cont-submodule-cache-z33a
  rec=$(make_case continuation-submodule-cache claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "submodule-cache continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  subrepo="$CASE_DIR/submodule-cache-source"
  fm_git_init_commit "$subrepo"
  printf 'ignored-cache/\n' > "$subrepo/.gitignore"
  git -C "$subrepo" add .gitignore
  git -C "$subrepo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore build cache'
  git -C "$worktree" -c protocol.file.allow=always submodule add -q "$subrepo" nested-submodule
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam 'add submodule'
  mkdir -p "$worktree/nested-submodule/ignored-cache"
  printf 'first ignored generation\n' > "$worktree/nested-submodule/ignored-cache/build.bin"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-submodule-cache.ready"; proceed="$CASE_DIR/continuation-submodule-cache.proceed"
  output="$CASE_DIR/continuation-submodule-cache.out"; packet="$HOME_DIR/data/$id/continuation-cache.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" cache > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "submodule-cache continuation gate did not open: $(cat "$output")"; }
  printf 'second ignored generation\n' > "$worktree/nested-submodule/ignored-cache/build.bin"
  touch "$proceed"
  if wait "$packet_pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "ignored submodule cache invalidated repository identity: $(cat "$output")"
  assert_present "$packet" "stable git-relevant submodule state did not produce a continuation packet"
  paths="$CASE_DIR/submodule-cache-paths"
  budget_output="$CASE_DIR/submodule-cache-budget.out"
  printf 'nested-submodule\0' > "$paths"
  if python3 "$ROOT/bin/fm-contained-read.py" fingerprint-submodules-fd "$paths" 10 1 10 \
    3< "$worktree" > "$budget_output" 2>&1; then
    fail "submodule fingerprint ignored its byte budget"
  fi
  assert_contains "$(cat "$budget_output")" "repository fingerprint exceeds its byte limit" \
    "submodule fingerprint byte-limit failure was unclear"
  pass "continuation submodule identity excludes ignored caches and enforces bounds"
}

test_continuation_repository_fingerprint_uses_pinned_root() {
  local id rec packet worktree moved outside hook marker
  id=account-cont-root-pin-z29b
  rec=$(make_case continuation-root-pin claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "root-pin continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  printf 'inside pinned repository\n' > "$worktree/README.md"
  moved="$CASE_DIR/worktree-moved"; outside="$CASE_DIR/worktree-outside"; hook="$CASE_DIR/root-pin-hook"; marker="$CASE_DIR/root-pin.marker"
  cp -R "$worktree" "$outside"
  printf 'outside replacement repository\n' > "$outside/README.md"
  mkdir -p "$hook"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False

def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "README.md":
        swapped = True
        os.rename(os.environ["FM_PIN_ROOT"], os.environ["FM_PIN_MOVED"])
        os.symlink(os.environ["FM_PIN_OUTSIDE"], os.environ["FM_PIN_ROOT"], target_is_directory=True)
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.unlink(os.environ["FM_PIN_ROOT"])
            os.rename(os.environ["FM_PIN_MOVED"], os.environ["FM_PIN_ROOT"])
            with open(os.environ["FM_PIN_MARKER"], "w", encoding="utf-8") as output:
                output.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)

os.open = guarded_open
PY
  rm -f "$CASE_DIR/endpoint-live"
  packet=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_PIN_ROOT="$worktree" FM_PIN_MOVED="$moved" \
    FM_PIN_OUTSIDE="$outside" FM_PIN_MARKER="$marker" PYTHONPATH="$hook" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" root-pin) \
    || fail "continuation rejected descriptor-pinned repository traversal"
  assert_present "$marker" "repository root ancestor-swap hook did not run"
  assert_present "$packet" "descriptor-pinned continuation packet was not published"
  assert_grep 'inside pinned repository' "$worktree/README.md" "repository root swap changed the original worktree"
  assert_grep 'outside replacement repository' "$outside/README.md" "repository root traversal opened the replacement tree"
  pass "continuation fingerprints repository descendants through one pinned root"
}

test_continuation_packet_publication_is_generation_owned() {
  local id rec ready proceed first_out second_out first_pid status packet
  id=account-cont-cas-z29c
  rec=$(make_case continuation-cas claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "continuation CAS precondition spawn failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-cas.ready"; proceed="$CASE_DIR/continuation-cas.proceed"
  first_out="$CASE_DIR/continuation-cas-first.out"; second_out="$CASE_DIR/continuation-cas-second.out"
  packet="$HOME_DIR/data/$id/continuation-cas.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" cas > "$first_out" 2>&1 &
  first_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$first_pid" 2>/dev/null || true; fail "continuation CAS gate did not open: $(cat "$first_out")"; }
  if FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" cas > "$second_out" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "a concurrent continuation overwrote the owned packet generation"
  assert_contains "$(cat "$second_out")" "publication is already in progress" \
    "concurrent continuation CAS refusal was unclear"
  assert_present "$packet" "concurrent continuation removed the first owned packet generation"
  touch "$proceed"
  wait "$first_pid" || fail "owned continuation generation failed after its competitor was refused"
  assert_present "$packet" "successful continuation CAS did not retain its canonical packet"
  pass "continuation publication serializes generation ownership without overwrites"
}

test_continuation_rejects_root_swap_before_descriptor_open() {
  local id rec ready proceed output pid status worktree moved outside
  id=account-cont-root-preopen-z29d
  rec=$(make_case continuation-root-preopen claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "root pre-open precondition failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  moved="$CASE_DIR/worktree-before-open"; outside="$CASE_DIR/outside-before-open"
  cp -R "$worktree" "$outside"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/root-preopen.ready"; proceed="$CASE_DIR/root-preopen.proceed"; output="$CASE_DIR/root-preopen.out"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_ROOT_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_ROOT_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" root-preopen > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "root pre-open gate did not open"; }
  mv "$worktree" "$moved"
  ln -s "$outside" "$worktree"
  touch "$proceed"
  wait "$pid"; status=$?
  rm "$worktree"; mv "$moved" "$worktree"
  [ "$status" -ne 0 ] || fail "continuation pinned a replacement worktree generation"
  assert_contains "$(cat "$output")" "changed before pinning" "pre-open root swap refusal was unclear"
  pass "continuation proves cwd descriptor identity when the root swaps before open"
}

test_continuation_prepublish_cas_preserves_unowned_replacement() {
  local id rec ready proceed output pid status packet replacement
  id=account-cont-prepublish-z29e
  rec=$(make_case continuation-prepublish claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "prepublish CAS precondition failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  packet="$HOME_DIR/data/$id/continuation-prepublish.md"; replacement="$CASE_DIR/unowned-replacement"
  printf 'owned prior generation\n' > "$packet"
  printf 'unowned concurrent generation\n' > "$replacement"
  ready="$CASE_DIR/prepublish.ready"; proceed="$CASE_DIR/prepublish.proceed"; output="$CASE_DIR/prepublish.out"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" prepublish > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "prepublish CAS gate did not open: $(cat "$output")"; }
  rm "$packet"; cp "$replacement" "$packet"
  touch "$proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation overwrote an unowned prepublish generation"
  cmp -s "$packet" "$replacement" || fail "continuation CAS deleted or changed an unowned replacement"
  assert_contains "$(cat "$output")" "exchange generation changed before publication" \
    "prepublish generation mismatch was not reported"
  pass "continuation CAS preserves unowned replacements at the exchange boundary"
}

test_continuation_reclaims_only_positively_stale_publish_lock() {
  local id rec packet lock
  id=account-cont-stale-lock-z29f
  rec=$(make_case continuation-stale-lock claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "stale publish-lock precondition failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  lock="$HOME_DIR/data/$id/.continuation-stale-lock.publish-lock"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-token\n' > "$lock"
  packet=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" stale-lock) || fail "continuation did not reclaim a positively stale publish lock"
  assert_present "$packet" "stale-lock recovery did not publish its packet"
  assert_absent "$lock" "stale-lock recovery retained its owned publish lock"
  pass "continuation publish locks reclaim only a positively stale owner"
}

test_continuation_recovers_abandoned_reclaim_owner() {
  local id rec packet lock reclaim
  id=account-cont-reclaim-z30a
  rec=$(make_case continuation-reclaim claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "reclaim precondition failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  lock="$HOME_DIR/data/$id/.continuation-reclaim.publish-lock"
  reclaim="$lock.reclaim"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-lock\n' > "$lock"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-reclaim\n' > "$reclaim"
  packet=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" reclaim) || fail "continuation did not recover an abandoned reclaim owner"
  assert_present "$packet" "abandoned reclaim recovery did not publish"
  assert_absent "$lock" "abandoned reclaim recovery retained the lock"
  assert_absent "$reclaim" "abandoned reclaim recovery retained the reclaim owner"
  pass "continuation reclaim ownership is atomically published and stale-recoverable"
}

test_continuation_no_prior_rollback_preserves_raced_replacement() {
  local id rec install_ready install_proceed remove_ready remove_proceed output pid status packet replacement worktree
  id=account-cont-remove-z30b
  rec=$(make_case continuation-remove claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "rollback race precondition failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  install_ready="$CASE_DIR/install.ready"; install_proceed="$CASE_DIR/install.proceed"
  remove_ready="$CASE_DIR/remove.ready"; remove_proceed="$CASE_DIR/remove.proceed"
  output="$CASE_DIR/remove.out"; packet="$HOME_DIR/data/$id/continuation-remove.md"
  replacement="$CASE_DIR/unowned.bytes"
  printf 'unowned replacement\000must survive' > "$replacement"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY="$install_ready" \
    FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED="$install_proceed" \
    FM_CONTAINED_REMOVE_TEST_READY="$remove_ready" FM_CONTAINED_REMOVE_TEST_PROCEED="$remove_proceed" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" remove > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$install_ready" ] && break; sleep 0.05; done
  [ -e "$install_ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "rollback install gate did not open"; }
  printf 'changed\n' > "$worktree/rollback-race.txt"
  touch "$install_proceed"
  for _ in $(seq 1 100); do [ -e "$remove_ready" ] && break; sleep 0.05; done
  [ -e "$remove_ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "conditional removal gate did not open: $(cat "$output")"; }
  rm -f "$packet"; cp "$replacement" "$packet"; touch "$remove_proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "rollback race unexpectedly succeeded"
  cmp -s "$packet" "$replacement" || fail "conditional rollback deleted an unowned packet"
  pass "continuation rollback conditionally removes only its owned packet inode"
}

test_task_file_publication_cas_preserves_concurrent_append() {
  local data="$TMP_ROOT/task-file-cas/data" task=task-file-cas file ready proceed output pid status before
  mkdir -p "$data/$task"
  file="$data/$task/trail.md"; ready="$TMP_ROOT/task-file-cas/ready"; proceed="$TMP_ROOT/task-file-cas/proceed"
  output="$TMP_ROOT/task-file-cas/out"
  printf 'original\n' > "$file"
  FM_FILE_TRANSACTION_PUBLISH_TEST_READY="$ready" FM_FILE_TRANSACTION_PUBLISH_TEST_PROCEED="$proceed" \
    node - "$ROOT/bin/fm-file-transaction.cjs" "$data" "$task" > "$output" 2>&1 <<'JS' &
const { pinnedTaskFileTransaction } = require(process.argv[2]);
pinnedTaskFileTransaction(process.argv[3], process.argv[4], 'trail.md', content => Buffer.concat([content, Buffer.from('transaction\n')]));
JS
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "task-file CAS gate did not open"; }
  printf 'concurrent\n' >> "$file"; before=$(cat "$file"); touch "$proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "task-file CAS overwrote a concurrent append"
  [ "$(cat "$file")" = "$before" ] || fail "task-file CAS failed to restore concurrent content"
  assert_no_grep 'transaction' "$file" "failed task-file CAS published stale output"
  pass "task-file publication is a generation-owned compare-and-swap"
}

test_task_file_rollback_preserves_unowned_replacement_and_displaced_generation() {
  local data="$TMP_ROOT/task-file-rollback/data" task=task-file-rollback file ready proceed output pid status displaced
  mkdir -p "$data/$task"
  file="$data/$task/trail.md"; ready="$TMP_ROOT/task-file-rollback/ready"; proceed="$TMP_ROOT/task-file-rollback/proceed"
  output="$TMP_ROOT/task-file-rollback/out"
  printf 'original generation\n' > "$file"
  FM_FILE_TRANSACTION_POSTPUBLISH_TEST_READY="$ready" FM_FILE_TRANSACTION_POSTPUBLISH_TEST_PROCEED="$proceed" \
    node - "$ROOT/bin/fm-file-transaction.cjs" "$data" "$task" > "$output" 2>&1 <<'JS' &
const { pinnedTaskFileTransaction } = require(process.argv[2]);
pinnedTaskFileTransaction(process.argv[3], process.argv[4], 'trail.md', content => Buffer.concat([content, Buffer.from('transaction\n')]));
JS
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "task-file rollback gate did not open"; }
  mv "$file" "$data/$task/installed-owned"
  printf 'concurrent replacement\n' > "$file"
  touch "$proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "task-file rollback accepted an unowned replacement"
  assert_contains "$(cat "$file")" "concurrent replacement" "task-file rollback clobbered the concurrent destination"
  displaced=$(find "$data/$task" -maxdepth 1 -type f -name '.trail.md.*' -print -quit)
  [ -n "$displaced" ] || fail "task-file rollback discarded the displaced prior generation"
  assert_contains "$(cat "$displaced")" "original generation" "task-file rollback changed the displaced prior generation"
  pass "task-file rollback preserves concurrent and displaced generations"
}

test_task_file_rollback_preserves_displaced_generation_when_destination_disappears() {
  local data="$TMP_ROOT/task-file-rollback-missing/data" task=task-file-rollback-missing file ready proceed output pid status displaced
  mkdir -p "$data/$task"
  file="$data/$task/trail.md"; ready="$TMP_ROOT/task-file-rollback-missing/ready"; proceed="$TMP_ROOT/task-file-rollback-missing/proceed"
  output="$TMP_ROOT/task-file-rollback-missing/out"
  printf 'original missing generation\n' > "$file"
  FM_FILE_TRANSACTION_POSTPUBLISH_TEST_READY="$ready" FM_FILE_TRANSACTION_POSTPUBLISH_TEST_PROCEED="$proceed" \
    node - "$ROOT/bin/fm-file-transaction.cjs" "$data" "$task" > "$output" 2>&1 <<'JS' &
const { pinnedTaskFileTransaction } = require(process.argv[2]);
pinnedTaskFileTransaction(process.argv[3], process.argv[4], 'trail.md', content => Buffer.concat([content, Buffer.from('transaction\n')]));
JS
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "task-file missing-destination gate did not open"; }
  rm "$file"; touch "$proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "task-file rollback accepted a missing destination"
  assert_absent "$file" "task-file rollback recreated an unowned missing destination"
  displaced=$(find "$data/$task" -maxdepth 1 -type f -name '.trail.md.*' -print -quit)
  [ -n "$displaced" ] || fail "task-file rollback discarded the displaced generation after destination removal"
  assert_contains "$(cat "$displaced")" "original missing generation" "missing-destination rollback changed the displaced generation"
  pass "task-file rollback preserves displaced state when the destination disappears"
}

test_continuation_generation_copy_requires_owned_source() {
  local root="$TMP_ROOT/continuation-copy-owned" source destination prior ready proceed output pid status source_id
  mkdir -p "$root"
  source="$root/source"; destination="$root/destination"; prior="$root/prior"
  ready="$TMP_ROOT/continuation-copy.ready"; proceed="$TMP_ROOT/continuation-copy.proceed"; output="$TMP_ROOT/continuation-copy.out"
  printf 'verified packet\n' > "$source"
  source_id=$(stat -f '%d:%i' "$source" 2>/dev/null || stat -c '%d:%i' "$source")
  FM_CONTAINED_COPY_TEST_READY="$ready" FM_CONTAINED_COPY_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" copy-file-fd source destination "$source_id" \
    3< "$root" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "owned continuation copy gate did not open"; }
  mv "$source" "$prior"; printf 'unowned packet\n' > "$source"; touch "$proceed"
  wait "$pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation generation copied an unowned canonical packet"
  assert_absent "$destination" "failed continuation generation copy retained output"
  assert_contains "$(cat "$source")" "unowned packet" "continuation generation copy changed the replacement source"
  pass "continuation generation copy requires the published packet identity"
}

test_submodule_timeout_terminates_process_group() {
  local root="$TMP_ROOT/submodule-process-group" fakebin paths output child_pid_file child_pid status child_state
  mkdir -p "$root/submodule"; fakebin=$(fm_fakebin "$TMP_ROOT/submodule-process-group-bin")
  paths="$TMP_ROOT/submodule-paths"; output="$TMP_ROOT/submodule-process.out"; child_pid_file="$TMP_ROOT/submodule-child.pid"
  printf 'submodule\0' > "$paths"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
sleep 30 &
child=$!
printf '%s\n' "$child" > "$FM_SUBMODULE_CHILD_PID"
trap 'wait "$child" 2>/dev/null; exit 143' TERM
wait "$child"
SH
  chmod +x "$fakebin/git"
  FM_SUBMODULE_CHILD_PID="$child_pid_file" PATH="$fakebin:$PATH" \
    python3 "$ROOT/bin/fm-contained-read.py" fingerprint-submodules-fd "$paths" 10 1024 1 \
    3< "$root" > "$output" 2>&1; status=$?
  [ "$status" -ne 0 ] || fail "submodule fingerprint timeout unexpectedly succeeded"
  [ -s "$child_pid_file" ] || fail "submodule timeout fixture did not start its descendant"
  child_pid=$(cat "$child_pid_file")
  child_state=$(ps -o stat= -p "$child_pid" 2>/dev/null || true)
  [ -z "$child_state" ] || fail "submodule timeout left a descendant process alive ($child_state)"
  pass "submodule timeouts terminate and reap the command process group"
}

test_bounded_command_reap_never_waits_unbounded() {
  local output="$TMP_ROOT/bounded-reap.out" status
  if python3 - "$ROOT/bin/fm-contained-read.py" > "$output" 2>&1 <<'PY'
import importlib.util
import os
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("fm_contained_read", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
read_fd, write_fd = os.pipe()


class Process:
    def __init__(self):
        self.pid = 12345
        self.stdout = os.fdopen(read_fd, "rb", buffering=0)
        self.waits = []

    def poll(self):
        return None

    def terminate(self):
        return None

    def kill(self):
        return None

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if timeout is None:
            raise AssertionError("unbounded wait attempted")
        raise subprocess.TimeoutExpired("git", timeout)


class Budget:
    def __init__(self):
        self.deadline = time.monotonic() + 0.25

    def check_time(self, reserve_seconds=0):
        raise RuntimeError("repository fingerprint exceeds its time limit")

    def bounded_deadline(self, maximum_seconds):
        return min(self.deadline, time.monotonic() + maximum_seconds)


process = Process()
module.subprocess.Popen = lambda *args, **kwargs: process
module.os.killpg = lambda *args, **kwargs: None
started = time.monotonic()
try:
    module.bounded_command_output(["git", "status"], Budget())
except RuntimeError as error:
    if "cleanup timed out before the child could be reaped" not in str(error):
        raise
else:
    raise AssertionError("bounded command unexpectedly succeeded")
finally:
    os.close(write_fd)
elapsed = time.monotonic() - started
if elapsed >= 0.5:
    raise AssertionError(f"bounded reap took {elapsed:.3f} seconds")
if not process.waits or any(timeout is None or timeout < 0 for timeout in process.waits):
    raise AssertionError(f"unbounded reap attempts: {process.waits}")
if max(process.waits) > 0.25:
    raise AssertionError(f"reap waits exceeded the shared deadline: {process.waits}")
PY
  then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || fail "bounded command reap regression failed: $(cat "$output")"
  pass "bounded command cleanup never waits indefinitely to reap"
}

test_continuation_fingerprint_deadline_covers_ordinary_paths() {
  local id rec ready proceed output pid status
  id=account-cont-path-timeout-z36a
  rec=$(make_case continuation-path-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "ordinary-path timeout precondition spawn failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/path-timeout.ready"; proceed="$CASE_DIR/path-timeout.proceed"
  output="$CASE_DIR/path-timeout.out"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS=1 \
    FM_FINGERPRINT_PATHS_TEST_READY="$ready" FM_FINGERPRINT_PATHS_TEST_PROCEED="$proceed" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" path-timeout > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "ordinary-path fingerprint timeout gate did not open"; }
  sleep 1.2
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "ordinary repository paths ignored the configured fingerprint deadline"
  assert_contains "$(cat "$output")" "cannot verify continuation repository status" \
    "ordinary repository path timeout did not fail at repository verification"
  pass "continuation fingerprint deadline covers ordinary repository paths"
}

test_continuation_deadline_starts_before_repository_enumeration() {
  local id rec ready proceed output pid status real_git
  id=account-cont-enumeration-timeout-z38a
  rec=$(make_case continuation-enumeration-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "enumeration timeout precondition spawn failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/enumeration-timeout.ready"; proceed="$CASE_DIR/enumeration-timeout.proceed"
  output="$CASE_DIR/enumeration-timeout.out"
  real_git=$(command -v git)
  cat > "$FAKEBIN_DIR/git" <<'SH'
#!/usr/bin/env bash
if [ "${FM_CONTINUATION_ENUMERATION_TEST:-}" = timeout ] \
  && [ "$*" = "status --porcelain=v2 --branch -z" ]; then
  : > "$FM_CONTINUATION_ENUMERATION_READY"
  while [ ! -e "$FM_CONTINUATION_ENUMERATION_PROCEED" ]; do sleep 0.01; done
fi
exec "$FM_CONTINUATION_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS=1 \
    FM_CONTINUATION_ENUMERATION_TEST=timeout FM_CONTINUATION_ENUMERATION_READY="$ready" \
    FM_CONTINUATION_ENUMERATION_PROCEED="$proceed" FM_CONTINUATION_REAL_GIT="$real_git" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" enumeration-timeout > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "repository enumeration timeout gate did not open"; }
  sleep 1.2
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "repository enumeration ignored the continuation deadline"
  assert_contains "$(cat "$output")" "repository fingerprint exceeds its time limit" \
    "repository enumeration timeout did not preserve the monotonic deadline diagnostic"
  assert_contains "$(cat "$output")" "FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS" \
    "repository enumeration timeout did not provide actionable configuration guidance"
  pass "continuation deadline starts before repository enumeration"
}

test_continuation_caps_repository_enumeration_output() {
  local id rec output status real_git
  id=account-cont-enumeration-limit-z38b
  rec=$(make_case continuation-enumeration-limit claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "enumeration output precondition spawn failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  output="$CASE_DIR/enumeration-limit.out"
  real_git=$(command -v git)
  cat > "$FAKEBIN_DIR/git" <<'SH'
#!/usr/bin/env bash
if [ "${FM_CONTINUATION_ENUMERATION_TEST:-}" = oversized ] \
  && [ "$*" = "status --porcelain=v2 --branch -z" ]; then
  head -c 2048 /dev/zero | tr '\0' x
  exit 0
fi
exec "$FM_CONTINUATION_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  if FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES=1024 \
    FM_CONTINUATION_ENUMERATION_TEST=oversized FM_CONTINUATION_REAL_GIT="$real_git" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" enumeration-limit > "$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "continuation accepted oversized repository enumeration output"
  assert_contains "$(cat "$output")" "repository enumeration or identity output exceeds its byte limit" \
    "oversized repository enumeration did not report its bound"
  assert_contains "$(cat "$output")" "FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES" \
    "oversized repository enumeration did not provide actionable configuration guidance"
  pass "continuation caps repository enumeration output"
}

test_continuation_deadline_covers_repository_parsing() {
  local id rec ready proceed output pid status
  id=account-cont-parse-timeout-z38c
  rec=$(make_case continuation-parse-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "repository parsing timeout precondition spawn failed"
  use_named_fake_tmux_target "$id"
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/parse-timeout.ready"; proceed="$CASE_DIR/parse-timeout.proceed"
  output="$CASE_DIR/parse-timeout.out"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS=1 \
    FM_REPOSITORY_IDENTITY_PARSE_TEST_READY="$ready" \
    FM_REPOSITORY_IDENTITY_PARSE_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" parse-timeout > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "repository parsing timeout gate did not open"; }
  sleep 1.2
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "repository enumeration parsing ignored the continuation deadline"
  assert_contains "$(cat "$output")" "repository fingerprint exceeds its time limit" \
    "repository parsing timeout did not preserve the monotonic deadline diagnostic"
  pass "continuation deadline covers repository enumeration parsing"
}

test_continuation_fingerprint_budget_spans_all_path_classes() {
  local root="$TMP_ROOT/shared-fingerprint-budget" tracked submodules untracked output status
  root="$root/root"
  tracked="$TMP_ROOT/shared-fingerprint-tracked"
  submodules="$TMP_ROOT/shared-fingerprint-submodules"
  untracked="$TMP_ROOT/shared-fingerprint-untracked"
  output="$TMP_ROOT/shared-fingerprint.out"
  mkdir -p "$root/submodule"
  printf 'tracked\n' > "$root/tracked"
  printf 'untracked\n' > "$root/untracked"
  git -C "$root/submodule" init -q
  git -C "$root/submodule" config user.name fmtest
  git -C "$root/submodule" config user.email fmtest@example.invalid
  git -C "$root/submodule" commit -q --allow-empty -m initial
  printf 'tracked\0' > "$tracked"
  printf 'submodule\0' > "$submodules"
  printf 'untracked\0' > "$untracked"
  python3 "$ROOT/bin/fm-contained-read.py" fingerprint-repository-fd \
    "$tracked" "$submodules" "$untracked" 5 1048576 10 3< "$root" > "$output" 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "repository path classes each received a fresh fingerprint budget"
  assert_contains "$(cat "$output")" "repository fingerprint exceeds its file-count limit" \
    "shared fingerprint budget failure was unclear"
  pass "continuation shares one fingerprint budget across every repository path class"
}

test_continuation_removes_packet_when_repository_changes_during_install() {
  local id rec ready proceed output packet_pid status packet worktree
  id=account-continuation-install-race-z28j
  rec=$(make_case continuation-install-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "continuation install-race precondition spawn failed"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-install.ready"
  proceed="$CASE_DIR/continuation-install.proceed"
  output="$CASE_DIR/continuation-install.out"
  packet="$HOME_DIR/data/$id/continuation-install-race.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" install-race > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "continuation install race gate did not open"; }
  assert_present "$packet" "continuation install race did not publish before its post-install check"
  printf 'changed during packet installation\n' > "$worktree/install-race.txt"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation retained a packet after its repository changed during installation"
  assert_contains "$(cat "$output")" "continuation repository snapshot changed" \
    "repository change during installation was not reported"
  assert_absent "$packet" "repository change during installation left a stale continuation packet"
  pass "continuation validates repository state around installation and removes stale packets"
}

test_continuation_restores_prior_packet_after_failed_postcheck() {
  local id rec ready proceed output packet_pid status packet prior worktree
  id=account-cont-prior-z28n
  rec=$(make_case continuation-prior-restore claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "prior-restore continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-prior-restore.ready"
  proceed="$CASE_DIR/continuation-prior-restore.proceed"
  output="$CASE_DIR/continuation-prior-restore.out"
  packet="$HOME_DIR/data/$id/continuation-prior-restore.md"
  prior="$CASE_DIR/prior-packet.bytes"
  printf 'valid prior packet\000with exact bytes' > "$packet"
  cp "$packet" "$prior"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" prior-restore > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "prior-restore continuation gate did not open"; }
  cmp -s "$packet" "$prior" && fail "new continuation packet was not published before the postcheck"
  printf 'changed during prior packet installation\n' > "$worktree/prior-restore-race.txt"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation retained a stale replacement over a prior packet"
  cmp -s "$packet" "$prior" || fail "failed postcheck did not restore the prior packet byte-verbatim"
  pass "failed continuation postchecks restore a displaced prior packet generation"
}

test_continuation_rollback_preserves_concurrent_packet_replacement() {
  local id rec ready proceed output packet_pid status packet worktree replacement prior preserved
  id=account-cont-owned-z28p
  rec=$(make_case continuation-owned-rollback claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "owned-rollback continuation precondition spawn failed"
  use_named_fake_tmux_target "$id"
  worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  rm -f "$CASE_DIR/endpoint-live"
  ready="$CASE_DIR/continuation-owned-rollback.ready"
  proceed="$CASE_DIR/continuation-owned-rollback.proceed"
  output="$CASE_DIR/continuation-owned-rollback.out"
  packet="$HOME_DIR/data/$id/continuation-owned-rollback.md"
  replacement="$CASE_DIR/concurrent-packet.bytes"
  prior="$CASE_DIR/prior-owned-packet.bytes"
  printf 'concurrent replacement\000must survive' > "$replacement"
  printf 'displaced prior\000must remain recoverable' > "$packet"
  cp "$packet" "$prior"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY="$ready" \
    FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED="$proceed" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" owned-rollback > "$output" 2>&1 &
  packet_pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] || { kill -TERM "$packet_pid" 2>/dev/null || true; fail "owned-rollback continuation gate did not open"; }
  rm -f "$packet"
  cp "$replacement" "$packet"
  printf 'changed during owned packet rollback\n' > "$worktree/owned-rollback-race.txt"
  touch "$proceed"
  wait "$packet_pid"; status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted a repository change after concurrent packet replacement"
  cmp -s "$packet" "$replacement" || fail "rollback deleted or overwrote a concurrent packet generation"
  preserved=$(find "$HOME_DIR/data/$id" -maxdepth 1 -type f \
    -name 'continuation-owned-rollback.displaced-*.md' -print -quit)
  [ -n "$preserved" ] || fail "rollback lost the prior packet after a concurrent replacement"
  cmp -s "$preserved" "$prior" || fail "durably preserved prior packet changed bytes"
  assert_contains "$(cat "$output")" "continuation packet generation changed before rollback" \
    "concurrent packet ownership loss was not reported"
  pass "continuation rollback preserves concurrent and displaced prior packet generations"
}

test_continuation_rejects_load_bearing_source_replacement_during_open() {
  local id rec source hook out status
  id=account-continuation-copy-race-z28d
  rec=$(make_case continuation-copy-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "continuation copy-race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  source="$(cd "$HOME_DIR/data/$id" && pwd -P)/checkpoint.md"
  printf 'load-bearing checkpoint\n' > "$source"
  hook="$CASE_DIR/continuation-source-replacement"
  mkdir -p "$hook"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
replaced = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global replaced
    target = os.environ["FM_MUTATE_CONTINUATION_SOURCE"]
    if not replaced and dir_fd is not None and file == os.path.basename(target):
        replaced = True
        os.rename(target, f"{target}.mutated")
        with open(target, "wb") as replacement:
            replacement.write(b"z" * os.stat(f"{target}.mutated").st_size)
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  export PYTHONPATH="$hook" FM_MUTATE_CONTINUATION_SOURCE="$source"
  if out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit \
    run_spawn "$id" --continue-account --account-profile claude-3); then
    status=0
  else
    status=$?
  fi
  unset PYTHONPATH FM_MUTATE_CONTINUATION_SOURCE
  [ "$status" -ne 0 ] || fail "continuation accepted a replaced load-bearing source"
  assert_present "$source.mutated" "continuation identity-race hook did not run: $out"
  assert_contains "$out" 'contained read failed' \
    "continuation replacement refusal did not report the identity change"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "continuation copy race acquired a replacement lease"
  assert_not_grep '^continuation_packet=' "$HOME_DIR/state/$id.meta" "continuation copy race installed a partial packet"
  pass "continuation load-bearing copies bind one validated source identity"
}

test_continuation_appends_the_validated_brief_snapshot() {
  local id rec brief packet
  id=account-continuation-brief-snapshot-z28g
  rec=$(make_case continuation-brief-snapshot claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "brief snapshot continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  brief="$HOME_DIR/data/$id/brief.md"
  printf 'validated original brief bytes\n' > "$brief"
  cat > "$FAKEBIN_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'replacement brief bytes\n' > "$FM_MUTATE_CONTINUATION_BRIEF"
printf 'status after mutation\n'
SH
  chmod +x "$FAKEBIN_DIR/no-mistakes"
  packet=$(FM_MUTATE_CONTINUATION_BRIEF="$brief" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" brief-snapshot) \
    || fail "continuation could not publish its validated brief snapshot"
  assert_grep 'validated original brief bytes' "$packet" "continuation discarded the validated brief snapshot"
  assert_not_grep 'replacement brief bytes' "$packet" "continuation reopened the replaced brief"
  assert_grep 'replacement brief bytes' "$brief" "brief snapshot race hook did not mutate the source"
  pass "continuation appends the exact validated brief snapshot"
}

test_continuation_reads_descendants_through_the_pinned_root() {
  local id rec task_dir moved outside source hook marker packet
  id=account-continuation-openat-z28h
  rec=$(make_case continuation-openat claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "descriptor-relative continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  task_dir=$(cd "$HOME_DIR/data/$id" && pwd -P)
  moved="$CASE_DIR/pinned-openat-task"
  outside="$CASE_DIR/outside-openat-task"
  source="$task_dir/decisions.md"
  hook="$CASE_DIR/continuation-openat-hook"
  marker="$CASE_DIR/continuation-openat-swapped"
  mkdir -p "$outside" "$hook"
  printf 'inside pinned decision\n' > "$source"
  printf 'outside private decision\n' > "$outside/decisions.md"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "decisions.md":
        swapped = True
        os.rename(os.environ["FM_CONTINUATION_SWAP_PARENT"], os.environ["FM_CONTINUATION_SWAP_MOVED"])
        os.rename(os.environ["FM_CONTINUATION_SWAP_OUTSIDE"], os.environ["FM_CONTINUATION_SWAP_PARENT"])
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_CONTINUATION_SWAP_PARENT"], os.environ["FM_CONTINUATION_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_CONTINUATION_SWAP_MOVED"], os.environ["FM_CONTINUATION_SWAP_PARENT"])
            with open(os.environ["FM_CONTINUATION_SWAP_MARKER"], "w", encoding="utf-8") as marker:
                marker.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  packet=$(PYTHONPATH="$hook" FM_CONTINUATION_SWAP_PARENT="$task_dir" \
    FM_CONTINUATION_SWAP_MOVED="$moved" FM_CONTINUATION_SWAP_OUTSIDE="$outside" \
    FM_CONTINUATION_SWAP_MARKER="$marker" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" openat-swap) \
    || fail "descriptor-relative continuation failed during a restored ancestor swap"
  assert_present "$marker" "descriptor-relative continuation swap hook did not run"
  assert_grep 'inside pinned decision' "$packet" "continuation lost the descendant from its pinned root"
  assert_not_grep 'outside private decision' "$packet" "continuation read through the swapped pathname"
  pass "continuation traverses descendants relative to its pinned root"
}

test_continuation_pins_one_root_for_the_complete_task_snapshot() {
  local id rec task_dir moved outside hook marker packet
  id=account-continuation-one-root-z28i
  rec=$(make_case continuation-one-root claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "single-root continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  task_dir=$(cd "$HOME_DIR/data/$id" && pwd -P)
  moved="$CASE_DIR/pinned-one-root-task"
  outside="$CASE_DIR/outside-one-root-task"
  hook="$CASE_DIR/continuation-one-root-hook"
  marker="$CASE_DIR/continuation-one-root-swapped"
  mkdir -p "$outside" "$hook"
  printf 'inside pinned decision\n' > "$task_dir/decisions.md"
  printf 'inside pinned steering\n' > "$task_dir/steering.md"
  printf 'outside decision\n' > "$outside/decisions.md"
  printf 'outside steering\n' > "$outside/steering.md"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "decisions.md":
        swapped = True
        descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        os.rename(os.environ["FM_CONTINUATION_SWAP_PARENT"], os.environ["FM_CONTINUATION_SWAP_MOVED"])
        os.rename(os.environ["FM_CONTINUATION_SWAP_OUTSIDE"], os.environ["FM_CONTINUATION_SWAP_PARENT"])
        with open(os.environ["FM_CONTINUATION_SWAP_MARKER"], "w", encoding="utf-8") as marker:
            marker.write("swapped\n")
        return descriptor
    if swapped and dir_fd is not None and file == "steering.md":
        try:
            return original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_CONTINUATION_SWAP_PARENT"], os.environ["FM_CONTINUATION_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_CONTINUATION_SWAP_MOVED"], os.environ["FM_CONTINUATION_SWAP_PARENT"])
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  packet=$(PYTHONPATH="$hook" FM_CONTINUATION_SWAP_PARENT="$task_dir" \
    FM_CONTINUATION_SWAP_MOVED="$moved" FM_CONTINUATION_SWAP_OUTSIDE="$outside" \
    FM_CONTINUATION_SWAP_MARKER="$marker" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" one-root-swap) \
    || fail "continuation did not hold one task root across its complete snapshot"
  assert_present "$marker" "single-root continuation swap hook did not run"
  assert_grep 'inside pinned decision' "$packet" "single-root snapshot lost the original decision"
  assert_grep 'inside pinned steering' "$packet" "single-root snapshot mixed in replacement steering"
  assert_not_grep 'outside decision' "$packet" "single-root snapshot read a replacement decision"
  assert_not_grep 'outside steering' "$packet" "single-root snapshot read replacement steering"
  pass "continuation pins one task root for its complete artifact snapshot"
}

test_continuation_rejects_task_source_ancestor_swap() {
  local id rec task_dir moved outside source hook marker out status
  id=account-continuation-task-parent-z28e
  rec=$(make_case continuation-task-parent claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "task-parent continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  task_dir=$(cd "$HOME_DIR/data/$id" && pwd -P)
  moved="$CASE_DIR/pinned-task-source"
  outside="$CASE_DIR/outside-task-source"
  source="$task_dir/decisions.md"
  hook="$CASE_DIR/task-source-ancestor-swap"
  marker="$CASE_DIR/task-source-swapped"
  mkdir "$outside"
  printf 'inside task decision\n' > "$source"
  printf 'outside private task decision\n' > "$outside/decisions.md"
  write_continuation_ancestor_swap_hook "$hook"
  if out=$(PYTHONPATH="$hook" \
    FM_CONTINUATION_SWAP_TARGET="$source" FM_CONTINUATION_SWAP_PARENT="$task_dir" \
    FM_CONTINUATION_SWAP_MOVED="$moved" FM_CONTINUATION_SWAP_OUTSIDE="$outside" \
    FM_CONTINUATION_SWAP_MARKER="$marker" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" task-parent-swap 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "continuation accepted a task-source ancestor swap"
  assert_present "$marker" "task-source ancestor-swap hook did not run: $out"
  assert_contains "$out" 'contained read failed' "task-source ancestor swap did not fail at the pinned read"
  if find "$moved" "$outside" -type f -name 'continuation-task-parent-swap.md' -print -quit | grep -q .; then
    fail "task-source ancestor swap installed a continuation packet"
  fi
  pass "continuation pins task-source ancestors through descriptor open"
}

test_continuation_rejects_metadata_ancestor_swap() {
  local id rec state_dir moved outside source hook marker out status
  id=account-continuation-meta-parent-z28f
  rec=$(make_case continuation-meta-parent claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "metadata-parent continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  state_dir=$(cd "$HOME_DIR/state" && pwd -P)
  moved="$CASE_DIR/pinned-state-source"
  outside="$CASE_DIR/outside-state-source"
  source="$state_dir/$id.meta"
  hook="$CASE_DIR/metadata-ancestor-swap"
  marker="$CASE_DIR/metadata-source-swapped"
  mkdir "$outside"
  cp "$source" "$outside/$id.meta"
  printf 'outside_marker=private-metadata\n' >> "$outside/$id.meta"
  write_continuation_ancestor_swap_hook "$hook"
  if out=$(PYTHONPATH="$hook" \
    FM_CONTINUATION_SWAP_TARGET="$source" FM_CONTINUATION_SWAP_PARENT="$state_dir" \
    FM_CONTINUATION_SWAP_MOVED="$moved" FM_CONTINUATION_SWAP_OUTSIDE="$outside" \
    FM_CONTINUATION_SWAP_MARKER="$marker" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" "$CONTINUATION" "$id" metadata-parent-swap 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "continuation accepted a metadata ancestor swap"
  assert_present "$marker" "metadata ancestor-swap hook did not run: $out"
  assert_contains "$out" 'cannot safely snapshot continuation metadata' \
    "metadata ancestor swap did not fail before parsing outside state"
  assert_absent "$HOME_DIR/data/$id/continuation-metadata-parent-swap.md" \
    "metadata ancestor swap installed a continuation packet"
  pass "continuation pins metadata ancestors before parsing task identity"
}

test_account_metadata_lock_reclaims_orphans_without_overlapping_owners() {
  local case_dir state lock workers pids pid rc owner_lines
  case_dir="$TMP_ROOT/account-lock"
  state="$case_dir/state"
  lock="$state/.account-meta-lock-task.lock"
  mkdir -p "$lock"

  set +e
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=30 \
    bash -c '. "$1"; fm_account_meta_lock_acquire "$2" lock-task' _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" \
    > "$case_dir/young-stdout" 2> "$case_dir/young-stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "young ownerless metadata lock was reclaimed before its grace"
  assert_present "$lock" "young ownerless metadata lock was deleted"
  assert_present "$lock/.ownerless-since" "ownerless metadata lock did not persist its grace baseline"

  printf '946684800\n' > "$lock/.ownerless-since"
  touch -t 200001010000 "$lock"
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 \
    bash -c '. "$1"; held=$(fm_account_meta_lock_acquire "$2" lock-task) || exit; fm_account_meta_lock_release "$held"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" || fail "old ownerless metadata lock was not reclaimed"

  owner_lines=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 bash -c '
    . "$1"
    held=$(fm_account_meta_lock_acquire "$2" lock-task)
    [ -f "$held" ] || exit 71
    wc -l < "$held" | tr -d "[:space:]"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$state") || fail "metadata lock ownership was not atomically published"
  [ "$owner_lines" -eq 2 ] || fail "published metadata lock did not contain complete ownership"

  mkdir -p "$lock"
  printf '999999\nstale-owner\n' > "$lock/owner"
  workers="$case_dir/workers.sh"
  cat > "$workers" <<'SH'
#!/usr/bin/env bash
set -eu
. "$1"
state=$2
critical=$3
overlap=$4
held=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=5 fm_account_meta_lock_acquire "$state" lock-task)
if ! mkdir "$critical" 2>/dev/null; then
  printf 'overlap\n' >> "$overlap"
fi
sleep 0.05
rmdir "$critical" 2>/dev/null || true
fm_account_meta_lock_release "$held"
SH
  chmod +x "$workers"
  pids=
  for _ in 1 2 3 4 5 6; do
    "$workers" "$ROOT/bin/fm-account-routing-lib.sh" "$state" "$case_dir/critical" "$case_dir/overlap" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent metadata lock owner lost ownership"
  done
  assert_absent "$case_dir/overlap" "metadata lock admitted overlapping owners"
  assert_absent "$lock" "metadata lock remained after concurrent owners exited"

  mkdir -p "$lock"
  FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 bash -c '
    . "$1"
    fm_account_reclaim_guard_acquire "$2/.reclaiming" 1
    [ -f "$2/.reclaiming" ] && [ "$(wc -l < "$2/.reclaiming" | tr -d "[:space:]")" -eq 2 ]
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$lock" \
    || fail "metadata reclaim ownership was not atomically published"
  rm -rf "$lock"

  mkdir -p "$lock/.reclaiming"
  printf '999999\nstale-reclaimer\n' > "$lock/.reclaiming/owner"
  touch -t 200001010000 "$lock" "$lock/.reclaiming"
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=2 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 \
    bash -c '. "$1"; held=$(fm_account_meta_lock_acquire "$2" lock-task); fm_account_meta_lock_release "$held"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" || fail "abandoned metadata reclaim owner blocked acquisition"
  assert_absent "$lock" "metadata lock retained an abandoned reclaim owner"
  pass "metadata locks reclaim abandoned directories without deleting new owners"
}

test_account_locks_never_reclaim_on_indeterminate_process_probe() {
  local case_dir state fake_ps ps_env_log kind acquire held owner_pid inode_before inode_after owner_before owner_after status
  . "$ROOT/bin/fm-account-routing-lib.sh"
  case_dir="$TMP_ROOT/account-lock-indeterminate-ps"
  state="$case_dir/state"
  fake_ps="$case_dir/ps"
  ps_env_log="$case_dir/ps-env"
  mkdir -p "$state"
  cat > "$fake_ps" <<'SH'
#!/usr/bin/env bash
original=("$@")
target=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -p ]; then target=${2:-}; break; fi
  shift
done
if [ "$target" = "${FM_TEST_ACCOUNT_PS_TARGET:?}" ]; then
  printf '%s|%s|%s|%s\n' "${LD_PRELOAD:-}" "${DYLD_INSERT_LIBRARIES:-}" \
    "${BASH_ENV:-}" "${PYTHONPATH:-}" >> "${FM_TEST_ACCOUNT_PS_ENV_LOG:?}"
  printf 'transient ps failure\n' >&2
  exit 42
fi
exec /bin/ps "${original[@]}"
SH
  chmod +x "$fake_ps"

  for kind in meta lifecycle; do
    if [ "$kind" = meta ]; then
      acquire=fm_account_meta_lock_acquire
    else
      acquire=fm_account_lifecycle_lock_acquire
    fi
    held=$($acquire "$state" "indeterminate-$kind") \
      || fail "could not acquire $kind lock fixture"
    owner_pid=$(sed -n '1p' "$held")
    inode_before=$(fm_account_path_inode "$held")
    owner_before=$(cat "$held")
    if FM_ACCOUNT_TEST_HOOKS=firstmate-account-tests-v1 \
      FM_TEST_ACCOUNT_PS_BIN="$fake_ps" FM_TEST_ACCOUNT_PS_TARGET="$owner_pid" \
      FM_TEST_ACCOUNT_PS_ENV_LOG="$ps_env_log" \
      FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 \
      FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=1 \
      bash -c '
        export LD_PRELOAD=/hostile-loader DYLD_INSERT_LIBRARIES=/hostile-dyld
        export BASH_ENV=/hostile-bash-env PYTHONPATH=/hostile-python
        . "$1"
        if [ "$2" = meta ]; then
          fm_account_meta_lock_acquire "$3" "indeterminate-$2"
        else
          fm_account_lifecycle_lock_acquire "$3" "indeterminate-$2"
        fi
      ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$kind" "$state" >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    [ "$status" -ne 0 ] || fail "$kind lock was stolen after an indeterminate process probe"
    inode_after=$(fm_account_path_inode "$held")
    owner_after=$(cat "$held")
    [ "$inode_after" = "$inode_before" ] && [ "$owner_after" = "$owner_before" ] \
      || fail "$kind lock identity changed after an indeterminate process probe"
    fm_account_meta_lock_release "$held" || fail "could not release preserved $kind lock"
  done
  [ -s "$ps_env_log" ] || fail "the pinned ps fixture was never invoked"
  [ "$(sort -u "$ps_env_log")" = '|||' ] \
    || fail "process probes inherited loader or language startup injection: $(cat "$ps_env_log")"
  pass "metadata and lifecycle locks preserve live owners when pinned ps is indeterminate"
}

test_ownerless_lock_marker_rejects_symlink_clobber() {
  local case_dir state lock marker outside out status
  case_dir="$TMP_ROOT/account-ownerless-marker"
  state="$case_dir/state"
  lock="$state/.account-meta-lock-task.lock"
  marker="$lock/.ownerless-since"
  outside="$case_dir/outside"
  mkdir -p "$lock"
  printf 'sentinel\n' > "$outside"
  ln -s "$outside" "$marker"

  if out=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 \
    bash -c '. "$1"; fm_account_meta_lock_acquire "$2" lock-task' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "ownerless metadata lock accepted a symlinked age marker"
  [ "$(cat "$outside")" = sentinel ] || fail "ownerless metadata lock clobbered a symlink target"
  [ -L "$marker" ] || fail "ownerless metadata lock replaced the unsafe marker"
  [ -n "$out" ] || true
  pass "ownerless lock recovery refuses symlinked age markers"
}

test_account_lock_owner_controls_reject_symlinks() {
  local case_dir state lock outside status
  case_dir="$TMP_ROOT/account-owner-controls"
  state="$case_dir/state"
  lock="$state/.account-meta-lock-task.lock"
  outside="$case_dir/outside"
  mkdir -p "$lock"
  printf '999999\nstale-owner\n' > "$outside"
  ln -s "$outside" "$lock/owner"
  touch -t 200001010000 "$lock"
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=2 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 bash -c '
    . "$1"
    held=$(fm_account_meta_lock_acquire "$2" task) || exit 1
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" \
    || fail "symlinked stale owner blocked metadata-lock recovery"
  [ "$(cat "$outside")" = $'999999\nstale-owner' ] || fail "metadata-lock recovery followed a symlinked owner"

  rm -rf "$lock"
  mkdir -p "$lock"
  ln -s "$outside" "$lock/owner"
  if bash -c '. "$1"; fm_account_meta_lock_release "$2"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$lock" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "metadata-lock release trusted a symlinked owner"
  assert_present "$lock" "metadata-lock release removed a lock with an unsafe owner"
  [ "$(cat "$outside")" = $'999999\nstale-owner' ] || fail "metadata-lock release changed a symlink target"
  rm -rf "$case_dir"
  pass "account lock owner controls reject symlinks by call-site semantics"
}

test_linux_stat_selection_avoids_filesystem_stat_output() {
  local case_dir fakebin file output
  case_dir="$TMP_ROOT/linux-stat-selection"
  fakebin="$case_dir/fakebin"
  file="$case_dir/file"
  mkdir -p "$fakebin"
  : > "$file"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -f) printf 'File: poisoned-filesystem-output\n'; exit 0 ;;
  -c)
    case "${2:-}" in
      %Y) printf '12345\n' ;;
      %i) printf '67890\n' ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  output=$(bash -c '
    . "$1"
    FM_ACCOUNT_SYSTEM_UNAME_BIN=$2/uname
    FM_ACCOUNT_SYSTEM_STAT_BIN=$2/stat
    printf "%s:%s\n" "$(fm_account_path_mtime "$3")" "$(fm_account_path_inode "$3")"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$fakebin" "$file") || fail "Linux account stat helpers failed"
  [ "$output" = '12345:67890' ] || fail "Linux account stat helpers accepted filesystem-stat output: $output"
  pass "account metadata stat helpers select GNU stat without probing BSD filesystem stat"
}

test_stale_reclaim_guard_is_owned_before_lock_removal() {
  local case_dir lock output status
  case_dir="$TMP_ROOT/reclaim-guard-ownership"
  lock="$case_dir/meta.lock"
  mkdir -p "$case_dir"
  printf '999999\nstale-owner\n' > "$lock"
  printf '999999\nstale-reclaimer\n' > "$lock.reclaiming"
  touch -t 200001010000 "$lock.reclaiming"
  bash -c '
    . "$1"
    fm_account_reclaim_guard_acquire "$2.reclaiming" 1 || exit 71
    fm_account_reclaim_guard_owned "$2.reclaiming" || exit 72
    fm_account_reclaim_guard_release "$2.reclaiming"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$lock" || fail "stale reclaim guard was observed but not acquired"

  printf '999999\nstale-owner\n' > "$lock"
  touch -t 200001010000 "$lock"
  set +e
  output=$(LOCK="$lock" bash -c '
    . "$1"
    replaced=0
    fm_account_reclaim_guard_acquire() { printf "%s\n%s\n" "$$" "$(fm_account_process_start_time "$$")" > "$1"; }
    fm_account_reclaim_guard_owned() {
      if [ "$replaced" = 0 ]; then
        replaced=1
        rm -f "$LOCK"
        printf "%s\n%s\n" "$$" "$(fm_account_process_start_time "$$")" > "$LOCK"
      fi
      return 0
    }
    fm_account_reclaim_guard_release() { rm -rf "$1"; }
    fm_account_meta_lock_reclaim "$LOCK" 1
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "metadata reclaim deleted a lock generation replaced after guard acquisition"
  [ "$(sed -n '1p' "$lock")" != 999999 ] || fail "metadata reclaim did not install the simulated replacement lock"
  [ -n "$output" ] || true
  pass "stale metadata reclaim owns its guard and preserves a replaced lock generation"
}

test_task_owned_account_artifacts_reject_symlink_paths() {
  local id rec outside original out status before
  id=account-symlink-safety-z29
  rec=$(make_case symlink-safety claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "symlink safety precondition spawn failed"
  original="$HOME_DIR/data/$id"
  outside="$CASE_DIR/outside-task"
  mv "$original" "$outside"
  ln -s "$outside" "$original"
  before=$(cat "$outside/account-attempts.md")

  if bash -c '. "$1"; fm_account_lineage_append "$2" "$3" unsafe attempt fleet claude pool profile session none' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$HOME_DIR/data" "$id"; then
    fail "account lineage followed a symlinked task directory"
  fi
  [ "$(cat "$outside/account-attempts.md")" = "$before" ] || fail "account lineage changed a symlink target outside the data root"

  out=$(run_send "$id" "Delivered without following the task symlink." 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "managed steering delivered without first recording a durable intent"
  assert_contains "$out" "intent could not be durably recorded before delivery" \
    "symlinked steering task-directory refusal was unclear"
  assert_not_grep 'Delivered without following the task symlink' "$LAUNCH_LOG" \
    "managed steering typed text after its durable intent could not be recorded"
  assert_absent "$outside/steering.md" "managed steering followed a symlinked task directory"
  assert_absent "$outside/steering-pending.md" "pending steering followed a symlinked task directory"
  assert_absent "$outside/steering-journal.md" "steering intent followed a symlinked task directory"
  assert_absent "$outside/steering-unconfirmed.md" "unconfirmed steering followed a symlinked task directory"

  rm -f "$CASE_DIR/endpoint-live"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" symlink-attempt 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "continuation accepted a symlinked task directory"
  assert_contains "$out" "task directory is unsafe" "continuation task-directory refusal was unclear"

  rm -f "$original"
  mv "$outside" "$original"
  printf 'outside\n' > "$CASE_DIR/outside-steering"
  ln -s "$CASE_DIR/outside-steering" "$original/steering.md"
  touch "$CASE_DIR/endpoint-live"
  out=$(run_send "$id" "Delivered without following the steering symlink." 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "symlinked steering file changed delivery truth: $out"
  [ "$(cat "$CASE_DIR/outside-steering")" = outside ] || fail "managed steering followed a symlinked output file"
  assert_grep 'Delivered without following the steering symlink' "$original/steering-unconfirmed.md" \
    "safe unconfirmed steering was not recorded without following the canonical trail symlink"
  pass "task-owned lineage, steering, and continuation artifacts reject symlink escapes"
}

test_account_lineage_rejects_parent_swap_during_transaction() {
  local data id original moved outside ready proceed writer_pid writer_rc before
  data="$TMP_ROOT/lineage-parent-race/data"
  id='lineage-parent-race'
  original="$data/$id"
  moved="$TMP_ROOT/lineage-parent-race/pinned-task"
  outside="$TMP_ROOT/lineage-parent-race/outside-task"
  ready="$TMP_ROOT/lineage-parent-race/ready"
  proceed="$TMP_ROOT/lineage-parent-race/proceed"
  mkdir -p "$original" "$outside"
  printf '# Account attempt lineage\n\n- original.\n' > "$original/account-attempts.md"
  printf 'outside lineage sentinel\n' > "$outside/account-attempts.md"
  bash -c '. "$1"; fm_account_lineage_append "$2" "$3" reserved normal fleet claude pool profile pending none' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$data" "$id" \
    || fail "normal pinned account-lineage append failed"
  assert_grep 'event=reserved attempt=normal' "$original/account-attempts.md" \
    "normal pinned account-lineage append lost its entry"
  before=$(cat "$original/account-attempts.md")
  FM_FILE_TRANSACTION_TEST_READY="$ready" FM_FILE_TRANSACTION_TEST_PROCEED="$proceed" \
    bash -c '. "$1"; fm_account_lineage_append "$2" "$3" reserved attempt fleet claude pool profile pending none' \
      _ "$ROOT/bin/fm-account-routing-lib.sh" "$data" "$id" > "$TMP_ROOT/lineage-parent-race/out" 2>&1 &
  writer_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  if [ ! -e "$ready" ]; then
    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
    fail "account-lineage transaction never pinned its task directory"
  fi
  mv "$original" "$moved"
  ln -s "$outside" "$original"
  : > "$proceed"
  set +e
  wait "$writer_pid"
  writer_rc=$?
  set -e
  [ "$writer_rc" -ne 0 ] || fail "account-lineage transaction accepted a replaced task parent"
  [ "$(cat "$outside/account-attempts.md")" = 'outside lineage sentinel' ] \
    || fail "account-lineage transaction wrote through a raced task parent"
  [ "$(cat "$moved/account-attempts.md")" = "$before" ] \
    || fail "failed account-lineage transaction changed the pinned original file"
  assert_absent "$data/.account-lineage-$id.lock" "failed account-lineage transaction retained its serialization lock"
  pass "account lineage rejects parent swaps during pinned atomic persistence"
}

test_agent_fleet_contract_is_validated_before_routing() {
  local id rec out status
  id=account-contract-z26
  rec=$(make_case contract claude "$id")
  read_case "$rec"
  if out=$(FM_FAKE_AF_CONTRACT_VERSION=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "incompatible Agent Fleet contract unexpectedly enforced routing"
  assert_not_grep 'lease (choose|acquire)' "$AF_LOG" "incompatible Agent Fleet contract mutated a lease"
  assert_contains "$out" "unsupported Agent Fleet contract version 1" "contract mismatch was not actionable"
  pass "Agent Fleet contract v2 is required before legacy fixture enforcement"
}

test_agent_fleet_entrypoint_is_physically_pinned_per_operation() {
  local dir releases releases_physical current pathbin log out unsafe shadow_status release
  dir="$TMP_ROOT/agent-fleet-physical-pin"
  releases="$dir/releases"
  current="$dir/current"
  pathbin="$dir/bin"
  log="$dir/invocations"
  mkdir -p "$releases/r1" "$releases/r2" "$pathbin"
  releases_physical=$(cd "$releases" && pwd -P)
  : > "$log"
  for release in r1 r2; do
    cat > "$releases/$release/agent-fleet" <<SH
#!/usr/bin/env bash
printf '$release:%s\n' "\$*" >> '$log'
case "\$*" in
  '--format json contract') printf '{"contract_version":2}\n' ;;
  *' lease release '*) printf '{"ok":true}\n' ;;
  *) exit 64 ;;
esac
SH
    chmod 755 "$releases/$release/agent-fleet"
  done
  ln -s "$releases/r1" "$current"
  ln -s "$current/agent-fleet" "$pathbin/agent-fleet"

  out=$(PATH="$pathbin:/usr/bin:/bin" FM_TEST_PIN_CURRENT="$current" \
    FM_TEST_PIN_RELEASE_TWO="$releases/r2" bash -c '
      . "$1"
      fm_account_pin_fleet_bin || exit 1
      pinned=$FM_ACCOUNT_FLEET_PINNED_BIN
      rm "$FM_TEST_PIN_CURRENT"
      ln -s "$FM_TEST_PIN_RELEASE_TWO" "$FM_TEST_PIN_CURRENT"
      command=$(fm_account_exec_command claude-1 claude-crew task "$PWD" "$PWD/end") || exit 1
      fm_account_release task --force >/dev/null || exit 1
      printf "%s\n%s\n" "$pinned" "$command"
    ' _ "$ROOT/bin/fm-account-routing-lib.sh") \
    || fail "physical Agent Fleet pin fixture failed"
  assert_contains "$out" "$releases_physical/r1/agent-fleet" "operation did not pin the physical release-one entrypoint"
  assert_not_contains "$out" "$releases_physical/r2/agent-fleet" "current switch changed the operation's pinned entrypoint"
  assert_grep 'r1:' "$log" "pinned release one was never executed"
  assert_not_grep 'r2:' "$log" "current switch executed release two inside the existing operation"

  unsafe="$dir/unsafe"
  mkdir -p "$unsafe"
  cat > "$unsafe/agent-fleet" <<SH
#!/usr/bin/env bash
printf 'unsafe-ran\n' >> '$log'
SH
  chmod 777 "$unsafe/agent-fleet"
  if PATH="$unsafe:$pathbin:/usr/bin:/bin" bash -c \
    '. "$1"; fm_account_pin_fleet_bin' _ "$ROOT/bin/fm-account-routing-lib.sh" >/dev/null 2>&1; then
    shadow_status=0
  else
    shadow_status=$?
  fi
  [ "$shadow_status" -ne 0 ] || fail "writable PATH shadow was accepted as Agent Fleet"
  assert_not_grep 'unsafe-ran' "$log" "writable PATH shadow executed during validation"

  if FM_AGENT_FLEET_BIN="$unsafe/agent-fleet" bash -c \
    '. "$1"; fm_account_pin_fleet_bin' _ "$ROOT/bin/fm-account-routing-lib.sh" >/dev/null 2>&1; then
    shadow_status=0
  else
    shadow_status=$?
  fi
  [ "$shadow_status" -ne 0 ] || fail "writable FM_AGENT_FLEET_BIN override was accepted"
  assert_not_grep 'unsafe-ran' "$log" "writable override executed during validation"

  out=$(FM_AGENT_FLEET_BIN="$pathbin/agent-fleet" bash -c \
    '. "$1"; fm_account_fleet_bin' _ "$ROOT/bin/fm-account-routing-lib.sh") \
    || fail "safe override did not resolve to its physical release"
  [ "$out" = "$releases_physical/r2/agent-fleet" ] \
    || fail "safe override did not return the canonical physical path: $out"

  ln "$releases/r2/agent-fleet" "$dir/agent-fleet-hardlink"
  if FM_AGENT_FLEET_BIN="$pathbin/agent-fleet" bash -c \
    '. "$1"; fm_account_fleet_bin' _ "$ROOT/bin/fm-account-routing-lib.sh" >/dev/null 2>&1; then
    shadow_status=0
  else
    shadow_status=$?
  fi
  [ "$shadow_status" -ne 0 ] || fail "hardlinked Agent Fleet entrypoint was accepted"
  pass "Agent Fleet resolves one safe physical release per operation and rejects PATH shadows"
}


test_agent_fleet_validation_ignores_ambient_system_tool_shadows() {
  local dir fakebin safe log out tool perl_lib perl_marker lock_state stale_lock loader_env bash_env
  dir="$TMP_ROOT/agent-fleet-system-tool-pin"
  fakebin="$dir/fakebin"
  safe="$dir/release/agent-fleet"
  log="$dir/ambient-tools-ran"
  perl_lib="$dir/perl-lib"
  perl_marker="$dir/perl-injection-ran"
  loader_env="$dir/loader-env"
  bash_env="$dir/hostile-bash-env"
  mkdir -p "$fakebin" "${safe%/*}" "$perl_lib"
  cat > "$safe" <<'SH'
#!/bin/sh
exit 0
SH
  chmod 755 "$safe"
  : > "$log"
  for tool in perl uname stat id jq dirname rm mv ln mkdir rmdir mktemp sleep cp sed date env basename cat awk; do
    cat > "$fakebin/$tool" <<SH
#!/bin/sh
printf '%s\n' '$tool' >> '$log'
exit 97
SH
    chmod 755 "$fakebin/$tool"
  done
  lock_state="$dir/lock-state"
  stale_lock="$lock_state/.account-meta-hostile-tools.lock"
  mkdir -p "$stale_lock"
  printf '999999\nMon Jan  1 00:00:00 2001\n' > "$stale_lock/owner"
  cat > "$perl_lib/BridgeFleetEvil.pm" <<'PERL'
package BridgeFleetEvil;
BEGIN {
  open my $fh, '>', $ENV{FM_PERL_INJECTION_MARKER} or die $!;
  print {$fh} "ambient Perl injection executed\n";
  close $fh;
}
1;
PERL
  cat > "$bash_env" <<SH
printf 'BASH_ENV injection executed\n' > '$perl_marker'
SH
  out=$(PATH="$fakebin" PERL5OPT=-MBridgeFleetEvil PERL5LIB="$perl_lib" \
    PERLLIB="$perl_lib" FM_PERL_INJECTION_MARKER="$perl_marker" /bin/bash -c \
    '. "$1"
     export LD_PRELOAD=/tmp/hostile.so DYLD_INSERT_LIBRARIES=/tmp/hostile.dylib
     export NODE_OPTIONS="--require /tmp/hostile-node.js" PYTHONPATH=/tmp/hostile-python
     export BASH_ENV="$6" FM_LOADER_ENV_LOG="$7"
     binary=$(fm_account_fleet_bin "$2") || exit 1
     selected=$(fm_account_json_field "$3" "$4" selection) || exit 1
     lock=$(FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 fm_account_meta_lock_acquire "$5" hostile-tools) || exit 1
     fm_account_meta_lock_release "$lock" || exit 1
     fm_account_system_exec /bin/bash -c '\''printf "%s|%s|%s|%s|%s\n" "${LD_PRELOAD-}" "${DYLD_INSERT_LIBRARIES-}" "${NODE_OPTIONS-}" "${PYTHONPATH-}" "${BASH_ENV-}" > "$FM_LOADER_ENV_LOG"'\'' || exit 1
     printf "%s\n%s\n" "$binary" "$selected"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$safe" '{"profile":"claude-1"}' \
    '.profile | select(type == "string" and length > 0)' "$lock_state" "$bash_env" "$loader_env") \
    || fail "fixed-tool Agent Fleet validation failed under hostile PATH"
  [ "${out%%$'\n'*}" = "$(cd "${safe%/*}" && pwd -P)/${safe##*/}" ] \
    || fail "fixed-tool validation returned the wrong physical entrypoint: $out"
  [ "${out##*$'\n'}" = claude-1 ] \
    || fail "hostile jq forged an Agent Fleet selection field: $out"
  PATH="$fakebin:/usr/bin:/bin" "$SESSION_SYNC" --help >/dev/null \
    || fail "session-sync could not self-locate under hostile PATH"
  [ ! -s "$log" ] || fail "Agent Fleet validation executed ambient system-tool shadows: $(cat "$log")"
  [ ! -e "$perl_marker" ] || fail "Agent Fleet validation honored ambient PERL5OPT/PERLLIB injection"
  [ "$(cat "$loader_env")" = '||||' ] \
    || fail "fixed system control inherited loader/runtime injection: $(cat "$loader_env")"
  [ ! -e "$stale_lock" ] || fail "hostile-path lock lifecycle did not reclaim and release its stale generation"
  pass "Agent Fleet validation and lock recovery pin system tools and scrub Perl injection"
}

test_production_routing_ignores_ambient_mode_and_forbids_binary_override() {
  local dir mode marker fake_ps ps_probe selected_ps status
  dir="$TMP_ROOT/production-routing-authority"
  mkdir -p "$dir/config"
  printf 'enforce\n' > "$dir/config/account-routing-mode"
  # Arguments are intentionally expanded by bash -c.
  # shellcheck disable=SC2016
  mode=$(env -u FM_ACCOUNT_ROUTING_TEST_LAB FM_ACCOUNT_ROUTING=off bash -c '
    . "$1"
    fm_account_resolve_mode "$2" 0 0
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$dir/config") \
    || fail "production routing mode could not be resolved"
  [ "$mode" = enforce ] || fail "ambient FM_ACCOUNT_ROUTING bypassed authoritative config: $mode"

  marker="$dir/override-ran"
  cat > "$dir/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$marker'
SH
  chmod 755 "$dir/agent-fleet"
  # $1 is intentionally expanded by bash -c.
  # shellcheck disable=SC2016
  if env -u FM_ACCOUNT_ROUTING_TEST_LAB FM_AGENT_FLEET_BIN="$dir/agent-fleet" bash -c \
    '. "$1"; fm_account_fleet_bin' _ "$ROOT/bin/fm-account-routing-lib.sh" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "production accepted an Agent Fleet executable override"
  [ ! -e "$marker" ] || fail "forbidden production Agent Fleet override executed"
  fake_ps="$dir/fake-ps"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_ps"
  chmod 755 "$fake_ps"
  # $1 is intentionally expanded by bash -c.
  # shellcheck disable=SC2016
  ps_probe='. "$1"; fm_account_ps_bin'
  selected_ps=$(env -u FM_ACCOUNT_ROUTING_TEST_LAB \
    FM_ACCOUNT_TEST_HOOKS=firstmate-account-tests-v1 \
    FM_TEST_ACCOUNT_PS_BIN="$fake_ps" bash -c \
    "$ps_probe" _ "$ROOT/bin/fm-account-routing-lib.sh") \
    || fail "production could not select its fixed ps binary"
  [ "$selected_ps" != "$fake_ps" ] \
    || fail "production accepted the test ps hook without the exact test-lab opt-in"
  pass "production routing config is authoritative and executable overrides are forbidden"
}

test_production_fleet_environment_is_closed_before_control_and_worker_exec() {
  local dir fake log marker bash_env prefix_log out canonical identity expected_prefix separator
  dir="$TMP_ROOT/production-fleet-environment"
  fake="$dir/fake-agent-fleet"
  log="$dir/invocations"
  marker="$dir/startup-injection-ran"
  bash_env="$dir/hostile-bash-env"
  prefix_log="$dir/worker-prefix"
  mkdir -p "$dir"
  cat > "$fake" <<PERL
#!/usr/bin/perl
use strict;
use warnings;
open my \$fh, '>>', '$log' or die \$!;
my @blocked = sort grep {
  /^(?:AGENT_FLEET_|QUOTA_AXI_|XDG_|BASH_FUNC_)/
    || /^(?:LD_|DYLD_|PERL|PYTHON|RUBY|NODE_)/
    || /^(?:BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PS4|BASH_XTRACEFD|KSHENV|ZDOTDIR|GCONV_PATH)\$/
} keys %ENV;
print {\$fh} "argv=", join("\x1f", @ARGV), "\n";
print {\$fh} "blocked=", join(",", @blocked), "\n";
print {\$fh} "identity=", join("|", map { \$ENV{\$_} // "" } qw(HOME USER LOGNAME)), "\n";
print {\$fh} "path=", (\$ENV{PATH} // ""), "\n";
print {\$fh} "locale=", (\$ENV{LC_ALL} // ""), "|", (\$ENV{LANG} // ""), "\n";
print {\$fh} "sentinel=", (\$ENV{FM_WORKER_SENTINEL} // ""), "\n";
close \$fh;
print "{\"contract_version\":2,\"ok\":true}\n";
PERL
  chmod 755 "$fake"
  cat > "$bash_env" <<SH
/usr/bin/touch '$marker'
SH

  # shellcheck disable=SC2016  # Dollar expressions belong to the nested shell.
  out=$(env -u FM_ACCOUNT_ROUTING_TEST_LAB /bin/bash --noprofile --norc -c '
    . "$1"
    export AGENT_FLEET_CONFIG=/tmp/hostile-config
    export AGENT_FLEET_STATE_DIR=/tmp/hostile-state
    export AGENT_FLEET_FUTURE_REDIRECT=/tmp/hostile-future
    export QUOTA_AXI_CACHE_DIR=/tmp/hostile-quota
    export QUOTA_AXI_FUTURE_REDIRECT=/tmp/hostile-quota-future
    export XDG_CONFIG_HOME=/tmp/hostile-xdg
    export BASH_ENV="$4"
    export FM_WORKER_SENTINEL=preserved
    fm_account_run_control "$2" --format json contract >/dev/null || exit 1
    fm_account_run_selection "$2" --format json choose --pool claude-crew --task probe --provider claude --workspace "$PWD" --dry-run >/dev/null || exit 1
    fm_account_reconcile_lease_mutation "$2" probe "$PWD" probe >/dev/null || exit 1
    prefix=$(fm_account_fleet_worker_prefix "$2") || exit 1
    printf "%s\n" "$prefix" > "$5"
    export SHELLOPTS BASHOPTS PS4
    hostile_exported_function() { /usr/bin/touch "$3"; }
    export -f hostile_exported_function
    eval "$prefix --format json contract" >/dev/null || exit 1
    "$FM_ACCOUNT_SYSTEM_ENV_BIN" \
      SHELLOPTS=xtrace "PS4=\$(/usr/bin/touch '\''$3'\'')" \
      "BASH_FUNC_hostile_direct%%=() { /usr/bin/touch '\''$3'\''; }" \
      AGENT_FLEET_CONFIG=/tmp/direct-hostile-config \
      QUOTA_AXI_CACHE_DIR=/tmp/direct-hostile-quota \
      XDG_CONFIG_HOME=/tmp/direct-hostile-xdg \
      FM_WORKER_SENTINEL=preserved \
      LD_PRELOAD= LD_LIBRARY_PATH= LD_AUDIT= LD_DEBUG= \
      DYLD_INSERT_LIBRARIES= DYLD_LIBRARY_PATH= DYLD_FRAMEWORK_PATH= \
      DYLD_FALLBACK_LIBRARY_PATH= DYLD_FALLBACK_FRAMEWORK_PATH= \
      PERL5OPT= PERL5LIB= PERLLIB= NODE_OPTIONS= NODE_PATH= \
      PYTHONHOME= PYTHONPATH= RUBYOPT= RUBYLIB= BASH_ENV= ENV= GCONV_PATH= \
      "$FM_ACCOUNT_SYSTEM_PERL_BIN" -e "$FM_ACCOUNT_WORKER_PERL_PROGRAM" \
      "$FM_ACCOUNT_PASSWD_HOME" "$FM_ACCOUNT_PASSWD_NAME" \
      "$FM_ACCOUNT_CANONICAL_CONFIG" "$2" --format json contract >/dev/null || exit 1
    printf "%s\n%s|%s|%s\n" "$FM_ACCOUNT_CANONICAL_CONFIG" \
      "$FM_ACCOUNT_PASSWD_HOME" "$FM_ACCOUNT_PASSWD_NAME" "$FM_ACCOUNT_PASSWD_NAME"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$fake" "$marker" "$bash_env" "$prefix_log") \
    || fail "production Fleet launcher did not close hostile authority environment"

  canonical=${out%%$'\n'*}
  identity=${out##*$'\n'}
  separator=$(printf '\037')
  expected_prefix="argv=--config${separator}${canonical}${separator}"
  [ "$(grep -Fc "$expected_prefix" "$log")" -eq 5 ] \
    || fail "not every Fleet path pinned the canonical config before its command: $(cat "$log")"
  [ "$(grep -c '^blocked=$' "$log")" -eq 5 ] \
    || fail "Fleet child inherited a hostile authority/startup variable: $(cat "$log")"
  [ "$(grep -Fc "identity=$identity" "$log")" -eq 5 ] \
    || fail "Fleet child did not use the passwd identity: $(cat "$log")"
  [ "$(grep -c '^path=/usr/bin:/bin:/usr/sbin:/sbin$' "$log")" -eq 3 ] \
    || fail "Fleet control paths did not use the closed system PATH: $(cat "$log")"
  [ "$(grep -c '^locale=C|C$' "$log")" -eq 3 ] \
    || fail "Fleet control paths did not use the closed locale: $(cat "$log")"
  [ "$(grep -c '^sentinel=$' "$log")" -eq 3 ] \
    || fail "closed Fleet control unexpectedly retained worker environment"
  [ "$(grep -c '^sentinel=preserved$' "$log")" -eq 2 ] \
    || fail "worker Fleet launcher discarded intentional non-routing environment"
  assert_not_contains "$(cat "$prefix_log")" "/bash" \
    "worker Fleet launcher reintroduced a shell before environment scrubbing"
  assert_contains "$(cat "$prefix_log")" "/perl" \
    "worker Fleet launcher did not use the fixed pre-shell scrubber"
  [ ! -e "$marker" ] \
    || fail "hostile shell startup or exported-function injection executed before Fleet"
  pass "production Fleet control, selection, recovery, and workers close authority environment before startup"
}

test_agent_fleet_lifecycle_calls_are_bounded() {
  local id rec out status started elapsed
  id=account-control-timeout-z27
  rec=$(make_case control-timeout claude "$id")
  read_case "$rec"
  started=$(date +%s)
  if out=$(FM_FAKE_AF_SELECT_SLEEP=10 FM_ACCOUNT_CONTROL_TIMEOUT=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ] || fail "timed-out lease choice was not reconciled through recovery: $out"
  # Semantic: returns well under the 10s unbounded fake sleep; 8s absorbs full-sweep scheduling load (5s flaked in-sweep while passing standalone).
  [ "$elapsed" -lt 8 ] || fail "lease choice timeout was not bounded (elapsed ${elapsed}s)"
  assert_grep 'lease recover ' "$AF_LOG" "timed-out lease choice did not reconcile ownership"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  started=$(date +%s)
  if out=$(FM_FAKE_AF_RELEASE_SLEEP=10 FM_ACCOUNT_CONTROL_TIMEOUT=1 run_teardown "$id" --force 2>&1); then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "ambiguous timed-out lease release unexpectedly completed teardown"
  # Semantic: returns well under the 10s unbounded fake sleep; 8s absorbs full-sweep scheduling load (5s flaked in-sweep while passing standalone).
  [ "$elapsed" -lt 8 ] || fail "lease release timeout was not bounded (elapsed ${elapsed}s)"
  assert_present "$HOME_DIR/state/$id.meta" "ambiguous lease release discarded retry metadata"
  pass "Agent Fleet lease mutations are bounded and ambiguous outcomes retain ownership state"
}

# Test doubles and environment values below are consumed indirectly by the
# sourced routing functions.
# shellcheck disable=SC2034,SC2329
test_agent_fleet_selection_timeout_is_scoped_and_backward_compatible() {
  local out invalid log workspace
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  fm_account_run_bounded() {
    printf '%s:%s\n' "$1" "$2"
  }

  unset FM_ACCOUNT_CONTROL_TIMEOUT FM_ACCOUNT_SELECTION_TIMEOUT
  out=$(fm_account_run_control ordinary; fm_account_run_selection selection)
  [ "$out" = $'10:ordinary\n120:selection' ] \
    || fail "default account timeouts were not ordinary=10s selection=120s: $out"

  FM_ACCOUNT_CONTROL_TIMEOUT=17
  unset FM_ACCOUNT_SELECTION_TIMEOUT
  out=$(fm_account_run_control ordinary; fm_account_run_selection selection)
  [ "$out" = $'17:ordinary\n17:selection' ] \
    || fail "legacy FM_ACCOUNT_CONTROL_TIMEOUT no longer overrides selection: $out"

  FM_ACCOUNT_SELECTION_TIMEOUT=43
  out=$(fm_account_run_control ordinary; fm_account_run_selection selection)
  [ "$out" = $'17:ordinary\n43:selection' ] \
    || fail "selection-specific timeout did not leave ordinary control unchanged: $out"

  invalid="$TMP_ROOT/selection-timeout-invalid"
  if FM_ACCOUNT_SELECTION_TIMEOUT=invalid fm_account_selection_timeout > /dev/null 2> "$invalid"; then
    fail "invalid FM_ACCOUNT_SELECTION_TIMEOUT was accepted"
  fi
  assert_contains "$(cat "$invalid")" "FM_ACCOUNT_SELECTION_TIMEOUT must be a positive integer" \
    "invalid selection timeout diagnostic did not name its variable"

  log="$TMP_ROOT/selection-timeout.calls"
  workspace="$TMP_ROOT/selection-timeout-workspace"
  mkdir -p "$workspace"
  : > "$log"
  FM_ACCOUNT_CONTROL_TIMEOUT=
  FM_ACCOUNT_SELECTION_TIMEOUT=37
  fm_account_fleet_bin() { printf '%s\n' fake-agent-fleet; }
  fm_account_validate_contract() { return 0; }
  fm_account_run_bounded() {
    local seconds=$1 task=task pool=pool profile=claude-1 provider=claude workspace='' argument
    shift
    printf '%s|%s\n' "$seconds" "$*" >> "$log"
    while [ "$#" -gt 0 ]; do
      argument=$1
      shift
      case "$argument" in
        --task) task=$1; shift ;;
        --pool) pool=$1; shift ;;
        --profile) profile=$1; shift ;;
        --provider) provider=$1; shift ;;
        --workspace) workspace=$1; shift ;;
      esac
    done
    printf '{"task":"%s","pool":"%s","profile":"%s","provider":"%s","workspace":"%s"}\n' \
      "$task" "$pool" "$profile" "$provider" "$workspace"
  }

  fm_account_select observe claude pool '' choose-task "$workspace" >/dev/null \
    || fail "observe selection timeout probe failed"
  fm_account_select enforce claude explicit claude-1 acquire-task "$workspace" >/dev/null \
    || fail "explicit acquire timeout probe failed"
  fm_account_select enforce claude pool '' dynamic-task "$workspace" >/dev/null \
    || fail "dynamic choose timeout probe failed"
  fm_account_recover recover-task claude-1 pool claude "$workspace" >/dev/null \
    || fail "sticky recover timeout probe failed"
  fm_account_reconcile_lease_mutation fake-agent-fleet reconcile-task "$workspace" reconcile \
    >/dev/null || fail "reconciliation timeout probe failed"
  fm_account_release release-task --force >/dev/null \
    || fail "ordinary release timeout probe failed"

  assert_regex '^37\|fake-agent-fleet --format json choose ' "$log" \
    "observe choose did not use the selection timeout"
  assert_regex '^37\|fake-agent-fleet --format json lease acquire ' "$log" \
    "explicit acquire did not use the selection timeout"
  assert_regex '^37\|fake-agent-fleet --format json lease choose ' "$log" \
    "lease choose did not use the selection timeout"
  [ "$(grep -Ec '^37\|fake-agent-fleet --format json lease recover ' "$log")" -eq 2 ] \
    || fail "recover and reconciliation did not both use the selection timeout"
  assert_regex '^10\|fake-agent-fleet --format json lease release ' "$log" \
    "ordinary release no longer uses the 10-second control default"
  pass "Agent Fleet selection gets 120s by default with scoped and legacy overrides"
}

test_unsuccessful_lease_mutations_always_reconcile() {
  local id rec out status
  id=account-reconcile-failure-z27a
  rec=$(make_case reconcile-failure claude "$id")
  read_case "$rec"
  if out=$(FM_FAKE_AF_CHOOSE_FAIL_STATUS=42 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "non-timeout lease failure was not recovered: $out"
  assert_grep 'lease choose ' "$AF_LOG" "non-timeout lease failure never attempted selection"
  assert_grep 'lease recover ' "$AF_LOG" "non-timeout lease failure skipped ownership reconciliation"

  id=account-reconcile-ambiguous-z27b
  rec=$(make_case reconcile-ambiguous claude "$id")
  read_case "$rec"
  if out=$(FM_FAKE_AF_SELECT_FAIL=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "unreconciled lease mutation unexpectedly spawned"
  assert_grep 'lease recover ' "$AF_LOG" "failed lease mutation skipped recovery"
  assert_present "$HOME_DIR/state/$id.meta" "ambiguous lease mutation discarded rollback identity"
  assert_regex '^account_rollback_cleanup=pending$' "$HOME_DIR/state/$id.meta" \
    "ambiguous lease mutation lost its retry marker"
  pass "every unsuccessful lease mutation reconciles or retains rollback identity"
}

test_unsuccessful_recovery_mutation_is_retried() {
  local id rec out status account_task recover_count marker
  id=account-recover-reconcile-z27c
  rec=$(make_case recover-reconcile claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null \
    || fail "recovery reconciliation precondition spawn failed"
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  marker="$CASE_DIR/recover-failed-once"
  if out=$(FM_FAKE_AF_RECOVER_FAIL_ONCE_FILE="$marker" run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "non-timeout recovery failure was not reconciled: $out"
  recover_count=$(grep -F -c "lease recover --task $account_task" "$AF_LOG")
  [ "$recover_count" -eq 2 ] || fail "recovery mutation was attempted $recover_count times instead of twice"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  if out=$(FM_FAKE_AF_RECOVER_FAIL=1 run_spawn "$id" --resume-account); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "doubly failed sticky recovery unexpectedly succeeded"
  recover_count=$(grep -F -c "lease recover --task $account_task" "$AF_LOG")
  [ "$recover_count" -eq 2 ] || fail "doubly failed recovery was attempted $recover_count times instead of twice"
  assert_not_grep "lease release --task $account_task --force" "$AF_LOG" \
    "doubly failed recovery force-released a pre-existing reservation"
  assert_grep "account_task=$account_task" "$HOME_DIR/state/$id.meta" \
    "doubly failed recovery discarded sticky reservation identity"
  pass "unsuccessful sticky recovery retries without claiming uncertain ownership"
}

test_lease_signal_handoff_publishes_cleanup_ownership() {
  local observed="$TMP_ROOT/lease-signal-handoff" status
  mkdir -p "${observed%/*}"
  rm -f "$observed"
  set +e
  FM_TEST_LEASE_HANDOFF_OBSERVED="$observed" bash -c '
    set -u
    . "$1"
    fm_account_fleet_bin() { printf "%s\n" fake-agent-fleet; }
    fm_account_validate_contract() { return 0; }
    fm_account_run_selection() {
      kill -TERM "$$"
      printf "%s\n" "{\"task\":\"task-signal\",\"pool\":\"pool-signal\",\"profile\":\"profile-signal\",\"provider\":\"claude\",\"workspace\":\"${FM_TEST_LEASE_HANDOFF_OBSERVED%/*}\"}"
    }
    trap '\''printf "%s\n" "${FM_ACCOUNT_MUTATION_ACQUIRED:-unset}" > "$FM_TEST_LEASE_HANDOFF_OBSERVED"'\'' EXIT
    fm_account_select enforce claude pool-signal "" task-signal "${FM_TEST_LEASE_HANDOFF_OBSERVED%/*}"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "lease handoff signal unexpectedly allowed selection to continue"
  assert_regex '^1$' "$observed" \
    "lease ownership was not cleanup-visible before the deferred signal was delivered"
  pass "lease mutation defers signals until cleanup-visible ownership handoff"
}

test_recovery_signal_handoff_publishes_cleanup_ownership() {
  local observed="$TMP_ROOT/recovery-signal-handoff" invalid="$TMP_ROOT/recovery-invalid-handoff" status
  mkdir -p "${observed%/*}"
  rm -f "$observed"
  set +e
  FM_TEST_LEASE_HANDOFF_OBSERVED="$observed" bash -c '
    set -u
    . "$1"
    fm_account_fleet_bin() { printf "%s\n" fake-agent-fleet; }
    fm_account_validate_contract() { return 0; }
    fm_account_run_selection() {
      kill -TERM "$$"
      printf "%s\n" "{\"task\":\"task-recover\",\"pool\":\"pool-recover\",\"profile\":\"profile-recover\",\"provider\":\"claude\",\"workspace\":\"${FM_TEST_LEASE_HANDOFF_OBSERVED%/*}\"}"
    }
    trap '\''printf "%s\n" "${FM_ACCOUNT_MUTATION_ACQUIRED:-unset}" > "$FM_TEST_LEASE_HANDOFF_OBSERVED"'\'' EXIT
    fm_account_recover task-recover profile-recover pool-recover claude "${FM_TEST_LEASE_HANDOFF_OBSERVED%/*}"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "sticky recovery handoff signal unexpectedly allowed recovery to continue"
  assert_regex '^1$' "$observed" \
    "sticky recovery ownership was not cleanup-visible before the deferred signal was delivered"
  FM_TEST_LEASE_HANDOFF_OBSERVED="$invalid" bash -c '
    set -u
    . "$1"
    fm_account_fleet_bin() { printf "%s\n" fake-agent-fleet; }
    fm_account_validate_contract() { return 0; }
    fm_account_run_selection() { printf "%s\n" "not-json"; }
    if fm_account_recover task-recover profile-recover pool-recover claude "${FM_TEST_LEASE_HANDOFF_OBSERVED%/*}"; then rc=0; else rc=$?; fi
    printf "%s:%s\n" "$rc" "${FM_ACCOUNT_MUTATION_ACQUIRED:-unset}" > "$FM_TEST_LEASE_HANDOFF_OBSERVED"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh"
  assert_regex '^2:1$' "$invalid" \
    "invalid sticky recovery output lost cleanup-visible lease ownership"
  pass "sticky recovery defers signals until cleanup-visible ownership handoff"
}

test_account_timeout_wrapper_uses_hard_kill_fallback() {
  local fakebin log status perl_bin
  fakebin=$(fm_fakebin "$TMP_ROOT/hard-timeout")
  log="$TMP_ROOT/hard-timeout.args"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_FAKE_TIMEOUT_LOG"
SH
  chmod +x "$fakebin/timeout"
  PATH="$fakebin:$PATH" FM_FAKE_TIMEOUT_LOG="$log" bash -c '
    . "$1"
    fm_account_run_bounded 3 true
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" || fail "account timeout wrapper invocation failed"
  assert_grep '--kill-after=1 3 true' "$log" "account timeout wrapper omitted the hard KILL fallback"

  status=$(PATH="$fakebin:$PATH" FM_FAKE_TIMEOUT_LOG="$log" bash -c '
    . "$1"
    cleanup() {
      local original=$? bounded_status
      set +e
      fm_account_run_control true
      bounded_status=$?
      printf "%s:%s\n" "$original" "$bounded_status"
    }
    trap cleanup EXIT
    false
  ' _ "$ROOT/bin/fm-account-routing-lib.sh")
  [ "$status" = 1:0 ] || fail "successful bounded control inherited a failing EXIT trap status ($status)"

  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exit 137
SH
  chmod +x "$fakebin/timeout"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_account_run_bounded 3 true' _ "$ROOT/bin/fm-account-routing-lib.sh"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 124 ] || fail "hard-kill timeout status was not normalized for reconciliation (status=$status)"

  perl_bin=$(command -v perl || true)
  if [ -n "$perl_bin" ]; then
    rm -rf "$fakebin"
    mkdir -p "$fakebin"
    ln -s "$perl_bin" "$fakebin/perl"
    cat > "$fakebin/signaled" <<'SH'
#!/bin/sh
kill -TERM $$
SH
    chmod +x "$fakebin/signaled"
    if PATH="$fakebin" /bin/bash -c '. "$1"; fm_account_run_bounded 3 "$2"' \
      _ "$ROOT/bin/fm-account-routing-lib.sh" "$fakebin/signaled"; then
      status=0
    else
      status=$?
    fi
    [ "$status" -eq 143 ] || fail "Perl timeout fallback converted a signaled child into success (status=$status)"
  fi
  pass "Agent Fleet control timeouts force-kill TERM-resistant subprocesses"
}

test_teardown_stops_after_rollback_restores_predecessor() {
  local id rec old_task failed_task out status
  id=account-teardown-restore-z28
  rec=$(make_case teardown-restore claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "rollback restore precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  if out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" --continue-account --account-profile claude-3); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "failed continuation precondition unexpectedly succeeded"
  failed_task=$(meta_account_task "$id")
  [ "$failed_task" != "$old_task" ] || fail "failed continuation did not install its rollback generation"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  if out=$(run_teardown "$id" --force 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "teardown continued after restoring predecessor metadata"
  [ "$(meta_account_task "$id")" = "$old_task" ] || fail "teardown did not preserve restored predecessor metadata"
  assert_not_grep "lease release --task $old_task" "$AF_LOG" "teardown released the restored predecessor in the stale generation pass"
  assert_contains "$out" "rerun teardown against the restored task generation" "rollback restoration retry guidance was not surfaced"

  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "restored predecessor could not be torn down on a fresh pass"
  assert_grep "lease release --task $old_task" "$AF_LOG" "fresh teardown did not release the restored predecessor"
  pass "teardown stops and revalidates after rollback restores predecessor state"
}

test_release_helpers_preserve_caller_errexit_state() {
  local id rec status
  id=account-errexit-preserve-z29
  rec=$(make_case errexit-preserve claude "$id")
  read_case "$rec"
  # shellcheck source=bin/fm-account-routing-lib.sh
  . "$ROOT/bin/fm-account-routing-lib.sh"
  FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet"
  export FM_AGENT_FLEET_BIN

  # spawn_abort_cleanup keeps errexit off for its whole rollback trap; the
  # release helpers must restore the caller's entry state, never force it on.
  set +e
  fm_account_release fm-errexit-release --force >/dev/null 2>&1
  status=$?
  case $- in *e*) fail "fm_account_release re-enabled errexit for an errexit-off caller" ;; esac
  [ "$status" -eq 0 ] || fail "fm_account_release failed under an errexit-off caller (exit $status)"

  FM_FAKE_AF_RELEASE_FAIL=1 fm_account_release fm-errexit-release --force >/dev/null 2>&1
  status=$?
  case $- in *e*) fail "failed fm_account_release re-enabled errexit for an errexit-off caller" ;; esac
  [ "$status" -eq 43 ] || fail "failed fm_account_release did not propagate its release status (exit $status)"

  fm_account_session_remove fm-errexit-release >/dev/null 2>&1
  status=$?
  case $- in *e*) fail "fm_account_session_remove re-enabled errexit for an errexit-off caller" ;; esac
  [ "$status" -eq 0 ] || fail "fm_account_session_remove failed under an errexit-off caller (exit $status)"

  FM_FAKE_AF_SESSION_REMOVE_FAIL=1 fm_account_session_remove fm-errexit-release >/dev/null 2>&1
  status=$?
  case $- in *e*) fail "failed fm_account_session_remove re-enabled errexit for an errexit-off caller" ;; esac
  [ "$status" -eq 44 ] || fail "failed fm_account_session_remove did not propagate its removal status (exit $status)"

  set -e
  fm_account_release fm-errexit-release --force >/dev/null 2>&1
  case $- in *e*) : ;; *) fail "fm_account_release dropped errexit for an errexit-on caller" ;; esac
  fm_account_session_remove fm-errexit-release >/dev/null 2>&1
  case $- in *e*) : ;; *) fail "fm_account_session_remove dropped errexit for an errexit-on caller" ;; esac
  set +e
  pass "release helpers preserve the caller's errexit state"
}

run_isolated_test() {
  # Run the isolating subshell as a plain command, never as an `if` condition:
  # a condition context suppresses errexit for the whole test body, so an
  # in-test `set -e` would be silently ignored.
  local status
  ( "$@" )
  status=$?
  [ "$status" -eq 0 ] || exit "$status"
}

if [ "${FM_TEST_FOCUSED:-}" = stale-reclaim-generation ]; then
  run_isolated_test test_stale_reclaim_guard_is_owned_before_lock_removal
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = checkout-freshness-cleanup ]; then
  run_isolated_test test_failed_freshness_proof_rolls_back_unmanaged_resources
  run_isolated_test test_local_only_spawn_uses_local_default_tip
  run_isolated_test test_dirty_acquisition_is_retained_without_force_return
  run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-40 ]; then
  run_isolated_test test_failed_freshness_proof_rolls_back_unmanaged_resources
  run_isolated_test test_local_only_spawn_uses_local_default_tip
  run_isolated_test test_dirty_acquisition_is_retained_without_force_return
  run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
  run_isolated_test test_unmanaged_rollback_waits_for_metadata_lock
  run_isolated_test test_reservation_occurs_after_worktree_preparation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-durable-secondmate ]; then
  run_isolated_test test_recovered_secondmate_kind_blocks_unsupported_cmux_backend_early
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-8 ]; then
  run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-4 ]; then
  run_isolated_test test_failed_freshness_proof_rolls_back_unmanaged_resources
  run_isolated_test test_treehouse_acquisition_timeout_is_bounded_before_endpoint_creation
  run_isolated_test test_changed_acquisition_is_retained_during_unmanaged_rollback
  run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12-ownership ]; then
  run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
  run_isolated_test test_spawn_rollback_relays_unverified_treehouse_cleanup
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = continuation-status-timeout ]; then
  run_isolated_test test_continuation_bounds_no_mistakes_status_snapshot
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = packet-rollback-aba ]; then
  run_isolated_test test_continuation_rollback_preserves_concurrent_packet_replacement
  exit 0
fi

test_secondmate_home_lock_key_fails_closed_without_fixed_hasher() {
  local home state out status
  home="$TMP_ROOT/secondmate-lock-key-home"
  state="$TMP_ROOT/secondmate-lock-key-state"
  mkdir -p "$home" "$state"
  set +e
  out=$(FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
    FM_ACCOUNT_TEST_HOOKS=firstmate-account-tests-v1 \
    bash -c '
      . "$1/bin/fm-account-routing-lib.sh"
      FM_CHECKOUT_SYSTEM_PERL_BIN=
      fm_secondmate_home_lifecycle_lock_acquire "$2" "$3"
    ' _ "$ROOT" "$state" "$home" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "secondmate home lock accepted an unavailable fixed hasher"
  assert_contains "$out" "lock identity is unavailable" \
    "secondmate home lock hash failure was not surfaced"
  [ -z "$(find "$state" -mindepth 1 -print -quit)" ] \
    || fail "secondmate home lock hash failure created a fallback lock"
  pass "secondmate home lifecycle locks fail closed without fixed hashing"
}

test_secondmate_home_lock_key_uses_filesystem_identity() {
  local home dotted case_alias missing_upper missing_lower key dotted_key case_key missing_upper_key missing_lower_key
  home="$TMP_ROOT/secondmate-lock-identity-home"
  mkdir -p "$home"
  dotted="$home/."
  key=$(bash -c '. "$1/bin/fm-account-routing-lib.sh"; fm_account_stable_path_key "$2" directory' _ "$ROOT" "$home") \
    || fail "secondmate home identity key was unavailable"
  dotted_key=$(bash -c '. "$1/bin/fm-account-routing-lib.sh"; fm_account_stable_path_key "$2" directory' _ "$ROOT" "$dotted") \
    || fail "dotted secondmate home identity key was unavailable"
  [ "$key" = "$dotted_key" ] || fail "one physical home produced different keys through a dotted alias"
  case_alias=$(printf '%s\n' "$home" | tr '[:lower:]' '[:upper:]')
  if [ "$case_alias" != "$home" ] && [ -d "$case_alias" ]; then
    case_key=$(bash -c '. "$1/bin/fm-account-routing-lib.sh"; fm_account_stable_path_key "$2" directory' _ "$ROOT" "$case_alias") \
      || fail "case-aliased secondmate home identity key was unavailable"
    [ "$key" = "$case_key" ] || fail "one physical home produced different keys through a case alias"
  fi
  missing_upper="$TMP_ROOT/Missing-Secondmate-Home"
  missing_lower="$TMP_ROOT/missing-secondmate-home"
  missing_upper_key=$(bash -c '. "$1/bin/fm-account-routing-lib.sh"; fm_account_stable_path_key "$2" directory' _ "$ROOT" "$missing_upper") \
    || fail "missing secondmate home identity key was unavailable"
  missing_lower_key=$(bash -c '. "$1/bin/fm-account-routing-lib.sh"; fm_account_stable_path_key "$2" directory' _ "$ROOT" "$missing_lower") \
    || fail "case-folded missing secondmate home identity key was unavailable"
  [ "$missing_upper_key" = "$missing_lower_key" ] \
    || fail "case aliases for one not-yet-created home produced different lifecycle keys"
  pass "secondmate home lifecycle keys follow filesystem identity"
}

if [ "${FM_TEST_FOCUSED:-}" = symlink-artifacts ]; then
  run_isolated_test test_task_owned_account_artifacts_reject_symlink_paths
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-races ]; then
  run_isolated_test test_secondmate_home_lock_key_fails_closed_without_fixed_hasher
  run_isolated_test test_secondmate_home_lock_key_uses_filesystem_identity
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = tail-safety ]; then
  run_isolated_test test_task_owned_account_artifacts_reject_symlink_paths
  run_isolated_test test_account_lineage_rejects_parent_swap_during_transaction
  run_isolated_test test_agent_fleet_contract_is_validated_before_routing
  run_isolated_test test_agent_fleet_lifecycle_calls_are_bounded
  run_isolated_test test_agent_fleet_selection_timeout_is_scoped_and_backward_compatible
  run_isolated_test test_unsuccessful_lease_mutations_always_reconcile
  run_isolated_test test_unsuccessful_recovery_mutation_is_retried
  run_isolated_test test_lease_signal_handoff_publishes_cleanup_ownership
  run_isolated_test test_account_timeout_wrapper_uses_hard_kill_fallback
  run_isolated_test test_teardown_stops_after_rollback_restores_predecessor
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = oversized-continuation ]; then
  run_isolated_test test_oversized_continuation_stops_before_mutation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = steering-audit ]; then
  run_isolated_test test_managed_steering_audit_failure_does_not_reclassify_delivery
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = unknown-continuation ]; then
  run_isolated_test test_continuation_refuses_unknown_endpoint_state
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = concurrent-continuation ]; then
  run_isolated_test test_concurrent_continuations_serialize_before_mutation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = unknown-endpoint-rollback ]; then
  run_isolated_test test_unknown_spawn_endpoint_retains_lease_for_retry
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = rollback-safety ]; then
  run_isolated_test test_secondmate_rollback_refuses_unsafe_tasktmp
  run_isolated_test test_rollback_backup_rejects_symlink_and_rechecks_under_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = enforce-select-failure ]; then
  run_isolated_test test_enforce_failure_rolls_back_prepared_endpoint
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = explicit-secondmate-route ]; then
  run_isolated_test test_explicit_secondmate_route_preserves_ambient_primary_enforce
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = secondmate-direct-scope ]; then
  run_isolated_test test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  run_isolated_test test_managed_recovery_accepts_inherited_lifecycle_lock
  run_isolated_test test_native_resume_requires_fresh_sessionstart_evidence
  run_isolated_test test_native_resume_rejects_prelaunch_sessionstart_evidence
  run_isolated_test test_native_resume_uses_private_launch_directory_and_cleans_it
  run_isolated_test test_ownerless_lock_marker_rejects_symlink_clobber
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12 ]; then
  run_isolated_test test_unmanaged_spawn_refuses_while_teardown_lifecycle_is_held
  run_isolated_test test_continuation_rejects_load_bearing_source_replacement_during_open
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  run_isolated_test test_account_lock_owner_controls_reject_symlinks
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-15 ]; then
  run_isolated_test test_inherited_lifecycle_lock_rejects_owner_aba
  run_isolated_test test_continuation_rejects_load_bearing_source_replacement_during_open
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-16 ]; then
  run_isolated_test test_managed_recovery_accepts_inherited_lifecycle_lock
  run_isolated_test test_inherited_lifecycle_handoff_releases_on_child_abort
  run_isolated_test test_off_metadata_merge_waits_for_metadata_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-findings ]; then
  run_isolated_test test_completion_contract_upgrade_is_contained_nonfollowing_and_atomic
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  run_isolated_test test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-19 ]; then
  run_isolated_test test_unsuccessful_lease_mutations_always_reconcile
  run_isolated_test test_unsuccessful_recovery_mutation_is_retried
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-20 ]; then
  run_isolated_test test_recovered_reservations_are_owned_only_after_validated_recovery
  run_isolated_test test_unsuccessful_recovery_mutation_is_retried
  run_isolated_test test_continuation_rejects_task_source_ancestor_swap
  run_isolated_test test_continuation_rejects_metadata_ancestor_swap
  run_isolated_test test_session_sync_all_bounds_each_task_and_reaches_later_mappings
  run_isolated_test test_completion_contract_ignores_raw_html_headings
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-21 ]; then
  run_isolated_test test_continuation_appends_the_validated_brief_snapshot
  run_isolated_test test_session_sync_all_has_one_total_task_timeout_budget
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-22 ]; then
  run_isolated_test test_continuation_reads_descendants_through_the_pinned_root
  run_isolated_test test_session_sync_all_rotates_a_bounded_parallel_batch
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-23 ]; then
  run_isolated_test test_continuation_pins_one_root_for_the_complete_task_snapshot
  run_isolated_test test_session_sync_all_signals_terminate_worker_groups
  run_isolated_test test_secondmate_routing_inheritance_is_authoritative_for_every_mode
  run_isolated_test test_malformed_routing_mode_fails_closed
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-24 ]; then
  run_isolated_test test_native_resume_accepts_same_wallclock_sessionstart_evidence
  run_isolated_test test_session_sync_removes_reaped_workers_from_cleanup_state
  run_isolated_test test_continuation_pins_packet_destination_directory
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = session-event-seq ]; then
  run_isolated_test test_native_resume_requires_fresh_sessionstart_evidence
  run_isolated_test test_native_resume_rejects_prelaunch_sessionstart_evidence
  run_isolated_test test_native_resume_accepts_same_wallclock_sessionstart_evidence
  run_isolated_test test_native_resume_migrates_legacy_session_mapping_after_launch_gate
  run_isolated_test test_native_resume_rejects_zero_sequence_on_current_schema
  run_isolated_test test_native_resume_accepts_regressed_wallclock_when_event_sequence_advances
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-25 ]; then
  run_isolated_test test_continuation_revalidates_repository_anchor_before_install
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-26 ]; then
  run_isolated_test test_continuation_revalidates_exact_repository_status_before_install
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-27 ]; then
  run_isolated_test test_continuation_removes_packet_when_repository_changes_during_install
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-28 ]; then
  run_isolated_test test_continuation_revalidates_dirty_tracked_content_before_install
  run_isolated_test test_continuation_revalidates_dirty_untracked_content_before_install
  run_isolated_test test_continuation_accepts_stable_tracked_deletion
  run_isolated_test test_continuation_restores_prior_packet_after_failed_postcheck
  run_isolated_test test_continuation_rollback_preserves_concurrent_packet_replacement
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-29 ]; then
  run_isolated_test test_reserved_generation_is_durable_before_lease_mutation
  run_isolated_test test_continuation_revalidates_dirty_submodule_content
  run_isolated_test test_continuation_repository_fingerprint_uses_pinned_root
  run_isolated_test test_continuation_rejects_root_swap_before_descriptor_open
  run_isolated_test test_continuation_packet_publication_is_generation_owned
  run_isolated_test test_continuation_prepublish_cas_preserves_unowned_replacement
  run_isolated_test test_continuation_reclaims_only_positively_stale_publish_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-30 ]; then
  run_isolated_test test_continuation_recovers_abandoned_reclaim_owner
  run_isolated_test test_continuation_no_prior_rollback_preserves_raced_replacement
  run_isolated_test test_task_file_publication_cas_preserves_concurrent_append
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-32 ]; then
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  run_isolated_test test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-33 ]; then
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  run_isolated_test test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
  run_isolated_test test_continuation_revalidates_dirty_submodule_content
  run_isolated_test test_continuation_submodule_fingerprint_excludes_ignored_caches
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34 ]; then
  run_isolated_test test_task_file_rollback_preserves_unowned_replacement_and_displaced_generation
  run_isolated_test test_task_file_rollback_preserves_displaced_generation_when_destination_disappears
  run_isolated_test test_continuation_generation_copy_requires_owned_source
  run_isolated_test test_submodule_timeout_terminates_process_group
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-lease ]; then
  run_isolated_test test_lease_signal_handoff_publishes_cleanup_ownership
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-35 ]; then
  run_isolated_test test_recovery_signal_handoff_publishes_cleanup_ownership
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  run_isolated_test test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
  run_isolated_test test_continuation_repository_fingerprint_uses_pinned_root
  run_isolated_test test_continuation_revalidates_dirty_submodule_content
  run_isolated_test test_account_lineage_rejects_parent_swap_during_transaction
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-36 ]; then
  run_isolated_test test_continuation_rejects_symlinked_charter_ancestor
  run_isolated_test test_continuation_rejects_present_empty_charter
  run_isolated_test test_continuation_fingerprint_deadline_covers_ordinary_paths
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-37 ]; then
  run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
  run_isolated_test test_continuation_fingerprint_budget_spans_all_path_classes
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-38 ]; then
  run_isolated_test test_continuation_deadline_starts_before_repository_enumeration
  run_isolated_test test_continuation_caps_repository_enumeration_output
  run_isolated_test test_continuation_deadline_covers_repository_parsing
  run_isolated_test test_continuation_fingerprint_deadline_covers_ordinary_paths
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-39 ]; then
  run_isolated_test test_submodule_timeout_terminates_process_group
  run_isolated_test test_bounded_command_reap_never_waits_unbounded
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-18 ]; then
  run_isolated_test test_completion_contract_upgrade_is_contained_nonfollowing_and_atomic
  run_isolated_test test_account_lineage_rejects_parent_swap_during_transaction
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = errexit-preserve ]; then
  run_isolated_test test_release_helpers_preserve_caller_errexit_state
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = session-workspace ]; then
  run_isolated_test test_session_sync_rejects_workspace_mismatch_without_metadata_change
  run_isolated_test test_native_resume_accepts_agent_fleet_utc_offset_timestamps
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = account-locks ]; then
  run_isolated_test test_account_metadata_lock_reclaims_orphans_without_overlapping_owners
  run_isolated_test test_account_locks_never_reclaim_on_indeterminate_process_probe
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = signal-handoff ]; then
  run_isolated_test test_lease_signal_handoff_publishes_cleanup_ownership
  run_isolated_test test_recovery_signal_handoff_publishes_cleanup_ownership
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = gate-e-workspace ]; then
  run_isolated_test test_enforce_pool_wraps_backend_and_records_real_session
  run_isolated_test test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure
  run_isolated_test test_lease_signal_handoff_publishes_cleanup_ownership
  run_isolated_test test_recovery_signal_handoff_publishes_cleanup_ownership
  run_isolated_test test_session_sync_rejects_workspace_mismatch_without_metadata_change
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = production-routing-authority ]; then
  run_isolated_test test_unused_secondmate_pool_never_blocks_unmanaged_spawn
  run_isolated_test test_agent_fleet_entrypoint_is_physically_pinned_per_operation
  run_isolated_test test_agent_fleet_validation_ignores_ambient_system_tool_shadows
  run_isolated_test test_linux_stat_selection_avoids_filesystem_stat_output
  run_isolated_test test_production_routing_ignores_ambient_mode_and_forbids_binary_override
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = production-fleet-environment ]; then
  run_isolated_test test_production_fleet_environment_is_closed_before_control_and_worker_exec
  exit 0
fi

run_isolated_test test_reserved_generation_is_durable_before_lease_mutation
run_isolated_test test_off_is_byte_compatible_and_never_calls_agent_fleet
run_isolated_test test_failed_freshness_proof_rolls_back_unmanaged_resources
run_isolated_test test_local_only_spawn_uses_local_default_tip
run_isolated_test test_dirty_acquisition_is_retained_without_force_return
run_isolated_test test_treehouse_acquisition_timeout_is_bounded_before_endpoint_creation
run_isolated_test test_changed_acquisition_is_retained_during_unmanaged_rollback
run_isolated_test test_unmanaged_postinstall_failure_restores_prior_state
run_isolated_test test_completion_contract_upgrade_is_contained_nonfollowing_and_atomic
run_isolated_test test_completion_contract_ignores_raw_html_headings
run_isolated_test test_enforce_pool_wraps_backend_and_records_real_session
run_isolated_test test_explicit_profile_uses_explicit_pool
run_isolated_test test_enforce_failure_rolls_back_prepared_endpoint
run_isolated_test test_pane_failure_happens_before_account_reservation
run_isolated_test test_batch_partial_failure_releases_only_failed_item
run_isolated_test test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure
run_isolated_test test_recovered_secondmate_kind_blocks_unsupported_cmux_backend_early
run_isolated_test test_managed_recovery_accepts_inherited_lifecycle_lock
run_isolated_test test_inherited_lifecycle_handoff_releases_on_child_abort
run_isolated_test test_inherited_lifecycle_lock_rejects_owner_aba
run_isolated_test test_unmanaged_spawn_refuses_while_teardown_lifecycle_is_held
run_isolated_test test_off_metadata_merge_waits_for_metadata_lock
run_isolated_test test_unmanaged_respawn_preserves_report_cutover_state
run_isolated_test test_failed_managed_respawn_restores_unmanaged_metadata
run_isolated_test test_preinstall_managed_failure_restores_artifact_snapshot
run_isolated_test test_session_sync_bounds_agent_fleet_queries
run_isolated_test test_session_sync_rejects_workspace_mismatch_without_metadata_change
run_isolated_test test_session_sync_all_bounds_each_task_and_reaches_later_mappings
run_isolated_test test_session_sync_removes_reaped_workers_from_cleanup_state
run_isolated_test test_session_sync_releases_metadata_lock_during_provider_query
run_isolated_test test_continuation_rejects_symlinked_charter_ancestor
run_isolated_test test_continuation_rejects_present_empty_charter
run_isolated_test test_recovered_reservations_are_owned_only_after_validated_recovery
run_isolated_test test_native_resume_requires_fresh_sessionstart_evidence
run_isolated_test test_native_resume_rejects_prelaunch_sessionstart_evidence
run_isolated_test test_native_resume_accepts_same_wallclock_sessionstart_evidence
run_isolated_test test_native_resume_migrates_legacy_session_mapping_after_launch_gate
run_isolated_test test_native_resume_rejects_zero_sequence_on_current_schema
run_isolated_test test_native_resume_accepts_agent_fleet_utc_offset_timestamps
run_isolated_test test_native_resume_uses_private_launch_directory_and_cleans_it
run_isolated_test test_secondmate_pool_is_nonactivating_and_noninherited
run_isolated_test test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits
run_isolated_test test_explicit_secondmate_route_preserves_ambient_primary_enforce
run_isolated_test test_enforced_secondmate_requires_routing_inheritance_and_capable_home
run_isolated_test test_secondmate_routing_inheritance_is_authoritative_for_every_mode
run_isolated_test test_managed_shared_namespace_secondmate_uses_primary_endpoint_scope
run_isolated_test test_unused_secondmate_pool_never_blocks_unmanaged_spawn
run_isolated_test test_agent_fleet_task_keys_are_namespaced_by_home_and_attempt
run_isolated_test test_duplicate_spawn_preserves_original_endpoint_and_lease
run_isolated_test test_reservation_occurs_after_worktree_preparation
run_isolated_test test_raw_enforced_launch_is_rejected_before_mutation
run_isolated_test test_global_enforce_refuses_unsupported_harnesses
run_isolated_test test_malformed_routing_mode_fails_closed
run_isolated_test test_invalid_selection_response_releases_reservation
run_isolated_test test_fresh_launch_requires_session_binding_and_fully_rolls_back
run_isolated_test test_failed_cleanup_persists_retryable_metadata
run_isolated_test test_unknown_spawn_endpoint_retains_lease_for_retry
run_isolated_test test_rollback_retry_rechecks_live_endpoint_before_release
run_isolated_test test_failed_secondmate_rollback_preserves_home_for_relaunch
run_isolated_test test_failed_secondmate_respawn_rollback_restores_prior_state
run_isolated_test test_explicit_secondmate_profile_ignores_configured_pool
run_isolated_test test_enforced_orca_is_rejected_before_owned_resource_creation
run_isolated_test test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
run_isolated_test test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
run_isolated_test test_cross_provider_continuation_uses_target_default_pool claude codex
run_isolated_test test_cross_provider_continuation_uses_target_default_pool codex claude
run_isolated_test test_continuation_refuses_unknown_endpoint_state
run_isolated_test test_missing_endpoint_target_retains_managed_lease
run_isolated_test test_predecessor_cleanup_failure_preserves_replacement_for_retry
run_isolated_test test_failed_continuation_cleanup_restores_predecessor_for_retry
run_isolated_test test_concurrent_continuations_serialize_before_mutation
run_isolated_test test_live_secondmate_recovery_precedes_home_convergence
run_isolated_test test_continuation_fails_closed_without_original_brief
run_isolated_test test_session_sync_cannot_recreate_metadata_after_teardown
run_isolated_test test_managed_steering_audit_failure_does_not_reclassify_delivery
run_isolated_test test_managed_tmux_identity_survives_window_rename
run_isolated_test test_native_resume_accepts_regressed_wallclock_when_event_sequence_advances
run_isolated_test test_session_sync_metadata_publish_failure_is_closed
run_isolated_test test_session_sync_lineage_failure_restores_unbound_metadata
run_isolated_test test_oversized_continuation_stops_before_mutation
run_isolated_test test_continuation_bounds_no_mistakes_status_snapshot
run_isolated_test test_continuation_caps_informational_snapshots_only
run_isolated_test test_continuation_rejects_symlinked_packet_destination
run_isolated_test test_continuation_pins_packet_destination_directory
run_isolated_test test_continuation_revalidates_repository_anchor_before_install
run_isolated_test test_continuation_revalidates_exact_repository_status_before_install
run_isolated_test test_continuation_revalidates_dirty_tracked_content_before_install
run_isolated_test test_continuation_revalidates_dirty_untracked_content_before_install
run_isolated_test test_continuation_accepts_stable_tracked_deletion
run_isolated_test test_continuation_fingerprint_deadline_covers_ordinary_paths
run_isolated_test test_bounded_command_reap_never_waits_unbounded
run_isolated_test test_continuation_deadline_starts_before_repository_enumeration
run_isolated_test test_continuation_caps_repository_enumeration_output
run_isolated_test test_continuation_deadline_covers_repository_parsing
run_isolated_test test_continuation_removes_packet_when_repository_changes_during_install
run_isolated_test test_continuation_restores_prior_packet_after_failed_postcheck
run_isolated_test test_continuation_rollback_preserves_concurrent_packet_replacement
run_isolated_test test_continuation_rejects_load_bearing_source_replacement_during_open
run_isolated_test test_continuation_rejects_task_source_ancestor_swap
run_isolated_test test_continuation_rejects_metadata_ancestor_swap
run_isolated_test test_account_metadata_lock_reclaims_orphans_without_overlapping_owners
run_isolated_test test_account_locks_never_reclaim_on_indeterminate_process_probe
run_isolated_test test_ownerless_lock_marker_rejects_symlink_clobber
run_isolated_test test_account_lock_owner_controls_reject_symlinks
run_isolated_test test_linux_stat_selection_avoids_filesystem_stat_output
run_isolated_test test_stale_reclaim_guard_is_owned_before_lock_removal
run_isolated_test test_task_owned_account_artifacts_reject_symlink_paths
run_isolated_test test_secondmate_home_lock_key_fails_closed_without_fixed_hasher
run_isolated_test test_secondmate_home_lock_key_uses_filesystem_identity
run_isolated_test test_account_lineage_rejects_parent_swap_during_transaction
run_isolated_test test_agent_fleet_contract_is_validated_before_routing
run_isolated_test test_agent_fleet_entrypoint_is_physically_pinned_per_operation
run_isolated_test test_agent_fleet_validation_ignores_ambient_system_tool_shadows
run_isolated_test test_production_routing_ignores_ambient_mode_and_forbids_binary_override
run_isolated_test test_production_fleet_environment_is_closed_before_control_and_worker_exec
run_isolated_test test_agent_fleet_lifecycle_calls_are_bounded
run_isolated_test test_agent_fleet_selection_timeout_is_scoped_and_backward_compatible
run_isolated_test test_unsuccessful_lease_mutations_always_reconcile
run_isolated_test test_unsuccessful_recovery_mutation_is_retried
run_isolated_test test_lease_signal_handoff_publishes_cleanup_ownership
run_isolated_test test_account_timeout_wrapper_uses_hard_kill_fallback
run_isolated_test test_teardown_stops_after_rollback_restores_predecessor
run_isolated_test test_release_helpers_preserve_caller_errexit_state

echo "# all fm-account-routing tests passed"
