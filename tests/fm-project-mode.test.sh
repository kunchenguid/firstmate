#!/usr/bin/env bash
# Behavior tests for per-project delivery mode and independent autonomy grants.
#
# The regression this file exists for: `+yolo` used to be ONE boolean covering
# three distinct grants (answering review findings, merging PRs, approving a
# local-only merge). A captain who wanted "you may answer PR questions, I merge
# PRs" had no registry input that said so, so the instruction survived only as
# prose in a description. test_findings_grant_is_independent_of_merge pins the
# fix: the two grants must be settable one without the other.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
mkdir -p "$TMP_ROOT"

# registry <line>... -> echoes an FM_HOME whose data/projects.md holds those lines.
registry() {
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/data"
  printf '%s\n' "$@" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# resolve <home> <project> -> stdout of the resolver, stderr dropped.
resolve() {
  FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" 2>/dev/null
}

# resolve_err <home> <project> -> stderr of the resolver, stdout dropped.
resolve_err() {
  { FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" >/dev/null; } 2>&1
}

# granted <home> <project> <grant> -> exit 0 when the grant is held.
granted() {
  FM_HOME="$1" "$ROOT/bin/fm-project-mode.sh" "$2" --grant "$3" 2>/dev/null
}

# --- backward compatibility -------------------------------------------------

test_bare_yolo_still_grants_all_three() {
  local home
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  for grant in findings merge local-merge; do
    granted "$home" app "$grant" || fail "bare +yolo must still grant $grant"
  done
  [ "$(resolve "$home" app)" = "no-mistakes findings,merge,local-merge" ] \
    || fail "bare +yolo should resolve to all grants, got: $(resolve "$home" app)"
  pass "bare +yolo keeps its current meaning: all three grants"
}

test_no_flag_grants_nothing() {
  local home
  home=$(registry '- app [direct-PR] - x (added 2026-07-21)')
  for grant in findings merge local-merge; do
    granted "$home" app "$grant" && fail "an unflagged project must not grant $grant"
  done
  [ "$(resolve "$home" app)" = "direct-PR none" ] \
    || fail "unflagged project should resolve to none, got: $(resolve "$home" app)"
  pass "a project with no autonomy flag grants nothing"
}

test_legacy_and_mode_only_lines_unchanged() {
  local home
  home=$(registry \
    '- legacy - no brackets at all (added 2026-06-01)' \
    '- app [local-only] - mode only (added 2026-06-01)' \
    '- full [local-only +yolo] - mode plus flag (added 2026-06-01)')
  [ "$(resolve "$home" legacy)" = "no-mistakes none" ] || fail "legacy line changed meaning"
  [ "$(resolve "$home" app)" = "local-only none" ] || fail "mode-only line changed meaning"
  [ "$(resolve "$home" full)" = "local-only findings,merge,local-merge" ] \
    || fail "mode+yolo line changed meaning"
  pass "every registry line shape that parses today keeps its meaning"
}

# --- the regression this task exists for ------------------------------------

test_findings_grant_is_independent_of_merge() {
  local home
  home=$(registry '- sched [no-mistakes +yolo:findings] - captain merges PRs (added 2026-07-21)')
  granted "$home" sched findings \
    || fail "+yolo:findings must grant findings"
  granted "$home" sched merge \
    && fail "+yolo:findings must NOT grant merge authority"
  granted "$home" sched local-merge \
    && fail "+yolo:findings must NOT grant local-merge authority"
  pass "findings can be granted without handing over merge authority"
}

test_each_grant_is_settable_alone() {
  local home token grant other
  for grant in findings merge local-merge; do
    token="+yolo:$grant"
    home=$(registry "- app [no-mistakes $token] - x (added 2026-07-21)")
    granted "$home" app "$grant" || fail "$token must grant $grant"
    for other in findings merge local-merge; do
      [ "$other" = "$grant" ] && continue
      granted "$home" app "$other" && fail "$token must not imply $other"
    done
  done
  pass "each grant is settable alone and implies none of the others"
}

test_grants_combine_and_report_canonically() {
  local home
  home=$(registry '- app [direct-PR +yolo:merge,findings] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "direct-PR findings,merge" ] \
    || fail "comma list should combine in canonical order, got: $(resolve "$home" app)"
  granted "$home" app local-merge && fail "a two-grant list must not grant the third"

  home=$(registry '- app [direct-PR +yolo:merge +yolo:findings] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "direct-PR findings,merge" ] \
    || fail "repeated tokens should combine identically, got: $(resolve "$home" app)"
  pass "grants combine as a comma list or repeated tokens, canonically ordered"
}

# --- least permission on bad input ------------------------------------------

test_unknown_grant_token_grants_nothing_and_reports() {
  local home err
  home=$(registry '- app [no-mistakes +yolo:merg] - typo (added 2026-07-21)')
  for grant in findings merge local-merge; do
    granted "$home" app "$grant" && fail "a typo'd grant must not grant $grant"
  done
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "typo'd grant should resolve to none, got: $(resolve "$home" app)"
  err=$(resolve_err "$home" app)
  assert_contains "$err" "merg" "typo'd grant must be reported by name"
  pass "an unknown grant token grants nothing and says so"
}

test_unknown_grant_does_not_poison_valid_siblings() {
  local home
  home=$(registry '- app [no-mistakes +yolo:findings,bogus] - x (added 2026-07-21)')
  granted "$home" app findings || fail "a valid sibling grant must survive"
  granted "$home" app merge && fail "an unknown token must never widen permission"
  granted "$home" app local-merge && fail "an unknown token must never widen permission"
  pass "an unknown grant is dropped without widening or voiding its siblings"
}

test_malformed_and_absent_input_resolves_to_least_permission() {
  local home
  # Unknown delivery mode: today's parser drops the flag too, and must keep doing so.
  home=$(registry '- app [bogus-mode +yolo] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "unknown mode must drop grants, got: $(resolve "$home" app)"

  # Bare +yolo: with nothing after the colon.
  home=$(registry '- app [no-mistakes +yolo:] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "empty grant list must grant nothing, got: $(resolve "$home" app)"

  # A near-miss that is not the flag at all.
  home=$(registry '- app [no-mistakes +yolo-merge] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "a non-flag token must grant nothing, got: $(resolve "$home" app)"

  # Project absent from the registry, and registry absent entirely.
  home=$(registry '- other [no-mistakes +yolo] - x (added 2026-07-21)')
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "an unregistered project must grant nothing"
  home=$(mktemp -d "$TMP_ROOT/empty.XXXXXX")
  [ "$(resolve "$home" app)" = "no-mistakes none" ] \
    || fail "a missing registry must grant nothing"
  pass "malformed, unknown, and absent input all resolve to least permission"
}

test_grant_query_rejects_an_unknown_grant_name() {
  local home status err
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  err=$({ FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --grant mrege >/dev/null; } 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] \
    || fail "querying an unknown grant name must not report success on a fully-granted project"
  assert_contains "$err" "mrege" "unknown grant query must name the bad grant"
  pass "an unknown grant name is refused, never answered as granted"
}

test_grant_query_rejects_an_empty_grant_name() {
  local home status out
  # An empty or unset grant name must be refused exactly like an unknown one.
  # The project below holds every grant, so falling through to the plain resolve
  # path would print "<mode> <grants>" and exit 0 - a silent grant of merge.
  home=$(registry '- app [no-mistakes +yolo] - x (added 2026-07-21)')
  out=$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" app --grant '' 2>/dev/null) && status=0 || status=$?
  [ "$status" -ne 0 ] \
    || fail "querying an empty grant name must not report success on a fully-granted project"
  [ -z "$out" ] || fail "an empty grant query must print nothing on stdout, got \"$out\""
  pass "an empty grant name is refused, never answered as granted"
}

# --- caller contract --------------------------------------------------------

test_second_field_can_never_be_read_as_the_old_boolean() {
  local home out
  # Every caller that still used `case $field in on) ...` must fall through to
  # its deny branch rather than silently matching a grant list.
  for line in \
    '- app [no-mistakes] - x (added 2026-07-21)' \
    '- app [no-mistakes +yolo] - x (added 2026-07-21)' \
    '- app [no-mistakes +yolo:merge] - x (added 2026-07-21)'; do
    home=$(registry "$line")
    out=$(resolve "$home" app)
    case "${out##* }" in
      on|off) fail "second field '$out' is still readable as the old on/off boolean" ;;
    esac
  done
  pass "the grants field can never be mistaken for the old on/off boolean"
}

test_every_caller_reads_the_field_it_intends() {
  local file line window callers=0
  # Pin the caller inventory: each invocation in bin/ must either take only the
  # mode (word 1) or deliberately take mode AND grants. A new or changed caller
  # shows up here as a failure so its field intent gets reviewed, not assumed.
  # The extraction can sit on either side of the call, so inspect a window.
  while IFS= read -r file; do
    [ "$(basename "$file")" = fm-project-mode.sh ] && continue
    while IFS= read -r line; do
      callers=$((callers + 1))
      window=$(awk -v n="$line" 'NR >= n-3 && NR <= n+3' "$file")
      case "$window" in
        *'read -r mode _'*|*'read -r MODE _'*) ;;               # mode only
        *'%% *'*) ;;                                            # mode only
        *'read -r MODE GRANTS'*) ;;                             # mode and grants
        *) fail "unreviewed fm-project-mode.sh caller at $file:$line"$'\n'"$window" ;;
      esac
    # Only count real invocations: every caller runs the resolver through a
    # quoted path token ("$FM_ROOT/bin/fm-project-mode.sh"). A bare path literal
    # in a changed-file family map (e.g. fm-test-run.sh's case pattern) mentions
    # the script name but never invokes it, so it must not register as a caller.
    done < <(grep -nE 'bin/fm-project-mode\.sh"' "$file" | grep -v ':[[:space:]]*#' | cut -d: -f1)
  done < <(grep -rl 'fm-project-mode\.sh' "$ROOT/bin")
  [ "$callers" -ge 6 ] || fail "expected at least 6 resolver call sites in bin/, found $callers"
  pass "every fm-project-mode.sh caller in bin/ reads the field it intends ($callers sites)"
}

test_spawn_records_grants_in_task_metadata() {
  # The split is worthless if it dies at the parser: the grants must reach the
  # durable task record the supervising agent actually reads.
  assert_grep 'grants=' "$ROOT/bin/fm-spawn.sh" "fm-spawn must record grants= in task metadata"
  grep -q 'echo "yolo=' "$ROOT/bin/fm-spawn.sh" \
    && fail "fm-spawn still writes the superseded single yolo= metadata field"
  assert_grep 'grants' "$ROOT/bin/fm-fleet-snapshot.sh" "the fleet view must surface grants"
  pass "resolved grants reach task metadata and the fleet view"
}

test_bare_yolo_still_grants_all_three
test_no_flag_grants_nothing
test_legacy_and_mode_only_lines_unchanged
test_findings_grant_is_independent_of_merge
test_each_grant_is_settable_alone
test_grants_combine_and_report_canonically
test_unknown_grant_token_grants_nothing_and_reports
test_unknown_grant_does_not_poison_valid_siblings
test_malformed_and_absent_input_resolves_to_least_permission
test_grant_query_rejects_an_unknown_grant_name
test_grant_query_rejects_an_empty_grant_name
test_second_field_can_never_be_read_as_the_old_boolean
test_every_caller_reads_the_field_it_intends
test_spawn_records_grants_in_task_metadata

echo "# all fm-project-mode tests passed"
