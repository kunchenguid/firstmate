#!/usr/bin/env bash
# tests/fm-queued-recheck.test.sh - behavior tests for the still-true re-check
# scan: a queued record whose declared report already exists, or whose named PR
# has merged, must surface for a human re-check and must never be closed or
# removed by the scan itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

RECHECK="$ROOT/bin/fm-queued-recheck.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-queued-recheck)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  empty_backlog "$home/data/backlog.md"
  fakebin="$home/fakebin"
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes
  printf 'OPEN\n' > "$home/pr-state"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${home}/gh.log"
if [ "\${1:-}" = api ] && [ "\${2:-}" = graphql ]; then
  state=\$(cat "$home/pr-state" 2>/dev/null || printf 'OPEN')
  case "\$state" in
    MERGED) printf '%s\\n' 'state=MERGED' 'merged=true' ;;
    *) printf '%s\\n' 'state=OPEN' 'merged=false' ;;
  esac
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${home}/gh-axi.log"
if [ "\${1:-}" = pr ] && [ "\${2:-}" = view ]; then
  printf 'state: %s\\n' "\$(cat "$home/pr-state" 2>/dev/null || printf 'OPEN')"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$home"
}

run_recheck() {  # <home> [args...]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$ROOT" "$RECHECK" "$@"
}

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$DRAIN"
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && PATH="$home/fakebin:$PATH" tasks-axi "$@")
}

queued_ids() {  # <home>
  tasks_in "$1" list --state queued | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id=$1
      sub(/^ +/, "", id)
      print id
    }
  '
}

test_queued_report_on_disk_surfaces_and_stays_queued() {
  local home out after
  home=$(make_home report-exists)
  tasks_in "$home" add scout-done "Scout whose report already exists" --kind scout >/dev/null
  mkdir -p "$home/data/scout-done"
  printf '%s\n' '# findings' > "$home/data/scout-done/report.md"

  out=$(run_recheck "$home") || fail "local scan failed on a queued report"
  assert_contains "$out" $'scout-done\treport\tdata/scout-done/report.md' \
    "a queued record with its report on disk produced no re-check line"

  after=$(queued_ids "$home")
  assert_contains "$after" "scout-done" \
    "the scan closed or removed the queued record instead of only warning"
  assert_present "$home/data/scout-done/report.md" \
    "the scan deleted the declared report"
  pass "queued report on disk surfaces and the record stays queued"
}

test_queued_without_report_is_silent() {
  local home out
  home=$(make_home report-absent)
  tasks_in "$home" add still-open "Genuinely open queued work" --kind ship >/dev/null
  out=$(run_recheck "$home") || fail "local scan failed on a clean queue"
  [ -z "$out" ] || fail "a queued record with no report produced output: $out"
  pass "queued record without a report stays silent"
}

test_in_flight_report_is_not_a_queued_recheck() {
  local home out
  home=$(make_home in-flight-report)
  tasks_in "$home" add live-scout "Live scout" --kind scout --start >/dev/null
  mkdir -p "$home/data/live-scout"
  printf '%s\n' '# draft' > "$home/data/live-scout/report.md"
  out=$(run_recheck "$home") || fail "local scan failed on an in-flight report"
  [ -z "$out" ] || fail "an in-flight report was treated as a queued re-check: $out"
  pass "in-flight report is not a queued re-check"
}

test_held_queued_report_is_silent() {
  local home out
  home=$(make_home held-report)
  tasks_in "$home" add held-scout "Held scout" --kind scout >/dev/null
  tasks_in "$home" hold held-scout --reason "captain still deciding" --kind captain >/dev/null
  mkdir -p "$home/data/held-scout"
  printf '%s\n' '# findings' > "$home/data/held-scout/report.md"
  out=$(run_recheck "$home") || fail "local scan failed on a held report"
  [ -z "$out" ] || fail "a held queued report was treated as a silent-queue miss: $out"
  pass "held queued report stays off the re-check list"
}

test_symlink_report_is_ignored() {
  local home out
  home=$(make_home symlink-report)
  tasks_in "$home" add link-scout "Symlink report" --kind scout >/dev/null
  mkdir -p "$home/data/link-scout" "$home/elsewhere"
  printf '%s\n' '# elsewhere' > "$home/elsewhere/report.md"
  ln -s "$home/elsewhere/report.md" "$home/data/link-scout/report.md"
  out=$(run_recheck "$home") || fail "local scan failed on a symlink report"
  [ -z "$out" ] || fail "a symlink report was treated as the declared deliverable: $out"
  pass "symlink report is ignored"
}

