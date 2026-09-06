#!/usr/bin/env bash
# fm-resgate-lib.sh / fm-resgate.sh - weekly clock-window resource governance,
# the manual override marker, and home-PC GPU exclusivity between Qwen and
# JARVIS voice.
#
# Covers: the captain's exact schedule windows and their boundaries (including
# the Friday-evening-through-Monday-morning free span on the work PC and the
# always-capped weekend on the home PC, both of which fall out of the same
# small per-weekday window rather than separate weekend-boundary code); the
# fail-closed clock, role, and GPU-probe paths; the override marker's atomic
# set/clear/status roundtrip and its precedence over the clock; and the GPU
# owner/availability decision, including the real CRLF line-ending bug found
# while live-testing this suite against the actual home host (Windows
# PowerShell terminates every line with CRLF; a naive `read -r` loop leaves
# the trailing CR on the last field and silently breaks every exact-match
# case pattern).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-resgate-lib.sh
. "$ROOT/bin/fm-resgate-lib.sh"

CLI="$ROOT/bin/fm-resgate.sh"

# --- role validation ---------------------------------------------------------

test_role_ok() {
  fm_resgate_role_ok work || fail "work must be a valid role"
  fm_resgate_role_ok home || fail "home must be a valid role"
  fm_resgate_role_ok both && fail "both must not be a valid single role"
  fm_resgate_role_ok '' && fail "empty must not be a valid role"
  pass "fm_resgate_role_ok accepts only work and home"
}

# --- clock parsing ------------------------------------------------------------

test_now_fields_from_override() {
  FM_RESGATE_NOW_OVERRIDE="3 14 05" fm_resgate_now_fields \
    || fail "a well-formed override must parse"
  # Re-run in this shell so the globals are visible to the assertion below.
  # shellcheck disable=SC2030,SC2031
  ( FM_RESGATE_NOW_OVERRIDE="3 14 05"; fm_resgate_now_fields
    [ "$FM_RESGATE_NOW_DOW" = 3 ] || exit 1
    [ "$FM_RESGATE_NOW_MOD" = "$((14 * 60 + 5))" ] || exit 1
  ) || fail "override dow/mod must parse to Wednesday 14:05"
  pass "fm_resgate_now_fields parses a well-formed override"
}

test_now_fields_rejects_malformed_override() {
  FM_RESGATE_NOW_OVERRIDE="not a clock reading" fm_resgate_now_fields \
    && fail "a malformed override must not parse"
  FM_RESGATE_NOW_OVERRIDE="8 14 05" fm_resgate_now_fields \
    && fail "a day-of-week of 8 must not parse"
  FM_RESGATE_NOW_OVERRIDE="3 24 05" fm_resgate_now_fields \
    && fail "an hour of 24 must not parse"
  FM_RESGATE_NOW_OVERRIDE="3 14 60" fm_resgate_now_fields \
    && fail "a minute of 60 must not parse"
  pass "fm_resgate_now_fields rejects malformed clock readings"
}

test_now_fields_handles_leading_zero_hours() {
  # 08 and 09 are invalid octal literals; a naive $((hh*60+mm)) would abort.
  # shellcheck disable=SC2030,SC2031
  ( FM_RESGATE_NOW_OVERRIDE="1 08 09"; fm_resgate_now_fields
    [ "$FM_RESGATE_NOW_MOD" = "$((8 * 60 + 9))" ]
  ) || fail "leading-zero hour/minute fields must not be read as octal"
  pass "fm_resgate_now_fields treats leading-zero HH/MM as decimal"
}

# --- schedule state: work PC --------------------------------------------------

test_work_capped_within_window() {
  FM_RESGATE_NOW_OVERRIDE="3 14 00" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
    || fail "work PC must be capped Wednesday 14:00 (inside 10:00-19:30)"
  pass "work PC is capped mid-window on a weekday"
}

test_work_capped_at_start_boundary() {
  FM_RESGATE_NOW_OVERRIDE="1 10 00" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
    || fail "work PC must be capped starting exactly at 10:00"
  FM_RESGATE_NOW_OVERRIDE="1 09 59" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
    || fail "work PC must still be uncapped at 09:59"
  pass "work PC's capped window starts exactly at 10:00, inclusive"
}

