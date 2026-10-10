#!/usr/bin/env bash
# Resolved dispatch validation through real fm-spawn, isolated homes/git copies,
# and fixture tmux/treehouse endpoints. No real fleet or harness is launched.
# T1-T6 cover absence, typed allow, refusal, deadlines, digest/bytes and batch.
# T7 is outside the fresh-only contract: relaunch/promotion are not enabled.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-validation)
HAVE_TASKS=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS=1

make_case() {
  local name=$1 id
  shift
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home with spaces"
  PROJ_DIR="$CASE_DIR/project with spaces"
  WT_DIR="$CASE_DIR/worktree"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/tools" codex gh gh-axi no-mistakes)
  fm_test_spawn_home "$HOME_DIR" codex
  printf 'tmux\n' > "$HOME_DIR/config/backend"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fixture-$name"
  : > "$CASE_DIR/calls"
  : > "$CASE_DIR/launch"
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-fixture"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_VALIDATION_CASE/calls"
if [ "${1:-}" = new-window ] && [ -n "${FM_MUTATE_AFTER_VALIDATION:-}" ]; then
  printf '\nchanged after validation\n' >> "$FM_MUTATE_AFTER_VALIDATION"
fi
exec "$(dirname "$0")/tmux-fixture" "$@"
SH
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_VALIDATION_CASE/calls"
exit 0
SH
  chmod +x "$FAKEBIN/tmux" "$FAKEBIN/treehouse"
  if [ "$HAVE_TASKS" = 1 ]; then
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
    printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  else
    printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
    printf 'queued fixture\n' > "$HOME_DIR/data/backlog.md"
  fi
  for id in "$@"; do
    fm_test_spawn_brief "$HOME_DIR" "$id"
    if [ "$HAVE_TASKS" = 1 ]; then
      tasks-axi add "$id" "validation fixture $id" --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'fixture backlog add failed'
    fi
  done
  cp "$HOME_DIR/data/backlog.md" "$CASE_DIR/backlog-before"
}

run_spawn() {
  FM_VALIDATION_CASE="$CASE_DIR" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch" FM_BACKEND=tmux \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$@"
}

ship() { run_spawn "$1" "$PROJ_DIR" codex --mode no-mistakes --yolo off; }

validator() {
  cat > "$HOME_DIR/config/dispatch-validator" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys
import time

request = json.load(sys.stdin)
case = Path(os.environ['FM_VALIDATION_CASE'])
with (case / 'requests').open('a') as log:
    log.write(json.dumps(request) + '\n')
behavior = (case / 'behavior').read_text().strip()
result = dict(schema_version=1, decision='allow', request_sha256=request['request_sha256'])
if behavior == 'batch' and request['task_id'] == 'first':
    result['decision'] = 'refuse'
elif behavior == 'refuse':
    print('policy says no', file=sys.stderr)
    result['decision'] = 'refuse'
elif behavior == 'nonzero':
    print(json.dumps(result), flush=True)
    print('validator failed', file=sys.stderr)
    sys.exit(7)
elif behavior == 'empty':
    sys.exit(0)
elif behavior == 'malformed':
    print('not JSON')
    sys.exit(0)
elif behavior == 'schema':
    result['schema_version'] = True
elif behavior == 'decision':
    result['decision'] = 0
elif behavior == 'digest':
    result['request_sha256'] = '0' * 64
elif behavior == 'replay':
    result['request_sha256'] = json.loads((case / 'other-request').read_text())['request_sha256']
elif behavior == 'changed':
    with open(request['effective_brief_path'], 'a') as brief:
        brief.write('\nchanged during validation\n')
elif behavior == 'extra':
    result['other'] = 'not in schema'
elif behavior == 'duplicate':
    print('{"schema_version":1,"schema_version":1,"decision":"allow","request_sha256":"' + request['request_sha256'] + '"}')
    sys.exit(0)
elif behavior == 'oversize':
    print('x' * 65537)
    sys.stdout.flush()
    sys.exit(0)
elif behavior == 'timeout':
    # An apparent allow before hanging must not be accepted. Ordinary children
    # inherit this group and must also be reaped by the production watchdog.
    pid = os.fork()
    if pid == 0:
        (case / 'child-pid').write_text(str(os.getpid()))
        while True:
            time.sleep(1)
print(json.dumps(result), flush=True)
if behavior == 'timeout':
    print('validator is hanging', file=sys.stderr, flush=True)
    while True:
        time.sleep(1)
PY
  chmod +x "$HOME_DIR/config/dispatch-validator"
  printf '%s\n' "$1" > "$CASE_DIR/behavior"
}

