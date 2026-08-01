#!/usr/bin/env bash
# Behavior tests for a GUI-capable relay task host: control-root/fmr-gui-lib.sh,
# the preflight the verb runs before it claims, and the queued dispatch that
# holds work a host could not take yet.
#
# Hermetic. The live cross-machine evidence lives in docs/relay-gui-host.md; what
# these tests protect are the invariants whose failure mode is expensive and
# quiet:
#   - a refusal must happen BEFORE the claim, because a claimed-then-failed task
#     tells the control machine the work has an owner when it has none;
#   - a screen state that cannot be READ must refuse, not pass - an unreadable
#     probe is not an unlocked screen;
#   - "never started" and "started and then died" must be distinguishable,
#     because the operator does different things about them;
#   - a transient refusal must hold the dispatch and a permanent one must not,
#     and ALREADY_CLAIMED must count as permanent even though it exits 0;
#   - a non-GUI host must not change by one byte, including needing none of the
#     GUI files deployed.
#
# The machine probes are driven through STUB EXECUTABLES on the verb's own
# configured PATH rather than through environment overrides in the library. The
# real deployment inherits no environment at all, so an env-driven switch could
# only ever be a test backdoor through a safety gate; a stub binary exercises the
# real decision code against a controlled answer instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-relay-gui)

# shellcheck source=control-root/fmr-gui-lib.sh
. "$ROOT/control-root/fmr-gui-lib.sh"
# shellcheck source=bin/fm-relay-lib.sh
. "$ROOT/bin/fm-relay-lib.sh"

IOREG_LOCKED='<key>IOConsoleUsers</key><array><dict>
		<key>CGSSessionScreenIsLocked</key>
		<true/>
		<key>kCGSSessionAuditIDKey</key>
		<integer>100023</integer>
</dict></array>'
IOREG_UNLOCKED='<key>IOConsoleUsers</key><array><dict>
		<key>CGSSessionScreenIsLocked</key>
		<false/>
		<key>kCGSSessionAuditIDKey</key>
		<integer>100023</integer>
</dict></array>'
# The shape after a login that has never been locked: the key is simply absent.
IOREG_NEVER_LOCKED='<key>IOConsoleUsers</key><array><dict>
		<key>kCGSSessionAuditIDKey</key>
		<integer>100023</integer>
</dict></array>'

# --- pure verdicts ------------------------------------------------------------

test_lock_verdict() {
  [ "$(fmr_gui_lock_verdict "$IOREG_LOCKED")" = locked ] \
    || fail "a locked console must read as locked"
  [ "$(fmr_gui_lock_verdict "$IOREG_UNLOCKED")" = unlocked ] \
    || fail "an explicitly unlocked console must read as unlocked"
  [ "$(fmr_gui_lock_verdict "$IOREG_NEVER_LOCKED")" = unlocked ] \
    || fail "a session never locked since login has no key and must read as unlocked"
  # The one that matters: an empty or unrecognisable probe is NOT an unlocked
  # screen. Treating it as one would dispatch onto a machine whose state is
  # unknown, which is exactly the mistake the preflight exists to prevent.
  [ "$(fmr_gui_lock_verdict "")" = unknown ] \
    || fail "an empty ioreg answer must read as unknown, not unlocked"
  [ "$(fmr_gui_lock_verdict "ioreg: command not found")" = unknown ] \
    || fail "an unreadable ioreg answer must read as unknown, not unlocked"
  pass "fmr_gui_lock_verdict: unreadable is unknown, absent key is unlocked"
}

test_ancestry_class() {
  local desktop indirect job
  desktop='4001 4000 /bin/zsh
4000 3999 /usr/bin/login
3999 1 /Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper'
  indirect='5001 5000 /bin/bash
5000 89470 -zsh
89470 1 tmux'
  job='6001 6000 /bin/bash
6000 1 /bin/bash'
  [ "$(fmr_gui_ancestry_class "$desktop")" = desktop ] \
    || fail "an .app bundle in the chain must classify as desktop"
  [ "$(fmr_gui_ancestry_class "$indirect")" = indirect ] \
    || fail "a multiplexer with no .app must classify as indirect, not desktop"
  [ "$(fmr_gui_ancestry_class "$job")" = launchd-job \
    ] || fail "a chain reaching launchd with neither must classify as launchd-job"
  [ "$(fmr_gui_ancestry_class "")" = launchd-job ] \
    || fail "an unreadable chain must classify as the refusing class, not a passing one"
  # An .app anywhere in the chain wins over a multiplexer that appears closer:
  # the question is whether desktop ancestry EXISTS, not what is nearest.
  [ "$(fmr_gui_ancestry_class "$(printf '7001 7000 tmux\n7000 1 /Applications/Foo.app/Contents/MacOS/Foo\n')")" = desktop ] \
    || fail "an .app behind a multiplexer must still classify as desktop"
  pass "fmr_gui_ancestry_class: desktop, indirect, and launchd-job are separated"
}

marker() {  # <pid> <asid> [provenance]
  printf 'socket=/tmp/s\nserver_pid=%s\nasid=%s\nprovenance=%s\nstarted_at=2026-08-01T10:00:00Z\n' \
    "$1" "$2" "${3:-desktop}"
}

