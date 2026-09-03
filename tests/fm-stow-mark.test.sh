#!/usr/bin/env bash
# Behavior tests for the automatic stow nudge (bin/fm-stow-mark.sh and its
# delivery through bin/fm-turnend-guard.sh --claude; docs/turnend-guard.md
# "Stow nudge").
#
# Layers:
#   RECORD   - `mark` and `read`: the durable last-stow record and its
#              transcript binding.
#   MEASURE  - `check`: context growth toward the window, compaction, and the
#              wall-clock horizon, read from synthetic Claude transcripts with a
#              bounded tail read.
#   CYCLE    - exactly one nudge per stow cycle until `mark` advances it.
#   GATES    - the lock-owning-primary gate (unowned lock, child worktree), the
#              no-transcript no-op, and config/stow-nudge (off, tuning, and
#              malformed).
#   DIGEST   - `summary`, the session-start digest's input.
#   GUARD    - the real Claude Stop guard turning a due pass into one exit-2
#              continuation only when it would otherwise allow, never in place
#              of a supervision block, and never for non-Claude payloads.
# All hermetic over temp dirs; the session lock is owned by a bash symlinked
# as `fake-claude`, the same harness-ancestry trick the auto-arm tests use.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MARK="$ROOT/bin/fm-stow-mark.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-mark)
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

FAKE_CLAUDE="$TMP_ROOT/fake-claude"
ln -s /bin/bash "$FAKE_CLAUDE"

# --- fixtures ---------------------------------------------------------------

# A primary-shaped home: plain git checkout, AGENTS.md, bin/, state/, config/.
make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cd -P -- "$dir" && pwd -P
}

# A crewmate-shaped child: a genuine linked worktree of a base repo, with the
# same files a primary has, so only the git-dir test tells them apart.
make_child_worktree() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/stow-mark-child
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  : > "$dir/AGENTS.md"
  cd -P -- "$dir" && pwd -P
}

assistant_line() {  # <context-tokens>
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-fable-5-1","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":%s}}}\n' $(( $1 - 105 ))
}

# A fresh transcript whose newest usage reads <context-tokens>, with a sidechain
# assistant line carrying a huge usage that the measure must ignore.
write_transcript() {  # <path> <context-tokens>
  {
    printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'
    printf '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":1,"cache_read_input_tokens":9999999}}}\n'
    assistant_line "$2"
  } > "$1"
}

append_turn() {  # <path> <context-tokens>
  {
    printf '{"type":"user","message":{"role":"user","content":"more"}}\n'
    assistant_line "$2"
  } >> "$1"
}

# Run <cmd...> inside a harness-shaped process that owns <home>'s session lock.
run_owned() {  # <home> <cmd...>
  local home=$1
  shift
  # shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fake harness child
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$@"
  ' _ "$@"
}

run_check() {  # <home> <transcript> [session]
  run_owned "$1" "$MARK" check --transcript "$2" --session "${3:-sess-1}"
}

# Run the real Stop guard in --claude mode inside a lock-owning harness process.
run_guard_owned() {  # <home> <transcript> [session] [guard-args...]
  local home=$1 transcript=$2 session=${3:-sess-1}
  shift 3 2>/dev/null || shift "$#"
  # shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fake harness child
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$session" "$transcript" \
    | CLAUDECODE=1 FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$@"
      ' _ "$GUARD" "$@" 2>&1
}

record_field() {  # <home> <key>
  sed -n "s/^$2=//p" "$1/state/.stow-mark"
}