refused() {
  local id=$1
  [ ! -s "$CASE_DIR/launch" ] || fail "refusal launched $id"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refusal published $id metadata"
  [ ! -e "$HOME_DIR/state/$id.busy" ] || fail "refusal armed $id"
  if grep -E '^(new-window|new-session|treehouse|send-keys)' "$CASE_DIR/calls" >/dev/null; then
    fail "refusal allocated an endpoint or worktree: $(cat "$CASE_DIR/calls")"
  fi
  cmp -s "$CASE_DIR/backlog-before" "$HOME_DIR/data/backlog.md" || fail 'refusal changed backlog'
  [ -z "$(find "$HOME_DIR/data/$id" -name '.validated-brief.*' -print)" ] || fail 'refusal retained scratch snapshot'
}

test_absent_and_home_scope() {
  local kind rc out
  for kind in ship scout; do
    make_case "absent-$kind" task
    mkdir -p "$CASE_DIR/other-home/config"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_DIR/other-home/config/dispatch-validator"
    chmod +x "$CASE_DIR/other-home/config/dispatch-validator"
    # An inactive hook must not start the added serializer.
    # shellcheck disable=SC2016 # the single-quoted stub expands when the stub runs
    printf '#!/usr/bin/env bash\nprintf invoked >> "$FM_VALIDATION_CASE/python-called"\nexit 1\n' > "$FAKEBIN/python3"
    chmod +x "$FAKEBIN/python3"
    rc=0
    if [ "$kind" = ship ]; then out=$(ship task) || rc=$?
    else out=$(run_spawn task "$PROJ_DIR" codex --scout) || rc=$?; fi
    [ "$rc" -eq 0 ] || fail "absent $kind: $out"
    [ -s "$CASE_DIR/launch" ] && [ -f "$HOME_DIR/state/task.meta" ] || fail 'absent hook changed normal launch'
    [ ! -e "$CASE_DIR/python-called" ] || fail 'absent hook used new dependency'
  done
  make_case config-override task
  validator refuse
  mkdir -p "$CASE_DIR/override"
  # The common fixture sets FM_CONFIG_OVERRIDE; explicitly replace it here.
  out=$(FM_VALIDATION_CASE="$CASE_DIR" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch" FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$CASE_DIR/override" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX='fake,1,0' PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-spawn.sh" task "$PROJ_DIR" codex --backend tmux --mode no-mistakes --yolo off 2>&1) || fail "config override: $out"
  [ ! -e "$CASE_DIR/requests" ] || fail 'used validator from another config directory'
  pass 'T1 absent ship/scout hooks add no serializer and effective config is isolated'
}

test_typed_allow_and_snapshot() {
  local kind out id snapshot
  for kind in ship scout raw base; do
    id=task
    make_case "allow-$kind" "$id"
    validator allow
    if [ "$kind" = base ]; then
      printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: main\n' >> "$HOME_DIR/data/$id/brief.md"
    fi
    case "$kind" in
      scout) out=$(run_spawn "$id" "$PROJ_DIR" codex --scout --model model-x --effort high) || fail "$out" ;;
      raw) out=$(run_spawn "$id" "$PROJ_DIR" 'codex --help' --mode no-mistakes --yolo off) || fail "$out" ;;
      base) out=$(run_spawn "$id" "$PROJ_DIR" codex --mode no-mistakes --yolo off --model model-x --effort high --base-branch main) || fail "$out" ;;
      *) out=$(run_spawn "$id" "$PROJ_DIR" codex --mode no-mistakes --yolo off --model model-x --effort high) || fail "$out" ;;
    esac
    snapshot=$(find "$HOME_DIR/data/$id" -name '.validated-brief.*' -print)
    [ -n "$snapshot" ] || fail 'allow did not retain accepted bytes for delivery'
    # Assertions read the actual request, artifact and launch, never source code.
    python3 - "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$snapshot" "$kind" <<'PY' || fail 'typed request or snapshot differs from delivery'
