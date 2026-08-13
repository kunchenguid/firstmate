#!/usr/bin/env bash
# Behavioral regressions for the autonomous-run engine's deterministic gates:
# manifest freeze, closed tool allowlist, write and read areas, lane
# partitioning, single mutable custody, idempotent resume, and receipts.
#
# Every case drives bin/fm-run.sh as an executable. Nothing here inspects the
# script's source, so a rewrite that keeps the behavior keeps these passing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-run-engine)

HOME_DIR="$TMP_ROOT/home"
LANE_PERSONAL="$TMP_ROOT/lane-personal"
LANE_COMPANY="$TMP_ROOT/lane-company"
SOURCES="$TMP_ROOT/sources"
WORKTREE="$TMP_ROOT/worktree"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" \
  "$LANE_PERSONAL" "$LANE_COMPANY" "$SOURCES" "$WORKTREE"
printf 'test-personal personal %s\ntest-company company %s\n' \
  "$LANE_PERSONAL" "$LANE_COMPANY" > "$HOME_DIR/config/run-lanes.conf"

export FM_HOME="$HOME_DIR"
export FM_RUN_OWNER=engine-test

# capture <args...>: run the engine, leaving its combined output in OUT and its
# exit code in RC. Assigning in the current shell (rather than through a command
# substitution) is what keeps the gate's exit code visible to the assertions.
RC=0
OUT=
capture() {
  RC=0
  OUT=$("$RUN" "$@" 2>&1) || RC=$?
}

new_research_run() {  # <run-id>
  "$RUN" new "$1" --mode afk-research --lane test-personal --grant read-only >/dev/null
  "$RUN" set "$1" account.isolationAsserted true --json
  "$RUN" add "$1" source.readRoots "$SOURCES"
}

test_frozen_manifest_cannot_be_expanded() {
  local out
  new_research_run freeze-case
  "$RUN" freeze freeze-case >/dev/null

  capture set freeze-case budgets.wallSeconds 99 --json; out=$OUT
  expect_code 3 "$RC" "editing a frozen manifest"
  assert_contains "$out" 'cannot expand its own manifest' "frozen manifest edit was not refused"

  capture add freeze-case source.projects sneaky; out=$OUT
  expect_code 3 "$RC" "appending scope to a frozen manifest"

  # Even an out-of-band edit is caught: the hash recorded at freeze is what every
  # later command compares against, so tampering stops the run instead of
  # quietly widening it.
  printf '\n' >> "$HOME_DIR/data/runs/freeze-case/manifest.json"
  capture verify freeze-case; out=$OUT
  expect_code 1 "$RC" "verifying a tampered manifest"
  assert_contains "$out" 'changed after freeze' "manifest tampering was not detected"

  capture tool-check freeze-case read; out=$OUT
  expect_code 1 "$RC" "gate on a tampered manifest"
  pass "a frozen manifest cannot be expanded, and tampering stops every later gate"
}

test_tool_allowlist_is_closed() {
  local out
  new_research_run tools-case
  "$RUN" freeze tools-case >/dev/null

  capture tool-check tools-case read; out=$OUT
  expect_code 0 "$RC" "an allowlisted tool"
  assert_contains "$out" 'allowed' "allowlisted tool was not permitted"

  # Absence is the mechanism: a tool nobody thought to deny is still refused,
  # because permission comes only from the allowlist.
  capture tool-check tools-case some_unheard_of_tool; out=$OUT
  expect_code 3 "$RC" "a tool absent from the allowlist"
  assert_contains "$out" 'absent from this run' "an unlisted tool was not refused"

  capture tool-check tools-case http:POST; out=$OUT
  expect_code 3 "$RC" "a built-in floor tool"
  assert_contains "$out" 'built-in floor' "the compiled-in mutation floor did not fire"

  capture tool-check tools-case vault:write; out=$OUT
  expect_code 3 "$RC" "a read-only floor tool"
  assert_contains "$out" 'read-only floor' "the read-only floor did not fire"
  pass "the tool gate permits only the allowlist and keeps a floor no manifest can lower"
}

test_jira_write_tools_are_absent_from_the_read_only_surface() {
  local out tool
  "$RUN" new jira-case --mode afk-jira-research --lane test-company --grant read-only >/dev/null
  "$RUN" freeze jira-case >/dev/null

  for tool in jira_search jira_get_issue jira_get_transitions confluence_get_comments; do
    capture tool-check jira-case "$tool"; out=$OUT
    expect_code 0 "$RC" "read-only Atlassian tool $tool"
  done
  for tool in jira_create_issue jira_update_issue jira_transition_issue jira_add_comment \
    jira_assign_issue confluence_create_page confluence_update_page confluence_add_label \
    confluence_upload_attachment jira_download_attachments confluence_download_page; do
    capture tool-check jira-case "$tool"; out=$OUT
    expect_code 3 "$RC" "Atlassian write tool $tool"
  done
  pass "the Jira surface carries the read tools and refuses every write and write-adjacent tool"
}

test_write_area_is_the_evidence_directory() {
  local out evidence
  new_research_run write-case
  "$RUN" freeze write-case >/dev/null
  evidence="$HOME_DIR/data/runs/write-case/evidence"

  capture write-check write-case "$evidence/findings.jsonl"; out=$OUT
  expect_code 0 "$RC" "writing into the evidence directory"

  capture write-check write-case "$SOURCES/edited.txt"; out=$OUT
  expect_code 3 "$RC" "writing outside the write area"
  assert_contains "$out" 'outside this run' "a write outside the evidence area was permitted"

  capture write-check write-case "$evidence/AGENTS.md"; out=$OUT
  expect_code 3 "$RC" "writing a protected path"
  assert_contains "$out" 'protected' "a protected path was writable"

  # A symlinked parent must not launder a path into the write area: the check
  # compares physical paths, so the link is resolved before the comparison.
  ln -s "$SOURCES" "$evidence/escape"
  capture write-check write-case "$evidence/escape/laundered.txt"; out=$OUT
  expect_code 3 "$RC" "writing through a symlinked parent"
  rm -f "$evidence/escape"
  pass "writes reach the evidence directory only, after physical path resolution"
}

