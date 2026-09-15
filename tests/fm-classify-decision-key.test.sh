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

# A bare "answered:" note on a reserved key is deliberately NOT a close.
# bin/fm-send.sh speaks the owning library's vocabulary on its --resolve-key
# path for reserved keys and never writes a bare answered: note for them, so
# such a line is a foreign writer and must leave the decision open - while the
# operator path through the owning vocabulary still closes.
test_reserved_key_bare_answered_note_does_not_close() {
  local dir f
  dir=$(case_dir reserved-answered)
  f="$dir/t.status"
  printf 'blocked [key=pending-reply-23332bee7274560a]: pending-reply-missed: task=lucie pending-reply-id=23332bee7274560a request=CONFIG_REREAD: go\n' > "$f"
  printf 'resolved [key=pending-reply-23332bee7274560a]: answered: operator thought this would close it\n' >> "$f"
  assert_fold "$f" "$(printf 'pending-reply-23332bee7274560a\tblocked\tpending-reply-missed: task=lucie pending-reply-id=23332bee7274560a request=CONFIG_REREAD: go\n')" \
    "bare answered: on a reserved key"
  printf 'resolved [key=pending-reply-23332bee7274560a]: pending-reply-resolved: task=lucie pending-reply-id=23332bee7274560a via=operator-resolve-key\n' >> "$f"
  assert_fold "$f" "" "owning-vocabulary operator close"
  pass "a bare 'answered:' note cannot close a reserved-key decision; the owning vocabulary still can"
}

# A reserved-key decision transferred to the durable captain-held inventory
# carries a "tracked by" note. The fold must accept that transfer as a close -
# otherwise the transferred decision re-appears in OPEN DECISIONS forever.
test_reserved_key_tracked_by_transfer_closes() {
  local dir f
  dir=$(case_dir reserved-tracked-by)
  f="$dir/t.status"
  printf 'blocked [key=pending-reply-cafe0001]: pending-reply-missed: task=z pending-reply-id=cafe0001 request=THING: go\n' > "$f"
  printf 'captain-held [key=pending-reply-cafe0001]: tracked by hold-pending-reply-cafe0001\n' >> "$f"
  assert_fold "$f" "" "reserved-key tracked-by transfer"
  pass "a reserved-key decision transferred with a 'tracked by' note folds as resolved"
}

# The widened vocabulary must not become an open door: a foreign resolution
# carrying no recognized system provenance still cannot close a reserved key.
test_reserved_key_foreign_resolution_still_rejected() {
  local dir f
  dir=$(case_dir reserved-foreign)
  f="$dir/t.status"
  printf 'blocked [key=pending-reply-abcdef01]: pending-reply-missed: task=ios pending-reply-id=abcdef01 request=ship: go\n' > "$f"
  printf 'resolved [key=pending-reply-abcdef01]: all good now\n' >> "$f"
  assert_fold "$f" "$(printf 'pending-reply-abcdef01\tblocked\tpending-reply-missed: task=ios pending-reply-id=abcdef01 request=ship: go\n')" \
    "foreign resolution on a reserved key"
  pass "a foreign resolution with no system provenance still cannot close a reserved-key decision"
}