test_merged_named_pr_surfaces_only_with_forge_read() {
  local home out after
  home=$(make_home merged-pr)
  tasks_in "$home" add pr-1702-rebase "Rebase leftover" --kind ship \
    --pr https://github.com/acme/maker/pull/1702 >/dev/null
  printf 'MERGED\n' > "$home/pr-state"

  out=$(run_recheck "$home") || fail "local scan failed"
  [ -z "$out" ] || fail "local scan queried or reported a PR without a forge read: $out"
  [ ! -s "$home/gh.log" ] || fail "local scan invoked gh: $(cat "$home/gh.log")"

  out=$(run_recheck "$home" --with-pr) || fail "forge scan failed on a merged PR"
  assert_contains "$out" $'pr-1702-rebase\tpr\thttps://github.com/acme/maker/pull/1702' \
    "a queued record naming a merged PR produced no re-check line"

  after=$(queued_ids "$home")
  assert_contains "$after" "pr-1702-rebase" \
    "the forge scan closed the queued record instead of only warning"
  pass "merged named PR surfaces with --with-pr and stays queued"
}

test_open_named_pr_is_silent() {
  local home out
  home=$(make_home open-pr)
  tasks_in "$home" add pr-still-open "Still open PR work" --kind ship \
    --pr https://github.com/acme/maker/pull/99 >/dev/null
  printf 'OPEN\n' > "$home/pr-state"
  out=$(run_recheck "$home" --with-pr) \
    || fail "forge scan failed on an open PR"
  [ -z "$out" ] || fail "an open named PR produced a re-check line: $out"
  pass "open named PR stays silent"
}

test_body_url_is_not_a_named_pr() {
  local home out
  home=$(make_home body-pr)
  tasks_in "$home" add followup "Regression cleanup" --kind ship \
    --body "Regression from https://github.com/acme/maker/pull/1824 yesterday." >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  out=$(run_recheck "$home" --with-pr) \
    || fail "forge scan failed on a body URL"
  [ -z "$out" ] || fail "a PR URL cited only in the body was treated as a named PR: $out"
  [ ! -s "$home/gh.log" ] || fail "a body-only PR URL caused a forge read: $(cat "$home/gh.log")"
  pass "body PR URL is not a named PR"
}

test_title_prose_url_is_not_a_named_pr() {
  local home out
  home=$(make_home title-pr)
  tasks_in "$home" add title-cite "Follow-up to https://github.com/acme/maker/pull/1824 fallout" \
    --kind ship >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  out=$(run_recheck "$home" --with-pr) \
    || fail "forge scan failed on a title URL"
  [ -z "$out" ] || fail "a PR URL cited mid-title was treated as a named PR: $out"
  [ ! -s "$home/gh.log" ] || fail "a mid-title PR URL caused a forge read: $(cat "$home/gh.log")"
  pass "mid-title PR URL is not a named PR"
}

test_long_title_prose_url_is_not_a_named_pr() {
  local home out
  home=$(make_home long-title-pr)
  # tasks-axi show truncates titles past 80 characters, which would cut the
  # mid-title URL and hide it from the title check.
  tasks_in "$home" add long-cite \
    "Follow-up to the regression and review fallout from https://github.com/acme/maker/pull/1824 still needs a proper fix" \
    --kind ship >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  out=$(run_recheck "$home" --with-pr) \
    || fail "forge scan failed on a long title URL"
  [ -z "$out" ] || fail "a PR URL cited mid-title in a long title was treated as a named PR: $out"
  pass "mid-title PR URL in a long title is not a named PR"
}

test_long_title_trailing_pr_link_still_surfaces() {
  local home out
  home=$(make_home long-title-trailing-pr)
  tasks_in "$home" add long-link \
    "Fix after the shared release branch fallout from https://github.com/acme/maker/pull/1824 lands" \
    --kind ship --pr https://github.com/acme/maker/pull/1830 >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  out=$(run_recheck "$home" --with-pr) \
    || fail "forge scan failed on a long title with a trailing link"
  assert_contains "$out" $'long-link\tpr\thttps://github.com/acme/maker/pull/1830' \
    "a --pr link at the end of a long title produced no re-check line"
  case "$out" in
    *pull/1824*) fail "the mid-title citation in a long title was treated as a named PR: $out" ;;
  esac
  pass "trailing --pr link on a long title still surfaces"
}

