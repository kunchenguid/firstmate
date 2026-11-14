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
     "summary": "Legacy fused summary", "owner": "beta"},
    {"id": "full-call", "key": "full-call", "verb": "captain-hold",
     "title": "Choose the rollout scope for the next release while preserving the", "reason": "Which route should proceed? A: retain the existing workflow until the staged",
     "summary": "Choose the rollout scope: Which route",
     "question": "Choose the rollout scope for the next release while preserving the complete operator question: Which route should proceed? A: retain the workflow. B: start the migration. C: defer.",
     "owner": "(main)"},
    {"id": "questions/full-call", "key": "full-call", "verb": "captain-hold",
     "title": "Other home call", "reason": "same task id as main",
     "summary": "Other home call: same task id as main",
     "question": "Other home call: same task id as main", "owner": "questions"}
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

  assert_equals "alpha-fix,old-row,full-call,questions.full-call" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "captains_call is one card per open decision, and a colliding home keeps its own card"
  assert_contains "$(jq -r '.captains_call[2].decide' <<<"$p")" "B: start the migration. C: defer." "the card shows every option of a question the short fields cut"
  assert_equals "null" "$(jq -c '.captains_call[0].decide' <<<"$p")" "a question the short fields already carry adds no duplicate row"
  assert_equals "null" "$(jq -c '.captains_call[3].decide' <<<"$p")" "a short other-home question adds no duplicate row"
  assert_equals "Other home call" "$(jq -r '.captains_call[3].title' <<<"$p")" "the other home's hold keeps its own title"
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
  assert_equals "alpha-fix,full-call,questions.full-call,merge-widgets" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" "a null overlay drops its card and extra cards append"
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

# A captain-waiting item firstmate never held: a contribution awaiting merge
# approval has no hold, so the snapshot carries it only in contributions.captain.
# Its card is link-only: its key names no held task, so an answer could never apply.
test_an_unheld_captain_contribution_becomes_a_link_only_card() {
  local snap p out
  snap="$TMP_ROOT/snap-unheld.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.contributions.captain = [
        {task: "alpha-fix", url: "https://github.com/acme/alpha/pull/3", kind: "pr",
         reason: "checks green; merge approval needed", hold: "alpha-fix"},
        {task: "gamma-ship", url: "https://github.com/acme/gamma/pull/12", kind: "pr",
         reason: "checks green; merge approval needed", owner: "(main)"},
        {task: "same-pr", url: "https://github.com/acme/alpha/pull/3", kind: "pr",
         reason: "checks green; merge approval needed"}]' "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "alpha-fix,old-row,full-call,questions.full-call,contribution._main_.gamma-ship.github.com_acme_gamma_pull_12" \
    "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "an unheld captain contribution is carded once, and a held or duplicate one adds nothing"
  out=$(jq -c '.captains_call[4]' <<<"$p")
  assert_equals '{"key":"contribution._main_.gamma-ship.github.com_acme_gamma_pull_12","type":"link","repo":"gamma","title":"gamma #12","about":"checks green; merge approval needed (home (main))","pr_url":"https://github.com/acme/gamma/pull/12","options":[]}' \
    "$out" "the link card carried an answer control or lost the contribution's page"
  printf '%s\n' "$p" > "$TMP_ROOT/unheld.json"
  validates "$TMP_ROOT/unheld.json" || fail "a payload with an unheld contribution card did not satisfy the board validator"
  pass "a captain contribution with no hold becomes a link-only card the validator accepts"
}

# One task can own several contribution URLs, and two homes can reuse a task id.
# Each distinct home, task, and URL keeps its own card; only an exact repeat is dropped.
test_every_distinct_contribution_gets_its_own_link_card() {
  local snap p
  snap="$TMP_ROOT/snap-many.json"
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.contributions.captain = [
        {task: "multi", url: "https://github.com/acme/alpha/pull/1", kind: "pr", reason: "first", owner: "(main)"},
        {task: "multi", url: "https://github.com/acme/alpha/pull/2", kind: "pr", reason: "second", owner: "(main)"},
        {task: "multi", url: "https://github.com/acme/beta/pull/2", kind: "pr", reason: "other home", owner: "beta"},
        {task: "multi", url: "https://github.com/acme/alpha/pull/2", kind: "pr", reason: "exact repeat", owner: "(main)"},
        {task: "long", url: ("https://github.com/acme/alpha/pull/" + ("9" * 140) + "1"), kind: "pr", reason: "long one", owner: "(main)"},
        {task: "long", url: ("https://github.com/acme/alpha/pull/" + ("9" * 140) + "2"), kind: "pr", reason: "long two", owner: "(main)"}]' \
    "$TMP_ROOT/snap.json" > "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  assert_equals "5" "$(jq '[.captains_call[] | select(.type == "link")] | length' <<<"$p")" \
    "two PRs of one task, one task id in two homes, or two long URLs lost a card"
  assert_equals "5" "$(jq '[.captains_call[] | select(.type == "link") | .key] | unique | length' <<<"$p")" \
    "link card keys collided"
  assert_equals "https://github.com/acme/alpha/pull/1,https://github.com/acme/alpha/pull/2,https://github.com/acme/beta/pull/2" \
    "$(jq -r '[.captains_call[] | select(.type == "link" and (.about | startswith("long") | not)) | .pr_url] | join(",")' <<<"$p")" \
    "a contribution page did not reach its own card"
  printf '%s\n' "$p" > "$TMP_ROOT/many.json"
  validates "$TMP_ROOT/many.json" || fail "a payload with several link cards did not satisfy the board validator"
  pass "each distinct home, task, and contribution URL keeps its own link card"
}

