#!/usr/bin/env bash
# Behavior tests for the read-only intake TUI.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-intake-tui-tests)
BASE_PATH=$PATH
NOW=1800000000

write_fixture_snapshot() { # <path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'JSON'
{
  "generated_at": "2027-01-15T08:00:00Z",
  "items": [
    {
      "id": "EM-WARN",
      "source": "linear",
      "lane": "oncall",
      "title": "Warn oncall ticket",
      "url": "https://linear.app/acme/issue/EM-WARN",
      "assignee": "tim@example.invalid",
      "priority": "2",
      "state": "Todo",
      "detected_at": "2027-01-15T07:00:00Z",
      "sla_class": "oncall",
      "sla_warn_at": "2027-01-15T07:30:00Z",
      "sla_breach_at": "2027-01-15T09:00:00Z"
    },
    {
      "id": "EM-BREACH",
      "source": "linear",
      "lane": "oncall",
      "title": "Breached oncall ticket",
      "url": "https://linear.app/acme/issue/EM-BREACH",
      "assignee": "tim@example.invalid",
      "priority": "1",
      "state": "In Progress",
      "detected_at": "2027-01-15T06:00:00Z",
      "sla_class": "oncall",
      "sla_warn_at": "2027-01-15T06:30:00Z",
      "sla_breach_at": "2027-01-15T07:00:00Z"
    },
    {
      "id": "EM-NORMAL",
      "source": "linear",
      "lane": "normal",
      "title": "Normal ticket carrying ghp_abcdefghijklmnopqrstuv1234567890",
      "url": "https://linear.app/acme/issue/EM-NORMAL?token=secret-linear-key",
      "assignee": "tim@example.invalid",
      "priority": "3",
      "state": "Todo",
      "detected_at": "2027-01-15T08:00:00Z",
      "sla_class": "normal",
      "sla_warn_at": null,
      "sla_breach_at": null
    },
    {
      "id": "github:pr:101",
      "source": "github",
      "lane": "pr",
      "title": "Captain-authored PR",
      "url": "https://github.com/acme/repo/pull/101",
      "assignee": "twaldin",
      "priority": null,
      "state": "open",
      "detected_at": "2027-01-15T08:00:00Z",
      "sla_class": "pr",
      "sla_warn_at": null,
      "sla_breach_at": null
    },
    {
      "id": "github:review:201",
      "source": "github",
      "lane": "review",
      "title": "Needs review",
      "url": "https://github.com/acme/repo/pull/201",
      "assignee": "twaldin",
      "priority": null,
      "state": "open",
      "detected_at": "2027-01-15T07:00:00Z",
      "sla_class": "review",
      "sla_warn_at": "2027-01-15T10:00:00Z",
      "sla_breach_at": "2027-01-16T07:00:00Z"
    }
  ]
}
JSON
}

make_fake_crew_state() { # <dir>
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  alpha) printf 'state: working · source: pane · active turn\n' ;;
  *) printf 'state: unknown · source: none\n' ;;
esac
SH
  chmod +x "$fakebin/fm-crew-state.sh"
}

run_tui_once() { # <home> <fakebin> [extra args...]
  local home=$1 fakebin=$2
  shift 2
  env PATH="$fakebin:$BASE_PATH" \
    TERM=xterm \
    FM_HOME="$home" \
    FM_INTAKE_TUI_NOW_EPOCH="$NOW" \
    FM_INTAKE_TUI_CREW_STATE_CMD="$fakebin/fm-crew-state.sh" \
    "$ROOT/bin/fm-intake-tui.sh" --once "$@"
}

line_number() { # <haystack> <needle>
  printf '%s\n' "$1" | awk -v needle="$2" 'index($0, needle) { print NR; exit }'
}

test_renders_sections_colors_sorting_and_redaction() {
  local case_dir home fakebin out breach_line warn_line
  case_dir="$TMP_ROOT/render"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state/intake" "$home/state" "$home/worktrees/alpha"
  write_fixture_snapshot "$home/state/intake/snapshot.json"
  printf 'worktree=%s\n' "$home/worktrees/alpha" > "$home/state/alpha.meta"
  make_fake_crew_state "$fakebin"

  out=$(run_tui_once "$home" "$fakebin" --color always)
  assert_contains "$out" "ONCALL tickets" "TUI should render oncall section"
  assert_contains "$out" "NORMAL tickets" "TUI should render normal section"
  assert_contains "$out" "MY PRs / REVIEW queue" "TUI should render PR/review section"
  assert_contains "$out" "FLEET LANES" "TUI should render fleet lanes section"
  assert_contains "$out" "EM-BREACH" "TUI should render breached ticket"
  assert_contains "$out" "EM-WARN" "TUI should render warning ticket"
  assert_contains "$out" "github:pr:101" "TUI should render authored PR"
  assert_contains "$out" "github:review:201" "TUI should render review request"
  assert_contains "$out" "alpha" "TUI should render fleet lane id"
  assert_contains "$out" "pane" "TUI should render fleet lane source"
  assert_contains "$out" $'\033[31m  EM-BREACH' "breached item should be red"
  assert_contains "$out" $'\033[33m  EM-WARN' "warn item should be yellow"
  assert_not_contains "$out" "ghp_abcdefghijklmnopqrstuv1234567890" "TUI must not render full GitHub-token-shaped text"
  assert_not_contains "$out" "secret-linear-key" "TUI must not render full secret-shaped text"

  breach_line=$(line_number "$out" "EM-BREACH")
  warn_line=$(line_number "$out" "EM-WARN")
  [ -n "$breach_line" ] && [ -n "$warn_line" ] || fail "oncall line numbers missing"
  [ "$breach_line" -lt "$warn_line" ] || fail "oncall tickets should sort by earliest SLA breach"

  pass "intake TUI renders sections, SLA colors, sorted oncall rows, fleet lanes, and redacts token-shaped text"
}

test_missing_and_empty_snapshot_degrade_cleanly() {
  local case_dir home fakebin out
  case_dir="$TMP_ROOT/missing"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state/intake"
  make_fake_crew_state "$fakebin"

  out=$(run_tui_once "$home" "$fakebin" --color never)
  assert_contains "$out" "no intake data yet - is config/intake.env enabled?" "missing snapshot should show empty-state message"

  : > "$home/state/intake/snapshot.json"
  out=$(run_tui_once "$home" "$fakebin" --color never)
  assert_contains "$out" "no intake data yet - is config/intake.env enabled?" "empty snapshot should show empty-state message"

  pass "intake TUI degrades cleanly for missing and empty snapshots"
}

test_intake_status_counts_oncall_and_breaches() {
  local case_dir home out
  case_dir="$TMP_ROOT/status"
  home="$case_dir/home"
  mkdir -p "$home/state/intake"
  write_fixture_snapshot "$home/state/intake/snapshot.json"

  out=$(env FM_HOME="$home" FM_INTAKE_TUI_NOW_EPOCH="$NOW" "$ROOT/bin/fm-intake-status.sh")
  [ "$out" = "intake: 2 oncall / 1 breach" ] || fail "unexpected intake status: $out"

  pass "intake status helper reports oncall and breach counts"
}

test_renders_sections_colors_sorting_and_redaction
test_missing_and_empty_snapshot_degrade_cleanly
test_intake_status_counts_oncall_and_breaches
