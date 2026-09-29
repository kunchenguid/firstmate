#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, Herdr, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Fixtures own their terminal identity; never inherit the invoking live pane.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Init/doctor stub: touch marker files; other verbs exit 2. Does not answer
# --version (the suites using it never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- fake Herdr -----------------------------------------------------------

fm_test_fake_herdr_spawn() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local fb=$1 dir; dir=$(dirname "$fb")
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:-$(dirname "$0")/herdr.log}"
STATE="${FM_FAKE_HERDR_STATE:-$(dirname "$(dirname "$0")")/state.json}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "session list")
    jq -n --arg socket "$(dirname "$0")/api.sock" --arg configured "${HERDR_SESSION:-fixture}" '{sessions:([$configured,"fixture","firstmate","default"]|unique|map({name:.,running:true,socket_path:$socket}))}'
    ;;
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "terminal title")
    printf '{"result":{"reason":"no_foreground_client"}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane get")
    jq_state --arg p "${3:-}" --arg cwd "${FM_FAKE_PANE_PATH:-}" '([.tabs[]|select(.pane_id==$p)|{pane_id:.pane_id,tab_id:.tab_id,workspace_id:.workspace_id,foreground_cwd:$cwd}] | first) as $pane | if $pane == null then {error:{code:"pane_not_found"}} else {result:{pane:$pane}} end'
    ;;
  "pane process-info")
    jq -n --arg cwd "${FM_FAKE_PANE_PATH:-}" '{result:{foreground_cwd:$cwd}}'
    ;;
  "pane read")
    if [ -n "${FM_FAKE_CAPTURE_FILE:-}" ]; then cat "$FM_FAKE_CAPTURE_FILE"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    ;;
  "pane send-text")
    [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
    ;;
  "pane send-keys"|"pane run") : ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select($w=="" or .workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent":"pi","pane_id":"%s","agent_status":"%s"}}}\n' "$3" "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
}

# --- fake Herdr / ssh / sleep -----------------------------------------------

# Herdr send fixture; captures actual typed bytes and preserves failure knobs.
fm_test_fake_herdr_send() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_HERDR_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$1 ${2:-}" in
  'status --json') echo '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  'pane get') jq -n --arg p "$3" '{result:{pane:{pane_id:$p}}}' ;;
  'pane process-info') jq -n --arg p "${4:-}" '{result:{type:"pane_process_info",process_info:{pane_id:$p,shell_pid:101,foreground_processes:[{pid:102,name:"codex",argv0:"codex"}]}}}';;
  'agent get') jq -n --arg pane "$3" '{result:{agent:{agent:"pi",pane_id:$pane,agent_status:"idle"}}}' ;;
  'pane read')
    if [ "${FM_FAKE_HERDR_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else printf '╭────╮\n│    │\n╰────╯\n'; fi ;;
  'pane send-text')
    [ "${FM_FAKE_HERDR_SEND_FAIL:-0}" != 1 ] || exit 1
    printf '%s' "${4:-}" >> "${FM_SEND_LOG:-/dev/null}" ;;
  'pane send-keys') [ "${FM_FAKE_HERDR_SEND_FAIL:-0}" != 1 ] || exit 1 ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn Herdr stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_herdr_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env. Extra caller variables such as FM_FAKE_LAUNCH_LOG are inherited.
# Does not add --mode/--yolo; ship tests pass their own delivery contract.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # Keep all test launches inside a throwaway user home.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" FM_BACKEND=herdr HERDR_ENV='' HERDR_PANE_ID='' HERDR_SESSION=fixture \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: Herdr send + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_herdr_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# Explicit normal-runtime metadata fixture. Callers requesting historical or
# malformed records keep using fm_write_meta and never opt into this helper.
fm_test_write_herdr_meta() {
  local file=$1 arg window='' backend='' binding='' id session pane key value found
  shift
  id=${file##*/}; id=${id%.meta}
  for arg in "$@"; do
    case "$arg" in window=*) window=${arg#window=} ;; backend=*) backend=1 ;; endpoint_task_id=*) binding=1 ;; esac
  done
  session=${window%%:*}; pane=${window#*:}
  local -a fields=()
  [ -n "$backend" ] || fields+=(backend=herdr)
  [ -n "$binding" ] || fields+=("endpoint_task_id=$id")
  for value in "herdr_session=$session" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" "herdr_pane_id=$pane"; do
    key=${value%%=*}; found=0
    for arg in "$@"; do case "$arg" in "$key="*) found=1 ;; esac; done
    [ "$found" = 1 ] || fields+=("$value")
  done
  fm_write_meta "$file" "${fields[@]}" "$@"
}

# Reachable private API with a structurally absent exact pane. Teardown can
# retire a record without silently treating unreadable transport as absence.
fm_test_fake_herdr_gone() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SHIM'
#!/usr/bin/env bash
set -u
[ -z "${FM_HERDR_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$1 ${2:-}" in
  'session list')
    jq -n --arg socket "$(dirname "$0")/api.sock" '{sessions:(["fixture","firstmate","session","default"]|map({name:.,running:true,socket_path:$socket}))}' ;;
  'status --json') echo '{"server":{"running":true}}' ;;
  'pane get') echo '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 1 ;;
esac
SHIM
  chmod +x "$fakebin/herdr"
}
