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
#     flag that only means something locally.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-relay)

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

# --- host= branches in the existing scripts -----------------------------------

test_spawn_host_flag_refusals() {
  local out rc
  out=$("$ROOT/bin/fm-spawn.sh" --host 2>&1); rc=$?
  expect_code 1 "$rc" "--host with no value must refuse"
  assert_contains "$out" "--host requires a value" "--host with no value must say so"
  out=$("$ROOT/bin/fm-spawn.sh" --host box id proj --secondmate 2>&1); rc=$?
  expect_code 1 "$rc" "--host with --secondmate must refuse"
  assert_contains "$out" "does not support --secondmate" "--host + --secondmate must say so"
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

test_teardown_refuses_force_on_a_relay_task() {
  local home out rc
  home="$TMP_ROOT/tdhome"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w\nworktree=/nowhere\nkind=scout\nhost=box\n' > "$home/state/t4.meta"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" t4 --force 2>&1); rc=$?
  expect_code 1 "$rc" "--force on a relay task must refuse"
  assert_contains "$out" "not available for a relay task" \
    "--force on a relay task must say discard authority belongs on the host"
  pass "fm-teardown: --force is refused for a task owned by another machine"
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
test_spawn_host_flag_refusals
test_spawn_host_applies_the_local_task_id_gate
test_spawn_help_documents_host
test_teardown_refuses_force_on_a_relay_task
test_brief_host_variant
test_check_make_requires_a_relay_task
test_check_make_writes_a_thin_registered_check