# Rewrite one record field in place through the documented key=value format.
set_record_field() {  # <home> <key> <value>
  local file="$1/state/.stow-mark" tmp="$1/state/.stow-mark.edit"
  awk -v k="$2" -v v="$3" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

watcher_identity() {  # <home> <pid>
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$2"
}

record_watcher_lock() {  # <home> <pid> <identity>
  mkdir -p "$1/state/.watch.lock"
  printf '%s\n' "$2" > "$1/state/.watch.lock/pid"
  printf '%s\n' "$1" > "$1/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$1/state/.watch.lock/watcher-path"
  printf '%s\n' "$3" > "$1/state/.watch.lock/pid-identity"
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

# --- RECORD: mark and read ---------------------------------------------------

test_mark_records_pass_and_binds_transcript() {
  local home t out size
  home=$(make_home "$TMP_ROOT/mark")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  size=$(wc -c < "$t" | tr -d ' ')

  out=$(FM_HOME="$home" "$MARK" read); expect_code 1 "$?" "read must fail before any mark"
  [ -z "$out" ] || fail "read printed a record that does not exist: $out"

  out=$(FM_HOME="$home" "$MARK" mark --transcript "$t" --session sess-1); expect_code 0 "$?" "mark with a transcript"
  assert_contains "$out" "recorded the completed /stow pass (context 70000 tokens at this point)" "mark must confirm the bound context"
  [ -n "$(record_field "$home" stowed)" ] || fail "mark did not record when the pass completed"
  [ "$(record_field "$home" bound)" = "$(record_field "$home" stowed)" ] || fail "a mark with a transcript must bind at the stow time"
  [ "$(record_field "$home" session)" = sess-1 ] || fail "mark did not record the session"
  [ "$(record_field "$home" transcript)" = "$t" ] || fail "mark did not record the transcript path"
  [ "$(record_field "$home" offset)" = "$size" ] || fail "mark must record the transcript's size as the offset, got $(record_field "$home" offset)"
  [ "$(record_field "$home" context)" = 70000 ] || fail "mark must read the newest non-sidechain usage, got $(record_field "$home" context)"
  out=$(FM_HOME="$home" "$MARK" read); expect_code 0 "$?" "read after mark"
  assert_contains "$out" "context=70000" "read must print the record"

  # A later mark with no arguments reuses the recorded transcript and rebinds.
  append_turn "$t" 120000
  out=$(FM_HOME="$home" "$MARK" mark); expect_code 0 "$?" "mark reusing the recorded transcript"
  [ "$(record_field "$home" context)" = 120000 ] || fail "mark must rebind context from the recorded transcript, got $(record_field "$home" context)"
  [ "$(record_field "$home" offset)" = "$(wc -c < "$t" | tr -d ' ')" ] || fail "mark must rebind the offset"

  # With no usable transcript, only the stow time is recorded.
  home=$(make_home "$TMP_ROOT/mark-unbound")
  out=$(FM_HOME="$home" "$MARK" mark); expect_code 0 "$?" "mark without a transcript"
  assert_contains "$out" "the next turn end binds the transcript" "mark must say the binding is deferred"
  [ "$(cat "$home/state/.stow-mark")" = "stowed=$(record_field "$home" stowed)" ] \
    || fail "an unbound mark must record only stowed=, got: $(cat "$home/state/.stow-mark")"
  out=$(FM_HOME="$home" "$MARK" mark --transcript "$home/missing.jsonl"); expect_code 0 "$?" "mark with an unreadable transcript"
  [ -z "$(record_field "$home" transcript)" ] || fail "an unreadable transcript must not be bound"
  pass "fm-stow-mark mark/read: records the pass, binds the transcript, reuses it, and defers an unknown binding"
}

# --- MEASURE: growth toward the window -------------------------------------

test_check_binds_then_nudges_on_growth() {
  local home t out
  home=$(make_home "$TMP_ROOT/growth")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000

  out=$(run_check "$home" "$t"); expect_code 0 "$?" "first check must bind, not nudge"
  [ -z "$out" ] || fail "binding check produced output: $out"
  [ "$(record_field "$home" context)" = 70000 ] || fail "first check did not bind the context"
  [ "$(record_field "$home" transcript)" = "$t" ] || fail "first check did not bind the transcript"
  [ -z "$(record_field "$home" stowed)" ] || fail "binding must not invent a stow time"

  # 60% of the 930k room left below a 1M window is 558k of growth.
  append_turn "$t" 500000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "430k of growth is below the 558k threshold"
  [ -z "$out" ] || fail "below-threshold check produced output: $out"
  assert_absent "$home/state/.stow-nudged" "no delivery marker below threshold"

  append_turn "$t" 640000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "570k of growth must be due"
  [ "$out" = "firstmate stow nudge: 570k context tokens with no /stow pass recorded (threshold 558k); run the /stow pass now" ] \
    || fail "unexpected nudge text: $out"
  assert_present "$home/state/.stow-nudged" "delivery must be recorded"
  pass "fm-stow-mark check: binds on first sight, then nudges at 60% of the room left to the window"
}

test_check_once_per_cycle_until_mark() {
  local home t out
  home=$(make_home "$TMP_ROOT/cycle")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_check "$home" "$t" >/dev/null
  append_turn "$t" 640000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "first due check nudges"

  append_turn "$t" 700000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a delivered cycle must stay silent"
  [ -z "$out" ] || fail "delivered cycle nudged again: $out"
  append_turn "$t" 900000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "still silent however far it grows"

  # The completed pass advances the cycle: growth is measured from it anew.
  out=$(FM_HOME="$home" "$MARK" mark --transcript "$t"); expect_code 0 "$?" "mark after the nudge"
  assert_absent "$home/state/.stow-nudged" "mark must clear the delivery marker"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "no growth since the pass"
  # Room left is now 100k, so 60k of growth is due.
  append_turn "$t" 950000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "50k of growth is below the 60k threshold"
  append_turn "$t" 965000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "65k of growth is due"
  [ "$out" = "firstmate stow nudge: 65k context tokens since last /stow (threshold 60k); run the /stow pass now" ] \
    || fail "unexpected second-cycle nudge text: $out"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "second cycle delivered once"
  pass "fm-stow-mark check: exactly one nudge per cycle, and mark starts the next cycle"
}

test_check_compaction_drop_nudges_and_rebinds() {
  local home t out
  home=$(make_home "$TMP_ROOT/compaction")
  t="$home/transcript.jsonl"
  write_transcript "$t" 600000
  run_check "$home" "$t" >/dev/null
  [ "$(record_field "$home" context)" = 600000 ] || fail "binding at 600k"

  append_turn "$t" 150000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "a context that shrank was compacted"
  [ "$out" = "firstmate stow nudge: the context was compacted with no /stow pass recorded; run the /stow pass now" ] \
    || fail "unexpected compaction nudge text: $out"
  [ "$(record_field "$home" context)" = 150000 ] || fail "compaction must rebind the context to the smaller value"
  [ "$(record_field "$home" offset)" = "$(wc -c < "$t" | tr -d ' ')" ] || fail "compaction must rebind the offset"

  append_turn "$t" 160000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "the compaction nudge was delivered once"
  pass "fm-stow-mark check: a compacted context nudges once and rebinds the baseline"
}

test_check_horizon_fallback_and_bounded_tail() {
  local home t out now
  home=$(make_home "$TMP_ROOT/horizon")
  t="$home/transcript.jsonl"
  # The newest usage sits beyond a 300-byte tail: the growth measure is
  # unavailable, and only the horizon can nudge.
  write_transcript "$t" 70000
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$(printf 'x%.0s' $(seq 1 400))" >> "$t"
  FM_STOW_TAIL_BYTES=300 run_check "$home" "$t" >/dev/null
  [ -z "$(record_field "$home" context)" ] || fail "no usage inside the bounded tail must bind no context"
  [ -n "$(record_field "$home" bound)" ] || fail "binding time must still be recorded"
  append_turn "$t" 900000
  out=$(FM_STOW_TAIL_BYTES=300 run_check "$home" "$t"); expect_code 0 "$?" "no growth measure without a bound context"

  now=$(date +%s)
  set_record_field "$home" bound $((now - 4 * 3600))
  out=$(FM_STOW_TAIL_BYTES=300 run_check "$home" "$t"); expect_code 3 "$?" "4h of wall clock is past the 3h horizon"
  [ "$out" = "firstmate stow nudge: 4h 00m wall clock since this session's first turn end, with no /stow pass recorded (threshold 3h); run the /stow pass now" ] \
    || fail "unexpected horizon nudge text: $out"

  # A partial first line in the tail is skipped, and the usage after it is read.
  home=$(make_home "$TMP_ROOT/tail")
  t="$home/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$(printf 'y%.0s' $(seq 1 400))" > "$t"
  assistant_line 123000 >> "$t"
  FM_STOW_TAIL_BYTES=300 run_check "$home" "$t" >/dev/null
  [ "$(record_field "$home" context)" = 123000 ] || fail "the usage inside the tail must be read past a partial first line, got '$(record_field "$home" context)'"
  pass "fm-stow-mark check: the horizon covers a session without a growth measure, and the tail read is bounded"
}

# Claude Code writes assistant lines with no real usage: API-error and
# interruption messages carry model "<synthetic>" and all-zero usage. Neither a
# synthetic line nor a zero usage is a context reading, so neither can look
# like a compaction or become a baseline of 0.
synthetic_line() {  # [context-tokens, default 0]
  printf '{"type":"assistant","message":{"role":"assistant","model":"<synthetic>","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "${1:-0}"
}

zero_usage_line() {
  printf '{"type":"assistant","message":{"role":"assistant","model":"claude-fable-5-1","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
}

test_check_skips_synthetic_and_zero_usage_lines() {
  local home t out
  home=$(make_home "$TMP_ROOT/synthetic")
  t="$home/transcript.jsonl"
  write_transcript "$t" 300000
  run_check "$home" "$t" >/dev/null
  [ "$(record_field "$home" context)" = 300000 ] || fail "binding at 300k"

  synthetic_line >> "$t"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a synthetic zero-usage line is not a compaction"
  [ -z "$out" ] || fail "synthetic line nudged: $out"
  [ "$(record_field "$home" context)" = 300000 ] || fail "a synthetic line must not rebind the context, got '$(record_field "$home" context)'"
  assert_absent "$home/state/.stow-nudged" "a synthetic line must not consume the cycle"

  zero_usage_line >> "$t"
  synthetic_line 50 >> "$t"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a real-model zero usage and a synthetic non-zero usage are both skipped"
  [ -z "$out" ] || fail "zero-usage or synthetic line nudged: $out"
  [ "$(record_field "$home" context)" = 300000 ] || fail "the baseline must survive skipped lines, got '$(record_field "$home" context)'"

  # The newest real usage is still read past those lines.
  append_turn "$t" 310000
  synthetic_line >> "$t"
  out=$(FM_HOME="$home" "$MARK" mark --transcript "$t"); expect_code 0 "$?" "mark past trailing synthetic lines"
  assert_contains "$out" "(context 310000 tokens at this point)" "mark must read the newest real usage"
  [ "$(record_field "$home" context)" = 310000 ] || fail "mark must bind the newest real usage, got '$(record_field "$home" context)'"

  # A transcript with only synthetic assistant lines has no reading at all:
  # the context stays unknown, so nothing can be mistaken for a compaction.
  home=$(make_home "$TMP_ROOT/synthetic-only")
  t="$home/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$t"
  synthetic_line >> "$t"
  zero_usage_line >> "$t"
  out=$(FM_HOME="$home" "$MARK" mark --transcript "$t"); expect_code 0 "$?" "mark on a synthetic-only transcript"
  [ -z "$(record_field "$home" context)" ] || fail "a synthetic-only transcript must bind no context, got '$(record_field "$home" context)'"
  [ "$(record_field "$home" transcript)" = "$t" ] || fail "the transcript itself is still bound"
  synthetic_line >> "$t"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "no reading means no compaction nudge"
  [ -z "$out" ] || fail "synthetic-only transcript nudged: $out"
  [ -z "$(record_field "$home" context)" ] || fail "check must not rebind a context it could not read, got '$(record_field "$home" context)'"

  # A record that already holds context=0 is read as no baseline, never as a
  # point every real reading would be compared against.
  home=$(make_home "$TMP_ROOT/zero-baseline")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_check "$home" "$t" >/dev/null
  set_record_field "$home" context 0
  append_turn "$t" 150000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a zero baseline measures nothing"
  [ -z "$out" ] || fail "zero baseline nudged: $out"
  assert_absent "$home/state/.stow-nudged" "a zero baseline must not deliver"
  pass "fm-stow-mark check: synthetic and zero-usage assistant lines are never a reading, a baseline, or a compaction"
}

# A first turn that ends in an API error leaves only a synthetic assistant line,
# so the binding has no context. The first real reading after that becomes the
# cycle's baseline instead of being discarded turn after turn.
test_check_adopts_first_real_reading_as_baseline() {
  local home t out now bound
  home=$(make_home "$TMP_ROOT/late-binding")
  t="$home/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$t"
  synthetic_line >> "$t"
  run_check "$home" "$t" >/dev/null
  [ -z "$(record_field "$home" context)" ] || fail "a synthetic-only first turn binds no context"
  bound=$(record_field "$home" bound)
  [ -n "$bound" ] || fail "the binding time must be recorded"

  append_turn "$t" 300000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "the first real reading is adopted, not nudged"
  [ -z "$out" ] || fail "adopting Stop produced output: $out"
  [ "$(record_field "$home" context)" = 300000 ] || fail "the reading must become the baseline, got '$(record_field "$home" context)'"
  [ "$(record_field "$home" offset)" = "$(wc -c < "$t" | tr -d ' ')" ] || fail "adoption must rebind the offset"
  [ "$(record_field "$home" bound)" = "$bound" ] || fail "adoption must leave the binding time alone"
  assert_absent "$home/state/.stow-nudged" "adoption must not consume the cycle"

  # Growth is measured from the adopted baseline: room is 700k, so 420k is due.
  append_turn "$t" 700000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "400k of growth is below the 420k threshold"
  append_turn "$t" 730000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "430k of growth is due"
  [ "$out" = "firstmate stow nudge: 430k context tokens with no /stow pass recorded (threshold 420k); run the /stow pass now" ] \
    || fail "unexpected nudge from the adopted baseline: $out"

  # A pass marked on a synthetic-only transcript adopts the same way, keeping
  # the stow time, and a compaction is then seen against the adopted baseline.
  home=$(make_home "$TMP_ROOT/late-binding-mark")
  t="$home/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$t"
  synthetic_line >> "$t"
  FM_HOME="$home" "$MARK" mark --transcript "$t" --session sess-1 >/dev/null
  [ -z "$(record_field "$home" context)" ] || fail "mark on a synthetic-only transcript binds no context"
  bound=$(record_field "$home" bound)
  append_turn "$t" 500000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "the reading after the pass is adopted"
  [ "$(record_field "$home" context)" = 500000 ] || fail "adopted after mark, got '$(record_field "$home" context)'"
  [ "$(record_field "$home" bound)" = "$bound" ] || fail "mark's binding time must survive adoption"
  [ "$(record_field "$home" stowed)" = "$bound" ] || fail "the stow time must survive adoption"
  append_turn "$t" 120000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "a compaction against the adopted baseline nudges"
  [ "$out" = "firstmate stow nudge: the context was compacted since last /stow; run the /stow pass now" ] \
    || fail "unexpected compaction nudge: $out"

  # An already-due horizon waits for the Stop after the adopting one.
  home=$(make_home "$TMP_ROOT/late-binding-horizon")
  t="$home/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hello"}}\n' > "$t"
  synthetic_line >> "$t"
  run_check "$home" "$t" >/dev/null
  now=$(date +%s)
  set_record_field "$home" bound $((now - 4 * 3600))
  append_turn "$t" 90000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "the adopting Stop delivers nothing"
  [ -z "$out" ] || fail "adopting Stop nudged: $out"
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "the next Stop delivers the horizon"
  assert_contains "$out" "4h 00m wall clock since this session's first turn end" "the horizon must be the reason"
  pass "fm-stow-mark check: the first real reading after a context-less binding becomes the cycle baseline"
}

