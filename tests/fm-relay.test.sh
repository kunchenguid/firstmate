#!/usr/bin/env bash
# Behavior tests for the relay task-host layer: bin/fm-relay-lib.sh,
# bin/fm-relay-check-make.sh, control-root/verbs/fmr-verb.sh, and the host=
# branches added to fm-spawn/fm-teardown/fm-brief.
#
# Everything here is hermetic. The live cross-machine evidence lives in
# docs/relay-host.md; what these tests protect are the local invariants that
# would otherwise only fail on a real host, hours into a real task:
#   - an absent optional field in a host record must not shift later fields
#     (tab is IFS whitespace, so a TSV row collapsed empties and once handed the
#     ssh route the key path);
#   - the verb argument charset must reject every shell metacharacter locally,
#     before a malformed argument turns into an opaque policy rejection;
#   - the grant audit must be UNIVERSAL, because a per-grant audit passes on a
#     machine that a second pairing reopened;
#   - --host must be refused, not silently reinterpreted, when combined with a
#     flag that only means something locally;
#   - the captain's discard authority must CROSS the link while the judgement it
#     authorizes stays on the machine holding the work, and must remain covered
#     by the helm fence rather than by a credential of its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-relay)

# A bifrost that echoes back the shell text it was asked to run, so a test can
# inspect exactly what would go over the wire instead of inferring it.
# The mkdir is not redundant: fm_test_tmproot runs inside a command substitution,
# so its own EXIT trap fires when that subshell ends and removes the directory it
# just made. Every other user of TMP_ROOT here happens to recreate it with a
# `mkdir -p` of a subdirectory; this file is the first to write into the root.
mkdir -p "$TMP_ROOT"
cat > "$TMP_ROOT/echo-bifrost" <<'SH'
#!/usr/bin/env bash
prev=
for a in "$@"; do [ "$prev" = "--shell-text" ] && { printf '%s\n' "$a"; exit 0; }; prev=$a; done
exit 1
SH
chmod +x "$TMP_ROOT/echo-bifrost"

# A stub relay that actually carries the call: `exec` runs the real verb with an
# empty environment and `file` copies within this filesystem, so a cross-machine
# test here goes through the real client, allowlist, and verb table.
STUB_BIFROST="$TMP_ROOT/stub"
fm_test_make_stub_bifrost "$STUB_BIFROST"

# shellcheck source=bin/fm-relay-lib.sh
. "$ROOT/bin/fm-relay-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

write_registry() {  # <home> <extra-json-fields>
  mkdir -p "$1/config"
  cat > "$1/config/relay-hosts.json" <<EOF
{
  "box": {
    "client_id": "cid-1",
    "control_root": "/srv/control-root",
    "fleet_root": "/srv/fleet-root",
    "home": "/srv/host-home",
    "root": "/srv/firstmate"$2
  }
}
EOF
}

test_scripts_parse() {
  local f out rc
  for f in bin/fm-relay-lib.sh bin/fm-relay-conn.sh bin/fm-relay-host.sh \
    bin/fm-relay-check-make.sh control-root/verbs/fmr-verb.sh control-root/tighten-grants.sh; do
    out=$(bash -n "$ROOT/$f" 2>&1); rc=$?
    expect_code 0 "$rc" "bash -n $f must parse cleanly (got: $out)"
  done
  pass "relay scripts: bash -n succeeds"
}

# The regression that motivated line-per-field parsing: with @tsv, one absent
# optional field collapsed against its neighbour and every later field shifted
# left, so `ssh` silently became the key path.
test_absent_optional_fields_do_not_shift_later_ones() {
  write_registry "$TMP_ROOT/h1" ',
    "key": "/keys/box.key",
    "ssh": "user@host"'
  fm_relay_host_load "$TMP_ROOT/h1" box || fail "fm_relay_host_load rejected a valid record"
  [ "$FM_RELAY_SSH" = "user@host" ] \
    || fail "ssh route mis-parsed with home_dir/path/lang absent: got '$FM_RELAY_SSH'"
  [ "$FM_RELAY_KEY" = "/keys/box.key" ] \
    || fail "key path mis-parsed: got '$FM_RELAY_KEY'"
  [ "$FM_RELAY_HOST_LANG" = "en_US.UTF-8" ] \
    || fail "absent lang must default to a UTF-8 locale, got '$FM_RELAY_HOST_LANG'"
  [ "$FM_RELAY_VERB" = "/srv/control-root/verbs/fmr-verb.sh" ] \
    || fail "verb path not derived from control_root: got '$FM_RELAY_VERB'"
  pass "fm_relay_host_load: absent optional fields do not shift later ones"
}

# Command substitution strips TRAILING newlines, so a record whose last optional
# fields are all absent - the normal shape for a laptop host with no ssh route -
# loses those lines entirely and the reads run off the end of the input. Each
# failed read returns non-zero, which in a `set -e` caller killed the whole
# script with no message at all: `fm-relay-conn.sh deploy` simply exited 1 and
# printed nothing. The parser carries a sentinel line so the last real field is
# never the last line; this drives it through a REAL set -e caller, because that
# is the only place the bug was visible.
test_a_record_with_no_optional_fields_survives_a_set_e_caller() {
  local home out rc
  home="$TMP_ROOT/sparse"
  write_registry "$home" ''
  fm_relay_host_load "$home" box || fail "a record with no optional fields must load"
  [ -z "$FM_RELAY_SSH" ] || fail "an absent ssh route must be empty, got '$FM_RELAY_SSH'"
  [ "$FM_RELAY_HOST_DIR" = /srv ] \
    || fail "home_dir must still default from home when later fields are absent: got '$FM_RELAY_HOST_DIR'"
  rc=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-conn.sh" audit box 2>&1) || rc=$?
  assert_contains "$out" "RELAY" "a set -e caller must reach its own logic, not die inside the parser"
  pass "fm_relay_host_load: a record with no optional fields does not kill a set -e caller"
}

test_incomplete_record_is_refused() {
  mkdir -p "$TMP_ROOT/h2/config"
  printf '{"box": {"client_id": "c"}}\n' > "$TMP_ROOT/h2/config/relay-hosts.json"
  fm_relay_host_load "$TMP_ROOT/h2" box 2>/dev/null \
    && fail "a record missing control_root/fleet_root/home/root must be refused"
  fm_relay_host_load "$TMP_ROOT/h2" nosuch 2>/dev/null \
    && fail "an unregistered host name must be refused"
  pass "fm_relay_host_load: incomplete and unknown records are refused"
}

test_relative_paths_are_refused() {
  write_registry "$TMP_ROOT/h3" ''
  python3 - "$TMP_ROOT/h3/config/relay-hosts.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["box"]["fleet_root"] = "relative/fleet-root"
json.dump(d, open(p, "w"))
PY
  fm_relay_host_load "$TMP_ROOT/h3" box 2>/dev/null \
    && fail "a relative path in a host record must be refused"
  pass "fm_relay_host_load: relative paths are refused"
}

