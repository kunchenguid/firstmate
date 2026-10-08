#!/usr/bin/env bash
# A same-named window on the parent's server does not establish child ownership.
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
# This fixture uses a Git worktree rather than a treehouse-managed slot.
mkdir "$LAB/fakebin"
cat > "$LAB/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = return ] && [ "$2" = --force ] || exit 1
git worktree remove --force "$3"
SH
chmod +x "$LAB/fakebin/treehouse"
export PATH="$LAB/fakebin:$PATH"
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
tmux -S "$LAB/p" new-session -d -s unavailable -n fm-child -c "$ROOT" 'sleep 300'
rc=0
"$ROOT/bin/fm-teardown.sh" parent --force > "$LAB/stdout" 2> "$LAB/stderr" || rc=$?
[ "$rc" -ne 0 ] || fail 'forced teardown reported success while the child lived on another socket'
# --force authorizes the named close on this server, so the recorded endpoint
# is what must be reported honestly: a survivor is named, never assumed gone.
grep -F 'survives as a live or unaddressable endpoint' "$LAB/stderr" >/dev/null \
  || fail 'forced teardown did not name the surviving tmux endpoint'
[ "$(tmux -S "$LAB/c" display-message -p -t '=unavailable:=fm-child' '#{pane_dead}')" = 0 ] || fail 'the child on the other server was stopped'
[ -f "$HOME_CHILD/state/child.meta" ] || fail 'child identity was deleted'
[ -d "$LAB/wt" ] || fail 'child worktree was removed'
[ -f "$HOME_PARENT/state/parent.meta" ] || fail 'parent identity was deleted'
for task in parent child; do
  seat_home=$HOME_PARENT
  [ "$task" != child ] || seat_home=$HOME_CHILD
  ledger=$(FM_HOME="$seat_home" "$ROOT/bin/fm-fleet-seats.sh" show "$task")
  [ "$(printf '%s' "$ledger" | jq -r '.incarnations[0].lifecycle')" = reserved ] || fail "$task seat was released"
done
# Cleanup from the child's own home and server, then retry the parent.
FM_HOME="$HOME_CHILD" TMUX="$LAB/c,1,0" "$ROOT/bin/fm-teardown.sh" child --force > "$LAB/child.stdout" 2> "$LAB/child.stderr" || { cat "$LAB/child.stderr" >&2; fail 'owning-home child teardown failed'; }
if tmux -S "$LAB/c" has-session -t '=unavailable' 2>/dev/null; then
  fail 'owning-home cleanup left the child endpoint running'
fi
"$ROOT/bin/fm-teardown.sh" parent --force > "$LAB/retry.stdout" 2> "$LAB/retry.stderr" || { cat "$LAB/retry.stderr" >&2; fail 'reachable child teardown failed'; }
[ ! -e "$HOME_CHILD" ] || fail 'successful retry retained the child home'
[ ! -e "$HOME_PARENT/state/parent.meta" ] || fail 'successful retry retained the parent'
for holder in "$HOME_PARENT/state/fleet-seats/holders/"*.json; do
  jq -e 'all(.incarnations[]; .lifecycle == "released")' "$holder" >/dev/null || fail 'successful retry retained a counted seat'
done
# Under --force the named close may reach a same-named window on this server,
# so the decoy's fate is not a correctness signal. What must hold is that the
# task's own recorded endpoint is closed once the retry reports success.
if tmux -S "$LAB/p" display-message -p -t '=primary:=fm-parent' '#{pane_id}' >/dev/null 2>&1; then
  [ "$(tmux -S "$LAB/p" display-message -p -t '=primary:=fm-parent' '#{pane_dead}')" = 1 ] \
    || fail 'successful retry left the parent endpoint live'
fi
echo 'ok - forced teardown preserves wrong-socket children until owning-home cleanup'