test_read_gate_partitions_lanes_and_frozen_roots() {
  local out
  new_research_run read-case
  "$RUN" freeze read-case >/dev/null

  capture read-check read-case "$SOURCES/paper.md"; out=$OUT
  expect_code 0 "$RC" "reading inside the frozen read roots"

  capture read-check read-case "$LANE_COMPANY/secrets.txt"; out=$OUT
  expect_code 3 "$RC" "reading another lane's config root"
  assert_contains "$out" 'belongs to lane test-company' "a cross-lane read was permitted"

  capture read-check read-case "$TMP_ROOT/unlisted/file.txt"; out=$OUT
  expect_code 3 "$RC" "reading outside the frozen read roots"
  assert_contains "$out" 'outside this run' "a read outside the frozen roots was permitted"
  pass "reads stay inside the frozen roots and never cross into another lane's account"
}

# The read gate can only bound reads against roots the manifest names, so a
# read-only run that froze none has to be stopped before it starts rather than
# reaching a gate with nothing to compare against.
test_a_read_only_run_without_read_roots_is_refused_at_preflight() {
  local out mode
  for mode in afk-research afk-obsidian-projects afk-session-review; do
    "$RUN" new "noroots-$mode" --mode "$mode" --lane test-personal --grant read-only >/dev/null
    "$RUN" set "noroots-$mode" account.isolationAsserted true --json
    "$RUN" freeze "noroots-$mode" >/dev/null
    "$RUN" claim "noroots-$mode" >/dev/null
    capture preflight "noroots-$mode"; out=$OUT
    expect_code 3 "$RC" "$mode preflight with no frozen read roots"
    assert_contains "$out" 'source.readRoots' "$mode started without a frozen read boundary"
    assert_grep 'readRoots' "$HOME_DIR/data/runs/noroots-$mode/receipts.jsonl" \
      "the $mode refusal left no receipt"
  done

  # The refusal is the missing boundary, not the mode: the same run passes once
  # it names one, and its reads are then bounded by it.
  new_research_run roots-declared
  "$RUN" freeze roots-declared >/dev/null
  "$RUN" claim roots-declared >/dev/null
  capture preflight roots-declared; out=$OUT
  expect_code 0 "$RC" "preflight with a frozen read root"

  capture read-check roots-declared "$SOURCES/paper.md"; out=$OUT
  expect_code 0 "$RC" "reading inside the declared root"

  capture read-check roots-declared /etc/hosts; out=$OUT
  expect_code 3 "$RC" "reading the wider filesystem"
  assert_contains "$out" 'outside this run' "a read outside the declared roots was permitted"
  pass "a read-only run must freeze its read roots before it starts, and is bounded by them after"
}

test_preflight_refuses_an_unproven_or_misdeclared_start() {
  local out
  # A run that never asserted profile isolation must not start.
  new_research_run preflight-isolation
  "$RUN" set preflight-isolation account.isolationAsserted false --json
  "$RUN" freeze preflight-isolation >/dev/null
  "$RUN" claim preflight-isolation >/dev/null
  capture preflight preflight-isolation; out=$OUT
  expect_code 3 "$RC" "preflight without asserted isolation"
  assert_contains "$out" 'isolationAsserted' "preflight accepted an unasserted profile"

  # A lane the home never registered is a blocker naming the registration, not a
  # guess from the lane's name.
  "$RUN" new preflight-lane --mode afk-research --lane test-personal --grant read-only >/dev/null
  "$RUN" set preflight-lane account.isolationAsserted true --json
  "$RUN" set preflight-lane account.lane invented-lane
  "$RUN" freeze preflight-lane >/dev/null
  "$RUN" claim preflight-lane >/dev/null
  capture preflight preflight-lane; out=$OUT
  expect_code 3 "$RC" "preflight on an unregistered lane"
  assert_contains "$out" 'not registered' "an unregistered lane passed preflight"

  # Bounded improvement stays deferred until the fix-known pilots pass.
  "$RUN" new preflight-bounded --mode afk-app --submode bounded-improvement \
    --lane test-personal --grant bounded-improvement:abc123 >/dev/null
  "$RUN" set preflight-bounded account.isolationAsserted true --json
  "$RUN" add preflight-bounded source.projects demo
  "$RUN" add preflight-bounded writes.allowedPaths "$WORKTREE"
  "$RUN" freeze preflight-bounded >/dev/null
  "$RUN" claim preflight-bounded >/dev/null
  capture preflight preflight-bounded; out=$OUT
  expect_code 3 "$RC" "preflight on the deferred bounded-improvement submode"
  assert_contains "$out" 'deferred until fix-known pilots pass' "bounded-improvement was not deferred"

  # Jira research stops before access while no verified write-tool-absence proof
  # exists, rather than running on an unproven surface.
  "$RUN" new preflight-jira --mode afk-jira-research --lane test-company --grant read-only >/dev/null
  "$RUN" set preflight-jira account.isolationAsserted true --json
  "$RUN" add preflight-jira source.readRoots "$SOURCES"
  "$RUN" freeze preflight-jira >/dev/null
  "$RUN" claim preflight-jira >/dev/null
  capture preflight preflight-jira; out=$OUT
  expect_code 3 "$RC" "preflight without a tool-surface proof"
  assert_contains "$out" 'surfaceProof' "Jira research started without a proven surface"
  pass "preflight refuses an unasserted profile, an unregistered lane, the deferred submode, and an unproven surface"
}