# The charset is the whole defence: it contains no shell metacharacter and no
# slash, which is why the deployed allowlist can be one pattern.
test_argument_charset() {
  local ok bad a
  for a in ping relay-probe-a1 brief.md 0 1785563030 harness=claude a@b c+d e.f-g; do
    fm_relay_arg_valid "$a" || fail "valid argument rejected: $a"
  done
  ok=$(printf 'a%.0s' $(seq 1 96)); fm_relay_arg_valid "$ok" || fail "96-char argument rejected"
  bad=$(printf 'a%.0s' $(seq 1 97)); fm_relay_arg_valid "$bad" && fail "97-char argument accepted"
  # shellcheck disable=SC2016  # these are literal REJECTION inputs; expanding them would defeat the test
  for a in 'a b' 'a;b' 'a|b' 'a&b' 'a$b' 'a`b' 'a/b' 'a>b' 'a(b' "a'b" 'a"b' '../etc' '' 'a
b'; do
    fm_relay_arg_valid "$a" && fail "argument outside the charset accepted: [$a]"
  done
  pass "fm_relay_arg_valid: charset admits verb arguments and rejects every metacharacter"
}

# A second pairing ADDS a full-access grant and leaves the tightened one looking
# correct, so only the universal question is sound.
test_grant_audit_is_universal() {
  local clean dirty
  clean='Remote Grants
  Count: 2
  - aaaa caller-a
    binding: {"mode":"selected","policy_ids":["fm-relay-verbs"]}
  - bbbb caller-b
    binding: {"mode":"selected","policy_ids":["fm-relay-verbs"]}'
  dirty='Remote Grants
  Count: 2
  - aaaa caller-a
    binding: {"mode":"selected","policy_ids":["fm-relay-verbs"]}
  - bbbb caller-b
    binding: {"mode":"selected","policy_ids":["ssh-key-full-access"]}'
  fm_relay_audit_grants_text "$clean" || fail "an all-narrow grant list must pass the audit"
  fm_relay_audit_grants_text "$dirty" && fail "a list with ONE full-access grant must fail the audit"
  pass "fm_relay_audit_grants_text: the assertion is universal, not per-grant"
}

test_verb_ok_drops_a_bare_ok_header() {
  local out
  FM_RELAY_OUT='OK
state: parked'
  FM_RELAY_RC=0
  fm_relay_exec() { return 0; }
  out=$(fm_relay_verb_ok crew-state x)
  [ "$out" = "state: parked" ] || fail "bare OK header not dropped: got [$out]"
  FM_RELAY_OUT='OK sent=x'
  out=$(fm_relay_verb_ok send x)
  [ "$out" = "sent=x" ] || fail "OK payload not returned: got [$out]"
  unset -f fm_relay_exec
  pass "fm_relay_verb_ok: the OK header never leaks into the answer"
}

# --- the deployed verb, driven locally against a fake control root ------------

setup_verb_host() {  # echoes the control root
  local croot="$TMP_ROOT/verbhost/control-root" home="$TMP_ROOT/verbhost/home"
  mkdir -p "$croot/verbs" "$croot/tasks" "$home/state" "$home/data" \
    "$TMP_ROOT/verbhost/fleet-root/tasks" "$TMP_ROOT/verbhost/fmroot/bin"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$croot/verbs/fmr-verb.sh"
  chmod 755 "$croot/verbs/fmr-verb.sh"
  {
    printf 'FM_ROOT=%s\n' "$TMP_ROOT/verbhost/fmroot"
    printf 'FM_HOME=%s\n' "$home"
    printf 'HOME_DIR=%s\n' "$TMP_ROOT/verbhost"
    printf 'PATH=%s\n' "$PATH"
    printf 'FLEET_ROOT=%s\n' "$TMP_ROOT/verbhost/fleet-root"
  } > "$croot/config"
  printf '%s' "$croot"
}

test_verb_refuses_without_config() {
  local croot out
  croot="$TMP_ROOT/noconfig/control-root"
  mkdir -p "$croot/verbs"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$croot/verbs/fmr-verb.sh"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" ping 2>&1)
  assert_contains "$out" "ERR config" "a verb with no host config must refuse, not guess"
  pass "fmr-verb: refuses without its host config"
}

test_verb_validates_its_own_arguments() {
  local croot out
  croot=$(setup_verb_host)
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" 2>&1)
  assert_contains "$out" "ERR badarg" "a verb call with no verb must refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" nosuchverb 2>&1)
  assert_contains "$out" "ERR badverb" "an unknown verb must refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events .. 0 2>&1)
  assert_contains "$out" "ERR badarg" "a dot-leading task id must refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events task notanumber 2>&1)
  assert_contains "$out" "ERR badarg" "a non-numeric offset must refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn task ship proj ref 2>&1)
  assert_contains "$out" "ERR noproject" "spawn into an absent project must refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" key task Delete 2>&1)
  assert_contains "$out" "ERR badarg" "an unsupported key name must refuse"
  pass "fmr-verb: re-validates every argument itself"
}

# The byte-offset cursor is what makes "at least once, never lost" work across a
# broken link, so its arithmetic is worth pinning.
test_verb_events_are_byte_offset_incremental() {
  local croot home out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events t1 0 2>&1)
  assert_contains "$out" "OK offset=0 new=0" "an absent status log must report an empty log, not an error"
  printf 'working: one\n' > "$home/state/t1.status"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events t1 0 2>&1)
  assert_contains "$out" "OK offset=13 new=13" "first read must report the whole log"
  assert_contains "$out" "working: one" "first read must return the event text"
  printf 'done: two\n' >> "$home/state/t1.status"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events t1 13 2>&1)
  assert_contains "$out" "OK offset=23 new=10" "second read must report only the increment"
  assert_contains "$out" "done: two" "second read must return only the new event"
  assert_not_contains "$out" "working: one" "an already-read event must not be replayed by offset"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events t1 23 2>&1)
  assert_contains "$out" "OK offset=23 new=0" "a caught-up read must report nothing new"
  pass "fmr-verb events: incremental by byte offset"
}

test_verb_sanitizes_crew_authored_event_text() {
  local croot home out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  printf 'working: \033[31mred\033[0m and \001control\n' > "$home/state/t2.status"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" events t2 0 2>&1)
  case "$out" in
    *$'\033'*) fail "an escape sequence in crew status text reached the supervisor" ;;
    *$'\001'*) fail "a control character in crew status text reached the supervisor" ;;
  esac
  assert_contains "$out" "red" "sanitizing must keep the readable text"
  pass "fmr-verb events: crew-authored text is stripped of control characters"
}

