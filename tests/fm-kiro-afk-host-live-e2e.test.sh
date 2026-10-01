#!/usr/bin/env bash
# Opt-in credentialed live guard for a whole away cycle on a real Kiro V3
# primary whose home opted into the supervision host (config/supervision-host,
# docs/supervision-host.md "Away").
#
# Builds a lab home from the current working files with config/supervision-host
# naming the Claude engine, a ready ship task whose PR lives on a lab-only fake
# forge (gh and gh-axi on PATH, a repository that does not exist on GitHub, so a
# leaked call can never merge anything), and launches bin/fm-kiro-primary.sh in
# a private tmux server. After one first prompt the doorbell owner must run the
# supervision host. The captain then says they are going afk with words that
# ask for the merge: the real primary must write the away-posture record and
# launch no away daemon. A real ready status line then wakes the host, whose
# real headless engine turn must merge the green PR through bin/fm-pr-merge.sh
# under away authority while main stays parked (no doorbell, no note). The
# captain's next ordinary message must run the return, archive the record, and
# report the merge. This submits three Kiro prompts and at least one engine
# turn. Cleanup removes the lab's own Kiro sessions from the login home.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_AFK_HOST_LIVE_E2E tmux kiro-cli claude node perl jq git tar

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
KIRO_VERSION=$("$KIRO_BIN" --version 2>/dev/null | head -n 1)
case "$KIRO_VERSION" in
  'kiro-cli 2.24.1') ;;
  *) fail "Kiro away-host proof requires the recorded 2.24.1 surface, found: $KIRO_VERSION" ;;
esac
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)

LAB=$(fm_test_tmproot fm-kiro-afk-host-live)
LAB=$(cd -P "$LAB" && pwd -P)
PRIMARY="$LAB/firstmate"
FORGE="$LAB/forge"
WT="$LAB/demo-wt"
SOCK="$LAB/tmux.sock"
SESSION=kiro-afk-host-live
TARGET="$SESSION"
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
WAIT=${FM_KIRO_AFK_HOST_TIMEOUT:-600}
URL=https://github.com/fm-lab-invalid/demo/pull/7
IDLE='ask a question or describe a task'

# A lab copy of the current working files (tracked and untracked, never
# ignored), committed on main, so the lab is a genuine primary checkout.
mkdir -p "$PRIMARY"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$PRIMARY" && tar -xf -)
git -C "$PRIMARY" init -q -b main
git -C "$PRIMARY" add -A >/dev/null
git -C "$PRIMARY" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects" "$LAB/tmux-tmpdir"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$PRIMARY/data/backlog.md"
printf 'claude\n' > "$PRIMARY/config/supervision-host"

# The ready task's pushed head, in its own repository; its record is written
# only once the captain is away, so startup recovery never sees it.
git init -q -b fm/demo "$WT"
git -C "$WT" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m demo
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" update-ref refs/remotes/origin/fm/demo "$HEAD_SHA"

# The fake forge: one open, green, mergeable pull request until a merge that
# names its exact head lands; every call is logged.
mkdir -p "$FORGE/bin"
printf '%s\n' "$HEAD_SHA" > "$FORGE/head"
: > "$FORGE/gh.log"
cat > "$FORGE/bin/gh" <<'SH'
#!/usr/bin/env bash
F=${FM_LAB_FORGE:?}
printf '%s\n' "$*" >> "$F/gh.log"
head=$(cat "$F/head")
state=OPEN merged=false
[ -e "$F/merged" ] && { state=MERGED; merged=true; }
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *" headRefOid -q "*|*" headRefOid --jq "*) printf '%s\n' "$head"; exit 0 ;;
    esac
    printf '{"state":"%s","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-01T00:00:00Z","completedAt":"2026-10-01T00:01:00Z"}]}\n' \
      "$state" "$head"
    exit 0 ;;
  "pr merge")
    case " $* " in
      *" --match-head-commit $head "*|*" --match-head-commit $head") ;;
      *) echo "error: merge did not name the verified head" >&2; exit 1 ;;
    esac
    : > "$F/merged"
    printf 'merged pull request #%s\n' "${3:-}"
    exit 0 ;;
  "pr checks") printf 'ci\tpass\t1m\thttps://example.invalid/ci\n'; exit 0 ;;
  "api graphql") printf 'state=%s\nmerged=%s\nqueued=false\nbase=main\n' "$state" "$merged"; exit 0 ;;
  api\ *)
    case " $* " in
      *"/rules/branches/"*merge_queue*) exit 0 ;;
      *"/rules/branches/"*) printf '[{"type":"deletion"}]\n'; exit 0 ;;
      *"/branches/"*) printf '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n'; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
