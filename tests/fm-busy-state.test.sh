#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source pi-ext --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "idle pi-ext" ] || fail "expected 'idle pi-ext', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "expected 'busy pi-ext', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-recovery --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "idle fm-recovery" ] || fail "expected 'idle fm-recovery', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source pi-ext --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

test_retire_serializes_and_rejects_stale_gen() {
  local state old_gen new_gen out retire_pid i=0
  state=$(new_state_dir retire)
  old_gen=$("$EV" arm "$state" t1)
  mkdir "$state/t1.busy-state.lock"
  "$EV" retire "$state" t1 --gen "$old_gen" >/dev/null 2>&1 &
  retire_pid=$!
  while [ "$i" -lt 20 ] && ! kill -0 "$retire_pid" 2>/dev/null; do
    i=$((i + 1))
  done
  [ -e "$state/t1.busy-state" ] || fail "retire bypassed the writer lock"
  rmdir "$state/t1.busy-state.lock"
  wait "$retire_pid" || fail "retire failed after acquiring the writer lock"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"

  new_gen=$("$EV" arm "$state" t1)
  if "$EV" retire "$state" t1 --gen "$old_gen" 2>/dev/null; then
    fail "retire accepted a superseded incarnation"
  fi
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale retirement changed the new incarnation, got '$out'"
  [ "$(cat "$state/t1.busy-gen")" = "$new_gen" ] || fail "stale retirement changed the new gen"
  pass "retire waits for the writer lock and cannot remove a new incarnation"
}

# Regression for issue #2625: the writer lock's stale-lock branch resolved the
# lock's mtime with `stat -f %m ... || stat -c %Y ...`. On GNU coreutils `-f` is
# *filesystem* stat, so it consumes the format string as a path, complains on
# stderr, prints "  File: ..." on stdout, and still exits 0 - the GNU form in the
# fallback never ran. The following `$((now - mtime))` then evaluated the word
# `File`, which under `set -u` aborted the writer with "File: unbound variable".
# fm-teardown.sh died there after returning the worktree, leaving state/<id>.meta
# and friends behind to generate stale wakes forever, and every re-run died
# identically because the abandoned lock directory was never broken.
#
# The stat and uname stubs make this deterministic on any host: the writer must
# take the Linux path and still break a provably stale lock.
test_stale_lock_broken_under_gnu_stat() {
  local state gen fakebin real_uname out status
  state=$(new_state_dir gnu-stat-lock)
  gen=$("$EV" arm "$state" t1)
  fakebin=$(fm_fakebin "$TMP_ROOT/gnu-stat-lock")
  real_uname=$(command -v uname)

  # GNU coreutils semantics, self-contained so no real stat is consulted.
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
  printf '%s\n' 1000000000   # long-abandoned lock
  exit 0
fi
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  shift 2
  printf '  File: "%s"\n' "${1:-}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/stat"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then printf 'Linux\n'; exit 0; fi
exec "$real_uname" "\$@"
SH
  chmod +x "$fakebin/uname"

  mkdir "$state/t1.busy-state.lock"
  out=$(PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --gen "$gen" 2>&1) && status=0 || status=$?
  case "$out" in
    *'unbound variable'*) fail "the writer still dies on GNU stat output: $out" ;;
  esac
  [ "$status" = 0 ] || fail "retire did not break a provably stale writer lock: $out"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"
  [ ! -e "$state/t1.busy-state.lock" ] || fail "retire left the stale lock behind"

  # Teardown must be able to run again over the same task without failing.
  PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --current-gen \
    || fail "a repeated retire over already-cleaned state was not idempotent"
  pass "the writer breaks a stale lock instead of dying on GNU stat output"
}

