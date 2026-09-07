#!/usr/bin/env bash
# Behavior tests for bin/fm-report-index.sh and its session-start digest tail.
#
# fm-report-index.sh is the single schema owner of data/report-index.md, a
# privacy-safe catalog of scout reports. These tests pin the public contract:
#   - rebuild deterministically extracts id/date/project/title/summary/path
#     from data/<id>/report.md (+ brief.md for project) with NO second LLM,
#   - rebuild is idempotent (same inputs -> same bytes),
#   - missing/no-title/unreadable/oversized reports are skipped to
#     data/report-index.skipped with a reason and no report body,
#   - report BODIES never enter the index or the skipped file (privacy bound),
#   - show prints a bounded tail and an ABSENT marker when no index exists,
#   - the session-start digest surfaces a bounded "Scout report index" tail
#     from the prebuilt file and never rebuilds on the blocking path.
#
# All assertions are through the executable public interface; none assert
# implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-report-index)
SCRIPT="$ROOT/bin/fm-report-index.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"

# One isolated home under the temp root. Echoes its path.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

# write_report <home> <id> <report-body on stdin>; optional project as $3.
write_report() {
  local home=$1 id=$2 brief_proj=${3:-}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/report.md"
  if [ -n "$brief_proj" ]; then
    printf 'You are in a disposable git worktree of %s, at a detached HEAD on a clean default branch.\n' \
      "$brief_proj" > "$home/data/$id/brief.md"
  fi
}

test_rebuild_extracts_all_fields_deterministically() {
  local home out line
  home=$(make_home extract)
  write_report "$home" alpha-probe firstmate <<'EOF'
# Alpha probe report

- 访问日期：2026-09-07 至 2026-09-09
- 范围：a focused scout

---

## 0. 结论摘要（TL;DR）

1. The probe confirms the hypothesis holds under load.
2. Secondary finding is out of scope here.

## 1. Body
EOF
  for _ in $(seq 1 90); do printf 'padding line %s\n' "$_"; done >> "$home/data/alpha-probe/report.md"
  printf 'Far below the head: ZZPRIVACYBODYMARKER should never reach the index.\n' \
    >> "$home/data/alpha-probe/report.md"
  out=$(FM_HOME="$home" "$SCRIPT" rebuild)
  assert_contains "$out" "indexed 1 report(s)" "rebuild reported one indexed report"
  line=$(grep -v '^#' "$home/data/report-index.md" | grep 'alpha-probe')
  assert_contains "$line" "alpha-probe | 2026-09-07 | firstmate" "id/date/project extracted"
  assert_contains "$line" "Alpha probe report" "title extracted"
  assert_contains "$line" "The probe confirms the hypothesis holds under load." "summary is the TL;DR first content line"
  assert_contains "$line" "data/alpha-probe/report.md" "path recorded"
  [ "$(grep -vc '^#' "$home/data/report-index.md")" -eq 1 ] \
    || fail "a date-range line split one report across multiple index lines"
  ! grep -q '2026-09-09' "$home/data/report-index.md" \
    || fail "date extraction retained more than the first date match"
  pass "rebuild extracts id/date/project/title/summary/path deterministically"
}

test_report_body_marker_never_enters_index_or_skipped() {
  local home
  home=$(make_home privacy)
  write_report "$home" secret-scout firstmate <<'EOF'
# Secret scout report

## Summary (TL;DR)

Benign summary line.

## Body
EOF
  for _ in $(seq 1 90); do printf 'pad %s\n' "$_"; done >> "$home/data/secret-scout/report.md"
  printf 'ZZPRIVACYBODYMARKER secret finding detail that must never be cataloged.\n' \
    >> "$home/data/secret-scout/report.md"
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  ! grep -q 'ZZPRIVACYBODYMARKER' "$home/data/report-index.md" \
    || fail "report body leaked into the index"
  ! grep -q 'ZZPRIVACYBODYMARKER' "$home/data/report-index.skipped" 2>/dev/null \
    || fail "report body leaked into the skipped file"
  pass "report body marker never enters the index or skipped diagnostics"
}

