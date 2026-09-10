#!/usr/bin/env bash
# Focused safety tests for bin/fm-herdr-session-cleanup.sh.
# Covers one exact cleanup, every title/journal/topology/agent/process refusal,
# locked revalidation races, focus refusal, read errors, and repeat idempotence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-cleanup)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
touch "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
printf '%s\n' herdr > "$FM_CONFIG_OVERRIDE/backend"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
fm_fake_quota_axi "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

# The idle-shell proof now lives in the backend as
# fm_backend_herdr_pane_idle_shell_pid; prove it still reads Linux argv
# arrays (no argv0 field) and rejects malformed executable identities.
FAKE_PS="$TMP_ROOT/fake-ps"
cat > "$FAKE_PS" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n67 1\n' ;;
  "-p 67 -o stat=") printf 'Ss\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_PS"
LINUX_PROCESS_INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":["/bin/sh"],"name":"sh","pid":67}]}}}'
argv_pid=$(
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' "$LINUX_PROCESS_INFO"; }
  FM_HERDR_PS_BIN="$FAKE_PS" fm_backend_herdr_pane_idle_shell_pid test w2:p1
) || fail "Linux Herdr process argv array was not accepted"
[ "$argv_pid" = 67 ] || fail "idle-shell proof printed the wrong shell pid: $argv_pid"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":[67],"name":"sh","pid":67}]}}}'; }
  FM_HERDR_PS_BIN="$FAKE_PS" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_idle_shell_pid test w2:p1
) >/dev/null 2>&1; then
  fail "non-string Herdr process argv was accepted"
fi
pass "process proof reads Linux Herdr argv arrays and rejects malformed executable identities"

TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=task
WS=w2
TAB=w2:t1
PANE=w2:p1
TITLE="└ task · p:$TOKEN"
FIXTURE_DIR="$TMP_ROOT/fixture"
LOCK_LOG="$TMP_ROOT/locks.log"
CLOSE_LOG="$TMP_ROOT/closes.log"
mkdir -p "$FIXTURE_DIR"

fm_backend_name() { printf herdr; }
fm_backend_herdr_session() { printf test; }
fm_backend_herdr_presentation_session_lock_path() { printf '%s/presentation.lock' "$TMP_ROOT"; }
# shellcheck disable=SC2329 # invoked indirectly by the cleanup under test.
fm_lock_try_acquire() {
  printf '%s\n' "$1" >> "$LOCK_LOG"
  mkdir "$1" 2>/dev/null
}
# shellcheck disable=SC2329 # invoked indirectly by the cleanup under test.
fm_lock_release() { rm -rf -- "$1"; }
fm_backend_herdr_pane_idle_shell_pid() {
  if [ -n "${MASS_FIXTURE_DIR:-}" ]; then
    MASS_CURRENT_PANE=$2
    [ "$2" != wlate-meta:p1 ] || : > "$FM_STATE_OVERRIDE/late-meta.meta"
    printf '67\n'
    return
  fi
  [ ! -e "$FIXTURE_DIR/process-unsafe" ] && printf '67\n'
}
fm_backend_herdr_projection_focus_snapshot() {
  if [ -n "${MASS_FIXTURE_DIR:-}" ]; then
    case "$MASS_CURRENT_PANE" in wfocus:p1) printf 'w0\twfocus:t1' ;; *) printf 'w0\tw0:t1' ;; esac
    return
  fi
  [ ! -e "$FIXTURE_DIR/focus-unreadable" ] || return 1
  printf 'w1\t%s' "$(cat "$FIXTURE_DIR/active-tab")"
}

fixture_workspace_json() {
  local title=$1 tabs=$2 panes=$3 focused=false active=$TAB
  [ "$(cat "$FIXTURE_DIR/active-tab")" = "$TAB" ] && focused=true
  printf '{"workspace_id":"%s","label":"%s","focused":%s,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}' \
    "$WS" "$title" "$focused" "$active" "$tabs" "$panes"
}

