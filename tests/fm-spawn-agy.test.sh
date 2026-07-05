#!/usr/bin/env bash
# agy spawn posts a Begin-now nudge after the launch Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agy)

make_spawn_fakebin() {
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
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        elif [ "$prev" = "-l" ] || [ "$a" = "Enter" ]; then
          :
        fi
        if [ "$a" = "Enter" ]; then
          printf 'Enter\n' >> "$FM_FAKE_LAUNCH_LOG"
        fi
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
  printf '%s\n' "$fakebin"
}

case_dir="$TMP_ROOT/agy-nudge"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
launchlog="$case_dir/launch.log"
fakebin=$(make_spawn_fakebin "$case_dir/fake")
id=agy-nudge-z1

mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
printf 'agy\n' > "$home/config/crew-harness"
fm_git_worktree "$proj" "$wt" "wt-agy"
mkdir -p "$home/data/$id"
printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
touch "$home/state/.last-watcher-beat"

: > "$launchlog"
FM_AGY_SPAWN_SETTLE=0 \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
  "$SPAWN" "$id" "$proj" agy >/dev/null 2>&1
status=$?
expect_code 0 "$status" "agy spawn should succeed"

launch=$(cat "$launchlog")
assert_contains "$launch" 'agy --dangerously-skip-permissions' "agy launch missing"
assert_contains "$launch" 'Begin now per brief' "agy spawn missing Begin-now nudge"
pass "agy spawn sends Begin-now nudge after launch"