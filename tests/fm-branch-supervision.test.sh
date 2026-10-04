#!/usr/bin/env bash
# Tests for the Pi supervision branch's fleet-record layer
# (docs/pi-supervision-branch.md): the byte-stable branch prompt generator
# (bin/fm-branch-prompt.sh), the append-only outcome store
# (bin/fm-branch-outcome.sh), the per-task lease contract (bin/fm-lease.sh,
# bin/fm-lease-lib.sh), the lease and role-partition guards wired into the
# mutating entrypoints, and the proof that a home which never runs the branch
# is untouched by all of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-supervision)
fm_git_identity fmtest fmtest@example.invalid

# --- byte-stable branch prompt ------------------------------------------------

test_branch_prompt_is_byte_stable_and_above_cache_floor() {
  local home_a home_b out_a out_b out_c size
  home_a="$TMP_ROOT/prompt-home-a"
  home_b="$TMP_ROOT/prompt-home-b"
  mkdir -p "$home_a/state" "$home_b/state"
  # Give the two homes deliberately different fleet state and clock context:
  # a byte-stable prompt must not absorb any of it.
  printf 'signal: task-1 done\n' > "$home_a/state/task-1.status"
  printf 'window=x\nharness=pi\n' > "$home_a/state/task-1.meta"

  out_a=$(cd "$TMP_ROOT" && FM_HOME="$home_a" TZ=UTC "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home A"
  out_b=$(cd / && FM_HOME="$home_b" TZ=Australia/Eucla "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home B"
  sleep 1
  out_c=$("$ROOT/bin/fm-branch-prompt.sh") || fail "branch prompt generator failed on re-run"

  [ "$out_a" = "$out_b" ] || fail "branch prompt differs across homes/cwd/timezone: prefix stability broken"
  [ "$out_a" = "$out_c" ] || fail "branch prompt differs across runs at different times: prefix stability broken"

  # Below the provider's 1024-token caching minimum a branch prompt gets no
  # cache reuse at all (measured in the feasibility evidence), so hold a
  # comfortable byte floor.
  size=${#out_a}
  [ "$size" -ge 5000 ] || fail "branch prompt is only $size bytes - below the provider caching minimum"
  case "$out_a" in
    "You are the SUPERVISION BRANCH"*) ;;
    *) fail "branch prompt lost its role preamble" ;;
  esac
  case "$out_a" in
    *"stuck-crewmate-recovery"*) ;;
    *) fail "branch prompt lost the inlined recovery playbook" ;;
  esac
  case "$out_a" in
    *"Report verdict captain for the finished result of work the captain requested, even when that result is healthy."*"A start or still-working update on requested work that brings no new artifact, finding, or decision is verdict routine."*"Keep an unsolicited routine outcome as verdict routine"*"Keep an unchanged fleet review silent"*) ;;
    *) fail "branch prompt lost the requested-result, progress-routine, or routine-silence rules" ;;
  esac
  case "$out_a" in
    *"# PR identity: copy or abstain"*"copied verbatim from the task's \`done: PR <url>\` status line or its \`pr=\` metadata field"*"Never assemble an owner, repository, host, or number"*"report the identifier you do have"*) ;;
    *) fail "branch prompt lost the copy-or-abstain PR identity rule" ;;
  esac
  case "$out_a" in
    *"# Goal-directed acceptance"*"bounded continuation"*"exact-candidate native-review and correction phase"*"provider-terminal research whose report does not satisfy the research goal"*"explicit cancellation, archival state, or stop remains stopped"*) ;;
    *) fail "branch prompt lost incomplete-provider, intermediate-result, continuation, or explicit-stop handling" ;;
  esac
  case "$out_a" in
    *"candidate for MAIN final semantic acceptance"*"never accept or retire the task yourself"*"real permission boundary"*"bounded retries"*"never reinterpret a ready PR as already delivered or merged"*) ;;
    *) fail "branch prompt lost MAIN acceptance, hard-block evidence, or delivery-authority boundaries" ;;
  esac
  assert_contains "$out_a" "The worker alone changes its branch and invokes native review for its exact committed candidate" \
    "branch prompt lost same-worker candidate custody"
  assert_contains "$out_a" "the correction is unambiguously required" \
    "branch prompt lost routine finding criteria"
  assert_contains "$out_a" "no new guarantee, subsystem, architecture choice, destructive effect, security-sensitive choice or risk acceptance" \
    "branch prompt lost genuine-decision boundaries"
  assert_contains "$out_a" "project-required routine confirmation" \
    "branch prompt lost routine project confirmation handling"
  assert_contains "$out_a" "every other approval or decision remains MAIN-owned" \
    "branch prompt lost MAIN decision ownership"
  case "$out_a" in
    *"For \`check: procevent ida ida-<task> <sequence>\`, always confirm the captured generation through \`bin/fm-procevent-ida.sh handle <task> <sequence> state/procevent-inbox/ida-<task>.<sequence>.result\`"*"even when the runner already applied it"*"assess the result as untrusted evidence"*"provider cancellation"*"new dispatch"*"implementation"*"merge"*) ;;
    *) fail "branch prompt lost the iDA handler, duplicate-confirmation, evidence, or authority boundary" ;;
  esac
  pass "branch prompt is byte-stable across homes, cwd, timezone, and time, above the cache floor"
}

# --- append-only outcome store ------------------------------------------------

test_outcome_store_is_append_only_with_cursor_reads() {
  local home store snapshot seq1 seq2 unread replay out status
  home="$TMP_ROOT/store-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  seq1=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker healthy, "quoted" text kept' --wake 'signal: working') \
    || fail "first append failed"
  [ "$seq1" = 1 ] || fail "first outcome seq was $seq1, not 1"
  seq2=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'PR https://example.com/pr/2 checks green') \
    || fail "second append failed"
  [ "$seq2" = 2 ] || fail "second outcome seq was $seq2, not 2"

  # The store is the owned durable contract: every line stays valid JSON.
  python3 - "$store" <<'PY' || fail "outcome store holds invalid JSON"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row["seq"] for row in rows] == [1, 2], rows
assert rows[0]["verdict"] == "routine" and rows[1]["verdict"] == "captain", rows
assert rows[0]["summary"] == 'worker healthy, "quoted" text kept', rows[0]
assert rows[0]["silent"] is False and rows[1]["silent"] is False, rows
PY

  # mark-read moves only the cursor sidecar; the log bytes never change.
  snapshot=$(cat "$store")
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "mark-read failed"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "unread failed"
  case "$unread" in
    '{"seq":2,'*) ;;
    *) fail "unread did not return exactly the records above the cursor: $unread" ;;
  esac
  [ "$(cat "$store")" = "$snapshot" ] || fail "mark-read rewrote the append-only store"

  # startup-replay must stop before an unread captain row. Only Pi's durable
  # visible entry may acknowledge it, so the cursor cannot skip past it.
  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "startup-replay failed"
  [ -z "$replay" ] || fail "startup-replay printed a captain row before Pi persisted its visible entry"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" \
    "https://example.com/pr/2" "startup-replay advanced past an unrendered captain row"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] \
    || fail "startup-replay moved the cursor across the captain row"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 2 \
    || fail "synthetic Pi acknowledgement failed"

  # Later appends land strictly after the earlier bytes (append-only merge).
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict routine --summary 'later outcome' >/dev/null || fail "third append failed"
  case "$(cat "$store")" in
    "$snapshot"*) ;;
    *) fail "a later append disturbed earlier store bytes" ;;
  esac

  printf '{"seq":4,"epoch":' >> "$store"
  snapshot=$(cat "$store")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-5 --verdict captain --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a malformed outcome-store tail"
  assert_contains "$out" "malformed or non-sequential" "torn-tail refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed append changed the torn outcome store"
  pass "outcome store is append-only and refuses sequence reuse after a torn tail"
}

