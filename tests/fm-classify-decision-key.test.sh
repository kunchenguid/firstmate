#!/usr/bin/env bash
# tests/fm-classify-decision-key.test.sh - decision-key position tolerance in
# the open-decisions fold (bin/fm-classify-lib.sh). A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). Also covers
# status_line_verb's bracket-tag stripping: a remote secondmate reply prepends
# a "[corr=...]" correlation tag before (or without) "[key=...]", and every
# such tag before the colon must be stripped so the leading word is the bare
# verb, regardless of order or count. These tests drive the REAL
# status_line_verb / status_open_decisions / status_open_decisions_incremental
# functions over crafted status files and assert their folded output, never the
# fold's own source text. Also covers status_key_closing_verb, which reports how
# the status side currently reads one key so a consumer can tell a settled key
# from one handed to a durable captain-held task (bin/fm-captain-hold.sh
# diverged). Cross-drain cursor persistence and the incremental
# cost bound live in tests/fm-wake-drain-open-decisions-cursor.test.sh; the
# drain wiring lives in tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-tests)

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_mid_note_prose_mention_is_not_a_stated_key() {
  local dir
  dir=$(case_dir prose)
  # Only a token at the head of the note states a key; a summary merely
  # mentioning "[key=x]" deeper in must neither open nor close that key.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\n')" \
    "mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "a [key=x] mentioned mid-note is prose, never an opened or closed key"
}

test_malformed_stated_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir malformed)
  # A stated-but-invalid slug is rejected in BOTH positions - identically,
  # and never rewritten into the shared default bucket.
  printf 'needs-decision [key=bad key]: before-colon malformed\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] colon-first malformed\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "" "malformed before-colon key"
  assert_fold "$dir/after.status" "" "malformed colon-first key"
  pass "a malformed stated key is rejected in both positions, never folded as default"
}