import hashlib, json, os, pathlib, sys
case, home, project, snapshot, kind = sys.argv[1:]
r = json.loads(pathlib.Path(case, 'requests').read_text())
digest = r.pop('request_sha256')
assert digest == hashlib.sha256(json.dumps(r, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
assert set(r) == {'schema_version', 'home', 'state_dir', 'data_dir', 'config_dir', 'task_id', 'kind',
                  'project', 'delivery_mode', 'base_branch', 'relaunch', 'effective_brief_path', 'brief_sha256'}
assert r['schema_version'] == 1 and r['relaunch'] is False
assert r['home'] == str(pathlib.Path(home).resolve()) and r['task_id'] == 'task'
assert r['state_dir'] == str(pathlib.Path(home, 'state').resolve())
assert r['data_dir'] == str(pathlib.Path(home, 'data').resolve())
assert r['config_dir'] == str(pathlib.Path(home, 'config'))
assert r['project'] == str(pathlib.Path(project).resolve())
assert r['kind'] == ('scout' if kind == 'scout' else 'ship')
assert r['delivery_mode'] == (None if kind == 'scout' else 'no-mistakes')
assert r['base_branch'] == ('main' if kind == 'base' else None)
meta = dict(line.split('=', 1) for line in pathlib.Path(home, 'state/task.meta').read_text().splitlines() if '=' in line)
assert meta['kind'] == r['kind'] and meta['project'] == r['project']
assert meta.get('mode') == r['delivery_mode'] and meta.get('base_branch') == r['base_branch']
assert r['effective_brief_path'] == str(pathlib.Path(home, 'data/task/launch-brief.md').resolve())
accepted = pathlib.Path(snapshot).read_bytes()
assert r['brief_sha256'] == hashlib.sha256(accepted).hexdigest()
assert os.stat(snapshot).st_mode & 0o777 == 0o400
assert snapshot in pathlib.Path(case, 'launch').read_text() or kind == 'raw'
assert pathlib.Path(r['effective_brief_path']).read_bytes() == accepted
PY
  done
  pass 'T2 typed ship/scout/raw/base allow binds request and delivered snapshot'
}

test_refusals_and_retry() {
  local behavior out rc
  for behavior in refuse nonzero empty malformed schema decision digest changed extra duplicate non-executable unreadable dangling missing-python; do
    make_case "refusal-$behavior" task
    validator "$behavior"
    case "$behavior" in
      non-executable) chmod -x "$HOME_DIR/config/dispatch-validator" ;;
      unreadable)
        # Root can read mode 0111; keep that capability explicit rather than
        # claiming an unreadable-file test whose precondition is false.
        chmod 111 "$HOME_DIR/config/dispatch-validator"
        if [ -r "$HOME_DIR/config/dispatch-validator" ]; then
          printf 'note: unreadable executable capability unavailable as this user\n'
          continue
        fi
        ;;
      dangling) rm -f -- "$HOME_DIR/config/dispatch-validator"; ln -s missing "$HOME_DIR/config/dispatch-validator" ;;
      missing-python)
        printf '#!/usr/bin/env bash\nexit 127\n' > "$FAKEBIN/python3"
        chmod +x "$FAKEBIN/python3"
        ;;
    esac
    rc=0; out=$(ship task) || rc=$?
    [ "$rc" -eq 1 ] || fail "$behavior did not refuse: $out"
    refused task
    case "$behavior" in
      refuse) assert_contains "$out" 'policy says no' 'validator stderr was lost' ;;
      nonzero) assert_contains "$out" 'validator failed' 'validator failure stderr was lost' ;;
    esac
    if [ "$behavior" = refuse ]; then
      printf 'allow\n' > "$CASE_DIR/behavior"
      out=$(ship task) || fail "refusal retained locks: $out"
      [ -f "$HOME_DIR/state/task.meta" ] || fail 'retry failed to publish'
    fi
  done
  # Reusing an allow for the same brief in another task/home is also refused.
  make_case replay-source other
  validator allow
  out=$(ship other) || fail "$out"
  cp "$CASE_DIR/requests" "$TMP_ROOT/other-request"
  make_case replay-target task
  validator replay
  cp "$TMP_ROOT/other-request" "$CASE_DIR/other-request"
  rc=0; out=$(ship task) || rc=$?
  [ "$rc" -eq 1 ] || fail "request replay was accepted: $out"
  refused task
  make_case changed-before-delivery task
  validator allow
  rc=0
  out=$(FM_MUTATE_AFTER_VALIDATION="$HOME_DIR/data/task/launch-brief.md" ship task) || rc=$?
  [ "$rc" -eq 1 ] || fail "brief change after validation launched: $out"
  assert_contains "$out" 'effective brief changed before launch' 'delivery did not refuse changed input'
  [ ! -s "$CASE_DIR/launch" ] || fail 'changed brief reached worker launch'
  [ ! -e "$HOME_DIR/state/task.meta" ] || fail 'changed brief retained provisional record'
  cmp -s "$CASE_DIR/backlog-before" "$HOME_DIR/data/backlog.md" || fail 'changed brief moved backlog'
  pass 'T3/T5 refusal preserves queued backlog and releases locks; invalid results cannot allow'
}