test_session_verdict_distinguishes_never_started_from_died() {
  local v
  v=$(fmr_gui_session_verdict "" "" 100023)
  case "$v" in absent\ *) ;; *) fail "no marker must be 'absent', got [$v]" ;; esac
  # The distinction the design asks for: a marker with no live server is a
  # session that DIED, and the operator's next move differs from "start it".
  v=$(fmr_gui_session_verdict "$(marker 4242 100023)" "" 100023)
  case "$v" in dead\ *) ;; *) fail "a marker with no live server must be 'dead', got [$v]" ;; esac
  assert_contains "$v" "4242" "the dead verdict must name the server it expected"
  assert_contains "$v" "2026-08-01T10:00:00Z" "the dead verdict must say when it had started"
  v=$(fmr_gui_session_verdict "$(marker 4242 100023)" 9999 100023)
  case "$v" in replaced\ *) ;; *) fail "a different server on the socket must be 'replaced', got [$v]" ;; esac
  # A new desktop login gets a new audit session id, so the old session belongs
  # to a login that is gone even though its process is still alive.
  v=$(fmr_gui_session_verdict "$(marker 4242 100023)" 4242 100077)
  case "$v" in stale\ *) ;; *) fail "an audit-session change must be 'stale', got [$v]" ;; esac
  v=$(fmr_gui_session_verdict "$(marker 4242 100023)" 4242 100023)
  case "$v" in ok\ *) ;; *) fail "a live, matching session must be 'ok', got [$v]" ;; esac
  v=$(fmr_gui_session_verdict "socket=/tmp/s
server_pid=1" 1 100023)
  case "$v" in malformed\ *) ;; *) fail "a marker missing fields must be 'malformed', got [$v]" ;; esac
  pass "fmr_gui_session_verdict: absent, dead, replaced, stale, malformed, ok"
}

# --- the deployed verb, GUI host ----------------------------------------------

# Build a control root whose ioreg and tmux answers are stubs on the verb's own
# configured PATH, so the real preflight code runs against a controlled machine.
setup_gui_verb_host() {  # <tag> -> echoes the control root
  local tag=$1 base croot home stubs
  base="$TMP_ROOT/$tag"
  croot="$base/control-root"; home="$base/home"; stubs="$base/stubs"
  mkdir -p "$croot/verbs" "$croot/tasks" "$home/state" "$home/data" \
    "$base/fleet-root/tasks" "$base/fmroot/bin" "$stubs" "$home/projects/proj"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$croot/verbs/fmr-verb.sh"
  cp "$ROOT/control-root/fmr-gui-lib.sh" "$croot/fmr-gui-lib.sh"
  cp "$ROOT/control-root/fmr-host-session.sh" "$croot/fmr-host-session.sh"
  chmod 755 "$croot/verbs/fmr-verb.sh" "$croot/fmr-host-session.sh"
  cat > "$stubs/ioreg" <<STUB
#!/bin/bash
cat "$base/ioreg.out" 2>/dev/null || true
STUB
  cat > "$stubs/tmux" <<STUB
#!/bin/bash
[ -s "$base/tmux.pid" ] || exit 1
cat "$base/tmux.pid"
STUB
  chmod 755 "$stubs/ioreg" "$stubs/tmux"
  {
    printf 'FM_ROOT=%s\n' "$base/fmroot"
    printf 'FM_HOME=%s\n' "$home"
    printf 'HOME_DIR=%s\n' "$base"
    printf 'PATH=%s:/usr/bin:/bin\n' "$stubs"
    printf 'PROJECTS=%s\n' "$home/projects"
    printf 'FLEET_ROOT=%s\n' "$base/fleet-root"
    printf 'GUI=1\n'
    printf 'TMUX_SOCKET=%s\n' "$base/host.sock"
    printf 'HOST_SESSION=%s\n' "$croot/host-session"
  } > "$croot/config"
  printf '%s' "$croot"
}

gui_state() {  # <tag> <ioreg-text> <tmux-pid-or-empty> <marker-text-or-empty>
  local base="$TMP_ROOT/$1"
  printf '%s' "$2" > "$base/ioreg.out"
  printf '%s' "$3" > "$base/tmux.pid"
  if [ -n "$4" ]; then printf '%s' "$4" > "$base/control-root/host-session"
  else rm -f "$base/control-root/host-session"; fi
}

stage_brief() {  # <tag> <id>
  local base="$TMP_ROOT/$1"
  mkdir -p "$base/fleet-root/tasks/$2/in"
  printf 'a brief\n' > "$base/fleet-root/tasks/$2/in/brief.md"
}

test_gui_preflight_refuses_a_locked_screen() {
  local croot out
  croot=$(setup_gui_verb_host locked)
  gui_state locked "$IOREG_LOCKED" 4242 "$(marker 4242 100023)"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1)
  assert_contains "$out" "ERR guilocked" "a locked screen must refuse with a guilocked code"
  assert_contains "$out" "locked" "the refusal must say in plain words what is wrong"
  pass "fmr-verb preflight: a locked screen refuses"
}