# --- GATES ------------------------------------------------------------------

test_check_no_transcript_is_silent_noop() {
  local home out
  home=$(make_home "$TMP_ROOT/no-transcript")
  out=$(run_owned "$home" "$MARK" check); expect_code 0 "$?" "check with no transcript"
  [ -z "$out" ] || fail "no-transcript check produced output: $out"
  out=$(run_owned "$home" "$MARK" check --transcript "$home/missing.jsonl" --session sess-1); expect_code 0 "$?" "check with a missing transcript"
  [ -z "$out" ] || fail "missing-transcript check produced output: $out"
  out=$(run_owned "$home" "$MARK" check --transcript "$home/state" --session sess-1); expect_code 0 "$?" "check with a directory"
  [ -z "$out" ] || fail "directory check produced output: $out"
  assert_absent "$home/state/.stow-mark" "a no-op check must write no record"
  assert_absent "$home/state/.stow-nudged" "a no-op check must write no marker"
  out=$(FM_HOME="$home" "$MARK" check --transcript 2>/dev/null); expect_code 2 "$?" "a dangling option is invalid use"
  pass "fm-stow-mark check: no transcript, an unreadable one, or a directory is a silent no-op"
}

test_check_requires_lock_owning_primary() {
  local home base child t out sleeper dead
  home=$(make_home "$TMP_ROOT/gate")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_check "$home" "$t" >/dev/null
  append_turn "$t" 900000

  # No lock at all.
  rm -f "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$MARK" check --transcript "$t" --session sess-1); expect_code 0 "$?" "no lock"
  [ -z "$out" ] || fail "unowned home nudged: $out"
  # A lock held by a live process outside this ancestry, and by a dead one.
  sleep 60 &
  sleeper=$!
  printf '%s\n' "$sleeper" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$MARK" check --transcript "$t" --session sess-1); expect_code 0 "$?" "foreign live lock"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  [ -z "$out" ] || fail "foreign-locked home nudged: $out"
  dead=$(nonexistent_pid)
  printf '%s\n' "$dead" > "$home/state/.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$MARK" check --transcript "$t" --session sess-1); expect_code 0 "$?" "dead lock"
  [ -z "$out" ] || fail "dead-locked home nudged: $out"
  assert_absent "$home/state/.stow-nudged" "an unowned session must not deliver"
  [ "$(record_field "$home" context)" = 70000 ] || fail "an unowned session must not touch the record"

  # The owning session is due right away.
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "the lock-owning session nudges"

  # A crewmate-shaped child worktree is never a primary, even when owned.
  base="$TMP_ROOT/gate-base"
  child=$(make_child_worktree "$base" "$TMP_ROOT/gate-child")
  t="$child/transcript.jsonl"
  write_transcript "$t" 70000
  out=$(run_check "$child" "$t"); expect_code 0 "$?" "child worktree first check"
  assert_absent "$child/state/.stow-mark" "a child worktree must never write a record"
  append_turn "$t" 900000
  out=$(run_check "$child" "$t"); expect_code 0 "$?" "child worktree with a huge context"
  [ -z "$out" ] || fail "child worktree nudged: $out"
  assert_absent "$child/state/.stow-nudged" "a child worktree must never deliver"
  pass "fm-stow-mark check: only the primary session that owns the lock measures, writes, or nudges"
}

