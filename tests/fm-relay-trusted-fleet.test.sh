#!/usr/bin/env bash
# Behavior tests for the captain-trusted fixed fleet relationship: the
# `trusted_full_access` host-record field, the pairing modes it selects in
# bin/fm-relay-conn.sh, the idempotent `ensure` reconnect, and the two sweeps
# bin/fm-bootstrap.sh runs on top of them - relay reconnect and helm task
# adoption.
#
# Hermetic. What these protect is the pair of properties that are cheap to break
# and expensive to notice:
#   - a host the captain did NOT mark can never end up keeping a full-access
#     authorization, by any path, including the automatic ones. Every negative
#     case below asserts the absence of a `remote conn up` call, not just an
#     unhappy exit code, because the damage is the grant and not the message;
#   - a reconnect must reuse a healthy link. `conn up` ADDS a grant rather than
#     reusing one (measured, docs/relay-host.md), so a sweep that paired
#     unconditionally at every session start would accumulate exactly the
#     authorizations this layer exists to remove.
#
# The stub bifrost here models the CONNECTION LIFECYCLE, which the one in
# tests/fm-helm.test.sh deliberately does not: it starts disconnected, `conn up`
# connects it, `conn down` disconnects it, and `exec` against a disconnected stub
# produces a transport failure with no protocol line - the exact shape a lapsed
# 24-hour grant session produces on the real relay. It also logs every
# invocation, which is what lets a test assert that nothing was paired.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-relay-trusted)
FLEET=trustfleet

# The ambient runtime markers must not leak into the backend detection bootstrap
# runs, for the same reason tests/fm-bootstrap.test.sh unsets them.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

# shellcheck source=bin/fm-relay-lib.sh disable=SC1091
. "$ROOT/bin/fm-relay-lib.sh"

BIFROST_STATE="$TMP_ROOT/bifrost-state"
export FM_TEST_BIFROST_HOME="$BIFROST_STATE"
mkdir -p "$BIFROST_STATE"

make_stub_bifrost() {  # <bin-dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/bifrost" <<'SH'
#!/usr/bin/env bash
# Stub Bifrost with a connection lifecycle. Only the shapes firstmate uses.
set -u
S=${FM_TEST_BIFROST_HOME:?stub bifrost needs FM_TEST_BIFROST_HOME}
mkdir -p "$S"
printf '%s\n' "$*" >> "$S/calls.log"

if [ "${1:-}" = sync ] && [ "${2:-}" = status ]; then
  echo "Authorized: true"
  exit 0
fi

mode=; text=; prev=; conn_sub=
for a in "$@"; do
  [ "$prev" = "--shell-text" ] && text=$a
  case "$a" in
    exec) [ -z "$mode" ] && mode=exec ;;
    conn) [ -z "$mode" ] && mode=conn ;;
  esac
  if [ "$mode" = conn ] && [ -z "$conn_sub" ]; then
    case "$a" in up|down) conn_sub=$a ;; esac
  fi
  prev=$a
done

case "$mode" in
  conn)
    case "$conn_sub" in
      up)
        # A revoked or unusable key: the peer refuses and nothing is created.
        if [ -f "$S/refuse-up" ]; then
          echo "bifrost: remote rejected the device key (401 unauthorized)" >&2
          exit 1
        fi
        : > "$S/connected"
        echo "connected: grant session established"
        exit 0 ;;
      down) rm -f "$S/connected"; echo "disconnected"; exit 0 ;;
    esac
    echo "stub: unsupported conn call: $*" >&2
    exit 2 ;;
  exec)
    [ -n "$text" ] || { echo "stub: no shell text" >&2; exit 2; }
    if [ ! -f "$S/connected" ]; then
      # No protocol line at all, which is what a dead link looks like from here.
      echo "Network error: no saved connection for that client id" >&2
      exit 1
    fi
    # An EMPTY environment, exactly like the real policy layer.
    env -i PATH="$PATH" bash -c "$text"
    exit $? ;;
esac
echo "stub: unsupported bifrost call: $*" >&2
exit 2
SH
  chmod +x "$dir/bifrost"
}