test_read_only_run_cannot_declare_write_paths() {
  local out
  new_research_run readonly-writes
  "$RUN" add readonly-writes writes.allowedPaths "$WORKTREE"
  "$RUN" freeze readonly-writes >/dev/null
  "$RUN" claim readonly-writes >/dev/null
  capture preflight readonly-writes; out=$OUT
  expect_code 3 "$RC" "a read-only run declaring write paths"
  assert_contains "$out" 'must declare no writes.allowedPaths' "a read-only run kept write paths"

  # And a change-authorized run may not point its write paths at firstmate's own
  # home, where the primary checkout and the read-only project clones live.
  "$RUN" new fixknown-home --mode afk-app --submode fix-known \
    --lane test-personal --grant fix-known:deadbeef >/dev/null
  "$RUN" set fixknown-home account.isolationAsserted true --json
  "$RUN" add fixknown-home source.projects demo
  "$RUN" add fixknown-home writes.allowedPaths "$HOME_DIR/projects/demo"
  "$RUN" freeze fixknown-home >/dev/null
  "$RUN" claim fixknown-home >/dev/null
  capture preflight fixknown-home; out=$OUT
  expect_code 3 "$RC" "fix-known writing inside the firstmate home"
  assert_contains "$out" 'isolated worktree' "a change run could target the firstmate home"
  pass "write authority is refused for read-only runs and never points at the firstmate home"
}

test_fix_known_writes_only_inside_its_granted_worktree() {
  local out
  "$RUN" new fixknown-ok --mode afk-app --submode fix-known \
    --lane test-personal --grant fix-known:deadbeef >/dev/null
  "$RUN" set fixknown-ok account.isolationAsserted true --json
  "$RUN" add fixknown-ok source.projects demo
  "$RUN" add fixknown-ok writes.allowedPaths "$WORKTREE"
  "$RUN" freeze fixknown-ok >/dev/null
  "$RUN" claim fixknown-ok >/dev/null
  capture preflight fixknown-ok; out=$OUT
  expect_code 0 "$RC" "preflight for a granted fix-known run"

  capture write-check fixknown-ok "$WORKTREE/src/app.js"; out=$OUT
  expect_code 0 "$RC" "writing inside the granted worktree"

  capture write-check fixknown-ok "$WORKTREE/tests/app.test.js"; out=$OUT
  expect_code 3 "$RC" "writing a protected test path inside the worktree"
  assert_contains "$out" 'protected' "the accepted-behavior tests were writable"

  capture write-check fixknown-ok "$SOURCES/other.js"; out=$OUT
  expect_code 3 "$RC" "writing outside the granted worktree"
  pass "a fix-known grant reaches its own worktree and still cannot touch the tests that define accepted behavior"
}

# The manifest seeds writes.protectedPaths, so an author can narrow or replace it
# before freezing. The floor is what makes that harmless.
test_the_protected_floor_survives_a_manifest_that_drops_it() {
  local out
  "$RUN" new floor-case --mode afk-app --submode fix-known \
    --lane test-personal --grant fix-known:deadbeef >/dev/null
  "$RUN" set floor-case account.isolationAsserted true --json
  "$RUN" add floor-case source.projects demo
  "$RUN" add floor-case writes.allowedPaths "$WORKTREE"
  "$RUN" set floor-case writes.protectedPaths '["nothing-real"]' --json
  "$RUN" freeze floor-case >/dev/null
  "$RUN" claim floor-case >/dev/null

  # The narrowed list is still non-empty, so preflight has nothing to object to:
  # the floor has to hold at the gate itself.
  capture preflight floor-case; out=$OUT
  expect_code 0 "$RC" "preflight with a narrowed protected list"

  capture write-check floor-case "$WORKTREE/tests/app.test.js"; out=$OUT
  expect_code 3 "$RC" "writing a test path under a manifest that dropped the defaults"
  assert_contains "$out" 'protected floor' "the compiled floor did not refuse a test path"

  capture write-check floor-case "$WORKTREE/AGENTS.md"; out=$OUT
  expect_code 3 "$RC" "writing AGENTS.md under a manifest that dropped the defaults"

  capture write-check floor-case "$WORKTREE/nested/CLAUDE.md"; out=$OUT
  expect_code 3 "$RC" "writing a nested CLAUDE.md"

  capture write-check floor-case "$WORKTREE/.git/config"; out=$OUT
  expect_code 3 "$RC" "writing into the git directory"

  assert_grep 'protected-floor' "$HOME_DIR/data/runs/floor-case/receipts.jsonl" \
    "the floor refusals left no receipt"

  # The floor refuses what it covers and nothing more: ordinary source still writes.
  capture write-check floor-case "$WORKTREE/src/app.js"; out=$OUT
  expect_code 0 "$RC" "writing ordinary source under the floor"

  # A manifest may still ADD to the floor.
  "$RUN" new floor-added --mode afk-app --submode fix-known \
    --lane test-personal --grant fix-known:deadbeef >/dev/null
  "$RUN" set floor-added account.isolationAsserted true --json
  "$RUN" add floor-added source.projects demo
  "$RUN" add floor-added writes.allowedPaths "$WORKTREE"
  "$RUN" add floor-added writes.protectedPaths '**/vendor/**'
  "$RUN" freeze floor-added >/dev/null
  "$RUN" claim floor-added >/dev/null
  capture write-check floor-added "$WORKTREE/vendor/lib.js"; out=$OUT
  expect_code 3 "$RC" "writing a path the manifest added to the floor"
  pass "a manifest may add protected paths and can never subtract from the compiled floor"
}