test_work_uncapped_at_end_boundary() {
  FM_RESGATE_NOW_OVERRIDE="1 19 30" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
    || fail "work PC must be uncapped again exactly at 19:30"
  FM_RESGATE_NOW_OVERRIDE="1 19 29" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
    || fail "work PC must still be capped at 19:29"
  pass "work PC's capped window ends exactly at 19:30, exclusive"
}

test_work_free_through_weekend_span() {
  local case
  for case in "5 19 30" "5 23 59" "6 00 00" "6 12 00" "7 23 59" "1 00 00" "1 09 59"; do
    FM_RESGATE_NOW_OVERRIDE="$case" fm_resgate_schedule_state work
    [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
      || fail "work PC must be uncapped throughout Fri 19:30 - Mon 10:00 (failed at '$case')"
  done
  pass "work PC stays uncapped continuously from Friday 19:30 through Monday 10:00"
}

# --- schedule state: home PC ---------------------------------------------------

test_home_free_within_window() {
  FM_RESGATE_NOW_OVERRIDE="3 10 00" fm_resgate_schedule_state home
  [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
    || fail "home PC must be free Wednesday 10:00 (inside 04:00-19:00)"
  pass "home PC is free mid-window on a weekday"
}

test_home_free_starts_at_boundary() {
  FM_RESGATE_NOW_OVERRIDE="1 04 00" fm_resgate_schedule_state home
  [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
    || fail "home PC must be free starting exactly at 04:00"
  FM_RESGATE_NOW_OVERRIDE="1 03 59" fm_resgate_schedule_state home
  [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
    || fail "home PC must still be capped at 03:59"
  pass "home PC's free window starts exactly at 04:00, inclusive"
}

test_home_free_ends_at_boundary() {
  FM_RESGATE_NOW_OVERRIDE="1 19 00" fm_resgate_schedule_state home
  [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
    || fail "home PC must be capped again exactly at 19:00"
  FM_RESGATE_NOW_OVERRIDE="1 18 59" fm_resgate_schedule_state home
  [ "$FM_RESGATE_SCHEDULE_STATE" = uncapped ] \
    || fail "home PC must still be free at 18:59"
  pass "home PC's free window ends exactly at 19:00, exclusive"
}

test_home_capped_all_weekend() {
  local case
  for case in "5 19 00" "5 23 59" "6 00 00" "6 12 00" "7 23 59" "1 00 00" "1 03 59"; do
    FM_RESGATE_NOW_OVERRIDE="$case" fm_resgate_schedule_state home
    [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] \
      || fail "home PC must be capped throughout Fri 19:00 - Mon 04:00 (failed at '$case')"
  done
  pass "home PC stays capped continuously across the whole weekend"
}

# --- fail-closed clock ---------------------------------------------------------

test_schedule_blocked_on_unreadable_clock() {
  FM_RESGATE_NOW_OVERRIDE="garbage" fm_resgate_schedule_state work
  [ "$FM_RESGATE_SCHEDULE_STATE" = blocked ] \
    || fail "an unreadable clock must yield 'blocked', not a guessed state"
  pass "schedule state fails closed to 'blocked' on an unreadable clock"
}

test_capacity_pct_zero_on_unreadable_clock() {
  local state
  state=$(fm_test_tmproot resgate-pct-blocked)
  FM_RESGATE_NOW_OVERRIDE="garbage" fm_resgate_capacity_pct "$state" work
  [ "$FM_RESGATE_PCT" = 0 ] \
    || fail "an unreadable clock must yield 0%, stricter than the ordinary 50% cap"
  pass "capacity_pct fails closed to 0% on an unreadable clock"
}

# --- fail-closed clock: the zone must actually have resolved ---------------------
#
# `date` exits 0 on a zone it cannot resolve and silently reports UTC, so these
# shadow `date` on PATH to hand fm_resgate_now_fields each reading a real host
# could produce and assert the resulting schedule verdict.

fake_date_at() { # <fakebin-dir> <dow> <HH> <MM> <zone-abbrev> <utc-offset>
  local fakebin=$1
  # Substitutes the requested specifiers rather than echoing a fixed line, so
  # the stub answers whatever format the library asks for - the reading it
  # returns is what varies here, never the shape of the call.
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
fmt=\${1#+}
fmt=\${fmt//%u/$2}
fmt=\${fmt//%H/$3}
fmt=\${fmt//%M/$4}
fmt=\${fmt//%Z/$5}
fmt=\${fmt//%z/$6}
printf '%s\n' "\$fmt"
SH
  chmod +x "$fakebin/date"
}

test_schedule_blocked_when_berlin_zone_did_not_resolve() {
  local tmp fakebin
  tmp=$(fm_test_tmproot resgate-tz-unresolved)
  fakebin=$(fm_fakebin "$tmp")
  # Real Berlin time is Monday 10:30 CEST - squarely inside the work PC's
  # capped window - but tzdata is missing, so the read comes back as UTC.
  # Trusting it would report "uncapped" and hand the fleet 100% of the
  # captain's work PC in the middle of his working hours.
  fake_date_at "$fakebin" 1 08 30 UTC +0000
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    unset FM_RESGATE_NOW_OVERRIDE
    fm_resgate_now_fields && exit 1
    fm_resgate_schedule_state work
    [ "$FM_RESGATE_SCHEDULE_STATE" = blocked ] || exit 1
    exit 0
  ) || fail "a UTC fallback from an unresolvable Europe/Berlin must fail closed to blocked, not read as Berlin time"
  pass "an unresolved Europe/Berlin zone fails closed to blocked instead of silently reading UTC"
}

test_schedule_blocked_when_zone_and_offset_disagree() {
  local tmp fakebin
  tmp=$(fm_test_tmproot resgate-tz-mismatch)
  fakebin=$(fm_fakebin "$tmp")
  fake_date_at "$fakebin" 1 10 30 CEST +0100
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    unset FM_RESGATE_NOW_OVERRIDE
    fm_resgate_schedule_state work
    [ "$FM_RESGATE_SCHEDULE_STATE" = blocked ] || exit 1
    exit 0
  ) || fail "an abbreviation and offset that do not belong together must fail closed"
  pass "a zone abbreviation contradicting its UTC offset fails closed to blocked"
}

test_schedule_reads_a_genuinely_resolved_berlin_clock() {
  local tmp fakebin
  tmp=$(fm_test_tmproot resgate-tz-resolved)
  fakebin=$(fm_fakebin "$tmp")
  # Both real Europe/Berlin pairs must still be accepted, or the zone check
  # would have turned the gate into a permanent 0%.
  fake_date_at "$fakebin" 1 10 30 CEST +0200
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    unset FM_RESGATE_NOW_OVERRIDE
    fm_resgate_schedule_state work
    [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] || exit 1
    exit 0
  ) || fail "summer time (CEST +0200) must be accepted and read as Monday 10:30, inside the capped window"
  fake_date_at "$fakebin" 1 10 30 CET +0100
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    unset FM_RESGATE_NOW_OVERRIDE
    fm_resgate_schedule_state work
    [ "$FM_RESGATE_SCHEDULE_STATE" = capped ] || exit 1
    exit 0
  ) || fail "standard time (CET +0100) must be accepted and read as Monday 10:30, inside the capped window"
  pass "both real Europe/Berlin zone pairs are accepted and drive the ordinary schedule verdict"
}

# --- manual override -----------------------------------------------------------

test_override_set_active_clear_roundtrip() {
  local state
  state=$(fm_test_tmproot resgate-override)
  fm_resgate_override_active "$state" work \
    && fail "override must start inactive"
  fm_resgate_override_set "$state" work note \
    || fail "override_set must succeed"
  fm_resgate_override_active "$state" work \
    || fail "override must read active immediately after being set"
  fm_resgate_override_active "$state" home \
    && fail "setting work's override must not arm home's"
  [ -f "$(fm_resgate_override_path "$state" work)" ] \
    || fail "the marker file itself must exist on disk"
  fm_resgate_override_clear "$state" work
  fm_resgate_override_active "$state" work \
    && fail "override must read inactive immediately after being cleared"
  pass "override marker set/active/clear roundtrips per role, atomically"
}

# shellcheck disable=SC2031
test_override_forces_capped_regardless_of_schedule() {
  local state
  state=$(fm_test_tmproot resgate-override-forces)
  fm_resgate_override_set "$state" work Kappung || fail "override_set must succeed"
  # Saturday noon would ordinarily be fully free on the work PC.
  FM_RESGATE_NOW_OVERRIDE="6 12 00" fm_resgate_capacity_pct "$state" work
  [ "$FM_RESGATE_PCT" = 50 ] \
    || fail "an armed override must force 50% even during an otherwise-free window"
  [ "$FM_RESGATE_STATE" = capped ] || fail "an armed override must report state=capped"
  pass "an armed override forces capped state independent of the clock window"
}

# shellcheck disable=SC2031
test_blocked_clock_beats_armed_override() {
  local state
  state=$(fm_test_tmproot resgate-override-vs-blocked)
  fm_resgate_override_set "$state" work Kappung || fail "override_set must succeed"
  FM_RESGATE_NOW_OVERRIDE="garbage" fm_resgate_capacity_pct "$state" work
  [ "$FM_RESGATE_PCT" = 0 ] \
    || fail "an armed override must not lift an unreadable clock's 0% to 50% (got $FM_RESGATE_PCT)"
  [ "$FM_RESGATE_STATE" = blocked ] \
    || fail "an unreadable clock must stay blocked even with the override armed (got $FM_RESGATE_STATE)"
  pass "an unreadable clock stays blocked at 0%: the override can only tighten the gate, never loosen it"
}

test_override_clear_reports_failure_when_the_marker_survives() {
  local state rc out
  [ "$(id -u)" -ne 0 ] || { echo "skip - running as root, an unwritable directory cannot be simulated"; return 0; }
  state=$(fm_test_tmproot resgate-clear-fails)
  fm_resgate_override_set "$state" work Kappung || fail "override_set must succeed"
  chmod 555 "$state" || fail "could not make the state directory unwritable"

  rc=0
  fm_resgate_override_clear "$state" work || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a clear that left the marker in place must not report success"
  fm_resgate_override_active "$state" work \
    || fail "the marker must still be armed - the precondition for this test"

  rc=0
  out=$(FM_STATE_OVERRIDE="$state" "$CLI" override clear work 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "the CLI must exit non-zero when the cap could not actually be released"
  case "$out" in
    *"could not clear override for work"*) ;;
    *) fail "the CLI must say the release failed, got: $out" ;;
  esac

  chmod 755 "$state"
  fm_resgate_override_clear "$state" work \
    || fail "a clear that really removes the marker must report success"
  fm_resgate_override_active "$state" work \
    && fail "the marker must be gone after a successful clear"
  pass "a failed override clear is reported, never mistaken for a lifted cap"
}

# --- percentage arithmetic ------------------------------------------------------

test_apply_pct_arithmetic() {
  [ "$(fm_resgate_apply_pct 10 100)" = 10 ] || fail "100% of 10 must be 10"
  [ "$(fm_resgate_apply_pct 10 50)" = 5 ] || fail "50% of 10 must be 5"
  [ "$(fm_resgate_apply_pct 3 50)" = 1 ] || fail "50% of 3 must floor to 1"
  [ "$(fm_resgate_apply_pct 10 0)" = 0 ] || fail "0% of anything must be 0"
  pass "fm_resgate_apply_pct halves (and floors) correctly"
}

test_apply_pct_fails_closed_on_bad_input() {
  [ "$(fm_resgate_apply_pct abc 50)" = 0 ] || fail "a non-numeric raw count must yield 0"
  [ "$(fm_resgate_apply_pct 10 150)" = 0 ] || fail "a percentage over 100 must yield 0, not overshoot"
  [ "$(fm_resgate_apply_pct '' 50)" = 0 ] || fail "an empty raw count must yield 0"
  pass "fm_resgate_apply_pct fails closed on non-numeric or out-of-range input"
}

# --- GPU exclusivity: mocked SSH -----------------------------------------------
#
# The fake `ssh` prints exactly the FM_RESGATE lines a real probe would, with
# real Windows CRLF line endings, so absorption is exercised the same way the
# live host exercises it.

fake_ssh_returning() { # <fakebin-dir> <literal-output-with-\r\n>
  local fakebin=$1 output=$2
  cat > "$fakebin/ssh" <<SH
#!/usr/bin/env bash
printf '%b' '$output'
SH
  chmod +x "$fakebin/ssh"
}

fake_ssh_unreachable() { # <fakebin-dir>
  cat > "$1/ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
  chmod +x "$1/ssh"
}

test_gpu_owner_qwen_when_process_and_memory_both_active() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-qwen)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner
    [ "$FM_RESGATE_GPU_OWNER" = qwen ]
  ) || fail "process running + memory above threshold must read owner=qwen"
  pass "GPU owner is qwen when both the named process and aggregate memory are active"
}

test_gpu_owner_none_when_process_running_but_memory_idle() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-idle-process)
  fakebin=$(fm_fakebin "$tmp")
  # A background service can be installed and running with no model loaded;
  # the process check alone must not be read as "Qwen is active".
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=512\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner
    [ "$FM_RESGATE_GPU_OWNER" = none ]
  ) || fail "an idle-but-running process below the memory threshold must read owner=none"
  pass "GPU owner is none when the process is running but aggregate memory stays below threshold"
}