# A toolchain complete enough that bootstrap's own tool detection stays quiet
# about everything this suite is not testing.
make_fake_toolchain() {  # <dir> -> echoes the fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh gh-axi chrome-devtools-axi lavish-axi \
    quota-axi treehouse no-mistakes
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && printf '%s\n' 'Usage: treehouse get [--lease]'
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = watch ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage:' '  no-mistakes watch --pr <url> [flags]'
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '0.9.0\n'; exit 0; }
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  make_stub_bifrost "$fakebin"
  printf '%s\n' "$fakebin"
}

FAKEBIN=$(make_fake_toolchain "$TMP_ROOT")
STUB_PATH="$FAKEBIN:$BASE_PATH"

calls_log() { printf '%s' "$BIFROST_STATE/calls.log"; }
reset_calls() { : > "$(calls_log)"; }
conn_up_count() {
  # `grep -c` prints 0 AND exits 1 when it matches nothing, so a `|| printf 0`
  # fallback would emit two counts and every arithmetic comparison below would
  # fail on a syntax error rather than on the property under test.
  local n
  n=$(grep -c 'conn up' "$(calls_log)" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
link_up() { : > "$BIFROST_STATE/connected"; }
link_down() { rm -f "$BIFROST_STATE/connected"; }

assert_no_pairing() {  # <what>
  local n
  n=$(conn_up_count)
  [ "$n" -eq 0 ] || {
    cat "$(calls_log)" >&2
    fail "$1: an authorization was created ($n conn up call(s)); it must not have been"
  }
}

# --- the two machines ---------------------------------------------------------
#
# `box` is this machine and the anchor; `mac` is the peer with a real screen, no
# inbound SSH, and the captain's trust declaration. That is the real fleet's
# asymmetry, and it is the asymmetry every case below turns on.

write_peer_record() {  # <home> <peer> <peer-root> <extra-json-lines>
  local home=$1 peer=$2 proot=$3 extra=$4
  mkdir -p "$home/config"
  cat > "$home/config/relay-hosts.json" <<EOF
{
  "$peer": {
    "client_id": "cid-$peer",
    "control_root": "$proot/cr",
    "fleet_root": "$proot/fr",
    "home": "$proot",
    "root": "$ROOT",
    "path": "$STUB_PATH",
    "key": "$home/keys/$peer.key",
    "fleet": "$FLEET"$extra
  }
}
EOF
  mkdir -p "$home/keys"
  printf 'fake-device-key\n' > "$home/keys/$peer.key"
}

# A deployed control root for <machine>, whose verb runs against that machine's
# own home. `gui` also deploys the GUI library and points the verb's PATH at a
# stub `ioreg` reporting an unlocked console, so the only thing left for its
# preflight to complain about is the desktop host session - which is exactly the
# one action this side cannot perform.
build_machine() {  # <root> <machine> <gui|nogui>
  local root=$1 m=$2 gui=$3 home="$1/$2"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$home/cr/verbs" "$home/cr/tasks" "$home/fr/tasks"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$home/cr/verbs/fmr-verb.sh"
  chmod 755 "$home/cr/verbs/fmr-verb.sh"
  {
    printf 'FM_ROOT=%s\n' "$ROOT"
    printf 'FM_HOME=%s\n' "$home"
    printf 'HOME_DIR=%s\n' "$home"
    printf 'PATH=%s\n' "$STUB_PATH"
    printf 'PROJECTS=%s\n' "$home/projects"
    printf 'FLEET_ROOT=%s\n' "$home/fr"
    printf 'LANG=en_US.UTF-8\n'
  } > "$home/cr/config"
  if [ "$gui" = gui ]; then
    cp "$ROOT/control-root/fmr-gui-lib.sh" "$home/cr/fmr-gui-lib.sh"
    {
      printf 'GUI=1\n'
      printf 'TMUX_SOCKET=%s\n' "$home/cr/host.sock"
      printf 'HOST_SESSION=%s\n' "$home/cr/host-session"
    } >> "$home/cr/config"
  fi
  cat > "$home/config/fleet.json" <<EOF
{ "fleet": "$FLEET", "machine": "$m", "control_root": "$home/cr", "anchor": "box" }
EOF
}

# `ioreg` answering "unlocked", so a GUI preflight gets past the screen check and
# lands on the host-session question. A stub binary on the verb's own PATH, not
# an environment override, for the reason tests/fm-relay-gui-host.test.sh states:
# the real deployment inherits no environment, so an env switch could only ever
# be a backdoor through a safety gate.
install_unlocked_ioreg() {
  cat > "$FAKEBIN/ioreg" <<'SH'
#!/usr/bin/env bash
cat <<'XML'
<key>IOConsoleUsers</key><array><dict>
	<key>CGSSessionScreenIsLocked</key>
	<false/>
	<key>kCGSSessionAuditIDKey</key>
	<integer>100023</integer>
</dict></array>
XML
SH
  chmod +x "$FAKEBIN/ioreg"
}

BOX="$TMP_ROOT/box"
MAC="$TMP_ROOT/mac"
build_machine "$TMP_ROOT" box nogui
build_machine "$TMP_ROOT" mac gui
install_unlocked_ioreg

# The trust declaration under test. `mac` has NO ssh route, which is the whole
# situation: nothing on this side can tighten a grant there.
mark_trusted() { write_peer_record "$BOX" mac "$MAC" ',
    "gui": true,
    "trusted_full_access": true'; }
mark_untrusted() { write_peer_record "$BOX" mac "$MAC" ',
    "gui": true'; }

conn() {  # <args...>
  PATH="$STUB_PATH" FM_HOME="$BOX" "$ROOT/bin/fm-relay-conn.sh" "$@" 2>&1
}

# FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home so it
# stays inert; every line this suite asserts on is on bootstrap's stdout, and the
# stderr that a non-repo root produces is not part of any contract here.
bootstrap() {
  PATH="$STUB_PATH" FM_HOME="$BOX" FM_ROOT_OVERRIDE="$BOX" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

helm() {  # <machine> <args...>
  local m=$1
  shift
  PATH="$STUB_PATH" FM_HOME="$TMP_ROOT/$m" "$ROOT/bin/fm-helm.sh" "$@" 2>&1
}

lease_holder() {  # <machine>
  grep '^holder=' "$TMP_ROOT/$1/cr/helm/lease" 2>/dev/null | cut -d= -f2- || printf 'none'
}

# --- 1. the schema ------------------------------------------------------------

test_trust_is_one_explicit_field() {
  mark_trusted
  fm_relay_host_load "$BOX" mac || fail "a trusted record must load"
  fm_relay_host_trusts_full_access || fail "trusted_full_access:true must select the trusted mode"
  [ "$FM_RELAY_FLEET" = "$FLEET" ] \
    || fail "the new last field must not shift fleet: got '$FM_RELAY_FLEET'"
  [ -z "$FM_RELAY_SSH" ] || fail "this fixture must have no ssh route"

  # Absent, and explicitly false, are both the narrow default.
  mark_untrusted
  fm_relay_host_load "$BOX" mac || fail "a record without the field must load"
  fm_relay_host_trusts_full_access && fail "an absent trusted_full_access must NOT select the trusted mode"
  [ "$FM_RELAY_FLEET" = "$FLEET" ] || fail "fleet mis-parsed when trusted_full_access is absent"
  write_peer_record "$BOX" mac "$MAC" ',
    "gui": true,
    "trusted_full_access": false'
  fm_relay_host_load "$BOX" mac || fail "an explicitly false record must load"
  fm_relay_host_trusts_full_access && fail "trusted_full_access:false must NOT select the trusted mode"
  pass "trusted_full_access: one explicit field, absent and false are both narrow"
}

# Off is the safe reading of an unreadable value, but reading it silently would
# leave a captain who wrote "yes" believing the trust is on while the narrow path
# quietly stayed in force - and then debugging the wrong machine.
test_a_malformed_trust_value_is_refused_not_guessed() {
  local out rc=0
  write_peer_record "$BOX" mac "$MAC" ',
    "trusted_full_access": "yes"'
  out=$(fm_relay_host_load "$BOX" mac 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-boolean trusted_full_access must refuse the record"
  assert_contains "$out" "trusted_full_access must be the JSON literal true or false" \
    "the refusal must name the field and the accepted values"
  pass "trusted_full_access: a non-boolean value is refused, never guessed at"
}

# --- 2. the negative case, which is the one that matters ----------------------

test_an_unmarked_host_can_never_keep_full_access() {
  local out rc

  # The universal assertion itself is untouched: it is what every narrow host
  # still passes through, and a single full-access grant still fails it.
  fm_relay_audit_grants_text 'binding: {"policy_ids":["fm-relay-verbs"]}' \
    || fail "an all-narrow grant list must still pass the universal audit"
  fm_relay_audit_grants_text 'binding: {"policy_ids":["ssh-key-full-access"]}' \
    && fail "one full-access grant must still fail the universal audit"

  mark_untrusted
  link_down
  reset_calls
  rc=0
  out=$(conn up mac) || rc=$?
  [ "$rc" -ne 0 ] || fail "up on an unmarked host with no ssh route must refuse"
  assert_contains "$out" "tighten-local" "the refusal must name the two-operator repair"
  assert_no_pairing "up on an unmarked no-ssh host"

  reset_calls
  rc=0
  out=$(conn ensure mac) || rc=$?
  [ "$rc" -ne 0 ] || fail "ensure on an unmarked host with no ssh route must refuse"
  assert_contains "$out" "does not carry trusted_full_access" \
    "the refusal must say which declaration is missing"
  assert_contains "$out" "tighten-local" "the refusal must name the action and the machine it belongs to"
  assert_no_pairing "ensure on an unmarked no-ssh host"

  # And the automatic path cannot do it either, which is the case that would
  # otherwise reopen a machine quietly, once per session start, forever.
  reset_calls
  out=$(bootstrap)
  assert_contains "$out" "RELAY: mac:" "bootstrap must report an unreachable unmarked host"
  assert_no_pairing "bootstrap on an unmarked no-ssh host"
  pass "unmarked host: no path - by hand or automatic - ever keeps a full-access grant"
}

# --- 3. no-SSH pairing for the marked host ------------------------------------

test_trusted_no_ssh_host_pairs_from_here_alone() {
  local out
  mark_trusted
  link_down
  reset_calls
  out=$(conn up mac) || fail "up on a trusted no-ssh host must succeed: $out"
  assert_contains "$out" "OK pong" "the pairing must prove the verb channel answers"
  assert_contains "$out" "full-access authorization RETAINED" \
    "a retained grant must be stated out loud, not implied by silence"
  assert_contains "$out" "trusted_full_access" "the reason must name the declaration that allowed it"
  assert_not_contains "$out" "tighten-local" "a trusted pairing must not ask for a second operator"
  [ "$(conn_up_count)" -eq 1 ] || fail "a pairing must be exactly one conn up, got $(conn_up_count)"
  pass "trusted no-ssh host: pairs from the control machine with nobody at its keyboard"
}

# A pairing whose channel still does not answer is not a pairing. Without the
# tighten step there is no other assertion left, so this one has to hold.
test_a_trusted_pairing_that_does_not_answer_is_unpaired() {
  local out rc=0
  mark_trusted
  link_down
  # `conn up` reports success but the channel stays dead: the stub connects and
  # the verb path is then made unusable, which is the shape of a pairing against
  # a machine whose control root is gone.
  mv "$MAC/cr/verbs/fmr-verb.sh" "$MAC/cr/verbs/fmr-verb.sh.away"
  reset_calls
  out=$(conn up mac) || rc=$?
  mv "$MAC/cr/verbs/fmr-verb.sh.away" "$MAC/cr/verbs/fmr-verb.sh"
  [ "$rc" -ne 0 ] || fail "a pairing whose channel does not answer must fail"
  assert_contains "$out" "Unpairing" "a failed trusted pairing must unpair rather than leave the grant"
  [ -f "$BIFROST_STATE/connected" ] \
    && fail "a failed trusted pairing must not leave this caller connected"
  pass "trusted pairing: a channel that does not answer is unpaired, not reported as success"
}

# --- 4. idempotence -----------------------------------------------------------

test_ensure_reuses_a_healthy_link_and_creates_nothing() {
  local out
  mark_trusted
  link_up
  reset_calls
  out=$(conn ensure mac) || fail "ensure against a healthy link must succeed: $out"
  assert_contains "$out" "connected: mac" "a healthy link must be reported as reused"
  assert_no_pairing "ensure against a healthy link"

  # Ten times over is still nothing created, which is the property a session
  # start depends on.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do conn ensure mac >/dev/null || fail "repeat $i failed"; done
  assert_no_pairing "ten ensure runs against a healthy link"
  pass "ensure: a healthy link is reused and no second authorization is created"
}

test_ensure_repairs_a_dead_link_exactly_once() {
  local out
  mark_trusted
  link_down
  reset_calls
  out=$(conn ensure mac) || fail "ensure against a dead link must repair it: $out"
  assert_contains "$out" "reconnected: mac" "a repaired link must say so"
  assert_contains "$out" "full-access authorization retained by explicit trust" \
    "the repair must restate what it kept"
  [ "$(conn_up_count)" -eq 1 ] || fail "a repair must be exactly one conn up, got $(conn_up_count)"

  # And immediately afterwards it is the healthy case again.
  reset_calls
  conn ensure mac >/dev/null || fail "ensure after a repair must reuse the link"
  assert_no_pairing "ensure immediately after a repair"
  pass "ensure: a dead link is repaired with exactly one pairing, then reused"
}

# --- 5. identity material that is missing or revoked --------------------------

test_ensure_never_claims_a_recovery_it_did_not_make() {
  local out rc
  mark_trusted
  link_down

  # Missing key file: nothing to pair with.
  mv "$BOX/keys/mac.key" "$BOX/keys/mac.key.away"
  reset_calls
  rc=0
  out=$(conn ensure mac) || rc=$?
  mv "$BOX/keys/mac.key.away" "$BOX/keys/mac.key"
  [ "$rc" -ne 0 ] || fail "ensure with no key material must fail"
  assert_contains "$out" "is missing" "the refusal must name the missing key file"
  assert_contains "$out" "out of band" "the refusal must name the one-time action that fixes it"
  assert_not_contains "$out" "reconnected" "a failure must never report a reconnect"
  assert_no_pairing "ensure with no key material"

  # Key present, peer refuses it: a revoked key.
  : > "$BIFROST_STATE/refuse-up"
  reset_calls
  rc=0
  out=$(conn ensure mac) || rc=$?
  rm -f "$BIFROST_STATE/refuse-up"
  [ "$rc" -ne 0 ] || fail "ensure must fail when the peer rejects the key"
  assert_contains "$out" "401" "the peer's own refusal must reach the operator"
  assert_not_contains "$out" "reconnected" "a rejected key must never report a reconnect"
  pass "ensure: missing and revoked key material report the action needed, never a recovery"
}

# --- 6. bootstrap recovery ----------------------------------------------------

test_bootstrap_restores_a_trusted_link_and_says_so() {
  local out
  mark_trusted
  link_down
  reset_calls
  out=$(bootstrap)
  assert_contains "$out" "BOOTSTRAP_INFO: relay mac: reconnected" \
    "a restored link is a completed fact, not an action for the agent"
  assert_not_contains "$out" "RELAY: mac: not answering" \
    "a link that was restored must not also be reported as broken"
  [ "$(conn_up_count)" -eq 1 ] || fail "bootstrap must pair exactly once, got $(conn_up_count)"

  # The next session start finds it healthy and creates nothing.
  reset_calls
  out=$(bootstrap)
  assert_no_pairing "a second bootstrap run against a healthy link"
  assert_not_contains "$out" "RELAY: mac" "a healthy trusted host must draw no relay line"
  pass "bootstrap: restores a lapsed trusted link once, then leaves it alone"
}

# A second concurrent session must never create an authorization on a peer while
# the session holding the lock is doing the same thing.
test_detect_only_bootstrap_never_pairs() {
  local out
  mark_trusted
  link_down
  reset_calls
  out=$(PATH="$STUB_PATH" FM_HOME="$BOX" FM_ROOT_OVERRIDE="$BOX" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "the session holding the fleet lock owns the reconnect" \
    "a read-only session must say who owns the repair"
  assert_no_pairing "a detect-only bootstrap run"
  pass "bootstrap: a read-only session reports the dead link and pairs nothing"
}

# The trusted grant is expected, so bootstrap must not report it as a fault at
# every session start - that is how a real full-access line stops being read.
test_a_trusted_host_grant_is_not_reported_as_a_fault() {
  local out
  mark_trusted
  link_up
  out=$(bootstrap)
  assert_not_contains "$out" "full-access authorization is live" \
    "a configured full-access grant must not be reported as a fault"
  out=$(conn audit mac) || true
  assert_contains "$out" "RELAY_GRANT: mac keeps its full-access authorization by explicit captain trust" \
    "audit must state the retained grant plainly rather than hiding it"
  pass "trusted host: its grant is stated by audit and never nagged about at session start"
}

# --- 7. the one action this side cannot perform -------------------------------

test_the_remaining_gui_setup_action_is_named_precisely() {
  local out
  mark_trusted
  rm -f "$MAC/cr/host-session"
  link_down
  reset_calls
  out=$(bootstrap)
  assert_contains "$out" "BOOTSTRAP_INFO: relay mac: reconnected" "the link must still be restored"
  assert_contains "$out" "RELAY: mac:" "the remaining action must be reported"
  assert_contains "$out" "fmr-host-session.sh start" \
    "the remaining action must name the exact command, on the machine that must run it"
  pass "GUI host: the one action this side cannot perform is named, not left to be discovered"
}

# --- 8. post-handover adoption ------------------------------------------------

seed_peer_task() {  # <id>
  local id=$1
  mkdir -p "$MAC/state"
  cat > "$MAC/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$MAC/wt-$id
project=$MAC/projects/alpha
harness=claude
kind=scout
mode=local-only
yolo=off
EOF
  printf 'working: started\n' > "$MAC/state/$id.status"
}

clear_control_side() {
  rm -f "$BOX"/state/*.meta "$BOX"/state/*.check.sh "$BOX"/state/*.check-trust \
    "$BOX"/state/*.relay-ack "$BOX"/state/*.relay-seen "$BOX/state/.helm-lost" 2>/dev/null || true
  rm -f "$MAC"/state/*.meta 2>/dev/null || true
  rm -rf "$BOX/cr/helm" "$MAC/cr/helm"
}

# The whole observed failure, reproduced and then repaired by one session start.
#
# The captain takes the helm on this machine while the saved connection to the
# other one has expired. The claim itself succeeds - the anchor is local - and
# adoption cannot happen, which is precisely the state that was found: helm held
# here, no host= mirror, and `task-list` unreadable. Nothing but this sweep would
# ever retry it.
test_bootstrap_adopts_peer_work_without_a_second_command() {
  local out before
  mark_trusted
  clear_control_side
  seed_peer_task adoptme
  before=$(cat "$MAC/state/adoptme.meta")

  link_down
  out=$(helm box claim)
  assert_contains "$out" "helm claimed: box" "the claim must succeed even with the peer unreachable"
  assert_contains "$out" "could not ask mac what it is running" \
    "a claim that could not reach the peer must say adoption did not happen"
  assert_absent "$BOX/state/adoptme.meta" "nothing may be recorded for work that could not be read"

  # One ordinary session start, with nobody typing a second command.
  reset_calls
  out=$(bootstrap)
  assert_contains "$out" "BOOTSTRAP_INFO: relay mac: reconnected" "the link must be restored first"
  assert_contains "$out" "BOOTSTRAP_INFO: helm: adopted adoptme from mac" \
    "the holder must then pick up the peer's work"
  assert_present "$BOX/state/adoptme.meta" "the adopted task must be recorded here"
  assert_grep 'host=mac' "$BOX/state/adoptme.meta" "the adopted record must point at the machine running it"
  assert_present "$BOX/state/adoptme.check.sh" "adoption must arm the task's notifications"
  assert_present "$BOX/state/adoptme.check-trust" "the armed check must be registered"
  [ "$(cat "$MAC/state/adoptme.meta")" = "$before" ] \
    || fail "adoption must not modify the task on the machine running it"

  # Idempotent: already known is not news, and nothing is re-paired either.
  reset_calls
  out=$(bootstrap)
  assert_not_contains "$out" "adopted adoptme" "an already-known task must not be re-reported"
  assert_no_pairing "a second session start after a successful reconnect"
  pass "bootstrap: a helm taken while the link was down converges at the next session start"
}

test_bootstrap_adoption_is_holder_only() {
  local out
  mark_trusted
  clear_control_side
  link_up
  helm box claim >/dev/null 2>&1 || true
  helm box handover mac >/dev/null 2>&1 || true
  [ "$(lease_holder box)" = mac ] || fail "fixture: mac must hold the helm"
  # The peer starts work AFTER this machine stopped being the control plane.
  seed_peer_task notmine

  out=$(bootstrap)
  assert_not_contains "$out" "adopted notmine" \
    "a machine that does not hold the helm must adopt nothing"
  assert_absent "$BOX/state/notmine.meta" "a non-holder must record nothing about the peer's work"
  pass "bootstrap: a non-holder stays read-only and discovers nothing"
}

test_bootstrap_adoption_still_refuses_an_id_collision() {
  local out
  mark_trusted
  clear_control_side
  seed_peer_task clash
  printf 'window=local\nworktree=/tmp/local\nkind=ship\n' > "$BOX/state/clash.meta"
  link_up
  helm box claim >/dev/null 2>&1 || true

  out=$(bootstrap)
  assert_contains "$out" "DIFFERENT local task already uses that id" \
    "an id collision must surface as an actionable relay line"
  assert_grep 'window=local' "$BOX/state/clash.meta" \
    "a refused adoption must leave the colliding local record exactly as it was"
  pass "bootstrap adoption: an id collision refuses instead of overwriting a local task"
}

test_claim_adopts_inline() {
  local out
  mark_trusted
  clear_control_side
  seed_peer_task inline
  link_up
  out=$(helm box claim)
  assert_contains "$out" "helm claimed: box" "the claim itself must still report"
  assert_contains "$out" "adopted inline from mac" \
    "claim must pick up the other machines' work without a second command"
  assert_present "$BOX/state/inline.meta" "the inline adoption must record the task"
  pass "claim: adopts the peer's running work in the same command"
}

test_scripts_parse() {
  local f out rc
  for f in bin/fm-relay-conn.sh bin/fm-relay-lib.sh bin/fm-helm.sh bin/fm-bootstrap.sh; do
    out=$(bash -n "$ROOT/$f" 2>&1); rc=$?
    expect_code 0 "$rc" "bash -n $f must parse cleanly (got: $out)"
  done
  pass "trusted-fleet scripts: bash -n succeeds"
}

test_scripts_parse
test_trust_is_one_explicit_field
test_a_malformed_trust_value_is_refused_not_guessed
test_an_unmarked_host_can_never_keep_full_access
test_trusted_no_ssh_host_pairs_from_here_alone
test_a_trusted_pairing_that_does_not_answer_is_unpaired
test_ensure_reuses_a_healthy_link_and_creates_nothing
test_ensure_repairs_a_dead_link_exactly_once
test_ensure_never_claims_a_recovery_it_did_not_make
test_bootstrap_restores_a_trusted_link_and_says_so
test_detect_only_bootstrap_never_pairs
test_a_trusted_host_grant_is_not_reported_as_a_fault
test_the_remaining_gui_setup_action_is_named_precisely
test_bootstrap_adopts_peer_work_without_a_second_command
test_bootstrap_adoption_is_holder_only
test_bootstrap_adoption_still_refuses_an_id_collision
test_claim_adopts_inline
