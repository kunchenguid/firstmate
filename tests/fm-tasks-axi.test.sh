#!/usr/bin/env bash
# Canonical per-task record tests for bin/fm-tasks-axi.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_split() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

wrapper_from_code() {
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

bootstrap_backlog_lines() {
  local code=$1 home=$2
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
}

test_canonical_record_local_writes() {
  local dir before first_mtime second_mtime snapshot
  dir=$(make_split canonical)
  before=$(sha256sum "$dir/home/data/backlog.md")
  printf 'fixture body\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" add ship-1 'ship one' --kind ship --body-file body.md --start
  [ "$(jq -r '.body' "$dir/home/data/ship-1/task.json")" = 'fixture body' ] \
    || fail 'caller-relative body did not reach the canonical task record'
  [ "$before" = "$(sha256sum "$dir/home/data/backlog.md")" ] \
    || fail 'canonical add rewrote retained legacy backlog bytes'
  first_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  sleep 1
  wrapper_from_code "$dir" "done" ship-1 --pr https://example.invalid/pull/1
  second_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  [ "$second_mtime" -gt "$first_mtime" ] || fail 'done did not update the task record'
  [ "$(jq -r '.completion.verb' "$dir/home/data/ship-1/task.json")" = merged ] \
    || fail 'PR completion did not retain the merged verb'
  snapshot=$(FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/home/data" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail 'canonical completion snapshot failed'
  printf '%s' "$snapshot" | jq -e '
    any(.backlog.records[];.id=="ship-1" and .completion.verb=="merged" and .completion.date!=null)' \
    >/dev/null || fail 'canonical snapshot lost the merged completion fact'
  first_mtime=$second_mtime
  sleep 1
  wrapper_from_code "$dir" "done" ship-1 --pr https://example.invalid/pull/1
  second_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  [ "$first_mtime" = "$second_mtime" ] || fail 'idempotent done replay rewrote the record'
  pass 'fm-tasks-axi writes one canonical record and preserves inert legacy bytes'
}

test_ambient_file_cannot_redirect() {
  local dir
  dir=$(make_split ambient)
  printf 'decoy\n' > "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" \
    "$WRAPPER" add task-1 ambient >/dev/null) || fail 'canonical add under ambient file failed'
  assert_present "$dir/home/data/task-1/task.json" 'ambient file diverted canonical write'
  [ "$(cat "$dir/decoy.md")" = decoy ] || fail 'ambient file was rewritten'
  pass 'ambient shared-backlog variables cannot redirect canonical task writes'
}

test_removed_compatibility_arguments_refuse() {
  local dir rc=0 before
  dir=$(make_split removed-arguments)

  wrapper_from_code "$dir" add stable 'Stable task' --kind ship --start >/dev/null
  before=$(sha256sum "$dir/home/data/stable/task.json")

  wrapper_from_code "$dir" add queued 'Old queued spelling' --queue \
    >"$dir/out" 2>"$dir/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "obsolete --queue returned $rc instead of argparse usage failure"
  assert_absent "$dir/home/data/queued/task.json" "obsolete --queue created a task record"

  for obsolete in --keep --no-prune; do
    rc=0
    if [ "$obsolete" = --keep ]; then
      wrapper_from_code "$dir" "done" stable --keep 0 >"$dir/out" 2>"$dir/err" || rc=$?
    else
      wrapper_from_code "$dir" "done" stable --no-prune >"$dir/out" 2>"$dir/err" || rc=$?
    fi
    [ "$rc" -eq 2 ] || fail "obsolete $obsolete returned $rc instead of argparse usage failure"
    [ "$before" = "$(sha256sum "$dir/home/data/stable/task.json")" ] \
      || fail "obsolete $obsolete mutated the canonical task record"
  done

  rc=0
  wrapper_from_code "$dir" prune --keep 10 >"$dir/out" 2>"$dir/err" || rc=$?
  [ "$rc" -eq 2 ] || fail "removed prune command returned $rc instead of argparse usage failure"
  pass 'obsolete queue, retention, and prune compatibility inputs are rejected without writes'
}

test_task_directory_symlink_refuses() {
  local dir rc=0
  dir=$(make_split symlink)
  mkdir -p "$dir/outside"
  ln -s "$dir/outside" "$dir/home/data/task-1"
  wrapper_from_code "$dir" add task-1 unsafe >/dev/null 2>"$dir/error" || rc=$?
  [ "$rc" -ne 0 ] || fail 'symlinked task directory was accepted'
  assert_absent "$dir/outside/task.json" 'symlink refusal wrote outside the task data root'
  pass 'canonical wrapper refuses a symlinked task directory'
}

test_shadow_backlog_files_are_inert() {
  local dir out
  dir=$(make_split shadow)
  rm "$dir/code/data/backlog.md"
  printf 'retained shadow\n' > "$dir/code/data/backlog.md"
  printf 'retained archive shadow\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  [ -z "$out" ] || fail "bootstrap advertised reconciliation for retained legacy files: $out"
  pass 'bootstrap ignores retained code-root backlog and archive files'
}

test_authority_transitions_and_backfill() {
  local dir
  dir=$(make_split authority)
  if ! python3 - "$WRAPPER" "$dir/home" <<'PY'
import concurrent.futures, hashlib, json, os, pathlib, subprocess, sys
cli, root = sys.argv[1], pathlib.Path(sys.argv[2])
env = dict(os.environ, FM_HOME=str(root))
def run(*args, ok=True):
    result = subprocess.run([cli, *args], env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
    return result
run('add', 'active', 'Current goal', '--start')
run('hold', 'active', '--kind', 'captain', '--reason', 'decision')
run('add', 'queued', 'Queued goal')
run('add', 'ended', 'Ended goal')
run('hold', 'ended', '--kind', 'captain', '--reason', 'old call')
run('archive', 'ended')
ended = root/'data/ended/task.json'
before = ended.read_bytes()
run('start', 'ended', ok=False)
run('hold', 'ended', '--kind', 'captain', '--reason', 'new call', ok=False)
run('done', 'ended')
assert ended.read_bytes() == before
held = run('list', '--state', 'held').stdout
assert 'active,in_flight' in held and 'ended,' not in held
run('block', 'queued', '--by', 'ended')
assert 'queued' in json.loads(run('inventory').stdout)['ready_ids']
for name in ('old', 'home-record', 'orphan-report'):
    (root/'data'/name).mkdir()
    (root/'data'/name/'report.md').write_text('preserved report')
(root/'state/home-record.meta').write_text('kind=secondmate\nhome=/fixture/old-home\n')
(root/'state/orphan-report.status').write_text('old opaque status bytes\n')
(root/'state/status-only.status').write_text('done: legacy report without acceptance proof\n')
(root/'state/transferred-only.status').write_text('needs-decision [corr=review] [key=route]: choose route\ncaptain-held [key=route]: transferred to durable hold\n')
(root/'state/timestamp-only.status').write_text('[2026-01-01T12:00:00Z] working: legacy timestamp\n12:00:01 resolved: legacy answer\n')
(root/'data/backlog.md').write_text('## Done\n- [x] legacy - Legacy title (kind: ship) (repo: known) (done 2020-01-01)\n')
existing = {p: p.read_bytes() for p in (root/'data').glob('*/task.json')}
manifest = root/'preview.json'
manifest.write_text(run('backfill-archived', '--state-dir', str(root/'state'), '--preview').stdout)
preview = json.loads(manifest.read_text())
assert {e['id'] for e in preview['entries'] if e['disposition']=='absent'} == {'old','orphan-report','status-only','transferred-only','timestamp-only','legacy'}
assert any(e['id']=='home-record' for e in preview['exclusions'])
# Creation after preview wins without the importer overwriting the new active record.
run('add', 'old', 'Concurrently created', '--start')
existing[root/'data/old/task.json'] = (root/'data/old/task.json').read_bytes()
run('backfill-archived', '--state-dir', str(root/'state'), '--apply-file', str(manifest))
for p, raw in existing.items(): assert p.read_bytes() == raw
for name in ('orphan-report','status-only','transferred-only','timestamp-only','legacy'):
    record = json.loads((root/'data'/name/'task.json').read_bytes())
    assert record['state']=='archived' and record['completion'] is None
    assert not any(record['progress'].values())
assert json.loads((root/'data/legacy/task.json').read_bytes())['title']=='Legacy title'
all_before = {p: p.read_bytes() for p in (root/'data').glob('*/task.json')}
run('backfill-archived', '--state-dir', str(root/'state'), '--apply-file', str(manifest))
assert all(p.read_bytes()==raw for p,raw in all_before.items())
run('reopen','ended'); run('start','ended')
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(lambda i: subprocess.run([cli,'add','racing',f'creator {i}'],env=env,capture_output=True),range(8)))
assert sum(r.returncode==0 for r in results)==1
assert json.loads((root/'data/racing/task.json').read_bytes())['state']=='queued'
# Partial application publishes each record atomically and retry keeps already published bytes.
for name in ('partial-a', 'partial-b'):
    (root/'data'/name).mkdir()
    (root/'data'/name/'report.md').write_text('preserved partial evidence')
manifest.write_text(run('backfill-archived', '--state-dir', str(root/'state'), '--preview').stdout)
(root/'data/partial-b/task.json').mkdir()
failure = run('backfill-archived', '--state-dir', str(root/'state'), '--apply-file', str(manifest), ok=False)
assert json.loads(failure.stdout)['failed_id']=='partial-b'
published = (root/'data/partial-a/task.json').read_bytes()
(root/'data/partial-b/task.json').rmdir()
run('backfill-archived', '--state-dir', str(root/'state'), '--apply-file', str(manifest))
assert (root/'data/partial-a/task.json').read_bytes()==published
assert json.loads((root/'data/partial-b/task.json').read_bytes())['state']=='archived'
# A corrupt canonical record is never interpreted as absent and never overwritten.
(root/'data/broken').mkdir(); (root/'data/broken/task.json').write_text('{broken')
run('inventory',ok=False)
run('backfill-archived','--state-dir',str(root/'state'),'--preview',ok=False)
assert (root/'data/broken/task.json').read_text()=='{broken'
PY
  then fail 'canonical authority/backfill acceptance failed'; fi
  pass 'terminal policy, known identity backfill, exclusions, no-overwrite/repeat/racing create and corrupt-owner errors'
}

test_canonical_record_local_writes
test_ambient_file_cannot_redirect
test_removed_compatibility_arguments_refuse
test_task_directory_symlink_refuses
test_shadow_backlog_files_are_inert

test_authority_transitions_and_backfill