test_outcome_startup_replay_preserves_silence() {
  local home replay out status store
  home="$TMP_ROOT/store-silent-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict captain --summary 'blocked' --silent true 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a silent captain outcome"
  assert_contains "$out" "silent outcomes must be routine fleet outcomes" "silent captain refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-a --verdict routine --summary 'healthy' --silent true 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a silent task-scoped outcome"
  assert_contains "$out" "silent outcomes must be routine fleet outcomes" "silent task refusal lost its diagnostic"
  [ ! -e "$store" ] || fail "refused silent outcomes changed the durable store"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task fleet --verdict routine --summary 'fleet reviewed, nothing changed' --silent true >/dev/null \
    || fail "silent outcome append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker recovered automatically' >/dev/null \
    || fail "visible outcome append failed"

  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "mixed startup replay failed"
  assert_not_contains "$replay" "fleet reviewed, nothing changed" "startup replay printed a silent outcome"
  assert_contains "$replay" "worker recovered automatically" "startup replay lost a visible routine outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" ] \
    || fail "startup replay did not mark the silent and visible rows read"

  printf '%s\n' '{"seq":3,"epoch":1,"task":"task-legacy","wake":"","verdict":"routine","summary":"legacy visible outcome"}' \
    >> "$home/state/branch-outcomes.jsonl"
  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "legacy startup replay failed"
  assert_contains "$replay" "legacy visible outcome" "startup replay hid a legacy row with no silent field"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" ] \
    || fail "startup replay did not mark the legacy row read"

  printf '%s\n' '{"seq":4,"epoch":1,"task":"task-bad","wake":"","verdict":"captain","summary":"poisoned","silent":true}' >> "$store"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread accepted a stored silent captain outcome"
  assert_contains "$out" "malformed or non-sequential" "stored silent captain refusal lost its diagnostic"
  pass "only routine fleet outcomes can be silent"
}

test_outcome_startup_replay_stops_at_captain_barrier() {
  local home replay unread
  home="$TMP_ROOT/store-captain-barrier-home"
  mkdir -p "$home/state"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'leading routine' >/dev/null || fail "leading append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'captain must render in Pi' >/dev/null || fail "captain append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict routine --summary 'routine behind captain' >/dev/null || fail "trailing append failed"

  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "barrier replay failed"
  assert_contains "$replay" "leading routine" "startup replay lost the leading routine row"
  assert_not_contains "$replay" "captain must render in Pi" "startup replay rendered the captain row"
  assert_not_contains "$replay" "routine behind captain" "startup replay crossed the captain barrier"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "cursor crossed the captain barrier"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "barrier unread failed"
  assert_contains "$unread" '"seq":2' "captain row did not remain unread"
  assert_contains "$unread" '"seq":3' "row behind captain did not remain unread"
  pass "startup replay cannot advance the cursor across an unrendered captain outcome"
}

test_outcome_cursor_corruption_fails_closed() {
  local home store snapshot out status
  home="$TMP_ROOT/store-corrupt-cursor-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict captain --summary 'captain outcome must remain unread' >/dev/null \
    || fail "captain outcome append failed"
  snapshot=$(cat "$store")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 01 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-read accepted a noncanonical sequence"
  [ ! -e "$home/state/.branch-outcomes-cursor" ] || fail "noncanonical mark-read created a malformed cursor"

  printf '1x2\n' > "$home/state/.branch-outcomes-cursor"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread accepted a malformed cursor and skipped an outcome"
  assert_contains "$out" "outcome cursor is malformed" "malformed cursor refusal lost its diagnostic"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1x2 ] || fail "failed unread rewrote the malformed cursor"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed unread changed the append-only outcome store"

  printf '999999999999999999999999999999999\n' > "$home/state/.branch-outcomes-cursor"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread accepted an out-of-range cursor"
  assert_contains "$out" "outcome cursor is out of range" "out-of-range cursor refusal lost its diagnostic"

  printf '2\n' > "$home/state/.branch-outcomes-cursor"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread accepted a cursor beyond the outcome-store tail"
  assert_contains "$out" "cursor is ahead of the store" "ahead-of-store refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-read accepted an existing cursor beyond the store"
  assert_contains "$out" "cursor is ahead of the store" "mark-read ahead-cursor refusal lost its diagnostic"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 2 ] || fail "refused mark-read changed the ahead cursor"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'must not remain hidden behind the cursor' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a cursor beyond the outcome-store tail"
  assert_contains "$out" "cursor is invalid or ahead of the store" "append cursor refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed append changed the store behind an invalid cursor"
  pass "malformed and ahead-of-store cursor state fail closed before any outcome can be skipped"
}

test_cursor_advancement_refuses_ahead_processed_marker() {
  local home cursor marker out status
  home="$TMP_ROOT/store-ahead-processed-home"
  mkdir -p "$home/state"
  cursor="$home/state/.branch-outcomes-cursor"
  marker="$home/state/.branch-outcomes-processed"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'already read' >/dev/null || fail "first routine append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict routine --summary 'replayable second' >/dev/null || fail "second routine append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict routine --summary 'replayable third' >/dev/null || fail "third routine append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "fixture mark-read failed"
  printf '3\n' > "$marker"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-read legitimized an ahead processed marker"
  assert_contains "$out" "processed marker is ahead of the read cursor" "mark-read ahead-marker refusal lost its diagnostic"
  [ "$(cat "$cursor")" = 1 ] || fail "refused mark-read advanced the cursor"
  [ "$(cat "$marker")" = 3 ] || fail "refused mark-read changed the processed marker"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "startup replay legitimized an ahead processed marker"
  assert_contains "$out" "processed marker is ahead of the read cursor" "startup replay ahead-marker refusal lost its diagnostic"
  [ "$(cat "$cursor")" = 1 ] || fail "refused startup replay advanced the cursor"
  [ "$(cat "$marker")" = 3 ] || fail "refused startup replay changed the processed marker"
  pass "cursor advancement refuses to legitimize an ahead processed marker"
}