# The path argument is interpolated into a jq program, so a receipt that names one
# field has to mean exactly one field changed.
test_a_manifest_edit_cannot_change_fields_its_receipt_never_names() {
  local out grant
  "$RUN" new path-case --mode afk-research --lane test-personal --grant read-only >/dev/null

  capture set path-case 'authority.grant = "fix-known:x" | .writes.allowedPaths' '["/etc"]' --json
  out=$OUT
  expect_code 1 "$RC" "a set path carrying a second assignment"
  assert_contains "$out" 'not a plain manifest field path' "an injected set path was accepted"

  grant=$("$RUN" show path-case | jq -r '.authority.grant')
  [ "$grant" = read-only ] \
    || fail "the refused edit still changed authority.grant to $grant"

  capture add path-case 'source.readRoots) | .writes.allowedPaths += (["/etc"]' /tmp
  expect_code 1 "$RC" "an add path carrying a second assignment"

  # jq reads `.a-b` as subtraction, so the guard names the problem itself rather
  # than letting the caller get a compile error about an undefined function.
  capture set path-case a-b 1 --json; out=$OUT
  expect_code 1 "$RC" "a hyphenated field path"
  assert_contains "$out" 'not a plain manifest field path' "a hyphenated path reached jq"

  # A legitimate dotted path still works, so the guard bounds the shape and not the feature.
  capture set path-case budgets.wallSeconds 120 --json
  expect_code 0 "$RC" "a plain dotted field path"
  pass "a manifest edit is confined to the single field its receipt names"
}

# The run root is the durable record an operator reads after a restart, so a
# refused edit must not leave half-written manifests sitting next to the real one.
test_a_refused_manifest_edit_leaves_no_residue_in_the_run_root() {
  local strays
  "$RUN" new residue-case --mode afk-research --lane test-personal --grant read-only >/dev/null

  capture set residue-case budgets.wallSeconds not-json --json
  expect_code 1 "$RC" "a set carrying an unparseable JSON value"
  capture set residue-case budgets.wallSeconds also-bad --json
  expect_code 1 "$RC" "a second failing set"
  capture add residue-case source.readRoots.deep not-an-array
  expect_code 1 "$RC" "an add against a non-array field"

  strays=$(find "$HOME_DIR/data/runs/residue-case" -name 'manifest.json.tmp.*' | wc -l | tr -d ' ')
  [ "$strays" = 0 ] || fail "$strays orphan manifest temp files were left in the run root"

  # The refusals changed nothing, so the run still freezes and starts normally.
  jq -e . "$HOME_DIR/data/runs/residue-case/manifest.json" >/dev/null \
    || fail "the manifest is no longer valid JSON after the refused edits"
  "$RUN" set residue-case account.isolationAsserted true --json
  "$RUN" add residue-case source.readRoots "$SOURCES"
  "$RUN" freeze residue-case >/dev/null
  "$RUN" claim residue-case >/dev/null
  capture preflight residue-case
  expect_code 0 "$RC" "preflight after refused edits"
  pass "a refused manifest edit leaves no temp file behind and does not disturb the run"
}

# A command naming a run that was never created must refuse without leaving the
# run id occupied. Taking the run lock before the existence check would create
# the run root as a side effect, and `new` refuses an id whose root already
# exists - so a single mistyped id would burn that id for the rest of the home.
test_a_command_against_a_missing_run_does_not_occupy_its_id() {
  local out
  capture set typo-case account.isolationAsserted true --json
  expect_code 1 "$RC" "editing a run that was never created"
  capture add typo-case source.readRoots "$SOURCES"
  expect_code 1 "$RC" "appending to a run that was never created"
  capture claim typo-case
  expect_code 1 "$RC" "claiming a run that was never created"

  [ ! -e "$HOME_DIR/data/runs/typo-case" ] \
    || fail "a command against a missing run created its run root"

  # The refusals left nothing that `list` reports as a run.
  capture list
  out=$OUT
  assert_not_contains "$out" typo-case "list reported a run id no run occupies"

  # The decisive consequence: the id is still free, so the operator can create
  # the run they meant to create.
  capture new typo-case --mode afk-research --lane test-personal --grant read-only
  expect_code 0 "$RC" "creating a run whose id a refused command had touched"
  pass "a command against a missing run refuses without occupying the run id"
}

test_one_mutable_owner_and_idempotent_resume() {
  local out
  new_research_run custody-case
  "$RUN" freeze custody-case >/dev/null
  "$RUN" claim custody-case >/dev/null
  "$RUN" preflight custody-case >/dev/null
  "$RUN" advance custody-case baseline >/dev/null
  "$RUN" advance custody-case plan >/dev/null
  "$RUN" advance custody-case dispatch >/dev/null
  "$RUN" advance custody-case supervise >/dev/null

  RC=0
  out=$(FM_RUN_OWNER=second-primary "$RUN" advance custody-case decision 2>&1) || RC=$?
  expect_code 3 "$RC" "a second owner mutating a live run"
  assert_contains "$out" 'is owned by' "a second owner could mutate the run"

  RC=0
  out=$(FM_RUN_OWNER=second-primary "$RUN" claim custody-case --takeover 2>&1) || RC=$?
  expect_code 3 "$RC" "taking over a run that is still live"
  assert_contains "$out" 'checkpoint or stop before a takeover' "a live run was taken over"

  "$RUN" stop custody-case --rule deadline >/dev/null
  "$RUN" advance custody-case report >/dev/null
  capture resume custody-case; out=$OUT
  expect_code 0 "$RC" "resuming from report"
  assert_contains "$out" 'state=supervise' "resume did not re-enter supervision"

  # The second resume is the duplicate-loop bug this record exists to prevent.
  capture resume custody-case; out=$OUT
  expect_code 0 "$RC" "resuming twice in one generation"
  assert_contains "$out" 'already resumed' "a second resume started a duplicate loop"

  "$RUN" stop custody-case --rule no-progress >/dev/null
  out=$(FM_RUN_OWNER=second-primary "$RUN" claim custody-case --takeover 2>&1)
  assert_contains "$out" 'generation=2' "a quiesced takeover did not advance the ownership generation"
  RC=0
  "$RUN" advance custody-case report >/dev/null 2>&1 || RC=$?
  expect_code 3 "$RC" "the former owner mutating after a takeover"
  pass "exactly one owner mutates a run, takeover needs a quiesced run, and resume is idempotent per generation"
}

