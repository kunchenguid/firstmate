#!/usr/bin/env bash
# tests/fm-spawn-docker-transaction.test.sh - failure-path coverage for fresh
# Docker Sandbox acquisition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-docker-transaction)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -u
log_event() {
  printf 'tmux' >> "${FM_FAKE_EVENTS:?}"
  local arg
  for arg in "$@"; do
    printf '\t%s' "$arg" >> "$FM_FAKE_EVENTS"
  done
  printf '\n' >> "$FM_FAKE_EVENTS"
}
log_event "$@"
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    case "$*" in
      *window_id*) cat "${FM_FAKE_TMUX_STATE:?}" ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
  display-message) printf 'firstmate\n' ;;
  new-window)
    printf '@spawnwid\tfm-%s\n' "${FM_FAKE_TASK_ID:?}" >> "${FM_FAKE_TMUX_STATE:?}"
    printf '@spawnwid\n'
    ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" = 1 ] && exit 1
    tmp="${FM_FAKE_TMUX_STATE}.tmp.$$"
    : > "$tmp"
    while IFS=$'\t' read -r id label || [ -n "$id" ]; do
      case "$*" in *":$id") ;; *) printf '%s\t%s\n' "$id" "$label" >> "$tmp" ;; esac
    done < "$FM_FAKE_TMUX_STATE"
    mv -f -- "$tmp" "$FM_FAKE_TMUX_STATE"
    ;;
esac
exit 0
TMUX
  cat > "$fakebin/treehouse" <<'TREEHOUSE'
#!/usr/bin/env bash
set -u
printf 'treehouse' >> "${FM_FAKE_EVENTS:?}"
local_arg=''
for local_arg in "$@"; do
  printf '\t%s' "$local_arg" >> "$FM_FAKE_EVENTS"
done
printf '\n' >> "$FM_FAKE_EVENTS"
exit 0
TREEHOUSE
  cat > "$fakebin/mv" <<'MV'
#!/usr/bin/env bash
case "${FM_FAKE_ACQUISITION_WRITE_FAIL:-0}:$*" in
  1:*'.spawn-endpoint-'*) exit 1 ;;
esac
exec /bin/mv "$@"
MV
  cat > "$fakebin/sbx" <<'SBX'
#!/usr/bin/env bash
set -u

log_event() {
  printf 'sbx' >> "${FM_FAKE_EVENTS:?}"
  local arg
  for arg in "$@"; do
    printf '\t%s' "$arg" >> "$FM_FAKE_EVENTS"
  done
  printf '\n' >> "$FM_FAKE_EVENTS"
}

remove_selector() {
  local selector=$1 id name agent workspace tmp="${FM_FAKE_SBX_STATE}.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r id name agent workspace || [ -n "$id" ]; do
    [ "$id" = "$selector" ] || [ "$name" = "$selector" ] || \
      printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$agent" "$workspace" >> "$tmp"
  done < "$FM_FAKE_SBX_STATE"
  mv -f -- "$tmp" "$FM_FAKE_SBX_STATE"
}

json_state() {
  local id name agent workspace
  while IFS=$'\t' read -r id name agent workspace || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    jq -cn --arg id "$id" --arg name "$name" --arg agent "$agent" --arg workspace "$workspace" \
      '{id:$id,name:$name,agent:$agent,workspace:$workspace}'
  done < "$FM_FAKE_SBX_STATE" | jq -s .
}

log_event "$@"
[ "$#" -gt 0 ] || exit 2
case "$1" in
  ls)
    [ "${2:-}" = '--json' ] || exit 2
    json_state
    ;;
  create)
    shift
    [ "${1:-}" = '--name' ] || exit 2
    name=${2:-}
    shift 2
    while [ "${1:-}" = '--kit' ]; do
      [ "$#" -ge 2 ] || exit 2
      shift 2
    done
    [ "${1:-}" = 'codex' ] || exit 2
    workspace=${2:-}
    printf 'id-%s\t%s\tcodex\t%s\n' "$name" "$name" "$workspace" >> "$FM_FAKE_SBX_STATE"
    if [ "${FM_FAKE_SBX_CREATE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    ;;
  stop)
    ;;
  rm)
    if [ "${2:-}" = '--force' ]; then
      name=${3:-}
    else
      name=${2:-}
    fi
    [ -n "${name:-}" ] || exit 2
    remove_selector "$name"
    ;;
  *)
    exit 2
    ;;