test_outcome_sequence_conflicts_fail_closed() {
  local home store snapshot out status
  home="$TMP_ROOT/store-sequence-conflict-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"
  printf '%s\n' \
    '{"seq":1,"epoch":1,"task":"task-1","wake":"","verdict":"routine","summary":"first","silent":false}' \
    '{"seq":1,"epoch":2,"task":"task-conflict","wake":"","verdict":"captain","summary":"conflict","silent":false}' \
    '{"seq":3,"epoch":3,"task":"task-3","wake":"","verdict":"routine","summary":"third","silent":false}' \
    > "$store"
  snapshot=$(cat "$store")

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread skipped over a conflicting middle sequence"
  assert_contains "$out" "malformed or non-sequential" "sequence-conflict read refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-4 --verdict routine --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append continued after a conflicting middle sequence"
  assert_contains "$out" "malformed or non-sequential" "sequence-conflict append refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 2 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "list exposed rows from a conflicting outcome store"
  assert_contains "$out" "malformed or non-sequential" "sequence-conflict list refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "sequence-conflict refusal changed the durable store"
  pass "middle sequence conflicts fail closed for every store read and append"
}

test_outcome_recent_window_boundaries() {
  local count home store out lines first last expected
  for count in 0 199 200 201; do
    home="$TMP_ROOT/store-recent-$count"
    mkdir -p "$home/state"
    store="$home/state/branch-outcomes.jsonl"
    if [ "$count" -gt 0 ]; then
      awk -v count="$count" 'BEGIN {
        for (seq = 1; seq <= count; seq++) {
          printf "{\"seq\":%d,\"epoch\":%d,\"task\":\"task-%d\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"row-%d\",\"silent\":false}\n", seq, seq, seq, seq
        }
      }' > "$store"
    fi
    out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 200) \
      || fail "recent-window read failed at history size $count"
    lines=$(printf '%s\n' "$out" | awk 'NF { n++ } END { print n + 0 }')
    expected=$count
    [ "$expected" -le 200 ] || expected=200
    [ "$lines" -eq "$expected" ] \
      || fail "recent-window history size $count returned $lines rows, expected $expected"
    if [ "$count" -gt 0 ]; then
      first=$(printf '%s\n' "$out" | head -n 1 | jq -r .seq)
      last=$(printf '%s\n' "$out" | tail -n 1 | jq -r .seq)
      [ "$first" -eq "$((count - expected + 1))" ] \
        || fail "recent-window history size $count began at seq $first"
      [ "$last" -eq "$count" ] || fail "recent-window history size $count ended at seq $last"
    fi
  done
  pass "recent outcome reads cover empty, below-window, exact-window, and above-window histories"
}

test_outcome_non_jsonl_layout_fails_closed() {
  local home store snapshot out status
  home="$TMP_ROOT/store-physical-layout-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"
  printf '%s\n' \
    '{' \
    '  "seq": 1, "epoch": 1, "task": "task-1", "wake": "",' \
    '  "verdict": "routine", "summary": "pretty printed", "silent": false' \
    '}' > "$store"
  snapshot=$(cat "$store")

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "list accepted a multi-line outcome record"
  assert_contains "$out" "malformed or non-sequential" "multi-line record refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict routine --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append extended a store containing a multi-line record"
  [ "$(cat "$store")" = "$snapshot" ] || fail "multi-line layout refusal changed the durable store"

  printf '%s\n' \
    '{"seq":1,"epoch":1,"task":"task-1","wake":"","verdict":"routine","summary":"first","silent":false}' \
    '' \
    '{"seq":2,"epoch":2,"task":"task-2","wake":"","verdict":"captain","summary":"second","silent":false}' \
    > "$store"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unread accepted a blank physical record"
  assert_contains "$out" "malformed or non-sequential" "blank-record refusal lost its diagnostic"

  printf '%s' '{"seq":1,"epoch":1,"task":"task-1","wake":"","verdict":"routine","summary":"unterminated","silent":false}' > "$store"
  snapshot=$(cat "$store")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted an unterminated outcome store"
  assert_contains "$out" "malformed or non-sequential" "unterminated-store refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed append changed the unterminated store"
  pass "outcome stores require terminated single-line JSON records"
}

test_outcome_processed_marker_is_sequence_bound() {
  local home marker out status
  home="$TMP_ROOT/store-processed-home"
  mkdir -p "$home/state"
  marker="$home/state/.branch-outcomes-processed"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'routine first' >/dev/null || fail "routine append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'captain second' >/dev/null || fail "captain append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict captain --summary 'captain third' >/dev/null || fail "second captain append failed"

  # Nothing is unprocessed until it has been read (its visible entry exists).
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "an unread captain row was reported as unprocessed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 2 || fail "mark-read failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed) || fail "unprocessed failed"
  case "$out" in
    '{"seq":2,'*) ;;
    *) fail "unprocessed did not return exactly the read captain rows: $out" ;;
  esac
  assert_not_contains "$out" '"seq":1' "a routine row entered the processing path"

  # The marker advances only to a read, currently unprocessed captain row.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-processed advanced past the read cursor"
  assert_contains "$out" "beyond the read cursor" "past-cursor refusal lost its diagnostic"
  [ ! -e "$marker" ] || fail "a refused acknowledgement created the processed marker"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-processed accepted a routine sequence"
  assert_contains "$out" "not an unprocessed captain outcome" "routine-sequence refusal lost its diagnostic"
  [ ! -e "$marker" ] || fail "a routine-sequence acknowledgement created the processed marker"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 || fail "mark-processed failed"
  [ "$(cat "$marker")" = 2 ] || fail "processed marker was not written"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "an acknowledged row stayed unprocessed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mark-processed accepted an already-processed sequence"
  assert_contains "$out" "already processed" "already-processed refusal lost its diagnostic"
  [ "$(cat "$marker")" = 2 ] || fail "refused backwards acknowledgement moved the processed marker"

  # Reading the next captain row reopens exactly that row for processing.
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 3 || fail "second mark-read failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed) || fail "second unprocessed failed"
  case "$out" in
    '{"seq":3,'*) ;;
    *) fail "the newly read captain row was not the only unprocessed row: $out" ;;
  esac

  # processed-init leaves a present marker alone and fails closed on a
  # malformed one instead of skipping an outcome.
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init || fail "processed-init failed on a present marker"
  [ "$(cat "$marker")" = 2 ] || fail "processed-init rewrote a present marker"
  printf '2x\n' > "$marker"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unprocessed accepted a malformed processed marker"
  assert_contains "$out" "processed marker is malformed" "malformed marker refusal lost its diagnostic"
  printf '5\n' > "$marker"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unprocessed accepted a marker ahead of the read cursor"
  assert_contains "$out" "ahead of the read cursor" "ahead-of-cursor refusal lost its diagnostic"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "processed-init accepted a marker ahead of the read cursor"
  assert_contains "$out" "ahead of the read cursor" "processed-init ahead-marker refusal lost its diagnostic"
  [ "$(cat "$marker")" = 5 ] || fail "refused processed-init rewrote the ahead marker"
  printf '999999999999999999999999999999999\n' > "$marker"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unprocessed accepted an out-of-range processed marker"
  assert_contains "$out" "processed marker is out of range" "out-of-range marker refusal lost its diagnostic"
  [ "$(cat "$marker")" = 999999999999999999999999999999999 ] \
    || fail "out-of-range marker refusal changed the marker"

  # Migration: a home with delivered history and no marker starts processed
  # at its read cursor, so that history is not re-presented; an absent marker
  # otherwise reads as zero, the safe direction.
  home="$TMP_ROOT/store-processed-migration-home"
  mkdir -p "$home/state"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-old --verdict captain --summary 'delivered before the marker existed' >/dev/null || fail "migration append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "migration mark-read failed"
  assert_contains "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" '"seq":1' \
    "an absent marker hid a delivered captain row instead of reading as zero"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init || fail "migration processed-init failed"
  [ "$(cat "$home/state/.branch-outcomes-processed")" = 1 ] || fail "processed-init did not start at the read cursor"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)" ] \
    || fail "migrated history was re-presented for processing"
  pass "the processed marker is sequence-bound, never ahead of the read cursor, never backwards, and migrates delivered history once"
}

