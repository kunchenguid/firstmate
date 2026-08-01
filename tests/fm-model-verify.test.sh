#!/usr/bin/env bash
# Behavior tests for bin/fm-model-verify.sh - the helper that checks the model a
# dispatched worker ACTUALLY ran on against the model firstmate RECORDED for it
# in state/<id>.meta.
#
# The record is what was REQUESTED, sometimes after a quota-balanced choice. The
# evidence is what the runtime WROTE. These cases pin every branch of that
# comparison hermetically, over a throwaway home and a throwaway claude config
# store, with no live fleet state and no real harness:
#   (a) a family alias matches any member of that family, suffix and all
#   (b) a pinned specific model matches only itself
#   (c) a downgrade below the dispatched family is a mismatch
#   (d) a mid-dispatch model change is a mismatch even when one value matches
#   (e) evidence that cannot be located or read is LOUD, never a quiet pass
#   (f) `pending` (nothing to compare yet) and `unpinned` (nothing promised) are
#       distinct no-verdict outcomes and never render as `match`
#   (g) spawned_at binds evidence to THIS dispatch, so a reused worktree's
#       previous occupant can neither be attributed to it nor silently ignored
#   (h) --all reports every task and exits on the worst verdict
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-model-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-verify)

# A throwaway home plus a throwaway claude config store. CLAUDE_CONFIG_DIR is
# the same knob bin/fm-spawn.sh forwards onto a real crewmate launch, so the
# fixture reads exactly the way production does.
HOME_DIR="$TMP_ROOT/home"
CFG="$TMP_ROOT/claude"
mkdir -p "$HOME_DIR/state" "$CFG/projects"
export CLAUDE_CONFIG_DIR="$CFG"

# encoded_dir <cwd>: claude's transcript directory for a working directory.
# Every character outside [A-Za-z0-9] becomes '-'.
encoded_dir() {
  printf '%s/projects/%s' "$CFG" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
}

# write_transcript <cwd> <session> <model>...: one JSONL transcript recording an
# assistant turn per model, in the shape the runtime writes.
write_transcript() {
  local cwd=$1 session=$2 dir model
  shift 2
  dir=$(encoded_dir "$cwd")
  mkdir -p "$dir"
  : > "$dir/$session.jsonl"
  for model in "$@"; do
    printf '{"type":"assistant","message":{"model":"%s"}}\n' "$model" >> "$dir/$session.jsonl"
  done
}

# meta <id> <model> [extra-key=value]...: a dispatch record for a claude worker
# in its own worktree under the throwaway home.
meta() {
  local id=$1 model=$2 wt
  shift 2
  wt="$TMP_ROOT/wt/$id"
  mkdir -p "$wt"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$wt" \
    "project=$TMP_ROOT/clone" \
    "harness=claude" \
    "kind=ship" \
    "model=$model" \
    "$@"
  printf '%s' "$wt"
}

run_verify() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$VERIFY" "$@" 2>&1
}

# --- (a) family alias matches any member of that family ---------------------

wt=$(meta alias-match opus)
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify alias-match); code=$?
expect_code 0 "$code" "alias match exits 0"
assert_contains "$out" "verdict: match" "an opus-family model satisfies a recorded 'opus'"
assert_contains "$out" "actual: claude-opus-5" "the actual model is reported verbatim"
pass "family alias matches a member of its family"

# The runtime appends a context-window suffix; it names the same model.
wt=$(meta suffix-match opus)
write_transcript "$wt" s1 'claude-opus-5[1m]'
out=$(run_verify suffix-match); code=$?
expect_code 0 "$code" "suffixed model exits 0"
assert_contains "$out" "verdict: match" "a [1m] context suffix does not make a model a different model"
pass "context-window suffix does not fake a mismatch"

# --- (b) a pinned specific model matches only itself ------------------------

wt=$(meta pinned-match claude-opus-4-8)
write_transcript "$wt" s1 claude-opus-4-8
out=$(run_verify pinned-match); code=$?
expect_code 0 "$code" "pinned exact match exits 0"
assert_contains "$out" "verdict: match" "a pinned model matches itself"
pass "pinned specific model matches itself"

