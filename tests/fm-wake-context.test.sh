#!/usr/bin/env bash
# Behavioral contract for the bounded adapter-owned wake context.
set -u

# Keep real-backend fixtures fast while retaining the production hard timeout.
export FM_WAKE_CONTEXT_BACKEND_TIMEOUT=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-wake-context-r1.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

install_fixture() { # <home>
  local home=$1
  mkdir -p "$home/bin" "$home/state" "$home/data/alpha" "$home/worktree"
  cp "$ROOT/bin/fm-wake-context.sh" "$home/bin/fm-wake-context.sh"
  printf 'report body must stay out of the packet' > "$home/data/alpha/report.md"
  printf 'window=fleet:alpha\nbackend=tmux\nworktree=%s\nkind=ship\n' "$home/worktree" > "$home/state/alpha.meta"
  printf 'working: old\nneeds-decision [key=choice]: choose safely\nnote: latest\n' > "$home/state/alpha.status"
  install_stubs "$home"
}

install_stubs() { # <home>
  local bin=$1/bin
  printf '%s\n' 'fm_session_lock_owned_by_self() { return 0; }' > "$bin/fm-session-lock-lib.sh"
  cat > "$bin/fm-classify-lib.sh" <<'SH'
status_open_decisions() {
  printf 'choice\tneeds-decision\tchoose safely\n'
}
SH
  cat > "$bin/fm-backend.sh" <<'SH'
fm_backend_is_known() { return 0; }
fm_backend_agent_state() { printf 'alive\n'; }
fm_run_timed() { printf '%s\n' "$1" >> "$FM_HOME/backend-timeout"; shift; "$@"; }
SH
cat > "$bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_HOME/drain.calls" ] || exit 9
printf '%s\n' "$1" >> "$FM_HOME/crew-state.calls"
if [ -n "${FM_CREW_STATE_HANG:-}" ] && [ -e "$FM_CREW_STATE_HANG" ]; then
  printf '%s\n' "$$" > "$FM_CREW_STATE_HANG.entered"
  while [ -e "$FM_CREW_STATE_HANG" ]; do sleep 0.05; done
fi
if [ -n "${FM_CREW_STATE_LARGE:-}" ]; then head -c 70000 /dev/zero | tr '\0' x; exit 0; fi
printf 'state: working · source: pane · implementing\n'
SH
cat > "$bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'drained\n' >> "$FM_HOME/drain.calls"
if [ "${FM_DRAIN_MANY_STATUS:-0}" = 1 ]; then
  printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n'
  for n in $(seq 1 10); do printf 'alpha note: status-%s\n' "$n"; done