test_outcome_index_migration_preserves_legacy_endpoint_records() {
  local home store before unread unprocessed
  home="$TMP_ROOT/store-legacy-endpoints"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"
  cat > "$store" <<'JSON'
{"seq":1,"epoch":1,"task":"default:w90:p2","wake":"signal: old endpoint","verdict":"captain","summary":"legacy captain result"}
{"seq":2,"epoch":2,"task":"../../outside","wake":"signal: old label","verdict":"routine","summary":"history is data, never a cache path"}
{"seq":3,"epoch":3,"task":"old-label\n","wake":"signal: old label","verdict":"routine","summary":"non-filename history"}
{"seq":4,"epoch":4,"task":"current-task","wake":"signal: current task","verdict":"routine","summary":"indexable task"}
JSON
  printf '1\n' > "$home/state/.branch-outcomes-cursor"
  printf '0\n' > "$home/state/.branch-outcomes-processed"
  before=$(cat "$store")
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init || fail "legacy endpoint broke outcome migration"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init || fail "legacy endpoint broke repeated migration"
  [ "$(cat "$store")" = "$before" ] || fail "migration rewrote authoritative history"
  [ "$(cat "$home/state/.branch-outcomes-cursor")" = 1 ] || fail "migration moved the read cursor"
  [ "$(cat "$home/state/.branch-outcomes-processed")" = 0 ] || fail "migration acknowledged a captain result"
  [ "$(cat "$home/state/.branch-outcome-index-ready")" = 4 ] || fail "migration did not publish cache readiness"
  [ -f "$home/state/.current-task.branch-outcome-index" ] || fail "migration omitted the valid task cache"
  [ ! -e "$home/state/.default:w90:p2.branch-outcome-index" ] || fail "migration indexed a legacy endpoint"
  [ "$(find "$TMP_ROOT" -name '*outside.branch-outcome-index' | wc -l | tr -d ' ')" = 0 ] || fail "history escaped the cache directory"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "legacy unread records became unreadable"
  [ "$(printf '%s\n' "$unread" | jq -s length)" = 3 ] || fail "migration lost unread outcomes"
  unprocessed=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed) || fail "legacy captain result became unreadable"
  [ "$(printf '%s\n' "$unprocessed" | jq -r '.task')" = 'default:w90:p2' ] || fail "migration lost the unprocessed captain result"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task 'default:w90:p2' --verdict routine --summary invalid >/dev/null 2>&1 \
    && fail "migration relaxed new task identity validation"
  [ "$(cat "$store")" = "$before" ] || fail "refused append changed history"
  pass "outcome cache migration preserves legacy endpoint history and captain acknowledgements without using labels as paths"
}

seed_outcome_history() { # <home> <rows>
  local home=$1 rows=$2 seq verdict task
  mkdir -p "$home/state"
  : > "$home/state/branch-outcomes.jsonl"
  seq=1
  while [ "$seq" -le "$rows" ]; do
    verdict=routine
    task="task-$seq"
    case "$seq" in 100|105|112|128) verdict=captain ;; esac
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"fixture","verdict":"%s","summary":"summary-%s","silent":false}\n' \
      "$seq" "$seq" "$task" "$verdict" "$seq" >> "$home/state/branch-outcomes.jsonl"
    seq=$((seq + 1))
  done
}