fixture_workspaces() {
  local title tabs panes
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  printf '[{"workspace_id":"w1","label":"firstmate","focused":%s,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},' \
    "$( [ "$(cat "$FIXTURE_DIR/active-tab")" = w1:t1 ] && printf true || printf false )"
  fixture_workspace_json "$title" "$tabs" "$panes"
  if [ -e "$FIXTURE_DIR/duplicate-token" ]; then
    printf ',{"workspace_id":"w3","label":"└ copy · p:%s","focused":false,"active_tab_id":"w3:t1","tab_count":1,"pane_count":1}' "$TOKEN"
  fi
  printf ']'
}

fixture_tabs() {
  local count i
  count=$(cat "$FIXTURE_DIR/tabs")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"tab_id":"%s:t%s","workspace_id":"%s","focused":false,"label":"fm-task"}' "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fixture_panes() {
  local count i
  count=$(cat "$FIXTURE_DIR/panes")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"pane_id":"%s:p%s","tab_id":"%s:t%s","workspace_id":"%s","agent_status":"unknown"}' \
      "$WS" "$i" "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-} title tabs panes
  if [ -n "${MASS_FIXTURE_DIR:-}" ]; then
    fm_mass_cli "$@"
    return
  fi
  shift
  [ ! -e "$FIXTURE_DIR/error-${first}-${second}" ] || return 1
  if [ -e "$FIXTURE_DIR/closed" ]; then
    case "$first $second" in
      "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; return 1 ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1}]}}'; return 0 ;;
    esac
  fi
  if [ -e "$FIXTURE_DIR/race" ] && [ -e "$FIXTURE_DIR/snapshotted" ] && [ "$first $second" = "workspace list" ]; then
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},{"workspace_id":"w2","label":"renamed","focused":false,"active_tab_id":"w2:t1","tab_count":1,"pane_count":1}]}}'
    return 0
  fi
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  case "$first $second" in
    "workspace list")
      printf '{"result":{"workspaces":'; fixture_workspaces; printf '}}\n'
      ;;
    "workspace get")
      printf '{"result":{"workspace":'; fixture_workspace_json "$title" "$tabs" "$panes"; printf '}}\n'
      ;;
    "tab list")
      printf '{"result":{"tabs":'; fixture_tabs; printf '}}\n'
      ;;
    "pane list")
      printf '{"result":{"panes":'; fixture_panes; printf '}}\n'
      ;;
    "pane get")
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' "$PANE" "$TAB" "$WS"
      ;;
    "agent get")
      case "$(cat "$FIXTURE_DIR/agent")" in
        absent) printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2; return 1 ;;
        live) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
        unknown) printf '%s\n' '{"error":{"code":"internal_error"}}' >&2; return 1 ;;
      esac
      ;;
    "api snapshot")
      : > "$FIXTURE_DIR/snapshotted"
      printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"w1:p1","workspaces":' "$(cat "$FIXTURE_DIR/active-tab")"
      fixture_workspaces
      printf ',"tabs":'; fixture_tabs
      printf ',"panes":'; fixture_panes
      printf '}}}\n'
      ;;
    "session list")
      printf '%s\n' '{"sessions":[{"name":"test","running":true,"socket_path":"/tmp/fake.sock"}]}'
      ;;
    "pane close")
      : > "$FIXTURE_DIR/closed"
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_projection_close_pane_focus_preserving() {
  if [ -n "${MASS_FIXTURE_DIR:-}" ]; then
    MASS_CURRENT_PANE=$2
    : > "$MASS_FIXTURE_DIR/closed-${2//:/-}"
    return 0
  fi
  [ ! -e "$FIXTURE_DIR/focus-refuse" ] || return 1
  [ "${3:-}" = no-agent ] || return 1
  printf '%s\n' "$*" >> "$CLOSE_LOG"
  : > "$FIXTURE_DIR/closed"
}

fm_mass_token() { printf '%022d' "$1"; }