test_gpu_owner_voice_when_port_listening() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-voice)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=listening\r\nFM_RESGATE gpu_process=not-running\r\nFM_RESGATE gpu_used_mb=1800\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner
    [ "$FM_RESGATE_GPU_OWNER" = voice ]
  ) || fail "a listening voice port must read owner=voice"
  pass "GPU owner is voice when the gateway port is listening"
}

test_gpu_owner_voice_wins_over_resident_qwen_signal() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-voice-wins)
  fakebin=$(fm_fakebin "$tmp")
  # The home PC's likely normal state: the voice worker holds the card (port
  # listening, its own VRAM on the meter) while the ollama service sits started
  # but idle. Aggregate memory cannot say whose memory it is, so crediting it to
  # Qwen here would refuse the voice worker the card it already holds - JARVIS
  # blocking itself. The port is authoritative and decides alone.
  out='FM_RESGATE voice_port=listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner || exit 1
    [ "$FM_RESGATE_GPU_OWNER" = voice ] || exit 1
    fm_resgate_gpu_available_for voice || exit 1
    fm_resgate_gpu_available_for qwen && exit 1
    exit 0
  ) || fail "a listening voice port must read owner=voice even with the Qwen process and card memory active, allowing voice and refusing qwen"
  pass "a listening voice port owns the GPU outright; a resident Qwen signal never blocks the voice worker"
}