test_config_off_tuning_env_and_malformed() {
  local home t out now
  home=$(make_home "$TMP_ROOT/config")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_check "$home" "$t" >/dev/null
  now=$(date +%s)

  # off: nothing nudges however due.
  append_turn "$t" 900000
  set_record_field "$home" bound $((now - 5 * 3600))
  printf ' off \n' > "$home/config/stow-nudge"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "off disables the nudge"
  [ -z "$out" ] || fail "off nudged: $out"
  assert_absent "$home/state/.stow-nudged" "off must not deliver"

  # Tuning: a 200k window at 10 percent nudges after 13k of growth from 70k.
  set_record_field "$home" bound "$now"
  printf '# local tuning\nwindow = 200000\npercent=10\n\nhours=1\n' > "$home/config/stow-nudge"
  write_transcript "$t" 70000
  append_turn "$t" 82000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "12k of growth is below a 13k threshold"
  append_turn "$t" 84000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "14k of growth is due at 10 percent of 130k"
  assert_contains "$out" "14k context tokens with no /stow pass recorded (threshold 13k)" "tuned threshold must be reported"
  # hours=1 shortens the horizon.
  FM_HOME="$home" "$MARK" mark --transcript "$t" >/dev/null
  set_record_field "$home" bound $((now - 3700))
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "1h 01m is past a 1h horizon"
  assert_contains "$out" "1h 01m wall clock since the last stow record or this session's first turn end, whichever is later (threshold 1h)" "tuned horizon must be reported"

  # Environment overrides supply the default window when the file sets none.
  rm -f "$home/config/stow-nudge"
  home=$(make_home "$TMP_ROOT/config-env")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_check "$home" "$t" >/dev/null
  append_turn "$t" 200000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_check "$home" "$t"); expect_code 0 "$?" "130k is below 60% of 230k"
  append_turn "$t" 210000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_check "$home" "$t"); expect_code 3 "$?" "140k is due against a 300k window"
  assert_contains "$out" "(threshold 138k)" "the environment window must set the threshold"
  home=$(make_home "$TMP_ROOT/config-env-200k")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  CLAUDE_CODE_DISABLE_1M_CONTEXT=1 run_check "$home" "$t" >/dev/null
  append_turn "$t" 150000
  out=$(CLAUDE_CODE_DISABLE_1M_CONTEXT=1 run_check "$home" "$t"); expect_code 3 "$?" "80k is due against a 200k window"
  assert_contains "$out" "(threshold 78k)" "the disabled-1M window must set the threshold"
  # A configured window beats the environment.
  home=$(make_home "$TMP_ROOT/config-wins")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  printf 'window=1000000\n' > "$home/config/stow-nudge"
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_check "$home" "$t" >/dev/null
  append_turn "$t" 300000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 run_check "$home" "$t"); expect_code 0 "$?" "230k is below 60% of 930k"

  # Malformed: the nudge is disabled and summary names the reason.
  home=$(make_home "$TMP_ROOT/config-bad")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_check "$home" "$t" >/dev/null
  append_turn "$t" 900000
  for bad in 'window=abc' 'window=99999' 'window=0200000' 'window=0900000' 'percent=0' 'percent=08' 'percent=100' 'hours=-1' 'hours=08' 'cadence=3' 'just words'; do
    printf '%s\n' "$bad" > "$home/config/stow-nudge"
    out=$(run_check "$home" "$t"); expect_code 0 "$?" "malformed '$bad' disables the nudge"
    [ -z "$out" ] || fail "malformed '$bad' nudged: $out"
    out=$(FM_HOME="$home" "$MARK" summary); expect_code 1 "$?" "summary reports malformed '$bad'"
    [ -n "$out" ] || fail "summary gave no reason for '$bad'"
  done
  printf 'window=abc\n' > "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary)
  [ "$out" = "window must be a positive token count, got 'abc'" ] || fail "unexpected malformed reason: $out"
  printf 'window=99999\n' > "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary)
  [ "$out" = "window must be at least 100000 tokens, got '99999'" ] || fail "unexpected below-floor reason: $out"
  # A leading zero would be read as octal by arithmetic, so it is not a number.
  printf 'window=0200000\n' > "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary)
  [ "$out" = "window must be a positive token count, got '0200000'" ] || fail "unexpected leading-zero reason: $out"
  printf 'hours=08\n' > "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary)
  [ "$out" = "hours must be a positive integer, got '08'" ] || fail "unexpected leading-zero hours reason: $out"
  rm -f "$home/config/stow-nudge"
  ln -s /dev/null "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 1 "$?" "a symlinked config is malformed"
  [ "$out" = "must not be a symlink" ] || fail "unexpected symlink reason: $out"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a symlinked config disables the nudge"
  assert_absent "$home/state/.stow-nudged" "malformed config must never deliver"
  pass "fm-stow-mark config: off, tuning, documented environment windows, and malformed files"
}

