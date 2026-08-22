#!/usr/bin/env bash
# Tests for the report -> epic-dir auto-bridge (report dcen-10).
#
# A completed scout/ship writes its canonical report to data/<id>/report.md, but
# the dashboard artifact tab scans data/plans/<epic>/reports/ and never sees it.
# fm-teardown.sh now bridges that gap automatically: it symlinks the report into
# the epic's reports/ dir so the artifact tab shows it with zero hand-patching.
# The symlink mechanics are owned once by fm-epic-status-lib.sh (epic_report_symlink)
# and the epic slug by fm-captain-hold.sh (epic-slug), so teardown re-parses nothing.
#
# Covers:
#   - epic_report_symlink: relative symlink, idempotent, real-file-safe, skip-when-absent
#   - full teardown: an epic-tagged scout gets the symlink; a standalone scout is skipped
#   - fm-captain-hold.sh epic-slug: prints the slug for a member, empty for a non-member
#   - epic membership stamping at creation (the [<slug>] tag)
#   - the <=64-char id guard the dashboard route (ID_RE) needs
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-report-symlink)

# --- 1. pure symlink mechanics (no tasks-axi needed) ------------------------
test_symlink_mechanics() {
  local d="$TMP_ROOT/mech/data" epic tgt
  # shellcheck source=bin/fm-epic-status-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-epic-status-lib.sh"
  epic="$d/plans/260822-epic-x"
  tgt="$epic/reports/dcen-99-report.md"
  mkdir -p "$d/dcen-99" "$epic"
  printf '# real report\n' > "$d/dcen-99/report.md"

  epic_report_symlink "$d" dcen-99 "$epic"
  [ -L "$tgt" ] || fail "symlink not created for an epic task"
  [ "$(readlink "$tgt")" = "../../../dcen-99/report.md" ] \
    || fail "symlink is not the canonical relative target"
  [ -f "$tgt" ] || fail "symlink does not resolve to the real report"
  assert_grep "# real report" "$tgt" "symlink does not read the real report content"
  # the canonical file stays a REAL file where the scout wrote it (never moved)
  { [ -f "$d/dcen-99/report.md" ] && [ ! -L "$d/dcen-99/report.md" ]; } \
    || fail "the canonical report was moved or replaced"

  # idempotent: a second run leaves exactly one entry pointing the same way
  epic_report_symlink "$d" dcen-99 "$epic"
  [ "$(find "$epic/reports" -name 'dcen-99-report.md' | wc -l | tr -d ' ')" = 1 ] \
    || fail "re-run duplicated the report entry"

  # real-file-safe: a legacy hand-moved real file at the target is never clobbered
  mkdir -p "$d/dcen-88"
  printf '# r88\n' > "$d/dcen-88/report.md"
  printf 'LEGACY REAL FILE\n' > "$epic/reports/dcen-88-report.md"
  epic_report_symlink "$d" dcen-88 "$epic" 2>/dev/null
  [ ! -L "$epic/reports/dcen-88-report.md" ] \
    || fail "a real file at the target was clobbered with a symlink"
  assert_grep "LEGACY REAL FILE" "$epic/reports/dcen-88-report.md" \
    "the legacy real report was overwritten"

  # no canonical report -> silent skip, no stray symlink
  epic_report_symlink "$d" dcen-77 "$epic" || fail "a missing report must skip, not fail"
  [ ! -e "$epic/reports/dcen-77-report.md" ] \
    || fail "a symlink was created without a real report"

  pass "epic_report_symlink: relative symlink, idempotent, real-file-safe, skip-when-absent"
}

# The tasks-axi-backed cases need the real backend; skip cleanly without it.
command -v tasks-axi >/dev/null 2>&1 || { test_symlink_mechanics; echo "skip: tasks-axi not found (backend cases)"; exit 0; }
command -v jq >/dev/null 2>&1 || { test_symlink_mechanics; echo "skip: jq not found (backend cases)"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin b
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  for b in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$b"
    chmod +x "$fakebin/$b"
  done
  printf '%s\n' "$home"
}

run_captain() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$CAPTAIN" "$@"
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Seed a completed scout ready for teardown: backlog row, report, meta, a clean
# done status, and the passed captain-call completion gate teardown requires.
seed_scout() {  # <home> <id> <title>
  local home=$1 id=$2 title=$3
  mkdir -p "$home/data/$id"
  printf '# report body\n' > "$home/data/$id/report.md"
  (cd "$home" && tasks-axi add "$id" "$title" --kind scout --repo sample --start >/dev/null) \
    || fail "could not seed scout backlog row for $id"
  cat > "$home/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$home/projects/missing-$id
project=$home/projects/sample
harness=codex
kind=scout
mode=scout
EOF
  printf 'done: report complete, no captain call\n' > "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null 2>&1 \
    || fail "could not pass the captain-call completion gate for $id"
}

