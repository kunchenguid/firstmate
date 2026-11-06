#!/usr/bin/env bash
# Behavioral coverage for the daily startup growth check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-startup-growth-check)
CHECK="$ROOT/bin/fm-startup-growth-check.sh"

make_world() {
  local name=$1 root home
  root="$TMP_ROOT/$name/root"
  home="$TMP_ROOT/$name/home"
  mkdir -p "$root/bin" "$home/config" "$home/data" "$home/state"
  printf '# Firstmate\n' > "$root/AGENTS.md"
  printf 'See AGENTS.md\n' > "$root/CLAUDE.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-session-start.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-bootstrap.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/fm-supervision-instructions.sh"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf 'projects\n' > "$home/data/projects.md"
  printf 'secondmates\n' > "$home/data/secondmates.md"
  printf 'captain\n' > "$home/data/captain.md"
  printf 'shared\n' > "$home/data/captain-shared.md"
  printf 'learnings\n' > "$home/data/learnings.md"
  printf '%s|%s\n' "$root" "$home"
}

run_check() {
  local root=$1 home=$2 now=$3 out status=0
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW="$now" "$CHECK" check 2>&1) || status=$?
  printf '%s\t%s\n' "$status" "$out"
}

output_part() { printf '%s' "$1" | cut -f2-; }
status_part() { printf '%s' "$1" | cut -f1; }

add_bytes() {
  local path=$1 count=$2
  dd if=/dev/zero bs=1 count="$count" 2>/dev/null | tr '\000' x >> "$path"
}

budget_total() {  # <home>
  awk -F '\t' '$1 == "memory_budget" { print $3; exit }' "$1/state/.startup-growth-check"
}

