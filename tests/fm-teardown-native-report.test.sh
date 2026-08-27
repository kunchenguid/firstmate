#!/usr/bin/env bash
# Tests for the native report path teardown (story fmops-07 §1, plan §2.3).
#
# The fork engine (nphattai/tasks-axi@0.3.0) writes the report at the native
# path `data/plans/<epic>/reports/<id>-report.md` from `add`, and the brief
# tells the worker to write there directly (via `tasks-axi report path`). So:
#   - teardown NO LONGER creates the dcen-11 symlink bridge (the helper
#     `epic_report_symlink` and the caller `bridge_report_into_epic` are
#     both deleted from fm-teardown.sh + fm-epic-status-lib.sh).
#   - teardown's scout `done` suggestion uses `--report <native>` instead of
#     the `--note "report: ..."` workaround that dodged the pre-fork title
#     pollution.
#   - epic-slug derivation stays on fm-captain-hold.sh (it is still the ONE
#     owner used by teardown before, and other callers still need it).
#   - non-composed captain-hold minting still stamps [<slug>] at creation
#     (fmops-07 §5 routes composed-shape mints to the register; direct
#     non-composed mints continue on tasks-axi via tasks_axi_mint_captain_hold).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-native)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (backend cases)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (backend cases)"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin b
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # Story fmops-07 §1: the fork engine's `add` requires --epic <slug> and a
  # matching data/plans/*-epic-<slug>/epic.md. Seed a standing `sample` epic
  # so scout fixtures can be legitimately membered.
  mkdir -p "$home/data/plans/000000-epic-sample/stories" \
    "$home/data/plans/000000-epic-sample/reports" \
    "$home/data/plans/000000-epic-ops/stories"
  cat > "$home/data/plans/000000-epic-sample/epic.md" <<'EOF'
---
epic: sample
title: Sample fixture epic
---

# Sample fixture epic
EOF
  cat > "$home/data/plans/000000-epic-ops/epic.md" <<'EOF'
---
epic: ops
title: Ops catch-all fixture
---

# Ops catch-all fixture
EOF
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