# A window below the context the measure counts from would leave no room, so
# every token of growth after a /stow pass would be due again and each mark
# would open a fresh cycle: /stow, nudge, /stow, nudge, back to back. Such a
# window skips the growth condition for that cycle instead; compaction and the
# horizon still apply.
test_window_below_context_skips_growth_not_horizon_or_compaction() {
  local home t out now
  home=$(make_home "$TMP_ROOT/window-below")
  t="$home/transcript.jsonl"
  printf 'window=200000\n' > "$home/config/stow-nudge"
  write_transcript "$t" 250000
  run_check "$home" "$t" >/dev/null
  [ "$(record_field "$home" context)" = 250000 ] || fail "binding at 250k"

  append_turn "$t" 260000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "growth above a window that is already exceeded is not due"
  [ -z "$out" ] || fail "exceeded window nudged on growth: $out"
  assert_absent "$home/state/.stow-nudged" "no delivery when the growth condition is skipped"

  # The runaway shape: a pass completes above the window, then the receipt
  # adds a few tokens. Each such turn end must allow silently.
  FM_HOME="$home" "$MARK" mark --transcript "$t" >/dev/null
  append_turn "$t" 260200
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a few tokens after the pass must not re-nudge"
  [ -z "$out" ] || fail "re-nudged right after the pass: $out"
  append_turn "$t" 400000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "however far it grows past the window"
  assert_absent "$home/state/.stow-nudged" "still no delivery"

  # The horizon still covers that cycle.
  now=$(date +%s)
  set_record_field "$home" bound $((now - 4 * 3600))
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "the horizon still nudges"
  assert_contains "$out" "4h 00m wall clock" "the horizon must be the reason"

  # And so does a compaction in the next cycle.
  FM_HOME="$home" "$MARK" mark --transcript "$t" >/dev/null
  append_turn "$t" 120000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "a compaction still nudges"
  assert_contains "$out" "the context was compacted since last /stow" "compaction must be the reason"
  [ "$(record_field "$home" context)" = 120000 ] || fail "compaction must still rebind"
  # Back under the window, the growth measure resumes: room is 80k, so 48k is due.
  append_turn "$t" 170000
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "delivered cycle stays silent"
  FM_HOME="$home" "$MARK" mark --transcript "$t" >/dev/null
  append_turn "$t" 210000
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "40k of growth against 30k of room is due"
  assert_contains "$out" "40k context tokens since last /stow (threshold 18k)" "growth resumes under the window"
  pass "fm-stow-mark check: a window below the bound context skips growth for the cycle while horizon and compaction still apply"
}

