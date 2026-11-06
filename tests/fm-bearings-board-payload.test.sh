#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board-payload.sh: the same snapshot always
# yields the same fm-bearings-board.v1 payload, the payload satisfies the board
# validator with no authored copy, and the optional copy overlay can refine a
# card but never change the payload's shape.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-bearings-board-payload.sh"
BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-payload)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A snapshot exercising every mapping: a decision with clean title/reason, a
# legacy decision row with only a fused summary, a recorded PR, a done row that
# must not surface as underway, landed rows with and without a PR artifact,
# queued/held/synthetic gates, and both secondmate warning kinds.
write_snapshot() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings.v1",
  "home": "/fixture/home",
  "generated": "2026-11-06T07:34:00Z",
  "prs": "unchecked",
  "decisions_open": [
    {"id": "alpha-fix", "key": "alpha-fix", "verb": "captain-hold",
     "title": "Pick the alpha retry policy", "reason": "two options measured",
     "summary": "Pick the alpha retry policy: two options measured", "owner": "(main)"},
    {"id": "beta/old-row", "key": "old-row", "verb": "captain-hold",
     "summary": "Legacy fused summary", "owner": "beta"}
  ],
  "in_flight": [
    {"id": "t1", "name": "Build the thing", "repo": "alpha", "state": "working", "doing": "writing tests", "kind": "ship"},
    {"id": "t2", "name": "-", "repo": null, "state": "done", "doing": "-", "kind": "ship"},
    {"id": "alpha-fix", "name": "Alpha fix", "repo": "alpha", "state": "parked", "doing": "waiting", "kind": "ship"}
  ],
  "landed": [
    {"id": "l1", "what": "shipped the widget", "artifact": "https://github.com/acme/widgets/pull/7", "owner": "(main)"},
    {"id": "l2", "what": "local landing", "artifact": "-", "owner": "beta"}
  ],
  "recorded_prs": [{"id": "alpha-fix", "url": "https://github.com/acme/alpha/pull/3"}],
  "contributions": {"captain": []},
  "gates": [
    {"id": "plain-queued", "title": "A queued item", "blocked_by": "-", "reason": "-", "owner": "(main)", "filed": "2026-10-30"},
    {"id": "dated-hold", "title": "A dated hold", "blocked_by": "-", "reason": "until 2026-11-14: gate", "owner": "(main)", "filed": "2026-10-31"},
    {"id": "(main-inventory)", "title": "item has no child metadata", "blocked_by": "-", "reason": "main inventory", "owner": "(main)"}
  ],
  "secondmates": [
    {"id": "beta", "state": "no_active_work"},
    {"id": "gamma", "state": "unknown", "reason": "home unreadable"},
    {"id": "delta", "state": "no_active_work"}
  ],
  "secondmate_reconcile": [
    {"id": "delta", "kind": "terminal_in_flight", "ids": ["d-1", "d-2"]},
    {"id": "beta", "kind": null, "ids": []}
  ],
  "omitted": [{"surface": "gates showing 3 of 8", "reveal": "--all-queued"}]
}
EOF
}

# The board validator runs before the template is read, so a missing template
# separates "the payload failed validation" from "validation passed".
validates() {  # <payload>
  local out
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$TMP_ROOT/absent-template.html" FM_HOME="$TMP_ROOT/vhome" \
    "$BOARD" build "$1" 2>&1) || true
  case "$out" in
    *"does not satisfy"*|*"not valid JSON"*) return 1 ;;
    *"template is missing"*) return 0 ;;
    *) printf 'unexpected build output: %s\n' "$out" >&2; return 1 ;;
  esac
}

test_zero_copy_payload_satisfies_the_board_validator() {
  local snap out
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  out="$TMP_ROOT/payload.json"
  "$GEN" --snapshot "$snap" > "$out" || fail "the generator failed on a valid snapshot"
  validates "$out" || fail "the zero-copy payload did not satisfy the board validator"
  printf '{"schema":"fm-bearings-board.v1"}\n' > "$TMP_ROOT/bad.json"
  validates "$TMP_ROOT/bad.json" && fail "the validator probe accepted a bad payload, so the check is vacuous"
  pass "a zero-copy payload satisfies the board validator"
}

test_the_same_snapshot_yields_the_same_payload() {
  local snap a b
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  a=$("$GEN" --snapshot "$snap") || fail "first run failed"
  b=$("$GEN" --snapshot - < "$snap") || fail "second run failed"
  assert_equals "$a" "$b" "the same snapshot produced two different payloads"
  pass "the same snapshot always yields the same payload"
}