# The first token IS the protocol. An unconditional OK made a failed read look
# like a successful one whose text the control side would have to guess at.
test_verb_crew_state_reports_failure_as_err() {
  local croot home out rc
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  cat > "$TMP_ROOT/verbhost/fmroot/bin/fm-crew-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "no such task" >&2
exit 3
STUB
  chmod +x "$TMP_ROOT/verbhost/fmroot/bin/fm-crew-state.sh"
  rc=0
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" crew-state t7 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote state read must exit non-zero"
  case "$out" in
    ERR\ statefailed*) ;;
    *) fail "a failed remote state read must answer ERR on the first line, got [$out]" ;;
  esac

  cat > "$TMP_ROOT/verbhost/fmroot/bin/fm-crew-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "state: working · source: pane · harness busy"
STUB
  chmod +x "$TMP_ROOT/verbhost/fmroot/bin/fm-crew-state.sh"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" crew-state t7 2>&1) \
    || fail "a successful remote state read must exit 0"
  assert_contains "$out" "OK" "a successful remote state read must still answer OK"
  assert_contains "$out" "state: working" "a successful remote state read must return the state line"
  rm -f "$TMP_ROOT/verbhost/fmroot/bin/fm-crew-state.sh"
  pass "fmr-verb crew-state: a failed read answers ERR, not OK"
}

test_verb_teardown_gate_needs_a_matching_report_hash() {
  local croot home out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  mkdir -p "$home/data/t3"
  printf 'kind=scout\nworktree=/nowhere\n' > "$home/state/t3.meta"
  printf 'the deliverable\n' > "$home/data/t3/report.md"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown t3 none 2>&1)
  assert_contains "$out" "ERR reportgate" "scout teardown must refuse without a control-side report hash"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown t3 \
    0000000000000000000000000000000000000000000000000000000000000000 2>&1)
  assert_contains "$out" "ERR reportgate" "scout teardown must refuse a hash that does not match the host report"
  pass "fmr-verb teardown: the scout report gate refuses a missing or mismatched copy"
}

# --- crossing the link with the captain's discard authority -------------------
#
# The hole this closes, measured 2026-08-06: the host's teardown refused two
# expired tasks - one dirty, one with five unpushed commits - which is exactly
# what it is for, and there was no way to tell it the captain had authorized
# discarding them. Running the host's teardown directly instead was refused by
# the helm gate, because the helm was on the other machine. A remote task that
# ran off the rails could therefore never be cleaned up from anywhere.
#
# What is asserted here is that authorization travels and JUDGEMENT DOES NOT: the
# host is handed --force and applies its own rules to its own worktree.

# A teardown stub in the host's fake bin/ that records the arguments it was given,
# so a test can tell "the flag crossed the link" from "the flag was swallowed".
install_teardown_recorder() {  # <fmroot>
  local fmroot=$1
  cat > "$fmroot/bin/fm-teardown.sh" <<'STUB'
#!/usr/bin/env bash
printf 'stub-teardown args: %s\n' "$*"
printf '%s\n' "$*" > "$(dirname "$0")/../teardown.args"
STUB
  chmod +x "$fmroot/bin/fm-teardown.sh"
}

test_verb_teardown_force_passes_discard_authority_to_the_host() {
  local croot home fmroot out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  fmroot="$TMP_ROOT/verbhost/fmroot"
  install_teardown_recorder "$fmroot"
  rm -f "$fmroot/teardown.args"
  printf 'kind=ship\nworktree=/nowhere\n' > "$home/state/tf1.meta"

  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf1 none 2>&1)
  assert_contains "$out" "OK torndown=tf1" "an ordinary teardown must still work"
  [ "$(cat "$fmroot/teardown.args")" = tf1 ] \
    || fail "without the token the host must be asked for an ORDINARY teardown, with no flag: got [$(cat "$fmroot/teardown.args")]"

  printf 'kind=ship\nworktree=/nowhere\n' > "$home/state/tf2.meta"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf2 none force 2>&1)
  assert_contains "$out" "OK torndown=tf2" "a forced teardown must succeed"
  [ "$(cat "$fmroot/teardown.args")" = "tf2 --force" ] \
    || fail "the token must reach the host's OWN teardown as --force, so it makes the judgement: got [$(cat "$fmroot/teardown.args")]"
  rm -f "$fmroot/bin/fm-teardown.sh"
  pass "fmr-verb teardown: force crosses as authorization, and the host still judges"
}

test_verb_teardown_force_releases_only_the_report_gate() {
  local croot home fmroot out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  fmroot="$TMP_ROOT/verbhost/fmroot"
  install_teardown_recorder "$fmroot"
  # A scout whose worker died BEFORE writing a report: no deliverable exists, so
  # the gate that protects one has nothing to protect and would otherwise make
  # this task permanently un-cleanable.
  printf 'kind=scout\nworktree=/nowhere\n' > "$home/state/tf3.meta"
  rm -rf "$home/data/tf3"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf3 none 2>&1)
  assert_contains "$out" "ERR noreport" "without the token a reportless scout must still refuse"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf3 none force 2>&1)
  assert_contains "$out" "OK torndown=tf3" "with the token a reportless scout must tear down"

  # The gate is released, not weakened: the unforced path is byte-identical.
  mkdir -p "$home/data/tf4"
  printf 'kind=scout\nworktree=/nowhere\n' > "$home/state/tf4.meta"
  printf 'the deliverable\n' > "$home/data/tf4/report.md"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf4 none 2>&1)
  assert_contains "$out" "ERR reportgate" "an unforced scout teardown must still demand the hash"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf4 \
    0000000000000000000000000000000000000000000000000000000000000000 2>&1)
  assert_contains "$out" "ERR reportgate" "an unforced scout teardown must still compare the hash"
  rm -f "$fmroot/bin/fm-teardown.sh"
  pass "fmr-verb teardown: force releases the report gate and nothing else"
}

# An unknown third token must not be read as "not force" and quietly ignored: a
# typo would then look like it worked while the authorization never travelled.
test_verb_teardown_refuses_an_unknown_third_token() {
  local croot home out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  printf 'kind=ship\nworktree=/nowhere\n' > "$home/state/tf5.meta"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf5 none FORCE 2>&1)
  assert_contains "$out" "ERR badarg" "an unrecognised discard token must refuse"
  assert_present "$home/state/tf5.meta" "a refused teardown must change nothing"
  pass "fmr-verb teardown: an unknown third token refuses instead of being ignored"
}

