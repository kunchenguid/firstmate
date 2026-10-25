#!/usr/bin/env bash
# Behavior tests for bin/fm-midtask-fallback.sh.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-midtask-fallback.sh"
LAB="$(mktemp -d "${TMPDIR:-/tmp}/fm-midtask-fallback.XXXXXX")"
export HOME="$LAB/userhome"
export XDG_CONFIG_HOME="$LAB/xdg/config"
export XDG_DATA_HOME="$LAB/xdg/data"
export XDG_STATE_HOME="$LAB/xdg/state"
export XDG_CACHE_HOME="$LAB/xdg/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

ID=t7016
NOTE='The previous run stopped on a usage limit. Continue this task from the existing local copy, including uncommitted work.'
CASE=''
CONTROL_RC=0
unset FM_LIMIT_OBS || true

begin() {
  CASE="$LAB/cases/$1"
  rm -rf "$CASE"
  mkdir -p "$CASE/config" "$CASE/state" "$CASE/limits" "$CASE/work" "$CASE/bin"
  git -C "$CASE/work" init -q
  printf 'unlanded\n' > "$CASE/work/note.txt"
  cat > "$CASE/bin/control" <<'EOF'
#!/bin/bash
printf '%s\n' "$#" >> "$CONTROL_CALLS"
printf '%s\n' "$@" >> "$CONTROL_CALLS"
exit "${CONTROL_RC:-0}"
EOF
  chmod +x "$CASE/bin/control"
  : > "$CASE/control-calls"
  CONTROL_RC=0
  unset FM_LIMIT_OBS || true
}

write_meta() {
  cat > "$CASE/state/$ID.meta" <<EOF
kind=ship
harness=claude
model=claude-sonnet-5
effort=high
worktree=$CASE/work
EOF
}

write_rules() {
  local fallback=${1-}
  local body
  body='{"rules":[{"when":"work","use":[
    {"harness":"claude","model":"claude-sonnet-5","effort":"high"},
    {"harness":"grok","model":"grok-4","effort":"high"},
    {"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}'
  if [ -n "$fallback" ]; then
    printf '%s\n' "$body" | jq --argjson fb "$fallback" '. + {mid_task_fallback:$fb}' > "$CASE/config/crew-dispatch.json"
  else
    printf '%s\n' "$body" | jq . > "$CASE/config/crew-dispatch.json"
  fi
}

write_pair() {
  local fallback=$1 second_effort=$2
  jq -n --argjson fb "$fallback" --arg effort "$second_effort" '{
    mid_task_fallback: $fb,
    rules: [{when:"work", use:[
      {harness:"claude", model:"claude-sonnet-5", effort:"high"},
      {harness:"codex", model:"gpt-5.5", effort:$effort}
    ]}]
  }' > "$CASE/config/crew-dispatch.json"
}

quota_doc() {
  local out=$1
  shift
  jq -n '{schemaVersion:5, providers:[]}' > "$out"
  while [ "$#" -ge 3 ]; do
    jq --arg p "$1" --arg r "$2" --argjson n "$3" \
      '.providers += [{provider:$p, quotaSemantics:{status:"known", effectiveAvailability:[{scope:"all_models", status:"known", effectivePercentRemaining:$n, runway:{status:$r}}]}}]' \
      "$out" > "$out.next"
    mv "$out.next" "$out"
    shift 3
  done
}

invoke() {
  FM_HOME="$CASE" \
  FM_STATE_OVERRIDE="$CASE/state" \
  FM_CONFIG_OVERRIDE="$CASE/config" \
  FM_MIDTASK_CONTROL_BIN="$CASE/bin/control" \
  CONTROL_CALLS="$CASE/control-calls" \
  CONTROL_RC="$CONTROL_RC" \
  FM_LIMIT_MESSAGE_DIR="$CASE/limits" \
    "$SCRIPT" "$@"
}

assert_kept() {
  local label=$1 got
  [ -f "$CASE/work/note.txt" ] || fail "$label: unlanded file was removed"
  git -C "$CASE/work" status --porcelain | grep -q 'note.txt' || fail "$label: local copy has no uncommitted file"
  got=$(awk -F= '/^worktree=/ { v = substr($0, index($0, "=") + 1) } END { print v }' "$CASE/state/$ID.meta")
  [ "$got" = "$CASE/work" ] || fail "$label: recorded local copy changed to $got"
}

assert_no_control() {
  [ ! -s "$CASE/control-calls" ] || fail "$1: relaunched: $(cat "$CASE/control-calls")"
}

