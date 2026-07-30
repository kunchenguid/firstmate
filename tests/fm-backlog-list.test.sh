#!/usr/bin/env bash
# tests/fm-backlog-list.test.sh - hidden backlog category listing and inheritance.
#
# Coverage:
#   - hold reason starting with "backlog:" is hidden from routine listing
#   - --backlog shows only those items
#   - deferred (future/hold-until) and parked (non-backlog: reason) stay visible
#   - routine surfaces print the hidden-count hint
#   - fleet-snapshot / fleet-view inherit the hide via the shared backlog filter
#   - --include-backlog keeps backlogged rows in the snapshot
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIST="$ROOT/bin/fm-backlog-list.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-list)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

write_mixed_backlog() {
  local path=$1
  cat > "$path" <<'EOF'
# Backlog

## In flight

## Queued
- [ ] active-do - Ready to ship (repo: alpha) (kind: ship) (since 2026-07-15)
- [ ] defer-later - Defer until Monday (repo: alpha) (kind: ship) (since 2026-07-15) (hold: defer until Monday) (hold-kind: future) (hold-until: 2030-01-01)
- [ ] park-vendor - Waiting on vendor (repo: alpha) (kind: ship) (since 2026-07-15) (hold: waiting on vendor) (hold-kind: parked)
- [ ] cold-storage - Not now (repo: alpha) (kind: ship) (since 2026-07-15) (hold: backlog: cold storage) (hold-kind: parked)
- [ ] backlog-note - Shelf it (repo: beta) (kind: scout) (since 2026-07-16) (hold: backlog: revisit after launch) (hold-kind: future)

## Done
- [x] finished-task - Finished work (repo: alpha) (kind: ship) (done 2026-07-10)
EOF
}

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  write_mixed_backlog "$home/data/backlog.md"
  mkdir -p "$home/data/backlog-note" "$home/data/defer-later"
  printf '# Hidden report\n' > "$home/data/backlog-note/report.md"
  printf '# Visible report\n' > "$home/data/defer-later/report.md"
  printf '%s\n' \
    '- cold-storage - fixture (home: ; scope: fixture; projects: alpha; added 2026-07-29)' \
    '- defer-later - fixture (home: ; scope: fixture; projects: alpha; added 2026-07-29)' \
    > "$home/data/secondmates.md"
  printf 'kind=ship\nproject=alpha\n' > "$home/state/cold-storage.meta"
  printf 'kind=ship\nproject=alpha\n' > "$home/state/defer-later.meta"
  printf '%s\n' "$home"
}

# --- fm-backlog-list.sh ------------------------------------------------------

test_routine_hides_backlogged_keeps_defer_and_parked() {
  local home out
  home=$(new_home routine-list)
  out=$(FM_HOME="$home" "$LIST" --file "$home/data/backlog.md")

  assert_contains "$out" "active-do" "routine listing dropped ready work"
  assert_contains "$out" "defer-later" "routine listing hid a deferred (future) hold"
  assert_contains "$out" "park-vendor" "routine listing hid a parked non-backlog hold"
  assert_not_contains "$out" "cold-storage" "routine listing showed a backlog: hold"
  assert_not_contains "$out" "backlog-note" "routine listing showed a second backlog: hold"
  assert_contains "$out" "2 backlogged hidden - use bin/fm-backlog-list.sh --backlog to list" \
    "routine listing omitted the hidden-count hint"
  assert_contains "$out" "finished-task" "routine listing dropped a Done item"

  pass "routine listing hides backlog: holds and keeps defer/parked visible"
}

test_explicit_backlog_mode_lists_only_hidden() {
  local home out
  home=$(new_home explicit-backlog)
  out=$(FM_HOME="$home" "$LIST" --backlog --file "$home/data/backlog.md")

  assert_contains "$out" "cold-storage" "explicit --backlog omitted a backlog: hold"
  assert_contains "$out" "backlog-note" "explicit --backlog omitted the second backlog: hold"
  assert_contains "$out" "(hold: backlog: cold storage)" "explicit --backlog dropped hold metadata"
  assert_not_contains "$out" "active-do" "explicit --backlog included non-backlogged work"
  assert_not_contains "$out" "defer-later" "explicit --backlog included a deferred item"
  assert_not_contains "$out" "park-vendor" "explicit --backlog included a parked item"
  assert_not_contains "$out" "backlogged hidden" "explicit --backlog printed the hide hint"
  assert_contains "$out" "(shown 2 backlogged item title line(s))" \
    "explicit --backlog did not report its count"

  pass "explicit --backlog lists only hidden backlog: holds"
}