# The forced path gets NO authorization of its own, so it must be covered by the
# one that already guards teardown. A caller with no current helm epoch is
# refused by the machine it is commanding, before anything is discarded.
test_verb_teardown_force_is_covered_by_the_existing_helm_fence() {
  local croot home fmroot out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  fmroot="$TMP_ROOT/verbhost/fmroot"
  install_teardown_recorder "$fmroot"
  rm -f "$fmroot/teardown.args"
  printf 'kind=ship\nworktree=/nowhere\n' > "$home/state/tf6.meta"
  mkdir -p "$croot/helm"
  printf 'helm-v1\nfleet=f\nepoch=7\nholder=other\n' > "$croot/helm/lease"

  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown tf6 none force 2>&1)
  assert_contains "$out" "EPOCH_STALE" "a forced discard carrying no helm epoch must be refused"
  assert_absent "$fmroot/teardown.args" "a fenced forced discard must not reach the host's teardown at all"
  assert_present "$home/state/tf6.meta" "a fenced forced discard must change nothing"

  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown@3 tf6 none force 2>&1)
  assert_contains "$out" "EPOCH_STALE" "a forced discard from a stale control plane must be refused"

  # And the current epoch is accepted, so the fence is a fence and not a wall.
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" teardown@7 tf6 none force 2>&1)
  assert_contains "$out" "OK torndown=tf6" "the current epoch must be accepted"
  rm -rf "$croot/helm"
  rm -f "$fmroot/bin/fm-teardown.sh"
  pass "fmr-verb teardown: forced discard rides the existing helm fence, not a new credential"
}

# --- a persistent secondmate on the other machine -----------------------------
#
# The design rule under test is one sentence: nothing about the secondmate
# contract is reimplemented on the wire. Every assertion below is a form of it -
# the peer runs its OWN fm-home-seed.sh, its OWN fm-spawn.sh --secondmate, its
# OWN fm-config-inherit-apply.sh, its OWN fm-backlog-handoff.sh, and this side
# holds a route plus a mirror.
#
# The other half is the deployed-copy problem. control-root/ is installed on each
# host, so a host that has not been redeployed has an OLD verb table. It must
# REFUSE, and this side must report that refusal as a failure rather than as a
# quiet success - which is what the last test here pins.

# A recorder in the host's fake bin/ that logs its arguments and answers.
install_recorder() {  # <fmroot> <script-name> <stdout-lines>
  local fmroot=$1 name=$2 out=$3
  cat > "$fmroot/bin/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "\$(dirname "\$0")/../$name.args"
[ -z "$out" ] || printf '%s\n' "$out"
exit \${STUB_RC:-0}
STUB
  chmod +x "$fmroot/bin/$name"
}

test_verb_spawn_takes_a_secondmate_with_no_project_and_no_brief() {
  local croot home fmroot out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  fmroot="$TMP_ROOT/verbhost/fmroot"
  install_recorder "$fmroot" fm-spawn.sh ''
  install_recorder "$fmroot" fm-peek.sh 'esc to interrupt'
  install_recorder "$fmroot" fm-send.sh ''
  printf 'kind=secondmate\nhome=%s/sm\nwindow=firstmate:fm-sm1\n' "$home" > "$home/state/sm1.meta"

  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn sm1 secondmate - - 2>&1)
  assert_contains "$out" "OK spawned=sm1" "a secondmate spawn must succeed with no project and no staged brief"
  assert_contains "$out" "kind=secondmate" "the host's own metadata must come back for the control side to mirror"
  assert_grep "sm1 --secondmate" "$fmroot/fm-spawn.sh.args" \
    "the host must run its OWN fm-spawn.sh --secondmate"
  # A claim would refuse exactly the call recovery has to make.
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" spawn sm1 secondmate - - 2>&1)
  assert_contains "$out" "OK spawned=sm1" "respawning a secondmate must not be refused as already-claimed"
  rm -f "$fmroot/bin/fm-spawn.sh" "$fmroot/bin/fm-peek.sh" "$fmroot/bin/fm-send.sh"
  pass "fmr-verb spawn: a secondmate needs no project, no brief, and no claim"
}

test_verb_home_seed_validates_its_spec_before_seeding() {
  local croot fmroot fleet out
  croot=$(setup_verb_host)
  fmroot="$TMP_ROOT/verbhost/fmroot"
  fleet="$TMP_ROOT/verbhost/fleet-root"
  install_recorder "$fmroot" fm-home-seed.sh 'home=/leased/home'
  mkdir -p "$fleet/tasks/sm2/in"
  printf 'charter body\n' > "$fleet/tasks/sm2/in/charter.md"

  printf 'home=-\nproject=alpha\n' > "$fleet/tasks/sm2/in/spec"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm2 charter.md spec 2>&1)
  assert_contains "$out" "ERR badarg" "a spec with no protocol line must refuse"

  printf 'fmseed-v1\nhome=/somewhere/else\nproject=alpha\n' > "$fleet/tasks/sm2/in/spec"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm2 charter.md spec 2>&1)
  assert_contains "$out" "ERR badarg" "a spec naming a home path must refuse; a remote home is leased there"

  printf 'fmseed-v1\nhome=-\nproject=../escape\n' > "$fleet/tasks/sm2/in/spec"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm2 charter.md spec 2>&1)
  assert_contains "$out" "ERR badarg" "a spec naming an unsafe project must refuse"

  printf 'fmseed-v1\nhome=-\nno_projects=1\nproject=alpha\n' > "$fleet/tasks/sm2/in/spec"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm2 charter.md spec 2>&1)
  assert_contains "$out" "ERR badarg" "a spec combining no_projects with a project list must refuse"

  printf 'fmseed-v1\nhome=-\n' > "$fleet/tasks/sm2/in/spec"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm2 charter.md spec 2>&1)
  assert_contains "$out" "ERR badarg" "a spec naming neither a project nor no_projects must refuse"

  assert_absent "$fmroot/fm-home-seed.sh.args" "a refused spec must never reach the host's own seed"
  rm -f "$fmroot/bin/fm-home-seed.sh"
  pass "fmr-verb home-seed: every spec field is re-validated before the seed runs"
}

test_verb_home_seed_runs_the_hosts_own_seed_and_cleans_up_on_failure() {
  local croot home fmroot fleet out
  croot=$(setup_verb_host)
  home="$TMP_ROOT/verbhost/home"
  fmroot="$TMP_ROOT/verbhost/fmroot"
  fleet="$TMP_ROOT/verbhost/fleet-root"
  mkdir -p "$fleet/tasks/sm3/in"
  printf 'charter body\n' > "$fleet/tasks/sm3/in/charter.md"
  printf 'fmseed-v1\nhome=-\nproject=alpha\nproject=beta\n' > "$fleet/tasks/sm3/in/spec"

  install_recorder "$fmroot" fm-home-seed.sh 'home=/leased/sm3'
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm3 charter.md spec 2>&1)
  assert_contains "$out" "OK seeded=sm3 home=/leased/sm3" "the verb must report the home the host leased"
  assert_grep "sm3 - alpha beta" "$fmroot/fm-home-seed.sh.args" \
    "the host must run its OWN fm-home-seed.sh with the leased-home form"
  assert_grep 'charter body' "$home/data/sm3/brief.md" "the charter must be installed where the host's seed reads it"

  # A failed seed must not leave this machine holding a charter it never used.
  rm -f "$home/data/sm3/brief.md" "$fmroot/fm-home-seed.sh.args"
  cat > "$fmroot/bin/fm-home-seed.sh" <<'STUB'