test_gui_preflight_refuses_an_unreadable_screen_state() {
  local croot out
  croot=$(setup_gui_verb_host unreadable)
  gui_state unreadable "" 4242 "$(marker 4242 100023)"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1)
  assert_contains "$out" "ERR guilockunknown" \
    "an unreadable lock state must refuse rather than assume unlocked"
  pass "fmr-verb preflight: an unreadable lock state refuses"
}

test_gui_preflight_names_what_to_start_when_the_session_is_missing() {
  local croot out
  croot=$(setup_gui_verb_host nosession)
  gui_state nosession "$IOREG_UNLOCKED" "" ""
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1)
  assert_contains "$out" "ERR guisession" "a missing host session must refuse with a guisession code"
  assert_contains "$out" "no desktop host session has been started" \
    "the refusal must distinguish never-started from died"
  # The operator cannot act on "something is wrong"; the refusal has to carry the
  # command that fixes it.
  assert_contains "$out" "fmr-host-session.sh start" \
    "the refusal must name the exact command that starts what is missing"

  gui_state nosession "$IOREG_UNLOCKED" "" "$(marker 4242 100023)"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1)
  assert_contains "$out" "no longer running" "a marker with a dead server must say it died"
  pass "fmr-verb preflight: a missing or dead host session refuses and names the fix"
}

test_gui_preflight_passes_a_healthy_host() {
  local croot out
  croot=$(setup_gui_verb_host healthy)
  gui_state healthy "$IOREG_UNLOCKED" 4242 "$(marker 4242 100023)"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1) \
    || fail "a healthy GUI host must pass preflight: $out"
  assert_contains "$out" "OK preflight=ok" "a healthy GUI host must answer OK"
  assert_contains "$out" "locked=no" "the pass must state what it checked"
  pass "fmr-verb preflight: a healthy GUI host passes"
}

# The invariant with the most expensive failure mode: a refusal that claims first
# leaves the control machine believing the work has an owner.
test_gui_spawn_refuses_before_it_claims() {
  local croot out
  croot=$(setup_gui_verb_host beforeclaim)
  stage_brief beforeclaim t1
  gui_state beforeclaim "$IOREG_LOCKED" 4242 "$(marker 4242 100023)"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn t1 scout proj brief.md 2>&1)
  assert_contains "$out" "ERR guilocked" "a locked screen must refuse the spawn itself"
  assert_absent "$croot/tasks/t1" "the refused spawn must NOT have created a claim"

  gui_state beforeclaim "$IOREG_UNLOCKED" "" ""
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn t1 scout proj brief.md 2>&1)
  assert_contains "$out" "ERR guisession" "a missing host session must refuse the spawn itself"
  assert_absent "$croot/tasks/t1" "the refused spawn must NOT have created a claim"
  pass "fmr-verb spawn: a GUI refusal happens before the claim, not after"
}

test_gui_host_refuses_when_its_library_is_not_deployed() {
  local croot out
  croot=$(setup_gui_verb_host nolib)
  gui_state nolib "$IOREG_UNLOCKED" 4242 "$(marker 4242 100023)"
  rm -f "$croot/fmr-gui-lib.sh"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1)
  assert_contains "$out" "ERR guilib" \
    "a GUI host missing its preflight library must refuse, never skip the checks"
  pass "fmr-verb: GUI=1 without the library refuses instead of passing unchecked"
}

# A Phase 1 host must be untouched: no GUI files, no probes, no new behaviour.
test_non_gui_host_needs_nothing_new() {
  local croot base out
  croot=$(setup_gui_verb_host nongui)
  base="$TMP_ROOT/nongui"
  grep -v '^GUI=' "$croot/config" > "$croot/config.new" && mv "$croot/config.new" "$croot/config"
  rm -f "$croot/fmr-gui-lib.sh" "$croot/fmr-host-session.sh"
  gui_state nongui "$IOREG_LOCKED" "" ""
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" preflight 2>&1) \
    || fail "a non-GUI host must pass preflight with no GUI files at all: $out"
  assert_contains "$out" "gui=0" "a non-GUI host must report itself as such"
  stage_brief nongui t2
  # A locked screen and no host session must not stop a non-GUI host: it gets as
  # far as its own spawn, which fails only because this fixture has no firstmate.
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn t2 scout proj brief.md 2>&1)
  assert_not_contains "$out" "ERR gui" "a non-GUI host must not run any GUI check"
  assert_present "$base/home/data/t2/brief.md" "a non-GUI host must have reached its own spawn"
  pass "fmr-verb: a non-GUI host is unchanged and needs none of the GUI files"
}

# --- control side: dispatch classification ------------------------------------

