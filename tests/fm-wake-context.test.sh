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

process_tree_has_sleep() { # <root-pid>
  local child command
  for child in $(pgrep -P "$1" 2>/dev/null); do
    command=$(ps -o comm= -p "$child")
    case "$command" in */sleep|sleep) return 0 ;; esac
    process_tree_has_sleep "$child" && return 0
  done
  return 1
}

install_fixture() { # <home>
  local home=$1
  mkdir -p "$home/bin" "$home/state" "$home/config" "$home/data/alpha" "$home/worktree"
  : > "$home/config/wake-context-presentation"
  cp "$ROOT/bin/fm-wake-context.sh" "$home/bin/fm-wake-context.sh"
  printf 'report body must stay out of the packet' > "$home/data/alpha/report.md"
  printf 'window=fleet:alpha\nbackend=tmux\nworktree=%s\nkind=ship\n' "$home/worktree" > "$home/state/alpha.meta"
  printf 'working: old\nneeds-decision [key=choice]: choose safely\nnote: latest\n' > "$home/state/alpha.status"
  install_stubs "$home"
}

write_classify_stub() { # <bin>
  cat > "$1/fm-classify-lib.sh" <<'SH'
status_open_decisions() {
  printf 'choice\tneeds-decision\tchoose safely\n'
}
SH
}

write_backend_stub() { # <bin>
  cat > "$1/fm-backend.sh" <<'SH'
fm_backend_is_known() { return 0; }
fm_backend_agent_state() { printf 'alive\n'; }
fm_run_timed() { printf '%s\n' "$1" >> "$FM_HOME/backend-timeout"; shift; "$@"; }
SH
}

write_crew_state_stub() { # <bin>
  cat > "$1/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_HOME/drain.calls" ] || exit 9
printf '%s\n' "$1" >> "$FM_HOME/crew-state.calls"
if [ -n "${FM_CREW_STATE_HANG:-}" ] && [ -e "$FM_CREW_STATE_HANG" ]; then
  printf '%s\n' "$$" > "$FM_CREW_STATE_HANG.entered"
  while [ -e "$FM_CREW_STATE_HANG" ]; do sleep 0.05; done
fi
case "$1" in
  alpha) sleep "${FM_CREW_STATE_ALPHA_SECONDS:-0}" ;;
  beta) sleep "${FM_CREW_STATE_BETA_SECONDS:-0}" ;;
esac
if [ -n "${FM_CREW_STATE_LARGE:-}" ]; then head -c 70000 /dev/zero | tr '\0' x; exit 0; fi
printf 'state: working · source: pane · implementing\n'
SH
}

write_drain_stub() { # <bin>
  cat > "$1/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'drained\n' >> "$FM_HOME/drain.calls"
sleep "${FM_DRAIN_SECONDS:-0}"
if [ "${FM_DRAIN_MANY_STATUS:-0}" = 1 ]; then
  printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n'
  for n in $(seq 1 10); do printf 'alpha note: status-%s\n' "$n"; done
fi
[ "${FM_DRAIN_APPEND_WAKE:-0}" != 1 ] || printf '1\t17\tsignal\talpha.status\tlate wake\n' >> "$FM_STATE_OVERRIDE/.wake-queue"
if [ "${FM_WAKE_CONTEXT_NONMUTATING:-0}" = 1 ]; then
  : > "$FM_WAKE_CONTEXT_STATUS_CURSOR_STAGE" || exit 1
fi
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation fixture-1\n' "${FM_DRAIN_ACK_THROUGH:-1}" >&2
SH
}