assert_switch() {
  local harness=$1 model=$2 effort=$3 reason=$4 line n
  [ -s "$CASE/control-calls" ] || fail "control was not called"
  n=$(awk 'NR==1 { print; exit }' "$CASE/control-calls")
  [ "$n" = 10 ] || fail "expected 10 control arguments, got $n"
  line=$(sed -n '2,11p' "$CASE/control-calls")
  [ "$line" = "$ID
relaunch
--harness
$harness
--model
$model
--effort
$effort
--note
$NOTE" ] || fail "relaunch arguments were: $line"
  grep -Eq "^switched \\[at=[0-9]+\\]: claude claude-sonnet-5 high -> $harness $model $effort because a usage limit stopped the worker$" \
    "$CASE/state/$ID.status" || fail "missing switch outcome"
  sed -n 's/^midtask_switch=//p' "$CASE/state/$ID.meta" | tail -n 1 | jq -e \
    --arg h "$harness" --arg m "$model" --arg e "$effort" --arg reason "$reason" \
    '.from == {harness:"claude", model:"claude-sonnet-5", effort:"high"} and .to == {harness:$h, model:$m, effort:$e} and .reason == $reason and (.at | type) == "number"' \
    >/dev/null || fail "task record did not store the switch"
  [ "$(wc -l < "$CASE/control-calls" | tr -d '[:space:]')" = 11 ] || fail "control ran more than once"
}

# Setting absent: a recorded array does not relaunch.
begin absent
write_rules
write_meta
printf 'dispatch_array=%s\ndispatch_fallback=on\n' \
  "$(jq -c '.rules[0].use' "$CASE/config/crew-dispatch.json")" >> "$CASE/state/$ID.meta"
printf 'paused [at=100]: hit a rate limit\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 grok exhausted_now 0 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "setting absent exited $rc: $out"
assert_no_control "setting absent"
assert_kept "setting absent"
grep -q '^midtask_switch=' "$CASE/state/$ID.meta" && fail "setting absent wrote a switch" || true
ok "setting absent does not relaunch"

# Setting off at bind writes nothing.
begin bind-off
write_rules
write_meta
out=$(invoke bind "$ID" --rule 0)
rc=$?
[ "$rc" -eq 0 ] || fail "bind while off exited $rc"
[ "$out" = "mid-task fallback: off" ] || fail "bind while off said: $out"
grep -q '^dispatch_array=' "$CASE/state/$ID.meta" && fail "bind while off recorded an array" || true
ok "bind while off records nothing"

# Setting present: next non-exhausted candidate, local copy kept, no second relaunch.
begin present
write_rules true
write_meta
out=$(invoke bind "$ID" --rule 0)
[ "$out" = "bound: $ID" ] || fail "bind said: $out"
printf 'paused [at=100]: usage limit reached\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 grok exhausted_now 0 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "eligible next exited $rc: $out"
[ "$out" = "relaunched: codex gpt-5.5 high" ] || fail "eligible next said: $out"
assert_switch codex gpt-5.5 high usage-limit
assert_kept "eligible next"
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "second consider exited $rc: $out"
[ "$(wc -l < "$CASE/control-calls" | tr -d '[:space:]')" = 11 ] || fail "second consider relaunched again"
assert_kept "second consider"
ok "setting present relaunches the next eligible profile and keeps the local copy"

# No eligible candidate: no relaunch, one decision report, local copy kept.
begin none
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: out of credits\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 grok exhausted_now 0 codex exhausted_now 0
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 2 ] || fail "no candidate exited $rc: $out"
[ "$out" = "no eligible candidate" ] || fail "no candidate said: $out"
assert_no_control "no candidate"
assert_kept "no candidate"
grep -Eq '^needs-decision \[at=[0-9]+\] \[key=midtask-fallback\]: ' "$CASE/state/$ID.status" \
  || fail "no candidate did not report the decision"
grep -q '^midtask_switch=' "$CASE/state/$ID.meta" && fail "no candidate wrote a switch" || true
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 2 ] || fail "repeat no candidate exited $rc: $out"
[ "$(grep -c 'key=midtask-fallback' "$CASE/state/$ID.status")" = 1 ] || fail "repeat no candidate reported twice"
printf 'working [at=200]: resumed\n' >> "$CASE/state/$ID.status"
invoke consider "$ID" --snapshot "$CASE/snap.json" >/dev/null
[ "$(grep -c 'key=midtask-fallback' "$CASE/state/$ID.status")" = 2 ] || fail "stall after a resume was not reported"
ok "no eligible candidate does not relaunch and reports the decision"

# Limit text on a status line is not a signal, with or without a snapshot.
begin ordinary
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: waiting for the GitHub API rate limit to reset\n' > "$CASE/state/$ID.status"
out=$(invoke consider "$ID")
rc=$?
[ "$rc" -eq 0 ] || fail "ordinary pause exited $rc: $out"
assert_no_control "ordinary pause"
quota_doc "$CASE/snap.json" claude through_reset 40 grok through_reset 40 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "ordinary pause with snapshot exited $rc: $out"
[ -z "$out" ] || fail "ordinary pause printed: $out"
assert_no_control "ordinary pause with snapshot"
ok "status line limit text does not relaunch"

# The current profile exhausted_now starts the switch with no status text at all.
begin snapshot-trigger
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
: > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 grok through_reset 40 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "snapshot trigger exited $rc: $out"
[ "$out" = "relaunched: grok grok-4 high" ] || fail "snapshot trigger said: $out"
assert_switch grok grok-4 high usage-limit
ok "exhausted_now on the current profile relaunches"