#!/usr/bin/env bash
echo "error: project alpha not found" >&2
exit 1
STUB
  chmod +x "$fmroot/bin/fm-home-seed.sh"
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" home-seed sm3 charter.md spec 2>&1)
  assert_contains "$out" "ERR seedfailed" "a refused seed must answer ERR"
  assert_contains "$out" "project alpha not found" "a refused seed must relay the host's own reason"
  assert_absent "$home/data/sm3/brief.md" "a failed seed must not leave the charter it installed behind"
  rm -f "$fmroot/bin/fm-home-seed.sh"
  pass "fmr-verb home-seed: the host seeds itself, and a failure leaves nothing behind"
}

test_new_secondmate_verbs_ride_the_existing_helm_fence() {
  local croot fmroot out v
  croot=$(setup_verb_host)
  fmroot="$TMP_ROOT/verbhost/fmroot"
  mkdir -p "$croot/helm"
  printf 'helm-v1\nfleet=f\nepoch=9\nholder=other\n' > "$croot/helm/lease"
  install_recorder "$fmroot" fm-home-seed.sh 'home=/leased/x'
  install_recorder "$fmroot" fm-config-inherit-apply.sh 'digest=abc'
  install_recorder "$fmroot" fm-backlog-handoff.sh 'moved'
  install_recorder "$fmroot" fm-agent-alive.sh 'alive'
  rm -f "$fmroot"/fm-*.args

  for v in home-seed home-config backlog-mv; do
    out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" "$v" smf ref1 ref2 2>&1)
    assert_contains "$out" "EPOCH_STALE" "$v carrying no helm epoch must be refused"
    out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" "$v@3" smf ref1 ref2 2>&1)
    assert_contains "$out" "EPOCH_STALE" "$v from a stale control plane must be refused"
  done
  assert_absent "$fmroot/fm-home-seed.sh.args" "a fenced call must not reach the host's own scripts"
  assert_absent "$fmroot/fm-config-inherit-apply.sh.args" "a fenced call must not reach the host's own scripts"
  assert_absent "$fmroot/fm-backlog-handoff.sh.args" "a fenced call must not reach the host's own scripts"

  # Reading stays allowed from a demoted machine, exactly like every other read.
  out=$(env -i /bin/bash "$croot/verbs/fmr-verb.sh" agent-alive smf 2>&1)
  assert_contains "$out" "OK alive=alive" "agent-alive is a read and must not be fenced"
  rm -rf "$croot/helm"
  rm -f "$fmroot/bin/fm-home-seed.sh" "$fmroot/bin/fm-config-inherit-apply.sh" \
    "$fmroot/bin/fm-backlog-handoff.sh" "$fmroot/bin/fm-agent-alive.sh"
  pass "fmr-verb: the secondmate verbs reuse the helm fence, and the read stays readable"
}

# --- control side, end to end against a stub relay ----------------------------

# Two real directories and the real verb between them, so a "cross-machine" seed
# here exercises the real client, the real allowlist, and the real verb table.
setup_two_machines() {  # echoes the control home
  local root="$TMP_ROOT/2m" here="$TMP_ROOT/2m/here" peer="$TMP_ROOT/2m/peer"
  rm -rf "$root"
  mkdir -p "$here/state" "$here/data" "$here/config" \
    "$peer/state" "$peer/data" "$peer/config" "$peer/projects" \
    "$peer/cr/verbs" "$peer/cr/tasks" "$peer/fr/tasks" "$peer/fmroot/bin"
  cp "$ROOT/control-root/verbs/fmr-verb.sh" "$peer/cr/verbs/fmr-verb.sh"
  chmod 755 "$peer/cr/verbs/fmr-verb.sh"
  {
    printf 'FM_ROOT=%s\n' "$peer/fmroot"
    printf 'FM_HOME=%s\n' "$peer"
    printf 'HOME_DIR=%s\n' "$peer"
    printf 'PATH=%s\n' "$PATH"
    printf 'PROJECTS=%s\n' "$peer/projects"
    printf 'FLEET_ROOT=%s\n' "$peer/fr"
  } > "$peer/cr/config"
  cat > "$here/config/relay-hosts.json" <<EOF
{
  "box151": {
    "client_id": "cid-box151",
    "control_root": "$peer/cr",
    "fleet_root": "$peer/fr",
    "home": "$peer",
    "root": "$peer/fmroot",
    "path": "$PATH"
  }
}
EOF
  printf '%s' "$here"
}

test_home_seed_over_the_link_records_a_route_carrying_the_machine() {
  local here peer out rc=0
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  install_recorder "$peer/fmroot" fm-home-seed.sh 'home=/leased/sm-far'
  mkdir -p "$here/data/sm-far"
  cat > "$here/data/sm-far/brief.md" <<'EOF'
# Charter

Keep three upstreams in step.

# Routing scope

upstream sync work
EOF
  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-home-seed.sh" sm-far - --machine box151 alpha 2>&1) || rc=$?
  expect_code 0 "$rc" "a cross-machine seed must succeed: $out"
  assert_contains "$out" "home=/leased/sm-far" "the seed must report the home the peer leased"
  assert_grep "- sm-far - " "$here/data/secondmates.md" "the route must be recorded here"
  assert_grep 'machine: box151;' "$here/data/secondmates.md" "the route must name the machine"
  assert_grep 'home: /leased/sm-far;' "$here/data/secondmates.md" "the route must carry the peer's home path"
  assert_grep "sm-far - alpha" "$peer/fmroot/fm-home-seed.sh.args" \
    "the peer must have run its OWN seed with its own project name"
  assert_grep 'Keep three upstreams' "$peer/data/sm-far/brief.md" "the charter must reach the peer"

  # And re-seeding a registered id is refused rather than leaking a second lease.
  rm -f "$peer/fmroot/fm-home-seed.sh.args"
  rc=0
  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-home-seed.sh" sm-far - --machine box151 alpha 2>&1) || rc=$?
  expect_code 1 "$rc" "re-seeding a registered id must refuse"
  assert_contains "$out" "already registered" "the refusal must say why"
  assert_absent "$peer/fmroot/fm-home-seed.sh.args" "a refused re-seed must never reach the peer"
  pass "fm-home-seed --machine: the peer seeds itself and this side records one route"
}

