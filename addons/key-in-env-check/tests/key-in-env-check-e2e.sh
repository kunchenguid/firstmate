#!/usr/bin/env bash
# key-in-env-check e2e: the real check against a fixture home and real fixture processes
# (a key-holding parent with child workers in a task worktree, and a key-free worker).
# Proves hit attribution, first alerting, quiet thresholds, new-name wakes for the
# current OpenRouter key (hash matches a fixture ~/.config/openrouter/api_key under
# a temp HOME), old-key log-only when the file is rotated (no wake even on count
# jumps), clean-scan reset, and that canary values never reach output or files.
# Never touches the real OpenRouter key file; never makes a network call.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
bin=${KEY_IN_ENV_BIN:-$here/../key-in-env-check}
[ -x "$bin" ] || { echo "not ok - $bin is missing"; exit 1; }
work=$(mktemp -d) || exit 1
pids=()
# shellcheck disable=SC2317,SC2329 # runs through the EXIT trap
cleanup() { # only the fixture processes this test started: their children first, then the roots
  for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  rm -rf -- "$work"
}
trap cleanup EXIT
fail=0
ok() { echo "ok - $1"; }
no() { echo "not ok - $1"; fail=1; }

canary=CANARY-$$-$RANDOM-sk-or-v1-deadbeef
rotated=ROTATED-$$-$RANDOM-sk-or-v1-beefdead
# Isolated HOME so the check reads only the fixture key file, never the real one.
export HOME=$work/userhome
mkdir -p "$HOME/.config/openrouter" "$work/pool/1/firstmate/state" "$work/wt-a" "$work/wt-b"
printf '%s\n' "$canary" >"$HOME/.config/openrouter/api_key"
home=$work/pool/1/firstmate
printf 'worktree=%s\nendpoint_task_id=task-a\n' "$work/wt-a" > "$home/state/task-a.meta"
export FM_HOME=$home FM_KEY_HOMES=$home

# Fixture trees run under setsid with an empty environment so nothing real (the live fleet's
# keys, the test shell's own parents) is picked up; FM_KEY_TREES scopes the scan to them.
# tree A: a parent holding the key that runs a child worker in the task worktree (key inherited).
# tree B: a worker with no key.
root() { # root <pidfile> <cwd> <env assignment or -> <exec command...>
  local pf=$1 cwd=$2 asg=$3; shift 3
  # shellcheck disable=SC2016 # the script is for the inner bash
  setsid -f env -i PATH="$PATH" bash -c 'echo $$ > "$1"; cd "$2"; shift 2; [ "$1" = - ] || export "$1"; shift; exec "$@"' _ "$pf" "$cwd" "$asg" "$@" </dev/null >/dev/null 2>&1
  for _ in $(seq 100); do [ -s "$pf" ] && break; sleep 0.1; done
  [ -s "$pf" ] || { echo "not ok - fixture root did not start"; exit 1; }
  pids+=("$(cat "$pf")")
}
# shellcheck disable=SC2016 # the loop runs in the fixture process shell
root "$work/a.pid" "$work/wt-a" "OPENROUTER_API_KEY=$canary" bash -c 'for _ in $(seq 49); do sleep 300 & done; wait'
root "$work/b.pid" "$work/wt-b" - sleep 300
sleep 1
export FM_KEY_TREES=${pids[0]},${pids[1]}
child=$(pgrep -P "${pids[0]}" sleep | head -n 1)

run() { "$bin" >"$work/out" 2>"$work/err"; }
run
inc=$home/state/key-in-env.incidents
line=$(awk -F'\t' -v p="$child" '$1==p' "$inc")
IFS=$'\t' read -r _ h t v top <<<"$line"
[ -n "$line" ] && ok "child worker listed" || no "child worker missing from $inc"
case "$h" in */1) ok "home attributed ($h)" ;; *) no "home is '$h'" ;; esac
[ "$t" = task-a ] && ok "task attributed" || no "task is '$t'"
[ "$v" = OPENROUTER_API_KEY ] && ok "variable named" || no "variable is '$v'"
[ "$top" = "bash(${pids[0]})" ] && ok "topmost parent named ($top)" || no "topmost is '$top'"
grep -q "key-in-env: " "$work/out" && grep -q "task-a" "$work/out" && ok "wake line printed" || no "no wake line"
grep -q '"count": 50' "$home/state/.key-in-env.alerted.json" && ok "alerted count persisted" || no "alerted count missing"

