#!/usr/bin/env bash
# A missing window on the parent's server is not proof a child stopped.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/tests/git-config-helpers.sh"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "$ROOT/.tmux-child.XXXXXX")
cleanup() {
  tmux -S "$LAB/p" kill-server 2>/dev/null || true
  tmux -S "$LAB/c" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
fail() { echo "not ok - $*" >&2; exit 1; }
HOME_PARENT="$LAB/parent"
HOME_CHILD="$LAB/mate"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_PARENT" >/dev/null
"$ROOT/bin/fm-lab-home.sh" create "$HOME_CHILD" >/dev/null
# The test-only code-root override keeps disposable homes outside the protected
# code root while all fixtures remain inside this checkout.
ln -s "$ROOT/bin" "$HOME_PARENT/bin"
export FM_ROOT_OVERRIDE="$HOME_PARENT" FM_GATE_REFUSE_BYPASS=1
git -c init.defaultBranch=main init -q "$LAB/project"
git -C "$LAB/project" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m fixture
git -C "$LAB/project" worktree add -q -b fm/child "$LAB/wt"
export FM_HOME="$HOME_PARENT"
tmux -f /dev/null -S "$LAB/p" new-session -d -s primary -n fm-parent -c "$ROOT" 'sleep 300'
export TMUX="$LAB/p,1,0"
printf 'parent\n' > "$HOME_CHILD/.fm-secondmate-home"
printf '{"pools":[{"name":"shared","capacity":2,"models":["pool-model-a"]}]}\n' > "$HOME_PARENT/config/fleet-seats"
"$ROOT/bin/fm-fleet-seats.sh" reserve parent --generation g-parent --harness claude --model pool-model-a --kind secondmate --holder-pid "$$" >/dev/null
printf 'kind=secondmate\nmode=local-only\nbackend=tmux\nwindow=primary:fm-parent\nendpoint_task_id=parent\nworktree=%s\nproject=%s\nhome=%s\nspawn_gen=g-parent\nmodel=pool-model-a\n' "$HOME_CHILD" "$HOME_CHILD" "$HOME_CHILD" > "$HOME_PARENT/state/parent.meta"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_PARENT" > "$HOME_CHILD/.fm-secondmate-parent"
printf -- '- parent - Lab mate. (home: %s; scope: tests; projects: ; added 2026-10-07)\n' "$HOME_CHILD" > "$HOME_PARENT/data/secondmates.md"
FM_HOME="$HOME_CHILD" "$ROOT/bin/fm-fleet-seats.sh" reserve child --generation g-child --harness claude --model pool-model-a --kind ship --holder-pid "$$" >/dev/null
printf 'kind=ship\nmode=local-only\nbackend=tmux\nwindow=unavailable:fm-child\nendpoint_task_id=child\nspawn_gen=g-child\nmodel=pool-model-a\nworktree=%s\nproject=%s\n' "$LAB/wt" "$LAB/project" > "$HOME_CHILD/state/child.meta"
tmux -f /dev/null -S "$LAB/c" new-session -d -s unavailable -n fm-child -c "$LAB/wt" 'sleep 300'
[ "$(tmux -S "$LAB/c" display-message -p -t '=unavailable:=fm-child' '#{pane_dead}')" = 0 ] || fail 'child fixture is not live'
rc=0
"$ROOT/bin/fm-teardown.sh" parent --force > "$LAB/stdout" 2> "$LAB/stderr" || rc=$?
[ "$rc" -ne 0 ] || fail 'forced teardown succeeded while the child lived on another socket'
[ "$(tmux -S "$LAB/c" display-message -p -t '=unavailable:=fm-child' '#{pane_dead}')" = 0 ] || fail 'unaddressed child was stopped'
[ -f "$HOME_CHILD/state/child.meta" ] || fail 'child identity was deleted'
[ -d "$LAB/wt" ] || fail 'child worktree was removed'
[ -f "$HOME_PARENT/state/parent.meta" ] || fail 'parent identity was deleted'
for task in parent child; do
  seat_home=$HOME_PARENT
  [ "$task" != child ] || seat_home=$HOME_CHILD
  ledger=$(FM_HOME="$seat_home" "$ROOT/bin/fm-fleet-seats.sh" show "$task")
  [ "$(printf '%s' "$ledger" | jq -r '.incarnations[0].lifecycle')" = reserved ] || fail "$task seat was released"
done
# Once the recorded endpoint is reachable and can actually be closed, retry succeeds.
tmux -S "$LAB/c" kill-server
tmux -S "$LAB/p" new-session -d -s unavailable -n fm-child -c "$LAB/wt" 'sleep 300'
"$ROOT/bin/fm-teardown.sh" parent --force > "$LAB/retry.stdout" 2> "$LAB/retry.stderr" || { cat "$LAB/retry.stderr" >&2; fail 'reachable child teardown failed'; }
[ ! -e "$HOME_CHILD" ] || fail 'successful retry retained the child home'
[ ! -e "$HOME_PARENT/state/parent.meta" ] || fail 'successful retry retained the parent'
for holder in "$HOME_PARENT/state/fleet-seats/holders/"*.json; do
  jq -e 'all(.incarnations[]; .lifecycle == "released")' "$holder" >/dev/null || fail 'successful retry retained a counted seat'
done
if tmux -S "$LAB/p" has-session -t '=unavailable' 2>/dev/null; then
  fail 'successful retry left the child endpoint running'
fi
echo 'ok - forced teardown retains an unreachable tmux child and releases a closed child'