test_include_backlog_shows_everything() {
  local home out
  home=$(new_home include-all)
  out=$(FM_HOME="$home" "$LIST" --include-backlog --file "$home/data/backlog.md")

  assert_contains "$out" "active-do" "include mode dropped ready work"
  assert_contains "$out" "cold-storage" "include mode dropped a backlog: hold"
  assert_contains "$out" "defer-later" "include mode dropped a deferred hold"
  assert_not_contains "$out" "backlogged hidden" "include mode printed a hide hint"
  assert_contains "$out" "includes backlogged" "include mode omitted its accounting note"

  pass "--include-backlog lists every title line without hiding"
}

test_empty_backlog_mode_is_explicit() {
  local home out
  home=$(new_home empty-backlog-mode)
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog
## Queued
- [ ] only-active - Just do it (repo: alpha)
## Done
EOF
  out=$(FM_HOME="$home" "$LIST" --backlog --file "$home/data/backlog.md")
  assert_contains "$out" "(no backlogged items)" "empty --backlog mode lacked the empty marker"
  pass "--backlog on a file with no backlog: holds is explicit about emptiness"
}

# --- fleet snapshot / view inheritance ---------------------------------------

test_fleet_snapshot_hides_backlogged_by_default() {
  local home snap view
  home=$(new_home snap-hide)
  snap=$(FM_HOME="$home" "$SNAPSHOT" --json)
  view=$(FM_HOME="$home" "$VIEW")

  printf '%s' "$snap" | jq -e '
    (.backlog.hidden_backlogged_count == 2)
    and (.backlog.hidden_backlogged_hint | test("2 backlogged hidden"))
    and (.backlog.hidden_backlogged_hint | test("fm-backlog-list.sh --backlog"))
    and ([.backlog.records[] | select(.id == "cold-storage")] | length) == 0
    and ([.backlog.records[] | select(.id == "backlog-note")] | length) == 0
    and ([.backlog.records[] | select(.id == "defer-later")] | length) == 1
    and ([.backlog.records[] | select(.id == "park-vendor")] | length) == 1
    and ([.backlog.records[] | select(.id == "active-do")] | length) == 1
    and (.backlog.hidden_backlogged_ids == ["backlog-note", "cold-storage"])
    and ([.tasks[] | select(.id == "cold-storage")] | length) == 0
    and ([.tasks[] | select(.id == "defer-later")] | length) == 1
    and ([.scout_reports[] | select(.id == "backlog-note")] | length) == 0
    and ([.scout_reports[] | select(.id == "defer-later")] | length) == 1
    and ([.secondmate_current.records[] | select(.id == "cold-storage")] | length) == 0
    and ([.secondmate_current.registry.records[] | select(.id == "cold-storage")] | length) == 0
    and ([.secondmate_current.records[] | select(.id == "defer-later")] | length) == 1
    and (.backlog.records[] | select(.id == "defer-later") | .backlogged == false)
    and (.backlog.records[] | select(.id == "park-vendor") | .hold_kind == "parked")
  ' >/dev/null \
    || fail "fleet snapshot did not hide backlog: holds or preserve defer/parked"

  assert_not_contains "$view" "cold-storage" "fleet view showed a hidden backlog: hold"
  assert_contains "$view" "defer-later" "fleet view hid a deferred hold"
  assert_contains "$view" "park-vendor" "fleet view hid a parked hold"
  assert_contains "$view" "2 backlogged hidden - use bin/fm-backlog-list.sh --backlog to list" \
    "fleet view omitted the hidden-count hint"

  pass "fleet snapshot and view hide backlog: holds and keep defer/parked"
}