test_concurrent_claims_leave_exactly_one_owner() {
  local i rc winners=0 owner
  new_research_run race-case
  "$RUN" freeze race-case >/dev/null

  # Eight primaries claim the same run at once. Reading the owner, deciding, and
  # writing it is one compare-and-swap, so exactly one may win. Without the run
  # lock every contender reads generation 0, every one decides the run is free,
  # and every one writes: the run ends up with as many "owners" as contenders,
  # each believing it holds custody.
  for i in 1 2 3 4 5 6 7 8; do
    (
      RC=0
      FM_RUN_OWNER="racer-$i" "$RUN" claim race-case >/dev/null 2>&1 || RC=$?
      printf '%s\n' "$RC" > "$TMP_ROOT/race.rc.$i"
    ) &
  done
  wait

  for i in 1 2 3 4 5 6 7 8; do
    rc=$(cat "$TMP_ROOT/race.rc.$i" 2>/dev/null || echo 1)
    [ "$rc" = 0 ] && winners=$((winners + 1))
  done
  [ "$winners" -eq 1 ] || fail "concurrent claims produced $winners owners, expected exactly 1"

  # The survivor is a real owner, not a half-written record: exactly one identity
  # is recorded, and it is one of the contenders rather than a torn value.
  owner=$("$RUN" summary race-case | grep '^owner=' | head -1)
  case "$owner" in
    owner=racer-[1-8]) ;;
    *) fail "the winning claim left no single recorded owner: '$owner'" ;;
  esac

  # A losing contender must be shut out of the run it did not win.
  RC=0
  FM_RUN_OWNER=not-the-winner "$RUN" stop race-case --rule deadline >/dev/null 2>&1 || RC=$?
  expect_code 3 "$RC" "a losing contender mutating the run it did not win"
  pass "concurrent claims resolve to exactly one owner"
}

test_a_symlinked_write_target_is_refused_but_a_read_follows_it() {
  local out evidence
  new_research_run leaf-case
  "$RUN" freeze leaf-case >/dev/null
  evidence="$HOME_DIR/data/runs/leaf-case/evidence"
  mkdir -p "$evidence"

  # The final component matters as much as the parents. A symlink NAMED inside
  # the evidence directory but POINTING outside it would otherwise be judged by
  # its name and send the write anywhere.
  #
  # A write target is refused outright rather than resolved, because resolving
  # answers the question at check time while the caller writes later: the link
  # can be repointed in between, so only refusal is race-safe.
  ln -s "$SOURCES/smuggled.txt" "$evidence/decoy.txt"
  capture write-check leaf-case "$evidence/decoy.txt"; out=$OUT
  expect_code 3 "$RC" "writing through a symlinked leaf"
  assert_contains "$out" 'is a symlink' "a symlinked write target was not refused as one"

  # A dangling link is refused on the same grounds: what it would point at later
  # is not knowable now.
  ln -s "$SOURCES/never-created.txt" "$evidence/dangling.txt"
  capture write-check leaf-case "$evidence/dangling.txt"; out=$OUT
  expect_code 3 "$RC" "writing through a dangling symlinked leaf"

  # Reads are the opposite case: following a link is ordinary, so the gate judges
  # the file the read would actually open. A link inside the evidence area that
  # points into the frozen read roots is allowed on the target's merits.
  : > "$SOURCES/paper.md"
  ln -s "$SOURCES/paper.md" "$evidence/paper-link.md"
  capture read-check leaf-case "$evidence/paper-link.md"; out=$OUT
  expect_code 0 "$RC" "reading through a symlink into the frozen read roots"

  # And a link whose target lies in another lane is refused on the target, not
  # excused by the innocent-looking name it was reached through.
  ln -s "$LANE_COMPANY/secrets.txt" "$evidence/innocent.md"
  capture read-check leaf-case "$evidence/innocent.md"; out=$OUT
  expect_code 3 "$RC" "reading a cross-lane target through a symlink"
  assert_contains "$out" 'belongs to lane test-company' "a symlink laundered a cross-lane read"

  rm -f "$evidence/decoy.txt" "$evidence/dangling.txt" "$evidence/paper-link.md" \
    "$evidence/innocent.md"
  pass "a symlinked write target is refused while a read is judged on its real target"
}