test_outcome_retention_keeps_64_processed_and_all_pending_rows() {
  local empty short exact full active cold unread unprocessed appended out status original_first plan
  empty="$TMP_ROOT/store-retention-empty"
  short="$TMP_ROOT/store-retention-short"
  exact="$TMP_ROOT/store-retention-exact"
  full="$TMP_ROOT/store-retention-full"
  mkdir -p "$empty/state"
  FM_HOME="$empty" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null \
    || fail "empty retention apply failed"
  [ ! -e "$empty/state/.branch-outcomes-base" ] || fail "empty retention invented a base"

  seed_outcome_history "$short" 63
  printf '63\n' > "$short/state/.branch-outcomes-cursor"
  printf '63\n' > "$short/state/.branch-outcomes-processed"
  FM_HOME="$short" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null \
    || fail "short retention apply failed"
  [ "$(wc -l < "$short/state/branch-outcomes.jsonl" | tr -d ' ')" = 63 ] \
    || fail "fewer than 64 processed rows were compacted"

  seed_outcome_history "$exact" 64
  printf '64\n' > "$exact/state/.branch-outcomes-cursor"
  printf '64\n' > "$exact/state/.branch-outcomes-processed"
  FM_HOME="$exact" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null \
    || fail "exact-window retention apply failed"
  [ "$(wc -l < "$exact/state/branch-outcomes.jsonl" | tr -d ' ')" = 64 ] \
    || fail "exactly 64 processed rows changed"

  seed_outcome_history "$full" 128
  sed '1s/^/  /; 1s/$/  /' "$full/state/branch-outcomes.jsonl" > "$full/state/branch-outcomes.spaced"
  mv "$full/state/branch-outcomes.spaced" "$full/state/branch-outcomes.jsonl"
  original_first=$(head -n 1 "$full/state/branch-outcomes.jsonl")
  printf '112\n' > "$full/state/.branch-outcomes-cursor"
  printf '100\n' > "$full/state/.branch-outcomes-processed"
  plan=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" compact --dry-run) \
    || fail "retention dry-run failed"
  [ "$(printf '%s\n' "$plan" | jq -c '[.base,.tail,.processed,.retain_processed,.archive_through,.move_rows,.active_rows_after]')" = \
    '[1,128,100,64,36,36,92]' ] || fail "retention dry-run returned the wrong boundary: $plan"
  [ "$(wc -l < "$full/state/branch-outcomes.jsonl" | tr -d ' ')" = 128 ] \
    || fail "retention dry-run changed the active store"
  FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null \
    || fail "retention apply failed"
  active=$(wc -l < "$full/state/branch-outcomes.jsonl" | tr -d ' ')
  cold=$(wc -l < "$full/state/branch-outcomes-cold.jsonl" | tr -d ' ')
  [ "$active" = 92 ] || fail "active store has $active rows, not 64 processed plus 28 pending"
  [ "$cold" = 36 ] || fail "cold store has $cold rows, not the moved processed prefix"
  [ "$(cat "$full/state/.branch-outcomes-base")" = $'fm-branch-outcomes-base-v1\t37' ] \
    || fail "active base does not name retained frontier window"
  [ "$(head -n 1 "$full/state/branch-outcomes.jsonl" | jq -r .seq)" = 37 ] \
    || fail "frontier-inclusive window did not retain seq 37"
  [ "$(tail -n 1 "$full/state/branch-outcomes-cold.jsonl" | jq -r .seq)" = 36 ] \
    || fail "cold prefix did not end immediately before the active base"
  [ "$(head -n 1 "$full/state/branch-outcomes-cold.jsonl")" = "$original_first" ] \
    || fail "cold storage reserialized immutable outcome bytes"

  unread=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "retained unread read failed"
  [ "$(printf '%s\n' "$unread" | jq -sc 'map(.seq)')" = '[113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,128]' ] \
    || fail "compaction lost or reordered unread rows"
  unprocessed=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" unprocessed) || fail "retained unprocessed read failed"
  [ "$(printf '%s\n' "$unprocessed" | jq -sc 'map(.seq)')" = '[105,112]' ] \
    || fail "compaction lost exact unprocessed membership: $unprocessed"
  [ "$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" list --seq 1 | jq -r .summary)" = summary-1 ] \
    || fail "exact cold lookup lost the first immutable row"
  [ "$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" list --seq 37 | jq -r .summary)" = summary-37 ] \
    || fail "exact active lookup lost the base row"
  out=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" list --seq 130 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "exact lookup accepted a sequence beyond the durable tail"
  assert_contains "$out" "exact outcome sequence 130 does not exist" "missing exact lookup lost its identity refusal"
  [ "$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" list --all | jq -s '.[-1].seq')" = 128 ] \
    || fail "explicit full history did not join cold and active rows"

  appended=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-129 --verdict routine --summary summary-129) || fail "post-compaction append failed"
  [ "$appended" = 129 ] || fail "post-compaction append renumbered the stable sequence"
  [ "$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" append --once-task \
    --task task-1 --verdict routine --summary summary-1 --wake fixture)" = 1 ] \
    || fail "once-task did not find exact cold identity"
  out=$(FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" append --once-task \
    --task task-1 --verdict routine --summary changed --wake fixture 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "once-task accepted conflicting cold identity"
  assert_contains "$out" "conflicting once-task outcome" "cold identity refusal lost its diagnostic"

  rm -f "$full/state/.branch-outcome-index-ready" "$full/state/.task-1.branch-outcome-index"
  FM_HOME="$full" "$ROOT/bin/fm-branch-outcome.sh" processed-init || fail "cold index rebuild failed"
  [ -f "$full/state/.task-1.branch-outcome-index" ] || fail "index rebuild omitted cold-only task provenance"
  pass "retention keeps exactly 64 processed rows plus every unread and unprocessed row with stable cold lookup"
}