test_rebuild_is_idempotent() {
  local home first second
  home=$(make_home idempotent)
  write_report "$home" one firstmate <<'EOF'
# One

## Summary (TL;DR)

First summary.
EOF
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  first=$(cat "$home/data/report-index.md")
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  second=$(cat "$home/data/report-index.md")
  [ "$first" = "$second" ] || fail "rebuild is not idempotent (bytes differ)"
  pass "rebuild is idempotent"
}

test_skip_cases_record_reasons_without_body() {
  local home index skipped
  # Shrink the oversized cap so the test needs no giant fixture.
  home=$(make_home skips)
  write_report "$home" good one <<'EOF'
# Good

## TL;DR

ok
EOF
  write_report "$home" titleless one <<'EOF'
No heading here at all, just prose.

## Summary

ignored.
EOF
  mkdir -p "$home/data/huge"
  { printf '# Huge\n\n## TL;DR\n\nbig\n\n'; yes 'xxxxxxxxxx' 2>/dev/null | head -2000; } > "$home/data/huge/report.md"
  # Unreadable: only meaningful as non-root.
  if [ "$(id -u)" != 0 ]; then
    mkdir -p "$home/data/unread"
    printf '# Unread\n\n## TL;DR\n\nu\n' > "$home/data/unread/report.md"
    chmod 000 "$home/data/unread/report.md"
  fi
  FM_REPORT_INDEX_MAX_BYTES=1024 FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  index=$(cat "$home/data/report-index.md")
  assert_contains "$index" "good | " "the valid report was indexed"
  skipped=$(cat "$home/data/report-index.skipped")
  assert_contains "$skipped" "huge | oversized" "oversized report skipped with reason"
  assert_contains "$skipped" "titleless | no-title" "titleless report skipped with reason"
  if [ "$(id -u)" != 0 ]; then
    assert_contains "$skipped" "unread | unreadable" "unreadable report skipped with reason"
    chmod 644 "$home/data/unread/report.md"
  fi
  # A directory with a brief but no report.md is never scanned, so it appears
  # in neither file.
  mkdir -p "$home/data/no-report"
  printf 'brief only\n' > "$home/data/no-report/brief.md"
  ! grep -q 'no-report' "$home/data/report-index.md" || fail "dir without report.md was indexed"
  ! grep -q 'no-report' "$home/data/report-index.skipped" || fail "dir without report.md was skipped"
  pass "skip cases record reasons; no-report dirs are not scanned; no body leaks"
}

test_show_bounded_tail_and_absent() {
  local home out
  home=$(make_home show)
  FM_HOME="$home" "$SCRIPT" show --tail 5 >"$TMP_ROOT/show-absent.out" 2>/dev/null
  assert_grep "ABSENT" "$TMP_ROOT/show-absent.out" "show reports ABSENT when no index exists"
  for i in 1 2 3; do
    write_report "$home" "r$i" proj <<EOF
# Report $i

## Summary (TL;DR)

summary $i
EOF
  done
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  out=$(FM_HOME="$home" "$SCRIPT" show --tail 2)
  assert_contains "$out" "r3" "show tails newest entries"
  assert_contains "$out" "r2" "show tail includes second-newest"
  # r1 must not appear in a tail of 2 (entries are newest-last).
  case "$out" in *r1*) fail "show tail of 2 leaked an older entry" ;; esac
  pass "show prints a bounded tail and an ABSENT marker"
}