test_gpu_available_for_blocks_the_other_side() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-exclusive)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_gpu_available_for qwen || exit 1
    fm_resgate_gpu_available_for voice && exit 1
    exit 0
  ) || fail "GPU reserved for Qwen must allow qwen and refuse voice"
  pass "gpu_available_for enforces exclusivity: the reserved side is allowed, the other refused"
}

test_gpu_owner_unknown_on_crlf_lines_still_parses_correctly() {
  # Regression for the exact bug found live-testing against the real host:
  # Windows CRLF line endings left a trailing \r on the last field of each
  # line, breaking every exact-match case pattern silently.
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-crlf)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=not-running\r\nFM_RESGATE gpu_used_mb=1200\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner
    [ "$FM_RESGATE_GPU_VOICE" = no ] || exit 1
    [ "$FM_RESGATE_GPU_PROCESS" = no ] || exit 1
    [ "$FM_RESGATE_GPU_USED_MB" = 1200 ] || exit 1
    [ "$FM_RESGATE_GPU_OWNER" = none ] || exit 1
  ) || fail "CRLF-terminated probe lines must still parse to their exact values, not fall through to unknown"
  pass "GPU probe parsing survives real Windows CRLF line endings"
}

test_gpu_owner_unknown_on_probe_failure_field() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-probefail)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=probe-failed\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    fm_resgate_gpu_available_for qwen && exit 1
    fm_resgate_gpu_available_for voice && exit 1
    exit 0
  ) || fail "a failed individual reading (nvidia-smi failure) must fail closed to unknown for BOTH workloads"
  pass "a single failed probe field fails the whole GPU reading closed, never a partial guess"
}