esac
SBX
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/mv" "$fakebin/sbx"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir=$TMP_ROOT/$1 home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects"
  fm_git_worktree "$proj" "$wt" "fm-$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fakebin=$(make_fakebin "$case_dir/tools")
  : > "$case_dir/events.log"
  : > "$case_dir/sbx.state"
  : > "$case_dir/tmux.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 id=$2 home=$3 proj=$4 wt=$5 fakebin=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_FAKE_EVENTS="$case_dir/events.log" \
    FM_FAKE_SBX_STATE="$case_dir/sbx.state" FM_FAKE_TMUX_STATE="$case_dir/tmux.state" \
    FM_FAKE_TASK_ID="$id" TMUX='fake,1,0' \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex \
      --backend tmux --placement docker-sandbox --mode no-mistakes --yolo off
}

event_line() {
  local pattern=$1 file=$2
  grep -n -m 1 -F -- "$pattern" "$file" | cut -d: -f1
}

assert_events_in_order() {
  local first=$1 second=$2 file=$3 first_line second_line
  first_line=$(event_line "$first" "$file") || fail "missing event '$first'"
  second_line=$(event_line "$second" "$file") || fail "missing event '$second'"
  [ "$first_line" -lt "$second_line" ] || fail "event '$first' did not precede '$second'"
}

case_record=$(make_case bridge-failure bridge-fail-ab3)
IFS='|' read -r case_dir home proj wt fakebin <<EOF
$case_record
EOF
mkdir -p "$home/state/sandbox-bridge/bridge-fail-ab3"
run_spawn "$case_dir" bridge-fail-ab3 "$home" "$proj" "$wt" "$fakebin" > "$case_dir/output" 2>&1
status=$?
rm -rf -- "/tmp/fm-bridge-fail-ab3"
expect_code 1 "$status" 'bridge creation failure should abort fresh Docker spawn'
assert_absent "$home/state/bridge-fail-ab3.meta" 'bridge failure published task metadata'
assert_present "$home/state/sandbox-bridge/bridge-fail-ab3" 'pre-existing bridge collision was not preserved'
assert_absent "$home/state/.spawn-cleanup/bridge-fail-ab3.record" \
  'successful reverse cleanup left a durable retry record'
assert_grep $'treehouse\treturn\t--force\t'"$wt" "$case_dir/events.log" \
  'bridge failure did not return the acquired treehouse worktree'
assert_grep $'tmux\tkill-window\t-t\tfirstmate:@spawnwid' "$case_dir/events.log" \
  'bridge failure did not remove the exact tmux endpoint'
assert_events_in_order $'treehouse\treturn' $'tmux\tkill-window' "$case_dir/events.log"
assert_no_grep $'sbx\tcreate' "$case_dir/events.log" 'bridge failure attempted provider creation'
pass 'fresh Docker spawn unwinds endpoint and worktree when bridge creation fails'

case_record=$(make_case provider-failure provider-fail-cd4)
IFS='|' read -r case_dir home proj wt fakebin <<EOF
$case_record
EOF
export FM_FAKE_SBX_CREATE_FAIL=1
run_spawn "$case_dir" provider-fail-cd4 "$home" "$proj" "$wt" "$fakebin" > "$case_dir/output" 2>&1
status=$?
unset FM_FAKE_SBX_CREATE_FAIL
rm -rf -- "/tmp/fm-provider-fail-cd4"
expect_code 1 "$status" 'provider creation failure should abort fresh Docker spawn'
assert_absent "$home/state/provider-fail-cd4.meta" 'provider failure published task metadata'
assert_absent "$home/state/sandbox-bridge/provider-fail-cd4" 'provider failure left the bridge behind'
assert_grep $'id-fm-provider-fail-cd4\tfm-provider-fail-cd4' "$case_dir/sbx.state" \
  'provider failure discarded the unresolved partial sandbox'
assert_no_grep $'sbx\tstop' "$case_dir/events.log" \
  'provider failure attempted an unverified provider stop'
assert_no_grep $'sbx\trm' "$case_dir/events.log" \
  'provider failure attempted an unverified provider removal'