test_session_start_digest_surfaces_bounded_index_tail() {
  local home out
  home=$(make_home digest)
  write_report "$home" digest-scout firstmate <<'EOF'
# Digest scout

## Summary (TL;DR)

A conclusion the digest should advertise.
EOF
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  out=$(FM_HOME="$home" "$SESSION_START" 2>/dev/null)
  assert_contains "$out" "Scout report index (data/report-index.md)" "digest has the report-index subsection"
  assert_contains "$out" "digest-scout" "digest shows the report id"
  assert_contains "$out" "A conclusion the digest should advertise." "digest shows the bounded summary line"
  ! grep -q 'report index: ABSENT' <<<"$out" || fail "digest reported ABSENT despite a built index"
  pass "session-start digest surfaces a bounded scout report index tail"
}

test_session_start_digest_reports_absent_without_rebuild() {
  local home out before after
  home=$(make_home digest-absent)
  # No report-index.md and no reports. The digest must show ABSENT and must NOT
  # create the index file (rebuild would be an unbounded scan on the blocking
  # path, which the contract forbids).
  before=$(ls "$home/data" 2>/dev/null)
  out=$(FM_HOME="$home" "$SESSION_START" 2>/dev/null)
  assert_contains "$out" "report index: ABSENT" "digest reports ABSENT when no index exists"
  after=$(ls "$home/data" 2>/dev/null)
  [ "$before" = "$after" ] || fail "digest created data/ files (rebuilt on the blocking path)"
  pass "digest reports ABSENT without rebuilding"
}

test_rebuild_output_is_deterministic() {
  local home a b c
  home=$(make_home deterministic)
  write_report "$home" det firstmate <<'EOF'
# Det

- date: 2026-01-02

## TL;DR

fixed summary.
EOF
  a=$(FM_HOME="$home" "$SCRIPT" rebuild >/dev/null; cat "$home/data/report-index.md")
  b=$(FM_HOME="$home" "$SCRIPT" rebuild >/dev/null; cat "$home/data/report-index.md")
  c=$(FM_HOME="$home" "$SCRIPT" rebuild >/dev/null; cat "$home/data/report-index.md")
  [ "$a" = "$b" ] && [ "$b" = "$c" ] || fail "extraction is not deterministic across runs"
  pass "rebuild output is identical across repeated runs"
}

test_rebuild_serializes_scan_through_publication() {
  local home held release holder_pid rebuild_pid blocked=1 published=0 rc
  home=$(make_home serialized)
  held="$home/lock-held"
  release="$home/release-lock"
  write_report "$home" serialized-report firstmate <<'EOF'
# Serialized report

## TL;DR

serialized summary.
EOF
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while [ ! -f "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.report-index.lock" "$held" "$release" &
  holder_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$held" ] && break
    sleep 0.02
  done
  [ -f "$held" ] || { : > "$release"; wait "$holder_pid" 2>/dev/null; fail "lock holder did not start"; }
  FM_HOME="$home" "$SCRIPT" rebuild > "$home/rebuild.out" 2>&1 &
  rebuild_pid=$!
  sleep 0.2
  kill -0 "$rebuild_pid" 2>/dev/null || blocked=0
  [ ! -e "$home/data/report-index.md" ] || published=1
  : > "$release"
  wait "$holder_pid" || fail "lock holder failed"
  wait "$rebuild_pid"; rc=$?
  expect_code 0 "$rc" "serialized rebuild failed"
  [ "$blocked" -eq 1 ] || fail "rebuild did not wait for the shared report-index lock"
  [ "$published" -eq 0 ] || fail "rebuild published while another rebuild held the lock"
  assert_grep 'serialized-report | ' "$home/data/report-index.md" "serialized rebuild published after lock release"
  pass "rebuild serializes scan through publication"
}

test_rebuild_reports_publication_failure_and_cleans_staging() {
  local home rc leftovers
  home=$(make_home publish-failure)
  write_report "$home" publish-report firstmate <<'EOF'
# Publish report

## TL;DR

publish summary.
EOF
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=
for argument in "$@"; do destination=$argument; done
case "$destination" in
  */report-index.md) exit 73 ;;
esac
exec /bin/mv "$@"
EOF
  chmod +x "$home/fake-bin/mv"
  PATH="$home/fake-bin:$PATH" FM_HOME="$home" "$SCRIPT" rebuild \
    > "$home/rebuild.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication failure was reported as success"
  assert_grep 'could not publish report index' "$home/rebuild.out" "publication failure was diagnosable"
  [ ! -e "$home/data/report-index.md" ] || fail "failed publication left an index behind"
  leftovers=$(find "$home/data" -maxdepth 1 -name '.report-index.*' -print)
  [ -z "$leftovers" ] || fail "failed publication left staging files behind: $leftovers"
  pass "publication failure returns nonzero and cleans staging files"
}