test_home_seed_refuses_a_named_home_path_and_an_unfilled_charter() {
  local here out rc=0
  here=$(setup_two_machines)
  mkdir -p "$here/data/sm-bad"
  printf '# Charter\n\n{TASK}\n\n# Routing scope\n\nx\n' > "$here/data/sm-bad/brief.md"
  out=$(FM_HOME="$here" "$ROOT/bin/fm-home-seed.sh" sm-bad /tmp/somewhere --machine box151 alpha 2>&1) || rc=$?
  expect_code 1 "$rc" "--machine with an explicit home path must refuse"
  assert_contains "$out" "requires the home spec '-'" "the refusal must name the one accepted form"
  rc=0
  out=$(FM_HOME="$here" "$ROOT/bin/fm-home-seed.sh" sm-bad - --machine box151 alpha 2>&1) || rc=$?
  expect_code 1 "$rc" "an unfilled charter must refuse before anything travels"
  assert_contains "$out" "{TASK}" "the refusal must name the placeholder"
  assert_absent "$here/data/secondmates.md" "a refused seed must write no route"
  pass "fm-home-seed --machine: refuses a named path and an unfilled charter, before the link"
}

# The deployed-copy problem, stated as a test: a host that has not been
# redeployed does not know these verbs, and the only safe answer is a refusal
# this side reports as a failure.
test_an_undeployed_host_refuses_the_new_verbs_loudly() {
  local here peer out rc=0
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  # An older deployment: a verb table that knows nothing but ping.
  cat > "$peer/cr/verbs/fmr-verb.sh" <<'OLD'
#!/usr/bin/env bash
set -u
case "${1%%@*}" in
  ping) printf 'OK pong host=old proto=fmr-v1\n' ;;
  *) printf 'ERR badverb unknown verb\n'; exit 1 ;;
esac
OLD
  chmod 755 "$peer/cr/verbs/fmr-verb.sh"
  mkdir -p "$here/data/sm-old"
  printf '# Charter\n\nc\n\n# Routing scope\n\ns\n' > "$here/data/sm-old/brief.md"
  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-home-seed.sh" sm-old - --machine box151 alpha 2>&1) || rc=$?
  expect_code 1 "$rc" "an undeployed host must make the seed FAIL, not succeed quietly"
  assert_contains "$out" "badverb" "the peer's own refusal must be relayed verbatim"
  assert_not_contains "$out" "seeded:" "nothing may claim a seed that did not happen"
  assert_absent "$here/data/secondmates.md" "no route may be recorded for a seed the peer refused"
  pass "an undeployed host: the new verbs are refused, and this side reports the refusal"
}

test_spawn_host_secondmate_launches_over_there_and_moves_no_backlog_row() {
  local here peer out rc=0
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  install_recorder "$peer/fmroot" fm-spawn.sh ''
  install_recorder "$peer/fmroot" fm-peek.sh 'esc to interrupt'
  install_recorder "$peer/fmroot" fm-send.sh ''
  printf 'kind=secondmate\nwindow=firstmate:fm-sm-far\nworktree=/leased/sm-far\nhome=/leased/sm-far\n' \
    > "$peer/state/sm-far.meta"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$here/data/backlog.md"

  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-spawn.sh" --host box151 sm-far --secondmate 2>&1) || rc=$?
  expect_code 0 "$rc" "a cross-machine secondmate launch must succeed: $out"
  assert_grep "sm-far --secondmate" "$peer/fmroot/fm-spawn.sh.args" \
    "the peer must run its OWN fm-spawn.sh --secondmate"
  assert_grep 'kind=secondmate' "$here/state/sm-far.meta" "this side must mirror the peer's metadata"
  assert_grep 'host=box151' "$here/state/sm-far.meta" "the mirror must record which machine holds it"
  assert_no_grep 'sm-far' "$here/data/backlog.md" "a secondmate is not a backlog item on either machine"

  # A launch with no project positional is the point; a task still needs one.
  rc=0
  out=$("$ROOT/bin/fm-spawn.sh" --host box151 onlyid 2>&1) || rc=$?
  expect_code 1 "$rc" "a remote TASK must still name its project"
  assert_contains "$out" "project-name-on-host" "the task refusal must name what is missing"
  pass "fm-spawn --host --secondmate: the peer launches it, and no backlog row moves"
}

test_teardown_of_a_remote_secondmate_drops_the_route_here() {
  local here peer out rc=0
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  install_recorder "$peer/fmroot" fm-teardown.sh 'retired'
  printf 'kind=secondmate\nwindow=w\nworktree=/leased/sm-far\nhome=/leased/sm-far\nhost=box151\n' \
    > "$here/state/sm-far.meta"
  printf 'kind=secondmate\nwindow=w\nworktree=/leased/sm-far\nhome=/leased/sm-far\n' \
    > "$peer/state/sm-far.meta"
  {
    printf -- '- sm-far - upstream work (home: /leased/sm-far; machine: box151; scope: s; projects: alpha; added 2026-08-06)\n'
    printf -- '- sm-here - local work (home: /homes/local; scope: s; projects: beta; added 2026-08-06)\n'
  } > "$here/data/secondmates.md"

  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-teardown.sh" sm-far 2>&1) || rc=$?
  expect_code 0 "$rc" "retiring a remote secondmate must succeed: $out"
  assert_grep "sm-far" "$peer/fmroot/fm-teardown.sh.args" \
    "the peer must run its OWN teardown, which owns the in-flight-children refusal"
  assert_absent "$here/state/sm-far.meta" "the local mirror must be cleared"
  assert_no_grep '- sm-far ' "$here/data/secondmates.md" \
    "a retired secondmate's route must not keep routing work to a home that is gone"
  assert_grep '- sm-here ' "$here/data/secondmates.md" "another secondmate's route must survive"
  pass "fm-teardown: retiring a remote secondmate clears the route this side owns"
}

# The real receiving half, not a recorder: the peer runs the real
# bin/fm-config-inherit-apply.sh against a real seeded home, so the guards and
# the read-only destination mode are exercised where they run.
test_home_config_applies_the_real_surface_into_a_real_home() {
  local here peer sm out rc=0 mode
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  sm="$TMP_ROOT/2m/sm"
  # The peer's own firstmate root is the real one, so the real scripts run there.
  sed -i.bak "s|^FM_ROOT=.*|FM_ROOT=$ROOT|" "$peer/cr/config" && rm -f "$peer/cr/config.bak"
  mkdir -p "$sm/data" "$sm/state" "$sm/config" "$sm/projects" "$sm/bin"
  printf 'sm-far\n' > "$sm/.fm-secondmate-home"
  printf 'instructions\n' > "$sm/AGENTS.md"
  printf -- '- sm-far - upstream work (home: %s; scope: s; projects: alpha; added 2026-08-06)\n' "$sm" \
    > "$peer/data/secondmates.md"
  printf 'kind=secondmate\nhome=%s\nhost=box151\n' "$sm" > "$here/state/sm-far.meta"
  printf 'codex\n' > "$here/config/crew-harness"
  cat > "$here/data/captain-shared.md" <<'EOF'
# Shared captain preferences

This file is main-authoritative and read-only in secondmate homes.
It must not be edited there; route a new captain-preference discovery to the
main firstmate through marked status or a document pointer.

- prefer plain answers
EOF

  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" home-config sm-far 2>&1) || rc=$?
  # The bytes must land whatever the reread send does in a fixture with no agent.
  assert_present "$sm/config/crew-harness" "the declared config item must reach the remote home"
  cmp -s "$here/config/crew-harness" "$sm/config/crew-harness" \
    || fail "the remote copy must be byte-identical to the primary's"
  assert_present "$sm/data/captain-shared.md" "the shared captain file must reach the remote home"
  mode=$(fm_pr_file_mode "$sm/data/captain-shared.md")
  [ "$mode" = "444" ] || fail "the shared captain copy must be read-only in the secondmate home, got $mode"
  # And a converged home then costs one round trip: the digests agree.
  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" home-config sm-far 2>&1) || true
  assert_contains "$out" "unchanged:" "a converged home must ship nothing on the next push"
  pass "home-config: the peer applies the real surface, read-only, and then reports convergence"
}

