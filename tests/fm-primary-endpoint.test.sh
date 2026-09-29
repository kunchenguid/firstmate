#!/usr/bin/env bash
# Portable behavior tests for bin/fm-primary-endpoint-lib.sh and the central
# watcher wake integration. A copied Bash executable named kiro-cli provides a
# real process identity; a thin tmux fake supplies one Kiro composer and records
# terminal delivery. No model or live harness is used.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-endpoint)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
REAL_BASH=$(command -v bash)
cp "$REAL_BASH" "$FAKEBIN/kiro-cli"
chmod +x "$FAKEBIN/kiro-cli"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '1\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    cat "$FM_PRIMARY_TEST_SCREEN"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_PRIMARY_TEST_SEND_LOG"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

run_as_kiro() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  mkdir -p "$dir/home/state" "$dir/root"
  # The whole bin tree, so the library's transitive sources never drift out of
  # a hand-kept copy list.
  cp -R "$ROOT/bin" "$dir/root/bin"
  printf '# Firstmate\n' > "$dir/root/AGENTS.md"
  : > "$dir/send.log"
  printf 'transcript\n\033[38;2;158;158;158m› ask a question or describe a task ↵\033[0m\n' > "$dir/idle.screen"
  printf 'transcript\n› half typed command\n' > "$dir/pending.screen"
  local fake_script
  fake_script=$(cat <<'FAKE_KIRO'
      set -eu
      mode=$1
      state=$FM_STATE_OVERRIDE
      printf "%s\n" "$$" > "$state/.lock"
      . "$FM_ROOT_OVERRIDE/bin/fm-primary-endpoint-lib.sh"
      fm_primary_endpoint_publish "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME"
      case "$mode" in
        direct)
          log=$FM_PRIMARY_TEST_SEND_LOG
          fm_primary_endpoint_ring_kiro "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" wake || exit 21
          mv "$log" "$log.wake"; : > "$log"
          fm_primary_endpoint_ring_kiro "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" failure || exit 22
          mv "$log" "$log.failure"; : > "$log"
          if fm_primary_endpoint_ring_kiro "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" bogus; then
            exit 23
          fi
          [ ! -s "$log" ] || exit 24
          export FM_PRIMARY_TEST_SCREEN=${FM_PRIMARY_TEST_SCREEN%/*}/pending.screen
          if fm_primary_endpoint_ring_kiro "$state" "$FM_ROOT_OVERRIDE" "$FM_HOME" wake; then
            exit 25
          fi
          [ ! -s "$log" ] || exit 26
          ;;
        wake)
          fm_wake_append check primary-doorbell "check: primary doorbell"
          . "$FM_ROOT_OVERRIDE/bin/fm-push-transition-lib.sh"
          wake "check: primary doorbell"
          ;;
      esac
FAKE_KIRO
)
  MODE="$mode" PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" TMUX_PANE='primary:0' \
    FM_PRIMARY_TEST_SCREEN="$dir/idle.screen" FM_PRIMARY_TEST_SEND_LOG="$dir/send.log" \
    "$FAKEBIN/kiro-cli" -c "$fake_script" _ "$mode"
}

test_direct_ring_and_safety_guards() {
  local dir="$TMP_ROOT/direct" record sent rc=0
  run_as_kiro "$dir" direct > "$dir.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "identity-bound direct ring scenario failed at step $rc: $(cat "$dir.out")"
  record="$dir/home/state/.primary-endpoint"
  assert_present "$record" "SessionStart publication did not create a primary endpoint record"
  assert_grep 'schema=fm-primary-endpoint.v1' "$record" "endpoint schema is missing"
  assert_grep 'harness=kiro-cli' "$record" "endpoint is not Kiro-scoped"
  sent=$(cat "$dir/send.log.wake")
  assert_contains "$sent" ': Firstmate wake waiting:' "Kiro primary doorbell was not typed"
  assert_contains "$sent" 'fm-wake-drain.sh' "doorbell did not point at the existing drain owner"
  assert_contains "$sent" ' Enter' "doorbell was not submitted"
  sent=$(cat "$dir/send.log.failure")
  assert_contains "$sent" 'watcher continuity FAILED' "the continuity-failure ring was not typed"
  assert_contains "$sent" 'fm-primary-doorbell.sh' "the continuity-failure ring did not name the doorbell owner"
  assert_contains "$sent" ' Enter' "the continuity-failure ring was not submitted"
  pass "primary endpoint: lock-bound Kiro ring types the wake or failure line, and unknown kinds and pending composers stay silent"
}

test_watcher_wake_never_types_into_the_endpoint() {
  local dir="$TMP_ROOT/wake" out
  out=$(run_as_kiro "$dir" wake) || fail "central wake integration failed: $out"
  assert_contains "$out" 'check: primary doorbell' "central wake did not emit its actionable reason"
  assert_present "$dir/home/state/.wake-queue" "central wake did not retain the durable queue row"
  assert_grep 'primary-doorbell' "$dir/home/state/.wake-queue" "queued wake lost its key"
  [ ! -s "$dir/send.log" ] || fail "the watcher typed into the Kiro endpoint: $(cat "$dir/send.log")"
  pass "watcher wake: keeps the durable row and leaves ringing to the doorbell owner"
}

test_direct_ring_and_safety_guards
test_watcher_wake_never_types_into_the_endpoint

test_primary_hook_delivers_startup_and_unacknowledged_wake_context() {
  local dir="$TMP_ROOT/primary-hook" shim home state hook out
  shim="$dir/root"; home="$dir/home"; state="$home/state"; hook="$shim/bin/fm-kiro-turnend-hook.sh"
  mkdir -p "$shim/bin" "$state"
  cp "$ROOT/bin/fm-kiro-turnend-hook.sh" "$hook"
  cat > "$shim/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { [ "${FM_PRIMARY_SCOPE_RESULT:-0}" = 0 ]; }
SH
  cat > "$shim/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'SESSION-DIGEST\n'
SH
  cat > "$shim/bin/fm-primary-endpoint-lib.sh" <<'SH'
fm_primary_endpoint_publish() { printf '%s\n' "$*" > "$FM_PRIMARY_PUBLISH_LOG"; }
fm_primary_endpoint_ensure() { FM_PRIMARY_ENDPOINT_ENSURED=current; }
SH
  cat > "$shim/bin/fm-session-lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() { return 0; }
SH
  cat > "$shim/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'WAKE-CONTEXT\nWAKE_ACK_REQUIRED: keep queued until handled\n'
SH
  chmod +x "$hook" "$shim/bin/fm-sessionstart-run.sh" "$shim/bin/fm-wake-drain.sh"

  out=$(printf '{"hook_event_name":"SessionStart"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_ROOT_OVERRIDE="$shim" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_PUBLISH_LOG="$dir/published" bash "$hook")
  assert_contains "$out" SESSION-DIGEST "primary SessionStart did not deliver the startup digest: '$out'"
  assert_contains "$out" 'KIRO_PRIMARY_ENDPOINT: structural wake doorbell published' \
    "primary SessionStart did not tell the model its doorbell is live: '$out'"
  assert_grep "$state $shim $home" "$dir/published" \
    "primary SessionStart did not publish its endpoint after startup"

  printf 'queued\n' > "$state/.wake-queue"
  out=$(printf '{"hook_event_name":"UserPromptSubmit"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_ROOT_OVERRIDE="$shim" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash "$hook")
  assert_contains "$out" WAKE-CONTEXT "primary UserPromptSubmit did not attach wake context"
  assert_contains "$out" WAKE_ACK_REQUIRED "primary wake context lost its post-handling acknowledgement"
  assert_grep queued "$state/.wake-queue" "UserPromptSubmit consumed a wake before model handling"

  rm -f "$dir/published"
  out=$(printf '{"hook_event_name":"SessionStart"}\n' | \
    FM_KIRO_PRIMARY_HOOK=1 FM_PRIMARY_SCOPE_RESULT=1 FM_ROOT_OVERRIDE="$shim" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PRIMARY_PUBLISH_LOG="$dir/published" bash "$hook")
  [ -z "$out" ] || fail "an inherited primary hook in linked scope emitted context: '$out'"
  assert_absent "$dir/published" "an inherited primary hook published a worker endpoint"
  pass "Kiro primary hook: startup and wake context deliver only in primary scope without early acknowledgement"
}
test_primary_hook_delivers_startup_and_unacknowledged_wake_context

# A real Kiro-shaped process chain for the every-turn ensure: a copied bash named
# kiro-cli owns the fleet lock and runs the SHIPPED hook through genuine nested
# shells, deeper than eight frames, exactly where a Kiro hook reaches it. Only
# the primary-scope predicate, the startup runner, supervision need, and the
# watcher arm are shimmed, so no digest runs and no watcher starts.
make_ensure_case() {  # <case-dir>
  local dir=$1 root=$1/root
  mkdir -p "$dir/home/state" "$root"
  cp -R "$ROOT/bin" "$root/bin"
  printf '# Firstmate\n' > "$root/AGENTS.md"
  cat > "$root/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { return 0; }
SH
  cat > "$root/bin/fm-supervision-lib.sh" <<SH
fm_supervision_needed() { [ "\$(cat '$dir/needed' 2>/dev/null)" = 1 ]; }
SH
  printf '#!/usr/bin/env bash\nprintf "SESSION-DIGEST\\n"\n' > "$root/bin/fm-sessionstart-run.sh"
  cat > "$root/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf 'arm\\n' >> '$dir/arm.log'
SH
  cat > "$root/bin/fm-primary-doorbell.sh" <<SH
#!/usr/bin/env bash
printf 'doorbell %s\\n' "\$*" >> '$dir/doorbell.log'
exit "\$(cat '$dir/doorbell.rc' 2>/dev/null || echo 0)"
SH
  chmod +x "$root/bin/fm-watch-arm.sh" "$root/bin/fm-primary-doorbell.sh"
  : > "$dir/send.log"
}

# Run <event> through the shipped hook <depth> shells below a kiro-cli process.
# With <lock-owner>=self that process records itself as the lock owner first;
# any other value is written to the lock verbatim. Prints the hook's context
# output, then `kiro=<pid>` for the session's own pid.
run_ensure_hook() {  # <case-dir> <event> <lock-owner> [depth] [pane]
  local dir=$1 event=$2 owner=$3 depth=${4:-10} pane=${5:-primary:0} hook inner
  hook="$dir/root/bin/fm-kiro-turnend-hook.sh"
  inner="printf '{\"hook_event_name\":\"%s\"}\\n' '$event' | bash '$hook'"
  PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" FM_KIRO_PRIMARY_HOOK=1 TMUX_PANE="$pane" \
    FM_PRIMARY_TEST_SCREEN="$dir/idle.screen" FM_PRIMARY_TEST_SEND_LOG="$dir/send.log" \
    "$FAKEBIN/kiro-cli" -c "
      if [ '$owner' = self ]; then printf '%s\n' \"\$\$\" > '$dir/home/state/.lock'
      else printf '%s\n' '$owner' > '$dir/home/state/.lock'; fi
      $(fm_nested_bash_command "$depth" "$inner")
      printf 'kiro=%s\n' \"\$\$\""
}

endpoint_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1"
}

test_every_turn_hooks_ensure_the_doorbell() {
  local dir="$TMP_ROOT/ensure" record out pid
  make_ensure_case "$dir"
  record="$dir/home/state/.primary-endpoint"

  # Hooks that arrive after the first prompt never see SessionStart: a missing
  # doorbell is published by the next UserPromptSubmit, which says so once.
  out=$(run_ensure_hook "$dir" UserPromptSubmit self) || fail "UserPromptSubmit ensure scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  assert_present "$record" "UserPromptSubmit did not publish a missing doorbell"
  [ "$(endpoint_field "$record" pid)" = "$pid" ] \
    || fail "published doorbell names pid '$(endpoint_field "$record" pid)', not the kiro session '$pid'"
  assert_contains "$out" 'KIRO_PRIMARY_ENDPOINT: structural wake doorbell published' \
    "UserPromptSubmit did not tell the model its doorbell became live: $out"

  # Stop publishes a missing doorbell too, silently.
  rm -f "$record"
  out=$(run_ensure_hook "$dir" Stop self) || fail "Stop ensure scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  assert_present "$record" "Stop did not publish a missing doorbell"
  [ "$(endpoint_field "$record" pid)" = "$pid" ] || fail "Stop published the wrong pid"
  [ "$(printf '%s\n' "$out" | grep -vc '^kiro=')" = 0 ] || fail "Stop wrote context: $out"

  # A record left by an older session incarnation is republished for this one,
  # and a moved pane is followed.
  out=$(run_ensure_hook "$dir" UserPromptSubmit self 10 'primary:7') || fail "republish scenario failed: $out"
  pid=$(printf '%s\n' "$out" | sed -n 's/^kiro=//p')
  [ "$(endpoint_field "$record" pid)" = "$pid" ] || fail "an old-pid doorbell was not republished for pid '$pid'"
  [ "$(endpoint_field "$record" target)" = 'primary:7' ] || fail "a moved pane was not republished"

  # A current doorbell is left exactly as it is.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" TMUX_PANE='primary:0' \
    "$FAKEBIN/kiro-cli" -c "
      . '$dir/root/bin/fm-primary-endpoint-lib.sh'
      printf '%s\n' \"\$\$\" > '$dir/home/state/.lock'
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 3
      printf 'first=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 4
      printf 'second=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"
      touch -d '2000-01-01' '$record'
      fm_primary_endpoint_ensure '$dir/home/state' '$dir/root' '$dir/home' || exit 5
      printf 'third=%s\n' \"\$FM_PRIMARY_ENDPOINT_ENSURED\"") \
    || fail "direct ensure scenario failed: $out"
  assert_contains "$out" 'first=published' "a new session's first ensure did not publish: $out"
  assert_contains "$out" 'second=current' "an unchanged doorbell was republished: $out"
  assert_contains "$out" 'third=current' "a current doorbell was rewritten: $out"
  touch "$dir/now"
  [ "$record" -ot "$dir/now" ] || fail "a current doorbell was rewritten on disk"
  pass "Kiro primary hooks: every turn publishes a missing doorbell, follows a new pid or pane, and leaves a current one alone"
}

test_ensure_refuses_another_sessions_lock() {
  local dir="$TMP_ROOT/ensure-foreign" record other out before
  make_ensure_case "$dir"
  record="$dir/home/state/.primary-endpoint"
  # Another live kiro-cli session holds the lock.
  "$FAKEBIN/kiro-cli" -c 'sleep 60' &
  other=$!
  for event in UserPromptSubmit Stop; do
    out=$(run_ensure_hook "$dir" "$event" "$other") || fail "$event foreign-lock scenario failed: $out"
    assert_absent "$record" "$event published a doorbell while another session owns the lock"
  done
  # Its own record stays byte-identical.
  printf 'schema=fm-primary-endpoint.v1\nharness=kiro-cli\nbackend=tmux\ntarget=other:1\npid=%s\npid_identity=x\nroot=%s\nhome=%s\n' \
    "$other" "$dir/root" "$dir/home" > "$record"
  before=$(cat "$record")
  for event in UserPromptSubmit Stop; do
    run_ensure_hook "$dir" "$event" "$other" >/dev/null || fail "$event foreign-lock scenario failed"
    [ "$(cat "$record")" = "$before" ] || fail "$event overwrote another session's doorbell"
  done
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "Kiro primary hooks: the every-turn ensure refuses when another session owns the lock"
}

test_every_turn_hooks_ensure_the_doorbell
test_ensure_refuses_another_sessions_lock

test_prompt_hook_attaches_the_doorbell_note_once() {
  local dir="$TMP_ROOT/doorbell-note" note out
  make_ensure_case "$dir"
  note="$dir/home/state/.primary-doorbell-note"
  printf 'supervision-host: cycle boundary test\n' > "$note"
  out=$(run_ensure_hook "$dir" UserPromptSubmit self) || fail "doorbell-note scenario failed: $out"
  printf '%s\n' "$out" | grep -A1 '^KIRO_PRIMARY_DOORBELL_NOTE: ' | grep -qx 'supervision-host: cycle boundary test' \
    || fail "UserPromptSubmit did not attach the note after its header: $out"
  assert_absent "$note" "UserPromptSubmit left the doorbell note behind"
  out=$(run_ensure_hook "$dir" UserPromptSubmit self) || fail "second doorbell-note scenario failed: $out"
  assert_not_contains "$out" 'KIRO_PRIMARY_DOORBELL_NOTE' "a second UserPromptSubmit attached the note again: $out"
  pass "Kiro primary hooks: the lock-owning UserPromptSubmit attaches the doorbell note once and removes it"
}
test_prompt_hook_attaches_the_doorbell_note_once

test_stop_hook_ensures_the_doorbell_owner() {
  local dir="$TMP_ROOT/stop-doorbell" other out i
  make_ensure_case "$dir"
  printf '1\n' > "$dir/needed"
  arm_count() { grep -c '^arm$' "$dir/arm.log" 2>/dev/null || true; }

  # A running doorbell owner is the whole Stop continuity: no arm is forked.
  out=$(run_ensure_hook "$dir" Stop self) || fail "Stop doorbell scenario failed: $out"
  assert_grep 'doorbell ensure' "$dir/doorbell.log" "Stop did not ensure the doorbell owner"
  sleep 1
  assert_absent "$dir/arm.log" "Stop armed a watcher although the doorbell owner is running"

  # No owner can run: Stop falls back to exactly one detached arm.
  printf '3\n' > "$dir/doorbell.rc"
  : > "$dir/doorbell.log"
  out=$(run_ensure_hook "$dir" Stop self) || fail "Stop fallback scenario failed: $out"
  assert_grep 'doorbell ensure' "$dir/doorbell.log" "Stop fallback did not try the doorbell owner first"
  i=0
  while [ "$(arm_count)" = 0 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 0.3
  assert_equals "$(arm_count)" 1 "Stop fallback did not arm exactly one watcher"

  # Another session's lock: neither the owner nor an arm.
  rm -f "$dir/arm.log" "$dir/doorbell.log"
  "$FAKEBIN/kiro-cli" -c 'sleep 60' &
  other=$!
  out=$(run_ensure_hook "$dir" Stop "$other") || fail "Stop foreign-lock scenario failed: $out"
  sleep 1
  assert_absent "$dir/doorbell.log" "a foreign-lock Stop ensured the doorbell owner"
  assert_absent "$dir/arm.log" "a foreign-lock Stop armed a watcher"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  pass "Kiro primary Stop: ensures the doorbell owner, falls back to one arm only when no owner can run, and ignores a foreign lock"
}
test_stop_hook_ensures_the_doorbell_owner


# Run a PreToolUse payload for <command> through the shipped hook below a
# kiro-cli process. <setup> is one of: owner (this session owns the lock and
# publishes its doorbell), foreign (publishes, then the lock moves to <other>),
# afk (publishes, then the away flag appears), noendpoint (owns the lock but
# publishes nothing). Writes the hook's exit status to $dir/seatbelt.rc and its
# stderr to $dir/seatbelt.err.
run_seatbelt_hook() {  # <case-dir> <command> <setup> [other-pid]
  local dir=$1 cmd=$2 setup=$3 other=${4:-} hook inner
  hook="$dir/root/bin/fm-kiro-turnend-hook.sh"
  jq -cn --arg command "$cmd" \
    '{session_id:"s",hook_event_name:"PreToolUse",tool_name:"execute_bash",tool_input:{command:$command}}' \
    > "$dir/seatbelt.json"
  rm -f "$dir/seatbelt.rc" "$dir/seatbelt.err" "$dir/home/state/.afk" "$dir/home/state/.primary-endpoint"
  inner="bash '$hook' < '$dir/seatbelt.json' 2> '$dir/seatbelt.err'; printf '%s\n' \$? > '$dir/seatbelt.rc'"
  PATH="$FAKEBIN:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_ROOT_OVERRIDE="$dir/root" FM_KIRO_PRIMARY_HOOK=1 TMUX_PANE=primary:0 \
    "$FAKEBIN/kiro-cli" -c "
      printf '%s\n' \"\$\$\" > '$dir/home/state/.lock'
      if [ '$setup' != noendpoint ]; then
        . '$dir/root/bin/fm-primary-endpoint-lib.sh'
        fm_primary_endpoint_publish '$dir/home/state' '$dir/root' '$dir/home' || exit 7
      fi
      case '$setup' in
        foreign) printf '%s\n' '$other' > '$dir/home/state/.lock' ;;
        afk) : > '$dir/home/state/.afk' ;;
      esac
      $(fm_nested_bash_command 10 "$inner")
      true"  # keeps the kiro-cli frame from exec'ing into the nested shell
}

test_pretool_seatbelt_blocks_only_an_owner_held_arm() {
  local dir="$TMP_ROOT/seatbelt" other rc
  make_ensure_case "$dir"
  printf '1\n' > "$dir/needed"

  run_seatbelt_hook "$dir" 'bin/fm-watch-arm.sh --restart' owner || fail "seatbelt owner scenario failed"
  rc=$(cat "$dir/seatbelt.rc")
  assert_equals "$rc" 2 "an owner-held arm was not blocked: $(cat "$dir/seatbelt.err")"
  assert_grep watcher-owner-held "$dir/seatbelt.err" "the seatbelt block did not name watcher-owner-held"

  run_seatbelt_hook "$dir" 'ls' owner || fail "seatbelt ls scenario failed"
  assert_equals "$(cat "$dir/seatbelt.rc")" 0 "the seatbelt blocked an unrelated command"

  "$FAKEBIN/kiro-cli" -c 'sleep 60' &
  other=$!
  run_seatbelt_hook "$dir" 'bin/fm-watch-arm.sh --restart' foreign "$other" || fail "seatbelt foreign scenario failed"
  assert_equals "$(cat "$dir/seatbelt.rc")" 0 "the seatbelt blocked an arm under another session's lock"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true

  run_seatbelt_hook "$dir" 'bin/fm-watch-arm.sh --restart' afk || fail "seatbelt afk scenario failed"
  assert_equals "$(cat "$dir/seatbelt.rc")" 0 "the seatbelt blocked an arm in away mode"

  run_seatbelt_hook "$dir" 'bin/fm-watch-arm.sh --restart' noendpoint || fail "seatbelt noendpoint scenario failed"
  assert_equals "$(cat "$dir/seatbelt.rc")" 0 "the seatbelt blocked an arm with no doorbell record"
  pass "Kiro primary PreToolUse: blocks a model-run arm only for the lock owner with a published doorbell and no away flag"
}
test_pretool_seatbelt_blocks_only_an_owner_held_arm

test_published_line_forbids_a_model_arm() {
  local dir="$TMP_ROOT/published-line" out line
  make_ensure_case "$dir"
  out=$(run_ensure_hook "$dir" UserPromptSubmit self) || fail "published-line scenario failed: $out"
  line=$(printf '%s\n' "$out" | grep 'KIRO_PRIMARY_ENDPOINT: structural wake doorbell published')
  [ -n "$line" ] || fail "UserPromptSubmit did not print the published line: $out"
  assert_contains "$line" 'never run bin/fm-watch-arm.sh' "the published line does not forbid a model arm: $line"
  case "$line" in *'keep one cycle armed'*) fail "the published line still tells the model to arm: $line" ;; esac
  assert_grep 'doorbell ensure' "$dir/doorbell.log" "lock-owning UserPromptSubmit did not ensure the doorbell owner"
  pass "Kiro primary UserPromptSubmit: ensures the doorbell owner and its published line forbids a model-run arm"
}
test_published_line_forbids_a_model_arm

test_stop_falls_back_only_when_no_owner_can_run() {
  local dir="$TMP_ROOT/stop-rc" out rc
  make_ensure_case "$dir"
  printf '1\n' > "$dir/needed"
  for rc in 4 1; do
    printf '%s\n' "$rc" > "$dir/doorbell.rc"
    rm -f "$dir/arm.log" "$dir/doorbell.log"
    out=$(run_ensure_hook "$dir" Stop self) || fail "Stop rc=$rc scenario failed: $out"
    assert_grep 'doorbell ensure' "$dir/doorbell.log" "Stop rc=$rc did not try the doorbell owner"
    sleep 1
    assert_absent "$dir/arm.log" "Stop fell back to an arm when the doorbell owner exited $rc"
  done
  pass "Kiro primary Stop: no fallback arm when the doorbell owner is cooling down (4) or failed (1)"
}
test_stop_falls_back_only_when_no_owner_can_run
