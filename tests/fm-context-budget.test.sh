#!/usr/bin/env bash
# Behavior tests for the primary context-budget guardrail (docs/context-budget.md).
#
# Subject: bin/fm-context-budget.sh, the Stop-boundary hook that measures the
# live session's context from the transcript the payload points at and blocks
# the turn end once the measurement crosses the absolute ceiling.
#
# Five layers:
#   MEASUREMENT  - the three correctness rules (last-not-max-not-sum, sidechain
#                  exclusion, zero-usage synthetic entries ignored) and the
#                  multi-block property that subsumes dedupe.
#   STAGES       - the derived advisory notice, the warning-only shipped default
#                  at the ceiling, and the opt-in enforcing ceiling.
#   CHANNELS     - which stream each notice lands on. Asserted SEPARATELY, never
#                  merged: Claude Code discards a successful Stop hook's stderr,
#                  so a merged capture cannot tell a visible notice from an
#                  invisible one.
#   DEGRADATION  - every measurement failure is a silent exit 0, and every record
#                  failure degrades toward not blocking.
#   SCOPE        - inert in a crewmate worktree, active in a secondmate home.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-budget)
fm_git_identity fmtest fmtest@example.invalid

# --- fixtures ----------------------------------------------------------------

install_budget_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-context-budget.sh" "$dir/bin/fm-context-budget.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  chmod +x "$dir/bin/fm-context-budget.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the shared primary scope requires.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape plus the .fm-secondmate-home marker bin/fm-home-seed.sh writes. A
# secondmate runs its OWN primary session, so the guard must bind it.
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree`, the shape bin/fm-spawn.sh hands every
# crewmate and scout task. git-dir != git-common-dir here, and a child worktree
# never carries the gitignored secondmate marker.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/context-budget-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf '%s\n' "$dir"
}

# One assistant transcript line whose four usage fields sum to $1. The bulk sits
# in cache_read_input_tokens, the field that dominates a real long session.
assistant_line() {
  local total=$1 rid=${2:-req-1} sidechain=${3:-false}
  printf '{"type":"assistant","isSidechain":%s,"requestId":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' \
    "$sidechain" "$rid" "$((total - 20))"
}

# A transcript of one assistant turn per argument, each with its own requestId.
write_transcript() {
  local path=$1
  shift
  : > "$path"
  local total
  for total in "$@"; do
    assistant_line "$total" "req-$total" >> "$path"
  done
}

# A trailing synthetic entry, the shape Claude Code writes when a turn ends
# abnormally: assistant, main chain, model "<synthetic>", all four usage fields 0.
synthetic_zero_line() {
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n'
}

# The marker Claude Code writes across a compaction. Real observed values.
compact_boundary_line() {
  printf '{"type":"system","subtype":"compact_boundary","isSidechain":%s,"compactMetadata":{"preTokens":%s,"postTokens":%s}}\n' \
    "${3:-false}" "${1:-318961}" "${2:-18947}"
}

stop_payload() {
  printf '{"session_id":"%s","stop_hook_active":false,"transcript_path":"%s"}' "${2:-sess-1}" "$1"
}

# Run the hook as the registered Claude Stop hook, capturing the two channels
# SEPARATELY into BUDGET_STDOUT and BUDGET_STDERR and returning the hook's exit
# status. Channel identity is load-bearing here, so it must never be lost to a
# 2>&1 merge: an exit-0 notice written to stderr is discarded by Claude Code and
# is therefore invisible, which a merged capture cannot detect.
# Call this DIRECTLY, never inside a command substitution, or the two globals are
# set in a subshell and lost.
BUDGET_STDOUT=''
BUDGET_STDERR=''
run_budget_channels() {
  local dir=$1 payload=$2
  shift 2
  local home errfile status
  home=$(cd "$dir" && pwd)
  errfile=$(mktemp "$TMP_ROOT/stderr.XXXXXX")
  BUDGET_STDOUT=$(printf '%s' "$payload" | env "$@" CLAUDECODE=1 FM_HOME="$home" \
    bash "$dir/bin/fm-context-budget.sh" --claude 2>"$errfile")
  status=$?
  BUDGET_STDERR=$(cat "$errfile")
  rm -f "$errfile"
  return "$status"
}

# The merged view, for the tests whose subject is behavior rather than channel.
run_budget() {
  local status
  run_budget_channels "$@"
  status=$?
  [ -z "$BUDGET_STDOUT" ] || printf '%s\n' "$BUDGET_STDOUT"
  [ -z "$BUDGET_STDERR" ] || printf '%s\n' "$BUDGET_STDERR"
  return "$status"
}

# The visible non-blocking channel is a systemMessage JSON object on stdout, so
# assert the shape too: a bare banner on stdout would render as nothing.
assert_system_message_contains() {  # <stdout> <needle> <label>
  local msg
  msg=$(printf '%s' "$1" | jq -r '.systemMessage' 2>/dev/null) \
    || fail "$3: stdout is not a JSON hook response: $1"
  [ -n "$msg" ] && [ "$msg" != null ] || fail "$3: stdout carried no systemMessage: $1"
  assert_contains "$msg" "$2" "$3"
}

# Same, with enforcement switched on. The shipped default only warns, so every
# assertion about a BLOCKED turn end has to opt in explicitly.
run_budget_enforcing() {
  local dir=$1 payload=$2
  shift 2
  run_budget "$dir" "$payload" FM_CONTEXT_BUDGET_ENFORCE=1 "$@"
}

run_budget_channels_enforcing() {
  local dir=$1 payload=$2
  shift 2
  run_budget_channels "$dir" "$payload" FM_CONTEXT_BUDGET_ENFORCE=1 "$@"
}

# --- MEASUREMENT: the ceiling blocks and names the valve ---------------------

test_blocks_over_ceiling_and_names_the_valve() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/over-ceiling")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "with enforcement on the hook must block the turn end above the ceiling"
  assert_contains "$out" "CONTEXT BUDGET CEILING" "block banner must read as a ceiling alarm"
  assert_contains "$out" "210000" "block banner must report the measured total"
  assert_contains "$out" "180000" "block banner must report the ceiling it enforced"
  assert_contains "$out" "/stow" "the valve must name /stow"
  # The handover mechanism owns the valve; this guard reports earlier and points at
  # it. Two things it must NOT do, both retired deliberately: order the session to
  # stall until the captain acts, and tell it to clear, which a session cannot do
  # and which a handover does not need.
  assert_contains "$out" "bin/fm-handover.sh" "the valve must point at the handover mechanism that owns it"
  assert_not_contains "$out" "Clear the context" "the guard must not tell a session to clear"
  assert_not_contains "$out" "before any other work" "the guard must not order the session to stall"
  assert_contains "$out" "Do not stall the fleet" "the guard must say plainly that it does not stall the fleet"
  pass "fm-context-budget: blocks above the ceiling under enforcement and points at the handover that owns the valve"
}

# The shipped default is deliberately warning-only: the ceiling has to be
# observed in real working days before it is allowed to interrupt anyone.
test_shipped_default_warns_and_never_blocks() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/warn-only")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 0 "$status" "the shipped default must allow the turn end over the ceiling"
  assert_contains "$out" "CONTEXT BUDGET CEILING" "the default must still surface the crossing visibly"
  assert_contains "$out" "210000" "the default notice must report the measured total"
  assert_contains "$out" "/stow" "the default notice must still name the valve"
  assert_contains "$out" "does not block by default" "the default notice must say it is not blocking"
  pass "fm-context-budget: the shipped default warns at the ceiling and never blocks"
}

test_enforcement_requires_an_exact_opt_in() {
  local dir transcript status value i
  dir=$(make_primary_dir "$TMP_ROOT/enforce-optin")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  # Anything other than an exact 1 must leave the warning-only default alone, so
  # a typo can never start blocking sessions.
  # The session id is indexed rather than derived from the value under test: a
  # value like '1 ' would otherwise produce an unsafe session id, and the hook
  # would exit on identity validation long before it ever consulted ENFORCE, so
  # the row would keep passing even if the enforce check were loosened to strip
  # whitespace - exactly the typo class this row exists to pin.
  i=0
  for value in 0 '' true yes on 2 '1 '; do
    i=$((i + 1))
    run_budget "$dir" "$(stop_payload "$transcript" "sess-optin-$i")" \
      FM_CONTEXT_BUDGET_CEILING=180000 "FM_CONTEXT_BUDGET_ENFORCE=$value" >/dev/null
    status=$?
    expect_code 0 "$status" "FM_CONTEXT_BUDGET_ENFORCE='$value' must not switch enforcement on"
  done
  run_budget "$dir" "$(stop_payload "$transcript" sess-exact)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_ENFORCE=1 >/dev/null
  status=$?
  expect_code 2 "$status" "an exact FM_CONTEXT_BUDGET_ENFORCE=1 must switch enforcement on"
  pass "fm-context-budget: only an exact FM_CONTEXT_BUDGET_ENFORCE=1 switches enforcement on"
}

test_default_ceiling_is_180000() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/default-ceiling")
  transcript="$dir/transcript.jsonl"
  # One token under the shipped default ceiling must stay silent; one over must
  # reach it. Enforcement is on so the boundary reads as 0 against 2.
  write_transcript "$transcript" 179999
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "179,999 tokens must not reach the shipped default ceiling"
  write_transcript "$transcript" 180000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-2)" FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 2 "$status" "180,000 tokens must reach the shipped default ceiling"
  assert_contains "$out" "180000" "the shipped default ceiling must be 180000"
  pass "fm-context-budget: the shipped default ceiling is an absolute 180,000 tokens"
}

# A multi-block assistant turn writes several JSONL lines, each carrying that
# turn's own CUMULATIVE usage rather than a slice of it. Taking the last entry
# therefore measures the turn exactly, with no dedupe step: summing the blocks
# would report a multiple, and taking the first would report a stale prefix.
# Both wrong answers are pinned here, so the test cannot pass vacuously.
test_multi_block_turn_measures_the_last_block_not_the_sum() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/multi-block")
  transcript="$dir/transcript.jsonl"
  # Realistic shape first: three identical blocks of one 100,000-token turn.
  # 100,000 is under the ceiling; a 300,000 sum would be far over it.
  {
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
    assistant_line 100000 req-multi
  } > "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "three blocks of one 100,000-token turn must measure 100,000, not 300,000"
  [ -z "$out" ] || fail "hook summed the blocks of one turn: $out"
  # Now pin take-LAST specifically: a growing turn whose final block is the only
  # one over the ceiling. Taking the first block would measure 100,000 and stay
  # silent; summing would report 320,000; only take-last reports 120,000.
  {
    assistant_line 100000 req-grow
    assistant_line 100000 req-grow
    assistant_line 120000 req-grow
  } > "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-grow)" \
    FM_CONTEXT_BUDGET_CEILING=110000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 2 "$status" "the final block of a multi-block turn must be the measured total"
  assert_contains "$out" "120000 tokens" "the measurement must be the last block, not the first or the sum"
  pass "fm-context-budget: a multi-block turn measures its last block, never the sum or the first"
}

# Correctness rule: compaction RESETS the running total. A max implementation
# would latch the pre-compaction peak and suppress the guard forever after.
test_takes_last_never_max_across_compaction() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/last-not-max")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 240000 30000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "a post-compaction 30,000 must be measured, not the stale 240,000 peak"
  [ -z "$out" ] || fail "hook fired on a stale pre-compaction peak: $out"
  pass "fm-context-budget: takes the last total, never the max, so compaction cannot disable the guard"
}

# Correctness rule: isSidechain==true marks subagent turns. A single inflated
# sidechain entry must never drag the primary over the ceiling.
test_excludes_sidechain_entries() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/sidechain")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  assistant_line 20000 req-main >> "$transcript"
  assistant_line 999999 req-sub true >> "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 0 "$status" "a 999,999-token sidechain entry must not count toward the primary total"
  [ -z "$out" ] || fail "hook counted a sidechain entry: $out"
  pass "fm-context-budget: excludes isSidechain entries so subagent turns never inflate the primary"
}

test_measures_only_assistant_entries() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/assistant-only")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  assistant_line 210000 req-a >> "$transcript"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' >> "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a trailing user entry must not hide the last assistant measurement"
  assert_contains "$out" "210000" "the last assistant usage must still be measured"
  pass "fm-context-budget: measures the last assistant usage past trailing non-assistant entries"
}

test_sums_all_four_usage_fields() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/four-fields")
  transcript="$dir/transcript.jsonl"
  printf '{"type":"assistant","requestId":"req-1","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":4000,"output_tokens":8000}}}\n' \
    > "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=15000 FM_CONTEXT_BUDGET_HEADROOM=0); status=$?
  expect_code 2 "$status" "1000+2000+4000+8000 must measure 15000 and reach a 15000 ceiling"
  assert_contains "$out" "15000 tokens" "all four usage fields must be summed"
  pass "fm-context-budget: sums input, cache creation, cache read, and output tokens"
}

# --- STAGES: one policy number, one derived advisory -------------------------

test_advisory_warns_without_blocking() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/advisory")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "the advisory stage must never block the turn end"
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "advisory must print the banner"
  assert_contains "$out" "20000 tokens of headroom" "advisory must report remaining headroom"
  assert_contains "$out" "/stow" "advisory must still name the valve"
  pass "fm-context-budget: warns without blocking between the derived advisory and the ceiling"
}

test_advisory_is_derived_from_ceiling_minus_headroom() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/derived")
  transcript="$dir/transcript.jsonl"
  # 149,999 is below 180000-30000 and must stay silent; 150,000 is exactly the
  # derived advisory and must warn. No second policy number is configurable.
  write_transcript "$transcript" 149999
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "below the derived advisory must exit 0"
  [ -z "$out" ] || fail "hook warned below the derived advisory: $out"
  write_transcript "$transcript" 150000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-derived)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "at the derived advisory must still exit 0"
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "the advisory point must be ceiling minus headroom"
  pass "fm-context-budget: the advisory is derived as ceiling minus headroom, not a second threshold"
}

test_advisory_prints_once_per_episode() {
  local dir transcript first second status
  dir=$(make_primary_dir "$TMP_ROOT/advisory-dedup")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  first=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000)
  assert_contains "$first" "CONTEXT BUDGET ADVISORY" "the first advisory turn must print the banner"
  second=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000); status=$?
  expect_code 0 "$status" "a repeat advisory turn must still exit 0"
  [ -z "$second" ] || fail "advisory banner repeated inside one episode: $second"
  pass "fm-context-budget: the advisory banner prints once per episode, like bin/fm-guard.sh"
}

test_advisory_rearms_after_dropping_below() {
  local dir transcript out
  dir=$(make_primary_dir "$TMP_ROOT/advisory-rearm")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  # A clear or compaction drops the measurement back under the advisory.
  write_transcript "$transcript" 30000
  run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  write_transcript "$transcript" 160000
  out=$(run_budget "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000)
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" "a later episode must re-arm the advisory banner"
  pass "fm-context-budget: the advisory re-arms once the session drops back below it"
}

test_silent_well_below_advisory() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/below")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 31710
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_code 0 "$status" "an ordinary session must exit 0"
  [ -z "$out" ] || fail "hook produced output for an ordinary session: $out"
  pass "fm-context-budget: completely silent for a session well below the advisory"
}

test_ceiling_notice_prints_once_per_episode() {
  local dir transcript first second status
  dir=$(make_primary_dir "$TMP_ROOT/ceiling-dedup")
  transcript="$dir/transcript.jsonl"
  # Cross the advisory first, so the advisory notice is already spent. Crossing
  # into the ceiling is a DIFFERENT stage and must still produce one notice.
  write_transcript "$transcript" 160000
  first=$(run_budget "$dir" "$(stop_payload "$transcript" sess-cn)" FM_CONTEXT_BUDGET_CEILING=180000)
  assert_contains "$first" "CONTEXT BUDGET ADVISORY" "the advisory stage must warn first"
  write_transcript "$transcript" 210000
  first=$(run_budget "$dir" "$(stop_payload "$transcript" sess-cn)" FM_CONTEXT_BUDGET_CEILING=180000)
  assert_contains "$first" "CONTEXT BUDGET CEILING" "crossing into the ceiling stage must warn again"
  second=$(run_budget "$dir" "$(stop_payload "$transcript" sess-cn)" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 0 "$status" "a repeat ceiling turn must still exit 0 under the shipped default"
  [ -z "$second" ] || fail "ceiling notice repeated inside one episode: $second"
  pass "fm-context-budget: the warning-only ceiling notice is its own stage and prints once per episode"
}

# A session oscillating across the ceiling alternates the recorded stage, so each
# crossing back is a new stage and prints again. That is a real defect in this
# code and a DELIBERATELY unfixed one: replayed twice over real transcripts - 189
# sessions and 41,244 turns, then 190 sessions and 41,353 turns - the condition
# occurred zero times, because sessions that reach the ceiling climb past it
# rather than hover. The measurement is also effectively monotonic inside an
# episode by arithmetic, since each total is the previous prompt plus this turn's
# output, so it can only fall on a reset and a reset already ends the episode.
# Making the stage monotonic would close this and make the shared-key instances
# strictly worse, so this test pins the CURRENT behavior and the recorded
# reasoning, and a later reader who "fixes it while they are here" fails here.
test_the_ceiling_straddle_stays_a_known_unfixed_case() {
  local dir transcript out
  dir=$(make_primary_dir "$TMP_ROOT/straddle-known")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 181000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-straddle)" FM_CONTEXT_BUDGET_CEILING=180000)
  assert_contains "$out" "CONTEXT BUDGET CEILING" "the first crossing must warn at the ceiling"
  write_transcript "$transcript" 179000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-straddle)" FM_CONTEXT_BUDGET_CEILING=180000)
  assert_contains "$out" "CONTEXT BUDGET ADVISORY" \
    "a downward crossing prints again: the known, measured, unfixed case"
  write_transcript "$transcript" 181000
  out=$(run_budget "$dir" "$(stop_payload "$transcript" sess-straddle)" FM_CONTEXT_BUDGET_CEILING=180000)
  assert_contains "$out" "CONTEXT BUDGET CEILING" "and again on the way back up"
  # The reasoning has to live where the next reader is, not only in a report.
  assert_grep 'KNOWN UNFIXED' "$ROOT/bin/fm-context-budget.sh" \
    "the straddle must be recorded in the code as a known unfixed case"
  assert_grep '41,353' "$ROOT/bin/fm-context-budget.sh" \
    "the recorded case must carry the measured numbers, not just an assertion"
  pass "fm-context-budget: the ceiling straddle stays a recorded, measured, deliberately unfixed case"
}

# --- Block-budget safety: bounded blocking, then a STICKY stand-down ---------

test_block_budget_stands_down_visibly() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/block-budget")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-budget)
  for i in 1 2; do
    out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
    expect_code 2 "$status" "block $i must still block within the budget"
  done
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
  expect_code 0 "$status" "past the block budget the turn end must be allowed, never wedged"
  assert_contains "$out" "systemMessage" "the stand-down must stay visible to the session"
  assert_contains "$out" "block budget is exhausted" "the stand-down must say why it stopped blocking"
  assert_contains "$out" "stands down" "the stand-down must say it is standing down for the session"
  assert_contains "$out" "/stow" "the stand-down must still name the valve"
  pass "fm-context-budget: bounded blocking stands down visibly instead of wedging"
}

# The core loop-safety property. The ceiling cannot clear without the captain, so
# a guard that reset its budget on the degraded allow would oscillate
# block-block-allow forever, and each forced continuation would re-run the
# handoff and grow the very context the guard exists to cap. Away mode is the
# unbounded case, because nobody is there to clear.
test_stand_down_is_sticky_for_the_rest_of_the_session() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/sticky-standdown")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-sticky)
  for i in 1 2; do
    run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  done
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
  expect_code 0 "$status" "the budget must be spent by now"
  assert_contains "$out" "systemMessage" "the stand-down must announce itself once"
  # Ten more turns, still far over the ceiling: never another block, and never
  # another word.
  for i in $(seq 1 10); do
    out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2); status=$?
    expect_code 0 "$status" "turn $i after the stand-down must not block again"
    [ -z "$out" ] || fail "the stand-down repeated itself on turn $i: $out"
  done
  pass "fm-context-budget: the stand-down is sticky and silent, never oscillating back into blocking"
}

test_block_budget_is_per_session() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/block-budget-session")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-a)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-a)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the same session must exhaust its budget"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-b)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 2 "$status" "a different session must start with a fresh block budget"
  pass "fm-context-budget: the block budget is keyed to the session, not the home"
}

# Two conditions re-arm the stand-down, and this row covers one of them: the
# measurement drops back below the advisory. The other is a compaction boundary
# newer than the one the record was written with, covered by
# test_a_new_compaction_boundary_rearms_a_spent_stand_down. Both are the same two
# conditions that re-arm the notices.
test_stand_down_rearms_below_the_advisory() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/block-reset")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the budget is spent, so this turn stands down"
  # Back under the ceiling but still inside the advisory band does NOT re-arm.
  # Only a drop BELOW the advisory point counts as the measurement clearing.
  write_transcript "$transcript" 160000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "a dip into the advisory band must not re-arm the stand-down"
  # The session takes the valve: the measurement drops back to baseline.
  write_transcript "$transcript" 30000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-r)" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 2 "$status" "dropping below the advisory must re-arm the block budget"
  pass "fm-context-budget: a measurement below the advisory re-arms the stand-down, and a dip into the advisory band does not"
}

# --- CHANNELS: every notice on a stream the runtime actually renders ----------
# Claude Code discards a successful Stop hook's stderr: the hook_success
# attachment renders as null and only the SessionStart-family events feed hook
# output into model context. A notice printed to stderr with exit 0 is therefore
# invisible to both the captain and the session, so each non-blocking stage must
# land on stdout as a systemMessage object, and only the blocking path - which
# exits 2, the one status that does deliver stderr - may use stderr.

test_advisory_notice_is_a_system_message_on_stdout() {
  local dir transcript status
  dir=$(make_primary_dir "$TMP_ROOT/chan-advisory")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 160000
  run_budget_channels "$dir" "$(stop_payload "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000
  status=$?
  expect_code 0 "$status" "the advisory must allow the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "CONTEXT BUDGET ADVISORY" \
    "the advisory must be a systemMessage on stdout"
  assert_system_message_contains "$BUDGET_STDOUT" "20000 tokens of headroom" \
    "the advisory systemMessage must report remaining headroom"
  [ -z "$BUDGET_STDERR" ] \
    || fail "the advisory wrote to stderr, which an exit-0 Stop hook discards: $BUDGET_STDERR"
  pass "fm-context-budget channels: the advisory notice is a systemMessage on stdout, never stderr"
}

test_warning_only_ceiling_notice_is_a_system_message_on_stdout() {
  local dir transcript status
  dir=$(make_primary_dir "$TMP_ROOT/chan-warn")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_channels "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  expect_code 0 "$status" "the shipped default must allow the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "CONTEXT BUDGET CEILING REACHED" \
    "the warning-only ceiling notice must be a systemMessage on stdout"
  assert_system_message_contains "$BUDGET_STDOUT" "/stow" \
    "the warning-only systemMessage must still name the valve"
  [ -z "$BUDGET_STDERR" ] \
    || fail "the shipped default wrote its only notice to a discarded channel: $BUDGET_STDERR"
  pass "fm-context-budget channels: the shipped default's ceiling notice is a systemMessage on stdout"
}

test_stand_down_notice_is_a_system_message_on_stdout() {
  local dir transcript payload status
  dir=$(make_primary_dir "$TMP_ROOT/chan-standdown")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-chan-sd)
  run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1
  status=$?
  expect_code 0 "$status" "the spent budget must allow the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "block budget is exhausted" \
    "the stand-down must be a systemMessage on stdout"
  [ -z "$BUDGET_STDERR" ] || fail "the stand-down wrote to a discarded channel: $BUDGET_STDERR"
  pass "fm-context-budget channels: the sticky stand-down announces itself on stdout"
}

# The one path that legitimately uses stderr: exit 2 IS delivered to the model.
test_block_banner_is_on_stderr_with_clean_stdout() {
  local dir transcript status
  dir=$(make_primary_dir "$TMP_ROOT/chan-block")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_channels_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  expect_code 2 "$status" "enforcement must block above the ceiling"
  assert_contains "$BUDGET_STDERR" "CONTEXT BUDGET CEILING REACHED" \
    "the blocking banner must go to stderr, which exit 2 delivers"
  assert_contains "$BUDGET_STDERR" "/stow" "the blocking banner must name the valve"
  [ -z "$BUDGET_STDOUT" ] \
    || fail "a blocking turn must not also emit a hook response on stdout: $BUDGET_STDOUT"
  pass "fm-context-budget channels: the blocking banner stays on stderr with exit 2"
}

# --- MEASUREMENT: zero-usage synthetic entries -------------------------------
# Claude Code writes one of these whenever a turn ends abnormally - a login or
# API error, an interrupt - which is exactly when this hook fires. It is the LAST
# assistant entry at that moment, so counting it would read a long session as
# empty. A real 81 MB session transcript carries 32 of them.

test_trailing_synthetic_zero_entry_does_not_hide_the_measurement() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/synthetic-measure")
  transcript="$dir/transcript.jsonl"
  {
    assistant_line 210000 req-real
    synthetic_zero_line
  } > "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000)
  status=$?
  expect_code 2 "$status" "a trailing zero-usage synthetic entry must not read as an empty session"
  assert_contains "$out" "210000" "the last POSITIVE assistant total must be the measurement"
  pass "fm-context-budget: a trailing zero-usage synthetic entry is ignored, not measured as a reset"
}

test_trailing_synthetic_zero_entry_cannot_rearm_a_spent_stand_down() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/synthetic-standdown")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-synth)
  run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the budget must be spent by now"
  assert_contains "$out" "stands down" "the stand-down must announce itself once"
  # The abnormal turn end lands: a zero-usage synthetic entry becomes the last
  # assistant entry. It must not read as a drop below the advisory, because that
  # would delete the stand-down record and re-arm blocking.
  synthetic_zero_line >> "$transcript"
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the turn that ended abnormally must not block"
  [ -z "$out" ] || fail "a synthetic zero-usage entry produced a notice: $out"
  # The session carries on and the next real turn is logged. Still over the
  # ceiling, still the same session: the stand-down must have survived.
  assistant_line 210000 req-after >> "$transcript"
  for i in 1 2 3; do
    out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
    expect_code 0 "$status" "turn $i after the synthetic entry must not block again"
    [ -z "$out" ] || fail "a synthetic zero-usage entry re-armed the stand-down on turn $i: $out"
  done
  pass "fm-context-budget: a zero-usage entry is never treated as proof the context reset"
}

# --- Record durability: identity, isolation, and write failure ----------------

test_records_are_named_per_session() {
  local dir transcript
  dir=$(make_primary_dir "$TMP_ROOT/record-naming")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-named)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  assert_present "$dir/state/.context-budget-blocks-sess-named" \
    "the block record must be keyed to the session id, not the home"
  assert_absent "$dir/state/.context-budget-blocks" \
    "a home-scoped record would alias two sessions onto one count"
  pass "fm-context-budget: the durable records are named per session id"
}

# Two primary sessions in one home is the case the home session lock reports
# rather than prevents. With one shared record each turn end of one session reset
# the other's count, so neither ever reached its budget and both blocked without
# bound. Interleaving them here pins that they no longer interact.
test_two_sessions_in_one_home_keep_separate_budgets() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/two-sessions")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-one)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null; status=$?
  expect_code 2 "$status" "session one must spend its single block"
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-two)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null; status=$?
  expect_code 2 "$status" "session two must have its own single block"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-one)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "session one's count must have survived session two's turn end"
  assert_contains "$out" "stands down" "session one must reach its own stand-down"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-two)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "session two must reach its own stand-down too"
  pass "fm-context-budget: two sessions in one home cannot wipe each other's stand-down"
}

test_missing_session_id_is_inert() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/no-session-id")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" \
    "$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")" \
    FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a payload with no session_id" "$out" "$status"
  pass "fm-context-budget: a payload with no session_id is inert, never a shared record"
}

test_unsafe_session_id_is_inert() {
  local dir transcript out status value
  dir=$(make_primary_dir "$TMP_ROOT/unsafe-session-id")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  for value in '../escape' 'a/b' 'has space' 'tab	sep'; do
    out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript" "$value")" \
      FM_CONTEXT_BUDGET_CEILING=180000); status=$?
    expect_silent_exit_zero "session_id '$value'" "$out" "$status"
  done
  # No record anywhere under the home, so no unsafe id reached a path at all.
  [ -z "$(find "$dir" -name '.context-budget-*' -print -quit)" ] \
    || fail "an unsafe session id reached the filesystem as a record path"
  pass "fm-context-budget: a session id that is not a plain filename token is inert"
}

# A record that cannot be persisted cannot bound anything, so blocking on it
# would repeat every turn end forever. The degrade is toward warning, never
# toward blocking, and it stays visible.
test_unwritable_record_degrades_to_a_visible_warning() {
  local dir transcript status
  dir=$(make_primary_dir "$TMP_ROOT/record-unwritable")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  chmod 500 "$dir/state"
  if touch "$dir/state/.writable-probe" 2>/dev/null; then
    rm -f "$dir/state/.writable-probe"
    chmod 755 "$dir/state"
    pass "fm-context-budget: skipped unwritable-record row (test host ignores mode 500)"
    return 0
  fi
  run_budget_channels_enforcing "$dir" "$(stop_payload "$transcript" sess-ro)" \
    FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  chmod 755 "$dir/state"
  expect_code 0 "$status" "an unrecordable block count must never block the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "could not be recorded" \
    "the degrade must say why it allowed the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "/stow" "the degrade must still name the valve"
  pass "fm-context-budget: a record it cannot write degrades to a visible warning, never a block"
}

# The whole state directory unwritable is the harsher shape: NEITHER record can be
# written, so nothing can be deduped and the degrade necessarily repeats. Repeating
# a visible warning is the acceptable end of this trade; blocking on a bound that
# cannot be stored is not, and going silent about a broken safety mechanism is not.
test_unwritable_state_dir_never_blocks_and_stays_visible() {
  local dir transcript payload i status
  dir=$(make_primary_dir "$TMP_ROOT/state-dir-unwritable")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-rodir)
  chmod 500 "$dir/state"
  if touch "$dir/state/.writable-probe" 2>/dev/null; then
    rm -f "$dir/state/.writable-probe"
    chmod 755 "$dir/state"
    pass "fm-context-budget: skipped unwritable-state-dir row (test host ignores mode 500)"
    return 0
  fi
  for i in 1 2 3; do
    run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000
    status=$?
    if [ "$status" -ne 0 ]; then
      chmod 755 "$dir/state"
      fail "turn $i blocked on a bound that could not be stored: expected exit 0, got $status"
    fi
    if ! printf '%s' "$BUDGET_STDOUT" | grep -q 'could not be recorded'; then
      chmod 755 "$dir/state"
      fail "turn $i went silent about a block count it could not record: $BUDGET_STDOUT"
    fi
  done
  chmod 755 "$dir/state"
  pass "fm-context-budget: an unwritable state directory never blocks and never goes silent"
}

# Plant a block record this session can READ but can never REWRITE, so the write
# failure is isolated to the block record and the notice record stays writable.
# Returns non-zero when the host ignores the mode, so the caller can skip.
plant_unwritable_block_record() {  # <dir> <session> <count>
  local file=$1/state/.context-budget-blocks-$2
  printf 'count=%s\nstanddown=0\ncompacts=0\nsession=%s\n' "$3" "$2" > "$file"
  chmod 400 "$file"
  # 2>/dev/null FIRST: bash applies redirections left to right, so a trailing one
  # would not be in place yet when the failing append reports itself.
  if printf 'probe\n' 2>/dev/null >> "$file"; then
    chmod 600 "$file"
    return 1
  fi
  return 0
}

# Plant a notice record this session can READ but can never REWRITE, so a
# write failure is isolated to the notice record while the state directory,
# the trip record, and the block record all stay writable - narrower than a
# wholly unwritable state directory. Returns non-zero when the host ignores
# the mode, so the caller can skip.
plant_unwritable_notice_record() {  # <dir> <session>
  local file=$1/state/.context-budget-notice-$2
  printf 'stage=\nunrecorded=0\nbadrecord=0\nstanddownfail=0\nnoticedegraded=0\ncompacts=0\nsession=%s\n' \
    "$2" > "$file"
  chmod 400 "$file"
  if printf 'probe\n' 2>/dev/null >> "$file"; then
    chmod 600 "$file"
    return 1
  fi
  return 0
}

# A stand-down write can fail exactly like the block-count write it neighbors.
# Claiming a durability it did not achieve would leave every later turn end
# re-reading the same unpersisted count, re-entering this branch, and
# repeating a false claim with no trace anywhere - the same failure class
# ceiling-unrecorded already closed for the count write four lines above it.
test_standdown_write_failure_leaves_a_durable_trip_and_correct_message() {
  local dir transcript payload status trips
  dir=$(make_primary_dir "$TMP_ROOT/standdown-unrecorded")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-sd-unrec)
  if ! plant_unwritable_block_record "$dir" sess-sd-unrec 2; then
    pass "fm-context-budget: skipped standdown-unrecorded row (test host ignores mode 400)"
    return 0
  fi
  run_budget_channels_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2
  status=$?
  chmod 600 "$dir/state/.context-budget-blocks-sess-sd-unrec"
  expect_code 0 "$status" "a stand-down that could not be persisted must never block the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "could not be persisted" \
    "the message must admit the stand-down did not land"
  assert_system_message_contains "$BUDGET_STDOUT" "may recur" \
    "the message must warn the stand-down may recur on later turn ends"
  if printf '%s' "$BUDGET_STDOUT" | grep -q 'now stands down for the rest of the session'; then
    fail "the message must not claim a durability the guard did not achieve: $BUDGET_STDOUT"
  fi
  assert_grep 'stage=standdown-unrecorded' "$trips" \
    "the lost stand-down flag must leave a durable trace, not only a notice that may never render"
  pass "fm-context-budget: a stand-down write failure leaves one durable trip line and an honest message"
}

# The count-not-recorded degrade is a different MESSAGE from the ceiling notice,
# and the record's single `stage` key stood for both: whichever fired first
# silenced the other for the whole episode. A safety mechanism that promises to
# tell you when it breaks and then says nothing is the worst shape available, so
# the degrade carries its own key.
test_unrecorded_degrade_is_its_own_notice_key() {
  local dir transcript payload status trips
  dir=$(make_primary_dir "$TMP_ROOT/degrade-own-key")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-degrade)
  # Spend the `ceiling` key first, exactly as a warning-only turn would.
  run_budget "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000 >/dev/null
  if ! plant_unwritable_block_record "$dir" sess-degrade 0; then
    pass "fm-context-budget: skipped degrade-key row (test host ignores mode 400)"
    return 0
  fi
  run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  chmod 600 "$dir/state/.context-budget-blocks-sess-degrade"
  expect_code 0 "$status" "an unrecordable block count must never block the turn end"
  assert_system_message_contains "$BUDGET_STDOUT" "could not be recorded" \
    "a spent ceiling notice must not silence the count-not-recorded degrade"
  [ -z "$BUDGET_STDERR" ] || fail "the degrade must not use the discarded stderr channel: $BUDGET_STDERR"
  assert_grep 'stage=ceiling-unrecorded' "$trips" \
    "the lost block bound must leave a durable trace, not only a notice that may never render"
  pass "fm-context-budget: the count-not-recorded degrade has its own notice key and survives a spent ceiling notice"
}

# Its own key, not an unconditional message: while the block record stays
# unwritable the degrade would otherwise repeat at every single turn end.
test_unrecorded_degrade_prints_once_per_episode() {
  local dir transcript payload i lines
  dir=$(make_primary_dir "$TMP_ROOT/degrade-dedup")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-dd)
  if ! plant_unwritable_block_record "$dir" sess-dd 0; then
    pass "fm-context-budget: skipped degrade-dedup row (test host ignores mode 400)"
    return 0
  fi
  run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000
  assert_system_message_contains "$BUDGET_STDOUT" "could not be recorded" \
    "the first degrade must be visible"
  for i in 1 2 3 4; do
    run_budget_channels_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_CEILING=180000
    [ -z "$BUDGET_STDOUT" ] \
      || fail "the degrade repeated on turn $i instead of printing once per episode: $BUDGET_STDOUT"
  done
  chmod 600 "$dir/state/.context-budget-blocks-sess-dd"
  lines=$(trip_count "$dir/state/.context-budget-trips" ceiling-unrecorded)
  [ "$lines" -eq 1 ] \
    || fail "the degrade trace must stay one line per episode, found $lines"
  pass "fm-context-budget: the degrade prints once per episode rather than at every turn end"
}

# An unparseable record is evidence of NOTHING. Reading it as a spent stand-down
# conflated unknown with dismissed and let a corrupt file impersonate the
# captain's dismissal, silencing the guard for the whole session.
test_unparseable_budget_record_keeps_the_guard_active() {
  local dir transcript status
  dir=$(make_primary_dir "$TMP_ROOT/record-unparseable")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  printf 'count=not-a-number\nstanddown=1\ncompacts=0\nsession=sess-bad\n' \
    > "$dir/state/.context-budget-blocks-sess-bad"
  run_budget_channels_enforcing "$dir" "$(stop_payload "$transcript" sess-bad)" \
    FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  expect_code 2 "$status" "an unparseable record must leave the guard active, not stand it down"
  assert_contains "$BUDGET_STDERR" "CONTEXT BUDGET CEILING" \
    "the still-active guard must deliver its blocking banner"
  pass "fm-context-budget: an unparseable block record is read as no record and the guard stays active"
}

# Failing toward warning is right, and failing SILENTLY is not: the parse failure
# is the only trace of a corrupt record, so it is recorded once where every other
# firing is recorded.
test_unparseable_budget_record_records_the_parse_failure() {
  local dir transcript trips
  dir=$(make_primary_dir "$TMP_ROOT/record-unparseable-log")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  printf 'count=\nstanddown=0\ncompacts=0\nsession=sess-badlog\n' \
    > "$dir/state/.context-budget-blocks-sess-badlog"
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-badlog)" \
    FM_CONTEXT_BUDGET_CEILING=180000 >/dev/null 2>&1
  assert_present "$trips" "a parse failure must leave a durable trace"
  assert_grep 'stage=record-unparseable' "$trips" \
    "the parse failure must name itself in the record"
  assert_grep 'session=sess-badlog' "$trips" "the parse failure must name the session"
  pass "fm-context-budget: an unparseable block record records the parse failure"
}

# A record that is corrupt AND cannot be rewritten is re-read at every turn end. The
# trace must stay one line per episode: the trip record is bounded, so a line per
# turn end there would crowd out the crossing history the whole warning-only
# release exists to collect.
test_unparseable_record_trace_is_bounded() {
  local dir transcript trips file i lines
  dir=$(make_primary_dir "$TMP_ROOT/record-unparseable-bounded")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  file="$dir/state/.context-budget-blocks-sess-stuck"
  write_transcript "$transcript" 210000
  printf 'count=corrupt\nstanddown=0\ncompacts=0\nsession=sess-stuck\n' > "$file"
  chmod 400 "$file"
  if printf 'probe\n' 2>/dev/null >> "$file"; then
    chmod 600 "$file"
    pass "fm-context-budget: skipped bounded-parse-failure row (test host ignores mode 400)"
    return 0
  fi
  for i in $(seq 1 6); do
    run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-stuck)" \
      FM_CONTEXT_BUDGET_CEILING=180000 >/dev/null 2>&1
  done
  chmod 600 "$file"
  lines=$(trip_count "$trips" record-unparseable)
  [ "$lines" = 1 ] \
    || fail "six turn ends on one stuck corrupt record must trace it ONCE, got $lines"
  pass "fm-context-budget: a corrupt unrewritable record is traced once, not at every turn end"
}

# Leaving the guard armed on an unparseable record must not cost the bound. If the
# record were re-read as a fresh budget at every turn end the guard would block
# forever, which is the one thing it may never do. Two paths close it: a writable
# record is rewritten on the first blocked turn and counts normally from there, and
# an unwritable one degrades to the visible warning instead of blocking.
test_unparseable_record_does_not_unbound_blocking() {
  local dir transcript payload i status blocks
  dir=$(make_primary_dir "$TMP_ROOT/record-unparseable-bound")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-nb)
  printf 'count=??\nstanddown=0\ncompacts=0\nsession=sess-nb\n' \
    > "$dir/state/.context-budget-blocks-sess-nb"
  blocks=0
  for i in $(seq 1 8); do
    run_budget_channels_enforcing "$dir" "$payload" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2
    status=$?
    [ "$status" -eq 2 ] && blocks=$((blocks + 1))
  done
  [ "$blocks" -le 2 ] \
    || fail "an unparseable record must not unbound the block budget: blocked $blocks times over 8 turns with a budget of 2"
  [ "$blocks" -ge 1 ] \
    || fail "an unparseable record must leave the guard armed enough to block at least once, blocked $blocks times"
  pass "fm-context-budget: an unparseable record leaves the guard armed without unbounding the block budget"
}

# Raising the budget mid-session must not resurrect a stand-down that was already
# spent, which a clamped count alone could not prevent.
test_raising_the_block_budget_cannot_rearm_a_spent_stand_down() {
  local dir transcript payload out status
  dir=$(make_primary_dir "$TMP_ROOT/budget-raise")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-raise)
  run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the single block must be spent"
  assert_contains "$out" "stands down" "the stand-down must be recorded"
  out=$(run_budget_enforcing "$dir" "$payload" FM_CONTEXT_BUDGET_BLOCK_BUDGET=9); status=$?
  expect_code 0 "$status" "a raised budget must not re-arm a spent stand-down"
  [ -z "$out" ] || fail "a raised budget reopened a spent stand-down: $out"
  pass "fm-context-budget: raising the block budget mid-session cannot re-arm a spent stand-down"
}

test_long_dead_records_are_pruned_and_recent_ones_kept() {
  local dir transcript
  dir=$(make_primary_dir "$TMP_ROOT/record-prune")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  printf 'count=1\nstanddown=1\nsession=sess-ancient\n' \
    > "$dir/state/.context-budget-blocks-sess-ancient"
  printf 'count=1\nstanddown=1\nsession=sess-recent\n' \
    > "$dir/state/.context-budget-blocks-sess-recent"
  touch -t 202001010000 "$dir/state/.context-budget-blocks-sess-ancient"
  run_budget_enforcing "$dir" "$(stop_payload "$transcript" sess-live)" \
    FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  assert_absent "$dir/state/.context-budget-blocks-sess-ancient" \
    "a record too old for any live session must be pruned"
  assert_present "$dir/state/.context-budget-blocks-sess-recent" \
    "a recent record may still belong to a live session and must be kept"
  assert_present "$dir/state/.context-budget-blocks-sess-live" \
    "this session's own record must survive its own prune"
  pass "fm-context-budget: per-session records prune only when too old to belong to a live session"
}

# --- Compaction is the other proof of a genuine reset -------------------------
# A compaction does NOT change session_id, so a session-keyed stand-down survives
# it. When the post-compaction total is still above the advisory the drop-below
# rule never fires either, and the guard would stay stood down for the rest of a
# session that had genuinely reset. The boundary marker closes that.

test_a_new_compaction_boundary_rearms_a_spent_stand_down() {
  local dir transcript payload out status
  dir=$(make_primary_dir "$TMP_ROOT/compact-rearm")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 400000
  payload=$(stop_payload "$transcript" sess-compact)
  run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null; status=$?
  expect_code 2 "$status" "the single block must be spent first"
  out=$(run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the stand-down must be recorded"
  assert_contains "$out" "stands down" "the stand-down must announce itself once"
  # The session compacts. The post-compaction total is far smaller but still over
  # the ceiling, so nothing else in this guard could tell a real reset happened.
  {
    compact_boundary_line 400000 210000
    assistant_line 210000 req-post
  } >> "$transcript"
  out=$(run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 2 "$status" "a new compaction boundary must re-arm the spent stand-down"
  assert_contains "$out" "210000" "the post-compaction total must be the measurement"
  pass "fm-context-budget: a new compaction boundary re-arms a session-keyed stand-down"
}

# The boundary re-arms ONCE. A boundary already accounted for in the record must
# not clear it again on every later turn end, or the stand-down would never stick
# for the rest of a compacted session.
test_an_already_recorded_compaction_boundary_does_not_rearm_again() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/compact-once")
  transcript="$dir/transcript.jsonl"
  {
    compact_boundary_line 400000 210000
    assistant_line 210000 req-post
  } > "$transcript"
  payload=$(stop_payload "$transcript" sess-compact-once)
  run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null; status=$?
  expect_code 2 "$status" "the first turn over the ceiling must block"
  out=$(run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the budget must be spent"
  assert_contains "$out" "stands down" "the stand-down must be recorded"
  for i in 1 2 3; do
    out=$(run_budget_enforcing "$dir" "$payload" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
    expect_code 0 "$status" "turn $i must not block on a boundary already accounted for"
    [ -z "$out" ] || fail "an old compaction boundary re-armed the stand-down on turn $i: $out"
  done
  pass "fm-context-budget: only a NEW compaction boundary re-arms, never one already recorded"
}

# Rule 2 - exclude sidechains - governs the WHOLE measurement pass, and the
# boundary tally became part of that pass the moment a boundary started clearing
# records. A subagent-marked boundary must therefore count for nothing: were it
# tallied, the inflated count would delete both records and put a spent
# stand-down back into service, reopening exactly the oscillation the sticky
# record exists to end.
test_a_sidechain_compaction_boundary_never_rearms_a_stand_down() {
  local dir transcript payload out status i
  dir=$(make_primary_dir "$TMP_ROOT/compact-sidechain")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 400000
  payload=$(stop_payload "$transcript" sess-compact-sidechain)
  run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1 >/dev/null; status=$?
  expect_code 2 "$status" "the single block must be spent first"
  out=$(run_budget_enforcing "$dir" "$payload" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
  expect_code 0 "$status" "the stand-down must be recorded"
  assert_contains "$out" "stands down" "the stand-down must announce itself once"
  # A subagent's own compaction boundary, reaching the parent transcript. The
  # primary's context did not reset, so nothing here is evidence of one.
  compact_boundary_line 400000 210000 true >> "$transcript"
  for i in 1 2 3; do
    out=$(run_budget_enforcing "$dir" "$payload" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=1); status=$?
    expect_code 0 "$status" "a sidechain boundary must not re-arm the stand-down on turn $i"
    [ -z "$out" ] || fail "a sidechain compaction boundary re-armed the stand-down on turn $i: $out"
  done
  pass "fm-context-budget: a sidechain compaction boundary never re-arms a stand-down"
}

# --- The trip record: write-only observation ----------------------------------
# The shipped default's only rendered output is a systemMessage, and rendering is
# not something this repo controls: a controlled experiment confirmed 30
# emissions with zero renders. Counting how often the ceiling is actually crossed
# therefore cannot depend on the notice, so every stage firing is also appended to
# a durable file. That file is write-only by contract.

test_trip_record_captures_each_stage_firing() {
  local dir transcript trips
  dir=$(make_primary_dir "$TMP_ROOT/trip-record")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 160000
  run_budget "$dir" "$(stop_payload "$transcript" sess-trip)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  write_transcript "$transcript" 210000
  run_budget "$dir" "$(stop_payload "$transcript" sess-trip)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  assert_present "$trips" "a stage firing must leave a durable trip line"
  assert_grep 'stage=advisory total=160000 ceiling=180000 advisory=150000' "$trips" \
    "the advisory trip must record how big the session was and against which thresholds"
  assert_grep 'stage=ceiling total=210000' "$trips" \
    "the ceiling trip must record the crossing too"
  assert_grep 'session=sess-trip' "$trips" "a trip must name the session that made it"
  assert_grep 'enforce=0' "$trips" "a trip must record whether enforcement was on"
  pass "fm-context-budget: every stage firing appends a durable trip line"
}

test_trip_record_is_not_written_below_the_advisory() {
  local dir transcript
  dir=$(make_primary_dir "$TMP_ROOT/trip-quiet")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 31710
  run_budget "$dir" "$(stop_payload "$transcript" sess-quiet)" >/dev/null
  assert_absent "$dir/state/.context-budget-trips" \
    "an ordinary session below the advisory must leave no trip at all"
  pass "fm-context-budget: a session below the advisory records no trip"
}

test_trip_record_stays_bounded() {
  local dir transcript trips i bytes lines
  dir=$(make_primary_dir "$TMP_ROOT/trip-bounded")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  : > "$trips"
  for i in $(seq 1 4000); do
    printf '2026-01-01T00:00:00Z stage=ceiling total=210000 ceiling=180000 advisory=150000 enforce=0 session=sess-old-%04d\n' "$i" >> "$trips"
  done
  bytes=$(wc -c < "$trips" | tr -d ' ')
  [ "$bytes" -gt 131072 ] || fail "fixture must exceed the byte cap to exercise the trim, got $bytes"
  run_budget "$dir" "$(stop_payload "$transcript" sess-bound)" \
    FM_CONTEXT_BUDGET_CEILING=180000 >/dev/null
  bytes=$(wc -c < "$trips" | tr -d ' ')
  lines=$(wc -l < "$trips" | tr -d ' ')
  [ "$bytes" -le 131072 ] || fail "the trip record grew past its byte cap: $bytes"
  [ "$lines" -le 501 ] || fail "the trip record kept more than the most recent entries: $lines"
  assert_grep 'session=sess-bound' "$trips" "the newest trip must survive the trim"
  assert_no_grep 'session=sess-old-0001' "$trips" "the oldest trips must be the ones dropped"
  assert_grep 'session=sess-old-4000' "$trips" "the most recent old trips must be kept"
  pass "fm-context-budget: the trip record is bounded and keeps the most recent entries"
}

# Count the trip lines for one stage. grep -c exits non-zero on no match, which is
# a legitimate answer of zero here rather than an error.
trip_count() {  # <file> <stage>
  grep -c "stage=$2 " "$1" 2>/dev/null || true
}

# The captain asked how OFTEN the guard fires. A line per turn end above the
# advisory answers a different question - how long a session lingered there - and
# at a steady measurement it inflates the count by the length of the episode.
# Measured before this was corrected: 12 turn ends at a steady 160,000 produced 12
# trip lines and exactly one notice.
test_trip_record_counts_crossings_not_turn_ends() {
  local dir transcript trips i lines
  dir=$(make_primary_dir "$TMP_ROOT/trip-crossings")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 160000
  for i in $(seq 1 12); do
    run_budget "$dir" "$(stop_payload "$transcript" sess-cross)" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  done
  lines=$(trip_count "$trips" advisory)
  [ "$lines" = 1 ] \
    || fail "12 turn ends at one steady measurement must record ONE advisory crossing, got $lines"
  # A genuine re-crossing is a second crossing and must be counted as one.
  write_transcript "$transcript" 30000
  run_budget "$dir" "$(stop_payload "$transcript" sess-cross)" \
    FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  write_transcript "$transcript" 160000
  for i in 1 2 3; do
    run_budget "$dir" "$(stop_payload "$transcript" sess-cross)" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 >/dev/null
  done
  lines=$(trip_count "$trips" advisory)
  [ "$lines" = 2 ] \
    || fail "a genuine re-crossing after dropping below the advisory must add exactly one line, got $lines"
  pass "fm-context-budget: the trip record counts crossings, not turn ends above the advisory"
}

# The enforcing ceiling prints its banner on EVERY blocked turn, so it cannot
# dedupe through the notice path. The crossing itself must still be recorded once,
# or switching enforcement on would lose the observation the trip record exists for.
test_ceiling_crossing_is_tripped_once_under_enforcement() {
  local dir transcript trips payload i lines
  dir=$(make_primary_dir "$TMP_ROOT/trip-enforce")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  payload=$(stop_payload "$transcript" sess-trip-enf)
  # Two blocked turns, the stand-down turn, then three stood-down turns.
  for i in $(seq 1 6); do
    run_budget_enforcing "$dir" "$payload" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_BLOCK_BUDGET=2 >/dev/null
  done
  assert_present "$trips" "the enforcing ceiling must still record its crossing"
  lines=$(trip_count "$trips" ceiling)
  [ "$lines" = 1 ] \
    || fail "six enforcing turn ends over one ceiling crossing must record ONE line, got $lines"
  pass "fm-context-budget: an enforced ceiling crossing is recorded exactly once"
}

# The notice record's own write can fail while the state directory and the
# trip and block records stay writable - narrower than a wholly unwritable
# state directory. Losing the per-episode dedup key there must not reopen the
# trip-record inflation commit a9fb47f removed: the malfunction gets its own
# bounded trace, and a fallback marker restores the "once per crossing"
# promise without ever reading a decision back out of the write-only trip
# record. This fires above the advisory regardless of enforcement, so it is
# exercised here in the shipped default (warning-only) mode, matching the
# reported reproduction.
test_unwritable_notice_file_restores_dedup_and_traces_the_malfunction() {
  local dir transcript trips i lines
  dir=$(make_primary_dir "$TMP_ROOT/notice-unwritable")
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  write_transcript "$transcript" 210000
  if ! plant_unwritable_notice_record "$dir" sess-notice-deg; then
    pass "fm-context-budget: skipped unwritable-notice-file row (test host ignores mode 400)"
    return 0
  fi
  for i in $(seq 1 5); do
    run_budget "$dir" "$(stop_payload "$transcript" sess-notice-deg)" \
      FM_CONTEXT_BUDGET_CEILING=180000 >/dev/null
  done
  chmod 600 "$dir/state/.context-budget-notice-sess-notice-deg"
  lines=$(trip_count "$trips" ceiling)
  [ "$lines" = 1 ] \
    || fail "five turn ends over one crossing with an unwritable notice file must record ONE ceiling line, got $lines"
  lines=$(trip_count "$trips" notice-unwritable)
  [ "$lines" = 1 ] \
    || fail "the notice write failure itself must be traced exactly once, got $lines"
  assert_present "$dir/state/.context-budget-notice-degraded-sess-notice-deg" \
    "a fallback marker must record the dedup key the primary notice file could not hold"
  pass "fm-context-budget: an unwritable notice file traces its own failure once and a fallback marker restores per-crossing dedup"
}

# The property that keeps the trip record outside the record loss-path class: it
# is never read back to decide anything, so losing or corrupting it cannot change
# a single decision. Replay one identical scripted session three ways and compare.
trip_influence_replay() {  # <dir> <mode: keep|delete|corrupt>
  local dir=$1 mode=$2 transcript payload trips step status
  transcript="$dir/transcript.jsonl"
  trips="$dir/state/.context-budget-trips"
  payload=$(stop_payload "$transcript" sess-influence)
  write_transcript "$transcript" 160000
  for step in advisory advisory-repeat block-1 block-2 standdown quiet-1 quiet-2; do
    case "$mode" in
      delete) rm -f "$trips" ;;
      corrupt) printf '\0\0not a trip line at all\0\0' > "$trips" ;;
    esac
    case "$step" in
      block-1) write_transcript "$transcript" 210000 ;;
    esac
    run_budget_channels_enforcing "$dir" "$payload" \
      FM_CONTEXT_BUDGET_CEILING=180000 FM_CONTEXT_BUDGET_HEADROOM=30000 \
      FM_CONTEXT_BUDGET_BLOCK_BUDGET=2
    status=$?
    printf '%s exit=%s out=%s err=%s\n' "$step" "$status" "$BUDGET_STDOUT" "$BUDGET_STDERR"
  done
}

test_trip_record_never_influences_a_decision() {
  local keep deleted corrupted
  keep=$(trip_influence_replay "$(make_primary_dir "$TMP_ROOT/trip-influence-keep")" keep)
  deleted=$(trip_influence_replay "$(make_primary_dir "$TMP_ROOT/trip-influence-del")" delete)
  corrupted=$(trip_influence_replay "$(make_primary_dir "$TMP_ROOT/trip-influence-bad")" corrupt)
  [ "$keep" = "$deleted" ] \
    || fail "deleting the trip record changed behavior:\n--- kept ---\n$keep\n--- deleted ---\n$deleted"
  [ "$keep" = "$corrupted" ] \
    || fail "corrupting the trip record changed behavior:\n--- kept ---\n$keep\n--- corrupted ---\n$corrupted"
  assert_contains "$keep" "exit=2" "the replay must actually reach the blocking path"
  assert_contains "$keep" "stands down" "the replay must actually reach the stand-down"
  pass "fm-context-budget: the trip record is write-only and can never change a decision"
}

# --- DEGRADATION: the eight rows, every one a silent exit 0 ------------------

expect_silent_exit_zero() {
  local label=$1 out=$2 status=$3
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label produced output: $out"
}

test_degrades_on_empty_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-empty")
  out=$(run_budget "$dir" ""); status=$?
  expect_silent_exit_zero "empty stdin" "$out" "$status"
  pass "fm-context-budget degradation: empty stdin is a silent exit 0"
}

test_degrades_on_malformed_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-malformed")
  out=$(run_budget "$dir" 'not json at all {{{'); status=$?
  expect_silent_exit_zero "malformed stdin" "$out" "$status"
  pass "fm-context-budget degradation: malformed stdin is a silent exit 0"
}

test_degrades_without_transcript_path() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nopath")
  out=$(run_budget "$dir" '{"session_id":"s","stop_hook_active":false}'); status=$?
  expect_silent_exit_zero "a payload with no transcript_path" "$out" "$status"
  pass "fm-context-budget degradation: a payload with no transcript_path is a silent exit 0"
}

test_degrades_on_missing_transcript_file() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-missing")
  out=$(run_budget "$dir" "$(stop_payload "$dir/not-there.jsonl")"); status=$?
  expect_silent_exit_zero "a missing transcript file" "$out" "$status"
  pass "fm-context-budget degradation: a missing transcript file is a silent exit 0"
}

test_degrades_on_unreadable_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-unreadable")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  chmod 000 "$transcript"
  if [ -r "$transcript" ]; then
    chmod 644 "$transcript"
    pass "fm-context-budget degradation: skipped unreadable-transcript row (test host ignores mode 000)"
    return 0
  fi
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  chmod 644 "$transcript"
  expect_silent_exit_zero "an unreadable transcript" "$out" "$status"
  pass "fm-context-budget degradation: an unreadable transcript is a silent exit 0"
}

test_degrades_on_transcript_without_assistant_usage() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nousage")
  transcript="$dir/transcript.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$transcript"
  printf '{"type":"summary","summary":"a compaction summary"}\n' >> "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "a transcript with no assistant usage" "$out" "$status"
  pass "fm-context-budget degradation: a transcript with no assistant usage is a silent exit 0"
}

test_degrades_on_corrupt_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-corrupt")
  transcript="$dir/transcript.jsonl"
  printf 'this is not json\n{"type":"assist\n\0\0binary\n' > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "a corrupt transcript" "$out" "$status"
  pass "fm-context-budget degradation: a corrupt transcript is a silent exit 0"
}

test_degrades_on_empty_transcript() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-emptyfile")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  out=$(run_budget "$dir" "$(stop_payload "$transcript")"); status=$?
  expect_silent_exit_zero "an empty transcript" "$out" "$status"
  pass "fm-context-budget degradation: an empty transcript file is a silent exit 0"
}

test_degrades_without_jq() {
  local dir transcript fakebin tool tool_path out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-nojq")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  fakebin=$(fm_fakebin "$TMP_ROOT/deg-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname sed rm; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '%s' "$(stop_payload "$transcript")" | PATH="$fakebin" \
    bash "$dir/bin/fm-context-budget.sh" --claude 2>&1); status=$?
  expect_silent_exit_zero "a host without jq" "$out" "$status"
  pass "fm-context-budget degradation: a host without jq is a silent exit 0"
}

# A line that is SYNTACTICALLY valid JSON but not an object is the corruption the
# corrupt-transcript row cannot reach: it parses fine, so it survives into the
# filter, where a lookup like .isSidechain on a string would be a jq error.
#
# What this row can and cannot pin, stated plainly. With jq -R every line is its
# own input, so such an error is reported for that line and the next line still
# runs; it does NOT abort the pass, and deleting select(type == "object") from the
# reader would not change any assertion below. What is pinned is the observable
# contract: non-object lines are skipped wherever they sit, a later assistant
# entry is still measured, and the reader leaks no diagnostic onto the hook's own
# stderr - the channel the blocking path owns.
test_valid_json_non_object_lines_are_skipped() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-scalar")
  transcript="$dir/transcript.jsonl"
  # Non-object lines both before and after the entry that must be measured, so a
  # reader that stopped at the first one would report the wrong number.
  {
    assistant_line 100000 req-early
    printf '"a bare string line"\n'
    printf '42\n'
    printf 'null\n'
    printf 'true\n'
    printf '["an","array"]\n'
    assistant_line 210000 req-late
    printf '"trailing bare string"\n'
  } > "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a valid-JSON non-object line must not hide the measurement"
  assert_contains "$out" "210000" "the last assistant entry past the non-object lines must be measured"
  assert_not_contains "$out" "100000" "a non-object line must not freeze the measurement at an earlier entry"
  # Same transcript under the shipped default, where the hook's stderr must be
  # empty: a jq diagnostic escaping onto it would be indistinguishable from the
  # blocking banner's channel.
  run_budget_channels "$dir" "$(stop_payload "$transcript" sess-scalar-chan)" \
    FM_CONTEXT_BUDGET_CEILING=180000
  status=$?
  expect_code 0 "$status" "the shipped default must allow this turn end"
  [ -z "$BUDGET_STDERR" ] \
    || fail "the reader leaked a diagnostic onto the hook's stderr: $BUDGET_STDERR"
  pass "fm-context-budget: valid-JSON non-object lines are skipped without disturbing the measurement"
}

# A truncated final line is the realistic corruption: the transcript is written
# as the session runs. The measurement must fall back to the last line that
# parsed rather than aborting or reporting a wrong number.
test_truncated_last_line_measures_last_valid_entry() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/deg-truncated")
  transcript="$dir/transcript.jsonl"
  assistant_line 210000 req-good > "$transcript"
  printf '{"type":"assistant","requestId":"req-half","message":{"usa' >> "$transcript"
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a half-written final line must not hide the last complete measurement"
  assert_contains "$out" "210000" "the last parseable assistant entry must be measured"
  pass "fm-context-budget: a truncated final line falls back to the last entry that parsed"
}

# --- SCOPE: primary and secondmate bind, crew subagent worktrees stay inert ---

test_active_in_main_primary() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/scope-primary")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "the main primary home must be guarded"
  pass "fm-context-budget scope: active in the main primary home"
}

test_active_in_secondmate_home() {
  local dir transcript out status
  dir=$(make_secondmate_dir "$TMP_ROOT/scope-secondmate")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a secondmate runs its own primary session and must be guarded"
  assert_contains "$out" "CONTEXT BUDGET CEILING" "the secondmate block must carry the same banner"
  pass "fm-context-budget scope: active in a marked secondmate home"
}

test_active_in_treehouse_leased_secondmate_home() {
  local base dir transcript out status
  base="$TMP_ROOT/scope-sm-linked-base"
  dir="$TMP_ROOT/scope-sm-linked"
  fm_git_worktree "$base" "$dir" fm/context-budget-secondmate-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_code 2 "$status" "a treehouse-leased secondmate home is a linked worktree but still a primary"
  pass "fm-context-budget scope: active in a treehouse-leased secondmate home"
}

test_inert_in_crewmate_worktree() {
  local base dir transcript out status
  base="$TMP_ROOT/scope-crew-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/scope-crew")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 999999
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a crewmate task worktree" "$out" "$status"
  pass "fm-context-budget scope: inert in a linked crewmate worktree, whatever its context size"
}

test_inert_in_secondmate_child_worktree() {
  local home dir transcript out status
  home=$(make_secondmate_dir "$TMP_ROOT/scope-sm-parent")
  dir="$TMP_ROOT/scope-sm-child"
  git -C "$home" worktree add --quiet -b fm/context-budget-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 999999
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a secondmate's own child task worktree" "$out" "$status"
  pass "fm-context-budget scope: inert in a secondmate's own child task worktree"
}

test_inert_without_state_dir() {
  local dir transcript out status
  dir="$TMP_ROOT/scope-nostate"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_budget_scripts "$dir"
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  out=$(run_budget_enforcing "$dir" "$(stop_payload "$transcript")" FM_CONTEXT_BUDGET_CEILING=180000); status=$?
  expect_silent_exit_zero "a checkout with no state directory" "$out" "$status"
  pass "fm-context-budget scope: inert without an effective state directory"
}

# --- Registration and cost ---------------------------------------------------

test_settings_registers_the_stop_hook() {
  local settings count command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  count=$(jq -r '[.hooks.Stop[].hooks[] | select(.command | test("fm-context-budget\\.sh"))] | length' "$settings")
  [ "$count" -eq 1 ] || fail "expected exactly one context-budget Stop hook, found $count"
  command=$(jq -r '.hooks.Stop[].hooks[] | select(.command | test("fm-context-budget\\.sh")) | .command' "$settings")
  assert_contains "$command" 'CLAUDE_PROJECT_DIR' "the Stop hook must anchor through CLAUDE_PROJECT_DIR"
  assert_contains "$command" '--claude' "the Stop hook must run in Claude mode"
  # Four siblings now, and the exact set matters: the session pulse arrived
  # alongside this guard and both measure context on the same event, so a rebase
  # that dropped either one would still have produced a working hook array.
  jq -e '[.hooks.Stop[].hooks[]] | length == 4' "$settings" >/dev/null \
    || fail "Stop must stack exactly four hooks: turn-end guard, session pulse, context budget, auto-arm"
  for command in fm-turnend-guard fm-session-pulse fm-context-budget fm-claude-stop-autoarm; do
    jq -e --arg c "$command" '[.hooks.Stop[].hooks[] | select(.command | test($c))] | length == 1' "$settings" >/dev/null \
      || fail "Stop must register exactly one $command hook"
  done
  # The auto-arm stays last: it rewakes the session, so anything after it would run
  # against a turn end that has already been handed on.
  jq -e '[.hooks.Stop[].hooks[].command] | last | test("fm-claude-stop-autoarm")' "$settings" >/dev/null \
    || fail "the auto-arm hook must stay last in the Stop array"
  pass ".claude/settings.json: registers the context-budget guard as one of four sibling Stop hooks"
}

test_hook_does_not_fold_into_the_turnend_guard() {
  assert_no_grep 'fm-context-budget' "$ROOT/bin/fm-turnend-guard.sh" \
    "the turn-end guard must keep owning exactly one predicate"
  assert_no_grep 'transcript_path' "$ROOT/bin/fm-turnend-guard.sh" \
    "context measurement must not leak into the turn-end guard"
  pass "one-owner rule: the context budget is a separate owner from the turn-end guard"
}

test_hook_never_injects_a_command() {
  local script="$ROOT/bin/fm-context-budget.sh"
  assert_no_grep 'fm-send.sh' "$script" "the guard must never type into a pane"
  assert_no_grep 'tmux ' "$script" "the guard must never drive a terminal directly"
  assert_no_grep 'fm-spawn.sh' "$script" "the guard must never spawn a replacement agent"
  pass "settled decision: the guard only instructs, it never injects a command or spawns an agent"
}

test_requires_claude_mode_and_stays_inert_otherwise() {
  local dir transcript out status
  dir=$(make_primary_dir "$TMP_ROOT/mode")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" 210000
  # Enforcement is on throughout: mode gating must win over it, not the reverse.
  out=$(printf '%s' "$(stop_payload "$transcript")" | FM_CONTEXT_BUDGET_ENFORCE=1 FM_HOME="$dir" \
    bash "$dir/bin/fm-context-budget.sh" 2>&1); status=$?
  expect_code 0 "$status" "a bare invocation must never block; only claude is wired in this slice"
  assert_contains "$out" "usage:" "a bare invocation must say which mode it needs"
  out=$(printf '%s' "$(stop_payload "$transcript")" | FM_CONTEXT_BUDGET_ENFORCE=1 FM_HOME="$dir" \
    bash "$dir/bin/fm-context-budget.sh" --codex 2>&1); status=$?
  expect_code 0 "$status" "an unsupported harness mode must be inert, never a blocking usage error"
  pass "fm-context-budget: claude is the only wired mode, and every other invocation is inert"
}

test_help_prints_the_header_only() {
  local out
  out=$(bash "$ROOT/bin/fm-context-budget.sh" --help 2>&1)
  assert_contains "$out" "Context-budget guardrail" "--help must print the header contract"
  assert_contains "$out" "docs/context-budget.md" "--help must point at the owning doc"
  assert_not_contains "$out" "set -u" "--help must stop at the header and never leak script body"
  assert_not_contains "$out" "SCRIPT_DIR=" "--help must not leak implementation lines"
  pass "fm-context-budget: --help prints the header contract and no script body"
}

# A wall-clock bound over a fixture small enough to build in a test cannot
# distinguish a streaming reader from a slurping one; the difference only shows
# on a transcript far larger than any hermetic fixture. The structural assertion
# is the real regression guard, and the timing bound is a smoke check on top.
test_measurement_never_slurps_the_transcript() {
  local script="$ROOT/bin/fm-context-budget.sh" passes
  assert_no_grep 'jq -s' "$script" \
    "the reader must stream the transcript, never slurp it into one array"
  assert_no_grep 'jq --slurp' "$script" \
    "the reader must stream the transcript, never slurp it into one array"
  passes=$(grep -c '^[^#]*jq -R' "$script" || true)
  [ "$passes" -eq 1 ] \
    || fail "the transcript must be parsed by exactly one pass, not $passes"
  pass "fm-context-budget: the measurement is one streaming pass at constant memory"
}

test_hook_runs_fast() {
  local dir transcript i started elapsed
  dir=$(make_primary_dir "$TMP_ROOT/fast")
  transcript="$dir/transcript.jsonl"
  : > "$transcript"
  for i in $(seq 1 400); do
    assistant_line $((30000 + i)) "req-$i" >> "$transcript"
  done
  started=$(date +%s)
  run_budget "$dir" "$(stop_payload "$transcript")" >/dev/null
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 5 ] || fail "hook took ${elapsed}s over a 400-turn transcript; it runs on every turn end"
  pass "fm-context-budget: one measurement pass stays cheap on a long transcript"
}

test_blocks_over_ceiling_and_names_the_valve
test_shipped_default_warns_and_never_blocks
test_enforcement_requires_an_exact_opt_in
test_default_ceiling_is_180000
test_multi_block_turn_measures_the_last_block_not_the_sum
test_takes_last_never_max_across_compaction
test_excludes_sidechain_entries
test_measures_only_assistant_entries
test_sums_all_four_usage_fields
test_advisory_warns_without_blocking
test_advisory_is_derived_from_ceiling_minus_headroom
test_advisory_prints_once_per_episode
test_advisory_rearms_after_dropping_below
test_silent_well_below_advisory
test_ceiling_notice_prints_once_per_episode
test_the_ceiling_straddle_stays_a_known_unfixed_case
test_block_budget_stands_down_visibly
test_stand_down_is_sticky_for_the_rest_of_the_session
test_block_budget_is_per_session
test_stand_down_rearms_below_the_advisory
test_advisory_notice_is_a_system_message_on_stdout
test_warning_only_ceiling_notice_is_a_system_message_on_stdout
test_stand_down_notice_is_a_system_message_on_stdout
test_block_banner_is_on_stderr_with_clean_stdout
test_trailing_synthetic_zero_entry_does_not_hide_the_measurement
test_trailing_synthetic_zero_entry_cannot_rearm_a_spent_stand_down
test_records_are_named_per_session
test_two_sessions_in_one_home_keep_separate_budgets
test_missing_session_id_is_inert
test_unsafe_session_id_is_inert
test_unwritable_record_degrades_to_a_visible_warning
test_unwritable_state_dir_never_blocks_and_stays_visible
test_standdown_write_failure_leaves_a_durable_trip_and_correct_message
test_unrecorded_degrade_is_its_own_notice_key
test_unrecorded_degrade_prints_once_per_episode
test_unparseable_budget_record_keeps_the_guard_active
test_unparseable_budget_record_records_the_parse_failure
test_unparseable_record_trace_is_bounded
test_unparseable_record_does_not_unbound_blocking
test_raising_the_block_budget_cannot_rearm_a_spent_stand_down
test_long_dead_records_are_pruned_and_recent_ones_kept
test_a_new_compaction_boundary_rearms_a_spent_stand_down
test_an_already_recorded_compaction_boundary_does_not_rearm_again
test_a_sidechain_compaction_boundary_never_rearms_a_stand_down
test_trip_record_captures_each_stage_firing
test_trip_record_is_not_written_below_the_advisory
test_trip_record_stays_bounded
test_trip_record_counts_crossings_not_turn_ends
test_ceiling_crossing_is_tripped_once_under_enforcement
test_unwritable_notice_file_restores_dedup_and_traces_the_malfunction
test_trip_record_never_influences_a_decision
test_degrades_on_empty_stdin
test_degrades_on_malformed_stdin
test_degrades_without_transcript_path
test_degrades_on_missing_transcript_file
test_degrades_on_unreadable_transcript
test_degrades_on_transcript_without_assistant_usage
test_degrades_on_corrupt_transcript
test_degrades_on_empty_transcript
test_degrades_without_jq
test_valid_json_non_object_lines_are_skipped
test_truncated_last_line_measures_last_valid_entry
test_active_in_main_primary
test_active_in_secondmate_home
test_active_in_treehouse_leased_secondmate_home
test_inert_in_crewmate_worktree
test_inert_in_secondmate_child_worktree
test_inert_without_state_dir
test_settings_registers_the_stop_hook
test_hook_does_not_fold_into_the_turnend_guard
test_hook_never_injects_a_command
test_requires_claude_mode_and_stays_inert_otherwise
test_help_prints_the_header_only
test_measurement_never_slurps_the_transcript
test_hook_runs_fast