test_dispatch_classification() {
  local c
  c=$(fm_relay_dispatch_class "OK spawned=t1" 0)
  [ "$c" = ok ] || fail "a successful spawn must classify as ok, got [$c]"
  c=$(fm_relay_dispatch_class "ERR guilocked the screen is locked" 1)
  case "$c" in retry\ *) ;; *) fail "a GUI refusal must be retryable, got [$c]" ;; esac
  assert_contains "$c" "guilocked" "the retry reason must carry the host's own words"
  # Any future gui* code is retryable without this side being taught about it.
  c=$(fm_relay_dispatch_class "ERR guisomethingnew whatever" 1)
  case "$c" in retry\ *) ;; *) fail "an unseen gui* code must still be retryable, got [$c]" ;; esac
  # No protocol line at all is what a sleeping or powered-off host produces.
  c=$(fm_relay_dispatch_class "Network error: connection refused" 1)
  case "$c" in retry\ *) ;; *) fail "a transport failure must be retryable, got [$c]" ;; esac
  assert_contains "$c" "asleep" "an unreachable host must be described as possibly asleep"
  c=$(fm_relay_dispatch_class "ERR noproject no project directory" 1)
  case "$c" in fail\ *) ;; *) fail "a permanent refusal must not be retried, got [$c]" ;; esac
  # The trap: ALREADY_CLAIMED exits ZERO. Reading the exit status alone would
  # file a live foreign task as a successful spawn and then write metadata from
  # a claim report.
  c=$(fm_relay_dispatch_class "ALREADY_CLAIMED task t1 is already claimed" 0)
  case "$c" in fail\ *) ;; *) fail "ALREADY_CLAIMED must be permanent even at exit 0, got [$c]" ;; esac
  pass "fm_relay_dispatch_class: transient, permanent, and the exit-0 refusal"
}

# --- control side: the queued dispatch and its retry --------------------------

# The retry runs the real library against a stub dispatcher placed beside a COPY
# of the library, because FM_RELAY_LIB_DIR is where the library found itself.
setup_queue_home() {  # <tag> -> echoes the home
  local tag=$1 home bin
  home="$TMP_ROOT/q-$tag"; bin="$home/bin"
  mkdir -p "$home/state" "$home/data" "$bin"
  cp "$ROOT/bin/fm-relay-lib.sh" "$bin/fm-relay-lib.sh"
  # The helm library is a hard dependency of the relay library, which refuses to
  # load without it rather than silently shipping unfenced calls.
  cp "$ROOT/bin/fm-helm-lib.sh" "$bin/fm-helm-lib.sh"
  printf '%s' "$home"
}

# Stands in for `fm-relay-host.sh dispatch`, including the part that matters to
# the retry: a held dispatch records WHY in the queue record, and the retry reads
# it from there rather than parsing the printed sentence.
stub_dispatcher() {  # <tag> <exit-code> <printed-line> [reason]
  local bin home
  home="$TMP_ROOT/q-$1"; bin="$home/bin"
  cat > "$bin/fm-relay-host.sh" <<STUB
#!/bin/bash
printf '%s\n' "$3"
if [ "$2" = 3 ]; then
  f="$home/state/\$2.relay-pending"
  { grep -v '^reason=' "\$f" 2>/dev/null; printf 'reason=%s\n' "${4:-}"; } > "\$f.t" && mv "\$f.t" "\$f"
fi
exit $2
STUB
  chmod 755 "$bin/fm-relay-host.sh"
}

queue_record() {  # <home> <id> <host>
  printf 'host=%s\nproject=p\nkind=scout\nharness=default\nmodel=default\neffort=default\nqueued_at=t\n' \
    "$3" > "$1/state/$2.relay-pending"
}

# The subshell is the point: it sources a COPY of the library so FM_RELAY_LIB_DIR
# resolves to the stub dispatcher beside it, without that leaking into the real
# library this file already sourced.
# shellcheck disable=SC2030,SC2034  # read by the library sourced on the next line
emit_with() {  # <tag> <home> <id>
  ( FM_RELAY_QUEUE_WAKE_AFTER=2
    # shellcheck source=/dev/null
    . "$TMP_ROOT/q-$1/bin/fm-relay-lib.sh"
    fm_relay_check_emit "$2" "$3" )
}

test_queued_dispatch_is_silent_while_the_host_keeps_refusing() {
  local home out
  home=$(setup_queue_home quiet)
  queue_record "$home" g1 macbox
  stub_dispatcher quiet 3 "held: g1 is queued for macbox" "guilocked the screen is locked"
  out=$(emit_with quiet "$home" g1)
  [ -z "$out" ] || fail "a first refusal must not wake anyone, got [$out]"
  assert_present "$home/state/g1.relay-pending" "a refused dispatch must stay queued"
  # Second refusal reaches the threshold and says so once.
  out=$(emit_with quiet "$home" g1)
  assert_contains "$out" "waiting for macbox" "a persistent refusal must eventually be reported"
  assert_contains "$out" "guilocked" "the report must carry the host's own reason"
  # Third refusal, same reason: already said, so silence again.
  out=$(emit_with quiet "$home" g1)
  [ -z "$out" ] || fail "the same reason must not wake repeatedly, got [$out]"
  # A CHANGED reason is news again: the screen was unlocked but now the session
  # is down, and hiding that behind the first alert would misreport it.
  stub_dispatcher quiet 3 "held: g1 is queued for macbox" "guisession no desktop host session"
  out=$(emit_with quiet "$home" g1)
  assert_contains "$out" "guisession" "a changed refusal reason must wake once more"
  pass "queued dispatch: silent while refused, reports once per distinct reason"
}