# Seed a completed scout ready for teardown: backlog row, report at the LEGACY
# path (so we prove teardown does not touch it or create a bridge; a real
# fork-engine seed would write the native path directly, but that requires the
# fork installed which the test env may not have).
seed_scout_legacy_report_path() {  # <home> <id> <title> [epic]
  local home=$1 id=$2 title=$3 epic=${4:-sample}
  mkdir -p "$home/data/$id"
  printf '# report body\n' > "$home/data/$id/report.md"
  (cd "$home" && tasks-axi add "$id" "$title" --kind scout --repo sample --start --epic "$epic" >/dev/null) \
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

# --- 2. teardown creates NO symlink into the epic reports/ dir --------------
test_teardown_does_not_symlink() {
  local home epic_reports
  home=$(make_home no-symlink)
  mkdir -p "$home/data/plans/000000-epic-demox/stories"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/000000-epic-demox/epic.md"

  seed_scout_legacy_report_path "$home" dcen-epic "[demox] Investigate the thing" demox
  run_teardown "$home" dcen-epic > "$home/td.out" 2>/dev/null \
    || fail "epic scout teardown failed"
  epic_reports="$home/data/plans/000000-epic-demox/reports"
  # No symlink, no reports/ dir created by teardown (the fork engine creates
  # reports/ when the worker writes there directly, not teardown).
  [ ! -e "$epic_reports/dcen-epic-report.md" ] \
    || fail "teardown created a report entry in the epic reports/ dir (bridge should be dead)"
  # And the legacy report stays untouched where the worker wrote it.
  { [ -f "$home/data/dcen-epic/report.md" ] && [ ! -L "$home/data/dcen-epic/report.md" ]; } \
    || fail "the legacy report was moved or symlinked by teardown"
  pass "teardown creates no dcen-11 symlink for an epic scout (bridge is dead)"
}

# --- 3. epic-slug still works (fm-captain-hold.sh owns the derivation) -----
test_epic_slug_subcommand() {
  local home slug
  home=$(make_home slug)
  mkdir -p "$home/data/plans/000000-epic-demox/stories"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/000000-epic-demox/epic.md"
  # member-1 belongs to demox; loose-1 goes under the standing sample epic
  # (make_home seeds it) so it is a legitimate task that is NOT a demox member.
  (cd "$home" && tasks-axi add member-1 "[demox] member work" --repo sample --queue --epic demox >/dev/null)
  (cd "$home" && tasks-axi add loose-1 "unrelated work" --repo sample --queue --epic sample >/dev/null)

  slug=$(run_captain "$home" epic-slug member-1)
  [ "$slug" = demox ] || fail "epic-slug did not derive the member's epic (got: '$slug')"
  slug=$(run_captain "$home" epic-slug loose-1)
  [ "$slug" = sample ] || fail "epic-slug did not derive loose-1's sample epic (got: '$slug')"
  pass "epic-slug prints the member's epic and nothing for a non-member"
}

# --- 4. non-composed captain-hold mint still stamps [<slug>] and the id guard fires --
test_membership_stamp_and_id_guard() {
  local home show longid id64
  home=$(make_home stamp)
  mkdir -p "$home/data/plans/000000-epic-demox/stories" "$home/data/origin-tag"
  printf '%s\n' '---' 'epic: demox' 'title: Demo X' '---' '# Demo X' \
    > "$home/data/plans/000000-epic-demox/epic.md"
  printf '# report\n' > "$home/data/origin-tag/report.md"
  (cd "$home" && tasks-axi add origin-tag "[demox] origin work" --repo sample --queue --epic demox >/dev/null)

  # A non-composed captain-hold routed through tasks_axi_mint_captain_hold: story
  # fmops-07 §5 preserves this path for direct non-composed mints, and it still
  # stamps the [<slug>] tag.
  run_captain "$home" hold demox-hold-a --title "resolve X" \
    --reason "captain choice pending" --origin origin-tag >/dev/null \
    || fail "could not create the epic-origin captain hold"
  show=$(cd "$home" && tasks-axi show demox-hold-a --full)
  assert_contains "$show" 'title: "[demox] resolve X"' \
    "a newly created epic-scoped task did not carry the [<slug>] membership tag"

  # The dashboard task-detail route rejects ids > 64 chars, so creation refuses them.
  longid=$(printf 'x%.0s' $(seq 1 70))
  if run_captain "$home" hold "$longid" --title t --reason r >/dev/null 2>&1; then
    fail "creation minted an id longer than 64 chars the dashboard would reject"
  fi
  id64=$(printf 'a%.0s' $(seq 1 64))
  run_captain "$home" hold "$id64" --title t64 --reason r64 >/dev/null 2>&1 \
    || fail "a 64-char id was wrongly refused"

  pass "non-composed captain-hold stamps [<slug>] at creation and enforces the 64-char id cap"
}

# memval-04 broadening: a completed scout's one-line `done:` finding is pushed
# into fleet memory as the task lands, via the existing fm-remember.sh. These
# cases prove the trigger fires with the right fact shape when brain-axi is
# present, and is a silent no-op when it is absent (fail-open). make_home's
# fakebin has NO brain-axi, so every other teardown case here already exercises
# the absent path; the explicit case below pins it.
add_recording_brain() {  # <home> <log-path>
  local home=$1 log=$2
  cat > "$home/fakebin/brain-axi" <<SH
#!/usr/bin/env bash
# args: remember <fact> --provenance <p> --store <s>
[ "\${1:-}" = remember ] || exit 0
printf '%s\n' "\${2:-}" >> "$log"
exit 0
SH
  chmod +x "$home/fakebin/brain-axi"
}

test_scout_finding_is_remembered() {
  local home brainlog
  home=$(make_home remember-scout)
  brainlog="$home/brain.log"
  add_recording_brain "$home" "$brainlog"
  seed_scout_legacy_report_path "$home" scout-mem "[sample] Investigate the seed store"
  # Overwrite the seed's generic done line with a concrete finding.
  printf 'working: dug into the store\n' > "$home/state/scout-mem.status"
  printf 'done: the seed store corrupts under concurrent writers; needs a lock\n' \
    >> "$home/state/scout-mem.status"

  run_teardown "$home" scout-mem > "$home/td.out" 2>/dev/null \
    || fail "scout teardown failed"
  assert_present "$brainlog" "a completed scout should push its finding into fleet memory"
  assert_grep "Scout scout-mem finding: the seed store corrupts under concurrent writers; needs a lock" \
    "$brainlog" "the remembered fact should carry the scout's one-line done finding"
  pass "teardown: a scout's last done line is remembered as its finding"
}

test_scout_teardown_brain_absent_is_silent_noop() {
  local home
  home=$(make_home absent-brain-scout)
  # No brain-axi in the fakebin (make_home installs none): the remember must be
  # a pure no-op and teardown must still complete cleanly. Guard banners this
  # sandbox emits (tangle/watcher) go to stderr and are dropped like the other
  # teardown cases here; the fail-open proof is a clean rc 0 and completion.
  seed_scout_legacy_report_path "$home" scout-abs "[sample] a quiet scout"
  printf 'done: nothing surprising, the config is fine as-is\n' > "$home/state/scout-abs.status"
  run_teardown "$home" scout-abs > "$home/td.out" 2>/dev/null \
    || fail "scout teardown must succeed with brain-axi absent (fail open)"
  grep -F 'teardown scout-abs complete' "$home/td.out" >/dev/null \
    || fail "teardown did not report completion with brain-axi absent"
  pass "teardown: a scout with brain-axi absent completes and the remember is a silent no-op"
}

# A scout whose status log carries no `done:` line (e.g. only decision/blocker
# lines) must still tear down cleanly: the finding lookup finds nothing and
# remembers nothing, and must never abort teardown under set -u.
test_scout_without_done_line_tears_down_cleanly() {
  local home brainlog
  home=$(make_home no-done-line)
  brainlog="$home/brain.log"
  add_recording_brain "$home" "$brainlog"
  seed_scout_legacy_report_path "$home" scout-nodone "[sample] no done line"
  printf 'working: still digging, no verdict yet\n' > "$home/state/scout-nodone.status"
  run_teardown "$home" scout-nodone > "$home/td.out" 2>/dev/null \
    || fail "a scout with no done line must still tear down cleanly"
  grep -F 'teardown scout-nodone complete' "$home/td.out" >/dev/null \
    || fail "teardown did not complete for a scout with no done line"
  assert_absent "$brainlog" "a scout with no done line must remember nothing"
  pass "teardown: a scout with no done line tears down cleanly and remembers nothing"
}

test_teardown_does_not_symlink
test_epic_slug_subcommand
test_membership_stamp_and_id_guard
test_scout_finding_is_remembered
test_scout_teardown_brain_absent_is_silent_noop
test_scout_without_done_line_tears_down_cleanly