assert_present "$home/state/.spawn-cleanup/provider-fail-cd4.record" \
  'provider failure did not retain a durable cleanup record'
assert_grep 'placement_pending_name=fm-provider-fail-cd4' \
  "$home/state/.spawn-cleanup/provider-fail-cd4.record" \
  'durable cleanup record lost the unresolved provider name'
assert_grep $'treehouse\treturn\t--force\t'"$wt" "$case_dir/events.log" \
  'provider failure did not return the acquired treehouse worktree'
assert_grep $'tmux\tkill-window\t-t\tfirstmate:@spawnwid' "$case_dir/events.log" \
  'provider failure did not remove the exact tmux endpoint'
assert_events_in_order $'treehouse\treturn' $'tmux\tkill-window' "$case_dir/events.log"
pass 'fresh Docker spawn retains unresolved provider cleanup safely'

case_record=$(make_case endpoint-failure endpoint-fail-ef5)
IFS='|' read -r case_dir home proj wt fakebin <<EOF
$case_record
EOF
mkdir -p "$home/state/sandbox-bridge/endpoint-fail-ef5"
export FM_FAKE_TMUX_KILL_FAIL=1
run_spawn "$case_dir" endpoint-fail-ef5 "$home" "$proj" "$wt" "$fakebin" > "$case_dir/output" 2>&1
status=$?
unset FM_FAKE_TMUX_KILL_FAIL
rm -rf -- "/tmp/fm-endpoint-fail-ef5"
expect_code 1 "$status" 'endpoint cleanup failure should abort fresh Docker spawn'
assert_present "$home/state/.spawn-cleanup/endpoint-fail-ef5.record" \
  'endpoint cleanup failure did not retain a durable retry record'
assert_grep 'endpoint_target=firstmate' \
  "$home/state/.spawn-cleanup/endpoint-fail-ef5.record" \
  'endpoint cleanup record lost the exact acquired session'
assert_grep 'endpoint_aux=@spawnwid' \
  "$home/state/.spawn-cleanup/endpoint-fail-ef5.record" \
  'endpoint cleanup record lost the exact acquired window id'
assert_grep '@spawnwid' "$case_dir/tmux.state" \
  'endpoint cleanup failure unexpectedly removed the endpoint'
assert_grep $'treehouse\treturn\t--force\t'"$wt" "$case_dir/events.log" \
  'endpoint cleanup failure did not return the acquired worktree'
assert_events_in_order $'treehouse\treturn' $'tmux\tkill-window' "$case_dir/events.log"
pass 'failed endpoint cleanup remains durably recorded after reverse unwind'

case_record=$(make_case acquisition-write-failure acquisition-fail-gh6)
IFS='|' read -r case_dir home proj wt fakebin <<EOF
$case_record
EOF
export FM_FAKE_ACQUISITION_WRITE_FAIL=1 FM_FAKE_TMUX_KILL_FAIL=1
run_spawn "$case_dir" acquisition-fail-gh6 "$home" "$proj" "$wt" "$fakebin" > "$case_dir/output" 2>&1
status=$?
unset FM_FAKE_ACQUISITION_WRITE_FAIL FM_FAKE_TMUX_KILL_FAIL
rm -rf -- "/tmp/fm-acquisition-fail-gh6"
expect_code 1 "$status" 'endpoint acquisition-record failure should abort fresh Docker spawn'
assert_absent "$home/state/acquisition-fail-gh6.meta" 'acquisition-record failure published task metadata'
assert_present "$home/state/.spawn-cleanup/acquisition-fail-gh6.record" \
  'acquisition-record failure did not retain a durable retry record'
assert_grep 'endpoint_target=firstmate' \
  "$home/state/.spawn-cleanup/acquisition-fail-gh6.record" \
  'acquisition-record failure lost the exact endpoint session'
assert_grep 'endpoint_aux=@spawnwid' \
  "$home/state/.spawn-cleanup/acquisition-fail-gh6.record" \
  'acquisition-record failure lost the exact endpoint id'
assert_grep '@spawnwid' "$case_dir/tmux.state" \
  'acquisition-record failure unexpectedly removed the endpoint'
pass 'endpoint acquisition persistence failure refuses publication and records exact cleanup'

echo 'ALL TESTS PASSED'