test_rebuild_rejects_directory_destinations() {
  local home link_home rc
  home=$(make_home directory-index)
  write_report "$home" directory-report firstmate <<'EOF'
# Directory report

## TL;DR

directory summary.
EOF
  mkdir "$home/data/report-index.md"
  FM_HOME="$home" "$SCRIPT" rebuild > "$home/rebuild.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "index directory destination was reported as success"
  [ -d "$home/data/report-index.md" ] || fail "index directory destination was replaced"
  assert_grep 'destination is a directory' "$home/rebuild.out" "index directory rejection was diagnosable"

  link_home=$(make_home directory-skipped-link)
  write_report "$link_home" titleless firstmate <<'EOF'
Titleless report.
EOF
  mkdir "$link_home/skipped-target"
  ln -s "$link_home/skipped-target" "$link_home/data/report-index.skipped"
  FM_HOME="$link_home" "$SCRIPT" rebuild > "$link_home/rebuild.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "skipped directory symlink destination was reported as success"
  [ -L "$link_home/data/report-index.skipped" ] || fail "skipped directory symlink was replaced"
  assert_grep 'destination is a directory' "$link_home/rebuild.out" "skipped directory symlink rejection was diagnosable"
  pass "rebuild rejects directory and directory-symlink destinations"
}

test_rebuild_rejects_candidate_enumeration_failures() {
  local home sort_home real_sort rc
  home=$(make_home find-failure)
  write_report "$home" partial firstmate <<'EOF'
# Partial

## TL;DR

partial summary.
EOF
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/find" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FM_PARTIAL_REPORT"
exit 71
EOF
  chmod +x "$home/fake-bin/find"
  FM_PARTIAL_REPORT="$home/data/partial/report.md" PATH="$home/fake-bin:$PATH" \
    FM_HOME="$home" "$SCRIPT" rebuild > "$home/rebuild.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "failed candidate enumeration was reported as success"
  [ ! -e "$home/data/report-index.md" ] || fail "failed candidate enumeration published a partial index"
  assert_grep 'could not enumerate report candidates' "$home/rebuild.out" "find failure was diagnosable"

  sort_home=$(make_home sort-failure)
  write_report "$sort_home" unsorted firstmate <<'EOF'
# Unsorted

## TL;DR

unsorted summary.
EOF
  real_sort=$(command -v sort)
  mkdir -p "$sort_home/fake-bin"
  cat > "$sort_home/fake-bin/sort" <<'EOF'
#!/usr/bin/env bash
"$FM_REAL_SORT" "$@"
exit 72
EOF
  chmod +x "$sort_home/fake-bin/sort"
  FM_REAL_SORT="$real_sort" PATH="$sort_home/fake-bin:$PATH" \
    FM_HOME="$sort_home" "$SCRIPT" rebuild > "$sort_home/rebuild.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "failed candidate sorting was reported as success"
  [ ! -e "$sort_home/data/report-index.md" ] || fail "failed candidate sorting published an index"
  assert_grep 'could not sort report candidates' "$sort_home/rebuild.out" "sort failure was diagnosable"
  pass "rebuild rejects find and sort candidate failures"
}