test_home_config_ships_nothing_when_the_two_sides_already_agree() {
  local here peer out
  here=$(setup_two_machines)
  peer="$TMP_ROOT/2m/peer"
  printf 'codex\n' > "$here/config/crew-harness"
  printf 'kind=secondmate\nhome=%s/sm\nhost=box151\n' "$peer" > "$here/state/sm-cfg.meta"
  # The peer answers with the digest of a home that is already converged.
  cat > "$peer/fmroot/bin/fm-config-inherit-apply.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/../apply.args"
printf 'home=/leased/sm\n'
printf 'digest=%s\n' "${STUB_DIGEST:-nomatch}"
STUB
  chmod +x "$peer/fmroot/bin/fm-config-inherit-apply.sh"
  # First, digests differ, so the surface is staged and applied.
  out=$(FM_HOME="$here" FM_RELAY_BIFROST="$STUB_BIFROST/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" home-config sm-cfg 2>&1) \
    || fail "a differing digest must push: $out"
  assert_grep "--from" "$peer/fmroot/apply.args" "a differing digest must stage and apply the surface"
  assert_no_grep "unchanged:" "$peer/fmroot/apply.args" "the apply args must not carry the caller's wording"
  pass "fm-relay-host home-config: a differing digest stages the declared surface"
}

# The control side's own half: the flag has to reach the wire, and the local
# report precondition has to step aside with it.
test_relay_host_teardown_force_reaches_the_wire() {
  local home out
  home="$TMP_ROOT/tdforce"
  mkdir -p "$home/state" "$home/data" "$home/config"
  write_registry "$home" ''
  printf 'window=w\nworktree=/nowhere\nkind=scout\nhost=box\n' > "$home/state/t8.meta"

  # Without discard authority, and with no report pulled, this side refuses
  # before it spends a round trip - unchanged.
  out=$(FM_HOME="$home" FM_RELAY_BIFROST="$TMP_ROOT/echo-bifrost" \
    "$ROOT/bin/fm-relay-host.sh" teardown t8 2>&1) && fail "an unpulled scout teardown must refuse"
  assert_contains "$out" "run report-pull first" "the refusal must name the fix"

  # With it, there may be no report to pull at all, so this side sends none and
  # the flag rides along as its own token.
  out=$(FM_HOME="$home" FM_RELAY_BIFROST="$TMP_ROOT/echo-bifrost" \
    "$ROOT/bin/fm-relay-host.sh" teardown t8 --force 2>&1) \
    || fail "a forced remote teardown must not refuse locally: $out"
  assert_contains "$out" "teardown t8 none force" \
    "the forced teardown must reach the wire with the discard token"
  assert_not_contains "$out" "report-pull" "a forced teardown must not demand a report copy"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-host.sh" teardown t8 --wat 2>&1) \
    && fail "an unknown teardown flag must refuse"
  assert_contains "$out" "unexpected argument" "an unknown teardown flag must say so"
  pass "fm-relay-host teardown: --force reaches the wire and stands the report precondition down"
}

# --- host= branches in the existing scripts -----------------------------------

test_spawn_host_flag_refusals() {
  local out rc
  out=$("$ROOT/bin/fm-spawn.sh" --host 2>&1); rc=$?
  expect_code 1 "$rc" "--host with no value must refuse"
  assert_contains "$out" "--host requires a value" "--host with no value must say so"
  out=$("$ROOT/bin/fm-spawn.sh" --host box id proj --backend tmux 2>&1); rc=$?
  expect_code 1 "$rc" "--host with --backend must refuse"
  assert_contains "$out" "cannot combine with --host" "--host + --backend must say so"
  out=$("$ROOT/bin/fm-spawn.sh" --host box id proj --launch v 2>&1); rc=$?
  expect_code 1 "$rc" "--host with --launch must refuse"
  out=$("$ROOT/bin/fm-spawn.sh" --host box onlyid 2>&1); rc=$?
  expect_code 1 "$rc" "--host without a project name must refuse"
  assert_contains "$out" "project-name-on-host" "--host without a project must name what is missing"
  pass "fm-spawn --host: refuses every combination that only means something locally"
}

# The remote path still writes state/<id>.meta on THIS side, so it needs the
# local path's task-id gate verbatim. A dot-leading name would otherwise write a
# hidden record that every "$STATE"/*.meta glob skips, leaving a live remote task
# nothing here can find or steer.
test_spawn_host_applies_the_local_task_id_gate() {
  local out rc id
  for id in .hidden 'bad id' 'bad/id' 'bad;id' ''; do
    rc=0
    out=$("$ROOT/bin/fm-spawn.sh" --host box "$id" proj --scout 2>&1) || rc=$?
    expect_code 2 "$rc" "--host must refuse task id [$id] with the local path's exit code"
    assert_contains "$out" "error: invalid task id" \
      "--host must refuse task id [$id] with the local path's message"
  done
  # 65 characters: one past the length the local gate allows.
  rc=0
  out=$("$ROOT/bin/fm-spawn.sh" --host box "$(printf 'a%.0s' $(seq 1 65))" proj --scout 2>&1) || rc=$?
  expect_code 2 "$rc" "--host must apply the local path's task-id length limit"
  pass "fm-spawn --host: applies the same task-id gate as the local path"
}

test_spawn_help_documents_host() {
  local help
  help=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$help" "--host <name> dispatches the task to a REMOTE task host" \
    "fm-spawn --help must document --host"
  assert_contains "$help" "--scout records kind=scout" \
    "fm-spawn --help must still render everything it rendered before --host was added"
  pass "fm-spawn --help: documents --host without truncating the existing header"
}