fm_mass_workspace_list_build() {
  local i token
  printf '[{"workspace_id":"w0","label":"firstmate","focused":true,"active_tab_id":"w0:t1","tab_count":1,"pane_count":1}'
  i=1
  while [ "$i" -le 200 ]; do
    token=$(fm_mass_token "$i")
    printf ',{"workspace_id":"w%s","label":"└ task%s · p:%s","focused":false,"active_tab_id":"w%s:t1","tab_count":1,"pane_count":1}' "$i" "$i" "$token" "$i"
    i=$((i + 1))
  done
  printf ',{"workspace_id":"wduplicate","label":"└ duplicate · p:9999999999999999999999","focused":false,"active_tab_id":"wduplicate:t1","tab_count":1,"pane_count":1}'
  printf ',{"workspace_id":"wcopy","label":"└ duplicate-copy · p:9999999999999999999999","focused":false,"active_tab_id":"wcopy:t1","tab_count":1,"pane_count":1}'
  printf ',{"workspace_id":"wsymlink","label":"└ symlink · p:3000000000000000000006","focused":false,"active_tab_id":"wsymlink:t1","tab_count":1,"pane_count":1}'
  for i in change late-meta late-agent focus uncertain foreign; do
    case "$i" in
      change) token=3000000000000000000000 ;;
      late-meta) token=3000000000000000000001 ;;
      late-agent) token=3000000000000000000002 ;;
      focus) token=3000000000000000000003 ;;
      uncertain) token=3000000000000000000004 ;;
      foreign) token=3000000000000000000005 ;;
    esac
    printf ',{"workspace_id":"w%s","label":"└ %s · p:%s","focused":false,"active_tab_id":"w%s:t1","tab_count":1,"pane_count":1}' "$i" "$i" "$token" "$i"
  done
  printf ']'
}

fm_mass_workspace_list() {
  if [ -n "${MASS_WORKSPACES_JSON:-}" ]; then
    cat "$MASS_WORKSPACES_JSON"
  else
    fm_mass_workspace_list_build
  fi
}

fm_mass_id_for_workspace() { printf '%s' "${1#w}"; }

fm_mass_workspace_json() { # <workspace>
  local workspace=$1 id token label
  case "$workspace" in
    w0) printf '%s' '{"workspace_id":"w0","label":"firstmate","tab_count":1,"pane_count":1}'; return ;;
    w[0-9]*) id=${workspace#w}; token=$(fm_mass_token "$id"); label="└ task$id · p:$token" ;;
    wduplicate) id=duplicate; token=9999999999999999999999; label="└ duplicate · p:$token" ;;
    wcopy) id=copy; token=9999999999999999999999; label="└ duplicate-copy · p:$token" ;;
    wsymlink) id=symlink; token=3000000000000000000006; label="└ symlink · p:$token" ;;
    wchange) id=change; token=3000000000000000000000; label="└ change · p:$token" ;;
    wlate-meta) id=late-meta; token=3000000000000000000001; label="└ late-meta · p:$token" ;;
    wlate-agent) id=late-agent; token=3000000000000000000002; label="└ late-agent · p:$token" ;;
    wfocus) id=focus; token=3000000000000000000003; label="└ focus · p:$token" ;;
    wuncertain) id=uncertain; token=3000000000000000000004; label="└ uncertain · p:$token" ;;
    wforeign) id=foreign; token=3000000000000000000005; label="└ foreign · p:$token" ;;
    *) return 1 ;;
  esac
  printf '{"workspace_id":"%s","label":"%s","tab_count":1,"pane_count":1}' "$workspace" "$label"
}

fm_mass_snapshot_build() { # <workspace>
  local workspace=$1
  printf '{"result":{"snapshot":{"focused_workspace_id":"w0","focused_tab_id":"w0:t1","focused_pane_id":"w0:p1","workspaces":'
  printf '['; fm_mass_workspace_json w0; printf ','; fm_mass_workspace_json "$workspace"; printf ']'
  printf ',"tabs":[{"tab_id":"w0:t1","workspace_id":"w0","focused":true},{"tab_id":"%s:t1","workspace_id":"%s","focused":false}]' "$workspace" "$workspace"
  printf ',"panes":[{"pane_id":"w0:p1","tab_id":"w0:t1","workspace_id":"w0","agent_status":"unknown"},{"pane_id":"%s:p1","tab_id":"%s:t1","workspace_id":"%s","agent_status":"unknown"}]' "$workspace" "$workspace" "$workspace"
  printf '}}}\n'
}