test_stop_records_a_durable_checkpoint() {
  local out before after
  new_research_run stopckpt-case
  "$RUN" freeze stopckpt-case >/dev/null
  "$RUN" claim stopckpt-case >/dev/null
  "$RUN" preflight stopckpt-case >/dev/null

  before=$(find "$HOME_DIR/data/runs/stopckpt-case/checkpoints" -name '*.json' 2>/dev/null | grep -c . || true)
  [ "$before" = 0 ] || fail "the run had checkpoints before it stopped"

  # Stopping IS reaching a durable point. Leaving the checkpoint to a separate
  # command the operator had to remember made restart safety depend on memory,
  # so the stop writes one itself and names its index.
  capture stop stopckpt-case --rule deadline --note "budget reached"; out=$OUT
  expect_code 0 "$RC" "stopping on a frozen rule"
  assert_contains "$out" 'checkpoint=1' "stop did not report the checkpoint it wrote"

  after=$(find "$HOME_DIR/data/runs/stopckpt-case/checkpoints" -name '*.json' | grep -c . || true)
  [ "$after" = 1 ] || fail "stop wrote $after checkpoints, expected exactly 1"

  # The checkpoint must carry why it exists, so a resuming primary can tell a
  # deadline stop from a no-progress one without re-deriving it.
  assert_grep 'stop:deadline' "$HOME_DIR/data/runs/stopckpt-case/checkpoints/1.json" \
    "the stop checkpoint did not record the rule that fired"
  assert_grep 'budget reached' "$HOME_DIR/data/runs/stopckpt-case/checkpoints/1.json" \
    "the stop checkpoint did not record the operator's note"
  pass "stopping a run writes the durable checkpoint its own restart needs"
}

test_resume_revalidates_every_start_assertion() {
  local out lanes
  new_research_run revalidate-case
  "$RUN" freeze revalidate-case >/dev/null
  "$RUN" claim revalidate-case >/dev/null
  "$RUN" preflight revalidate-case >/dev/null
  "$RUN" stop revalidate-case --rule deadline >/dev/null

  # Time passes while a run is stopped, and the world moves under it: a lane can
  # be de-registered, a read root can vanish. A gate worth checking before the
  # first dispatch is worth checking before the next one, so resume re-runs the
  # whole preflight set instead of trusting that it passed once.
  lanes="$HOME_DIR/config/run-lanes.conf"
  cp "$lanes" "$TMP_ROOT/lanes.bak"
  : > "$lanes"
  capture resume revalidate-case; out=$OUT
  expect_code 3 "$RC" "resuming after the lane registration disappeared"
  assert_contains "$out" 'not registered' "resume did not re-check the lane registration"
  assert_contains "$out" 'resume-revalidation' "the failure was not attributed to the resume re-check"

  # The refusal is recorded under its own phase, so the receipt log distinguishes
  # a first-dispatch refusal from one that fired on the way back in.
  assert_grep 'resume-revalidation' "$HOME_DIR/data/runs/revalidate-case/receipts.jsonl" \
    "the revalidation refusal left no receipt"

  cp "$TMP_ROOT/lanes.bak" "$lanes"
  capture resume revalidate-case; out=$OUT
  expect_code 0 "$RC" "resuming once the assertions hold again"
  assert_contains "$out" 'revalidated=yes' "a successful resume did not report that it revalidated"
  pass "resume re-runs every start assertion before re-entering supervision"
}

test_stale_authority_needs_a_fresh_stamp_before_resume() {
  local out
  "$RUN" new stale-case --mode afk-research --lane test-personal --grant read-only \
    --authorized-at 2020-01-01T00:00:00Z >/dev/null
  "$RUN" set stale-case account.isolationAsserted true --json
  "$RUN" add stale-case source.readRoots "$SOURCES"
  "$RUN" freeze stale-case >/dev/null
  "$RUN" claim stale-case >/dev/null
  "$RUN" preflight stale-case >/dev/null
  "$RUN" advance stale-case baseline >/dev/null
  "$RUN" stop stale-case --rule deadline >/dev/null
  "$RUN" advance stale-case report >/dev/null

  capture resume stale-case; out=$OUT
  expect_code 3 "$RC" "resuming a run authorized long ago"
  assert_contains "$out" 'reauthorized-at' "a stale authorization resumed silently"

  capture resume stale-case --reauthorized-at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; out=$OUT
  expect_code 0 "$RC" "resuming after re-authorization"
  pass "an aged authorization must be restamped before the run resumes"
}

test_stop_rules_come_from_the_frozen_set() {
  local out
  new_research_run stop-case
  "$RUN" freeze stop-case >/dev/null
  "$RUN" claim stop-case >/dev/null
  "$RUN" preflight stop-case >/dev/null
  capture stop stop-case --rule invented-reason; out=$OUT
  expect_code 3 "$RC" "stopping on an unfrozen rule"
  assert_contains "$out" 'not in this run' "an invented stop rule was accepted"

  capture stop stop-case --rule captain-only-decision; out=$OUT
  expect_code 0 "$RC" "stopping on a frozen rule"
  assert_grep 'stop_rule=captain-only-decision' "$HOME_DIR/data/runs/stop-case/run.state" \
    "the stop rule was not recorded durably"
  pass "a run stops only on a rule its frozen manifest declared"
}