# The validator refuses any answer control on a link card, because none could apply.
test_the_validator_refuses_answer_controls_on_a_link_card() {
  local p
  write_snapshot "$TMP_ROOT/snap.json"
  jq '.contributions.captain = [{task: "t", url: "https://github.com/acme/alpha/pull/9", kind: "pr", reason: "r"}]' \
    "$TMP_ROOT/snap.json" > "$TMP_ROOT/snap-link.json"
  p=$("$GEN" --snapshot "$TMP_ROOT/snap-link.json") || fail "the generator failed"
  for edit in '.options = [{value: "later", label: "Later"}]' \
              '.allow_freeform = true' \
              '.freeform_hint = "answer here"' \
              '.recommend_value = "later"' \
              '.close = "done"'; do
    jq --arg e "$edit" '.captains_call |= map(if .type == "link" then (. | '"$edit"') else . end)' <<<"$p" > "$TMP_ROOT/link-ctl.json"
    validates "$TMP_ROOT/link-ctl.json" && fail "the validator accepted a link card with: $edit"
  done
  pass "a link card carrying any answer control is refused"
}

test_cards_carry_links_and_a_non_held_credential_card_survives() {
  local snap copy p
  snap="$TMP_ROOT/snap.json"
  copy="$TMP_ROOT/links-copy.json"
  write_snapshot "$snap"
  cat > "$copy" <<'EOF'
{
  "captains_call": {
    "alpha-fix": {"links": [{"url": "https://review.example.test/session/abc", "label": "Review page"}]}
  },
  "captains_call_extra": [
    {"key": "registry-login", "type": "credential", "repo": null, "title": "Log in to the package registry",
     "options": [{"value": "done", "label": "Done"}], "close": "done",
     "links": [{"url": "https://registry.example.test/login"}]},
    {"key": "mr-review", "type": "decision", "repo": "alpha", "title": "Review the alpha MR",
     "options": [], "allow_freeform": true,
     "links": [{"url": "https://gitlab.example.test/acme/alpha/-/merge_requests/4", "label": "MR 4"}]}
  ]
}
EOF
  p=$("$GEN" --snapshot "$snap" --copy "$copy") || fail "the generator refused cards with links"
  assert_equals "alpha-fix,old-row,full-call,questions.full-call,registry-login,mr-review" "$(jq -r '[.captains_call[].key] | join(",")' <<<"$p")" \
    "a card whose key is not a held task id was dropped"
  assert_equals "Review page" "$(jq -r '.captains_call[0].links[0].label' <<<"$p")" "an overlay attaches links to a generated card"
  assert_equals "https://registry.example.test/login" "$(jq -r '.captains_call[4].links[0].url' <<<"$p")" "a credential card keeps its link"
  printf '%s\n' "$p" > "$TMP_ROOT/links.json"
  validates "$TMP_ROOT/links.json" || fail "cards with links did not satisfy the board validator"
  pass "every card type carries links and a non-held credential card survives the generator and validator"
}

test_the_validator_accepts_https_links_and_refuses_every_other_scheme() {
  local snap p url
  snap="$TMP_ROOT/snap.json"
  write_snapshot "$snap"
  p=$("$GEN" --snapshot "$snap") || fail "the generator failed"
  for url in https://example.test/page \
             'https://example.test:8443/session/abc?x=1#frag'; do
    jq --arg u "$url" '.captains_call[0].links = [{url: $u}]' <<<"$p" > "$TMP_ROOT/link-ok.json"
    validates "$TMP_ROOT/link-ok.json" || fail "the validator refused an allowed link: $url"
  done
  for url in http://example.test/page \
             ftp://example.test/page \
             'javascript:alert(1)' \
             'https://example.test/has space'; do
    jq --arg u "$url" '.captains_call[0].links = [{url: $u}]' <<<"$p" > "$TMP_ROOT/link-bad.json"
    validates "$TMP_ROOT/link-bad.json" && fail "the validator accepted a link it must refuse: $url"
  done
  jq '.captains_call[0].links = []' <<<"$p" > "$TMP_ROOT/link-empty.json"
  validates "$TMP_ROOT/link-empty.json" || fail "the validator refused an empty links list"
  jq '.captains_call[0].links = [{url: "https://example.test/x", extra: 1}]' <<<"$p" > "$TMP_ROOT/link-field.json"
  validates "$TMP_ROOT/link-field.json" && fail "the validator accepted a link with an unknown field"
  jq '.captains_call[0].links = "https://example.test/x"' <<<"$p" > "$TMP_ROOT/link-str.json"
  validates "$TMP_ROOT/link-str.json" && fail "the validator accepted links that is not an array"
  pass "the validator accepts https links only and refuses every other scheme"
}

fm_test_run \
  test_zero_copy_payload_satisfies_the_board_validator \
  test_the_same_snapshot_yields_the_same_payload \
  test_rows_map_deterministically_from_the_snapshot \
  test_charted_rows_derive_dispatchable_and_warning_from_structure \
  test_copy_overlay_refines_cards_and_keeps_the_payload_valid \
  test_copy_overlay_cannot_change_the_payload_shape \
  test_an_unheld_captain_contribution_becomes_a_link_only_card \
  test_every_distinct_contribution_gets_its_own_link_card \
  test_the_validator_refuses_answer_controls_on_a_link_card \
  test_cards_carry_links_and_a_non_held_credential_card_survives \
  test_the_validator_accepts_https_links_and_refuses_every_other_scheme