test_outcome_compaction_serializes_and_recovers_publication() {
  local home crash ack cold_copy journal_bad mode pid out real_cat seq shim_dir status unprocessed
  home="$TMP_ROOT/store-retention-concurrent"
  seed_outcome_history "$home" 128
  printf '100\n' > "$home/state/.branch-outcomes-cursor"
  printf '100\n' > "$home/state/.branch-outcomes-processed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null &
  pid=$!
  for seq in 129 130 131 132; do
    FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
      --task "task-$seq" --verdict routine --summary "summary-$seq" >/dev/null &
  done
  wait "$pid" || fail "concurrent compaction failed"
  wait || fail "an append racing compaction failed"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --all | jq -sc '[length,.[0].seq,.[-1].seq]')" = '[132,1,132]' ] \
    || fail "compaction and append did not serialize to one continuous history"

  for mode in after-cold after-active after-base after-processed; do
    crash="$TMP_ROOT/store-retention-$mode"
    seed_outcome_history "$crash" 128
    printf '112\n' > "$crash/state/.branch-outcomes-cursor"
    printf '100\n' > "$crash/state/.branch-outcomes-processed"
    out=$(FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT="$mode" FM_HOME="$crash" \
      "$ROOT/bin/fm-branch-outcome.sh" compact --apply 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode interruption unexpectedly completed: $out"
    [ -e "$crash/state/.branch-outcomes-compaction" ] || fail "$mode interruption lost its recovery journal"
    [ "$(FM_HOME="$crash" "$ROOT/bin/fm-branch-outcome.sh" list --all | jq -sc '[length,.[0].seq,.[-1].seq]')" = '[128,1,128]' ] \
      || fail "$mode recovery did not restore complete history"
    [ ! -e "$crash/state/.branch-outcomes-compaction" ] || fail "$mode recovery left its journal active"
  done

  ack="$TMP_ROOT/store-retention-ack-transaction"
  seed_outcome_history "$ack" 128
  printf '100\n' > "$ack/state/.branch-outcomes-cursor"
  printf '99\n' > "$ack/state/.branch-outcomes-processed"
  out=$(FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT=after-cold FM_HOME="$ack" \
    "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 100 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "interrupted acknowledgement unexpectedly completed: $out"
  [ "$(cat "$ack/state/.branch-outcomes-processed")" = 99 ] \
    || fail "interrupted acknowledgement advanced the marker outside its recovery journal"
  [ -e "$ack/state/.branch-outcomes-compaction" ] \
    || fail "interrupted acknowledgement lost its recovery journal"
  unprocessed=$(FM_HOME="$ack" "$ROOT/bin/fm-branch-outcome.sh" unprocessed) \
    || fail "ordinary read did not recover the acknowledged compaction"
  [ -z "$unprocessed" ] || fail "recovered acknowledgement left seq 100 unprocessed: $unprocessed"
  [ "$(cat "$ack/state/.branch-outcomes-processed")" = 100 ] \
    || fail "recovered acknowledgement did not publish its exact marker"
  [ "$(head -n 1 "$ack/state/branch-outcomes.jsonl" | jq -r .seq)" = 37 ] \
    || fail "recovered acknowledgement did not retain the frontier-inclusive window"

  FM_HOME="$ack" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-129 --verdict captain --summary summary-129 >/dev/null \
    || fail "failed-compaction acknowledgement fixture append failed"
  FM_HOME="$ack" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 129 \
    || fail "failed-compaction acknowledgement fixture read failed"
  cold_copy="$ack/cold-before-copy-failure.jsonl"
  cp "$ack/state/branch-outcomes-cold.jsonl" "$cold_copy"
  shim_dir="$ack/failing-copy-bin"
  mkdir -p "$shim_dir"
  real_cat=$(command -v cat)
  printf '%s\n' '#!/bin/sh' \
    "case \"\${1:-}\" in */branch-outcomes-cold.jsonl) exit 74 ;; esac" \
    "exec '$real_cat' \"\$@\"" > "$shim_dir/cat"
  chmod +x "$shim_dir/cat"
  out=$(PATH="$shim_dir:$PATH" FM_HOME="$ack" \
    "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 129 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "acknowledgement ignored a cold-evidence copy failure"
  [ "$(cat "$ack/state/.branch-outcomes-processed")" = 100 ] \
    || fail "cold-copy failure advanced the acknowledgement before journal publication"
  cmp -s "$ack/state/branch-outcomes-cold.jsonl" "$cold_copy" \
    || fail "cold-copy failure changed historical evidence"
  [ ! -e "$ack/state/.branch-outcomes-compaction" ] \
    || fail "cold-copy failure published a compaction journal"

  sed '1s/"seq":1/"seq":2/' "$ack/state/branch-outcomes-cold.jsonl" > "$ack/state/cold.bad"
  mv "$ack/state/cold.bad" "$ack/state/branch-outcomes-cold.jsonl"
  out=$(FM_HOME="$ack" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 129 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "acknowledgement accepted malformed cold evidence"
  [ "$(cat "$ack/state/.branch-outcomes-processed")" = 100 ] \
    || fail "failed compaction advanced the acknowledgement before journal publication"
  [ ! -e "$ack/state/.branch-outcomes-compaction" ] \
    || fail "preparation failure published a compaction journal"

  journal_bad="$TMP_ROOT/store-retention-journal-trailing"
  seed_outcome_history "$journal_bad" 128
  printf '112\n' > "$journal_bad/state/.branch-outcomes-cursor"
  printf '100\n' > "$journal_bad/state/.branch-outcomes-processed"
  FM_BRANCH_OUTCOME_TEST_COMPACTION_INTERRUPT=after-cold FM_HOME="$journal_bad" \
    "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null 2>&1 || true
  printf 'trailing-record\n' >> "$journal_bad/state/.branch-outcomes-compaction"
  out=$(FM_HOME="$journal_bad" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "recovery accepted a trailing compaction-journal record"
  assert_contains "$out" "compaction journal is malformed" \
    "trailing-journal refusal lost its diagnostic"

  pass "compaction and acknowledgement serialize with appends and recover or refuse every publication boundary"
}

test_outcome_retention_refuses_identity_damage_without_loading_cold_normally() {
  local home malformed_base out status
  home="$TMP_ROOT/store-retention-corrupt"
  seed_outcome_history "$home" 128
  printf '112\n' > "$home/state/.branch-outcomes-cursor"
  printf '100\n' > "$home/state/.branch-outcomes-processed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null || fail "corruption fixture compaction failed"

  sed '1s/"seq":1/"seq":2/' "$home/state/branch-outcomes-cold.jsonl" > "$home/state/cold.bad"
  mv "$home/state/cold.bad" "$home/state/branch-outcomes-cold.jsonl"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 64 >/dev/null \
    || fail "ordinary retained-window read unnecessarily parsed cold evidence"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --seq 37 | jq -r .summary)" = summary-37 ] \
    || fail "exact active lookup unnecessarily parsed malformed cold evidence"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --seq 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "exact lookup accepted malformed cold evidence"
  assert_contains "$out" "cold outcome evidence is malformed" "cold refusal lost its diagnostic"

  sed '1s/"seq":37/"seq":38/' "$home/state/branch-outcomes.jsonl" > "$home/state/active.bad"
  mv "$home/state/active.bad" "$home/state/branch-outcomes.jsonl"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "ordinary read accepted an active sequence gap"
  assert_contains "$out" "malformed or non-sequential" "active-gap refusal lost its diagnostic"

  home="$TMP_ROOT/store-retention-behind-base"
  seed_outcome_history "$home" 128
  printf '112\n' > "$home/state/.branch-outcomes-cursor"
  printf '100\n' > "$home/state/.branch-outcomes-processed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" compact --apply >/dev/null \
    || fail "behind-base fixture compaction failed"
  printf '1\n' > "$home/state/.branch-outcomes-processed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unprocessed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unprocessed accepted a marker behind the archived prefix"
  assert_contains "$out" "behind the archived prefix" "behind-base refusal lost its diagnostic"
  printf '128\n' > "$home/state/.branch-outcome-index-ready"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" processed-init 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "processed-init ready shortcut accepted a marker behind the archived prefix"
  assert_contains "$out" "behind the archived prefix" \
    "processed-init behind-base refusal lost its diagnostic"

  malformed_base="$TMP_ROOT/store-retention-malformed-base"
  seed_outcome_history "$malformed_base" 4
  for invalid_base in not-a-sequence 0; do
    printf 'fm-branch-outcomes-base-v1\t%s\n' "$invalid_base" > "$malformed_base/state/.branch-outcomes-base"
    out=$(FM_HOME="$malformed_base" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "ordinary read accepted malformed active base $invalid_base"
    assert_contains "$out" "outcome base is malformed" "malformed-base refusal lost its diagnostic"
  done
  printf 'fm-branch-outcomes-base-v1\t1\ntrailing-record\n' > "$malformed_base/state/.branch-outcomes-base"
  out=$(FM_HOME="$malformed_base" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "ordinary read accepted a trailing outcome-base record"
  assert_contains "$out" "outcome base is malformed" "trailing-base refusal lost its diagnostic"
  pass "active gaps, cold corruption, and behind-base cursors fail closed while normal reads stay on the active store"
}

# --- lease contract -----------------------------------------------------------

test_lease_exclusivity_release_stale_and_sweep() {
  local home out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/lease-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"

  # Claim, exclusivity, same-actor refresh.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch \
    || fail "branch claim failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1) || fail "check missed a held lease"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "check misreported the lease: $out" ;;
  esac
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not the lease refusal 6"
  assert_contains "$out" "leased to the branch supervision actor" "refusal did not name the holder"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 \
    || fail "same-actor refresh was refused"

  # Release by the calling holder; release of an unheld lease stays a silent no-op.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "release failed"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1 >/dev/null && fail "released lease still reported"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "idempotent release failed"

  # A lease held by a dead process is stale: claimable by the other actor and
  # removed by the sweep, while a live lease survives the sweep.
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-dead \
    || fail "stale lease blocked a live claim"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-dead)
  case "$out" in "main $$ "*) ;; *) fail "stale lease was not taken over: $out" ;; esac
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead2"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-dead2" ] || fail "sweep left a provably stale lease"
  [ -e "$home/state/.lease-task-dead" ] || fail "sweep removed a live lease"

  # The reserved backlog resource claims like any task.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog --actor branch \
    || fail "backlog lease claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog 2>&1)
  [ $? -eq 6 ] || fail "backlog lease did not enforce exclusivity"
  pass "lease exclusivity, same-actor refresh, release, staleness, and sweep hold"
}

# --- guards in the mutating entrypoints ---------------------------------------

test_mutating_scripts_refuse_the_other_actors_lease() {
  local home root out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/guard-home"
  root="$TMP_ROOT/guard-root"
  mkdir -p "$home/state" "$root"
  printf '%s\n' "$$" > "$home/state/.lock"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor branch \
    || fail "fixture lease claim failed"

  # fm-control: refused while the branch holds the lease; the ordinary no-task
  # error (a different failure) proves pass-through once the lease is gone.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-control exited $status, not 6: $out"
  assert_contains "$out" "leased to the branch supervision actor" "fm-control refusal lost the holder"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-unheld interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "unleased fm-control still hit the lease refusal"
  assert_contains "$out" "no task 'task-unheld'" "unleased fm-control lost its ordinary error"

  # fm-teardown: same refusal shape before any teardown work.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-held 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-teardown exited $status, not 6: $out"
  assert_contains "$out" "teardown (fm-teardown) refused" "fm-teardown refusal lost its action label"

  # The same lease refuses the BRANCH actor when MAIN holds it - the guard is
  # symmetric, not a branch-only fence.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-held --actor branch
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor main \
    || fail "main fixture claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch actor bypassed main's lease: $status: $out"
  assert_contains "$out" "leased to the main supervision actor" "symmetric refusal lost the holder"
  pass "fm-control and fm-teardown refuse the other actor's live lease and pass through otherwise"
}

test_main_owned_actions_refuse_the_branch_actor() {
  local home root out status
  home="$TMP_ROOT/partition-home"
  root="$TMP_ROOT/partition-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-pr-merge.sh" task-x https://github.com/o/r/pull/1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-pr-merge exited $status, not 6: $out"
  assert_contains "$out" "the supervision branch never performs this action" "pr-merge refusal lost the partition wording"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-merge-local exited $status, not 6: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-new --mode review-PR --yolo off 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-spawn exited $status, not 6: $out"
  assert_contains "$out" "new-task spawn (fm-spawn) refused" "spawn refusal lost its action label"

  # The same calls as MAIN fail on their ORDINARY validation instead - the
  # partition guard never fires for the main actor.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "main fm-merge-local hit the partition refusal"
  assert_contains "$out" "no meta for task task-x" "main fm-merge-local lost its ordinary error"
  pass "PR merge, local landing, and new-task spawn refuse the branch actor and spare main"
}

test_home_without_branch_is_untouched() {
  local home out status
  home="$TMP_ROOT/untouched-home"
  mkdir -p "$home/state"

  # No lease files, no actor variable: the guard layer must be invisible - the
  # scripts fail (or succeed) exactly on their pre-existing logic, and nothing
  # branch-related appears in state/.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-any interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "no-branch home hit a lease refusal in fm-control"
  assert_contains "$out" "no task 'task-any'" "no-branch fm-control lost its ordinary error"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-pr-merge.sh" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no-branch fm-pr-merge usage error changed: $status: $out"
  [ -z "$(find "$home/state" -name '.lease-*' -o -name 'branch-outcomes*' -o -name '.branch-*' 2>/dev/null)" ] \
    || fail "guard layer created branch state in a home that never ran the branch"

  # A stale Pi marker and recycled-but-live lease pid cannot activate leases in
  # a no-lock Claude home; the guard removes the leftover and passes silently.
  printf 'harness=pi\n' > "$home/state/fake.meta"
  printf '%s\n' "$PPID" > "$home/state/.pi-branch-extension-loaded"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  out=$(STATE="$home/state" bash -c '. "$1"; fm_lease_guard task-reused "probe"; fm_lease_forbid_branch "probe"; echo silent-pass' _ "$ROOT/bin/fm-lease-lib.sh" 2>&1)
  [ "$out" = "silent-pass" ] || fail "guard helpers honored a leftover Pi lease in a no-lock Claude home: $out"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "guard kept a leftover Pi lease without a session lock"

  printf '%s\n' "$PPID" > "$home/state/.lock"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  # The positional parameter belongs to the nested shell.
  # shellcheck disable=SC2016
  out=$(env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR CLAUDECODE=1 STATE="$home/state" bash -c '. "$1"; fm_lease_guard task-reused "probe"; echo silent-pass' _ "$ROOT/bin/fm-lease-lib.sh" 2>&1)
  [ "$out" = "silent-pass" ] || fail "guard helpers honored a reused-pid Pi lease in a Claude context: $out"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "Claude context kept a Pi lease whose old pid matched its current lock"
  pass "a non-Pi home ignores stale Pi leases even when the recycled pid owns its lock"
}

# --- session-bound staleness and the loud accidental-override guard ---------

test_lease_liveness_binds_to_the_session_lock() {
  local home out
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/lock-bound-home"
  mkdir -p "$home/state"

  # A lease recorded by a pid that is alive but is NOT the current session-lock
  # holder is stale: a Pi session exited and its pid was recycled, or a non-Pi
  # harness now owns this home. Either way the leftover lease must not bind.
  printf '%s\n' "$$" > "$home/state/.lock.other"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-reused) || fail "check missed the leftover lease"
  case "$out" in
    *" stale") ;;
    *) fail "an alive non-lock-holder pid read as live: $out" ;;
  esac
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "sweep kept a lease whose pid is not the lock holder"

  # The same pid IS live while the lock names it.
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-current --actor main \
    || fail "claim under the current lock holder failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-current)
  case "$out" in
    "main $$ "*" live") ;;
    *) fail "the current lock holder's lease did not read live: $out" ;;
  esac

  printf '%sjunk\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-current) || fail "check missed the lease under a malformed lock"
  case "$out" in
    *" stale") ;;
    *) fail "a malformed lock proved lease liveness: $out" ;;
  esac
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep under malformed lock failed"
  [ ! -e "$home/state/.lease-task-current" ] || fail "sweep kept a lease proven only by a malformed lock"
  pass "lease liveness requires an exact valid session-lock pid"
}