# Claude Code accepts no auto-compact window under 100k, so neither does the
# measure: a smaller window= is malformed, and a smaller environment override
# is ignored in favor of the default rather than adopted.
test_window_floor_in_config_and_environment() {
  local home t out
  home=$(make_home "$TMP_ROOT/window-floor")
  t="$home/transcript.jsonl"
  write_transcript "$t" 20000
  run_check "$home" "$t" >/dev/null
  append_turn "$t" 90000
  printf 'window=50000\n' > "$home/config/stow-nudge"
  out=$(run_check "$home" "$t"); expect_code 0 "$?" "a window under the floor disables the nudge"
  [ -z "$out" ] || fail "below-floor window nudged: $out"
  assert_absent "$home/state/.stow-nudged" "malformed window must not deliver"
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 1 "$?" "summary reports the below-floor window"
  [ "$out" = "window must be at least 100000 tokens, got '50000'" ] || fail "unexpected floor reason: $out"
  printf 'window=100000\n' > "$home/config/stow-nudge"
  out=$(run_check "$home" "$t"); expect_code 3 "$?" "the floor itself is a valid window"
  assert_contains "$out" "70k context tokens with no /stow pass recorded (threshold 48k)" "a 100k window measures 80k of room"

  # Under a 50k environment window, 20k of growth from 20k would be due
  # (threshold 18k); the override is ignored and the 1M default applies.
  home=$(make_home "$TMP_ROOT/window-floor-env")
  t="$home/transcript.jsonl"
  write_transcript "$t" 20000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000 run_check "$home" "$t" >/dev/null
  append_turn "$t" 40000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000 run_check "$home" "$t"); expect_code 0 "$?" "a below-floor environment window is ignored"
  [ -z "$out" ] || fail "below-floor environment window nudged: $out"
  append_turn "$t" 640000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000 run_check "$home" "$t"); expect_code 3 "$?" "the default window measures instead"
  assert_contains "$out" "620k context tokens with no /stow pass recorded (threshold 588k)" "the 1M default must set the threshold"
  out=$(FM_HOME="$home" CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000 "$MARK" summary); expect_code 0 "$?" "an ignored override is not a malformed config"

  # A leading-zero override is not a token count either: under a 300k window
  # 180k of growth from 20k would be due (threshold 168k); the 1M default applies.
  home=$(make_home "$TMP_ROOT/window-floor-env-octal")
  t="$home/transcript.jsonl"
  write_transcript "$t" 20000
  CLAUDE_CODE_AUTO_COMPACT_WINDOW=0300000 run_check "$home" "$t" >/dev/null
  append_turn "$t" 200000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=0300000 run_check "$home" "$t"); expect_code 0 "$?" "a leading-zero environment window is ignored"
  [ -z "$out" ] || fail "leading-zero environment window nudged: $out"
  append_turn "$t" 640000
  out=$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=0300000 run_check "$home" "$t"); expect_code 3 "$?" "the default window measures instead of the octal reading"
  assert_contains "$out" "620k context tokens with no /stow pass recorded (threshold 588k)" "the 1M default must set the threshold"
  pass "fm-stow-mark config: a window under 100k or with a leading zero is malformed in the file and ignored in the environment"
}