# Same family, different version: the record promised a version, so this is not
# what was dispatched.
wt=$(meta pinned-version-drift claude-opus-4-8)
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify pinned-version-drift); code=$?
expect_code 3 "$code" "version drift under a pinned model exits 3"
assert_contains "$out" "verdict: mismatch" "a pinned version is not satisfied by another version"
pass "pinned model rejects a different version of the same family"

# --- (c) a downgrade below the dispatched family ----------------------------

wt=$(meta downgrade opus)
write_transcript "$wt" s1 claude-sonnet-5
out=$(run_verify downgrade); code=$?
expect_code 3 "$code" "silent downgrade exits 3"
assert_contains "$out" "verdict: mismatch" "sonnet does not satisfy a dispatched opus"
assert_contains "$out" "dispatched as 'opus' but ran on claude-sonnet-5" "the mismatch names both models"
pass "silent downgrade below the dispatched family is detected"

# --- (d) a mid-dispatch model change ----------------------------------------
#
# One value matching must never absolve the other: this is the case where a
# worker starts on the dispatched tier and is later served by another.

wt=$(meta mid-change opus spawned_at=1)
write_transcript "$wt" s1 claude-opus-5
write_transcript "$wt" s2 claude-sonnet-5
out=$(run_verify mid-change); code=$?
expect_code 3 "$code" "a partial match still exits 3"
assert_contains "$out" "verdict: mismatch" "a later downgrade is not excused by an earlier correct turn"
assert_contains "$out" "claude-sonnet-5" "the deviating model is named"
pass "mid-dispatch model change is detected"

# --- (e) evidence that cannot be located or read is loud --------------------

meta no-evidence opus >/dev/null
out=$(run_verify no-evidence); code=$?
expect_code 4 "$code" "missing transcript directory exits 4"
assert_contains "$out" "verdict: unverifiable" "a worker with no locatable evidence is unverifiable"
assert_not_contains "$out" "verdict: match" "unlocatable evidence never reads as a match"
pass "evidence that cannot be located fails loudly"

out=$(run_verify never-dispatched); code=$?
expect_code 4 "$code" "absent durable record exits 4"
assert_contains "$out" "verdict: unverifiable" "no record means no verdict, loudly"
pass "absent durable record fails loudly"

# A harness with no verified evidence source must say so rather than pass.
wt=$(meta other-harness opus)
sed -i.bak 's/^harness=claude$/harness=codex/' "$HOME_DIR/state/other-harness.meta"
rm -f "$HOME_DIR/state/other-harness.meta.bak"
write_transcript "$wt" s1 claude-opus-5
out=$(run_verify other-harness); code=$?
expect_code 4 "$code" "unsupported harness exits 4"
assert_contains "$out" "verdict: unverifiable" "a harness with no evidence adapter is unverifiable"
assert_contains "$out" "codex" "the unverifiable reason names the harness"
pass "a harness with no verified evidence source fails loudly"

# An unreadable transcript directory is a read failure, not a clean worker.
wt=$(meta unreadable opus)
dir=$(encoded_dir "$wt")
mkdir -p "$dir"
write_transcript "$wt" s1 claude-opus-5
chmod 000 "$dir"
out=$(run_verify unreadable); code=$?
chmod 755 "$dir"
if [ "$(id -u)" = 0 ]; then
  pass "unreadable transcript directory case skipped (running as root)"
else
  expect_code 4 "$code" "unreadable evidence exits 4"
  assert_contains "$out" "verdict: unverifiable" "unreadable evidence is unverifiable"
  pass "unreadable evidence fails loudly"
fi

# --- (f) pending and unpinned are distinct no-verdict outcomes --------------