test_gpu_owner_unknown_on_voice_port_probe_failure() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-portfail)
  fakebin=$(fm_fakebin "$tmp")
  # The port measurement itself failed (missing NetTCPIP module, unhealthy CIM
  # service). That must never be indistinguishable from "not-listening": the
  # voice gateway may well be up, and reading it as free would let Qwen start
  # on the card beside it - the exact simultaneity this gate exists to prevent.
  out='FM_RESGATE voice_port=probe-failed\r\nFM_RESGATE gpu_process=not-running\r\nFM_RESGATE gpu_used_mb=1200\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    [ -z "$FM_RESGATE_GPU_VOICE" ] || exit 1
    fm_resgate_gpu_available_for qwen && exit 1
    fm_resgate_gpu_available_for voice && exit 1
    exit 0
  ) || fail "a failed voice-port reading must fail closed to unknown, never read as not-listening"
  pass "a failed voice-port reading fails the GPU decision closed for both workloads"
}

test_gpu_owner_unknown_on_process_probe_failure() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-procfail)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=probe-failed\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    exit 0
  ) || fail "a failed process reading must fail closed to unknown, never read as not-running"
  pass "a failed process reading fails the GPU decision closed"
}

test_gpu_owner_unknown_on_unusable_ssh_timeout() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-sshtimeout)
  fakebin=$(fm_fakebin "$tmp")
  # A healthy probe reachable through a fake ssh: only the timeout pin is bad.
  # bin/fm-timeout-lib.sh's header states a non-positive bound is not a bound -
  # it disables the deadline - so 0 and a negative pin (which the +5 arithmetic
  # turns into exactly 0) must refuse to probe rather than probe unbounded.
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    FM_RESGATE_SSH_TIMEOUT=-5 fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    FM_RESGATE_SSH_TIMEOUT=0 fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    FM_RESGATE_SSH_TIMEOUT=soon fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    fm_resgate_home_gpu_owner || exit 1
    [ "$FM_RESGATE_GPU_OWNER" = qwen ] || exit 1
    exit 0
  ) || fail "a zero, negative, or non-numeric SSH timeout must fail the GPU reading closed instead of probing with a disabled deadline"
  pass "an unusable FM_RESGATE_SSH_TIMEOUT fails the GPU reading closed to unknown"
}