test_initial_baseline_is_silent_and_records_metadata() {
  local rec root home result out
  rec=$(make_world baseline)
  root=${rec%%|*}
  home=${rec#*|}
  result=$(run_check "$root" "$home" 1000)
  [ "$(status_part "$result")" = 0 ] || fail "baseline check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "baseline without findings should stay silent: $out"
  assert_grep $'last_eval\t1000' "$home/state/.startup-growth-check" "baseline did not record the evaluation time"
  assert_grep $'AGENTS.md\ttracked\tpresent' "$home/state/.startup-growth-check" "baseline did not record tracked startup metadata"
  assert_grep $'data/learnings.md\tmemory\tpresent' "$home/state/.startup-growth-check" "baseline did not record memory metadata"
  assert_grep $'data/projects.md\tprinted-memory\tpresent' "$home/state/.startup-growth-check" "baseline did not record printed projects metadata"
  assert_grep $'data/secondmates.md\tprinted-memory\tpresent' "$home/state/.startup-growth-check" "baseline did not record printed secondmates metadata"
}

test_same_day_poll_does_not_touch_surfaces() {
  local rec root home result out
  rec=$(make_world same-day)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  rm -f "$root/AGENTS.md"
  ln -s /no/such/place "$root/AGENTS.md"
  result=$(run_check "$root" "$home" 1200)
  [ "$(status_part "$result")" = 0 ] || fail "same-day poll failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "same-day poll inspected surfaces instead of staying gated: $out"
  assert_grep $'last_eval\t1000' "$home/state/.startup-growth-check" "same-day poll rewrote the daily record"
}

test_due_growth_reports_once_and_dedupes() {
  local rec root home result out
  rec=$(make_world growth)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  add_bytes "$root/AGENTS.md" 2500
  add_bytes "$home/data/learnings.md" 900
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "growth check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'tracked startup surface growth AGENTS.md +2500 bytes' "tracked growth was not reported"
  assert_contains "$out" 'memory growth data/learnings.md +300 estimated_tokens (+900 bytes' "memory growth was not reported as estimated prompt cost"
  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "dedupe check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "unchanged persistent finding was repeated: $out"
}

test_gradual_growth_below_daily_threshold_is_reported_cumulatively() {
  local rec root home result out now day
  rec=$(make_world cumulative)
  root=${rec%%|*}
  home=${rec#*|}
  now=1000
  result=$(run_check "$root" "$home" "$now")
  [ "$(status_part "$result")" = 0 ] || fail "cumulative baseline failed: $(output_part "$result")"
  for day in 1 2 3; do
    add_bytes "$root/AGENTS.md" 700
    add_bytes "$home/data/learnings.md" 300
    now=$((now + 86401))
    result=$(run_check "$root" "$home" "$now")
    [ "$(status_part "$result")" = 0 ] || fail "cumulative day $day failed: $(output_part "$result")"
    out=$(output_part "$result")
    if [ "$day" -lt 3 ]; then
      [ -z "$out" ] || fail "sub-threshold day $day should stay silent: $out"
    fi
  done
  assert_contains "$out" 'tracked startup surface growth AGENTS.md +2100 bytes' "cumulative tracked growth was not reported once it added up"
  assert_contains "$out" 'memory growth data/learnings.md +300 estimated_tokens (+900 bytes' "cumulative memory growth was not reported once it added up"

  now=$((now + 86401))
  result=$(run_check "$root" "$home" "$now")
  [ "$(status_part "$result")" = 0 ] || fail "post-report check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "reported growth was repeated after the baseline was rebased: $out"
}

test_printed_memory_growth_is_reported_without_entering_the_budget_total() {
  local rec root home result out before after
  rec=$(make_world printed)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  before=$(budget_total "$home")
  add_bytes "$home/data/projects.md" 900
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "printed-memory check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'printed-memory growth data/projects.md +300 estimated_tokens (+900 bytes' "printed startup memory growth was not reported"
  after=$(budget_total "$home")
  assert_equals "$before" "$after" "printed startup memory changed the budget total it must not own"
}

test_first_content_of_an_optional_file_is_baselined_silently() {
  local rec root home result out
  rec=$(make_world first-content)
  root=${rec%%|*}
  home=${rec#*|}
  rm -f "$home/data/secondmates.md"
  result=$(run_check "$root" "$home" 1000)
  [ "$(status_part "$result")" = 0 ] || fail "absent-surface baseline failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "an absent optional surface should stay silent: $out"

  add_bytes "$home/data/secondmates.md" 1000
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "first-content check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "first content of an optional file was reported as growth: $out"

  add_bytes "$home/data/secondmates.md" 900
  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "post-baseline growth check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'printed-memory growth data/secondmates.md +300 estimated_tokens (+900 bytes' "growth above the silently established baseline was not reported"
}

test_established_baseline_survives_disappearance_and_restoration() {
  local rec root home result out
  rec=$(make_world restored)
  root=${rec%%|*}
  home=${rec#*|}
  add_bytes "$home/data/projects.md" 3000
  run_check "$root" "$home" 1000 >/dev/null

  rm -f "$home/data/projects.md"
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "disappearance check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "an absent optional surface should stay silent: $out"

  printf 'projects\n' > "$home/data/projects.md"
  add_bytes "$home/data/projects.md" 3000
  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "restoration check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "restoring a file at its established size was reported as growth: $out"

  add_bytes "$home/data/projects.md" 900
  result=$(run_check "$root" "$home" 260203)
  [ "$(status_part "$result")" = 0 ] || fail "post-restoration growth check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'printed-memory growth data/projects.md +300 estimated_tokens (+900 bytes' "growth above the preserved baseline was not reported after restoration"
}

test_secondmate_is_not_notified_about_primary_owned_shared_growth() {
  local rec root home result out
  rec=$(make_world shared-growth)
  root=${rec%%|*}
  home=${rec#*|}
  : > "$home/.fm-secondmate-home"
  run_check "$root" "$home" 1000 >/dev/null
  add_bytes "$home/data/captain-shared.md" 900
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "secondmate shared-growth check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "a secondmate was notified about growth of the read-only primary-owned shared file: $out"

  rec=$(make_world shared-growth-primary)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  add_bytes "$home/data/captain-shared.md" 900
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "primary shared-growth check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'memory growth data/captain-shared.md +300 estimated_tokens (+900 bytes' "a primary home did not report growth of its own shared file"
}

test_budget_overrun_reports_and_separates_prompt_cost() {
  local rec root home result out
  rec=$(make_world overrun)
  root=${rec%%|*}
  home=${rec#*|}
  printf '10\n' > "$home/config/startup-memory-budget"
  add_bytes "$home/data/captain.md" 90
  add_bytes "$root/bin/fm-bootstrap.sh" 3000
  result=$(run_check "$root" "$home" 1000)
  [ "$(status_part "$result")" = 0 ] || fail "overrun check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'startup memory budget overrun total_estimated_tokens=' "budget overrun was not reported"
  assert_not_contains "$out" 'tracked startup surface growth' "initial tracked growth should not be inferred without a baseline"
  assert_not_contains "$out" 'bin/fm-bootstrap.sh' "initial tracked bytes were incorrectly counted as prompt-memory overrun evidence"
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "repeated overrun check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "standing budget overrun was reported again instead of deduplicated: $out"
}

test_secondmate_is_not_woken_about_the_primary_owned_shared_overrun() {
  local rec root home result out
  rec=$(make_world secondmate)
  root=${rec%%|*}
  home=${rec#*|}
  printf '10\n' > "$home/config/startup-memory-budget"
  add_bytes "$home/data/captain-shared.md" 900
  : > "$home/.fm-secondmate-home"
  result=$(run_check "$root" "$home" 1000)
  [ "$(status_part "$result")" = 0 ] || fail "secondmate overrun check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_not_contains "$out" 'startup memory budget overrun' "a secondmate was woken about the primary-owned shared overrun it cannot act on"

  rm -f "$home/.fm-secondmate-home"
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "primary overrun check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'startup memory budget overrun total_estimated_tokens=' "the same overrun was not reported in a primary home"
}

test_metadata_read_failure_keeps_the_retained_baseline() {
  local rec root home result out fakebin real_stat
  if [ "$(uname)" = Darwin ]; then
    printf 'note - metadata read failure is exercised through the stat -c branch; skipping on Darwin\n'
    return 0
  fi
  rec=$(make_world unreadable)
  root=${rec%%|*}
  home=${rec#*|}
  add_bytes "$root/AGENTS.md" 5000
  result=$(run_check "$root" "$home" 1000)
  [ "$(status_part "$result")" = 0 ] || fail "unreadable baseline failed: $(output_part "$result")"

  real_stat=$(command -v stat) || fail "no stat(1) on PATH"
  fakebin="$TMP_ROOT/unreadable/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/stat" <<FAKE
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in
  -c:%s) exit 1 ;;
esac
exec $real_stat "\$@"
FAKE
  chmod 0755 "$fakebin/stat"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=87401 "$CHECK" check 2>&1) \
    || fail "unreadable due run failed: $out"
  assert_contains "$out" 'unreadable tracked AGENTS.md' "a failed size read was not reported as unreadable"

  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "post-failure check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "a failed metadata read destroyed the retained baseline and fabricated growth: $out"
}

test_due_unsafe_inputs_are_reported_but_absent_optional_memory_is_not() {
  local rec root home result out
  rec=$(make_world unsafe)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  rm -f "$home/data/captain-shared.md" "$home/data/learnings.md"
  ln -s "$home/data/captain.md" "$home/data/learnings.md"
  result=$(run_check "$root" "$home" 87401)
  [ "$(status_part "$result")" = 0 ] || fail "unsafe check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'unsafe memory data/learnings.md' "unsafe symlinked memory was not reported"
  assert_not_contains "$out" 'missing memory data/captain-shared.md' "absent optional shared memory should not be reported"
  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "repeated unsafe check failed: $(output_part "$result")"
  out=$(output_part "$result")
  [ -z "$out" ] || fail "standing unsafe finding was reported again instead of deduplicated: $out"
}

test_over_long_finding_set_is_capped_with_the_shared_marker() {
  local rec root home deep seg out reported
  rec=$(make_world capped)
  root=${rec%%|*}
  home=${rec#*|}
  seg=
  while [ "${#seg}" -lt 100 ]; do
    seg="${seg}memory"
  done
  deep="$home/data"
  while [ "${#deep}" -lt 1200 ]; do
    deep="$deep/$seg"
  done
  mkdir -p "$deep"
  ln -s "$home/data/captain.md" "$deep/learnings.md"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$deep" FM_STARTUP_GROWTH_NOW=1000 \
    "$CHECK" check 2>/dev/null) || fail "capped check failed"
  assert_contains "$out" 'unsafe memory data/learnings.md' "the leading finding was lost"
  [ "${#out}" -le 1000 ] || fail "the wake line was emitted uncapped at ${#out} characters"
  assert_contains "$out" ' [truncated]' "the capped wake line carries no truncation marker"
  reported=$(awk -F '\t' '$1 == "reported" { print substr($0, index($0, "\t") + 1); exit }' \
    "$home/state/.startup-growth-check")
  [ "${#reported}" -gt "${#out}" ] \
    || fail "the dedupe record stored the capped line instead of the full finding set"
}

test_unknown_budget_verdict_fields_are_reported_as_unparseable() {
  local rec root home fixbin out
  fixbin=$(make_isolated_bin verdict 0)

  cat > "$fixbin/fm-startup-memory-budget.sh" <<'STUB'
#!/usr/bin/env bash
printf 'role=primary
'
printf 'effective_budget_tokens=7500
'
printf 'total_estimated_tokens=10
'
printf 'budget_status=sideways
'
STUB
  chmod 0755 "$fixbin/fm-startup-memory-budget.sh"
  rec=$(make_world verdict-status)
  root=${rec%%|*}
  home=${rec#*|}
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=1000 \
    "$fixbin/fm-startup-growth-check.sh" check 2>&1) || fail "unknown-status check failed: $out"
  assert_contains "$out" 'reason=unparseable report' "an unrecognized budget_status was accepted as within-budget"

  cat > "$fixbin/fm-startup-memory-budget.sh" <<'STUB'
#!/usr/bin/env bash
printf 'role=primary
'
printf 'effective_budget_tokens=10
'
printf 'total_estimated_tokens=7500
'
printf 'budget_status=over-budget
'
printf 'exception=some-unrelated-annotation
'
STUB
  chmod 0755 "$fixbin/fm-startup-memory-budget.sh"
  rec=$(make_world verdict-exception)
  root=${rec%%|*}
  home=${rec#*|}
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=1000 \
    "$fixbin/fm-startup-growth-check.sh" check 2>&1) || fail "unknown-exception check failed: $out"
  assert_contains "$out" 'reason=unparseable report' "an unrecognized exception annotation silently suppressed the overrun"
}

test_record_with_a_foreign_schema_marker_is_not_trusted() {
  local rec root home record out first
  rec=$(make_world foreign-schema)
  root=${rec%%|*}
  home=${rec#*|}
  record="$home/state/.startup-growth-check"
  {
    printf 'schema\tfm-startup-growth-check-v2\n'
    printf 'last_eval\t1000\n'
    printf 'AGENTS.md\tpresent\t1\t1\t1\n'
  } > "$record"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=1200 "$CHECK" check 2>&1) \
    || fail "foreign-schema check failed: $out"
  [ -z "$out" ] || fail "a record from another schema was reinterpreted instead of re-baselined: $out"
  IFS= read -r first < "$record"
  assert_equals "$(printf 'schema\tfm-startup-growth-check-v1')" "$first" "the foreign record was kept instead of replaced"
  assert_grep $'last_eval\t1200' "$record" "the foreign record's last_eval gated the evaluation instead of being ignored"
}

test_findings_are_delivered_even_when_the_record_cannot_be_published() {
  local rec root home out status=0 leftover
  rec=$(make_world unpublishable)
  root=${rec%%|*}
  home=${rec#*|}
  printf '5\n' > "$home/config/startup-memory-budget"
  ln -s /no/such/place "$home/state/.startup-growth-check"
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=1000 "$CHECK" check 2>/dev/null) || status=$?
  [ "$status" != 0 ] || fail "an unpublishable report record should surface as a failure"
  assert_contains "$out" 'startup memory budget overrun' "the finding was dropped because the record could not be published"
  leftover=$(cd "$home/state" && ls -1 .startup-growth-check.?????? 2>/dev/null || true)
  [ -z "$leftover" ] || fail "a failed evaluation leaked its temporary record: $leftover"
}

# Copies the check and the libraries it sources into an isolated bin, so the
# helpers it execs can be replaced: the budget owner with a stub report, or the
# register with a failing one.
make_isolated_bin() {  # <name> <register-exit-code>
  local name=$1 code=$2 bin
  bin="$TMP_ROOT/$name/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-startup-growth-check.sh" "$ROOT/bin/fm-pr-lib.sh" \
    "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$ROOT/bin/fm-line-cap-lib.sh" \
    "$ROOT/bin/fm-check-lib.sh" "$ROOT/bin/fm-startup-memory-budget.sh" "$bin/"
  if [ "$code" = 0 ]; then
    cp "$ROOT/bin/fm-check-register.sh" "$bin/fm-check-register.sh"
  else
    printf '#!/usr/bin/env bash\nexit %s\n' "$code" > "$bin/fm-check-register.sh"
    chmod 0755 "$bin/fm-check-register.sh"
  fi
  printf '%s\n' "$bin"
}

test_rearming_an_unchanged_binding_does_not_replace_the_shim() {
  local rec root home bin before after out
  rec=$(make_world rearm-noop)
  root=${rec%%|*}
  home=${rec#*|}
  bin=$(make_isolated_bin rearm-noop 0)
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$bin/fm-startup-growth-check.sh" arm >/dev/null \
    || fail "first arm failed"
  before=$(fm_pr_file_inode "$home/state/startup-growth.check.sh")
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$bin/fm-startup-growth-check.sh" arm 2>&1) \
    || fail "re-arm of an unchanged binding failed: $out"
  after=$(fm_pr_file_inode "$home/state/startup-growth.check.sh")
  assert_equals "$before" "$after" "re-arming replaced a shim whose bytes were already correct"
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$root" FM_STARTUP_GROWTH_NOW=1000 \
    "$home/state/startup-growth.check.sh" 2>&1) || fail "the re-armed shim no longer runs: $out"
  assert_present "$home/state/.startup-growth-check" "the re-armed shim did not run the daily check"
}

test_failed_first_arm_leaves_the_home_plainly_unarmed() {
  local rec root home bin status=0 out leftover
  rec=$(make_world arm-fail)
  root=${rec%%|*}
  home=${rec#*|}
  bin=$(make_isolated_bin arm-fail 1)
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$bin/fm-startup-growth-check.sh" arm 2>&1) || status=$?
  [ "$status" != 0 ] || fail "a failed registration reported a successful arm"
  assert_absent "$home/state/startup-growth.check.sh" "a failed first arm left an unregistered shim behind"
  assert_absent "$home/state/startup-growth.check-trust" "a failed first arm left a trust binding behind"
  leftover=$(cd "$home/state" && ls -1 .startup-growth-check-shim.?????? 2>/dev/null || true)
  [ -z "$leftover" ] || fail "a failed arm leaked its staged shim: $leftover"
}

test_failed_rearm_keeps_the_previously_armed_shim_and_trust() {
  local rec root home bin good bad shim trust status=0 out
  rec=$(make_world rearm-fail)
  root=${rec%%|*}
  home=${rec#*|}
  good=$(make_isolated_bin rearm-fail 0)
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$good/fm-startup-growth-check.sh" arm >/dev/null \
    || fail "first arm failed"
  shim=$(cat "$home/state/startup-growth.check.sh")
  trust=$(cat "$home/state/startup-growth.check-trust")

  bad=$(make_isolated_bin rearm-fail-bad 1)
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$bad/fm-startup-growth-check.sh" arm 2>&1) || status=$?
  [ "$status" != 0 ] || fail "a failed re-registration reported a successful arm"
  assert_present "$home/state/startup-growth.check.sh" "a failed re-arm disarmed a working home"
  assert_present "$home/state/startup-growth.check-trust" "a failed re-arm removed the trust binding of a working home"
  assert_equals "$shim" "$(cat "$home/state/startup-growth.check.sh")" "a failed re-arm changed the armed shim"
  assert_equals "$trust" "$(cat "$home/state/startup-growth.check-trust")" "a failed re-arm changed the trust binding"
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$root" FM_STARTUP_GROWTH_NOW=1000 \
    "$home/state/startup-growth.check.sh" 2>&1) || fail "the preserved shim no longer runs: $out"
  assert_present "$home/state/.startup-growth-check" "the preserved shim did not run the daily check"
}

test_interrupted_evaluation_abandons_its_partial_record() {
  local rec root home bin ready pid status=0 waited=0 first leftover result out
  rec=$(make_world interrupted)
  root=${rec%%|*}
  home=${rec#*|}
  run_check "$root" "$home" 1000 >/dev/null
  add_bytes "$root/AGENTS.md" 1500

  bin=$(make_isolated_bin interrupted 0)
  ready="$TMP_ROOT/interrupted/budget-entered"
  cat > "$bin/fm-startup-memory-budget.sh" <<STUB
#!/usr/bin/env bash
: > "$ready"
while [ -f "$ready" ]; do
  sleep 0.05
done
printf 'role=primary\n'
printf 'effective_budget_tokens=7500\n'
printf 'total_estimated_tokens=10\n'
printf 'budget_status=within-budget\n'
STUB
  chmod 0755 "$bin/fm-startup-memory-budget.sh"

  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STARTUP_GROWTH_NOW=87401 \
    "$bin/fm-startup-growth-check.sh" check >/dev/null 2>&1 &
  pid=$!
  while [ ! -f "$ready" ]; do
    [ "$waited" -lt 200 ] || fail "the check never reached its budget call"
    waited=$((waited + 1))
    sleep 0.05
  done
  kill -TERM "$pid" || fail "could not signal the running check"
  rm -f "$ready"
  wait "$pid" || status=$?
  [ "$status" != 0 ] || fail "an interrupted evaluation finished as if it had published a record"

  IFS= read -r first < "$home/state/.startup-growth-check"
  assert_equals "$(printf 'schema\tfm-startup-growth-check-v1')" "$first" "an interrupted evaluation published a partial record"
  assert_grep $'last_eval\t1000' "$home/state/.startup-growth-check" "an interrupted evaluation advanced the daily gate"
  leftover=$(cd "$home/state" && ls -1 .startup-growth-check.?????? 2>/dev/null || true)
  [ -z "$leftover" ] || fail "an interrupted evaluation left its temporary record behind: $leftover"

  add_bytes "$root/AGENTS.md" 1000
  result=$(run_check "$root" "$home" 173802)
  [ "$(status_part "$result")" = 0 ] || fail "post-interrupt check failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_contains "$out" 'tracked startup surface growth AGENTS.md +2500 bytes' "the retained baselines did not survive an interrupted evaluation"
}

test_aged_empty_orphan_records_are_swept_without_touching_live_work() {
  local rec root home state now result out
  rec=$(make_world orphan-sweep)
  root=${rec%%|*}
  home=${rec#*|}
  state="$home/state"
  now=$(date +%s)
  run_check "$root" "$home" "$((now - 90000))" >/dev/null
  add_bytes "$root/AGENTS.md" 2500

  : > "$state/.startup-growth-check.aaaaaa"
  printf 'schema\tfm-startup-growth-check-v1\n' > "$state/.startup-growth-check.bbbbbb"
  touch -t 202001010000 "$state/.startup-growth-check.aaaaaa" "$state/.startup-growth-check.bbbbbb"
  : > "$state/.startup-growth-check.cccccc"

  result=$(run_check "$root" "$home" "$now")
  [ "$(status_part "$result")" = 0 ] || fail "sweeping evaluation failed: $(output_part "$result")"
  out=$(output_part "$result")
  assert_absent "$state/.startup-growth-check.aaaaaa" "an interrupted evaluation's empty temporary record was never swept"
  assert_present "$state/.startup-growth-check.bbbbbb" "the sweep removed an orphan that still held record bytes"
  assert_present "$state/.startup-growth-check.cccccc" "the sweep removed a concurrent evaluation's live temporary record"
  assert_contains "$out" 'tracked startup surface growth AGENTS.md +2500 bytes' "the sweep cost the evaluation its retained baselines"
  assert_grep $'last_eval\t'"$now" "$state/.startup-growth-check" "the sweeping evaluation did not publish its own record"
}

test_orphan_sweep_stays_inside_the_daily_cadence() {
  local rec root home state now result
  rec=$(make_world orphan-sweep-gated)
  root=${rec%%|*}
  home=${rec#*|}
  state="$home/state"
  now=$(date +%s)
  run_check "$root" "$home" "$now" >/dev/null
  : > "$state/.startup-growth-check.aaaaaa"
  touch -t 202001010000 "$state/.startup-growth-check.aaaaaa"
  result=$(run_check "$root" "$home" "$((now + 200))")
  [ "$(status_part "$result")" = 0 ] || fail "same-day poll failed: $(output_part "$result")"
  assert_present "$state/.startup-growth-check.aaaaaa" "a same-day poll did work instead of staying gated"
}

test_arm_and_disarm_use_authenticated_custom_check() {
  local rec root home out
  rec=$(make_world arm)
  root=${rec%%|*}
  home=${rec#*|}
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$CHECK" arm)
  assert_contains "$out" 'armed: state/startup-growth.check.sh' "arm did not announce the check shim"
  assert_present "$home/state/startup-growth.check.sh" "arm did not write the check shim"
  assert_present "$home/state/startup-growth.check-trust" "arm did not register trust for the check shim"

  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$root" FM_STARTUP_GROWTH_NOW=1000 "$home/state/startup-growth.check.sh" 2>&1) \
    || fail "registered check shim failed: $out"
  [ -z "$out" ] || fail "registered shim baseline run should stay silent: $out"
  assert_present "$home/state/.startup-growth-check" "registered shim did not run the daily check in the pinned home"
  assert_absent "$root/state/.startup-growth-check" "registered shim resolved the home from the environment instead of its pinned value"
  add_bytes "$root/AGENTS.md" 2500
  out=$(env -u FM_HOME FM_ROOT_OVERRIDE="$root" FM_STARTUP_GROWTH_NOW=87401 "$home/state/startup-growth.check.sh" 2>&1) \
    || fail "registered check shim failed on growth: $out"
  assert_contains "$out" 'startup-growth: tracked startup surface growth AGENTS.md +2500 bytes' "registered shim did not report growth to the watcher"

  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/startup-growth.check.sh" "disarm left the check shim"
  assert_absent "$home/state/startup-growth.check-trust" "disarm left the trust binding"
}

test_initial_baseline_is_silent_and_records_metadata
test_same_day_poll_does_not_touch_surfaces
test_due_growth_reports_once_and_dedupes
test_gradual_growth_below_daily_threshold_is_reported_cumulatively
test_printed_memory_growth_is_reported_without_entering_the_budget_total
test_first_content_of_an_optional_file_is_baselined_silently
test_established_baseline_survives_disappearance_and_restoration
test_secondmate_is_not_notified_about_primary_owned_shared_growth
test_budget_overrun_reports_and_separates_prompt_cost
test_secondmate_is_not_woken_about_the_primary_owned_shared_overrun
test_metadata_read_failure_keeps_the_retained_baseline
test_due_unsafe_inputs_are_reported_but_absent_optional_memory_is_not
test_findings_are_delivered_even_when_the_record_cannot_be_published
test_record_with_a_foreign_schema_marker_is_not_trusted
test_over_long_finding_set_is_capped_with_the_shared_marker
test_unknown_budget_verdict_fields_are_reported_as_unparseable
test_interrupted_evaluation_abandons_its_partial_record
test_aged_empty_orphan_records_are_swept_without_touching_live_work
test_orphan_sweep_stays_inside_the_daily_cadence
test_arm_and_disarm_use_authenticated_custom_check
test_rearming_an_unchanged_binding_does_not_replace_the_shim
test_failed_first_arm_leaves_the_home_plainly_unarmed
test_failed_rearm_keeps_the_previously_armed_shim_and_trust
pass "fm-startup-growth-check"