# A lower effort stays ineligible unless the setting allows it.
begin lower-blocked
write_pair true low
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: exhausted credits\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 2 ] || fail "lower effort exited $rc: $out"
assert_no_control "lower effort"
ok "lower effort is not eligible"

begin lower-allowed
write_pair '{"allow_lower_reasoning_class":true}' low
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: rate-limit\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 codex through_reset 40
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "allowed lower effort exited $rc: $out"
assert_switch codex gpt-5.5 low usage-limit
ok "allowed lower effort relaunches"

# Version-pinned adapter. The token is a fixture, not vendor text.
begin adapter
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: waiting for review\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude through_reset 40 grok exhausted_now 0 codex through_reset 40
cat > "$CASE/limits/claude.sh" <<'EOF'
fm_limit_message_versions() { printf '%s\n' '1.2.3'; }
fm_limit_message_observed_version() { printf '%s\n' "${FM_LIMIT_OBS:-1.2.3}"; }
fm_limit_message_match() { grep -q 'QUARANTINE-LIMIT-TOKEN'; }
EOF
printf 'pane says QUARANTINE-LIMIT-TOKEN\n' > "$CASE/pane.txt"
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json" --pane-text-file "$CASE/pane.txt")
rc=$?
[ "$rc" -eq 0 ] || fail "pinned limit message exited $rc: $out"
assert_switch codex gpt-5.5 high limit-message
ok "pinned limit message relaunches"

begin adapter-mismatch
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: waiting for review\n' > "$CASE/state/$ID.status"
cat > "$CASE/limits/claude.sh" <<'EOF'
fm_limit_message_versions() { printf '%s\n' '1.2.3'; }
fm_limit_message_observed_version() { printf '%s\n' "${FM_LIMIT_OBS:-1.2.3}"; }
fm_limit_message_match() { grep -q 'QUARANTINE-LIMIT-TOKEN'; }
EOF
printf 'pane says QUARANTINE-LIMIT-TOKEN\n' > "$CASE/pane.txt"
export FM_LIMIT_OBS=9.9.9
out=$(invoke consider "$ID" --pane-text-file "$CASE/pane.txt")
rc=$?
unset FM_LIMIT_OBS
[ "$rc" -eq 0 ] || fail "unpinned limit message exited $rc: $out"
assert_no_control "unpinned limit message"
grep -q 'midtask-fallback' "$CASE/state/$ID.status" && fail "unpinned limit message reported a decision" || true
ok "unpinned limit message is not a signal"

# A failed relaunch is recorded and not retried.
begin control-fails
write_pair true high
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: rate limit\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 codex through_reset 40
CONTROL_RC=1
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 1 ] || fail "failed relaunch exited $rc: $out"
grep -Eq '^blocked \[at=[0-9]+\] \[key=midtask-fallback\]: ' "$CASE/state/$ID.status" \
  || fail "failed relaunch did not report the block"
sed -n 's/^midtask_switch_failed=//p' "$CASE/state/$ID.meta" | tail -n 1 | jq -e \
  '.to.harness == "codex" and .reason == "usage-limit"' >/dev/null \
  || fail "failed relaunch did not record the candidate"
grep -q '^midtask_switch=' "$CASE/state/$ID.meta" && fail "failed relaunch recorded a completed switch" || true
assert_kept "failed relaunch"
printf 'paused [at=200]: rate limit again\n' >> "$CASE/state/$ID.status"
CONTROL_RC=0
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 2 ] || fail "retry after failure exited $rc: $out"
[ "$(wc -l < "$CASE/control-calls" | tr -d '[:space:]')" = 11 ] || fail "failed candidate was retried"
assert_kept "retry after failure"
[ "$(grep -c 'key=midtask-fallback' "$CASE/state/$ID.status")" = 2 ] || fail "later no-candidate stall was not reported"
ok "failed relaunch is not retried"

# The same recorded switch does not relaunch again while the pause line remains last.
begin idempotent
write_rules true
write_meta
invoke bind "$ID" --rule 0 >/dev/null
printf 'paused [at=100]: rate limit\n' > "$CASE/state/$ID.status"
quota_doc "$CASE/snap.json" claude exhausted_now 0 grok exhausted_now 0 codex through_reset 40
invoke consider "$ID" --snapshot "$CASE/snap.json" >/dev/null
printf 'paused [at=100]: rate limit\n' > "$CASE/state/$ID.status"
out=$(invoke consider "$ID" --snapshot "$CASE/snap.json")
rc=$?
[ "$rc" -eq 0 ] || fail "recorded switch exited $rc: $out"
[ "$(wc -l < "$CASE/control-calls" | tr -d '[:space:]')" = 11 ] || fail "recorded switch relaunched again"
assert_kept "recorded switch"
ok "a recorded switch does not relaunch again"