test_queued_dispatch_wakes_when_it_finally_starts() {
  local home out
  home=$(setup_queue_home go)
  queue_record "$home" g2 macbox
  stub_dispatcher go 3 "held: g2 is queued for macbox" "guilocked the screen is locked"
  emit_with go "$home" g2 >/dev/null
  # The host becomes available; the SAME check that was holding it dispatches it.
  stub_dispatcher go 0 "OK spawned=g2 trust=working"
  out=$(emit_with go "$home" g2)
  assert_contains "$out" "dispatched to macbox" "a dispatch that finally lands must wake the supervisor"
  assert_contains "$out" "g2" "the wake line must name the task"
  pass "queued dispatch: the backlog is picked up automatically once the host can take it"
}

test_queued_dispatch_does_not_silently_drop_permanent_failures() {
  local home out
  home=$(setup_queue_home hard)
  queue_record "$home" g3 macbox
  stub_dispatcher hard 1 "ERR noproject no project directory at /srv/projects/p"
  out=$(emit_with hard "$home" g3)
  assert_contains "$out" "cannot start" "a permanent failure must be reported immediately"
  # Reported once, then quiet - but never discarded behind the supervisor's back.
  out=$(emit_with hard "$home" g3)
  [ -z "$out" ] || fail "a reported permanent failure must not repeat, got [$out]"
  assert_present "$home/state/g3.relay-pending" \
    "queued work must survive a permanent failure so a supervisor can see it"
  pass "queued dispatch: a permanent failure is reported once and never silently dropped"
}

test_check_emit_returns_to_events_once_the_task_is_live() {
  local home out
  home=$(setup_queue_home live)
  queue_record "$home" g4 macbox
  stub_dispatcher live 0 "OK spawned=g4"
  emit_with live "$home" g4 >/dev/null
  # The real dispatcher removes the record; the stub cannot, so remove it here to
  # reach the state a landed dispatch leaves behind.
  rm -f "$home/state/g4.relay-pending"
  printf 'window=w\nworktree=/nowhere\nkind=scout\n' > "$home/state/g4.meta"
  out=$(emit_with live "$home" g4)
  # No host= line means this is not a relay task, so the events path declines
  # quietly. What matters is that the QUEUE path no longer owns the check.
  [ -z "$out" ] || fail "with no queued record the check must fall through to events, got [$out]"
  pass "fm_relay_check_emit: the queue owns the check only while work is queued"
}

# --- control side: registry, arming, and the queue CLI ------------------------

write_gui_registry() {  # <home>
  mkdir -p "$1/config"
  cat > "$1/config/relay-hosts.json" <<'EOF'
{
  "macbox": {
    "client_id": "cid-mac",
    "control_root": "/Users/x/.fm-relay/control-root",
    "fleet_root": "/Users/x/.fm-relay/fleet-root",
    "home": "/Users/x/.fm-relay/host-home",
    "root": "/Users/x/firstmate",
    "gui": true,
    "tmux_socket": "/tmp/tmux-501/default"
  },
  "box151": {
    "client_id": "cid-151",
    "control_root": "/srv/control-root",
    "fleet_root": "/srv/fleet-root",
    "home": "/srv/host-home",
    "root": "/srv/firstmate"
  }
}
EOF
}

test_registry_gui_fields() {
  local home
  home="$TMP_ROOT/reg"
  write_gui_registry "$home"
  # shellcheck source=bin/fm-relay-lib.sh
  . "$ROOT/bin/fm-relay-lib.sh"
  fm_relay_host_load "$home" macbox || fail "a GUI host record must load"
  fm_relay_host_is_gui || fail "gui:true must set the GUI flag"
  [ "$FM_RELAY_TMUX_SOCKET" = /tmp/tmux-501/default ] \
    || fail "tmux_socket mis-parsed: got '$FM_RELAY_TMUX_SOCKET'"
  [ "$FM_RELAY_HOST_SESSION" = /Users/x/.fm-relay/control-root/host-session ] \
    || fail "host_session must default under control_root: got '$FM_RELAY_HOST_SESSION'"
  # The Phase 1 record must keep working with none of these fields present, and
  # its absent optional fields must not shift the new ones in.
  fm_relay_host_load "$home" box151 || fail "a Phase 1 host record must still load"
  fm_relay_host_is_gui && fail "a record with no gui field must not be treated as a GUI host"
  [ -z "$FM_RELAY_TMUX_SOCKET" ] || fail "an absent tmux_socket must stay empty"
  pass "fm_relay_host_load: GUI fields parse and a Phase 1 record is unaffected"
}

test_check_make_arms_from_a_queued_dispatch() {
  local home out
  home="$TMP_ROOT/arm"
  mkdir -p "$home/state"
  write_gui_registry "$home"
  # No metadata at all: the task is queued, not live. Arming must still work,
  # because the check IS what retries the queued dispatch.
  queue_record "$home" q1 macbox
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" q1 2>&1) \
    || fail "arming a queued dispatch must succeed: $out"
  assert_present "$home/state/q1.check.sh" "the queued task must get a wake check"
  assert_present "$home/state/q1.check-trust" "the check must be bound to its bytes"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" q2 2>&1); rc=$?
  expect_code 1 "$rc" "a task with neither metadata nor a queued dispatch must refuse"
  assert_contains "$out" "queued dispatch" "the refusal must name both things it looked for"
  pass "fm-relay-check-make: arms a queued dispatch, refuses a task that is neither"
}