fm_mass_cli() {
  local _session=$1 first=${2:-} second=${3:-} workspace=${4:-} pane=${4:-} id
  printf '%s %s\n' "$first" "$second" >> "$MASS_CLI_LOG"
  case "$first $second" in
    "workspace list")
      if [ ! -e "$MASS_FIXTURE_DIR/revalidated" ]; then
        : > "$MASS_FIXTURE_DIR/revalidated"
      else
        printf 'version=1\ntask_id=change\nprojection_id=8888888888888888888888\n' > "$FM_STATE_OVERRIDE/change.herdr-presentation"
      fi
      printf '{"result":{"workspaces":'; fm_mass_workspace_list; printf '}}\n'
      ;;
    "workspace get")
      workspace=${4:-}
      [ "$workspace" != wuncertain ] || return 1
      printf '{"result":{"workspace":'
      fm_mass_workspace_json "$workspace"
      printf '}}\n'
      ;;
    "tab list")
      workspace=${5:-}
      printf '{"result":{"tabs":[{"tab_id":"%s:t1","workspace_id":"%s","label":"fm-%s"}]}}\n' "$workspace" "$workspace" "${workspace#w}"
      ;;
    "pane list")
      workspace=${5:-}
      printf '{"result":{"panes":[{"pane_id":"%s:p1","tab_id":"%s:t1","workspace_id":"%s","agent_status":"unknown"}]}}\n' "$workspace" "$workspace" "$workspace"
      ;;
    "api snapshot")
      printf 'snapshot\n' >> "$MASS_SNAPSHOT_CALL_LOG"
      id=$(wc -l < "$MASS_SNAPSHOT_CALL_LOG" | tr -d ' ')
      if [ "$id" -le 200 ]; then
        fm_mass_snapshot_build "w$id"
      else
        case "$id" in
          201) fm_mass_snapshot_build wduplicate ;;
          202) fm_mass_snapshot_build wlate-meta ;;
          203) fm_mass_snapshot_build wlate-agent ;;
          204) fm_mass_snapshot_build wfocus ;;
          205) fm_mass_snapshot_build wuncertain ;;
          *) return 1 ;;
        esac
      fi
      ;;
    "agent get")
      pane=${4:-}
      if [ "$pane" = wlate-agent:p1 ]; then
        printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}'
      elif [ -e "$MASS_FIXTURE_DIR/closed-${pane//:/-}" ]; then
        printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
        return 1
      else
        printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
        return 1
      fi
      ;;
    "pane get")
      pane=${4:-}
      if [ -e "$MASS_FIXTURE_DIR/closed-${pane//:/-}" ]; then
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        return 1
      fi
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s:t1","workspace_id":"%s"}}}\n' "$pane" "${pane%%:*}" "${pane%%:*}"
      ;;
    "pane close")
      pane=${4:-}
      : > "$MASS_FIXTURE_DIR/closed-${pane//:/-}"
      ;;
    *) return 1 ;;
  esac
}

write_v1() { # <id> [token]
  local id=$1 token=${2:-$TOKEN}
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$FM_STATE_OVERRIDE/$id.herdr-presentation"
}

write_v2() { # <home> <workspace> <tab> <pane>
  local home=$1 workspace=$2 tab=$3 pane=$4
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$ID"
    printf 'projection_id=%s\n' "$TOKEN"
    printf 'home=%s\n' "$home"
    printf 'session=test\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$workspace" "$tab" "$pane"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$TITLE" "$ID"
  } > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"
}

write_cross_home_v2() {
  mkdir -p "$TMP_ROOT/other-home"
  write_v2 "$TMP_ROOT/other-home" "$WS" "$TAB" "$PANE"
}