# --- DIGEST: summary --------------------------------------------------------

test_summary_reports_age_and_overdue() {
  local home out now
  home=$(make_home "$TMP_ROOT/summary")
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 0 "$?" "summary with no record"
  [ "$out" = "no /stow pass recorded yet" ] || fail "unexpected empty summary: $out"
  FM_HOME="$home" "$MARK" mark >/dev/null
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 0 "$?" "summary right after a pass"
  [ "$out" = "last /stow pass recorded under 1m ago" ] || fail "unexpected fresh summary: $out"
  now=$(date +%s)
  set_record_field "$home" stowed $((now - 5 * 3600 - 120))
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 3 "$?" "an overdue pass exits 3"
  [ "$out" = "last /stow pass recorded 5h 02m ago, past the 3h stow-nudge horizon" ] || fail "unexpected overdue summary: $out"
  printf 'hours=6\n' > "$home/config/stow-nudge"
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 0 "$?" "a longer horizon is not overdue"
  [ "$out" = "last /stow pass recorded 5h 02m ago" ] || fail "unexpected tuned summary: $out"
  printf 'off\n' > "$home/config/stow-nudge"
  set_record_field "$home" stowed $((now - 2 * 86400 - 3600))
  out=$(FM_HOME="$home" "$MARK" summary); expect_code 0 "$?" "off is never overdue"
  [ "$out" = "last /stow pass recorded 2d 01h ago" ] || fail "unexpected off summary: $out"
  pass "fm-stow-mark summary: age, the overdue exit, and tuning"
}

# --- GUARD: delivery through the Claude Stop guard ----------------------------

test_guard_claude_mode_delivers_nudge_once_on_allow() {
  local home t out status
  home=$(make_home "$TMP_ROOT/guard-allow")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  expect_code 0 "$status" "an idle home binds silently on its first Stop"
  [ -z "$out" ] || fail "binding Stop produced output: $out"
  [ "$(record_field "$home" context)" = 70000 ] || fail "the guard's check did not bind"

  append_turn "$t" 640000
  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  expect_code 2 "$status" "a due pass becomes one continuation"
  [ "$out" = "firstmate stow nudge: 570k context tokens with no /stow pass recorded (threshold 558k); run the /stow pass now" ] \
    || fail "unexpected guard nudge output: $out"

  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  expect_code 0 "$status" "the next Stop allows again"
  [ -z "$out" ] || fail "delivered cycle produced output: $out"

  FM_HOME="$home" "$MARK" mark --transcript "$t" >/dev/null
  append_turn "$t" 950000
  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  expect_code 2 "$status" "the next cycle nudges again"
  assert_contains "$out" "310k context tokens since last /stow (threshold 216k)" "second-cycle nudge through the guard"
  pass "fm-turnend-guard --claude: one stow-nudge continuation per cycle on an otherwise allowed Stop"
}