test_rebuild_rejects_invalid_size_cap() {
  local home value rc
  for value in invalid 0; do
    home=$(make_home "invalid-cap-$value")
    write_report "$home" invalid-cap firstmate <<'EOF'
# Invalid cap

## TL;DR

invalid cap summary.
EOF
    FM_REPORT_INDEX_MAX_BYTES="$value" FM_HOME="$home" "$SCRIPT" rebuild \
      > "$home/rebuild.out" 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "invalid size cap $value was reported as success"
    [ ! -e "$home/data/report-index.md" ] || fail "invalid size cap $value published an index"
    assert_grep 'must be a positive integer' "$home/rebuild.out" "invalid size cap $value was diagnosable"
  done
  pass "rebuild rejects invalid and nonpositive size caps"
}

test_rebuild_handles_empty_home() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SCRIPT" rebuild 2>&1)
  assert_contains "$out" "indexed 0 report(s)" "empty home reports zero indexed"
  assert_contains "$out" "skipped 0" "empty home reports zero skipped"
  pass "rebuild handles an empty home cleanly"
}

test_rebuild_resolves_home_via_FM_HOME() {
  local home alt_home out
  home=$(make_home fmhome)
  alt_home=$(make_home fmhome-alt)
  write_report "$home" here proj <<'EOF'
# Here

## TL;DR

in home.
EOF
  write_report "$home" there proj <<'EOF'
# There

## TL;DR

in home too.
EOF
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  FM_HOME="$alt_home" "$SCRIPT" rebuild >/dev/null
  assert_grep "here | " "$home/data/report-index.md" "FM_HOME home got its report entry"
  # The index header says "No report bodies here", so grep for the entry
  # marker (id + pipe) rather than the bare word to avoid a header false hit.
  ! grep -q "here | " "$alt_home/data/report-index.md" \
    || fail "report leaked across FM_HOME boundaries"
  pass "rebuild resolves the home via FM_HOME and stays home-scoped"
}

test_rebuild_project_falls_back_when_no_brief() {
  local home line
  home=$(make_home no-brief)
  mkdir -p "$home/data/no-brief-task"
  printf '# No brief report\n\n## Summary (TL;DR)\n\nsummary.\n' > "$home/data/no-brief-task/report.md"
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  line=$(grep 'no-brief-task' "$home/data/report-index.md")
  assert_contains "$line" " | - | " "project falls back to '-' without a brief"
  pass "project field falls back to '-' when no brief is present"
}