wt=$(meta fresh-worker opus)
dir=$(encoded_dir "$wt")
mkdir -p "$dir"
printf '{"type":"user","message":{"role":"user"}}\n' > "$dir/s1.jsonl"
out=$(run_verify fresh-worker); code=$?
expect_code 0 "$code" "a worker with no turn yet does not alarm"
assert_contains "$out" "verdict: pending" "no model-attributed turn yet is pending"
assert_not_contains "$out" "verdict: match" "pending never reads as a verified match"
pass "a worker that has not taken a turn is pending, not verified"

# `<synthetic>` is a runtime placeholder for messages no model served. It must
# neither manufacture a mismatch nor stand in as evidence of a match.
wt=$(meta synthetic-only opus)
write_transcript "$wt" s1 '<synthetic>'
out=$(run_verify synthetic-only); code=$?
expect_code 0 "$code" "synthetic-only evidence does not alarm"
assert_contains "$out" "verdict: pending" "a synthetic placeholder is not a model"
pass "synthetic placeholder is not mistaken for a model"

wt=$(meta mixed-placeholder opus)
write_transcript "$wt" s1 '<synthetic>' claude-opus-5
out=$(run_verify mixed-placeholder); code=$?
expect_code 0 "$code" "synthetic alongside a real model does not alarm"
assert_contains "$out" "verdict: match" "the real model is compared and the placeholder ignored"
assert_not_contains "$out" "synthetic" "the placeholder is not reported as an actual model"
pass "synthetic placeholder never manufactures a mismatch"

# Nothing was promised, so there is no record for the runtime to contradict.
wt=$(meta unpinned-dispatch default)
write_transcript "$wt" s1 claude-sonnet-5
out=$(run_verify unpinned-dispatch); code=$?
expect_code 0 "$code" "an unpinned dispatch does not alarm"
assert_contains "$out" "verdict: unpinned" "no pinned model means no promise to check"
assert_not_contains "$out" "verdict: match" "unpinned never claims a verified match"
pass "unpinned dispatch is reported as unpinned, not verified"

# --- (g) spawned_at binds evidence to this dispatch -------------------------
#
# A worktree from a reusable pool can still carry the transcripts of a previous
# occupant. The dispatch timestamp is what tells the two apart.

wt=$(meta reused-slot opus spawned_at="$(date +%s)")
write_transcript "$wt" old claude-opus-4-8
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl"
write_transcript "$wt" new claude-opus-5
out=$(run_verify reused-slot); code=$?
expect_code 0 "$code" "a bound scan ignores a previous occupant"
assert_contains "$out" "verdict: match" "only this dispatch's evidence is compared"
assert_not_contains "$out" "claude-opus-4-8" "the previous occupant's model is not attributed to this task"
pass "dispatch timestamp binds evidence to this dispatch"

# A bound scan still catches a real deviation inside its own window.
wt=$(meta reused-slot-bad opus spawned_at="$(date +%s)")
write_transcript "$wt" old claude-opus-5
touch -t 200001010000 "$(encoded_dir "$wt")/old.jsonl"
write_transcript "$wt" new claude-sonnet-5
out=$(run_verify reused-slot-bad); code=$?
expect_code 3 "$code" "a bound scan still detects this dispatch's own downgrade"
assert_contains "$out" "verdict: mismatch" "binding does not blunt detection"
pass "dispatch timestamp does not hide a real downgrade"

# Without a timestamp, disagreeing evidence cannot be attributed. Guessing which
# half belongs to this task would be exactly the silent pass to avoid.
wt=$(meta unbound-ambiguous opus)
write_transcript "$wt" a claude-opus-5
write_transcript "$wt" b claude-opus-4-8
out=$(run_verify unbound-ambiguous); code=$?
expect_code 4 "$code" "unattributable evidence exits 4"
assert_contains "$out" "verdict: unverifiable" "disagreeing unbound evidence is unverifiable"
pass "unattributable evidence fails loudly instead of guessing"