# Version 5 named two different rule sets across the two trees, so a cursor
# stamped version=5 may carry an open set folded under older semantics -
# still listing a key the status log already closes. A newer fold version
# must invalidate it and rebuild from byte 0, closing the key.
test_stale_version5_cursor_is_invalidated() {
  local dir f cf file_ident file_size incr new_version
  dir=$(case_dir stale-version5)
  f="$dir/t.status"
  printf 'blocked [key=pending-reply-23332bee7274560a]: pending-reply-missed: task=lucie pending-reply-id=23332bee7274560a request=CONFIG_REREAD: go\n' > "$f"
  printf 'captain-held [key=pending-reply-23332bee7274560a]: tracked by hold-pending-reply-23332bee7274560a\n' >> "$f"
  [ -z "$(status_open_decisions "$f")" ] \
    || fail "stale-cursor sanity: the full fold should be empty"

  # Forge a cursor as the narrow reading would have written it: all bytes
  # consumed, file identity current, but the key still open - stamped with the
  # ambiguous version 5.
  cf=$(_fm_open_decisions_cursor_path "$f")
  file_ident=$(_fm_open_decisions_file_ident "$f")
  file_size=$(_fm_status_file_size "$f")
  file_size=${file_size//[[:space:]]/}
  {
    printf 'version=5\n'
    printf 'offset=%s\n' "$file_size"
    printf 'ident=%s\n' "$file_ident"
    printf 'pending-reply-23332bee7274560a\tblocked\tpending-reply-missed: task=lucie pending-reply-id=23332bee7274560a request=CONFIG_REREAD: go\n'
  } > "$cf"

  incr=$(status_open_decisions_incremental "$f")
  [ -z "$incr" ] \
    || fail "stale version-5 cursor was trusted: incremental fold still reports '$incr'"
  new_version=$(head -1 "$cf")
  [ "$new_version" = "version=$FM_OPEN_DECISIONS_FOLD_VERSION" ] \
    || fail "the cursor was not rewritten with the current version: got '$new_version'"
  [ "$FM_OPEN_DECISIONS_FOLD_VERSION" = "8" ] \
    || fail "the fold version is $FM_OPEN_DECISIONS_FOLD_VERSION, want 8"
  pass "a stale version-5 cursor is invalidated and refolds to resolved"
}

# A "[key=<slug>]" token as the last thing on the note (only whitespace may
# follow it) states the same key as the two previously accepted positions.
# Workers handed a brief that names the token without a position put it where
# it reads naturally, which is the end - and two such lines then shared the
# "default" bucket, so the second silently overwrote the first. The end
# position is asymmetric by verb: it opens and strips like the note-head form,
# but never closes (see test_end_of_line_close_across_positions). A token
# with prose after it stays prose (see the mid-note test below), so a summary
# merely mentioning "[key=x]" mid-sentence still cannot open that decision.
test_end_of_line_key_opens_stated_key() {
  local dir before endline
  dir=$(case_dir end-position)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: pick REST or RPC [key=api-shape]\n' > "$dir/end.status"
  before=$(status_open_decisions "$dir/before.status")
  endline=$(status_open_decisions "$dir/end.status")
  [ "$endline" = "$before" ] \
    || fail "end-of-line form folded differently: '$endline' vs '$before'"
  assert_fold "$dir/end.status" "$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')" \
    "end-of-line key"
  printf 'blocked: waiting on the deploy token [key=creds]\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "end-of-line blocked form"
  pass "a stated [key=X] at the end of the note opens X with the token stripped"
}

# The exact silent collapse from the incident: two needs-decision lines
# carrying different well-formed keys at the end of the line, on one task.
# Both must stay independently open; losing either without anyone being told
# is the defect.
test_two_end_of_line_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir end-distinct)
  printf 'needs-decision: remove the three asks [key=asks-to-remove]\n' > "$dir/t.status"
  printf 'needs-decision: what about the legend routes [key=legend-routes]\n' >> "$dir/t.status"
  expected=$(printf 'asks-to-remove\tneeds-decision\tremove the three asks\nlegend-routes\tneeds-decision\twhat about the legend routes\n')
  assert_fold "$dir/t.status" "$expected" "two end-of-line decisions"
  printf 'resolved [key=asks-to-remove]: answered: drop them\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'legend-routes\tneeds-decision\twhat about the legend routes\n')" \
    "closing one of two end-of-line decisions"
  pass "two end-of-line keyed decisions never collapse into one shared bucket"
}