test_gpu_owner_unknown_on_unusable_tunables() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-gpu-tunables)
  fakebin=$(fm_fakebin "$tmp")
  # Fully healthy probe output: only the mistyped session pin is wrong. A bad
  # threshold makes the -ge comparison error out (reading the card as free) and
  # a bad port probes something that is not the gateway; both must fail closed.
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    FM_RESGATE_GPU_BUSY_MB=lots fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    FM_RESGATE_VOICE_PORT=99999 fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    FM_RESGATE_VOICE_PORT=notaport fm_resgate_home_gpu_owner 2>/dev/null && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    fm_resgate_home_gpu_owner || exit 1
    [ "$FM_RESGATE_GPU_OWNER" = qwen ] || exit 1
    exit 0
  ) || fail "an unusable threshold or port must fail the GPU reading closed, not read the card as free"
  pass "an unusable GPU threshold or voice port fails the reading closed to unknown"
}

# --- GPU probe script: executed by its real consumer (PowerShell) --------------
#
# fm_resgate_home_gpu_probe_cmd emits a PowerShell program that runs on the home
# host; its error discrimination (which failures mean "nothing matched" and which
# mean "the measurement itself failed") is only meaningful when PowerShell itself
# evaluates it, so these run the generated program under pwsh with the failure
# modes stubbed in, rather than inspecting its text.

run_probe_under_pwsh() { # <prelude> -> probe stdout
  local prelude=$1 tmp script
  tmp=$(fm_test_tmproot resgate-probe-pwsh)
  script="$tmp/probe.ps1"
  {
    printf '%s\n' "$prelude"
    fm_resgate_home_gpu_probe_cmd 7414 definitely-no-such-proc-xyz
  } > "$script"
  pwsh -NoProfile -NonInteractive -File "$script" 2>/dev/null
}

test_probe_script_reports_port_probe_failure_distinctly() {
  local out
  command -v pwsh > /dev/null 2>&1 || { echo "skip - pwsh not installed"; return 0; }

  # No Get-NetTCPConnection at all: the NetTCPIP module is unavailable, the
  # real-world failure this must not report as a free port.
  out=$(run_probe_under_pwsh '')
  case "$out" in
    *voice_port=probe-failed*) ;;
    *) fail "a missing Get-NetTCPConnection must report probe-failed, got: $out" ;;
  esac

  # The CIM/WMI path itself errors while the gateway may well be listening.
  out=$(run_probe_under_pwsh \
    "function Get-NetTCPConnection { [CmdletBinding()] param([int]\$LocalPort,[string]\$State) throw 'CIM server unavailable' }")
  case "$out" in
    *voice_port=probe-failed*) ;;
    *) fail "a failing CIM query must report probe-failed, got: $out" ;;
  esac

  # Genuinely nothing bound to the port: the one error identity that really
  # does mean "no match" must still read as a negative, not a failure.
  out=$(run_probe_under_pwsh \
    "function Get-NetTCPConnection { [CmdletBinding()] param([int]\$LocalPort,[string]\$State) Write-Error -Message 'no match' -ErrorId 'CmdletizationQuery_NotFound_LocalPort' -Category ObjectNotFound }")
  case "$out" in
    *voice_port=not-listening*) ;;
    *) fail "a genuine no-match must still read as not-listening, got: $out" ;;
  esac

  out=$(run_probe_under_pwsh \
    "function Get-NetTCPConnection { [CmdletBinding()] param([int]\$LocalPort,[string]\$State) [pscustomobject]@{ LocalPort = \$LocalPort } }")
  case "$out" in
    *voice_port=listening*) ;;
    *) fail "a returned connection must read as listening, got: $out" ;;
  esac
  pass "the generated probe separates a failed port measurement from a genuinely free port"
}