# --- 2. full teardown bridges an epic scout, skips a standalone one ----------
test_teardown_bridges_epic_and_skips_standalone() {
  local home epic_reports
  home=$(make_home e2e)
  mkdir -p "$home/data/plans/260822-epic-x/stories"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/260822-epic-x/epic.md"

  # epic member: carries the [demox] tag
  seed_scout "$home" dcen-epic "[demox] Investigate the thing"
  run_teardown "$home" dcen-epic > "$home/td-epic.out" 2>/dev/null \
    || fail "epic scout teardown failed"
  epic_reports="$home/data/plans/260822-epic-x/reports"
  [ -L "$epic_reports/dcen-epic-report.md" ] \
    || fail "teardown did not symlink the epic scout's report into the epic reports/ dir"
  [ "$(readlink "$epic_reports/dcen-epic-report.md")" = "../../../dcen-epic/report.md" ] \
    || fail "the bridged symlink is not the canonical relative target"
  assert_grep "# report body" "$epic_reports/dcen-epic-report.md" \
    "the bridged symlink does not resolve to the real report"
  { [ -f "$home/data/dcen-epic/report.md" ] && [ ! -L "$home/data/dcen-epic/report.md" ]; } \
    || fail "the canonical report did not survive teardown as a real file"

  # standalone: no epic tag -> no bridge, teardown still clean
  seed_scout "$home" loose-scout "Investigate something unrelated"
  run_teardown "$home" loose-scout > "$home/td-loose.out" 2>/dev/null \
    || fail "standalone scout teardown failed"
  [ ! -e "$epic_reports/loose-scout-report.md" ] \
    || fail "a standalone scout was wrongly bridged into an epic"
  { [ -f "$home/data/loose-scout/report.md" ] && [ ! -L "$home/data/loose-scout/report.md" ]; } \
    || fail "the standalone report did not survive teardown"

  pass "teardown auto-bridges an epic scout's report and skips a standalone one"
}

# --- 3. epic-slug derivation is reusable and returns empty for non-members ---
test_epic_slug_subcommand() {
  local home slug
  home=$(make_home slug)
  mkdir -p "$home/data/plans/260822-epic-x/stories"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/260822-epic-x/epic.md"
  (cd "$home" && tasks-axi add member-1 "[demox] member work" --repo sample --queue >/dev/null)
  (cd "$home" && tasks-axi add loose-1 "unrelated work" --repo sample --queue >/dev/null)

  slug=$(run_captain "$home" epic-slug member-1)
  [ "$slug" = demox ] || fail "epic-slug did not derive the member's epic (got: '$slug')"
  slug=$(run_captain "$home" epic-slug loose-1)
  [ -z "$slug" ] || fail "epic-slug wrongly reported an epic for a non-member (got: '$slug')"

  pass "epic-slug prints the member's epic and nothing for a non-member"
}

# --- 4. membership is stamped at creation; over-long ids are refused ---------
test_membership_stamp_and_id_guard() {
  local home show longid id64
  home=$(make_home stamp)
  mkdir -p "$home/data/plans/260822-epic-x/stories" "$home/data/origin-tag"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/260822-epic-x/epic.md"
  printf '# report\n' > "$home/data/origin-tag/report.md"
  (cd "$home" && tasks-axi add origin-tag "[demox] origin work" --repo sample --queue >/dev/null)

  # a task created for an epic origin is born a recognized member (the [<slug>] tag)
  run_captain "$home" hold demox-hold-a --title "resolve X" \
    --reason "captain choice pending" --origin origin-tag >/dev/null \
    || fail "could not create the epic-origin captain hold"
  show=$(cd "$home" && tasks-axi show demox-hold-a --full)
  assert_contains "$show" 'title: "[demox] resolve X"' \
    "a newly created epic-scoped task did not carry the [<slug>] membership tag"

  # the dashboard task-detail route rejects ids > 64 chars, so creation refuses them
  longid=$(printf 'x%.0s' $(seq 1 70))
  if run_captain "$home" hold "$longid" --title t --reason r >/dev/null 2>&1; then
    fail "creation minted an id longer than 64 chars the dashboard would reject"
  fi
  # a 64-char id is exactly at the route's limit and is accepted
  id64=$(printf 'a%.0s' $(seq 1 64))
  run_captain "$home" hold "$id64" --title t64 --reason r64 >/dev/null 2>&1 \
    || fail "a 64-char id was wrongly refused"

  pass "epic membership is stamped at creation and ids stay within the dashboard's 64-char limit"
}

test_symlink_mechanics
test_teardown_bridges_epic_and_skips_standalone
test_epic_slug_subcommand
test_membership_stamp_and_id_guard
