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
  display-message) printf 'firstmate\n' ;;
  new-window) printf '@spawnwid\n' ;;
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

remove_name() {
  local name=$1 item tmp="${FM_FAKE_SBX_STATE}.tmp.$$"
  : > "$tmp"
  while IFS= read -r item || [ -n "$item" ]; do
    [ "$item" = "$name" ] || printf '%s\n' "$item" >> "$tmp"
  done < "$FM_FAKE_SBX_STATE"
  mv -f -- "$tmp" "$FM_FAKE_SBX_STATE"
}

log_event "$@"
[ "$#" -gt 0 ] || exit 2
case "$1" in
  ls)
    [ "${2:-}" = '--quiet' ] || exit 2
    cat "$FM_FAKE_SBX_STATE"
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
    printf '%s\n' "$name" >> "$FM_FAKE_SBX_STATE"
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
    remove_name "$name"
    ;;
  *)
    exit 2
    ;;
esac
SBX
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/sbx"
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
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 id=$2 home=$3 proj=$4 wt=$5 fakebin=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_FAKE_EVENTS="$case_dir/events.log" \
    FM_FAKE_SBX_STATE="$case_dir/sbx.state" TMUX='fake,1,0' \
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
assert_present "$home/state/sandbox-bridge/bridge-fail-ab3" 'bridge collision was removed during abort'
assert_grep $'treehouse\treturn\t--force\t'"$wt" "$case_dir/events.log" \
  'bridge failure did not return the acquired treehouse worktree'
assert_grep $'tmux\tkill-window\t-t\t=firstmate:=fm-bridge-fail-ab3' "$case_dir/events.log" \
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
assert_no_grep 'fm-provider-fail-cd4' "$case_dir/sbx.state" 'provider failure left a partial sandbox'
assert_grep $'sbx\tstop\tfm-provider-fail-cd4' "$case_dir/events.log" \
  'provider failure did not stop the exact partial sandbox'
assert_grep $'sbx\trm\t--force\tfm-provider-fail-cd4' "$case_dir/events.log" \
  'provider failure did not remove the exact partial sandbox'
assert_grep $'treehouse\treturn\t--force\t'"$wt" "$case_dir/events.log" \
  'provider failure did not return the acquired treehouse worktree'
assert_grep $'tmux\tkill-window\t-t\t=firstmate:=fm-provider-fail-cd4' "$case_dir/events.log" \
  'provider failure did not remove the exact tmux endpoint'
assert_events_in_order $'sbx\tstop' $'treehouse\treturn' "$case_dir/events.log"
assert_events_in_order $'treehouse\treturn' $'tmux\tkill-window' "$case_dir/events.log"
pass 'fresh Docker spawn unwinds provider, bridge, worktree, and endpoint resources'

echo 'ALL TESTS PASSED'
