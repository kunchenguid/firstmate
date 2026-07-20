#!/usr/bin/env bash
# Behavior tests for bin/fm-effort-lavish.sh.
#
# The Lavish round-trip is verified empirically in REPORT.md.
# These tests pin the deterministic row-to-card mapping and the embedded
# decision prompt contract that the loop consumes.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAVISH="$ROOT/bin/fm-effort-lavish.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort-lavish)

case_cards_map_inventory_fields() {
  local d rows inventory html cards review urls decision_options
  d="$TMP_ROOT/cards"
  mkdir -p "$d"
  rows="$d/rows.json"
  inventory="$d/inventory.json"
  html="$d/board.html"
  cards="$d/cards.json"
  cat > "$rows" <<'JSON'
[
  {
    "effort_id": "REL-1",
    "stage": "needs_captain",
    "updated_at": "2026-07-16T18:00:00Z",
    "actor": "fm-effort:inventory",
    "kind": "inventory_observed",
    "note": "Slack incident follow-up; next_machine=watch CI",
    "evidence": "https://linear.app/getlindy/issue/REL-1/demo",
    "decision": {
      "kind": "merge_word",
      "question": "Ship PR 123?",
      "recommendation": "APPROVE",
      "options": ["APPROVE", "CHANGES_REQUESTED", "PARK"]
    }
  }
]
JSON
  cat > "$inventory" <<'JSON'
{
  "items": [
    {
      "logicalId": "REL-1",
      "title": "Demo ticket",
      "owner": "lane-a",
      "linear": [{"url": "https://linear.app/getlindy/issue/REL-1/demo"}],
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/123",
          "review": {"decision": "APPROVED", "approvals": ["human-reviewer"]},
          "ci": {"state": "green"}
        }
      ],
      "blockers": [],
      "exactNextMachineAction": "watch deploy",
      "exactCaptainAction": "explicit merge/stamp decision if not already recorded",
      "updatedAt": "2026-07-16T18:05:00Z"
    }
  ]
}
JSON
  FM_EFFORT_NOW=2026-07-16T18:10:00Z "$LAVISH" --rows "$rows" --inventory "$inventory" --output "$html" --cards-json "$cards" >/dev/null
  review=$(jq -r '.[0].review_state' "$cards")
  urls=$(jq -r '.[0].urls | join(" ")' "$cards")
  decision_options=$(jq -r '.[0].decision_options[].value' "$cards" | tr '\n' ' ')
  [ "$review" = "real-human-approved: human-reviewer" ] || fail "expected human review state, got $review"
  assert_contains "$urls" "https://linear.app/getlindy/issue/REL-1/demo" "card keeps Linear URL"
  assert_contains "$urls" "https://github.com/lindy-ai/lindy/pull/123" "card keeps PR URL"
  assert_contains "$decision_options" "CLOSE_AS_OBSOLETE" "decision controls include close-as-obsolete"
  assert_grep "window.lavish.queuePrompt" "$html" "HTML wires Lavish queuePrompt"
  assert_grep "FM_EFFORT_DECISION effort_id=" "$html" "HTML carries machine-parseable prompt"
  pass "lavish cards map inventory fields and decision controls"
}

case_bot_only_review_flag_is_visible() {
  local d rows inventory cards flag review
  d="$TMP_ROOT/botflag"
  mkdir -p "$d"
  rows="$d/rows.json"
  inventory="$d/inventory.json"
  cards="$d/cards.json"
  printf '[{"effort_id":"PR-2","stage":"in_review","updated_at":"2026-07-16T18:00:00Z","actor":"test","kind":"stage","note":"","evidence":"https://github.com/lindy-ai/lindy/pull/2"}]\n' > "$rows"
  printf '{"items":[{"logicalId":"PR-2","prs":[{"url":"https://github.com/lindy-ai/lindy/pull/2","review":{"decision":"APPROVED","approvals":[]}}]}]}\n' > "$inventory"
  "$LAVISH" --rows "$rows" --inventory "$inventory" --output "$d/board.html" --cards-json "$cards" >/dev/null
  flag=$(jq -r '.[0].bot_only_review_flag' "$cards")
  review=$(jq -r '.[0].review_state' "$cards")
  [ "$flag" = true ] || fail "expected bot-only flag"
  [ "$review" = "bot-only-or-unverified approval" ] || fail "unexpected review state: $review"
  pass "bot-only approval is explicitly flagged"
}

case_repo_allowlist_filters_personal_pr_urls() {
  local d rows inventory html cards urls html_text
  d="$TMP_ROOT/allowlist"
  mkdir -p "$d"
  rows="$d/rows.json"
  inventory="$d/inventory.json"
  html="$d/board.html"
  cards="$d/cards.json"
  cat > "$rows" <<'JSON'
[
  {
    "effort_id": "MIXED",
    "stage": "in_review",
    "updated_at": "2026-07-16T18:00:00Z",
    "actor": "test",
    "kind": "stage",
    "note": "",
    "evidence": "https://github.com/twaldin/personal/pull/1"
  }
]
JSON
  cat > "$inventory" <<'JSON'
{
  "items": [
    {
      "logicalId": "MIXED",
      "linear": [{"url": "https://linear.app/getlindy/issue/MIXED/demo"}],
      "prs": [{"url": "https://github.com/twaldin/personal/pull/1"}]
    }
  ]
}
JSON
  "$LAVISH" --rows "$rows" --inventory "$inventory" --repo-allowlist "lindy-ai/*" --output "$html" --cards-json "$cards" >/dev/null
  urls=$(jq -r '.[0].urls | join(" ")' "$cards")
  html_text=$(cat "$html")
  assert_contains "$urls" "https://linear.app/getlindy/issue/MIXED/demo" "allowlist keeps non-GitHub URL"
  assert_not_contains "$urls" "https://github.com/twaldin/personal/pull/1" "allowlist removes personal PR URL"
  assert_not_contains "$html_text" "https://github.com/twaldin/personal/pull/1" "HTML omits personal PR URL"
  pass "repo allowlist filters personal GitHub URLs from Lavish cards"
}

case_cards_map_inventory_fields
case_bot_only_review_flag_is_visible
case_repo_allowlist_filters_personal_pr_urls
