#!/usr/bin/env bash
# Credentialed agy guard: canonical relaunch, detection, composer and lifecycle.
# Run FM_AGY_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh.
# Every Herdr operation goes through the named-session lab helper.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_AGY_LIVE agy herdr jq
LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name agy-live)
ORIGINAL_PATH=$PATH
tmp=$(fm_test_tmproot fm-agy-live)
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"
mkdir -p "$tmp/fakebin"
# The backend's client-only status probe is also routed into the lab.
cat > "$tmp/fakebin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = '$SESSION' ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\$*" != 'status --json' ]; then
  echo 'lab refused unscoped Herdr call' >&2
  exit 98
fi
exec env PATH='$ORIGINAL_PATH' '$LAB_HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$tmp/fakebin/herdr"
export PATH="$tmp/fakebin:$PATH"
export FM_HOME="$tmp/home"
fm_test_spawn_home "$FM_HOME" agy
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
fm_git_worktree "$tmp/project" "$tmp/wt" agy-live
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
ws=$(lab workspace create --cwd "$tmp/wt" --label agy-live --no-focus)
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
workspace=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id')
tab=$(printf '%s' "$ws" | jq -er '.result.root_pane.tab_id')
mkdir -p "$FM_HOME/data/probe"
cat > "$FM_HOME/data/probe/brief.md" <<EOF
# Task
Run this command once with Bash: $ROOT/bin/fm-harness.sh > $FM_HOME/detected
Then reply AGY_LIVE_READY.
Create only that detection result file. Do not delegate or use any other tools.
EOF
cat > "$FM_HOME/state/probe.meta" <<EOF
kind=scout
harness=agy
model=default
effort=low
project=$tmp/project
worktree=$tmp/wt
window=$SESSION:$pane
backend=herdr
endpoint_task_id=probe
herdr_session=$SESSION
herdr_workspace_id=$workspace
herdr_tab_id=$tab
herdr_pane_id=$pane
EOF
"$ROOT/bin/fm-spawn.sh" probe --relaunch --harness agy --effort low
ready=0
trusted=0
version=
for ((i=0; i<120; i++)); do
  screen=$(lab pane read "$pane" --source recent --lines 60)
  case "$screen" in
    *'Antigravity CLI '*) version=$(printf '%s\n' "$screen" | grep -oE 'Antigravity CLI [0-9]+\.[0-9]+\.[0-9]+' | tail -n1 | awk '{print $3}') ;;
  esac
  if [[ "$screen" == *'Do you trust the contents of this project?'* ]] && [ "$trusted" = 0 ]; then
    lab pane send-keys "$pane" Enter
    trusted=1
  fi
  if [ -f "$FM_HOME/detected" ] && [[ "$screen" == *'? for shortcuts'* ]]; then
    ready=1
    break
  fi
  sleep 0.5
done
[ -n "$version" ] || fail 'agy guard requires observing an Antigravity CLI version banner'
[ "$ready" = 1 ] || fail "agy $version initial turn never settled"
[ "$(cat "$FM_HOME/detected")" = agy ] || fail "agy $version tool marker not detected"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
target="$SESSION:$pane"
# The rendered settle can precede herdr's own idle report; poll for the proven
# empty composer instead of racing one read against the working-state refusal.
empty=0
for ((i=0; i<60; i++)); do
  [ "$(fm_backend_herdr_composer_state "$target")" = empty ] && { empty=1; break; }
  sleep 0.5
done
[ "$empty" = 1 ] || fail "agy $version idle composer unreadable"
lab pane send-text "$pane" AGY_UNSUBMITTED
sleep 0.5
[ "$(fm_backend_herdr_composer_state "$target")" = pending ] || fail "agy $version unsubmitted input lost"
lab pane send-keys "$pane" Ctrl+u
"$ROOT/bin/fm-control.sh" probe interrupt
"$ROOT/bin/fm-control.sh" probe exit
"$ROOT/bin/fm-control.sh" probe relaunch --note 'Repeat the trivial readiness probe.'
sleep 2
"$ROOT/bin/fm-control.sh" probe exit
pass "agy $version canonical launch, composer, interrupt, exit and relaunch"