test_queue_cli_lists_and_cancels() {
  local home out
  home="$TMP_ROOT/cli"
  mkdir -p "$home/state" "$home/data"
  write_gui_registry "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-host.sh" queued 2>&1)
  assert_contains "$out" "no queued dispatches" "an empty queue must say so plainly"
  queue_record "$home" c1 macbox
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-host.sh" queued 2>&1)
  assert_contains "$out" "c1 host=macbox" "a queued dispatch must be listed with its host"
  : > "$home/state/c1.check.sh"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-host.sh" cancel c1 2>&1) \
    || fail "cancelling a queued dispatch must succeed: $out"
  assert_absent "$home/state/c1.relay-pending" "cancel must drop the queued record"
  assert_absent "$home/state/c1.check.sh" "cancel must drop the retry that would re-dispatch it"
  pass "fm-relay-host queued/cancel: the queue is inspectable and reversible"
}

# The REAL dispatch against a fake relay, not the stub dispatcher the retry tests
# use. That stub cannot see what dispatch does to the queue record, and it hid a
# real disagreement: dispatch deleted the record on a permanent failure while the
# retry path and the documentation both said it was kept.
#
# Both behaviours are correct, for different callers, which is why this pins
# them: the retry runs where nobody is watching, so it must keep the work; a
# first attempt from fm-spawn reported the failure to a human and armed no retry,
# so keeping it would leave a record nothing will ever act on.
# Enough of bifrost to reach the verb call: the file channel has to succeed and
# hash-match first, because dispatch stages the brief before it spawns.
fake_bifrost() {  # <dir> <exec-output> <exec-exit> <brief-sha256>
  mkdir -p "$1"
  cat > "$1/bifrost" <<STUB
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    write|delete) exit 0 ;;
    hash) printf 'sha256: %s\n' "$4"; exit 0 ;;
    exec) printf '%s\n' "$2"; exit $3 ;;
  esac
done
exit 0
STUB
  chmod 755 "$1/bifrost"
}

test_dispatch_keeps_the_queue_record_when_the_host_refuses_for_good() {
  local home out rc fake
  home="$TMP_ROOT/perm"
  mkdir -p "$home/state" "$home/data/p1"
  write_gui_registry "$home"
  printf 'a brief\n' > "$home/data/p1/brief.md"
  queue_record "$home" p1 box151
  fake="$home/fakebin"
  fake_bifrost "$fake" "ERR noproject no project directory at /srv/projects/nope" 1 \
    "$(fm_relay_sha256 "$home/data/p1/brief.md")"
  rc=0
  out=$(FM_HOME="$home" FM_RELAY_BIFROST="$fake/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" dispatch p1 2>&1) || rc=$?
  expect_code 1 "$rc" "a permanent refusal must exit 1, not the retryable 3"
  assert_present "$home/state/p1.relay-pending" \
    "dispatch must KEEP the queued record; the retry runs where nobody is watching"
  assert_contains "$(cat "$home/state/p1.relay-pending")" "reason=ERR noproject" \
    "the record must carry why it cannot start, so the queue listing can show it"
  assert_absent "$home/state/p1.meta" "a failed dispatch must not write task metadata"
  pass "fm-relay-host dispatch: a permanent refusal keeps the queued record and records why"
}

test_dispatch_holds_the_record_when_the_relay_cannot_answer() {
  local home out rc fake
  home="$TMP_ROOT/unreach"
  mkdir -p "$home/state" "$home/data/u1"
  write_gui_registry "$home"
  printf 'a brief\n' > "$home/data/u1/brief.md"
  queue_record "$home" u1 box151
  fake="$home/fakebin"
  # No protocol line at all: the shape a sleeping or powered-off host produces.
  fake_bifrost "$fake" "Network error: connection refused" 1 \
    "$(fm_relay_sha256 "$home/data/u1/brief.md")"
  rc=0
  out=$(FM_HOME="$home" FM_RELAY_BIFROST="$fake/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" dispatch u1 2>&1) || rc=$?
  expect_code 3 "$rc" "an unreachable host must exit 3 so the dispatch is retried"
  assert_contains "$out" "held:" "the caller must be told the work is held, not lost"
  assert_present "$home/state/u1.relay-pending" "an unreachable host must leave the work queued"
  assert_contains "$(cat "$home/state/u1.relay-pending")" "asleep" \
    "the recorded reason must describe the unreachable host"
  pass "fm-relay-host dispatch: an unreachable host holds the dispatch at exit 3"
}

test_queue_refuses_to_shadow_a_live_task() {
  local home out rc
  home="$TMP_ROOT/shadow"
  mkdir -p "$home/state" "$home/data/s1"
  write_gui_registry "$home"
  printf 'a brief\n' > "$home/data/s1/brief.md"
  printf 'window=w\nworktree=/nowhere\nhost=macbox\n' > "$home/state/s1.meta"
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-host.sh" queue macbox s1 proj --scout 2>&1) || rc=$?
  expect_code 1 "$rc" "queueing over a task that already has metadata must refuse"
  assert_contains "$out" "already has metadata" "the refusal must say what is in the way"
  assert_absent "$home/state/s1.relay-pending" "a refused queue must write nothing"
  pass "fm-relay-host queue: refuses to shadow a task that is already live"
}

