#!/usr/bin/env bash
# Behavioral tests for task-bound rolling-quota reset recovery.
set -u

# This test drives the real bin/fm-send.sh (via `handle`'s guarded delivery),
# one of the fleet-lifecycle entrypoints fm-gate-refuse-lib.sh guards. See that
# library's TEST-HARNESS ESCAPE HATCH note: firstmate's own test suite must be
# exempt from the gate-agent refusal to exercise these scripts for real.
export FM_GATE_REFUSE_BYPASS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-reset.XXXXXX")
FAKEBIN="$LAB/fakebin"
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$FAKEBIN"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'quota-axi 0.1.29\n'; exit 0; fi
count=0
[ ! -f "$QUOTA_COUNT" ] || read -r count < "$QUOTA_COUNT"
count=$((count + 1)); printf '%s\n' "$count" > "$QUOTA_COUNT"
sed -n "${count}p" "$QUOTA_SEQUENCE"
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ "${2:-}" = status ] && [ "${3:-}" = --run ]; then cat "$NM_RUN_STATUS"; exit "${NM_RUN_RC:-0}"; fi
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then cat "$NM_OVERVIEW"; exit "${NM_OVERVIEW_RC:-0}"; fi
exit 1
SH
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/no-mistakes"

quota() { # percent reset [state] [weekly-reset]
  local percent=$1 reset=$2 state=${3:-fresh} weekly=${4:-2026-09-28T00:00:00Z}
  printf '{"schemaVersion":5,"providers":[{"provider":"claude","windows":[{"id":"five_hour","label":"session","kind":"session","resetsAt":"%s","percentRemaining":%s},{"id":"seven_day","label":"week","kind":"weekly","resetsAt":"%s","percentRemaining":55}],"state":{"status":"%s","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]}}]}\n' "$reset" "$percent" "$weekly" "$state" "$percent"
}

make_case() { # name
  CASE="$LAB/$1"; HOME_DIR="$CASE/home"; WT="$CASE/wt"; STATE="$HOME_DIR/state"
  mkdir -p "$STATE" "$WT" "$CASE"
  git -C "$WT" init -q -b fm/quota-retry
  git -C "$WT" config user.email test@example.com
  git -C "$WT" config user.name Test
  printf 'base\n' > "$WT/file"; git -C "$WT" add file; git -C "$WT" commit -qm base
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  RUN_STATUS="$CASE/run.toon"; OVERVIEW="$CASE/overview.toon"; SEQUENCE="$CASE/quota.jsonl"; COUNT="$CASE/count"
  cat > "$RUN_STATUS" <<EOF
run:
  id: run-one
  branch: fm/quota-retry
  status: failed
  head: ${HEAD_SHA:0:8}
  head_sha: $HEAD_SHA
outcome: failed
error: "Claude usage limit exhausted for the five-hour session window"
branch_sync:
  state: returned
  next_action: none
EOF
  cat > "$OVERVIEW" <<EOF
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  "run-one",fm/quota-retry,failed,${HEAD_SHA:0:8},""
EOF
  cat > "$STATE/task.meta" <<EOF
kind=ship
spawn_gen=spawn-one
worktree=$WT
branch=fm/quota-retry
backend=tmux
window=fm-task
harness=claude
EOF
  SID=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-quota-reset.sh" source-id task)
  WATCH_DIR="$STATE/procevent-quota-reset"; WATCH="$WATCH_DIR/$SID.watch"
}

env_run() {
  PATH="$FAKEBIN:$PATH" QUOTA_AXI_COUNT="$COUNT" QUOTA_COUNT="$COUNT" QUOTA_SEQUENCE="$SEQUENCE" \
    NM_RUN_STATUS="$RUN_STATUS" NM_OVERVIEW="$OVERVIEW" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$@"
}