test_rows_map_deterministically_from_the_snapshot() {
  local snap p
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"

  assert_equals "alpha-fix,old-row" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "captains_call is one card per open decision"
  assert_equals "Pick the alpha retry policy" "$(jq -r '.captains_call[0].title' <<<"$p")" "the card title comes from the clean title field"
  assert_equals "two options measured" "$(jq -r '.captains_call[0].about' <<<"$p")" "the card about comes from the reason field"
  assert_equals "Legacy fused summary" "$(jq -r '.captains_call[1].title' <<<"$p")" "a row with no title falls back to its summary"
  assert_equals "https://github.com/acme/alpha/pull/3" "$(jq -r '.captains_call[0].pr_url' <<<"$p")" "the recorded PR is attached to its card"
  assert_equals "alpha" "$(jq -r '.captains_call[0].repo' <<<"$p")" "the card repo comes from the recorded PR"
  assert_equals "true" "$(jq -r '[.captains_call[] | .allow_freeform] | all' <<<"$p")" "every generated card takes a freeform answer"
  assert_equals "t1,alpha-fix" "$(jq -r '[.underway[].id] | join(",")' <<<"$p")" "a done row is not underway"
  assert_equals "Build the thing" "$(jq -r '.underway[0].name' <<<"$p")" "underway keeps the projected name"
  assert_equals "https://github.com/acme/widgets/pull/7" "$(jq -r '.landed[0].pr_url' <<<"$p")" "a landed PR artifact becomes its link"
  assert_equals "widgets" "$(jq -r '.landed[0].repo' <<<"$p")" "a landed PR artifact supplies the repo"
  assert_equals "null" "$(jq -c '.landed[1].repo' <<<"$p")" "a landed row with no PR has no repo"
  assert_equals "false" "$(jq '.prs_live' <<<"$p")" "unchecked PRs are not live"
  assert_equals "5" "$(jq '.charted_more' <<<"$p")" "charted_more counts the gates the snapshot omitted"
  pass "snapshot rows map to cards the same way every run"
}

test_charted_rows_derive_dispatchable_and_warning_from_structure() {
  local snap p
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "true" "$(jq '.charted[] | select(.id == "plain-queued") | .dispatchable' <<<"$p")" "a gate with no blocker or hold is dispatchable"
  assert_equals "false" "$(jq '.charted[] | select(.id == "dated-hold") | .dispatchable' <<<"$p")" "a held gate is not dispatchable"
  assert_equals "warning" "$(jq -r '.charted[] | select(.id == "main-inventory") | .kind' <<<"$p")" "a synthetic gate becomes a warning row"
  assert_equals "warning,warning" \
    "$(jq -r '[.charted[] | select(.id | test("^(reconcile|unavailable)-")) | .kind] | join(",")' <<<"$p")" \
    "a mismatched home and an unavailable home each get one warning row"
  assert_equals "false" "$(jq '[.charted[] | select(.kind == "warning") | .dispatchable] | any' <<<"$p")" "no warning row is dispatchable"
  assert_equals "" "$(jq -r '.charted[] | select(.id == "plain-queued") | .reason' <<<"$p")" "a dash reason is blank"
  pass "charted rows derive their kind and dispatchable flag from structure"
}

test_copy_overlay_refines_cards_and_keeps_the_payload_valid() {
  local snap copy p
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/copy.json"
  write_snapshot "$snap"
  cat > "$copy" <<'EOF'
{
  "captains_call": {
    "alpha-fix": {"title": "Alpha retry: pick one", "options": [{"value": "fast", "label": "Fast"}], "recommend_value": "fast"},
    "old-row": null
  },
  "captains_call_extra": [
    {"key": "merge-widgets", "type": "merge", "repo": "widgets", "title": "Merge widgets 7",
     "risk": "low", "pr_url": "https://github.com/acme/widgets/pull/7",
     "options": [{"value": "merge", "label": "Merge"}]}
  ],
  "charted": {"plain-queued": {"title": "Queued, reworded"}}
}
EOF
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator refused a valid overlay"
  assert_equals "alpha-fix,merge-widgets" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "a null overlay drops its card and extra cards append"
  assert_equals "Alpha retry: pick one" "$(jq -r '.captains_call[0].title' <<<"$p")" "the overlay title wins"
  assert_equals "two options measured" "$(jq -r '.captains_call[0].about' <<<"$p")" "unlisted fields keep the generated value"
  assert_equals "Queued, reworded" "$(jq -r '.charted[] | select(.id == "plain-queued") | .title' <<<"$p")" "the overlay can reword a charted row"
  printf '%s\n' "$p" > "$TMP_ROOT/with-copy.json"
  validates "$TMP_ROOT/with-copy.json" || fail "the payload with a copy overlay did not satisfy the board validator"
  pass "a copy overlay refines cards and keeps the payload valid"
}

test_copy_overlay_cannot_change_the_payload_shape() {
  local snap copy out rc
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/bad-copy.json"
  write_snapshot "$snap"

  printf '{"captains_call":{"alpha-fix":{"sneaky":"x"}}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay with an unknown field was accepted"
  assert_contains "$out" "unknown field" "the unknown-field refusal did not say why: $out"

  printf '{"extras":{}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay with an unknown section was accepted"
  assert_contains "$out" "unknown section" "the unknown-section refusal did not say why: $out"

  printf '{"captains_call":{"alpha-fix":{"options":[{"value":"reconcile","label":"R"}]}}}\n' > "$copy"
  set +e; out=$("$GEN" --snapshot "$snap" --copy "$copy" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an overlay authoring the reconcile option was accepted"
  assert_contains "$out" "reconcile" "the reconcile refusal did not name the value: $out"

  printf '{"schema":"other"}\n' > "$TMP_ROOT/not-a-snapshot.json"
  set +e; out=$("$GEN" --snapshot "$TMP_ROOT/not-a-snapshot.json" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-snapshot input was accepted"
  pass "a copy overlay cannot add fields, sections, or the reconcile option"
}

fm_test_run \
  test_zero_copy_payload_satisfies_the_board_validator \
  test_the_same_snapshot_yields_the_same_payload \
  test_rows_map_deterministically_from_the_snapshot \
  test_charted_rows_derive_dispatchable_and_warning_from_structure \
  test_copy_overlay_refines_cards_and_keeps_the_payload_valid \
  test_copy_overlay_cannot_change_the_payload_shape