fi
[ "${FM_DRAIN_APPEND_WAKE:-0}" != 1 ] || printf '1\t17\tsignal\talpha.status\tlate wake\n' >> "$FM_STATE_OVERRIDE/.wake-queue"
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation fixture-1\n' "${FM_DRAIN_ACK_THROUGH:-1}" >&2
SH
  chmod +x "$bin"/*.sh
}

append_wake() { # <home> <sequence>
  printf '1\t%s\tsignal\talpha.status\tsignal: alpha.status\n' "$2" >> "$1/state/.wake-queue"
}

run_measured_context() { # <home> <log> <stdout> <stderr>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" \
    "$1/bin/fm-wake-context.sh" --present > "$3" 2> "$4" || return 1
  printf 'invocation\n' >> "$2"
}

packet_json() { # <output>
  sed -n '2p' "$1"
}

assert_packet_content() { # <packet>
  printf '%s\n' "$1" | jq -e '
    .schema == "fm-wake-context.v1"
    and .reason_queue[0].key == "alpha.status"
    and (.tasks[0].current_state.summary | startswith("state: working"))
    and .tasks[0].endpoint.liveness == "alive"
    and .bounds.max_packet_bytes == 65536
    and .ambiguity.status_recent_is_bounded_tail == true
    and .replay.recovery_generation == "fixture-1"
    and .tasks[0].status_recent[-1] == "note: latest"
    and .tasks[0].report.present == true
    and (.tasks[0].report | has("content") | not)
    and .open_decisions[0].key == "choice"
    and (.ack.after_handling | endswith("--recovery-generation fixture-1"))
  ' >/dev/null || fail "packet lost bounded context or acknowledgement"
}

test_packet_is_bounded_and_complete() {
  local home="$TMP_ROOT/complete" packet bytes invocations
  install_fixture "$home"
  append_wake "$home" 1
  run_measured_context "$home" "$home/after.calls" "$home/out" "$home/err" || fail "packet presentation failed"
  packet=$(packet_json "$home/out")
  assert_packet_content "$packet"
  [ "$(wc -l < "$home/crew-state.calls" | tr -d ' ')" -eq 1 ] || fail "current state was reconstructed more than once"
  invocations=$(wc -l < "$home/after.calls" | tr -d ' ')
  bytes=$(printf '%s' "$packet" | wc -c | tr -d ' ')
  [ "$bytes" -le 65536 ] || fail "packet exceeded its absolute byte bound"
  printf 'measure - wake_context_executable_invocations=%s packet_bytes=%s\n' "$invocations" "$bytes"
  pass "wake context is one bounded complete adapter presentation"
}

test_utf8_packet_uses_true_byte_bound() {
  local home="$TMP_ROOT/utf8-bound" payload
  install_fixture "$home"
  payload=$(head -c 34000 /dev/zero | tr '\0' x | sed 's/x/é/g')
  printf '1\t1\tsignal\talpha.status\t%s\n' "$payload" > "$home/state/.wake-queue"
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err"; then
    fail "a multibyte packet larger than the byte bound was accepted"
  fi
  grep -F 'WAKE_CONTEXT_FALLBACK:' "$home/out" >/dev/null || fail "UTF-8 overflow lost the safe fallback"
  pass "packet byte bound counts UTF-8 bytes rather than characters"
}

install_real_drain_fixture() { # <home>
  local home=$1; mkdir -p "$home/bin" "$home/state" "$home/data/alpha" "$home/data/beta" "$home/config"
  cp -R "$ROOT/bin/." "$home/bin/"
  printf '%s\n' 'fm_session_lock_owned_by_self() { return 0; }' > "$home/bin/fm-session-lock-lib.sh"
  cat > "$home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_CREW_STATE_HANG:-}" ] && [ -e "$FM_CREW_STATE_HANG" ]; then
  printf '%s\n' "$$" > "$FM_CREW_STATE_HANG.entered"
  while [ -e "$FM_CREW_STATE_HANG" ]; do sleep 0.05; done
fi
if [ -n "${FM_CREW_STATE_LARGE:-}" ]; then head -c 70000 /dev/zero | tr '\0' x; exit 0; fi
printf 'state: working · source: fixture · %s\n' "$1"
SH
  cat > "$home/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = diverged ] || exit 0
printf 'beta-call\tbeta\tbeta-call\tChoose beta safely\n'
SH
  chmod +x "$home/bin/fm-crew-state.sh" "$home/bin/fm-captain-hold.sh"
}

prepare_real_wake() { # <home>
  install_real_drain_fixture "$1"
  printf 'window=fleet:alpha\nbackend=tmux\n' > "$1/state/alpha.meta"
  printf 'note: alpha bootstrap\n' > "$1/state/alpha.status"
  printf 'note: beta bootstrap\n' > "$1/state/beta.status"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" "$1/bin/fm-wake-drain.sh" >/dev/null 2>/dev/null
  cp "$1/state/.status-presentation-cursor" "$1/cursor.before"
  printf 'note: beta during alpha wake\nresolved [key=beta-call]: beta decided\n' >> "$1/state/beta.status"
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; fm_wake_append signal alpha.status "signal: alpha.status"' _ "$1/bin/fm-wake-lib.sh"
}

ack_real_packet() { # <home> <packet>
  local ack generation
  ack=$(printf '%s' "$2" | jq -r '.replay.ack_through')
  generation=$(printf '%s' "$2" | jq -r '.replay.recovery_generation')
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" \
    "$1/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation"
}

assert_real_packet_and_ack() { # <home> <packet>
  printf '%s' "$2" | jq -er '.presentation.stdout' | grep -F 'beta note: beta during alpha wake' >/dev/null \
    || fail "packet lost fleet-wide unread beta note"
  printf '%s' "$2" | jq -er '.presentation.stdout' | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "packet lost record divergence"
  cmp -s "$1/cursor.before" "$1/state/.status-presentation-cursor" || fail "status cursor advanced before packet ACK"
  ack_real_packet "$1" "$2" >/dev/null 2>/dev/null || fail "packet acknowledgement failed"
  cmp -s "$1/cursor.before" "$1/state/.status-presentation-cursor" && fail "status cursor did not advance at packet ACK"
  [ ! -e "$1/state/.wake-context-cache" ] || fail "packet cache survived its acknowledgement"
}

test_real_drain_presentation_replays_identically_before_ack() {
  local home="$TMP_ROOT/real-drain" packet
  prepare_real_wake "$home"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/first" 2> "$home/first.err" || fail "real drain packet failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/replay" 2> "$home/replay.err" || fail "real drain replay failed"
  cmp -s "$home/first" "$home/replay" || fail "pre-ACK replay changed the presented packet"
  packet=$(packet_json "$home/first")
  assert_real_packet_and_ack "$home" "$packet"
  pass "real drain presentation and replay preserve unread status and divergence"
}

test_sigkill_before_cache_publish_keeps_unread_note() {
  local home="$TMP_ROOT/sigkill-before-publish" pid i=0 packet
  install_fixture "$home"; append_wake "$home" 1; mkdir "$home/tmp"; : > "$home/hang"
  TMPDIR="$home/tmp" FM_CREW_STATE_HANG="$home/hang" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/killed.out" 2> "$home/killed.err" & pid=$!
  while [ ! -e "$home/hang.entered" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/hang.entered" ] || fail "crew-state never reached the crash window"
  kill -KILL "$pid" 2>/dev/null || fail "could not SIGKILL wake-context in the crash window"
  wait "$pid" 2>/dev/null || true; rm -f "$home/hang"; sleep 0.1
  [ ! -e "$home/state/.wake-context-cache" ] || fail "SIGKILL published a cache before completing the packet"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/retry" 2> "$home/retry.err" || fail "retry after SIGKILL failed"
  packet=$(packet_json "$home/retry")
  printf '%s' "$packet" | jq -e '.reason_queue[0].key == "alpha.status"' >/dev/null || fail "retry after SIGKILL lost the durable wake"
  pass "SIGKILL before cache publication leaves the durable wake replayable"
}

test_mktemp_failure_emits_safe_fallback() {
  local home="$TMP_ROOT/mktemp-failure"
  install_fixture "$home"; append_wake "$home" 1
  mkdir "$home/not-a-temp-dir"; chmod 0500 "$home/not-a-temp-dir"
  if TMPDIR="$home/not-a-temp-dir/missing" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err"; then
    fail "mktemp failure unexpectedly succeeded"
  fi
  grep -F 'WAKE_CONTEXT_FALLBACK:' "$home/out" >/dev/null || fail "mktemp failure emitted no canonical fallback"
  pass "pre-presentation mktemp failure emits the canonical safe fallback"
}

test_cardinality_overflow_falls_back_before_drain() {
  local home="$TMP_ROOT/overflow" i=1
  install_fixture "$home"
  while [ "$i" -le 17 ]; do append_wake "$home" "$i"; i=$((i + 1)); done
  if FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err"; then
    fail "an oversized queue produced a partial packet"
  fi
  grep -F 'run bin/fm-wake-drain.sh' "$home/out" >/dev/null || fail "overflow did not name the safe fallback"
  [ ! -e "$home/drain.calls" ] || fail "overflow mutated presentation state before fallback"
  pass "wake context overflow falls back before durable presentation"
}

test_stale_window_maps_to_affected_task() {
  local home="$TMP_ROOT/stale" packet
  install_fixture "$home"
  printf '1\t1\tstale\tfleet:alpha\tstale: fleet:alpha\n' > "$home/state/.wake-queue"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "stale packet failed"
  packet=$(packet_json "$home/out")
  printf '%s\n' "$packet" | jq -e '.tasks[0].id == "alpha"' >/dev/null || fail "stale endpoint did not map to its task"
  pass "stale endpoint wake includes the affected task"
}

test_packet_projects_unread_status_tail() {
  local home="$TMP_ROOT/status-tail" packet
  install_fixture "$home"; append_wake "$home" 1
  FM_DRAIN_MANY_STATUS=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "status projection failed"
  packet=$(packet_json "$home/out")
  printf '%s' "$packet" | jq -er '.presentation.stdout' | grep -F 'UNREAD STATUS: 2 older line(s) omitted' >/dev/null \
    || fail "packet did not report omitted unread status lines"
  printf '%s' "$packet" | jq -er '.presentation.stdout' | grep -Fx 'alpha note: status-1' >/dev/null && fail "packet retained old unread status lines"
  printf '%s' "$packet" | jq -er '.presentation.stdout' | grep -F 'status-10' >/dev/null || fail "packet lost recent unread status"
  pass "wake packet bounds unread-status projection with an omission count"
}

test_absolute_check_key_maps_to_task() {
  local home="$TMP_ROOT/absolute-check" packet
  install_fixture "$home"
  printf '1\t1\tcheck\t%s/alpha.check.sh\tcheck: alpha\n' "$home/state" > "$home/state/.wake-queue"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "absolute check packet failed"
  packet=$(packet_json "$home/out")
  printf '%s' "$packet" | jq -e '.tasks[0].id == "alpha"' >/dev/null || fail "absolute check key did not map to alpha"
  pass "absolute check keys include their task context"
}

test_status_only_recovery_uses_zero_ack() {
  local home="$TMP_ROOT/status-only" packet
  install_fixture "$home"
  FM_DRAIN_ACK_THROUGH=0 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "status-only recovery packet failed"
  packet=$(packet_json "$home/out")
  printf '%s' "$packet" | jq -e '.replay.ack_through == 0' >/dev/null || fail "status-only recovery serialized a null ACK"
  FM_DRAIN_ACK_THROUGH=0 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/replay" 2> "$home/replay.err" || fail "status-only recovery did not replay"
  cmp -s "$home/out" "$home/replay" || fail "status-only recovery replay changed before ACK"
  pass "status-only recovery preserves its zero acknowledgement"
}

test_post_drain_overflow_falls_back() {
  local home="$TMP_ROOT/post-drain-overflow" i=1
  install_fixture "$home"
  while [ "$i" -le 16 ]; do append_wake "$home" "$i"; i=$((i + 1)); done
  if FM_DRAIN_APPEND_WAKE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err"; then
    fail "post-drain overflow produced a packet"
  fi
  grep -F 'more than 16 queued notifications' "$home/out" >/dev/null || fail "post-drain overflow did not fail closed"
  pass "post-drain queue snapshot still enforces wake cardinality"
}

test_backend_timeout_normalizes_to_a_positive_decimal() {
  local value home expected
  for value in 0 00 000 7; do
    home="$TMP_ROOT/backend-timeout-$value"; expected=3
    [ "$value" = 7 ] && expected=7
    install_fixture "$home"; append_wake "$home" 1
    FM_WAKE_CONTEXT_BACKEND_TIMEOUT="$value" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
      "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "timeout fixture $value failed"
    [ "$(cat "$home/backend-timeout")" = "$expected" ] || fail "timeout $value did not normalize to $expected"
  done
  pass "backend liveness timeout stays strictly positive after normalization"
}

test_cursor_merge_follows_live_rotation_without_regression() {
  local home="$TMP_ROOT/cursor-rotation" ident
  mkdir -p "$home/state"; printf 'note: rotated\n' > "$home/state/alpha.status"
  ident=$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$home/state/alpha.status")
  printf 'alpha\told-ident\t100\n' > "$home/state/.status-presentation-cursor"
  printf 'alpha\t%s\t20\n' "$ident" > "$home/state/.wake-context-cache.status-cursor"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; . "$2"; status_merge_presentation_cursor "$3" "$4"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$home/state" "$home/state/.wake-context-cache.status-cursor" \
    || fail "cursor merge failed"
  grep -Fx "alpha	$ident	20" "$home/state/.status-presentation-cursor" >/dev/null || fail "live rotation kept the obsolete cursor identity"
  printf 'alpha\told-ident\t999\n' > "$home/state/.wake-context-cache.status-cursor"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; . "$2"; status_merge_presentation_cursor "$3" "$4"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-classify-lib.sh" "$home/state" "$home/state/.wake-context-cache.status-cursor" \
    || fail "stale cursor merge failed"
  grep -Fx "alpha	$ident	20" "$home/state/.status-presentation-cursor" >/dev/null || fail "stale cursor regressed the live identity"
  pass "cursor merge follows a live rotation without replaying stale state"
}

test_post_presentation_failure_preserves_human_ack() {
  local home="$TMP_ROOT/post-fallback"
  install_fixture "$home"
  append_wake "$home" 1
  if FM_CREW_STATE_LARGE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err"; then
    fail "an oversized status set produced a packet"
  fi
  grep -F 'Handle the durable human presentation below' "$home/out" >/dev/null || fail "post-presentation fallback was ambiguous"
  grep -F -- '--ack-through 1 --recovery-generation fixture-1' "$home/err" >/dev/null || fail "post-presentation fallback lost its acknowledgement"
  [ -e "$home/drain.calls" ] || fail "post-presentation fallback did not preserve the first presentation"
  pass "post-presentation failure preserves the human acknowledgement without re-drain"
}

test_utf8_fallback_ack_commits_unread_cursor() {
  local home="$TMP_ROOT/utf8-fallback-ack" payload ack generation; prepare_real_wake "$home"
  payload=$(head -c 1000 /dev/zero | tr '\0' x | sed 's/x/é/g')
  printf 'note: utf8-fallback-%s\n' "$payload" >> "$home/state/beta.status"
  FM_CREW_STATE_LARGE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || true
  grep -F 'utf8-fallback-' "$home/out" >/dev/null || fail "UTF-8 fallback hid its durable note"
  [ ! -e "$home/state/.wake-context-cache" ] || fail "UTF-8 fallback published a packet cache"
  [ -e "$home/state/.wake-context-fallback-receipt" ] || fail "UTF-8 fallback lost its ACK receipt"
  [ -e "$home/state/.wake-context-cache.status-cursor" ] || fail "UTF-8 fallback lost its staged cursor"
  ack=$(jq -r '.replay.ack_through' "$home/state/.wake-context-fallback-receipt")
  generation=$(jq -r '.replay.recovery_generation' "$home/state/.wake-context-fallback-receipt")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || fail "UTF-8 fallback ACK failed"
  [ ! -e "$home/state/.wake-context-fallback-receipt" ] || fail "UTF-8 fallback receipt survived its ACK"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/replay" 2>/dev/null
  grep -F 'utf8-fallback-' "$home/replay" >/dev/null && fail "ACKed UTF-8 fallback replayed its handled note"
  pass "UTF-8 fallback acknowledgement commits its unread cursor exactly once"
}

test_manual_drain_supersedes_truncated_fallback_receipt() {
  local home="$TMP_ROOT/manual-supersede" payload ack generation
  prepare_real_wake "$home"; payload=$(head -c 60000 /dev/zero | tr '\0' x)
  printf '%s' "$payload" > "$home/state/alpha.status"; printf '%s' "$payload" > "$home/state/beta.status"
  printf '%s' "$payload" > "$home/state/gamma.status"; printf '\nnote: after-truncated\n' >> "$home/state/beta.status"
  jq -cn '{replay:{ack_through:1,recovery_generation:"old"}}' > "$home/state/.wake-context-fallback-receipt"
  cp "$home/cursor.before" "$home/state/.wake-context-cache.status-cursor"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/pi" 2>/dev/null || true
  grep -Fx 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: status bytes exceed the packet bound; run bin/fm-wake-drain.sh once.' "$home/pi" >/dev/null || fail "Pi preflight did not return a complete bounded action"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" > "$home/manual" 2> "$home/manual.err"
  grep -F 'after-truncated' "$home/manual" >/dev/null || fail "manual drain lost the post-truncation note"
  [ ! -e "$home/state/.wake-context-fallback-receipt" ] && [ ! -e "$home/state/.wake-context-cache.status-cursor" ] || fail "manual drain retained stale fallback state"
  ack=$(sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' "$home/manual.err"); generation=$(sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' "$home/manual.err")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || fail "manual fallback ACK failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" > "$home/replay" 2>/dev/null
  grep -F 'after-truncated' "$home/replay" >/dev/null && fail "manual fallback replayed its handled note"
  pass "manual drain supersedes stale fallback state before presenting large status"
}

test_resolved_is_not_primary_actionable() {
  bash -c '. "$1"; ! status_is_captain_relevant "resolved [key=choice]: answered"' \
    _ "$ROOT/bin/fm-classify-lib.sh" || fail "resolved status still wakes the primary classifier"
  pass "resolved status is already non-actionable on the primary"
}

test_packet_is_bounded_and_complete
test_utf8_packet_uses_true_byte_bound
test_real_drain_presentation_replays_identically_before_ack
test_sigkill_before_cache_publish_keeps_unread_note
test_mktemp_failure_emits_safe_fallback
test_cardinality_overflow_falls_back_before_drain
test_stale_window_maps_to_affected_task
test_packet_projects_unread_status_tail
test_absolute_check_key_maps_to_task
test_status_only_recovery_uses_zero_ack
test_post_drain_overflow_falls_back
test_backend_timeout_normalizes_to_a_positive_decimal
test_cursor_merge_follows_live_rotation_without_regression
test_post_presentation_failure_preserves_human_ack
test_utf8_fallback_ack_commits_unread_cursor
test_manual_drain_supersedes_truncated_fallback_receipt
test_resolved_is_not_primary_actionable
