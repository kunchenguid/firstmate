#!/usr/bin/env bash
# Shared fixtures for the boot-context emitter gates (m1, m2, m4, m5).
#
# Source AFTER tests/lib.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"
#
# These build a realistic firstmate home, a fleet-view directory of synthetic
# peers, and a stub bin/ whose helpers hang - the three inputs every emitter
# gate needs. They deliberately do NOT assert anything; assertions belong to the
# gate that owns them.

if [ -n "${FM_BOOT_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_BOOT_HELPERS_SOURCED=1

# The emitter under test. Every gate addresses it through this one name so a
# rename is a one-line change here.
# shellcheck disable=SC2034
FM_BOOT_EMITTER="$ROOT/bin/fm-boot-context.sh"

# fm_boot_hook_json [source] [cwd] [session_id]
# The SessionStart payload the harness pipes in on stdin. Every argument is
# optional; gates that want the defaults call it bare.
# shellcheck disable=SC2120
fm_boot_hook_json() {
  local src=${1:-startup} cwd=${2:-/tmp} sid=${3:-probe-session}
  printf '{"source":"%s","cwd":"%s","session_id":"%s","transcript_path":"/dev/null"}' \
    "$src" "$cwd" "$sid"
}

# fm_boot_make_home <dir> [ntasks]
# A firstmate home with the files the emitter reads: state/ metas, statuses, a
# wake queue, a lock, and data/ registry + backlog. Also drops a handoff and a
# resume directive - the two files fm-captain-bootstrap.sh moves and deletes, so
# the read-only gate's mutation arm has something real to mutate.
fm_boot_make_home() {
  local home=$1 n=${2:-3} i
  mkdir -p "$home/state" "$home/data"

  for i in $(seq 1 "$n"); do
    fm_write_meta "$home/state/task-$i.meta" \
      "window=firstmate:fm-task-$i" \
      "worktree=/tmp/wt-$i" \
      "project=projects/demo" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
    printf 'working: task %s under way\n' "$i" > "$home/state/task-$i.status"
  done
  # One task parked on a decision, so the needs-decision count is non-zero.
  printf 'needs-decision: two options on the schema\n' >> "$home/state/task-1.status"

  printf '%s\t1\tsignal\tfm-task-1\tstatus changed\n' "$(date +%s)" \
    > "$home/state/.wake-queue"
  printf '%s\t2\tstale\tfm-task-2\tpane quiet\n' "$(date +%s)" \
    >> "$home/state/.wake-queue"

  printf '99999999\n' > "$home/state/.lock"

  # The rehydrate pair. Present so a mutating emitter is caught moving them.
  printf '# handoff\nleave-off notes\n' > "$home/state/handoff-probe-session.md"
  printf 'frontier\n' > "$home/state/resume-probe-session.directive"

  cat > "$home/data/projects.md" <<'MD'
# Fleet registry

- demo [no-mistakes] - a demonstration project used by the boot-context gates, with a description long enough to matter to the output cap (added 2026-08-27)
- other [direct-PR] - a second project, also carrying a description long enough that a verbatim dump would eat a large share of the injected block (added 2026-08-27)
MD

  cat > "$home/data/secondmates.md" <<'MD'
# Secondmates

- domain-sm - triage for the demo domain (home: /tmp/sm-home; scope: triage; projects: demo; added 2026-08-27)
MD

  cat > "$home/data/backlog.md" <<'MD'
## In flight
- [ ] task-1 - first demo task (repo: demo, since 2026-08-27)

## Queued
- [ ] task-9 - a queued item (repo: demo) blocked-by: task-1 - overlapping files

## Done
- [x] task-0 - an earlier task - local main (merged 2026-08-26)
MD
}

# fm_boot_make_fleet <dir> <npeers>
# A fleet-view directory of synthetic peer files. Peer 1 is deliberately
# corrupt and peer 2 deliberately stale, so degradation markers are exercised
# by every gate that uses this.
fm_boot_make_fleet() {
  local dir=$1 n=${2:-12} i
  mkdir -p "$dir"
  for i in $(seq 1 "$n"); do
    cat > "$dir/peer-$i.json" <<JSON
{"id":"peer-$i","in_flight":$i,"needs_decision":0,"watcher":"healthy","home":"/tmp/home-$i"}
JSON
  done
  if [ "$n" -ge 1 ]; then
    printf '{"id":"peer-1", this is not json\n' > "$dir/peer-1.json"
  fi
  if [ "$n" -ge 2 ]; then
    # Six polls plus change in the past - the staleness threshold is 90s.
    touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M')" \
      "$dir/peer-2.json"
  fi
}

# fm_boot_hanging_bin <dir>
# A stub bin/ in which every helper the emitter may exec hangs forever. Echoes
# the directory, for FM_BOOTSTRAP_BIN.
fm_boot_hanging_bin() {
  local dir=$1/hanging-bin helper
  mkdir -p "$dir"
  # Each stub records the instant it started before hanging. Two start times a
  # few milliseconds apart prove the helpers ran CONCURRENTLY; run serially the
  # second would start one whole timeout after the first. That is a structural
  # observation rather than a wall-clock threshold, so it holds identically on
  # an idle machine and a saturated one.
  #
  # `sleep 999` is spawned as a CHILD deliberately, not exec'd: an orphan-prone
  # grandchild is the harder case, and gate m4 asserts the emitter reaps it.
  for helper in fm-watch-arm.sh fm-lock.sh; do
    cat > "$dir/$helper" <<SH
#!/usr/bin/env bash
python3 -c 'import time; print(time.time())' >> "$1/helper-starts.txt"
sleep 999
SH
    chmod +x "$dir/$helper"
  done
  printf '%s\n' "$dir"
}

# fm_boot_run <home> <fleetdir> [extra env assignments...]
# Run the emitter with a SessionStart payload on stdin and echo its stdout.
# The caller sets any further env inline (e.g. FIRSTMATE_ROLE=captain).
fm_boot_run() {
  local home=$1 fleet=$2
  shift 2
  fm_boot_hook_json | env \
    FM_HOME="$home" \
    FM_BOOT_FLEET_DIR="$fleet" \
    "$@" \
    bash "$FM_BOOT_EMITTER"
}

# fm_boot_context <stdout>
# Extract hookSpecificOutput.additionalContext from the emitter's JSON. Fails
# the calling test if the output is not the expected envelope.
fm_boot_context() {
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit("emitter produced no output")
d = json.loads(raw)
out = d["hookSpecificOutput"]
assert out["hookEventName"] == "SessionStart", out
sys.stdout.write(out["additionalContext"])
' || fail "emitter must print one SessionStart envelope carrying additionalContext"
}

# fm_boot_manifest <dir>
# A content+metadata manifest of every path under <dir>: relative path, type,
# size, mtime_ns, ctime_ns, inode. atime is deliberately excluded - reading a
# file updates it, and a read is exactly what the emitter is allowed to do.
fm_boot_manifest() {
  python3 - "$1" <<'PY'
import os, sys, stat
root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(dirnames) + sorted(filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        st = os.lstat(p)
        kind = "d" if stat.S_ISDIR(st.st_mode) else ("l" if stat.S_ISLNK(st.st_mode) else "f")
        rows.append("%s %s %d %d %d %d %o" % (
            rel, kind, st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino,
            stat.S_IMODE(st.st_mode)))
print("\n".join(sorted(rows)))
PY
}