# An end-of-line open closes through either previously accepted close shape -
# which is what lets fm-send's before-colon --resolve-key close answer an
# end-of-line decision. The reverse does NOT hold: the end position is
# asymmetric by verb, accepted when opening, refused when closing. A
# `resolved:` line whose note merely ENDS in a key token is prose quoting
# that key, not a close - CI caught the symmetric form of this fix closing
# q1 on exactly such a line (tests/fm-watch-triage.test.sh). A false close
# silently loses a live escalation; a missed close leaves the decision
# visibly open, re-closeable with a documented-position line.
test_end_of_line_close_across_positions() {
  local dir
  dir=$(case_dir end-cross-close)
  printf 'needs-decision: pick the bound [key=seam-max-bound]\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing an end-of-line open"

  printf 'needs-decision: pick the bound [key=seam-max-bound]\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "note-head resolution closing an end-of-line open"

  printf 'needs-decision [key=q1]: real choice\n' > "$dir/c.status"
  printf 'resolved: docs still mention [key=q1]\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" \
    "$(printf 'q1\tneeds-decision\treal choice\n')" \
    "a resolved note ending in a key token must not close that key"
  pass "an end-of-line open closes through the two accepted shapes, never through a trailing token"
}

# A token with prose after it is still prose, never a stated key: only a
# token at the head of the note or at its very end states a key. This pins
# the boundary the end-position tolerance must not cross.
test_mid_note_token_with_trailing_prose_stays_prose() {
  local dir
  dir=$(case_dir end-boundary)
  printf 'needs-decision: pick [key=red] now\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick [key=red] now\n')" \
    "mid-note token with trailing prose"
  printf 'needs-decision: see previous [key=red] for context\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tsee previous [key=red] for context\n')" \
    "a second mid-note mention still shares default"
  pass "a [key=x] with prose after it stays prose, never an opened key"
}

# A malformed slug at the end of the line is rejected, never folded as
# default - identically to both previously accepted positions.
test_end_of_line_malformed_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir end-malformed)
  printf 'needs-decision: before-colon malformed [key=bad key]\n' > "$dir/t.status"
  assert_fold "$dir/t.status" "" "malformed end-of-line key"
  pass "a malformed end-of-line key is rejected, never folded as default"
}

# A bare keyless resolution still closes only default when end-of-line keyed
# decisions are open beside it: the historical one-open-unkeyed-decision
# behavior is unchanged by the third position.
test_bare_resolved_closes_only_default_beside_end_keys() {
  local dir
  dir=$(case_dir end-beside-default)
  printf 'needs-decision: which color\n' > "$dir/t.status"
  printf 'needs-decision: pick a route [key=route]\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\twhich color\nroute\tneeds-decision\tpick a route\n')" \
    "keyless and end-of-line opens side by side"
  printf 'resolved: went with blue\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'route\tneeds-decision\tpick a route\n')" \
    "bare resolution closes only default"
  pass "a bare resolved: still closes only the default key"
}

# Documented precedence, unchanged: when both the before-colon and the
# note-head positions carry a token, the before-colon one wins and the
# note-head token stays note text.
test_both_positions_precedence_unchanged() {
  local dir
  dir=$(case_dir precedence)
  printf 'needs-decision [key=before]: [key=head] pick one\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'before\tneeds-decision\t[key=head] pick one\n')" \
    "before-colon wins over note-head"
  pass "a before-colon token wins and a note-head token stays note text"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_end_of_line_key_opens_stated_key
test_two_end_of_line_decisions_stay_distinct
test_end_of_line_close_across_positions
test_mid_note_token_with_trailing_prose_stays_prose
test_end_of_line_malformed_key_never_collapses_to_default
test_bare_resolved_closes_only_default_beside_end_keys
test_both_positions_precedence_unchanged
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_never_collapses_to_default
test_reserved_key_bare_answered_note_does_not_close
test_reserved_key_tracked_by_transfer_closes
test_reserved_key_foreign_resolution_still_rejected
test_stale_version5_cursor_is_invalidated
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