install_stubs() { # <home>
  local bin=$1/bin
  printf '%s\n' 'fm_session_lock_owned_by_self() { return 0; }' > "$bin/fm-session-lock-lib.sh"
  write_classify_stub "$bin"; write_backend_stub "$bin"
  write_crew_state_stub "$bin"; write_drain_stub "$bin"
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

test_missing_opt_in_falls_back_without_mutation() {
  local home="$TMP_ROOT/default-off" status=0
  install_fixture "$home"; rm "$home/config/wake-context-presentation"; append_wake "$home" 1
  cp "$home/state/.wake-queue" "$home/queue.before"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  [ "$status" -eq 3 ] || fail "default-off wake context did not return the fallback status"
  grep -Fx 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: automatic wake context is disabled until config/wake-context-presentation exists; run bin/fm-wake-drain.sh once.' "$home/out" >/dev/null \
    || fail "default-off wake context lost its single manual-drain action"
  cmp -s "$home/queue.before" "$home/state/.wake-queue" || fail "default-off wake context mutated the durable queue"
  [ ! -e "$home/drain.calls" ] || fail "default-off wake context ran the drain"
  [ ! -e "$home/state/.wake-context-cache" ] && [ ! -e "$home/state/.wake-context-cache.status-cursor" ] \
    && [ ! -e "$home/state/.wake-context-fallback-receipt" ] || fail "default-off wake context published durable presentation state"
  ! grep -F 'WAKE_ACK_REQUIRED' "$home/err" >/dev/null || fail "default-off wake context published an ACK"
  pass "wake context is default-off and leaves durable wake state untouched"
}

test_config_override_owns_opt_in_resolution() {
  local home="$TMP_ROOT/config-override" config="$TMP_ROOT/config-override-choice" status=0
  install_fixture "$home"; append_wake "$home" 1; mkdir -p "$config"
  FM_CONFIG_OVERRIDE="$config" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/off" 2> "$home/off.err" || status=$?
  [ "$status" -eq 3 ] || fail "empty FM_CONFIG_OVERRIDE did not keep wake context disabled"
  [ ! -e "$home/drain.calls" ] || fail "empty FM_CONFIG_OVERRIDE fell back to the home opt-in"
  : > "$config/wake-context-presentation"
  FM_CONFIG_OVERRIDE="$config" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/on" 2> "$home/on.err" || fail "FM_CONFIG_OVERRIDE opt-in did not enable presentation"
  packet_json "$home/on" | jq -e '.schema == "fm-wake-context.v1"' >/dev/null \
    || fail "FM_CONFIG_OVERRIDE enabled an invalid wake-context presentation"
  pass "FM_CONFIG_OVERRIDE exclusively owns wake-context opt-in resolution when set"
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
  : > "$home/config/wake-context-presentation"
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
  rm "$home/config/wake-context-presentation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/replay" 2> "$home/replay.err" || fail "real drain replay failed"
  cmp -s "$home/first" "$home/replay" || fail "pre-ACK replay changed the presented packet"
  packet=$(packet_json "$home/first")
  assert_real_packet_and_ack "$home" "$packet"
  pass "published wake context replays identically after opt-out until acknowledgement"
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

test_status_cursor_is_staged_before_ack() {
  local home="$TMP_ROOT/cursor-before-ack" pid i=0 ack generation
  prepare_real_wake "$home"
  FM_WAKE_ENRICH_TEST_DELAY=2 FM_WAKE_CONTEXT_NONMUTATING=1 \
    FM_WAKE_CONTEXT_STATUS_CURSOR_STAGE="$home/state/.wake-context-cache.status-cursor" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/out" 2> "$home/err" & pid=$!
  while ! grep -F 'WAKE_ACK_REQUIRED' "$home/err" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/state/.wake-context-cache.status-cursor" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "ACK became available before its status cursor stage"; }
  wait "$pid" || fail "nonmutating drain failed while staging its cursor"
  ack=$(sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' "$home/err")
  generation=$(sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' "$home/err")
  jq -cn --argjson ack "$ack" --arg generation "$generation" '{replay:{ack_through:$ack,recovery_generation:$generation}}' > "$home/state/.wake-context-fallback-receipt"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || fail "staged fallback ACK failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" > "$home/replay" 2>/dev/null
  grep -F 'beta during alpha wake' "$home/replay" >/dev/null && fail "ACK replayed status staged before its publication"
  pass "status cursor is staged before ACK publication and commits without replay"
}

test_unstageable_status_cursor_withholds_ack() {
  local home="$TMP_ROOT/unstageable-cursor" pid i=0 status=0
  prepare_real_wake "$home"
  FM_WAKE_ENRICH_TEST_DELAY=2 FM_WAKE_CONTEXT_NONMUTATING=1 \
    FM_WAKE_CONTEXT_STATUS_CURSOR_STAGE="$home/state/.wake-context-cache.status-cursor" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/out" 2> "$home/err" & pid=$!
  while ! process_tree_has_sleep "$pid" && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ "$i" -lt 100 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "nonmutating drain never reached cursor staging window"; }
  printf 'note: beta replaced during presentation\n' > "$home/state/beta.status.next"
  mv "$home/state/beta.status.next" "$home/state/beta.status"
  wait "$pid" || status=$?
  [ "$status" -ne 0 ] || fail "unstageable status presentation unexpectedly succeeded"
  grep -F 'WAKE_ACK_REQUIRED' "$home/err" >/dev/null && fail "unstageable status presentation published an ACK"
  [ ! -e "$home/state/.wake-context-cache.status-cursor" ] || fail "unstageable status presentation left a cursor stage"
  pass "nonmutating drain withholds ACK when status presentation cannot be staged"
}

test_empty_queue_unstageable_status_cursor_withholds_ack() {
  local home="$TMP_ROOT/empty-queue-unstageable-cursor" pid i=0
  install_real_drain_fixture "$home"; printf 'window=fleet:alpha\nbackend=tmux\n' > "$home/state/alpha.meta"
  printf 'note: alpha unread\n' > "$home/state/alpha.status"
  : > "$home/state/.wake-queue"; printf 'pending:handling:fixture\n' > "$home/state/.watcher-down"
  # shellcheck disable=SC2016 # The generated fixture expands these variables at runtime.
  printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" = diverged ] || exit 0' ': > "$FM_HOME/divergence.entered"' \
    'while [ -e "$FM_HOME/divergence.hang" ]; do sleep 0.05; done' > "$home/bin/fm-captain-hold.sh"
  : > "$home/divergence.hang"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" & pid=$!
  while [ ! -e "$home/divergence.entered" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/divergence.entered" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "empty queue never reached status presentation"; }
  printf 'note: alpha replaced during presentation\n' > "$home/state/alpha.status.next"
  mv "$home/state/alpha.status.next" "$home/state/alpha.status"; rm -f "$home/divergence.hang"; wait "$pid" || true
  grep -F 'WAKE_ACK_REQUIRED' "$home/err" >/dev/null && fail "empty queue published an ACK without staging its status cursor"
  grep -F 'WAKE_CONTEXT_FALLBACK:' "$home/out" >/dev/null || fail "empty queue lost its pre-presentation fallback"
  [ ! -e "$home/state/.wake-context-cache.status-cursor" ] || fail "empty queue staged an invalidated status cursor"
  pass "empty queue withholds ACK when status presentation cannot be staged"
}

retry_manual_drain_without_replay() { # <home> <status-text>
  local ack generation
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" "$1/bin/fm-wake-drain.sh" > "$1/retry" 2> "$1/retry.err" \
    || fail "manual drain retry failed"
  grep -F "$2" "$1/retry" >/dev/null || fail "manual retry lost the invalidated status"
  ack=$(sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' "$1/retry.err")
  generation=$(sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' "$1/retry.err")
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" "$1/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null \
    || fail "manual drain retry ACK failed"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$1" "$1/bin/fm-wake-drain.sh" > "$1/replay" 2>/dev/null
  grep -F "$2" "$1/replay" >/dev/null && fail "manual retry replayed the acknowledged status"
}

assert_manual_stage_failed_closed() { # <home> <status>
  [ "$2" -ne 0 ] || fail "manual drain published after status identity changed"
  grep -F 'WAKE_ACK_REQUIRED' "$1/err" >/dev/null && fail "manual drain exposed an ACK without a durable cursor"
  cmp -s "$1/cursor.before" "$1/state/.status-presentation-cursor" || fail "manual drain advanced the cursor after staging failed"
  [ ! -e "$1/state/.wake-context-cache.status-cursor" ] || fail "manual drain left a staged cursor"
}

test_manual_nonempty_queue_identity_change_withholds_ack() {
  local home="$TMP_ROOT/manual-nonempty-identity" pid i=0 status=0
  prepare_real_wake "$home"
  FM_WAKE_ENRICH_TEST_DELAY=2 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/out" 2> "$home/err" & pid=$!
  while ! process_tree_has_sleep "$pid" && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ "$i" -lt 100 ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "manual nonempty drain missed its staging barrier"; }
  printf 'note: beta replaced during manual presentation\n' > "$home/state/beta.status.next"
  mv "$home/state/beta.status.next" "$home/state/beta.status"
  wait "$pid" || status=$?
  assert_manual_stage_failed_closed "$home" "$status"
  [ -s "$home/state/.wake-queue" ] || fail "manual failure consumed the nonempty queue"
  retry_manual_drain_without_replay "$home" 'beta replaced during manual presentation'
  pass "manual nonempty queue withholds ACK until cursor staging succeeds"
}

install_empty_queue_identity_barrier() { # <home>
  cat > "$1/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = diverged ] || exit 0
: > "$FM_HOME/divergence.entered"
while [ -e "$FM_HOME/divergence.hang" ]; do sleep 0.05; done
SH
  chmod +x "$1/bin/fm-captain-hold.sh"
}

test_manual_empty_queue_identity_change_withholds_ack() {
  local home="$TMP_ROOT/manual-empty-identity" pid i=0 status=0
  install_real_drain_fixture "$home"; printf 'note: alpha bootstrap\n' > "$home/state/alpha.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" >/dev/null 2>/dev/null
  cp "$home/state/.status-presentation-cursor" "$home/cursor.before"
  printf 'note: alpha pending manual recovery\n' >> "$home/state/alpha.status"; : > "$home/state/.wake-queue"
  printf 'pending:handling:fixture\n' > "$home/state/.watcher-down"; install_empty_queue_identity_barrier "$home"; : > "$home/divergence.hang"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" > "$home/out" 2> "$home/err" & pid=$!
  while [ ! -e "$home/divergence.entered" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$home/divergence.entered" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "manual empty drain missed its staging barrier"; }
  printf 'note: alpha replaced during manual recovery\n' > "$home/state/alpha.status.next"
  mv "$home/state/alpha.status.next" "$home/state/alpha.status"; rm -f "$home/divergence.hang"; wait "$pid" || status=$?
  assert_manual_stage_failed_closed "$home" "$status"
  retry_manual_drain_without_replay "$home" 'alpha replaced during manual recovery'
  pass "manual empty queue withholds ACK until cursor staging succeeds"
}

test_manual_cursor_commit_error_withholds_ack() {
  local home="$TMP_ROOT/manual-cursor-error" real_mv status=0
  prepare_real_wake "$home"; cp "$home/state/.wake-queue" "$home/queue.before"
  real_mv=$(command -v mv); mkdir "$home/path"
  cat > "$home/path/mv" <<'SH'
#!/usr/bin/env bash
target=; for target do :; done
case "$target" in *.status-presentation-cursor) exit 1 ;; *) exec "$FM_TEST_REAL_MV" "$@" ;; esac
SH
  chmod +x "$home/path/mv"
  PATH="$home/path:$PATH" FM_TEST_REAL_MV="$real_mv" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/out" 2> "$home/err" || status=$?
  [ "$status" -ne 0 ] || fail "manual drain ignored cursor commit failure"
  grep -F 'WAKE_ACK_REQUIRED' "$home/err" >/dev/null && fail "manual drain exposed ACK after cursor commit failure"
  cmp -s "$home/queue.before" "$home/state/.wake-queue" || fail "cursor commit failure changed the durable queue"
  pass "manual cursor commit failure withholds ACK and preserves the queue"
}

test_empty_status_set_stages_empty_cursor() {
  local home="$TMP_ROOT/empty-status-stage" packet
  install_real_drain_fixture "$home"
  printf 'window=fleet:alpha\nbackend=tmux\n' > "$home/state/alpha.meta"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append heartbeat watcher "heartbeat: watcher"' \
    _ "$home/bin/fm-wake-lib.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "empty status set failed presentation"
  packet=$(packet_json "$home/out")
  [ -f "$home/state/.wake-context-cache.status-cursor" ] || fail "empty status set did not stage a cursor"
  [ ! -s "$home/state/.wake-context-cache.status-cursor" ] || fail "empty status set staged a nonempty cursor"
  ack_real_packet "$home" "$packet" >/dev/null 2>/dev/null || fail "empty status set ACK failed"
  pass "empty status set stages an explicit empty cursor before ACK"
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

test_zero_ack_replays_after_new_wake_and_opt_out() {
  local home="$TMP_ROOT/status-only-new-wake"
  install_fixture "$home"
  FM_DRAIN_ACK_THROUGH=0 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/first" 2> "$home/first.err" || fail "zero-ACK presentation failed"
  append_wake "$home" 1; rm "$home/config/wake-context-presentation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/replay" 2> "$home/replay.err" || fail "zero-ACK transaction did not replay"
  cmp -s "$home/first" "$home/replay" || fail "zero-ACK transaction changed after a new wake"
  pass "zero-ACK transaction replays byte-identically after a new wake and opt-out"
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
    [ "$(tail -1 "$home/backend-timeout")" = "$expected" ] || fail "timeout $value did not normalize to $expected"
  done
  pass "backend liveness timeout stays strictly positive after normalization"
}

test_collection_timeout_accepts_leading_zero_decimal() {
  local value home packet
  for value in 08 09; do
    home="$TMP_ROOT/collection-timeout-$value"
    install_fixture "$home"; append_wake "$home" 1
    FM_WAKE_CONTEXT_COLLECTION_TIMEOUT="$value" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
      "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || fail "collection timeout $value failed"
    packet=$(packet_json "$home/out")
    assert_packet_content "$packet"
  done
  pass "collection timeout accepts leading-zero decimal values"
}

test_collection_timeout_bounds_drain_before_ack() {
  local home="$TMP_ROOT/slow-drain" started finished status=0
  install_fixture "$home"; cp "$ROOT/bin/fm-timeout-lib.sh" "$home/bin/"; append_wake "$home" 1
  started=$SECONDS
  FM_DRAIN_SECONDS=5 FM_WAKE_CONTEXT_COLLECTION_TIMEOUT=2 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  finished=$SECONDS
  [ "$status" -ne 0 ] || fail "un drain lent a produit un paquet"
  [ $((finished - started)) -lt 5 ] || fail "le drain lent a dépassé la borne agrégée"
  grep -Fx 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: wake context collection timed out; run bin/fm-wake-drain.sh once.' "$home/out" >/dev/null \
    || fail "le timeout avant ACK n’a pas demandé un drain unique"
  [ ! -s "$home/err" ] || fail "le timeout avant ACK a inventé un ACK"
  [ ! -e "$home/state/.wake-context-cache" ] || fail "le timeout du drain a publié un cache"
  pass "le drain partage la borne agrégée et retombe avant présentation"
}

write_blocked_copy_stub() { # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_COPY_STARTED"
sleep 20
: > "$FM_TEST_COPY_COMPLETED"
exec "$FM_TEST_REAL_CP" "$@"
SH
  chmod +x "$1"
}

assert_initial_copy_timeout() { # <home> <status> <elapsed>
  [ "$2" -ne 0 ] || fail "initial queue copy ignored the aggregate deadline"
  [ "$3" -lt 10 ] || fail "initial queue copy escaped the aggregate deadline"
  [ -e "$1/copy.started" ] || fail "initial queue copy never reached the blocked executable"
  [ ! -e "$1/copy.completed" ] || fail "initial queue copy completed after the aggregate deadline"
  [ ! -e "$1/drain.calls" ] || fail "timed-out initial queue copy reached the drain"
  grep -Fx 'WAKE_CONTEXT_FALLBACK: wake context unavailable before presentation: wake context collection timed out; run bin/fm-wake-drain.sh once.' "$1/out" >/dev/null \
    || fail "timed-out initial queue copy lost its single manual-drain instruction"
  [ "$(grep -Fc 'WAKE_CONTEXT_FALLBACK:' "$1/out")" -eq 1 ] || fail "timed-out initial queue copy duplicated its fallback"
}

test_collection_timeout_bounds_initial_queue_copy() {
  local home="$TMP_ROOT/slow-copy" real_cp started elapsed status=0
  install_fixture "$home"; cp "$ROOT/bin/fm-timeout-lib.sh" "$home/bin/"; append_wake "$home" 1
  real_cp=$(command -v cp); mkdir "$home/path"; write_blocked_copy_stub "$home/path/cp"
  started=$SECONDS
  PATH="$home/path:$PATH" FM_TEST_REAL_CP="$real_cp" FM_TEST_COPY_STARTED="$home/copy.started" \
    FM_TEST_COPY_COMPLETED="$home/copy.completed" FM_WAKE_CONTEXT_COLLECTION_TIMEOUT=2 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  elapsed=$((SECONDS - started)); assert_initial_copy_timeout "$home" "$status" "$elapsed"
  pass "initial queue copy shares the aggregate collection deadline"
}

test_collection_timeout_falls_back_after_crew_state_hang() {
  local home="$TMP_ROOT/collection-timeout" started finished status=0
  install_fixture "$home"; cp "$ROOT/bin/fm-timeout-lib.sh" "$home/bin/"; append_wake "$home" 1; : > "$home/hang"
  started=$(date +%s)
  FM_CREW_STATE_HANG="$home/hang" FM_WAKE_CONTEXT_COLLECTION_TIMEOUT=2 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  finished=$(date +%s); rm -f "$home/hang"
  [ "$status" -ne 0 ] || fail "une collecte bloquée a produit un paquet"
  [ $((finished - started)) -le 4 ] || fail "le fallback a dépassé le délai agrégé"
  grep -Fx 'Wake context packet could not be built after the durable presentation.' "$home/out" >/dev/null || fail "le fallback canonique manque"
  grep -F -- '--ack-through 1 --recovery-generation fixture-1' "$home/err" >/dev/null || fail "le fallback a perdu son ACK"
  [ ! -e "$home/state/.wake-context-cache" ] || fail "le timeout a publié un cache"
  pass "une sonde crew-state bloquée respecte le délai agrégé et le fallback"
}

test_timeout_after_cursor_stage_keeps_receipt_before_ack() {
  local home="$TMP_ROOT/timeout-after-cursor-stage" real_mv ack generation expected status=0
  prepare_real_wake "$home"; real_mv=$(command -v mv); mkdir "$home/path"
  cat > "$home/path/mv" <<'SH'
#!/usr/bin/env bash
target=; for target do :; done
case "$target" in *.wake-context-cache.status-cursor) "$FM_TEST_REAL_MV" "$@" && : > "$FM_TEST_CURSOR_MOVED" ;; *.wake-context-cache) : > "$FM_TEST_CACHE_ENTERED"; sleep 10; "$FM_TEST_REAL_MV" "$@" ;; *) "$FM_TEST_REAL_MV" "$@" ;; esac
SH
  chmod +x "$home/path/mv"
  PATH="$home/path:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_CURSOR_MOVED="$home/cursor.moved" FM_TEST_CACHE_ENTERED="$home/cache.entered" FM_WAKE_CONTEXT_COLLECTION_TIMEOUT=8 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  [ "$status" -ne 0 ] && [ -e "$home/cursor.moved" ] && [ -e "$home/cache.entered" ] || fail "le timeout n’a pas suivi le vrai staging du curseur"
  [ -f "$home/state/.wake-context-fallback-receipt" ] && [ -f "$home/state/.wake-context-cache.status-cursor" ] || fail "le fallback a publié l’ACK sans reçu et curseur durables"
  ack=$(jq -r '.replay.ack_through' "$home/state/.wake-context-fallback-receipt"); generation=$(jq -r '.replay.recovery_generation' "$home/state/.wake-context-fallback-receipt")
  expected="WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through $ack --recovery-generation $generation"; if [ "$(grep -Fc 'WAKE_ACK_REQUIRED:' "$home/err")" -ne 1 ] || ! grep -Fx "$expected" "$home/err" >/dev/null; then fail "le fallback n’a pas publié l’ACK exact"; fi
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || fail "l’ACK exact du fallback a échoué"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" > "$home/replay" 2>/dev/null; grep -F 'beta during alpha wake' "$home/replay" >/dev/null && fail "le drain suivant a rejoué le status acquitté"
  pass "un timeout après staging publie reçu et curseur avant l’ACK exact sans rejeu"
}

test_collection_timeout_spans_slow_crew_probes() {
  local home="$TMP_ROOT/slow-probes" started finished status=0
  install_fixture "$home"; cp "$ROOT/bin/fm-timeout-lib.sh" "$home/bin/"; append_wake "$home" 1
  printf 'window=fleet:beta\nbackend=tmux\nworktree=%s\nkind=ship\n' "$home/worktree" > "$home/state/beta.meta"
  printf 'working: beta\n' > "$home/state/beta.status"; printf '1\t2\tsignal\tbeta.status\tsignal: beta.status\n' >> "$home/state/.wake-queue"
  started=$(date +%s)
  FM_CREW_STATE_ALPHA_SECONDS=1 FM_CREW_STATE_BETA_SECONDS=8 FM_WAKE_CONTEXT_COLLECTION_TIMEOUT=5 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-context.sh" --present > "$home/out" 2> "$home/err" || status=$?
  finished=$(date +%s); [ "$status" -ne 0 ] || fail "deux sondes lentes ont produit un paquet"
  [ $((finished - started)) -lt 8 ] || fail "les sondes lentes ont dépassé la borne agrégée"
  { grep -Fx 'alpha' "$home/crew-state.calls" >/dev/null && grep -Fx 'beta' "$home/crew-state.calls" >/dev/null; } \
    || fail "la borne agrégée n’a pas couvert deux vraies sondes lentes"
  grep -Fx 'Wake context packet could not be built after the durable presentation.' "$home/out" >/dev/null || fail "le fallback des sondes lentes manque"
  grep -F -- '--ack-through 1 --recovery-generation fixture-1' "$home/err" >/dev/null || fail "le fallback des sondes lentes a perdu l’ACK"
  [ ! -e "$home/state/.wake-context-cache" ] || fail "les sondes lentes ont publié un cache"
  pass "plusieurs sondes crew-state partagent une borne agrégée"
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
  grep -Fx 'WAKE_CONTEXT_PRESENTED: durable presentation complete; do not run bin/fm-wake-drain.sh again.' "$home/out" >/dev/null \
    || fail "post-presentation fallback did not expose the common result"
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

test_manual_drain_preserves_published_fallback() {
  local home="$TMP_ROOT/manual-preserve" payload status=0
  prepare_real_wake "$home"; payload=$(head -c 60000 /dev/zero | tr '\0' x)
  printf '%s' "$payload" > "$home/state/alpha.status"; printf '%s' "$payload" > "$home/state/beta.status"
  printf '%s' "$payload" > "$home/state/gamma.status"; printf '\nnote: after-truncated\n' >> "$home/state/beta.status"
  jq -cn '{replay:{ack_through:1,recovery_generation:"old"}}' > "$home/state/.wake-context-fallback-receipt"
  cp "$home/cursor.before" "$home/state/.wake-context-cache.status-cursor"
  cp "$home/state/.wake-context-fallback-receipt" "$home/receipt.before"; cp "$home/state/.wake-context-cache.status-cursor" "$home/stage.before"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" > "$home/manual" 2> "$home/manual.err" || status=$?
  [ "$status" -ne 0 ] || fail "manual drain superseded a published fallback"
  cmp -s "$home/receipt.before" "$home/state/.wake-context-fallback-receipt" || fail "manual drain changed the published receipt"
  cmp -s "$home/stage.before" "$home/state/.wake-context-cache.status-cursor" || fail "manual drain changed the staged cursor"
  pass "manual drain preserves a published fallback until its exact ACK"
}

test_superseded_ack_fails_before_wake_mutation() {
  local home="$TMP_ROOT/superseded-ack" ack generation status=0
  prepare_real_wake "$home"
  FM_CREW_STATE_LARGE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present >/dev/null 2>/dev/null || true
  ack=$(jq -r '.replay.ack_through' "$home/state/.wake-context-fallback-receipt"); generation=$(jq -r '.replay.recovery_generation' "$home/state/.wake-context-fallback-receipt")
  jq -cn --argjson ack "$((ack + 1))" --arg generation "$generation" '{replay:{ack_through:$ack,recovery_generation:$generation}}' > "$home/receipt.next"
  mv "$home/receipt.next" "$home/state/.wake-context-fallback-receipt"; cp -R "$home/state" "$home/state.before"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "superseded ACK was accepted"
  diff -qr "$home/state.before" "$home/state" >/dev/null || fail "superseded ACK mutated wake state"
  pass "superseded ACK fails before queue, claim, recovery, cursor, or receipt mutation"
}

test_ack_selects_the_exact_published_receipt() {
  local home="$TMP_ROOT/exact-receipt" ack generation
  prepare_real_wake "$home"
  FM_CREW_STATE_LARGE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-context.sh" --present >/dev/null 2>/dev/null || true
  ack=$(jq -r '.replay.ack_through' "$home/state/.wake-context-fallback-receipt"); generation=$(jq -r '.replay.recovery_generation' "$home/state/.wake-context-fallback-receipt")
  jq -cn --argjson ack "$((ack + 1))" --arg generation "$generation" '{replay:{ack_through:$ack,recovery_generation:$generation}}' > "$home/state/.wake-context-cache"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home" \
    "$home/bin/fm-wake-drain.sh" --ack-through "$ack" --recovery-generation "$generation" >/dev/null 2>/dev/null || fail "exact fallback receipt was ignored"
  [ ! -e "$home/state/.wake-context-cache.status-cursor" ] || fail "exact ACK did not commit its staged cursor"
  [ ! -e "$home/state/.wake-context-cache" ] && [ ! -e "$home/state/.wake-context-fallback-receipt" ] || fail "exact ACK did not retire transaction state"
  pass "ACK selects its exact receipt before committing the transaction"
}

test_resolved_is_not_primary_actionable() {
  bash -c '. "$1"; ! status_is_captain_relevant "resolved [key=choice]: answered"' \
    _ "$ROOT/bin/fm-classify-lib.sh" || fail "resolved status still wakes the primary classifier"
  pass "resolved status is already non-actionable on the primary"
}

test_packet_is_bounded_and_complete
test_missing_opt_in_falls_back_without_mutation
test_config_override_owns_opt_in_resolution
test_utf8_packet_uses_true_byte_bound
test_real_drain_presentation_replays_identically_before_ack
test_sigkill_before_cache_publish_keeps_unread_note
test_status_cursor_is_staged_before_ack
test_unstageable_status_cursor_withholds_ack
test_empty_queue_unstageable_status_cursor_withholds_ack
test_manual_nonempty_queue_identity_change_withholds_ack
test_manual_empty_queue_identity_change_withholds_ack
test_manual_cursor_commit_error_withholds_ack
test_empty_status_set_stages_empty_cursor
test_cardinality_overflow_falls_back_before_drain
test_stale_window_maps_to_affected_task
test_packet_projects_unread_status_tail
test_absolute_check_key_maps_to_task
test_status_only_recovery_uses_zero_ack
test_zero_ack_replays_after_new_wake_and_opt_out
test_post_drain_overflow_falls_back
test_backend_timeout_normalizes_to_a_positive_decimal
test_collection_timeout_accepts_leading_zero_decimal
test_collection_timeout_bounds_drain_before_ack
test_collection_timeout_bounds_initial_queue_copy
test_collection_timeout_falls_back_after_crew_state_hang
test_timeout_after_cursor_stage_keeps_receipt_before_ack
test_collection_timeout_spans_slow_crew_probes
test_cursor_merge_follows_live_rotation_without_regression
test_post_presentation_failure_preserves_human_ack
test_utf8_fallback_ack_commits_unread_cursor
test_manual_drain_preserves_published_fallback
test_superseded_ack_fails_before_wake_mutation
test_ack_selects_the_exact_published_receipt
test_resolved_is_not_primary_actionable