test_retire_missing_sidecar_is_idempotent() {
  local state gen
  state=$(new_state_dir retire-missing)
  gen=$("$EV" arm "$state" t1)
  rm -f "$state/t1.busy-gen"

  "$EV" retire "$state" t1 --gen "$gen" || fail "exact-gen retire rejected a missing sidecar"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left an orphan record behind"
  "$EV" retire "$state" t1 --gen "$gen" || fail "repeated exact-gen retire was not idempotent"
  "$EV" retire "$state" t1 --current-gen || fail "current-gen retire was not idempotent"

  printf 'malformed gen\n' > "$state/t1.busy-gen"
  printf 'orphan\n' > "$state/t1.busy-state"
  if "$EV" retire "$state" t1 --gen "$gen" 2>/dev/null; then
    fail "retire accepted a malformed existing sidecar"
  fi
  [ -e "$state/t1.busy-state" ] || fail "retire removed the record for a malformed existing sidecar"
  pass "retire treats only an absent sidecar as already retired"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source pi-ext --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in pi traex; do
    out=$(fm_busy_classify herdr w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify herdr w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=pi-ext event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=pi-ext event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=pi-ext event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=pi-ext event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify herdr w1 pi t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=pi-ext event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=pi-ext event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source foreign-source --event agent-start
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "foreign record trusted by Pi: $out"
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "Pi record was not trusted: $out"
  out=$(fm_busy_classify herdr w1 traex t1 "$state")
  [ "$out" = "unknown traex-transcript" ] || fail "Pi record trusted by TraeX: $out"
  pass "semantic records are trusted only by their adapter"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in pi traex; do
    out=$(fm_busy_classify herdr w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify herdr w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify herdr w1 codex t1 "$state")
  [ "$out" = "unknown codex-transcript" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live herdr w1 pi t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live herdr w1 pi t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live herdr '' pi t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p pi t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p pi t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source pi-ext --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p pi t1 "$state")
  [ "$out" = "idle pi-ext" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

# The record parser runs inside sourcing callers (the watcher, the daemon, the
# crew-state reader), so it must not disturb their shell: no clobbered
# positional parameters and no changed glob setting.
test_record_read_leaves_caller_shell_intact() {
  local state out
  state=$(new_state_dir parser-isolation)
  "$EV" arm "$state" t1 >/dev/null
  out=$(bash -c '
    set -f
    . "$1/bin/fm-busy-lib.sh"
    set -- keepme second
    fm_busy_record_read "$2" t1 >/dev/null
    printf "%s|%s|%s" "$1" "$#" "$-"
  ' _ "$ROOT" "$state")
  case "$out" in
    keepme\|2\|*f*) : ;;
    *) fail "record parsing disturbed the caller's shell: $out" ;;
  esac
  # A glob-shaped field must survive parsing literally rather than expanding.
  printf 'v1 gen=%s seq=1 state=busy source=* event=x ts=1\n' "$(cat "$state/t1.busy-gen")" \
    > "$state/t1.busy-state"
  out=$(fm_busy_classify herdr w1 pi t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "a glob-shaped source must be rejected, not expanded, got '$out'"
  pass "record parsing never clobbers the caller's positional parameters, glob setting, or fields"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy herdr w1 pi t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source pi-ext --event stop
  if fm_busy_is_busy herdr w1 pi t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy herdr w1 pi t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

test_progress_is_generation_bound_and_not_semantic_state() {
  local state gen replacement before
  state=$(new_state_dir native-progress)
  gen=$("$EV" arm "$state" t1)
  before=$(cat "$state/t1.busy-state")
  "$EV" progress "$state" t1 --gen "$gen" || fail "current progress was refused"
  [ -f "$state/t1.progress" ] || fail "progress marker missing"
  [ ! -e "$state/t1.turn-ended" ] || fail "progress emitted a completed turn"
  [ "$(cat "$state/t1.busy-state")" = "$before" ] || fail "progress changed semantic state"
  replacement=$("$EV" arm "$state" t1)
  [ ! -e "$state/t1.progress" ] || fail "arm retained the previous incarnation's progress"
  if "$EV" progress "$state" t1 --gen "$gen" 2>/dev/null; then fail "stale progress was accepted"; fi
  [ ! -e "$state/t1.progress" ] || fail "stale progress wrote a marker"
  "$EV" progress "$state" t1 --gen "$replacement" || fail "replacement progress was refused"
  "$EV" retire "$state" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$state/t1.progress" ] || fail "retire retained progress"
  pass "native progress is generation-bound, separately recorded, and cleared on arm and retire"
}

test_progress_is_generation_bound_and_not_semantic_state

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_retire_serializes_and_rejects_stale_gen
test_retire_missing_sidecar_is_idempotent
test_stale_lock_broken_under_gnu_stat
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_codex_unverified_gate
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_record_read_leaves_caller_shell_intact
test_boolean_view_never_promotes_unknown


test_task_bound_rollouts() {
  python3 - "$ROOT" "$TMP_ROOT/rollouts" <<'PYTEST' || fail 'task-bound rollout regressions failed'
import copy, json, os, pathlib, subprocess, sys
root, base = map(pathlib.Path, sys.argv[1:])
reader = root/'bin/fm-busy-transcript.py'

def run(*args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()

for harness, version in [('codex', '0.156.1'), ('traex', '0.207.1')]:
    home = base/harness
    state = home/'state'; state.mkdir(parents=True)
    cwd = home/'project'; cwd.mkdir()
    sessions = home/'sessions'; logs = sessions/'2026/09/25'; logs.mkdir(parents=True)
    log = logs/'rollout-main.jsonl'
    gen = run(root/'bin/fm-busy-event.sh', 'arm', state, 'worker', '--state', 'unknown')
    meta = f'backend=herdr\nharness={harness}\nworktree={cwd}\nwindow=lab:w1:p1\nbusy_gen={gen}\n'
    (state/'worker.meta').write_text(meta)
    run('python3', reader, 'init', state, 'worker', harness, cwd, sessions, 'herdr', 'lab:w1:p1')
    run('python3', reader, 'activate', state, 'worker')
    binding = (state/'worker.busy-session').read_text()
    records = [
        {'type':'session_meta','payload':{'id':'session-1','session_id':'session-1','cwd':str(cwd),
            'source':'cli','thread_source':'user','originator':harness+'-tui','cli_version':version}},
        {'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-1','root_turn_id':'turn-1'}},
        {'type':'event_msg','payload':{'type':'item_completed','thread_id':'session-1','turn_id':'turn-1',
            'item':{'type':'UserMessage','id':'initial-user','content':[{'type':'text','text':'brief\nFIRSTMATE_BUSY_GENERATION='+gen}]}}},
    ]
    complete = {'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-1','error':None}}
    def write(rows):
        with log.open('w') as f:
            for i, row in enumerate(rows): f.write(json.dumps(dict(row,ordinal=i))+'\n')
    def append(row):
        i = len(log.read_text().splitlines())
        with log.open('a') as f:f.write(json.dumps(dict(row,ordinal=i))+'\n')
    def reset():
        for p in logs.glob('*'):p.unlink()
        (state/'worker.busy-session').write_text(binding)
        (state/'worker.meta').write_text(meta)
        (state/'worker.busy-gen').write_text(gen+'\n')
        write(records)
    def expect(verdict, label):
        actual = run('python3', reader, 'read', state, 'worker', harness, 'herdr', 'lab:w1:p1')
        assert actual == verdict+' '+harness+'-transcript', (harness,label,actual)
        print('ok - '+harness+' '+label)
    def text_fence(text):
        script = '''source "$1/bin/fm-backend.sh"
fm_backend_source() { :; }
fm_backend_herdr_send_text_submit() { printf empty; }
fm_backend_send_text_submit herdr lab:w1:p1 "$2" 1 .01 .01
'''
        return subprocess.run(['bash', '-c', script, '_', str(root), text],
            env=dict(os.environ, FM_HOME=str(home)), capture_output=True, text=True)
    def user(text, turn='turn-1', thread='session-1'):
        return {'type': 'event_msg', 'payload': {'type': 'item_completed',
            'thread_id': thread, 'turn_id': turn,
            'item': {'type': 'UserMessage', 'id': 'user-' + str(len(log.read_text().splitlines())), 'content': [{'type': 'text', 'text': text}]}}}
    # Completion preserves superseded audit assignments as comments. Repeated
    # history and indented comments must not become effective identity fields.
    comments = ('# previous completion: decisions_reviewed=1\n'
                '# previous completion: decision_keys=older\n') * 2
    comments += (' \t# busy_gen=historical\n' * 2 +
                 '\t# window=old:w9:p9\n' * 2)
    commented_meta = comments + meta + 'decisions_reviewed=1\ndecision_keys=current\n'
    reset(); append(complete)
    (state/'worker.meta').write_text(commented_meta)
    expect('idle', 'repeated completion history and indented comments are ignored')
    assert text_fence('after completion audit').returncode == 0
    expect('unknown', 'comments do not consume pending text')
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('after completion audit', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2'}})
    expect('idle', 'normal text receipt settles with completion history retained')
    for invalid, label in [
        (commented_meta + f'busy_gen={gen}\n', 'duplicate effective generation'),
        (commented_meta + 'harness=other\n', 'conflicting effective harness'),
        (commented_meta.replace(f'busy_gen={gen}\n', 'busy_gen=other\n'), 'changed effective generation'),
        (commented_meta.replace('window=lab:w1:p1\n', 'window=lab:w9:p9\n'), 'wrong effective endpoint'),
    ]:
        reset(); append(complete)
        (state/'worker.meta').write_text(invalid)
        expect('unknown', label + ' still refuses beside comments')
        assert text_fence('must not be sent').returncode != 0, label
    reset(); append(complete)
    (state/'worker.meta').write_text(commented_meta)
    wrong = copy.deepcopy(records); wrong[0]['payload']['originator'] = 'other-tui'
    write(wrong + [complete])
    expect('unknown', 'comments cannot authorize invalid transcript provenance')
    assert text_fence('must not be sent').returncode != 0
    reset(); append(complete)
    (state/'worker.meta').write_text(commented_meta)
    run('python3', reader, 'fence-target', state, 'herdr', 'lab:w1:p1')
    run('python3', reader, 'fence-target', state, 'herdr', 'lab:w1:p1')
    expect('unknown', 'legacy input watermark survives completion history')
    assert text_fence('new text after old fences').returncode == 0
    accounted = json.loads((state/'worker.busy-session').read_text())
    assert accounted['required_starts'] == 3 and len(accounted['pending_inputs']) == 1
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('new text after old fences', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2'}})
    expect('unknown', 'consuming new text cannot clear the older root-start watermark')
    accounted = json.loads((state/'worker.busy-session').read_text())
    assert accounted['required_starts'] == 3 and accounted['pending_inputs'] == []
    reset(); expect('busy', 'bind before in-turn steering')
    assert text_fence('steer one').returncode == 0
    assert text_fence('steer two').returncode == 0
    append(user('steer one')); append(user('steer two'))
    expect('busy', 'multiple consumed inputs keep the same working root turn')
    append(complete); expect('idle', 'in-turn receipts settle without artificial root starts')
    reset(); expect('busy', 'bind before unconsumed input')
    assert text_fence('wanted').returncode == 0
    append(user('unrelated')); expect('busy', 'working turn is not input-consumption proof')
    append(complete); expect('unknown', 'unrelated user message cannot settle pending input')
    reset(); append(complete); expect('idle', 'bind before root-turn text input')
    assert text_fence('new root').returncode == 0
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('new root', 'turn-2')); expect('busy', 'matching root-turn input receipt')
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2','error':{'message':'simulated failure'}}})
    expect('idle', 'consumed input can settle with API failure')
    reset(); expect('busy', 'bind before identical inputs')
    assert text_fence('same').returncode == 0
    assert text_fence('same').returncode == 0
    append(user('same')); expect('busy', 'one receipt cannot consume two identical sends')
    append(complete); expect('unknown', 'second identical input remains unconsumed')
    reset(); expect('busy', 'bind before partial read retry')
    assert text_fence('late receipt').returncode == 0
    row = json.dumps(dict(user('late receipt'), ordinal=3)) + '\n'
    with log.open('a') as f: f.write(row[:20])
    expect('unknown', 'partial consumption record remains uncertain')
    with log.open('a') as f: f.write(row[20:])
    expect('busy', 'complete matching record resolves transient read')
    append(complete); expect('idle', 'retry preserves exact consumption attribution')
    reset(); expect('busy', 'bind before failed pre-input read')
    row = json.dumps({'type':'response_item','ordinal':3,'payload':{}}) + '\n'
    with log.open('a') as f: f.write(row[:20])
    refused = text_fence('never sent')
    assert refused.returncode != 0 and 'partial-record' in refused.stderr, refused
    with log.open('a') as f: f.write(row[20:])
    append(complete); expect('idle', 'refused transport creates no phantom input')
    assert text_fence('retry input').returncode == 0
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('retry input', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'turn_aborted','turn_id':'turn-2','reason':'interrupted'}})
    expect('idle', 'retried exact input and real cancellation settle')
    reset(); expect('busy', 'bind before wrong-thread receipt')
    assert text_fence('steer').returncode == 0
    append(user('steer', thread='other')); expect('unknown', 'wrong-thread consumption refused')
    reset(); expect('busy', 'bind before wrong-turn receipt')
    assert text_fence('steer').returncode == 0
    append(user('steer', turn='other')); expect('unknown', 'wrong-turn consumption refused')
    reset(); append(complete); expect('idle', 'bind before legacy uncertainty')
    legacy = json.loads((state/'worker.busy-session').read_text()); legacy['unaccounted_input'] = True
    (state/'worker.busy-session').write_text(json.dumps(legacy))
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('arbitrary', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2'}})
    expect('unknown', 'legacy unaccounted input never healed by readable unrelated records')
    reset(); expect('busy', 'bind before compaction')
    assert text_fence('after compaction').returncode == 0
    append({'type':'compacted','payload':{'message':'summary'}})
    append(user('after compaction')); append(complete)
    expect('idle', 'append-only compaction preserves receipts and lifecycle')
    reset(); expect('busy', 'bind before duplicate ordinal')
    assert text_fence('duplicate').returncode == 0
    append(user('duplicate'))
    with log.open('a') as f: f.write(json.dumps(dict(user('duplicate'), ordinal=3))+'\n')
    expect('unknown', 'replayed record ordinal cannot become another consumption')
    reset(); append(complete); expect('idle', 'bind before malformed neighbor')
    (state/'neighbor.busy-session').write_text('invalid')
    (state/'neighbor.meta').write_text('backend=herdr\nwindow=lab:other:p2\nharness=codex\nharness=traex\n')
    assert text_fence('neighbor unaffected').returncode == 0
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append(user('neighbor unaffected', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2'}})
    expect('idle', 'unrelated damaged task cannot affect exact-target input receipts')
    reset(); expect('busy', 'bind before malformed input accounting')
    damaged = json.loads((state/'worker.busy-session').read_text())
    damaged['pending_inputs'] = [{'after': 2, 'digest': 'not a hash'}]
    (state/'worker.busy-session').write_text(json.dumps(damaged))
    expect('unknown', 'malformed receipt accounting is never normalized')
    assert json.loads((state/'worker.busy-session').read_text())['last_refusal'] == {'stage':'read','reason':'malformed-record'}
    reset(); expect('busy', 'bind before diagnostic redaction')
    with log.open('a') as f: f.write('do-not-log-this-secret\n')
    refused = text_fence('do-not-log-input')
    assert refused.returncode != 0 and 'malformed-record' in refused.stderr, refused
    assert 'do-not-log' not in refused.stderr
    assert json.loads((state/'worker.busy-session').read_text())['last_refusal'] == {'stage':'fence','reason':'malformed-record'}
    if os.geteuid() != 0:
        reset(); append(complete); expect('idle', 'bind before unreadable transient')
        log.chmod(0)
        try:
            refused = text_fence('not delivered')
            assert refused.returncode != 0 and 'transient-read' in refused.stderr, refused
        finally:
            log.chmod(0o600)
        expect('idle', 'restored readability after refused send does not invent consumption')
    reset(); expect('busy', 'bind before replayed typed user item')
    assert text_fence('same').returncode == 0
    assert text_fence('same').returncode == 0
    replay = user('same'); append(replay); append(replay); append(complete)
    expect('unknown', 'duplicate vendor user identity cannot account for two inputs')
    reset(); expect('busy','active turn')
    append({'type':'response_item','payload':{'type':'function_call_output','call_id':'tool-1','output':'exit code 7'}})
    expect('busy','tool failure does not end the turn')
    append(complete); expect('idle','normal completion')
    # Exercise the public backend dispatcher, including the ordering of fencing
    # before a mocked transport failure. No implementation text is inspected.
    script = '''source "$1/bin/fm-backend.sh"
fm_backend_source() { :; }
fm_backend_herdr_send_text_submit() { return 9; }
fm_backend_send_text_submit herdr lab:w1:p1 next 1 .01 .01
'''
    result = subprocess.run(['bash','-c',script,'_',str(root)], env=dict(os.environ,FM_HOME=str(home)))
    assert result.returncode == 9
    expect('unknown','submit-before-log and transport failure cannot reuse old idle')
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    expect('busy','next matching turn clears submission fence')
    append(user('next', 'turn-2'))
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2','error':{'message':'simulated 401'}}})
    expect('idle','API failure terminal settles turn')
    reset(); append({'type':'event_msg','payload':{'type':'turn_aborted','turn_id':'turn-1','reason':'interrupted'}})
    expect('idle','user interrupt settles matching turn')
    reset(); append(complete); expect('idle','bind exact session')
    saved = log.read_bytes(); log.unlink(); expect('unknown','missing bound log')
    log.write_bytes(saved); expect('unknown','replacement inode cannot rebind')
    reset(); expect('busy','bind before truncation'); log.write_text(''); expect('unknown','truncated bound log')
    reset(); append(complete); expect('idle','bind before prefix rewrite')
    write(records+[dict(complete,payload={'type':'task_complete','turn_id':'turn-X'})]); expect('unknown','rewritten prefix')
    reset(); append(complete); expect('idle','bind before otherwise-valid history rewrite')
    changed=copy.deepcopy(records);changed[2]['payload']['item']['content'][0]['text']='changed brief\nFIRSTMATE_BUSY_GENERATION='+gen
    write(changed+[complete]);expect('unknown','same session cannot rewrite an observed prefix')
    reset(); log.write_text(log.read_text()+'{"type":'); expect('unknown','partial tail')
    reset(); log.write_text(log.read_text()+'invalid\n'); expect('unknown','corrupt record')
    reset(); log.write_text(log.read_text()+'[]\n'); expect('unknown','wrong JSON record shape')
    reset(); other=logs/'rollout-duplicate.jsonl';other.write_bytes(log.read_bytes()); expect('unknown','ambiguous sessions')
    reset(); child=copy.deepcopy(records);child[0]['payload']['source']={'subagent':'worker'}; write(child)
    expect('unknown','child session excluded even with copied marker')
    reset(); wrong=copy.deepcopy(records);wrong[0]['payload']['cwd']=str(home/'other');write(wrong)
    expect('unknown','canonical task path mismatch')
    reset(); wrong=copy.deepcopy(records);wrong[0]['payload']['session_id']='session-other';write(wrong)
    expect('unknown','session identity mismatch')
    reset(); wrong=copy.deepcopy(records);wrong[0]['payload']['cli_version']='999.0.0';write(wrong)
    expect('unknown','unverified version')
    reset(); wrong=copy.deepcopy(records);wrong[2]['payload']['item']['content'][0]['text']='FIRSTMATE_BUSY_GENERATION=old';write(wrong)
    append(complete);expect('unknown','reused slot old launch generation')
    reset(); (state/'worker.busy-gen').write_text('replacement\n');expect('unknown','retired busy generation')
    reset(); (state/'worker.busy-session').unlink();expect('unknown','missing binding')
    reset(); (state/'worker.busy-gen').unlink();expect('unknown','missing generation sidecar')
    reset(); append(dict(complete,payload={'type':'task_complete','turn_id':'old-turn'}));expect('unknown','mismatched terminal turn')
    reset(); append(complete);run('python3',reader,'fence-target',state,'herdr','lab:w1:p1')
    run('python3',reader,'fence-target',state,'herdr','lab:w1:p1')
    append({'type':'event_msg','payload':{'type':'task_started','turn_id':'turn-2','root_turn_id':'turn-2'}})
    append({'type':'event_msg','payload':{'type':'task_complete','turn_id':'turn-2'}})
    expect('unknown','two pending submissions need two observed starts')
    reset();append(complete);expect('idle','bind before unreadable submission');log.unlink()
    denied=subprocess.run(['python3',str(reader),'fence-target',str(state),'herdr','lab:w1:p1'],capture_output=True,text=True)
    assert denied.returncode != 0
    write(records+[complete])
    expect('unknown','lost watermark cannot later resurrect old idle')
    reset()
    # The classifier's liveness input is backed by a real short-lived process.
    process=subprocess.Popen(['sleep','30'])
    def classify():
        code='''source "$1/bin/fm-busy-lib.sh"
probe_pid=$5
fm_backend_agent_state() { if kill -0 "$probe_pid" 2>/dev/null; then printf alive; else printf dead; fi; }
fm_busy_classify herdr lab:w1:p1 "$2" worker "$3"
'''
        return run('bash','-c',code,'_',root,harness,state,'unused',process.pid)
    assert classify() == 'busy '+harness+'-transcript'
    process.terminate();process.wait()
    assert classify() == 'dead endpoint-gone'
    print('ok - '+harness+' process exit overrides an open transcript turn')
PYTEST
}

test_task_bound_rollouts

python3 "$ROOT/tests/busy-recovery.py" "$ROOT" "$TMP_ROOT/recovery-codex" codex || fail 'Codex busy recovery regressions failed'
python3 "$ROOT/tests/busy-recovery.py" "$ROOT" "$TMP_ROOT/recovery-traex" traex || fail 'TraeX busy recovery regressions failed'
echo "all fm-busy-state tests passed"