# A remote secondmate reply routinely prepends a "[corr=<hex>]" correlation
# tag ahead of "[key=...]" (issue: a remote reply's "needs-decision
# [corr=d448ea86afa4bf67] [key=x]: ..." folded to no open decision at all,
# because the verb parser only stripped a leading "[key=...]" token and left
# the corr tag glued onto the returned verb word). These cases drive the real
# status_line_verb directly, over every bracket-tag shape that precedes the
# colon, to pin the general fix: strip EVERY "[name=value]" tag there, not
# just "[key=...]", regardless of order or count.
test_status_line_verb_strips_every_bracket_tag_before_colon() {
  local v

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-then-key tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [key=loan-installment-cadence-amount] [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "key-then-corr tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-only tag: got '$v'"

  v=$(status_line_verb 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token')
  [ "$v" = "blocked" ] || fail "blocked with corr+key: got '$v'"

  v=$(status_line_verb 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated')
  [ "$v" = "resolved" ] || fail "resolved with corr+key: got '$v'"

  pass "status_line_verb strips every bracket tag before the colon, in any order, and recovers the bare verb"
}

test_corr_and_key_tags_open_and_close_under_the_stated_key() {
  local dir expected
  dir=$(case_dir corr-and-key)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$dir/t.status"
  expected=$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')
  assert_fold "$dir/t.status" "$expected" "corr-then-key opens under the stated key"

  printf 'resolved [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: answered: monthly\n' \
    >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "corr-then-key resolution closes the same stated key"
  pass "a [corr=...] tag ahead of [key=...] no longer swallows the verb: opens and closes under the stated key"
}

test_corr_only_tag_opens_as_default_like_a_bare_line() {
  local dir bare corred
  dir=$(case_dir corr-only)
  printf 'needs-decision: which vendor\n' > "$dir/bare.status"
  printf 'needs-decision [corr=d448ea86afa4bf67]: which vendor\n' > "$dir/corred.status"

  bare=$(status_open_decisions "$dir/bare.status")
  corred=$(status_open_decisions "$dir/corred.status")
  [ "$corred" = "$bare" ] \
    || fail "a corr-only tag folded differently than the bare line: '$corred' vs '$bare'"
  assert_fold "$dir/corred.status" "$(printf 'default\tneeds-decision\twhich vendor\n')" "corr-only tag"
  pass "a [corr=...] tag with no stated key opens under 'default', exactly like a bare needs-decision line"
}

test_key_only_before_colon_still_opens_no_regression() {
  local dir
  dir=$(case_dir key-only-no-corr)
  printf 'needs-decision [key=loan-installment-cadence-amount]: pick the cadence\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')" \
    "key-only before colon, no corr tag"
  pass "a [key=x] tag alone (no corr tag) still opens x - no regression from the tag-stripping fix"
}

test_blocked_and_resolved_are_tag_order_independent() {
  local dir
  dir=$(case_dir blocked-tag-order)
  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/a.status"
  assert_fold "$dir/a.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked corr-then-key"

  printf 'blocked [key=creds] [corr=aaaa1111bbbb2222]: waiting on the deploy token\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked key-then-corr"

  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/c.status"
  printf 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" "" "blocked/resolved corr+key close together regardless of tag order"
  pass "blocked/resolved parse their bare verb with any bracket-tag order preceding the colon"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_never_collapses_to_default
test_status_line_verb_strips_every_bracket_tag_before_colon
test_corr_and_key_tags_open_and_close_under_the_stated_key
test_corr_only_tag_opens_as_default_like_a_bare_line
test_key_only_before_colon_still_opens_no_regression
test_blocked_and_resolved_are_tag_order_independent
test_incremental_agrees_with_full_fold_across_appends

# status_key_closing_verb reports HOW the status side currently reads one key,
# which is what lets a consumer tell a settled key from a key handed to a
# durable captain-held task. The two closing verbs must stay distinguishable:
# `resolved` claims the question is settled outright, while `captain-held` is
# the verified transfer to that task, so treating them alike would either lose
# the record-divergence signal or invent one on every correct transfer.
test_closing_verb_separates_resolution_from_durable_transfer() {
  local dir f
  dir=$(case_dir closing-verb)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
working: started
needs-decision [key=route]: north or south
resolved [key=route]: answered: north
needs-decision [key=access]: open or restricted
captain-held [key=access]: tracked by sample-access-call
blocked [key=creds]: need the deploy token
done: everything else shipped
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a resolved key did not report the resolve verb: '$(status_key_closing_verb "$f" route)'"
  [ "$(status_key_closing_verb "$f" access)" = captain-held ] \
    || fail "a durable-transfer close reported the wrong verb: '$(status_key_closing_verb "$f" access)'"
  [ "$(status_key_closing_verb "$f" creds)" = blocked ] \
    || fail "a still-open key must report its opening verb: '$(status_key_closing_verb "$f" creds)'"
  [ -z "$(status_key_closing_verb "$f" never-mentioned)" ] \
    || fail "a key with no transition line reported a verb"
  [ -z "$(status_key_closing_verb "$dir/absent.status" route)" ] \
    || fail "an absent status file reported a verb"
  pass "status_key_closing_verb separates resolution, durable transfer, and still-open"
}

# The reported verb is the LAST transition, read through the same fold rule as
# everything else: the colon-first key position counts, a re-opened key reports
# open again, and a prose mention is never a transition.
test_closing_verb_tracks_the_last_transition_in_both_positions() {
  local dir f
  dir=$(case_dir closing-verb-last)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
needs-decision: [key=route] colon-first open
resolved: [key=route] colon-first close
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a colon-first resolution was not seen: '$(status_key_closing_verb "$f" route)'"

  printf 'needs-decision [key=route]: re-opened after a bad answer\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
    || fail "a re-opened key still reported closed: '$(status_key_closing_verb "$f" route)'"

  printf 'resolved [key=route]: answered: south after all\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "the last of several transitions was not reported: '$(status_key_closing_verb "$f" route)'"

  printf 'working: a later append that only mentions [key=route] as prose\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a prose mention changed the reported verb: '$(status_key_closing_verb "$f" route)'"
  pass "status_key_closing_verb reports the last real transition, in either key position"
}

test_closing_verb_separates_resolution_from_durable_transfer
test_closing_verb_tracks_the_last_transition_in_both_positions

# The per-key read pre-selects candidate lines by their leading verb before the
# bash fold sees them, and the resolve/durable-transfer verbs are overridable, so
# an overridden verb buried behind unrelated history must still close its key.
test_closing_verb_honors_overridden_transition_verbs() {
  local dir f i
  dir=$(case_dir closing-verb-overrides)
  f="$dir/task.status"
  printf 'kind=ship\n' > "$dir/task.meta"
  printf 'blocked [key=route]: waiting\n' > "$f"
  for ((i = 0; i < 200; i++)); do
    printf 'note: routine reply\nworking: still going\nContinuation prose here.\n' >> "$f"
  done
  printf 'answered [key=route]: settled\n' >> "$f"
  [ "$(FM_CLASSIFY_RESOLVE_VERB=answered status_key_closing_verb "$f" route)" = answered ] \
    || fail "an overridden resolve verb stopped closing its key"
  [ "$(status_key_closing_verb "$f" route)" = blocked ] \
    || fail "without the override the same line must leave the key open"
  printf 'blocked [key=access]: waiting\nawaiting-captain [key=access]: handed off\n' >> "$f"
  [ "$(FM_CLASSIFY_CAPTAIN_HELD_VERB=awaiting-captain status_key_closing_verb "$f" access)" = awaiting-captain ] \
    || fail "an overridden durable-transfer verb stopped closing its key"
  pass "overridden resolve and durable-transfer verbs still close keys behind unrelated history"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth() {
  local dir f want tag size i level small large
  dir=$(case_dir closing-verb-processes)
  f="$dir/task.status"
  printf 'kind=secondmate\n' > "$dir/task.meta"
  for want in route default; do
    tag="[key=$want]"
    [ "$want" != default ] || tag=''
    for size in 1 1000; do
      printf 'blocked corr=0123456789abcdef %s: waiting\n' "$tag" > "$f"
      for ((i = 0; i < size; i++)); do
        printf 'note: routine reply\nworking: mentions [key=%s] in prose\ndone: another task finished\nfailed: unrelated work\nPR ready https://example.com/pull/1\n\n' "$want" >> "$f"
        if [ "$want" != default ]; then
          printf 'blocked [key=other]: another question\nresolved [key=other]: answered\n' >> "$f"
        fi
      done
      printf 'resolved corr=0123456789abcdef: %s answered\nnote: cleanup complete\n' "$tag" >> "$f"
      : > "$dir/children-$size"
      (
        level=$BASH_SUBSHELL
        set -T
        trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$dir/children-$size"; fi' DEBUG
        status_key_closing_verb "$f" "$want" > "$dir/output"
      )
      [ "$(cat "$dir/output")" = resolved ] || fail "$want lost its resolution behind unrelated history"
    done
    small=$(wc -c < "$dir/children-1")
    large=$(wc -c < "$dir/children-1000")
    [ "$large" -le "$((small + 20))" ] || fail "$want launches subprocess work for unrelated history ($small -> $large)"
  done
  pass "per-key reads retain resolutions without subprocess work growing with unrelated history"
}

test_closing_verb_filter_preserves_terminal_chronology() {
  local dir f kind want tag terminal expected
  dir=$(case_dir closing-verb-terminals)
  f="$dir/task.status"
  for kind in ship scout secondmate; do
    printf 'kind=%s\n' "$kind" > "$dir/task.meta"
    for want in access default; do
      tag="[key=$want]"
      [ "$want" != default ] || tag=''
      for terminal in 'done' failed; do
        printf 'blocked %s: waiting\n' "$tag" > "$f"
        case "$terminal" in
          done) printf 'done: report saved\n' >> "$f" ;;
          failed) printf 'failed corr=0123456789abcdef [key=other]: task failed\n' >> "$f" ;;
        esac
        printf 'note: cleanup complete\n' >> "$f"
        expected=$terminal
        [ "$kind" != secondmate ] || expected=blocked
        [ "$(status_key_closing_verb "$f" "$want")" = "$expected" ] || fail "$kind/$want lost $terminal chronology"
        printf 'needs-decision: [key=%s] reopened\nnote: more cleanup\n' "$want" >> "$f"
        [ "$(status_key_closing_verb "$f" "$want")" = needs-decision ] || fail "$kind/$want lost a post-terminal reopening"
      done
    done
  done
  pass "per-key filtering retains ship/scout terminals, reopenings, and secondmate blockers"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth
test_closing_verb_honors_overridden_transition_verbs
test_closing_verb_filter_preserves_terminal_chronology

test_bare_prose_cannot_impersonate_a_terminal_declaration() {
  local dir f kind word open
  dir=$(case_dir prose-terminal)
  open=$(printf 'route\tneeds-decision\tA or B?\n')
  for kind in ship scout; do
    for word in 'done' failed; do
      f="$dir/$kind-$word.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word.meta"
      printf 'needs-decision [key=route]: A or B?\npaused: waiting on the vendor\nSteps remaining:\n %s\n' \
        "$word" > "$f"
      assert_fold "$f" "$open" "$kind: bare '$word' prose"
      [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
        || fail "$kind: bare '$word' prose closed a still-open key"
      f="$dir/$kind-$word-real.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word-real.meta"
      printf 'needs-decision [key=route]: A or B?\n%s: real outcome\n' "$word" > "$f"
      assert_fold "$f" '' "$kind: genuine $word supersedes"
      [ "$(status_key_closing_verb "$f" route)" = "$word" ] \
        || fail "$kind: genuine $word no longer supersedes the open key"
    done
  done
  pass "prose without a colon cannot impersonate a ship or scout terminal declaration"
}

test_bare_prose_cannot_impersonate_a_terminal_declaration

test_bare_prose_cannot_open_or_close_a_decision() {
  local dir f word blocked
  dir=$(case_dir prose-decision)
  blocked=$(printf 'default\tblocked\tneed release access\n')
  for word in blocked needs-decision resolved; do
    f="$dir/open-$word.status"
    printf 'kind=ship\n' > "$dir/open-$word.meta"
    printf 'working: investigating the deploy\nOptions considered:\n %s\n' "$word" > "$f"
    assert_fold "$f" '' "bare '$word' prose opened a decision"

    f="$dir/close-$word.status"
    printf 'kind=ship\n' > "$dir/close-$word.meta"
    printf 'blocked: need release access\nSteps remaining:\n %s\n' "$word" > "$f"
    assert_fold "$f" "$blocked" "bare '$word' prose moved an open decision"
  done

  f="$dir/keyed-colonless.status"
  printf 'kind=ship\n' > "$dir/keyed-colonless.meta"
  printf 'blocked [key=access]\n' > "$f"
  assert_fold "$f" "$(printf 'access\tblocked\tblocked [key=access]\n')" \
    "a keyed colonless line stopped opening its key"
  printf 'resolved [key=access]\n' >> "$f"
  assert_fold "$f" '' "a keyed colonless line stopped closing its key"

  f="$dir/real-resolution.status"
  printf 'kind=ship\n' > "$dir/real-resolution.meta"
  printf 'blocked: need release access\nresolved: access granted\n' > "$f"
  assert_fold "$f" '' "a genuine resolution stopped closing its decision"
  pass "only a colon-bearing or keyed line is a decision transition in the fold"
}

test_bare_prose_cannot_open_or_close_a_decision
