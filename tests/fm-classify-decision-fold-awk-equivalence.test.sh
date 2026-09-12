#!/usr/bin/env bash
# tests/fm-classify-decision-fold-awk-equivalence.test.sh - equivalence tests
# for _fm_decision_fold_awk (bin/fm-classify-lib.sh), the one-pass awk
# re-derivation of the per-line bash fold that status_open_decisions and the
# cursor-invalidated full-refold branch of status_open_decisions_incremental
# now call for a full fold from byte 0 (issue #2808: the bash while-read loop
# over _fm_decision_fold_line is CPU-bound-shell-slow across a large status
# log). tests/fm-classify-decision-key.test.sh already pins many exact
# open-set values through status_open_decisions, so it now exercises the awk
# engine too and would catch a semantic regression there. This file adds the
# proof the awk rewrite itself demands: the awk engine and a bash engine built
# from the SAME still-live _fm_decision_fold_line rule must agree byte for
# byte, including at the ~330KB scale the issue reports, not just on the
# small hand-pinned cases.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-fold-awk-equivalence-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# The pre-awk whole-file fold, rebuilt here from the SAME _fm_decision_fold_line
# rule status_open_decisions itself used before this fix (and still uses for
# the incremental steady-state chunk fold, and status_key_closing_verb). This
# is the bash-engine half of the equivalence proof, not a frozen duplicate of
# removed logic - it calls the one live implementation of the fold rule.
bash_reference_fold() {  # <status-file>
  local f=$1 line resolve held open=''
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held")
  done < "$f"
  printf '%s' "$open"
}

# Assert the awk engine (status_open_decisions, and the incremental fold's
# first-ever/cursor-invalidated call, both of which route through
# _fm_decision_fold_awk) agrees byte for byte with the bash reference fold.
assert_engines_agree() {  # <status-file> <label>
  local f=$1 label=$2 want got incr
  want=$(bash_reference_fold "$f")
  got=$(status_open_decisions "$f")
  [ "$got" = "$want" ] \
    || fail "$label: awk fold diverged from the bash reference fold: got '$got' want '$want'"
  incr=$(status_open_decisions_incremental "$f")
  [ "$incr" = "$want" ] \
    || fail "$label: incremental full-refold diverged from the bash reference fold: got '$incr' want '$want'"
  pass "$label: awk engine matches the bash reference fold byte for byte"
}

# Deterministic (no $RANDOM) ~<min_bytes>-byte fixture at <path>: a realistic
# mix of routine filler plus every decision-line shape the fold must treat
# identically - both key positions, corr+key tag combinations, mid-note prose
# mentions, malformed slugs, reserved pending-reply- keys under both the
# rejected and the correct vocabulary, and repeated open/close/reopen cycles
# (round-robin close on needs-decision/blocked/captain-held so the final open
# set is large but not the whole file). Reproducible byte for byte on every
# run, so a benchmark against it is reproducible too.
gen_fixture() {  # <path> <min-bytes>
  local path=$1 min_bytes=$2 i=0 size=0
  : > "$path"
  while [ "$size" -lt "$min_bytes" ]; do
    i=$((i + 1))
    {
      printf 'working: routine progress note number %d in the fixture log\n' "$i"
      printf 'needs-decision [key=topic-%d]: pick an option for round %d\n' "$i" "$i"
      printf 'working: still thinking, mentions [key=topic-%d] as prose only\n' "$i" "$i"
      printf 'blocked: [key=creds-%d] waiting on a credential for round %d\n' "$i" "$i"
      printf 'needs-decision [corr=corr%06d] [key=combo-%d]: a corr-tagged decision\n' "$i" "$i"
      printf 'needs-decision [key=bad key %d]: malformed slug never opens\n' "$i"
      printf 'blocked [key=pending-reply-%d]: not the reserved vocabulary, rejected\n' "$i"
      printf 'blocked [key=pending-reply-%d]: pending-reply-%d: correct vocabulary opens\n' "$i" "$i"
      printf 'working: more routine filler padding out the log to size, round %d\n' "$i"
      if [ $((i % 3)) -eq 0 ]; then
        printf 'resolved [key=topic-%d]: answered round %d\n' "$i" "$i"
      fi
      if [ $((i % 5)) -eq 0 ]; then
        printf 'captain-held: [key=creds-%d] handed to a durable captain-held task\n' "$i"
      fi
      if [ $((i % 7)) -eq 0 ]; then
        printf 'resolved [corr=corr%06d] [key=combo-%d]: closed the corr-tagged one\n' "$i" "$i"
      fi
      if [ $((i % 11)) -eq 0 ]; then
        printf 'resolved [key=pending-reply-%d]: pending-reply-%d: closed correctly\n' "$i" "$i"
      fi
    } >> "$path"
    size=$(LC_ALL=C wc -c < "$path" | tr -d '[:space:]')
  done
}

# The bash reference engine is exactly the per-line, per-subshell loop issue
# #2808 reports as CPU-bound-shell-slow at ~330KB, so pinning the committed
# suite's fixture at that full scale would make an ordinary test run take
# minutes. This case proves equivalence at a scale that still exercises
# hundreds of concurrently open decisions (multiple keys reopened, closed, and
# left open across every shape gen_fixture produces) while staying CI-fast;
# the PR evidence separately runs the SAME generator at the full ~330KB the
# issue reports and diffs both engines' output there too, alongside the
# before/after wall-clock benchmark.
test_generated_fixture_matches() {
  local dir f bytes
  dir=$(case_dir large-fixture)
  f="$dir/task.status"
  gen_fixture "$f" 20000
  bytes=$(LC_ALL=C wc -c < "$f" | tr -d '[:space:]')
  [ "$bytes" -ge 20000 ] || fail "fixture generator undershot its target: $bytes bytes"
  assert_engines_agree "$f" "generated ${bytes}-byte fixture (same generator as the #2808-scale PR benchmark)"
}

test_empty_file_matches() {
  local dir f
  dir=$(case_dir empty)
  f="$dir/task.status"
  : > "$f"
  assert_engines_agree "$f" "empty status file"
}

test_blank_and_whitespace_only_lines_matches() {
  local dir f
  dir=$(case_dir blank-lines)
  f="$dir/task.status"
  printf 'needs-decision [key=a]: first\n\n   \n\t\nworking: filler\nresolved [key=a]: done\n' > "$f"
  assert_engines_agree "$f" "blank and whitespace-only lines interleaved"
}

test_no_colon_lines_matches() {
  local dir f
  dir=$(case_dir no-colon)
  f="$dir/task.status"
  printf 'PR ready\nmerged\nneeds-decision [key=b]: pick one\nchecks green\n' > "$f"
  assert_engines_agree "$f" "legacy colon-free free-text lines"
}

test_multiple_key_tags_on_one_line_matches() {
  local dir f
  dir=$(case_dir multi-key-tag)
  f="$dir/task.status"
  printf 'needs-decision [key=first] [key=second]: only the first tag should count\n' > "$f"
  assert_engines_agree "$f" "two [key=...] tags before the colon on one line"
}

test_file_without_trailing_newline_matches() {
  local dir f
  dir=$(case_dir no-trailing-newline)
  f="$dir/task.status"
  printf 'needs-decision [key=x]: opened\nworking: filler' > "$f"
  assert_engines_agree "$f" "final line has no trailing newline"
}

test_generated_fixture_matches
test_empty_file_matches
test_blank_and_whitespace_only_lines_matches
test_no_colon_lines_matches
test_multiple_key_tags_on_one_line_matches
test_file_without_trailing_newline_matches