# Unbound but unanimous evidence is still attributable, and discloses that the
# scan was not time-bounded.
wt=$(meta unbound-agreed opus)
write_transcript "$wt" a claude-opus-5
write_transcript "$wt" b claude-opus-5
out=$(run_verify unbound-agreed); code=$?
expect_code 0 "$code" "unanimous unbound evidence does not alarm"
assert_contains "$out" "verdict: match" "unanimous evidence is attributable"
assert_contains "$out" "not time-bounded" "the weaker binding is disclosed rather than hidden"
pass "unbound but unanimous evidence is matched with disclosure"

# --- secondmate: the worker runs in its own home, not a worktree ------------

SM_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SM_HOME"
fm_write_secondmate_meta "$HOME_DIR/state/sm.meta" "$SM_HOME" "firstmate:fm-sm" alpha claude
printf 'model=opus\n' >> "$HOME_DIR/state/sm.meta"
write_transcript "$SM_HOME" s1 claude-opus-5
out=$(run_verify sm); code=$?
expect_code 0 "$code" "secondmate evidence resolves from its home"
assert_contains "$out" "verdict: match" "a secondmate's evidence lives under its own home"
pass "secondmate evidence is read from its home"

# --- (h) --all reports every task and exits on the worst verdict ------------

out=$(run_verify --all); code=$?
expect_code 4 "$code" "--all exits on the worst verdict present"
assert_contains "$out" "alias-match" "--all reports every recorded task"
assert_contains "$out" "verdict: mismatch" "--all surfaces mismatches"
assert_contains "$out" "verdict: unverifiable" "--all surfaces unverifiable tasks"
pass "--all reports every task and exits on the worst verdict"

# A home whose every task is fine exits 0 - no behavior change for correctly
# routed work.
CLEAN_HOME="$TMP_ROOT/clean"
mkdir -p "$CLEAN_HOME/state"
clean_wt="$TMP_ROOT/wt/clean-task"
mkdir -p "$clean_wt"
fm_write_meta "$CLEAN_HOME/state/clean-task.meta" \
  "worktree=$clean_wt" "harness=claude" "kind=ship" "model=opus" "spawned_at=1"
write_transcript "$clean_wt" s1 claude-opus-5
out=$(FM_HOME="$CLEAN_HOME" FM_STATE_OVERRIDE="$CLEAN_HOME/state" "$VERIFY" --all 2>&1); code=$?
expect_code 0 "$code" "a correctly routed fleet exits 0"
assert_contains "$out" "verdict: match" "a correctly routed fleet reports match"
pass "a correctly routed fleet exits 0"

# --- structured output -------------------------------------------------------

out=$(run_verify downgrade --json); code=$?
expect_code 3 "$code" "--json preserves the verdict exit code"
verdict=$(printf '%s' "$out" | jq -r '.verdict')
[ "$verdict" = mismatch ] || fail "--json verdict: expected mismatch, got $verdict"
actual=$(printf '%s' "$out" | jq -r '.actual | join(",")')
[ "$actual" = claude-sonnet-5 ] || fail "--json actual: expected claude-sonnet-5, got $actual"
recorded=$(printf '%s' "$out" | jq -r '.recorded')
[ "$recorded" = opus ] || fail "--json recorded: expected opus, got $recorded"
pass "--json carries verdict, recorded, and actual"

out=$(run_verify --all --json); code=$?
expect_code 4 "$code" "--all --json exits on the worst verdict"
n=$(printf '%s' "$out" | jq -r 'length')
[ "$n" -gt 5 ] || fail "--all --json: expected a row per task, got $n"
printf '%s' "$out" | jq -e 'all(.[]; has("verdict") and has("actual"))' >/dev/null \
  || fail "--all --json: every row must carry a verdict and actual list"
pass "--all --json emits one structured row per task"

# --- usage -------------------------------------------------------------------

out=$(run_verify); code=$?
expect_code 2 "$code" "no arguments is a usage error"
out=$(run_verify a b); code=$?
expect_code 2 "$code" "two task ids is a usage error"
out=$(run_verify --all extra); code=$?
expect_code 2 "$code" "--all with a task id is a usage error"
pass "usage errors exit 2"

printf '\nall fm-model-verify tests passed\n'