test_probe_script_reports_process_reading_from_real_cmdlet() {
  local out
  command -v pwsh > /dev/null 2>&1 || { echo "skip - pwsh not installed"; return 0; }

  # Real Get-Process, real absent process: must be the negative reading, not a
  # failure - otherwise every ordinary idle host would read unknown forever.
  out=$(run_probe_under_pwsh '')
  case "$out" in
    *gpu_process=not-running*) ;;
    *) fail "a genuinely absent process must read not-running, got: $out" ;;
  esac

  out=$(run_probe_under_pwsh \
    "function Get-Process { [CmdletBinding()] param([string]\$Name) throw 'process enumeration failed' }")
  case "$out" in
    *gpu_process=probe-failed*) ;;
    *) fail "a failing process enumeration must report probe-failed, got: $out" ;;
  esac
  pass "the generated probe separates a failed process measurement from a genuinely absent process"
}

test_gpu_owner_unknown_when_ssh_unreachable() {
  local tmp fakebin
  tmp=$(fm_test_tmproot resgate-gpu-unreachable)
  fakebin=$(fm_fakebin "$tmp")
  fake_ssh_unreachable "$fakebin"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$fakebin:$PATH"
    . "$ROOT/bin/fm-resgate-lib.sh"
    fm_resgate_home_gpu_owner && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    exit 0
  ) || fail "an unreachable home host must fail closed to unknown, never permissive"
  pass "GPU owner fails closed to unknown when the home host is unreachable"
}

test_gpu_skip_remote_never_probes() {
  # shellcheck disable=SC2030,SC2031
  ( FM_RESGATE_SKIP_REMOTE=1
    fm_resgate_home_gpu_owner && exit 1
    [ "$FM_RESGATE_GPU_OWNER" = unknown ] || exit 1
    exit 0
  ) || fail "FM_RESGATE_SKIP_REMOTE=1 must fail closed without attempting a probe"
  pass "FM_RESGATE_SKIP_REMOTE=1 fails closed without probing"
}

# --- CLI (public interface) -----------------------------------------------------

test_cli_schedule_and_cap() {
  local out
  out=$(FM_RESGATE_NOW_OVERRIDE="3 14 00" "$CLI" schedule work) \
    || fail "CLI schedule must exit 0"
  case "$out" in *state=capped*) ;; *) fail "CLI schedule must print state=capped: $out" ;; esac
  out=$(FM_STATE_OVERRIDE="$(fm_test_tmproot resgate-cli-cap)" \
    FM_RESGATE_NOW_OVERRIDE="3 14 00" "$CLI" cap work) \
    || fail "CLI cap must exit 0"
  case "$out" in *pct=50*) ;; *) fail "CLI cap must print pct=50: $out" ;; esac
  pass "CLI schedule/cap commands print the expected verdict"
}

test_cli_override_both_arms_and_clears_two_files() {
  local state
  state=$(fm_test_tmproot resgate-cli-override-both)
  FM_STATE_OVERRIDE="$state" "$CLI" override set both > /dev/null \
    || fail "CLI override set both must exit 0"
  [ -e "$state/.resgate-cap-work" ] || fail "override set both must arm the work marker"
  [ -e "$state/.resgate-cap-home" ] || fail "override set both must arm the home marker"
  FM_STATE_OVERRIDE="$state" "$CLI" override clear both > /dev/null \
    || fail "CLI override clear both must exit 0"
  [ -e "$state/.resgate-cap-work" ] && fail "override clear both must remove the work marker"
  [ -e "$state/.resgate-cap-home" ] && fail "override clear both must remove the home marker"
  pass "CLI override set/clear both arms and releases the markers for both roles"
}