test_concurrent_stale_lease_claims_have_one_winner() {
  local home fakebin real_mv branch_pid main_pid branch_status main_status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/concurrent-lease-home"
  fakebin="$TMP_ROOT/concurrent-lease-bin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-race"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_LEASE_PATH" ] && mkdir "$FM_TEST_GATE.once" 2>/dev/null; then
  : > "$FM_TEST_GATE.ready"
  while [ ! -e "$FM_TEST_GATE.release" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_LEASE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  branch_pid=$!
  while [ ! -e "$home/state/gate.ready" ]; do sleep 0.01; done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_LEASE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor main >/dev/null 2>&1 &
  main_pid=$!
  sleep 0.1
  : > "$home/state/gate.release"
  wait "$branch_pid"; branch_status=$?
  wait "$main_pid"; main_status=$?
  [ "$branch_status" -eq 0 ] || fail "first serialized lease claim failed with $branch_status"
  [ "$main_status" -eq 6 ] || fail "concurrent lease claim also succeeded or returned $main_status"
  pass "concurrent stale-lease claims serialize so exactly one actor succeeds"
}

test_guard_stale_clear_cannot_delete_a_new_claim() {
  local home fakebin real_rm guard_pid claim_pid guard_status claim_status out
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/guard-claim-race-home"
  fakebin="$TMP_ROOT/guard-claim-race-bin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'main\t999999\t123\n' > "$home/state/.lease-task-race"
  real_rm=$(command -v rm)
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_STALE_PATH" ] && mkdir "$FM_TEST_GATE.once" 2>/dev/null; then
  : > "$FM_TEST_GATE.ready"
  while [ ! -e "$FM_TEST_GATE.release" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$fakebin/rm"

  PATH="$fakebin:$PATH" STATE="$home/state" FM_TEST_REAL_RM="$real_rm" \
    FM_TEST_STALE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    bash -c '. "$1"; fm_lease_guard task-race "probe"' _ "$ROOT/bin/fm-lease-lib.sh" &
  guard_pid=$!
  while [ ! -e "$home/state/gate.ready" ]; do sleep 0.01; done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_RM="$real_rm" FM_TEST_STALE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  claim_pid=$!
  sleep 0.1
  : > "$home/state/gate.release"
  wait "$guard_pid"; guard_status=$?
  wait "$claim_pid"; claim_status=$?
  [ "$guard_status" -eq 0 ] || fail "guard stale cleanup failed with $guard_status"
  [ "$claim_status" -eq 0 ] || fail "serialized claim failed with $claim_status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-race) || fail "guard deleted the newer lease claim"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "newer claim was not preserved as live: $out" ;;
  esac
  pass "guard stale cleanup cannot race with or delete a newer lease claim"
}

test_guard_holds_exclusivity_through_mutation() {
  local home operation_pid claim_pid claim_status
  home="$TMP_ROOT/guard-mutation-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"

  PI_CODING_AGENT=true STATE="$home/state" FM_TEST_READY="$home/operation-ready" \
    FM_TEST_RELEASE="$home/operation-release" bash -c '
      . "$1"
      fm_lease_guard task-race "probe"
      trap "fm_lease_guard_release" EXIT
      : > "$FM_TEST_READY"
      while [ ! -e "$FM_TEST_RELEASE" ]; do sleep 0.01; done
    ' _ "$ROOT/bin/fm-lease-lib.sh" &
  operation_pid=$!
  while [ ! -e "$home/operation-ready" ]; do sleep 0.01; done

  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  claim_pid=$!
  sleep 0.2
  kill -0 "$claim_pid" 2>/dev/null \
    || fail "the other actor claimed while the guarded mutation was still running"
  [ ! -e "$home/state/.lease-task-race" ] \
    || fail "the concurrent claim published a lease before the guarded mutation ended"

  : > "$home/operation-release"
  wait "$operation_pid" || fail "guarded mutation fixture failed"
  wait "$claim_pid"; claim_status=$?
  [ "$claim_status" -eq 0 ] || fail "claim did not proceed after guarded mutation ended: $claim_status"
  pass "lease guard excludes a concurrent actor for the complete mutation"
}

test_claim_refuses_the_other_actors_name_loudly() {
  local home out status
  home="$TMP_ROOT/claim-guard-home"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim task-z --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not 6: $out"
  assert_contains "$out" "cannot claim a lease as main" "accidental-override refusal lost its wording"
  [ ! -e "$home/state/.lease-task-z" ] || fail "refused claim still created a lease"
  pass "a claim naming the other actor fails loudly instead of silently impersonating it"
}

test_release_actor_drops_only_that_actors_leases() {
  local home out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/release-actor-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-a --actor branch \
    || fail "branch claim failed"
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-b --actor main \
    || fail "main claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-b --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch release of main lease exited $status, not 6: $out"
  assert_contains "$out" "cannot release a lease as main" "cross-actor release refusal lost its diagnostic"
  [ -e "$home/state/.lease-task-b" ] || fail "refused release removed main's lease"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release-actor --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch release-actor of main leases exited $status, not 6: $out"
  assert_contains "$out" "cannot release leases as main" "cross-actor bulk release refusal lost its diagnostic"
  [ -e "$home/state/.lease-task-b" ] || fail "refused bulk release removed main's lease"

  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release-actor --actor branch || fail "release-actor failed"
  [ ! -e "$home/state/.lease-task-a" ] || fail "release-actor kept the branch lease"
  [ -e "$home/state/.lease-task-b" ] || fail "release-actor dropped main's lease"
  pass "release commands authorize the caller and bulk release drops only that actor's leases"
}

# --- role-partition refinements ----------------------------------------------

test_branch_cannot_force_teardown_or_directly_relaunch() {
  local home root out status
  home="$TMP_ROOT/partition2-home"
  root="$TMP_ROOT/partition2-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"

  # Forced teardown discards work; the branch never discards anything.
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-teardown.sh" task-x --force 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch forced teardown exited $status, not 6: $out"
  assert_contains "$out" "cannot discard work" "forced-teardown refusal lost its wording"
  # An ORDINARY branch teardown is not blocked by this guard (it fails later
  # on its ordinary no-task validation instead).
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-teardown.sh" task-x 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "ordinary branch teardown hit the forced-discard refusal: $out"

  # A branch relaunch is legal only through fm-control's owned transaction,
  # never by direct fm-spawn invocation.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-x --relaunch 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "direct branch relaunch exited $status, not 6: $out"
  assert_contains "$out" "must relaunch through fm-control" "relaunch refusal lost its wording"
  pass "the branch cannot force a teardown or bypass fm-control for a relaunch"
}

test_branch_prompt_is_byte_stable_and_above_cache_floor
test_outcome_store_is_append_only_with_cursor_reads
test_outcome_startup_replay_preserves_silence
test_outcome_startup_replay_stops_at_captain_barrier
test_outcome_cursor_corruption_fails_closed
test_cursor_advancement_refuses_ahead_processed_marker
test_outcome_sequence_conflicts_fail_closed
test_outcome_recent_window_boundaries
test_outcome_non_jsonl_layout_fails_closed
test_outcome_processed_marker_is_sequence_bound
test_outcome_index_migration_preserves_legacy_endpoint_records
test_outcome_retention_keeps_64_processed_and_all_pending_rows
test_outcome_compaction_serializes_and_recovers_publication
test_outcome_retention_refuses_identity_damage_without_loading_cold_normally
test_lease_exclusivity_release_stale_and_sweep
test_mutating_scripts_refuse_the_other_actors_lease
test_main_owned_actions_refuse_the_branch_actor
test_home_without_branch_is_untouched
test_lease_liveness_binds_to_the_session_lock
test_concurrent_stale_lease_claims_have_one_winner
test_guard_stale_clear_cannot_delete_a_new_claim
test_guard_holds_exclusivity_through_mutation
test_claim_refuses_the_other_actors_name_loudly
test_release_actor_drops_only_that_actors_leases
test_branch_cannot_force_teardown_or_directly_relaunch