HOME_SOLO="$LAB/solo"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_SOLO" >/dev/null
printf 'solo\n' > "$HOME_SOLO/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_PARENT" > "$HOME_SOLO/.fm-secondmate-parent"
printf -- '- solo - Lab mate. (home: %s; scope: tests; projects: ; added 2026-10-07)\n' "$HOME_SOLO" > "$HOME_PARENT/data/secondmates.md"
tmux -f /dev/null -S "$LAB/c" new-session -d -s solo -n fm-solo -c "$HOME_SOLO" 'sleep 300'
tmux -f /dev/null -S "$LAB/p" new-session -d -s decoy -n unrelated -c "$ROOT" 'sleep 300'
"$ROOT/bin/fm-fleet-seats.sh" reserve solo --generation g-solo --harness claude --model pool-model-a --kind secondmate --holder-pid "$$" >/dev/null
printf 'kind=secondmate\nmode=local-only\nbackend=tmux\nwindow=solo:fm-solo\nendpoint_task_id=solo\nworktree=%s\nproject=%s\nhome=%s\nspawn_gen=g-solo\nmodel=pool-model-a\n' "$HOME_SOLO" "$HOME_SOLO" "$HOME_SOLO" > "$HOME_PARENT/state/solo.meta"
(umask 077; printf '{"placement":"local","backend":"tmux","target":"solo:fm-solo","spawn_gen":"g-solo"}\n' > "$LAB/solo.route")
TMUX="$LAB/c,1,0" "$ROOT/bin/fm-fleet-seats.sh" dispatch solo --generation g-solo --route-file "$LAB/solo.route" >/dev/null
rc=0
"$ROOT/bin/fm-teardown.sh" solo --force > "$LAB/solo.stdout" 2> "$LAB/solo.stderr" || rc=$?
[ "$rc" -ne 0 ] || fail 'top-level wrong-socket cleanup succeeded'
[ "$(tmux -S "$LAB/c" display-message -p -t '=solo:=fm-solo' '#{pane_dead}')" = 0 ] || fail 'wrong-socket cleanup stopped the owning endpoint'
[ -f "$HOME_PARENT/state/solo.meta" ] || fail 'wrong-socket cleanup erased the route'
[ -d "$HOME_SOLO" ] || fail 'wrong-socket cleanup removed the home'
grep -Fx 'spawn_gen=g-solo' "$HOME_PARENT/state/solo.meta" >/dev/null || fail 'wrong-socket cleanup erased the generation binding'
ledger=$("$ROOT/bin/fm-fleet-seats.sh" show solo)
[ "$(printf '%s' "$ledger" | jq -r '.incarnations[0].lifecycle')" = reserved ] || fail 'wrong-socket cleanup released the seat'
TMUX="$LAB/c,1,0" "$ROOT/bin/fm-teardown.sh" solo --force > "$LAB/solo.retry.stdout" 2> "$LAB/solo.retry.stderr" || { cat "$LAB/solo.retry.stderr" >&2; fail 'owning-socket cleanup failed'; }
[ ! -e "$HOME_SOLO" ] || fail 'verified owning-socket cleanup retained the home'
ledger=$("$ROOT/bin/fm-fleet-seats.sh" show solo)
[ "$(printf '%s' "$ledger" | jq -r '.incarnations[0].lifecycle')" = released ] || fail 'verified destruction retained the seat'
echo 'ok - top-level cleanup requires owning-socket destruction evidence'

"$ROOT/bin/fm-fleet-seats.sh" reserve remote --generation g-remote --harness claude --model pool-model-a --kind secondmate --holder-pid "$$" >/dev/null
(umask 077; printf '{"placement":"remote","backend":"herdr","target":"fm-remote:p1","spawn_gen":"g-remote","operation":"g-remote","host":"remote-test","home":"/srv/mate","remote_root":"/srv/fm"}\n' > "$LAB/remote.route")
"$ROOT/bin/fm-fleet-seats.sh" dispatch remote --generation g-remote --route-file "$LAB/remote.route" >/dev/null
rc=0
"$ROOT/bin/fm-fleet-seats.sh" release remote --generation g-remote --reason teardown > "$LAB/remote.stdout" 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail 'remote cleanup accepted missing host evidence'
for field in generation home target destroyed; do
  (umask 077; jq -n --arg field "$field" '{task:"remote",generation:"g-remote",home:"/srv/mate",backend:"herdr",target:"fm-remote:p1",destroyed:true} | .[$field] = (if $field == "destroyed" then false else "wrong" end)' > "$LAB/retirement.json")
  rc=0
  "$ROOT/bin/fm-fleet-seats.sh" release remote --generation g-remote --reason teardown --response-file "$LAB/retirement.json" > "$LAB/remote.stdout" 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "remote cleanup accepted mismatched $field evidence"
done
(umask 077; printf '{"task":"remote","generation":"g-remote","home":"/srv/mate","backend":"herdr","target":"fm-remote:p1","destroyed":true}\n' > "$LAB/retirement.json")
"$ROOT/bin/fm-fleet-seats.sh" release remote --generation g-remote --reason teardown --response-file "$LAB/retirement.json" >/dev/null || fail 'remote cleanup refused matching host evidence'
ledger=$("$ROOT/bin/fm-fleet-seats.sh" show remote)
[ "$(printf '%s' "$ledger" | jq -r '.incarnations[0].lifecycle')" = released ] || fail 'verified remote retirement retained the seat'
echo 'ok - remote cleanup requires generation-bound host destruction evidence'