test_receipts_record_both_verdicts_and_prove_no_write() {
  local out receipts
  new_research_run receipt-case
  "$RUN" freeze receipt-case >/dev/null
  "$RUN" tool-check receipt-case read >/dev/null
  "$RUN" tool-check receipt-case jira_create_issue >/dev/null 2>&1 || true
  "$RUN" write-check receipt-case "$SOURCES/nope.txt" >/dev/null 2>&1 || true
  "$RUN" write-check receipt-case "$HOME_DIR/data/runs/receipt-case/evidence/ok.md" >/dev/null

  receipts="$HOME_DIR/data/runs/receipt-case/receipts.jsonl"
  assert_grep '"verdict":"refused"' "$receipts" "refusals were not recorded"
  assert_grep '"verdict":"allowed"' "$receipts" "permitted calls were not recorded"

  capture prove-no-write receipt-case; out=$OUT
  expect_code 0 "$RC" "proving no write for a read-only run"
  # The claim must match what the command actually checked: it reads receipts, so
  # it can only speak for writes that came through the gate.
  assert_contains "$out" 'no outside write recorded through fm-run gates' \
    "prove-no-write did not report cleanly"
  assert_contains "$out" 'a write that never called the write gate leaves no record here' \
    "prove-no-write did not state the scope of its claim"
  assert_not_contains "$out" 'no write outside the evidence directory' \
    "prove-no-write still claims more than a receipt scan can establish"

  # A recorded write outside the evidence area breaks the proof, which is what
  # makes the proof worth anything.
  printf '{"at":"now","run":"receipt-case","kind":"write","subject":"%s/leak.txt","verdict":"allowed","note":"","pid":"0"}\n' \
    "$SOURCES" >> "$receipts"
  capture prove-no-write receipt-case; out=$OUT
  expect_code 3 "$RC" "proving no write when one is recorded"
  assert_contains "$out" 'prove-no-write failed' "a recorded outside write still proved clean"
  pass "receipts record allowed and refused decisions, and prove-no-write fails when a write is recorded"
}

test_cross_lane_summary_needs_the_reconstruction_attestation() {
  local out summary
  summary="$TMP_ROOT/summary.md"
  printf 'context-switching correlates with lower follow-through\n' > "$summary"

  new_research_run crosslane-default
  "$RUN" freeze crosslane-default >/dev/null
  capture cross-lane-attest crosslane-default --summary-file "$summary"; out=$OUT
  expect_code 3 "$RC" "attesting when nothing may cross"
  assert_contains "$out" 'nothing may cross lanes' "a default run allowed a cross-lane summary"

  "$RUN" new crosslane-allowed --mode afk-session-review --lane test-personal --grant read-only >/dev/null
  "$RUN" set crosslane-allowed privacy.crossLaneAllowed sanitized-abstract-pattern-only
  "$RUN" freeze crosslane-allowed >/dev/null
  capture cross-lane-attest crosslane-allowed --summary-file "$summary"; out=$OUT
  expect_code 0 "$RC" "attesting a sanitized pattern"
  assert_grep 'reconstruction-test=passed' "$HOME_DIR/data/runs/crosslane-allowed/receipts.jsonl" \
    "the reconstruction attestation was not recorded"
  pass "a cross-lane summary crosses only under an explicit allowance and leaves an attestation receipt"
}

test_multi_lane_session_review_requires_the_privacy_partition() {
  local out
  "$RUN" new lanes-case --mode afk-session-review --lane test-personal --grant read-only >/dev/null
  "$RUN" set lanes-case account.isolationAsserted true --json
  "$RUN" add lanes-case source.sessionLanes test-personal
  "$RUN" add lanes-case source.sessionLanes test-company
  "$RUN" add lanes-case source.readRoots "$SOURCES"
  "$RUN" freeze lanes-case >/dev/null
  "$RUN" claim lanes-case >/dev/null
  capture preflight lanes-case; out=$OUT
  expect_code 3 "$RC" "a two-lane review without the sanitized-pattern rule"
  assert_contains "$out" 'sanitized-abstract-pattern-only' "a two-lane review skipped the privacy partition"
  pass "a review spanning both lanes must declare the sanitized-abstract-pattern boundary"
}

test_obsidian_run_needs_frozen_tasks_and_a_firstmate_only_writer() {
  local out
  "$RUN" new pm-empty --mode afk-obsidian-projects --lane test-personal --grant read-only >/dev/null
  "$RUN" set pm-empty account.isolationAsserted true --json
  "$RUN" add pm-empty source.readRoots "$SOURCES"
  "$RUN" freeze pm-empty >/dev/null
  "$RUN" claim pm-empty >/dev/null
  capture preflight pm-empty; out=$OUT
  expect_code 3 "$RC" "a PM run with no frozen task list"
  assert_contains "$out" 'readiness is not authority' "a PM run started without an authorized task list"

  "$RUN" new pm-writer --mode afk-obsidian-projects --lane test-personal --grant read-only >/dev/null
  "$RUN" set pm-writer account.isolationAsserted true --json
  "$RUN" add pm-writer source.taskPaths 'Projects/Alpha/Task 1.md'
  "$RUN" add pm-writer source.readRoots "$SOURCES"
  "$RUN" set pm-writer writes.vaultWriter worker
  "$RUN" freeze pm-writer >/dev/null
  "$RUN" claim pm-writer >/dev/null
  capture preflight pm-writer; out=$OUT
  expect_code 3 "$RC" "a PM run letting a worker write the vault"
  assert_contains "$out" 'firstmate-only' "a worker could be declared the vault writer"
  pass "a PM run needs the exact frozen task list and keeps firstmate the only vault writer"
}