test_cli_override_both_reports_each_role_when_only_one_applies() {
  local state out rc=0
  state=$(fm_test_tmproot resgate-cli-override-partial)
  FM_STATE_OVERRIDE="$state" "$CLI" override set both > /dev/null \
    || fail "arming both roles is this test's precondition"
  # Stage a marker that cannot be released: `rm -f` refuses a directory, so
  # home's clear fails while work's succeeds - the half-applied `both` run
  # the captain has to be able to read off the output.
  rm -f "$state/.resgate-cap-home"
  mkdir "$state/.resgate-cap-home" || fail "could not stage an unremovable home marker"

  out=$(FM_STATE_OVERRIDE="$state" "$CLI" override clear both 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a half-applied clear must exit non-zero, got 0: $out"
  case "$out" in
    *work=clear*) ;;
    *) fail "the released host must be reported as clear, got: $out" ;;
  esac
  case "$out" in
    *home=armed*) ;;
    *) fail "the host that stayed capped must be reported as armed, got: $out" ;;
  esac
  fm_resgate_override_active "$state" work \
    && fail "work's marker must really be gone after the reported release"
  pass "a half-applied override both reports each host's real state, not only the failure"
}

test_cli_gpu_allow_exit_codes() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot resgate-cli-gpu)
  fakebin=$(fm_fakebin "$tmp")
  out='FM_RESGATE voice_port=not-listening\r\nFM_RESGATE gpu_process=running\r\nFM_RESGATE gpu_used_mb=9046\r\n'
  fake_ssh_returning "$fakebin" "$out"
  # shellcheck disable=SC2031
  PATH="$fakebin:$PATH" "$CLI" gpu allow qwen \
    || fail "CLI gpu allow qwen must exit 0 when Qwen holds the GPU"
  # shellcheck disable=SC2031
  PATH="$fakebin:$PATH" "$CLI" gpu allow voice \
    && fail "CLI gpu allow voice must exit non-zero when Qwen holds the GPU"
  pass "CLI gpu allow exit codes reflect the exclusivity decision"
}

test_role_ok
test_now_fields_from_override
test_now_fields_rejects_malformed_override
test_now_fields_handles_leading_zero_hours
test_work_capped_within_window
test_work_capped_at_start_boundary
test_work_uncapped_at_end_boundary
test_work_free_through_weekend_span
test_home_free_within_window
test_home_free_starts_at_boundary
test_home_free_ends_at_boundary
test_home_capped_all_weekend
test_schedule_blocked_on_unreadable_clock
test_capacity_pct_zero_on_unreadable_clock
test_schedule_blocked_when_berlin_zone_did_not_resolve
test_schedule_blocked_when_zone_and_offset_disagree
test_schedule_reads_a_genuinely_resolved_berlin_clock
test_override_set_active_clear_roundtrip
test_override_forces_capped_regardless_of_schedule
test_blocked_clock_beats_armed_override
test_override_clear_reports_failure_when_the_marker_survives
test_apply_pct_arithmetic
test_apply_pct_fails_closed_on_bad_input
test_gpu_owner_qwen_when_process_and_memory_both_active
test_gpu_owner_none_when_process_running_but_memory_idle
test_gpu_owner_voice_when_port_listening
test_gpu_owner_voice_wins_over_resident_qwen_signal
test_gpu_available_for_blocks_the_other_side
test_gpu_owner_unknown_on_crlf_lines_still_parses_correctly
test_gpu_owner_unknown_on_probe_failure_field
test_gpu_owner_unknown_on_voice_port_probe_failure
test_gpu_owner_unknown_on_process_probe_failure
test_gpu_owner_unknown_on_unusable_tunables
test_gpu_owner_unknown_on_unusable_ssh_timeout
test_probe_script_reports_port_probe_failure_distinctly
test_probe_script_reports_process_reading_from_real_cmdlet
test_gpu_owner_unknown_when_ssh_unreachable
test_gpu_skip_remote_never_probes
test_cli_schedule_and_cap
test_cli_override_both_arms_and_clears_two_files
test_cli_override_both_reports_each_role_when_only_one_applies
test_cli_gpu_allow_exit_codes