test_rebuild_parses_cleanly() {
  local rc out
  out=$(bash -n "$SCRIPT" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-report-index.sh parses cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n emitted unexpected output: $out"
  pass "fm-report-index.sh parses cleanly"
}

test_rebuild_parses_session_start_and_teardown() {
  local rc out
  out=$(bash -n "$SESSION_START" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-session-start.sh parses cleanly (got: $out)"
  out=$(bash -n "$ROOT/bin/fm-teardown.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-teardown.sh parses cleanly (got: $out)"
  pass "touched scripts parse cleanly"
}

# r1: a completed scout recorded in the backlog whose report.md is missing is
# surfaced as `<id> | missing` rather than silently invisible.
test_rebuild_flags_missing_completed_scout_reports() {
  local home skipped
  home=$(make_home missing-scout)
  write_report "$home" present-scout firstmate <<'EOF'
# Present scout

## Summary (TL;DR)

present.
EOF
  # A completed scout recorded in done-archive but whose report.md is absent.
  cat > "$home/data/done-archive.md" <<'EOF'

## Archived 2026-09-07
- [x] ghost-scout - a completed scout whose report was removed data/ghost-scout/report.md (repo: firstmate) (kind: scout) (reported 2026-09-06)
- [x] present-scout - an indexed completed scout data/present-scout/report.md (repo: firstmate) (kind: scout) (reported 2026-09-07)
EOF
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  assert_grep "present-scout | " "$home/data/report-index.md" "the present scout was indexed"
  skipped=$(cat "$home/data/report-index.skipped" 2>/dev/null)
  assert_contains "$skipped" "ghost-scout | missing" "the missing completed scout was flagged with a reason"
  ! grep -q 'present-scout' "$home/data/report-index.skipped" 2>/dev/null \
    || fail "the present scout was wrongly flagged as missing"
  pass "rebuild flags missing completed-scout reports from the authoritative backlog"
}

# r2: entries are ordered by date then id (recency), not lexical task id, so the
# bounded tail surfaces the most recent reports.
test_rebuild_orders_entries_by_date_then_id() {
  local home out
  home=$(make_home date-order)
  # Lexical id order would put aaa before zzz; date order must win instead.
  write_report "$home" zzz-old-report firstmate <<'EOF'
# Older report

- date: 2026-01-01

## Summary (TL;DR)

older.
EOF
  write_report "$home" aaa-new-report firstmate <<'EOF'
# Newer report

- date: 2026-12-31

## Summary (TL;DR)

newer.
EOF
  FM_HOME="$home" "$SCRIPT" rebuild >/dev/null
  out=$(FM_HOME="$home" "$SCRIPT" show --tail 1)
  assert_contains "$out" "aaa-new-report" "the newest-by-date report is the tail entry"
  ! grep -q 'zzz-old-report' <<<"$out" \
    || fail "an older report displaced the newest-by-date report in the tail"
  pass "rebuild orders entries by date then id (recency), not lexical id"
}

# r12: the digest reader rejects a symlinked or non-schema-header index as
# ABSENT rather than streaming its target, so a path pointing at a report body
# can never inject report content.
test_digest_rejects_symlinked_and_non_schema_index() {
  local home out
  home=$(make_home digest-harden)
  write_report "$home" body-leak firstmate <<'EOF'
# A report body

## TL;DR

ZZLEAKMARKER must never reach the digest.
EOF
  # A symlinked index pointing at a report body.
  ln -s "$home/data/body-leak/report.md" "$home/data/report-index.md"
  out=$(FM_HOME="$home" "$SESSION_START" 2>/dev/null)
  assert_contains "$out" "report index: ABSENT" "a symlinked index was rejected as ABSENT"
  ! grep -q 'ZZLEAKMARKER' <<<"$out" || fail "a symlinked index streamed report body into the digest"
  # A regular index missing the schema-owner header.
  rm -f "$home/data/report-index.md"
  printf '# Not the schema owner\nbody line one\nbody line two\n' > "$home/data/report-index.md"
  out=$(FM_HOME="$home" "$SESSION_START" 2>/dev/null)
  assert_contains "$out" "is not the schema-owner index" "a non-schema-header index was rejected"
  ! grep -q 'body line one' <<<"$out" || fail "a non-schema index streamed content into the digest"
  pass "the digest rejects symlinked and non-schema-header indexes without streaming bodies"
}

test_rebuild_extracts_all_fields_deterministically
test_report_body_marker_never_enters_index_or_skipped
test_rebuild_is_idempotent
test_skip_cases_record_reasons_without_body
test_show_bounded_tail_and_absent
test_rebuild_output_is_deterministic
test_rebuild_serializes_scan_through_publication
test_rebuild_reports_publication_failure_and_cleans_staging
test_rebuild_rejects_directory_destinations
test_rebuild_rejects_candidate_enumeration_failures
test_rebuild_rejects_invalid_size_cap
test_rebuild_handles_empty_home
test_rebuild_resolves_home_via_FM_HOME
test_rebuild_project_falls_back_when_no_brief
test_rebuild_parses_cleanly
test_rebuild_parses_session_start_and_teardown
test_rebuild_flags_missing_completed_scout_reports
test_rebuild_orders_entries_by_date_then_id
test_digest_rejects_symlinked_and_non_schema_index
test_session_start_digest_surfaces_bounded_index_tail
test_session_start_digest_reports_absent_without_rebuild