test_self_analysis_stays_on_a_personal_lane() {
  local out
  "$RUN" new self-company --mode afk-session-review --lane test-company --grant read-only >/dev/null
  "$RUN" set self-company account.isolationAsserted true --json
  "$RUN" add self-company source.sessionLanes test-company
  "$RUN" add self-company source.readRoots "$SOURCES"
  "$RUN" set self-company selfAnalysis.enabled true --json
  "$RUN" freeze self-company >/dev/null
  "$RUN" claim self-company >/dev/null
  capture preflight self-company; out=$OUT
  expect_code 3 "$RC" "self-analysis on a company lane"
  assert_contains "$out" 'personal lane only' "self-analysis ran on a company lane"

  "$RUN" new self-subject --mode afk-session-review --lane test-personal --grant read-only >/dev/null
  "$RUN" set self-subject account.isolationAsserted true --json
  "$RUN" add self-subject source.sessionLanes test-personal
  "$RUN" add self-subject source.readRoots "$SOURCES"
  "$RUN" set self-subject selfAnalysis.enabled true --json
  "$RUN" set self-subject selfAnalysis.subjectCaptainOnly false --json
  "$RUN" freeze self-subject >/dev/null
  "$RUN" claim self-subject >/dev/null
  capture preflight self-subject; out=$OUT
  expect_code 3 "$RC" "self-analysis with a widened subject"
  assert_contains "$out" 'no other person is ever analysed' "self-analysis could widen past the captain"
  pass "self-analysis is refused off a personal lane and refuses to widen past the captain"
}

test_state_machine_refuses_an_out_of_order_transition() {
  local out
  new_research_run order-case
  "$RUN" freeze order-case >/dev/null
  "$RUN" claim order-case >/dev/null
  capture advance order-case supervise; out=$OUT
  expect_code 3 "$RC" "skipping straight into supervision"
  assert_contains "$out" 'cannot go from intake to supervise' "the state machine allowed a skipped transition"

  capture advance order-case preflight; out=$OUT
  expect_code 1 "$RC" "advancing into preflight"
  assert_contains "$out" 'has its own command' "preflight could be entered without its assertions"
  pass "the state machine refuses skipped transitions and keeps preflight behind its assertions"
}

test_check_stop_names_what_it_cannot_judge() {
  local out
  new_research_run checkstop-case
  "$RUN" set checkstop-case budgets.wallSeconds 1 --json
  # Backdate the run rather than racing the clock. Elapsed time is whole seconds
  # of `now - createdAt`, so a run created and checked inside the same second is
  # legitimately at elapsed=0: asserting the deadline fired would then depend on
  # how long the preceding cases happened to take.
  "$RUN" set checkstop-case createdAt 2020-01-01T00:00:00Z
  "$RUN" freeze checkstop-case >/dev/null

  capture check-stop checkstop-case; out=$OUT
  expect_code 0 "$RC" "checking stop rules"
  assert_contains "$out" 'rule=deadline' "an elapsed wall-clock budget did not fire the deadline rule"

  # The clock is the only rule decidable from the run's own record, so the rest
  # must be named rather than silently reported as not firing.
  assert_contains "$out" 'unevaluated=' "check-stop did not name the rules it cannot judge"
  assert_contains "$out" 'reserve-threshold' "the quota reserve rule was not named as unevaluated"
  assert_not_contains "$out" 'unevaluated=none' "every frozen rule was claimed as evaluated"

  # The opposite case must hold too, otherwise "the deadline fired" proves only
  # that the rule is always on.
  new_research_run checkstop-live
  "$RUN" set checkstop-live budgets.wallSeconds 86400 --json
  "$RUN" freeze checkstop-live >/dev/null
  capture check-stop checkstop-live; out=$OUT
  expect_code 0 "$RC" "checking stop rules on a run inside its budget"
  assert_contains "$out" 'rule=none' "a run inside its wall-clock budget was told to stop"
  pass "check-stop decides the wall-clock budget and names every rule it cannot judge itself"
}

test_frozen_manifest_data_is_readable_for_the_morning_report() {
  local out
  new_research_run report-case
  "$RUN" freeze report-case >/dev/null
  "$RUN" claim report-case >/dev/null
  "$RUN" preflight report-case >/dev/null
  capture summary report-case; out=$OUT
  expect_code 0 "$RC" "summarizing a live run"
  assert_contains "$out" 'mode=afk-research' "the run report lost its mode"
  assert_contains "$out" 'manifest_sha256=' "the run report lost the frozen manifest identity"
  assert_contains "$out" 'receipts_total=' "the run report lost its receipt counts"
  pass "a run reports its frozen identity, state, and receipt counts for the morning digest"
}

test_frozen_manifest_cannot_be_expanded
test_tool_allowlist_is_closed
test_jira_write_tools_are_absent_from_the_read_only_surface
test_write_area_is_the_evidence_directory
test_read_gate_partitions_lanes_and_frozen_roots
test_a_read_only_run_without_read_roots_is_refused_at_preflight
test_preflight_refuses_an_unproven_or_misdeclared_start
test_read_only_run_cannot_declare_write_paths
test_fix_known_writes_only_inside_its_granted_worktree
test_the_protected_floor_survives_a_manifest_that_drops_it
test_a_manifest_edit_cannot_change_fields_its_receipt_never_names
test_a_refused_manifest_edit_leaves_no_residue_in_the_run_root
test_a_command_against_a_missing_run_does_not_occupy_its_id
test_one_mutable_owner_and_idempotent_resume
test_concurrent_claims_leave_exactly_one_owner
test_a_symlinked_write_target_is_refused_but_a_read_follows_it
test_stop_records_a_durable_checkpoint
test_resume_revalidates_every_start_assertion
test_stale_authority_needs_a_fresh_stamp_before_resume
test_stop_rules_come_from_the_frozen_set
test_receipts_record_both_verdicts_and_prove_no_write
test_cross_lane_summary_needs_the_reconstruction_attestation
test_multi_lane_session_review_requires_the_privacy_partition
test_obsidian_run_needs_frozen_tasks_and_a_firstmate_only_writer
test_self_analysis_stays_on_a_personal_lane
test_state_machine_refuses_an_out_of_order_transition
test_check_stop_names_what_it_cannot_judge
test_frozen_manifest_data_is_readable_for_the_morning_report