make_watch() {
  mkdir -p "$WATCH_DIR"
  local reset_epoch failure binding
  reset_epoch=$(printf '%s\n' '2026-09-21T06:30:00Z' | jq -Rr 'fromdateiso8601')
  failure=$(printf '%s' '"Claude usage limit exhausted for the five-hour session window"' | shasum -a 256 | awk '{print $1}')
  binding=$(printf '%s' "$STATE|task|spawn-one|run-one|$WT|fm/quota-retry|$HEAD_SHA|claude|five_hour|2026-09-21T06:30:00Z|$reset_epoch|0|$failure" | shasum -a 256 | awk '{print $1}')
  cat > "$WATCH" <<EOF
schema=fm-quota-reset.v1
state=$STATE
task=task
incarnation=spawn-one
run=run-one
worktree=$WT
branch=fm/quota-retry
head=$HEAD_SHA
provider=claude
window=five_hour
baseline_reset_at=2026-09-21T06:30:00Z
baseline_reset_epoch=$reset_epoch
baseline_percent=0
failure_digest=$failure
binding_digest=$binding
EOF
  BINDING=$binding
}

make_result() { # seq [status]
  local seq=$1 status=${2:-reset} inbox="$STATE/procevent-inbox"
  mkdir -p "$inbox"
  RESULT="$inbox/$SID.$seq.result"
  printf 'status: %s\nsource: %s\nbinding: %s\n' "$status" "$SID" "$BINDING" > "$RESULT"
  printf 'quota-reset\n' > "$inbox/$SID.$seq.adapter"
}

make_case capture
quota 0 2026-09-21T06:30:00Z > "$SEQUENCE"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" arm task --run run-one --provider claude --window five_hour --interval 3600 --timeout 2) || fail "exhausted capture did not arm"
printf '%s\n' "$out" | grep -q '^armed: quota-reset-' || fail "capture omitted source identity"
grep -qx "head=$HEAD_SHA" "$WATCH" || fail "capture omitted submitted head"
grep -qx 'baseline_percent=0' "$WATCH" || fail "capture omitted exhausted baseline"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" arm task --run run-one --provider claude --window five_hour --interval 3600 --timeout 2) || fail "duplicate capture failed"
printf '%s\n' "$out" | grep -qx "already-armed: $SID" || fail "duplicate capture replaced its binding"
env_run "$BIN/fm-procevent-quota-reset.sh" retire task >/dev/null || fail "capture watch did not retire"
pass "quota exhaustion capture binds task, run, head, incarnation, provider, and reset identity once"

make_case billing
quota 0 2026-09-21T06:30:00Z > "$SEQUENCE"
sed -i.bak 's/Claude usage limit exhausted for the five-hour session window/Monthly billing quota limit exhausted/' "$RUN_STATUS"
if env_run "$BIN/fm-procevent-quota-reset.sh" arm task --run run-one --provider claude --window five_hour --timeout 2 >"$CASE/out" 2>&1; then fail "billing-limit prose armed recovery"; fi
grep -q 'not a rolling quota-exhaustion failure' "$CASE/out" || fail "billing refusal was not explicit"
pass "billing-cap prose cannot masquerade as a rolling reset"

make_case rollover
make_watch
{ quota 100 2026-09-21T06:30:00Z  fresh 2026-10-05T00:00:00Z; quota 92 2026-09-21T11:30:00Z; } > "$SEQUENCE"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" poll "$SID" --interval 0.01 --timeout 2) || fail "rollover poll failed"
printf '%s\n' "$out" | grep -qx 'status: reset' || fail "advanced reset was not recognized"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' || fail "unchanged-reset 100 percent or weekly-only change fired"
printf '%s\n' "$out" | grep -qx 'percent_remaining: 92' || fail "restored headroom was not captured"
rm -f "$COUNT"; quota 75 2026-09-21T11:30:00Z > "$SEQUENCE"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" poll "$SID" --interval 0.01 --timeout 2) || fail "restart poll failed"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "durable baseline was not reused after process restart"
pass "only the same advanced five-hour reset with restored headroom fires across restarts"

make_case unknown
make_watch
quota 0 2026-09-21T06:30:00Z auth_required > "$SEQUENCE"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" poll "$SID" --interval 0.01 --timeout 2) || fail "unknown quota poll failed"
printf '%s\n' "$out" | grep -qx 'status: diagnosis' || fail "unknown provider evidence claimed or silently awaited reset"
: > "$SEQUENCE"; rm -f "$COUNT"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" poll "$SID" --interval 0.01 --timeout 2) || fail "quota tool error poll failed"
printf '%s\n' "$out" | grep -qx 'status: diagnosis' || fail "quota tool failure did not wake diagnosis"
pass "unknown, authentication, malformed, and provider failures stop for diagnosis"