test_guard_supervision_block_wins_over_nudge() {
  local home t out status pid identity
  home=$(make_home "$TMP_ROOT/guard-block")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_guard_owned "$home" "$t" sess-1 --claude >/dev/null
  append_turn "$t" 640000
  : > "$home/state/task1.meta"

  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  expect_code 2 "$status" "an unsupervised Stop still blocks"
  assert_contains "$out" "TURN WOULD END BLIND" "the supervision block must be the verdict"
  assert_not_contains "$out" "firstmate stow nudge" "the nudge must not displace a block"
  assert_absent "$home/state/.stow-nudged" "a blocked Stop must not consume the cycle"

  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$home" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify the live watcher holder"
  }
  record_watcher_lock "$home" "$pid" "$identity"
  touch "$home/state/.last-watcher-beat"
  out=$(run_guard_owned "$home" "$t" sess-1 --claude); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a healthy Stop that would allow carries the nudge"
  assert_not_contains "$out" "TURN WOULD END BLIND" "a healthy home must not block"
  assert_contains "$out" "firstmate stow nudge: 570k context tokens" "the nudge rides the healthy allow"
  assert_present "$home/state/.stow-nudged" "delivery recorded on the healthy allow"
  pass "fm-turnend-guard --claude: a supervision block always wins, and the nudge rides the next allow"
}

test_guard_never_nudges_outside_claude_lock_owning_primary() {
  local home base child t out status
  home=$(make_home "$TMP_ROOT/guard-scope")
  t="$home/transcript.jsonl"
  write_transcript "$t" 70000
  run_guard_owned "$home" "$t" sess-1 --claude >/dev/null
  append_turn "$t" 900000

  # Default (Codex-shaped) mode, transcript present: never a nudge.
  out=$(run_guard_owned "$home" "$t" sess-1); status=$?
  expect_code 0 "$status" "non-Claude mode allows"
  [ -z "$out" ] || fail "non-Claude mode produced output: $out"
  # Cursor mode: never a nudge.
  out=$(run_guard_owned "$home" "$t" sess-1 --cursor); status=$?
  expect_code 0 "$status" "Cursor mode allows"
  [ -z "$out" ] || fail "Cursor mode produced output: $out"
  # Claude mode without the lock in this ancestry.
  rm -f "$home/state/.lock"
  out=$(printf '{"session_id":"sess-1","transcript_path":"%s","stop_hook_active":false}' "$t" \
    | CLAUDECODE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" bash "$GUARD" --claude 2>&1); status=$?
  expect_code 0 "$status" "a session that does not own the lock allows"
  [ -z "$out" ] || fail "unowned Claude session produced output: $out"
  # Claude mode without a transcript in the payload.
  # shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fake harness child
  out=$(printf '{"session_id":"sess-1","stop_hook_active":false}' \
    | CLAUDECODE=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$1" --claude
      ' _ "$GUARD" 2>&1); status=$?
  expect_code 0 "$status" "no transcript path allows"
  [ -z "$out" ] || fail "transcript-less payload produced output: $out"
  assert_absent "$home/state/.stow-nudged" "none of those Stops may deliver"

  # A crewmate worktree stays inert even when owned in Claude mode.
  base="$TMP_ROOT/guard-scope-base"
  child=$(make_child_worktree "$base" "$TMP_ROOT/guard-scope-child")
  t="$child/transcript.jsonl"
  write_transcript "$t" 900000
  out=$(run_guard_owned "$child" "$t" sess-1 --claude); status=$?
  expect_code 0 "$status" "child worktree allows"
  [ -z "$out" ] || fail "child worktree produced output: $out"
  assert_absent "$child/state/.stow-mark" "child worktree writes no record"
  pass "fm-turnend-guard: the stow nudge is a no-op for non-Claude modes, unowned sessions, missing transcripts, and worker worktrees"
}

test_mark_records_pass_and_binds_transcript
test_check_binds_then_nudges_on_growth
test_check_once_per_cycle_until_mark
test_check_compaction_drop_nudges_and_rebinds
test_check_horizon_fallback_and_bounded_tail
test_check_skips_synthetic_and_zero_usage_lines
test_check_adopts_first_real_reading_as_baseline
test_check_no_transcript_is_silent_noop
test_check_requires_lock_owning_primary
test_config_off_tuning_env_and_malformed
test_window_below_context_skips_growth_not_horizon_or_compaction
test_window_floor_in_config_and_environment
test_summary_reports_age_and_overdue
test_guard_claude_mode_delivers_nudge_once_on_allow
test_guard_supervision_block_wins_over_nudge
test_guard_never_nudges_outside_claude_lock_owning_primary