test_forge_failure_keeps_the_previous_merged_cache_line() {
  local home out
  home=$(make_home pr-cache-forge-failure)
  tasks_in "$home" add cached-pr "Cached merged PR" --kind ship \
    --pr https://github.com/acme/maker/pull/5 >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  run_recheck "$home" --with-pr >/dev/null || fail "forge scan failed while filling cache"

  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/gh-axi"
  out=$(run_recheck "$home" --with-pr) || fail "forge scan failed when gh was unavailable"
  assert_contains "$out" $'cached-pr\tpr\thttps://github.com/acme/maker/pull/5' \
    "a failed forge read dropped the confirmed merged-PR finding"
  out=$(run_recheck "$home") || fail "local rescan failed"
  assert_contains "$out" $'cached-pr\tpr\thttps://github.com/acme/maker/pull/5' \
    "a failed forge read deleted the confirmed merged-PR cache line"
  pass "a failed forge read keeps the previous merged-PR cache line"
}

test_with_pr_cache_lets_local_rescan_skip_the_forge() {
  local home out
  home=$(make_home pr-cache)
  tasks_in "$home" add cached-pr "Cached merged PR" --kind ship \
    --pr https://github.com/acme/maker/pull/5 >/dev/null
  printf 'MERGED\n' > "$home/pr-state"
  run_recheck "$home" --with-pr >/dev/null || fail "forge scan failed while filling cache"

  : > "$home/gh.log"
  out=$(run_recheck "$home") || fail "local rescan failed"
  assert_contains "$out" $'cached-pr\tpr\thttps://github.com/acme/maker/pull/5' \
    "local rescan did not reuse the merged-PR cache"
  [ ! -s "$home/gh.log" ] || fail "local rescan invoked gh after the cache was filled: $(cat "$home/gh.log")"
  pass "merged-PR cache lets a later local scan skip the forge"
}

test_section_flag_never_claims_to_close_anything() {
  local home out
  home=$(make_home section-copy)
  tasks_in "$home" add scout-done "Scout whose report already exists" --kind scout >/dev/null
  mkdir -p "$home/data/scout-done"
  printf '%s\n' '# findings' > "$home/data/scout-done/report.md"
  out=$(run_recheck "$home" --section) || fail "section render failed"
  assert_contains "$out" "STILL-TRUE RE-CHECK" "section render dropped its heading"
  assert_contains "$out" "nothing was closed automatically" \
    "section render dropped the never-close safeguard"
  assert_contains "$out" "Nothing here removes a record" \
    "section render dropped the undelivered-content safeguard"
  pass "section copy states that nothing is closed or removed"
}

test_drain_prints_the_queued_report_warning() {
  local home out after
  home=$(make_home drain-report)
  tasks_in "$home" add scout-done "Scout whose report already exists" --kind scout >/dev/null
  mkdir -p "$home/data/scout-done"
  printf '%s\n' '# findings' > "$home/data/scout-done/report.md"
  out=$(run_drain "$home") || fail "drain failed on a queued report"
  assert_contains "$out" "STILL-TRUE RE-CHECK" "drain omitted the re-check section"
  assert_contains "$out" "scout-done" "drain omitted the queued id"
  assert_contains "$out" "data/scout-done/report.md" "drain omitted the report path"
  after=$(queued_ids "$home")
  assert_contains "$after" "scout-done" "drain closed the queued record"
  pass "drain prints the queued-report warning and leaves the record queued"
}

test_queued_report_on_disk_surfaces_and_stays_queued
test_queued_without_report_is_silent
test_in_flight_report_is_not_a_queued_recheck
test_held_queued_report_is_silent
test_symlink_report_is_ignored
test_merged_named_pr_surfaces_only_with_forge_read
test_open_named_pr_is_silent
test_body_url_is_not_a_named_pr
test_title_prose_url_is_not_a_named_pr
test_long_title_prose_url_is_not_a_named_pr
test_long_title_trailing_pr_link_still_surfaces
test_forge_failure_keeps_the_previous_merged_cache_line
test_with_pr_cache_lets_local_rescan_skip_the_forge
test_section_flag_never_claims_to_close_anything
test_drain_prints_the_queued_report_warning