run_refusal() { # name mutator expected
  local name=$1 mutator=$2 expected=$3 out
  make_case "$name"; make_watch; make_result 1
  eval "$mutator"
  out=$(env_run "$BIN/fm-procevent-quota-reset.sh" handle "$SID" 1 "$RESULT") || fail "$name handle errored"
  printf '%s\n' "$out" | grep -Fq "refused: $expected" || fail "$name was not refused for $expected: $out"
  [ -f "$STATE/procevent-inbox/$SID.1.handled" ] || fail "$name refusal did not acknowledge exact result"
  [ "$(find "$STATE/task.inbox" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "$name refusal delivered a retry"
}

run_refusal retired 'rm -f "$STATE/task.meta"' 'task was retired'
run_refusal incarnation 'sed -i.bak "s/spawn_gen=spawn-one/spawn_gen=spawn-two/" "$STATE/task.meta"' 'task incarnation or worktree changed'
run_refusal head 'printf changed >> "$WT/file"; git -C "$WT" add file; git -C "$WT" commit -qm changed' 'branch or submitted head changed'
run_refusal dirty 'printf dirty >> "$WT/file"' 'task worktree is dirty'
run_refusal stale-run 'sed -i.bak "s/outcome: failed/outcome: cancelled/" "$RUN_STATUS"' 'terminal quota failure no longer matches'
run_refusal custody 'sed -i.bak "s/state: returned/state: pipeline_owned/" "$RUN_STATUS"' 'branch custody requires another action'
run_refusal merged 'printf "pr=https://example.invalid/pr/1\n" >> "$STATE/task.meta"' 'task already entered merge or cleanup'
run_refusal active 'cat > "$OVERVIEW" <<EOF
count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  "run-two",fm/quota-retry,running,${HEAD_SHA:0:8},""
  "run-one",fm/quota-retry,failed,${HEAD_SHA:0:8},""
EOF' 'another validation run is active'
pass "wake reconciliation refuses retired, replaced, changed, dirty, active, merged, and custody-conflicted work"

make_case success
make_watch; make_result 7
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" handle "$SID" 7 "$RESULT") || fail "guarded retry delivery failed: ${out:-}"
[ "$out" = 'retry-delivered: task' ] || fail "successful delivery returned: $out"
[ -f "$STATE/procevent-inbox/$SID.7.handled" ] || fail "successful delivery omitted exact acknowledgement"
count=$(find "$STATE/task.inbox" -name '*.msg' | wc -l | tr -d ' ')
[ "$count" = 1 ] || fail "successful delivery did not create exactly one instruction"
msg=$(find "$STATE/task.inbox" -name '*.msg' | head -1)
grep -q 'original persisted captain intent' "$msg" || fail "retry lost original-intent requirement"
grep -q 'same sleep-prevention arrangement' "$msg" || fail "retry lost sleep-prevention requirement"
grep -q 'do not use --yes' "$msg" || fail "retry lost gate-ownership boundary"
out=$(env_run "$BIN/fm-procevent-quota-reset.sh" handle "$SID" 7 "$RESULT") || fail "duplicate handling failed"
count=$(find "$STATE/task.inbox" -name '*.msg' | wc -l | tr -d ' ')
[ "$count" = 1 ] || fail "duplicate outcome authorized duplicate retry"
env_run "$BIN/fm-procevent-quota-reset.sh" retire task >/dev/null || fail "explicit retirement failed"
[ ! -e "$WATCH" ] || fail "retirement retained private watch"
[ -f "$STATE/procevent-inbox/$SID.7.handled" ] || fail "retirement removed handled acknowledgement"
pass "guarded retry delivery is durable, idempotent, acknowledged exactly, and independently retired"

printf '# all fm-procevent-quota-reset tests passed\n'