# --- deployment ----------------------------------------------------------------

test_deploy_local_ships_gui_files_only_for_a_gui_host() {
  local home out croot
  home="$TMP_ROOT/dep"
  mkdir -p "$home/config"
  cat > "$home/config/relay-hosts.json" <<EOF
{
  "macbox": {
    "client_id": "c", "control_root": "$home/mac/control-root",
    "fleet_root": "$home/mac/fleet-root", "home": "$home/mac/host-home",
    "root": "$ROOT", "gui": true, "tmux_socket": "/tmp/sock"
  },
  "box151": {
    "client_id": "c", "control_root": "$home/lin/control-root",
    "fleet_root": "$home/lin/fleet-root", "home": "$home/lin/host-home",
    "root": "$ROOT"
  }
}
EOF
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-conn.sh" deploy-local macbox 2>&1) \
    || fail "deploy-local for a GUI host must succeed: $out"
  croot="$home/mac/control-root"
  assert_present "$croot/verbs/fmr-verb.sh" "the verb must be installed"
  assert_present "$croot/fmr-gui-lib.sh" "a GUI host must get the preflight library"
  assert_present "$croot/fmr-host-session.sh" "a GUI host must get the host-session manager"
  assert_contains "$(cat "$croot/config")" "GUI=1" "a GUI host config must declare GUI"
  assert_contains "$(cat "$croot/config")" "TMUX_SOCKET=/tmp/sock" \
    "a GUI host config must pin the host session's socket"
  assert_contains "$out" "fmr-host-session.sh start" \
    "deploy-local must tell the operator what to start next"

  FM_HOME="$home" "$ROOT/bin/fm-relay-conn.sh" deploy-local box151 >/dev/null 2>&1 \
    || fail "deploy-local for a non-GUI host must succeed"
  croot="$home/lin/control-root"
  assert_present "$croot/verbs/fmr-verb.sh" "the verb must be installed for a non-GUI host too"
  assert_absent "$croot/fmr-gui-lib.sh" "a non-GUI host must NOT receive the GUI library"
  assert_absent "$croot/fmr-host-session.sh" "a non-GUI host must NOT receive the session manager"
  assert_not_contains "$(cat "$croot/config")" "GUI=" "a non-GUI host config must be unchanged"
  pass "fm-relay-conn deploy-local: GUI files ship only where they mean something"
}

# Both host-session tests drive the real script against a stubbed ancestry, and
# they have to: `ps -o comm=` prints the full executable path on macOS but only
# the basename on Linux, so a test that read the REAL chain would assert one
# thing on a developer's Mac and the opposite on a Linux CI runner. Stubbing the
# probe keeps the decision under test and the platform out of it.
write_ps_stub() {  # <dir> <exe-of-the-only-ancestor>
  mkdir -p "$1"
  cat > "$1/ps" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in -p) next=1 ;; *) [ "\${next:-}" = 1 ] && { pid=\$a; next=0; } ;; esac; done
case "\$pid" in
  1) echo "        1 /sbin/launchd" ;;
  *) echo "        1 $2" ;;
esac
STUB
  chmod 755 "$1/ps"
}

test_host_session_refuses_launchd_ancestry() {
  local croot out fake
  croot=$(setup_gui_verb_host session)
  fake="$TMP_ROOT/session/fakeps"
  # A chain that reaches launchd with no desktop app: the one shape known to
  # wedge every agent it would ever start.
  write_ps_stub "$fake" /bin/bash
  out=$(PATH="$fake:$PATH" "$croot/fmr-host-session.sh" start --control-root "$croot" 2>&1); rc=$?
  expect_code 1 "$rc" "starting a host session from launchd ancestry must refuse"
  assert_contains "$out" "REFUSED" "the refusal must be unmistakable"
  assert_contains "$out" "wedges permanently" "the refusal must say why, not just that"
  assert_contains "$out" "terminal window on this machine's desktop" \
    "the refusal must say what to do instead"
  assert_absent "$croot/host-session" "a refused start must not leave a marker claiming success"
  pass "fmr-host-session start: refuses the one ancestry that wedges every agent"
}