run
[ ! -s "$work/out" ] && ok "second run silent (de-duplicated)" || no "second run woke again"

# the key-free process in wt-b is never listed
[ "$(wc -l < "$inc")" -eq 50 ] && ok "key-free process not listed" || no "key-free process listed"

# A 10% process increase is quiet, even though the individual process set changed.
# shellcheck disable=SC2016 # the loop runs in the fixture process shell
root "$work/c.pid" "$work/wt-b" "OPENROUTER_API_KEY=$canary" bash -c 'for _ in $(seq 4); do sleep 300 & done; wait'
export FM_KEY_TREES=$FM_KEY_TREES,${pids[2]}
run
[ ! -s "$work/out" ] && ok "exact 10% process increase stays silent" || no "10% process increase woke"

# A 26% increase over the last alerted count wakes, even with the same key name.
# shellcheck disable=SC2016 # the loop runs in the fixture process shell
root "$work/d.pid" "$work/wt-b" "OPENROUTER_API_KEY=$canary" bash -c 'for _ in $(seq 7); do sleep 300 & done; wait'
export FM_KEY_TREES=$FM_KEY_TREES,${pids[3]}
run
grep -q "key-in-env: " "$work/out" && ok "exact 26% process increase wakes" || no "26% process increase stayed silent"

# Forced current key: a newly appearing key name while the env value still matches the file wakes once.
root "$work/e.pid" "$work/wt-b" "ANTHROPIC_API_KEY=$canary" sleep 302
export FM_KEY_TREES=$FM_KEY_TREES,${pids[4]}
run
grep -q "key-in-env: " "$work/out" && ok "forced current: new key name wakes" || no "forced current: new key name stayed silent"

# Forced old key: rotate the fixture key file so env canaries no longer match; log-only, no wake.
printf '%s\n' "$rotated" >"$HOME/.config/openrouter/api_key"
run
[ ! -s "$work/out" ] && ok "forced old key: no wake on stdout" || no "forced old key: woke on stdout"
grep -q "key revoked" "$work/err" && ok "forced old key: revoked note on stderr" || no "forced old key: revoked note missing"
if grep -q "key revoked" "$work/out" 2>/dev/null; then no "forced old key: revoked note on stdout"; else ok "forced old key: revoked note kept off stdout"; fi

# Count growth while the env still holds the old key must not wake Main.
# shellcheck disable=SC2016 # the loop runs in the fixture process shell
root "$work/f.pid" "$work/wt-b" "OPENROUTER_API_KEY=$canary" bash -c 'for _ in $(seq 40); do sleep 300 & done; wait'
export FM_KEY_TREES=$FM_KEY_TREES,${pids[5]}
run
[ ! -s "$work/out" ] && ok "forced old key: count jump stays silent" || no "forced old key: count jump woke"

# a custom pattern list narrows the match
FM_KEY_PATTERNS='NOTHING_*' run
[ ! -s "$inc" ] && ok "custom pattern list empties the match" || no "custom patterns ignored"
unset FM_KEY_PATTERNS

# A clean scan ends the active finding; restore the file to the env canary so a return wakes.
printf '%s\n' "$canary" >"$HOME/.config/openrouter/api_key"
run
grep -q "key-in-env: " "$work/out" && ok "finding after clean scan alerts again" || no "finding after clean scan stayed silent"

# canary / rotated values and full hashes are nowhere in anything the check wrote or printed
if grep -rqF -- "$canary" "$work/out" "$work/err" "$home" 2>/dev/null; then no "canary value leaked"; else ok "canary value absent from output, errors, incident file and state"; fi
if grep -rqF -- "$rotated" "$work/out" "$work/err" "$home" 2>/dev/null; then no "rotated key value leaked"; else ok "rotated key value absent from output, errors, incident file and state"; fi
kill -0 "${pids[0]}" 2>/dev/null && ok "no process signalled" || no "fixture daemon died"

exit "$fail"