cat > "$FORGE/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
F=${FM_LAB_FORGE:?}
printf '%s\n' "$*" >> "$F/gh-axi.log"
state=open
[ -e "$F/merged" ] && state=merged
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: %s\n  draft: no\n  checks: 1 passed, 0 failed\n' "${3:-7}" "$state" ;;
  "pr checks") printf 'checks[1]{name,status,conclusion}:\n  ci,completed,success\n' ;;
  *) printf 'ok\n' ;;
esac
exit 0
SH
chmod +x "$FORGE/bin/gh" "$FORGE/bin/gh-axi"

tm() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" "$@"; }
pane_history() { tm capture-pane -p -S - -t "$TARGET" 2>/dev/null || true; }
visible() { tm capture-pane -p -t "$TARGET" 2>/dev/null || true; }
doorbells() { pane_history | grep -c 'Firstmate wake waiting:' || true; }
idle_now() { visible | grep -Fq "$IDLE" && ! visible | grep -Fq 'Kiro is working'; }
say() {  # <text>: the captain typing one message
  tm set-buffer -- "$1"
  tm paste-buffer -d -t "$TARGET"
  sleep 0.5
  tm send-keys -t "$TARGET" Enter
}
wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}
settled_idle() {  # <seconds>: idle composer, unchanged doorbells, empty queue
  local need=$1 quiet=0 i=0 last now
  last=$(doorbells)
  while [ "$i" -lt "$WAIT" ]; do
    now=$(doorbells)
    if [ "$now" -eq "$last" ] && [ ! -s "$PRIMARY/state/.wake-queue" ] && idle_now; then
      quiet=$((quiet + 1))
    else
      quiet=0 last=$now
    fi
    [ "$quiet" -ge "$need" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

owner_pid() { cat "$PRIMARY/state/.primary-doorbell.lock/pid" 2>/dev/null; }
owner_live() { local p; p=$(owner_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
host_pid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$PRIMARY/state/.supervision-host" 2>/dev/null; }
host_live() { local p; p=$(host_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
merged() { grep -qxF "pr merge 7 --repo fm-lab-invalid/demo --match-head-commit $HEAD_SHA --squash" "$FORGE/gh.log"; }
away_handled() { grep -q '	handled	turn=[^	]*	posture=away	' "$PRIMARY/state/.supervision-host.log" 2>/dev/null; }
away_logged() { grep -q '"task":"demo".*per your away instructions' "$PRIMARY/state/branch-outcomes.jsonl" 2>/dev/null; }
archived() { [ ! -e "$PRIMARY/state/.afk-contract" ] && ls "$PRIMARY/state/afk-contracts/"*.afk-contract >/dev/null 2>&1; }

lab_pids() {  # every process whose environment names this lab
  local f pid
  for f in /proc/[0-9]*/environ; do
    pid=${f#/proc/}
    pid=${pid%/environ}
    [ "$pid" != "$$" ] || continue
    grep -qzF "$LAB" "$f" 2>/dev/null && printf '%s\n' "$pid"
  done
}

# The lab's own Kiro conversations: kiro-cli writes them under the login home
# even with its own KIRO_HOME, so remove exactly the ones whose session record
# names a workspace inside this lab.
lab_sessions() {
  local meta
  for meta in "$LOGIN_HOME"/.kiro/sessions/*/sess_*/session.json; do
    [ -f "$meta" ] || continue
    grep -qF "\"$LAB" "$meta" 2>/dev/null && printf '%s\n' "${meta%/session.json}"
  done
}

cleanup() {
  local pid dir
  tm kill-server 2>/dev/null || true
  for pid in "$(owner_pid)" "$(host_pid)" "$(cat "$PRIMARY/state/.watch.lock/pid" 2>/dev/null)"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
  for dir in $(lab_sessions); do
    case "$dir" in "$LOGIN_HOME"/.kiro/sessions/*/sess_*) rm -rf "$dir" ;; esac
  done
}
trap 'cleanup; fm_test_cleanup' EXIT

diagnose() {  # <message>
  pane_history | tail -150 >&2
  printf -- '--- host log\n%s\n--- queue\n%s\n--- doorbell note\n%s\n--- forge\n%s\n--- outcomes\n%s\n' \
    "$(cat "$PRIMARY/state/.supervision-host.log" 2>/dev/null)" "$(cat "$PRIMARY/state/.wake-queue" 2>/dev/null)" \
    "$(cat "$PRIMARY/state/.primary-doorbell-note" 2>/dev/null)" "$(cat "$FORGE/gh.log" 2>/dev/null)" \
    "$(cat "$PRIMARY/state/branch-outcomes.jsonl" 2>/dev/null)" >&2
  ls -la "$PRIMARY/state" >&2
  fail "$1 ($KIRO_VERSION, $CLAUDE_VERSION)"
}

# The pane keeps the private server's own TMUX and TMUX_PANE: they are how the
# primary publishes its endpoint, and every lab tmux call reaches this server.
tm new-session -d -s "$SESSION" -x 200 -y 55 -c "$PRIMARY" -- \
  env HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
  PATH="$FORGE/bin:$PATH" FM_LAB_FORGE="$FORGE" TMUX_TMPDIR="$LAB/tmux-tmpdir" \
  "$PRIMARY/bin/fm-kiro-primary.sh" ${FM_KIRO_LIVE_MODEL:+--model "$FM_KIRO_LIVE_MODEL"} \
  || fail "the private tmux server did not start"

wait_for 180 sh -c "'$REAL_TMUX' -S '$SOCK' capture-pane -p -t '$TARGET' 2>/dev/null | grep -Fq '$IDLE'" \
  || diagnose "the real V3 primary never reached its initial composer"
say 'Follow all SessionStart hook context, then reply with exactly PRIMARYREADY.'
ready() { [ -f "$PRIMARY/state/.primary-endpoint" ] && pane_history | grep -Fq PRIMARYREADY && idle_now; }
wait_for "$WAIT" ready || diagnose "the first prompt did not publish an idle Kiro endpoint"
settled_idle 15 || diagnose "the primary never settled after its first turn"
pass "a real Kiro primary published its endpoint from its first prompt"

# The ready task's record exists before the captain leaves, as a dispatched
# worker's does, so the away turn's Stop hook keeps the doorbell owner running.
# Its endpoint is a live window in the private server whose process is a copied
# sleep named claude, so the worker reads as alive and idle on its declared wait.
mkdir -p "$LAB/harness"
cp "$(command -v sleep)" "$LAB/harness/claude"
tm new-window -d -t "$SESSION" -n fm-demo "'$LAB/harness/claude' 100000" || fail "could not open the demo worker window"
printf 'window=%s:fm-demo\nbackend=tmux\nharness=claude\nkind=ship\nmode=no-mistakes\nworktree=%s\nproject=demo\n' \
  "$SESSION" "$WT" > "$PRIMARY/state/demo.meta"
printf 'paused [at=%s]: waiting for the demo PR checks\n' "$(date +%s)" >> "$PRIMARY/state/demo.status"

say "I'm going afk now. While I'm away, merge the demo PR as soon as its checks are green."
wait_for "$WAIT" test -e "$PRIMARY/state/.afk-contract" || diagnose "the afk message wrote no away-posture record"
grep -qi 'merge' "$PRIMARY/state/.afk-contract" || diagnose "the away record lost the captain's merge words"
settled_idle 10 || diagnose "the primary never settled after entering away mode"
[ ! -e "$PRIMARY/state/.afk" ] || diagnose "an away daemon flag exists on a home that runs the supervision host"
for pid in $(lab_pids); do
  tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" | grep -q 'fm-supervise-daemon' \
    && diagnose "an away daemon runs on a home that runs the supervision host (pid $pid)"
done
pass "the afk message wrote the away-posture record and launched no away daemon"
wait_for 60 owner_live || diagnose "the away turn's Stop hook left no live doorbell owner"
wait_for 60 host_live || diagnose "the doorbell owner never started the supervision host"
HOST_PID=$(host_pid)
tr '\0' '\n' < "/proc/$HOST_PID/environ" | grep -qx 'FM_SUPERVISION_HOST_PRIMARY=kiro-cli' \
  || diagnose "the host does not run for primary kiro-cli"
pass "the doorbell owner runs the supervision host for the parked Kiro primary"

BASE_BELLS=$(doorbells)
printf 'done [at=%s]: PR %s checks green\n' "$(date +%s)" "$URL" >> "$PRIMARY/state/demo.status"
i=0
while [ "$i" -lt "$WAIT" ]; do
  [ "$(doorbells)" -eq "$BASE_BELLS" ] || diagnose "the Kiro pane was rung while away"
  idle_now || diagnose "main started a turn while it should be parked"
  merged && away_logged && break
  sleep 1
  i=$((i + 1))
done
merged || diagnose "the away session never merged the green PR at its verified head"
away_logged || diagnose "the away turn did not log the merge under the captain's words"
wait_for 60 away_handled || diagnose "the supervision host recorded no handled away turn"
pass "a real engine turn merged the green PR under away authority and logged it under the captain's words"
! grep -qE '	(stand-down|to-main)	' "$PRIMARY/state/.supervision-host.log" \
  || diagnose "the host stood down or handed a wake to main"
sleep 10
[ "$(doorbells)" -eq "$BASE_BELLS" ] || diagnose "the Kiro pane was rung after the merge"
idle_now || diagnose "main is not parked after the merge"
[ ! -s "$PRIMARY/state/.primary-doorbell-note" ] || diagnose "the owner queued a doorbell note for main"
host_live || diagnose "the host is not parked after handling"
pass "main stayed parked: no doorbell, no note, no turn, and the host is still parked"

# The stand-in worker has no brief, spawn generation, or pool worktree, so a
# real cleanup of it can only refuse; retire its records before the captain
# returns, leaving the away session's account in the outcome store.
tm kill-window -t "$SESSION:fm-demo" 2>/dev/null || true
rm -f "$PRIMARY/state/demo.meta" "$PRIMARY/state/demo.status" "$PRIMARY/state/demo.check.sh"
RETURN_MARK=$(pane_history | wc -l)
say "I'm back. What happened while I was away?"
wait_for "$WAIT" archived || diagnose "the captain's return did not archive the away record"
settled_idle 10 || diagnose "the primary never settled after the return"
pane_history | tail -n +"$RETURN_MARK" | grep -Eq 'pull/7|PR 7|#7|demo' \
  || diagnose "the return reply did not report the merged demo PR"
pass "the captain's return archived the record and reported the merge"

trap - EXIT
cleanup
fm_test_cleanup
[ -z "$(lab_pids)" ] || fail "processes outlived the lab: $(lab_pids | tr '\n' ' ')"
[ -z "$(lab_sessions)" ] || fail "lab Kiro sessions outlived the lab"
pass "cleanup left no lab process or lab Kiro session"