test_host_session_start_status_stop_roundtrip() {
  local croot out sock fake rc
  croot=$(setup_gui_verb_host roundtrip)
  sock="$TMP_ROOT/roundtrip/host.sock"
  command -v tmux >/dev/null 2>&1 || { pass "fmr-host-session: skipped, no tmux"; return 0; }
  fake="$TMP_ROOT/roundtrip/fakeprobe"
  write_ps_stub "$fake" "/Applications/Term.app/Contents/MacOS/Term"
  # The console probe is macOS-only too, so the audit session id is stubbed for
  # the same reason as the ancestry. tmux and its socket stay real.
  cat > "$fake/ioreg" <<STUB
#!/bin/bash
cat <<'PLIST'
$IOREG_UNLOCKED
PLIST
STUB
  chmod 755 "$fake/ioreg"
  run_hs() { PATH="$fake:$PATH" "$croot/fmr-host-session.sh" "$@" --control-root "$croot" 2>&1; }

  out=$(run_hs start) || fail "starting a host session must succeed: $out"
  assert_present "$croot/host-session" "start must record a marker"
  assert_contains "$(cat "$croot/host-session")" "socket=$sock" "the marker must record its socket"
  assert_contains "$(cat "$croot/host-session")" "provenance=desktop" \
    "a start from desktop ancestry must record that provenance"
  out=$(run_hs status) || fail "status on a live host session must succeed: $out"
  assert_contains "$out" "ok desktop host session" "status must report a live session as ok"
  # Idempotent: starting twice must not stack servers or rewrite a good marker.
  out=$(run_hs start) || fail "starting twice must be a no-op, not an error: $out"
  assert_contains "$out" "already running" "a second start must say it is already running"
  # The distinction the design turns on: kill the server behind its back and the
  # answer must be "died", not "never started".
  tmux -S "$sock" kill-server 2>/dev/null
  out=$(run_hs status); rc=$?
  expect_code 1 "$rc" "status on a dead host session must report failure"
  assert_contains "$out" "dead the desktop host session" \
    "a killed server must read as died, not as never started"
  run_hs start >/dev/null
  run_hs stop >/dev/null
  assert_absent "$croot/host-session" "stop must remove the marker"
  out=$(run_hs status); rc=$?
  expect_code 1 "$rc" "status after stop must report failure"
  assert_contains "$out" "absent" "status after stop must report the session as never-started"
  unset -f run_hs
  pass "fmr-host-session: start, status, died-vs-never-started, idempotent restart, stop"
}

# An adopted server was not created here, and on the machine this was built for
# it is the captain's own fleet. Killing it would take every running agent.
test_host_session_stop_refuses_to_kill_an_adopted_server() {
  local croot out
  croot=$(setup_gui_verb_host adopted)
  printf 'socket=/tmp/whatever\nserver_pid=424242\nasid=100023\nprovenance=adopted\nstarted_at=t\n' \
    > "$croot/host-session"
  out=$("$croot/fmr-host-session.sh" stop --control-root "$croot" 2>&1)
  assert_contains "$out" "REFUSED" "stopping an adopted server must refuse"
  assert_contains "$out" "left alone" "the refusal must say the server was not touched"
  assert_absent "$croot/host-session" "the marker must still be cleared"
  pass "fmr-host-session stop: never kills a server it did not start"
}

test_brief_gui_host_variant() {
  local home brief out rc
  home="$TMP_ROOT/briefgui"
  mkdir -p "$home/data" "$home/state"
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" b1 proj --scout --gui-host 2>&1) || rc=$?
  expect_code 1 "$rc" "--gui-host without a remote host variant must refuse"
  assert_absent "$home/data/b1/brief.md" "a refused brief must not be written"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" g1 proj --scout \
    --host-home /srv/h --host-root /srv/r --gui-host >/dev/null
  brief=$(cat "$home/data/g1/brief.md")
  assert_contains "$brief" "This machine has a real screen" "the GUI brief must carry the graphical contract"
  assert_contains "$brief" "never the one the machine owner is using" \
    "the GUI brief must protect the machine owner's own browser"
  assert_contains "$brief" "layer 0" "the GUI brief must require window-existence proof"
  assert_contains "$brief" "# Where you are running" "the GUI brief must still be a remote-host brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" plain proj --scout \
    --host-home /srv/h --host-root /srv/r >/dev/null
  assert_not_contains "$(cat "$home/data/plain/brief.md")" "This machine has a real screen" \
    "a remote brief without --gui-host must not carry the graphical contract"
  pass "fm-brief --gui-host: adds the graphical contract only where asked"
}

test_lock_verdict
test_ancestry_class
test_session_verdict_distinguishes_never_started_from_died
test_gui_preflight_refuses_a_locked_screen
test_gui_preflight_refuses_an_unreadable_screen_state
test_gui_preflight_names_what_to_start_when_the_session_is_missing
test_gui_preflight_passes_a_healthy_host
test_gui_spawn_refuses_before_it_claims
test_gui_host_refuses_when_its_library_is_not_deployed
test_non_gui_host_needs_nothing_new
test_dispatch_classification
test_queued_dispatch_is_silent_while_the_host_keeps_refusing
test_queued_dispatch_wakes_when_it_finally_starts
test_queued_dispatch_does_not_silently_drop_permanent_failures
test_check_emit_returns_to_events_once_the_task_is_live
test_registry_gui_fields
test_check_make_arms_from_a_queued_dispatch
test_queue_cli_lists_and_cancels
test_dispatch_keeps_the_queue_record_when_the_host_refuses_for_good
test_dispatch_holds_the_record_when_the_relay_cannot_answer
test_queue_refuses_to_shadow_a_live_task
test_deploy_local_ships_gui_files_only_for_a_gui_host
test_host_session_refuses_launchd_ancestry
test_host_session_start_status_stop_roundtrip
test_host_session_stop_refuses_to_kill_an_adopted_server
test_brief_gui_host_variant