reset_fixture() {
  rm -rf "$FIXTURE_DIR" "$TMP_ROOT"/*.lock "${FM_STATE_OVERRIDE:?}/"*
  mkdir -p "$FIXTURE_DIR"
  : > "$LOCK_LOG"; : > "$CLOSE_LOG"
  printf '%s\n' "$TITLE" > "$FIXTURE_DIR/title"
  printf '1\n' > "$FIXTURE_DIR/tabs"
  printf '1\n' > "$FIXTURE_DIR/panes"
  printf 'w1:t1\n' > "$FIXTURE_DIR/active-tab"
  printf 'absent\n' > "$FIXTURE_DIR/agent"
  write_v1 "$ID"
}

assert_preserved() { # <case>
  local name=$1 had_journal=0
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] && had_journal=1
  fm_herdr_session_cleanup >/dev/null 2>&1
  if [ "$had_journal" -eq 1 ]; then
    [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$name retired the journal"
  fi
  [ ! -s "$CLOSE_LOG" ] || fail "$name closed the pane"
  pass "$name preserves the candidate"
}

reset_fixture
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "positive cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "positive cleanup did not close exactly once"
[ "$(sed -n '1p' "$LOCK_LOG")" = "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "task lock was not acquired first"
[ "$(sed -n '2p' "$LOCK_LOG")" = "$TMP_ROOT/presentation.lock" ] || fail "presentation lock was not acquired second"
pass "exact stale projection closes one exact pane under task then presentation locks"
fm_herdr_session_cleanup >/dev/null 2>&1
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "repeat cleanup closed again"
pass "successful cleanup is idempotent on repeat"

reset_fixture; printf '%s\n' '└ malformed p:AbCdEfGhIjKlMnOpQrStUv' > "$FIXTURE_DIR/title"; assert_preserved "malformed title"
reset_fixture; printf '%s\n' '└ missing-token' > "$FIXTURE_DIR/title"; assert_preserved "missing token"
reset_fixture; printf 'version=1\ntask_id=%s\nprojection_id=short\n' "$ID" > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "malformed journal"
reset_fixture; : > "$FIXTURE_DIR/duplicate-token"; assert_preserved "duplicate token"
reset_fixture; printf '%s\n' "└ task · p:$TOKEN p:$TOKEN" > "$FIXTURE_DIR/title"; assert_preserved "duplicate title token"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "zero journal match"
reset_fixture; write_v1 fm-task; assert_preserved "multiple journal matches"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; write_cross_home_v2; assert_preserved "cross-home journal"
reset_fixture; write_v2 "$FM_HOME" w9 "$TAB" "$PANE"; assert_preserved "v2 workspace binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" w9:t1 "$PANE"; assert_preserved "v2 tab binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" w9:p1; assert_preserved "v2 pane binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" "$PANE"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "matching v2 cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "matching v2 cleanup did not close exactly once"
pass "v2 cleanup requires and accepts the exact journal endpoint binding"
reset_fixture; : > "$FM_STATE_OVERRIDE/$ID.meta"; assert_preserved "current task metadata"
reset_fixture; printf 'live\n' > "$FIXTURE_DIR/agent"; assert_preserved "registered agent"
reset_fixture; printf 'unknown\n' > "$FIXTURE_DIR/agent"; assert_preserved "unknown agent"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/tabs"; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple tabs"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple panes"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "non-idle shell"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "child process or shell job"
reset_fixture; : > "$FIXTURE_DIR/error-api-snapshot"; assert_preserved "unreadable snapshot"
reset_fixture; : > "$FIXTURE_DIR/error-workspace-get"; assert_preserved "unreadable topology check"
reset_fixture; : > "$FIXTURE_DIR/race"; assert_preserved "revalidation race"
reset_fixture; printf '%s\n' "$TAB" > "$FIXTURE_DIR/active-tab"; assert_preserved "active target"
reset_fixture; : > "$FIXTURE_DIR/focus-refuse"; assert_preserved "focus refusal"

# A recorded protocol fixture, not a missing-Herdr early exit: it exercises
# the public cleanup composition with 200 eligible stale presentations and
# destructive-path negatives while recording the indexed discovery work.
MASS_FIXTURE_DIR="$TMP_ROOT/mass"
MASS_CLI_LOG="$TMP_ROOT/mass-cli.log"
MASS_SNAPSHOT_LOG="$TMP_ROOT/mass-snapshots.log"
MASS_WORKSPACES_JSON="$TMP_ROOT/mass-workspaces.json"
MASS_SNAPSHOT_CALL_LOG="$TMP_ROOT/mass-snapshot-calls.log"
mkdir -p "$MASS_FIXTURE_DIR"
fm_lock_try_acquire() { return 0; }
fm_lock_release() { return 0; }
fm_backend_herdr_pane_agent_state() {
  case "$2" in
    wlate-agent:p1) printf live ;;
    *)
      if [ -e "$MASS_FIXTURE_DIR/closed-${2//:/-}" ]; then printf dead; else printf no-agent; fi
      ;;
  esac
}
fm_backend_herdr_projection_journal_snapshot() {
  local journal=$1 expected_id=$2 key value
  FM_BACKEND_HERDR_JOURNAL_VERSION=
  FM_BACKEND_HERDR_JOURNAL_TASK_ID=
  FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=
  FM_BACKEND_HERDR_JOURNAL_HOME=
  FM_BACKEND_HERDR_JOURNAL_SESSION=
  FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=
  FM_BACKEND_HERDR_JOURNAL_TAB_ID=
  FM_BACKEND_HERDR_JOURNAL_PANE_ID=
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  printf 'snapshot\n' >> "$MASS_SNAPSHOT_LOG"
  while IFS='=' read -r key value; do
    case "$key" in
      version) FM_BACKEND_HERDR_JOURNAL_VERSION=$value ;;
      task_id) FM_BACKEND_HERDR_JOURNAL_TASK_ID=$value ;;
      projection_id) FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID=$value ;;
      home) # shellcheck disable=SC2034 # read by the sourced cleanup script.
        FM_BACKEND_HERDR_JOURNAL_HOME=$value ;;
      session) # shellcheck disable=SC2034 # read by the sourced cleanup script.
        FM_BACKEND_HERDR_JOURNAL_SESSION=$value ;;
      workspace_id) # shellcheck disable=SC2034 # read by the sourced cleanup script.
        FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID=$value ;;
      tab_id) # shellcheck disable=SC2034 # read by the sourced cleanup script.
        FM_BACKEND_HERDR_JOURNAL_TAB_ID=$value ;;
      pane_id) # shellcheck disable=SC2034 # read by the sourced cleanup script.
        FM_BACKEND_HERDR_JOURNAL_PANE_ID=$value ;;
    esac
  done < "$journal"
  [ "$FM_BACKEND_HERDR_JOURNAL_TASK_ID" = "$expected_id" ] \
    && [ "${#FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID}" -eq 22 ] \
    && { [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 1 ] || [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ]; }
}
write_mass_v1() { # <id> <token>
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$1" "$2" > "$FM_STATE_OVERRIDE/$1.herdr-presentation"
}
rm -rf "${FM_STATE_OVERRIDE:?}/"* "${MASS_FIXTURE_DIR:?}/"*
: > "$MASS_CLI_LOG"; : > "$MASS_SNAPSHOT_LOG"
: > "$MASS_SNAPSHOT_CALL_LOG"
fm_mass_workspace_list_build > "$MASS_WORKSPACES_JSON"
fm_mass_snapshot_build w1 | jq -e . >/dev/null || fail "mass snapshot fixture is invalid JSON"
for mass_i in $(seq 1 200); do
  write_mass_v1 "task$mass_i" "$(fm_mass_token "$mass_i")"
done
write_mass_v1 duplicate 9999999999999999999999
write_mass_v1 change 3000000000000000000000
write_mass_v1 late-meta 3000000000000000000001
write_mass_v1 late-agent 3000000000000000000002
write_mass_v1 focus 3000000000000000000003
write_mass_v1 uncertain 3000000000000000000004
mkdir -p "$TMP_ROOT/foreign-home"
{
  printf 'version=2\ntask_id=foreign\nprojection_id=3000000000000000000005\n'
  printf 'home=%s\nsession=test\nworkspace_id=wforeign\ntab_id=wforeign:t1\npane_id=wforeign:p1\n' "$TMP_ROOT/foreign-home"
  printf 'parent_workspace_id=w0\nparent_label=firstmate\nworkspace_label=└ foreign · p:3000000000000000000005\ntask_label=fm-foreign\n'
} > "$FM_STATE_OVERRIDE/foreign.herdr-presentation"
ln -s /missing "$FM_STATE_OVERRIDE/symlink.herdr-presentation"
MASS_CURRENT_PANE=
mass_started=$(date +%s)
fm_herdr_session_cleanup >/dev/null 2>&1
mass_elapsed=$(( $(date +%s) - mass_started ))
for mass_i in $(seq 1 200); do
  [ ! -e "$FM_STATE_OVERRIDE/task$mass_i.herdr-presentation" ] || fail "mass eligible task$mass_i was not retired"
done
for mass_id in duplicate change late-meta late-agent focus uncertain foreign symlink; do
  [ -e "$FM_STATE_OVERRIDE/$mass_id.herdr-presentation" ] || [ -L "$FM_STATE_OVERRIDE/$mass_id.herdr-presentation" ] \
    || fail "mass negative $mass_id was not preserved"
done
mass_snapshots=$(wc -l < "$MASS_SNAPSHOT_LOG" | tr -d ' ')
mass_cli=$(wc -l < "$MASS_CLI_LOG" | tr -d ' ')
[ "$mass_snapshots" -le 1100 ] || fail "mass cleanup re-read $mass_snapshots journals; expected at most 1100"
[ "$mass_cli" -le 2200 ] || fail "mass cleanup made $mass_cli CLI calls; expected at most 2200"
[ "$mass_elapsed" -lt 30 ] || fail "mass cleanup took ${mass_elapsed}s; expected under 30s"
pass "recorded 200-presentation cleanup retires only eligible journals with bounded discovery"
MASS_CURRENT_PANE=

NO_CANDIDATE_WORKSPACES="$TMP_ROOT/no-candidate-workspaces.json"
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w0","label":"firstmate","focused":true,"active_tab_id":"w0:t1","tab_count":1,"pane_count":1}]}}' > "$NO_CANDIDATE_WORKSPACES"
write_mass_v1 no-candidate 4000000000000000000000
rm -rf "$FM_STATE_OVERRIDE"/.herdr-cleanup-index.*
MASS_WORKSPACES_JSON="$NO_CANDIDATE_WORKSPACES" fm_herdr_session_cleanup >/dev/null 2>&1
[ -f "$FM_STATE_OVERRIDE/no-candidate.herdr-presentation" ] \
  || fail "cleanup removed a journal without a candidate workspace title"
[ -z "$(find "$FM_STATE_OVERRIDE" -maxdepth 1 -name '.herdr-cleanup-index.*' -print -quit)" ] \
  || fail "cleanup built an index when no workspace title could match"
unset MASS_WORKSPACES_JSON
pass "cleanup skips journal indexing when the session has no candidate title"

SIGNAL_INDEX="$TMP_ROOT/signal-index"
signal_status=0
FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1 bash -c '
  . "$0/bin/fm-herdr-session-cleanup.sh"
  FM_HERDR_CLEANUP_INDEX_DIR=$1
  mkdir -p "$FM_HERDR_CLEANUP_INDEX_DIR"
  kill -TERM "$$"
' "$ROOT" "$SIGNAL_INDEX" >/dev/null 2>&1 || signal_status=$?
[ "$signal_status" -eq 143 ] || fail "SIGTERM cleanup returned $signal_status instead of 143"
[ ! -e "$SIGNAL_INDEX" ] || fail "SIGTERM left the cleanup index behind"
pass "cleanup removes its journal index on interruption"
unset MASS_FIXTURE_DIR MASS_CURRENT_PANE MASS_WORKSPACES_JSON

INTEGRATION_ROOT="$TMP_ROOT/bootstrap-integration"
mkdir -p "$INTEGRATION_ROOT/home/state" "$INTEGRATION_ROOT/home/data" "$INTEGRATION_ROOT/home/config"
cp -R "$ROOT/bin" "$INTEGRATION_ROOT/bin"
TRACE="$INTEGRATION_ROOT/cleanup.trace"
cat > "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:?}" >> "${FM_HERDR_CLEANUP_TRACE:?}"
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh"
printf '%s\n' manual > "$INTEGRATION_ROOT/home/config/backlog-backend"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "detect-only bootstrap ran stale projection cleanup"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "standalone bootstrap ran lock-owned stale projection cleanup"
pass "standalone bootstrap cannot run lock-owned stale projection cleanup"

cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'lock acquired'
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "lock-owning session start failed"
[ "$(cat "$TRACE")" = "$INTEGRATION_ROOT/home" ] \
  || fail "lock-owning session start did not run cleanup for its exact home"

: > "$TRACE"
cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'error: another live firstmate session holds the lock' >&2
exit 1
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "read-only session start failed"
[ ! -s "$TRACE" ] || fail "read-only session start ran stale projection cleanup"
pass "session start runs cleanup only after acquiring its home lock"

printf 'all fm-herdr-session-cleanup tests passed\n'