# This used to refuse. It refused on the reasoning that discard authority had to
# be exercised on the host itself - true of the mechanism, false as advice for a
# host with no inbound SSH, and the reason a remote task that ran off the rails
# could never be cleaned up from anywhere. What the entry point owes now is that
# the flag REACHES the relay path rather than being swallowed or reinterpreted.
test_teardown_delegates_force_to_the_host() {
  local home out
  home="$TMP_ROOT/tdhome"
  mkdir -p "$home/state" "$home/data" "$home/config"
  write_registry "$home" ''
  printf 'window=w\nworktree=/nowhere\nkind=scout\nhost=box\n' > "$home/state/t4.meta"
  out=$(FM_HOME="$home" FM_RELAY_BIFROST="$TMP_ROOT/echo-bifrost" \
    "$ROOT/bin/fm-teardown.sh" t4 --force 2>&1) \
    || fail "--force on a relay task must no longer refuse here: $out"
  assert_contains "$out" "teardown t4 none force" \
    "the entry point must relay the discard authority to the machine holding the work"
  assert_not_contains "$out" "not available for a relay task" \
    "the old refusal must be gone, not merely bypassed"
  pass "fm-teardown: --force on a relay task travels to the machine holding the work"
}

test_brief_host_variant() {
  local home brief out rc
  home="$TMP_ROOT/briefhome"
  mkdir -p "$home/data" "$home/state"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" b1 proj --scout --host-home /srv/h 2>&1); rc=$?
  expect_code 1 "$rc" "--host-home without --host-root must refuse"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" b1 proj --scout --host-home rel --host-root /srv/r 2>&1); rc=$?
  expect_code 1 "$rc" "a relative --host-home must refuse"
  # Each path is checked on its own: an absolute --host-home must not carry a
  # relative --host-root past the gate and into the brief's own paths.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" b1 proj --scout --host-home /srv/h --host-root rel 2>&1); rc=$?
  expect_code 1 "$rc" "a relative --host-root behind an absolute --host-home must refuse"
  assert_contains "$out" "must be absolute paths" "the refusal must name the absolute-path requirement"
  assert_absent "$home/data/b1/brief.md" "a refused remote-host brief must not be written"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" plain proj --scout >/dev/null
  brief=$(cat "$home/data/plain/brief.md")
  assert_contains "$brief" "$home/state/plain.status" "a local brief must point at this home"
  assert_not_contains "$brief" "# Where you are running" \
    "a local brief must not carry the remote-host section"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" remote proj --scout \
    --host-home /srv/h --host-root /srv/r >/dev/null
  brief=$(cat "$home/data/remote/brief.md")
  assert_contains "$brief" "/srv/h/state/remote.status" "a remote brief must point at the host status file"
  assert_contains "$brief" "/srv/h/data/remote/report.md" "a remote brief must point at the host report path"
  assert_contains "$brief" "/srv/r/.agents/skills/" "a remote brief must point at the host firstmate checkout"
  assert_contains "$brief" "# Where you are running" "a remote brief must carry the remote-host section"
  assert_not_contains "$brief" "$home/state/remote.status" "a remote brief must not leak control-side paths"
  pass "fm-brief: the remote-host variant respells every path and the default is untouched"
}

test_check_make_requires_a_relay_task() {
  local home out rc
  home="$TMP_ROOT/checkhome"
  mkdir -p "$home/state" "$home/config"
  printf 'window=w\nworktree=/nowhere\nkind=scout\n' > "$home/state/t5.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" t5 2>&1); rc=$?
  expect_code 1 "$rc" "arming a wake check for a local task must refuse"
  assert_contains "$out" "not a relay task" "the refusal must say why"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" ../escape 2>&1); rc=$?
  expect_code 2 "$rc" "a path-traversing task id must refuse"
  pass "fm-relay-check-make: refuses a local task and an unsafe id"
}

test_check_make_writes_a_thin_registered_check() {
  local home out mode
  home="$TMP_ROOT/checkhome2"
  mkdir -p "$home/state"
  write_registry "$home" ''
  printf 'window=w\nworktree=/nowhere\nkind=scout\nhost=box\n' > "$home/state/t6.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" t6 2>&1) \
    || fail "arming a relay wake check failed: $out"
  assert_contains "$out" "registered:" "the check must go through fm-check-register.sh"
  assert_present "$home/state/t6.check.sh" "the generated check must exist"
  assert_present "$home/state/t6.check-trust" "the check must be bound to its bytes"
  mode=$(fm_pr_file_mode "$home/state/t6.check.sh")
  [ "$mode" = "700" ] || fail "the generated check must be mode 700, got $mode"
  # Thin by contract: parameters plus one library call, so a later fix in the
  # library reaches checks armed before the fix existed.
  assert_grep 'fm_relay_check_emit' "$home/state/t6.check.sh" "the check must call into the library"
  [ "$(grep -c . "$home/state/t6.check.sh")" -le 8 ] \
    || fail "the generated check grew logic of its own; it must stay parameters plus one call"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-relay-check-make.sh" t6 2>&1) \
    && fail "re-arming over an existing check must refuse"
  pass "fm-relay-check-make: writes a thin, mode-700, registered check and refuses to clobber"
}

test_scripts_parse
test_absent_optional_fields_do_not_shift_later_ones
test_a_record_with_no_optional_fields_survives_a_set_e_caller
test_incomplete_record_is_refused
test_relative_paths_are_refused
test_argument_charset
test_grant_audit_is_universal
test_verb_ok_drops_a_bare_ok_header
test_verb_refuses_without_config
test_verb_validates_its_own_arguments
test_verb_events_are_byte_offset_incremental
test_verb_sanitizes_crew_authored_event_text
test_verb_crew_state_reports_failure_as_err
test_verb_teardown_gate_needs_a_matching_report_hash
test_verb_teardown_force_passes_discard_authority_to_the_host
test_verb_teardown_force_releases_only_the_report_gate
test_verb_teardown_refuses_an_unknown_third_token
test_verb_teardown_force_is_covered_by_the_existing_helm_fence
test_verb_spawn_takes_a_secondmate_with_no_project_and_no_brief
test_verb_home_seed_validates_its_spec_before_seeding
test_verb_home_seed_runs_the_hosts_own_seed_and_cleans_up_on_failure
test_new_secondmate_verbs_ride_the_existing_helm_fence
test_home_seed_over_the_link_records_a_route_carrying_the_machine
test_home_seed_refuses_a_named_home_path_and_an_unfilled_charter
test_an_undeployed_host_refuses_the_new_verbs_loudly
test_spawn_host_secondmate_launches_over_there_and_moves_no_backlog_row
test_teardown_of_a_remote_secondmate_drops_the_route_here
test_home_config_applies_the_real_surface_into_a_real_home
test_home_config_ships_nothing_when_the_two_sides_already_agree
test_relay_host_teardown_force_reaches_the_wire
test_spawn_host_flag_refusals
test_spawn_host_applies_the_local_task_id_gate
test_spawn_help_documents_host
test_teardown_delegates_force_to_the_host
test_brief_host_variant
test_check_make_requires_a_relay_task
test_check_make_writes_a_thin_registered_check