test_fleet_snapshot_include_backlog_keeps_rows() {
  local home snap
  home=$(new_home snap-include)
  snap=$(FM_HOME="$home" "$SNAPSHOT" --json --include-backlog)

  printf '%s' "$snap" | jq -e '
    (.backlog.hidden_backlogged_count == 2)
    and (.backlog.hidden_backlogged_hint == null)
    and ([.backlog.records[] | select(.id == "cold-storage" and .backlogged == true)] | length) == 1
    and ([.backlog.records[] | select(.id == "backlog-note" and .backlogged == true)] | length) == 1
    and ([.backlog.records[] | select(.id == "defer-later" and .backlogged == false)] | length) == 1
    and ([.tasks[] | select(.id == "cold-storage" and .backlog.backlogged == true)] | length) == 1
    and ([.tasks[] | select(.id == "defer-later" and .backlog.backlogged == false)] | length) == 1
    and ([.scout_reports[] | select(.id == "backlog-note")] | length) == 1
    and ([.scout_reports[] | select(.id == "defer-later")] | length) == 1
    and ([.secondmate_current.records[] | select(.id == "cold-storage")] | length) == 1
    and ([.secondmate_current.registry.records[] | select(.id == "cold-storage")] | length) == 1
    and ((.backlog.records[] | select(.id == "cold-storage") | .hold_reason) | startswith("backlog:"))
  ' >/dev/null \
    || fail "fleet snapshot --include-backlog did not keep tagged backlog: rows"

  pass "fleet snapshot --include-backlog retains backlogged rows with tags"
}

test_hidden_secondmates_do_not_consume_registry_cap() {
  local home snap
  home=$(new_home registry-cap)
  snap=$(FM_HOME="$home" FM_SNAPSHOT_REGISTRY_RECORDS=1 "$SNAPSHOT" --json)

  printf '%s' "$snap" | jq -e '
    (.secondmate_current.registry.records | map(.id)) == ["defer-later"]
    and (.secondmate_current.registry.records_in_window == 1)
    and (.secondmate_current.registry.records_truncated == false)
    and (.secondmate_current.registry.complete == true)
    and (.secondmate_current.records | map(.id)) == ["defer-later"]
  ' >/dev/null \
    || fail "hidden secondmate consumed the visible registry cap or truncation accounting"

  pass "hidden secondmates are filtered before registry bounds and accounting"
}

test_lib_predicate_helpers() {
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  fm_hold_reason_is_backlogged "backlog: cold" || fail "prefix match failed"
  fm_hold_reason_is_backlogged "backlog:" || fail "bare prefix should match"
  if fm_hold_reason_is_backlogged "Backlog: cold"; then
    fail "predicate must be case-sensitive"
  fi
  if fm_hold_reason_is_backlogged "waiting on vendor"; then
    fail "parked reason must not match"
  fi
  if fm_hold_reason_is_backlogged "defer until Monday"; then
    fail "deferred reason must not match"
  fi
  fm_backlog_title_line_is_backlogged \
    '- [ ] x - t (hold: backlog: note) (hold-kind: parked)' \
    || fail "title-line detector missed backlog: hold"
  if fm_backlog_title_line_is_backlogged \
    '- [ ] x - t (hold: waiting on vendor) (hold-kind: parked)'; then
    fail "title-line detector false-positive on parked"
  fi
  hint=$(fm_backlog_hidden_hint 3)
  assert_contains "$hint" "3 backlogged hidden" "hint missing count"
  assert_contains "$hint" "bin/fm-backlog-list.sh --backlog" "hint missing list command"
  empty=$(fm_backlog_hidden_hint 0)
  [ -z "$empty" ] || fail "zero count must print no hint"

  pass "shared predicate and hint helpers match the backlog: contract"
}

# --- run ---------------------------------------------------------------------

test_routine_hides_backlogged_keeps_defer_and_parked
test_explicit_backlog_mode_lists_only_hidden
test_include_backlog_shows_everything
test_empty_backlog_mode_is_explicit
test_fleet_snapshot_hides_backlogged_by_default
test_fleet_snapshot_include_backlog_keeps_rows
test_hidden_secondmates_do_not_consume_registry_cap
test_lib_predicate_helpers

echo "ALL PASS: fm-backlog-list / hidden backlog category"