test_timeout_and_bounds() {
  local behavior out rc start elapsed pid state i
  for behavior in timeout oversize; do
    make_case "$behavior" task
    validator "$behavior"
    start=$(date +%s)
    rc=0; out=$(ship task) || rc=$?
    elapsed=$(( $(date +%s) - start ))
    [ "$rc" -eq 1 ] || fail "$behavior did not refuse: $out"
    [ "$elapsed" -lt 25 ] || fail "$behavior exceeded bounded fixture headroom: ${elapsed}s"
    refused task
    if [ "$behavior" = timeout ]; then
      assert_contains "$out" 'exit 124' 'hang did not reach the production timeout'
      assert_contains "$out" 'validator is hanging' 'timeout discarded validator stderr'
      pid=$(cat "$CASE_DIR/child-pid")
      for i in $(seq 1 50); do
        state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || state=
        case "$state" in ''|Z*) break ;; esac
        sleep 0.1
      done
      case "$state" in ''|Z*) ;; *) fail "validator child $pid survived timeout" ;; esac
    else
      assert_contains "$out" 'output exceeds 65536 bytes' 'output was not bounded'
    fi
  done
  pass 'T4 output before a hang cannot allow and ordinary validator descendants stop'
}

test_batch_and_capacity() {
  local out rc
  make_case batch first second
  validator batch
  rc=0
  out=$(run_spawn "first=$PROJ_DIR" "second=$PROJ_DIR" --harness codex --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -eq 1 ] || fail "batch refusal exit changed: $out"
  [ ! -e "$HOME_DIR/state/first.meta" ] && [ -e "$HOME_DIR/state/second.meta" ] || fail "batch did not continue independently: $out"
  python3 - "$CASE_DIR/requests" <<'PY' || fail 'batch did not validate once per pair'
import json, pathlib, sys
requests = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert [r['task_id'] for r in requests] == ['first', 'second']
assert requests[0]['request_sha256'] != requests[1]['request_sha256']
PY
  make_case capacity first second
  validator allow
  printf 'project with spaces 1\n' > "$HOME_DIR/config/project-capacity"
  out=$(ship first) || fail "$out"
  : > "$CASE_DIR/calls"
  : > "$CASE_DIR/launch"
  cp "$HOME_DIR/data/backlog.md" "$CASE_DIR/backlog-before"
  rc=0; out=$(ship second) || rc=$?
  [ "$rc" -eq 75 ] || fail "capacity exit changed: $out"
  refused second
  [ "$(wc -l < "$CASE_DIR/requests" | tr -d ' ')" -eq 1 ] || fail 'capacity refusal reached validator'
  [ ! -e "$HOME_DIR/data/second/launch-brief.md" ] || fail 'capacity no-render guarantee changed'
  pass 'T6 batch checks every pair despite guard suppression and preserves earlier capacity deferral'
}

test_absent_and_home_scope
test_typed_allow_and_snapshot
test_refusals_and_retry
test_timeout_and_bounds
test_batch_and_capacity
