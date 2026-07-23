#!/usr/bin/env bash
# fm-test-isolation-proof.sh - bounded concurrent isolation proof for portable
# behavior-test candidates (Phase 2 pre-shard gate).
#
# This is the single owner of the proven parallel candidate set, the concurrent
# proof run, and the isolation checks that admitted that set. Production
# portable CI shards and bounded local fm-test-run.sh --jobs for this exact set
# are owned by bin/fm-test-run.sh (docs/fm-test-portable-shards.md).
#
# It does NOT:
#   - compose production CI shard membership (fm-test-run.sh owns that partition)
#   - run real Herdr, real default-server tmux, watcher lock races, AFK, live
#     harnesses, or GUI backends
#
# Usage:
#   fm-test-isolation-proof.sh [--jobs N] [--json path] [--list]
#   fm-test-isolation-proof.sh --list-exclusions
#   fm-test-isolation-proof.sh -h | --help
#
# Options:
#   --jobs N     max concurrent workers (default: 4; min 1)
#   --json path  write a machine-readable proof artifact after the run
#   --list       print the proven candidate paths (one per line) and exit 0
#   --list-exclusions
#                print basename + reason for scripts deliberately kept serial
#                relative to the scout-proposed parallel pool, then exit 0
#   -h, --help   print this header
#
# Isolation contract for each concurrent worker:
#   - distinct mode-0700 temporary root under a proof-owned parent
#   - TMPDIR/TMP point only at that root so mktemp/fm_test_tmproot stay private
#   - ambient FM_HOME / FM_*_OVERRIDE cleared so no shared home is reused
#   - no global git config mutation (snapshot before/after)
#   - no production sharding and no retry-until-green
#
# Markers (stdout):
#   FM_ISOLATION_BEGIN <iso8601> concurrency=<n> candidates=<n>
#   FM_ISOLATION_CANDIDATE_BEGIN <iso8601> <script> worker=<i>
#   FM_ISOLATION_CANDIDATE_END <iso8601> <script> exit=<code> duration_ms=<n> worker=<i>
#   FM_ISOLATION_SUMMARY total=<n> failed=<n> concurrency=<n> duration_ms=<n>
#
# Exit status is the aggregate of candidate exits: non-zero if any candidate
# fails, if isolation checks fail, or if the candidate set is empty. A script
# that fails only under concurrency must be removed from the candidate set and
# investigated; this harness never retries a failure into green.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

JOBS=4
JSON_PATH=
LIST_ONLY=0
LIST_EXCLUSIONS=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-isolation-proof: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-isolation-proof: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

# Serial exclusions relative to the scout-proposed parallel pool (pure units,
# fake backends, private git fixtures, stubbed network). Reasons are audit
# evidence; do not re-add a basename without clearing its reason.
exclusion_reason() {
  case "$1" in
    fm-continuity-pretool-check.test.sh)
      printf '%s\n' 'background sleep 300 holder process for live-lock identity; process-leak risk under concurrent load'
      ;;
    fm-test-isolation-proof.test.sh)
      printf '%s\n' 'isolation-proof harness contract itself; must not re-enter concurrent matrix'
      ;;
    fm-backend-tmux-smoke.test.sh)
      printf '%s\n' 'real tmux on a private socket; keep exclusive of default-server contention class'
      ;;
    fm-backend.test.sh)
      printf '%s\n' 'old-vs-new main checkout diff fixture; gray-zone concurrent git/worktree cost'
      ;;
    fm-spawn-dispatch-profile.test.sh|fm-spawn-worktree-settle.test.sh)
      printf '%s\n' 'real isolated git worktrees plus spawn settle loops; gray zone until dedicated proof'
      ;;
    fm-pr-check-security.test.sh)
      printf '%s\n' 'watcher lock / migration / poll security surface; intentional shared-lock class'
      ;;
    fm-teardown.test.sh)
      printf '%s\n' 'landed-work + lock-race teardown matrix; keep serial with forge/git stress peers'
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-queue.test.sh|fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh)
      printf '%s\n' 'watcher/wake/lock family; intentional process locks and daemon races'
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh|fm-afk-inject-herdr-e2e.test.sh|\
    fm-afk-launch.test.sh)
      printf '%s\n' 'AFK lifecycle / inject path; exclusive daemon and pane control'
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|fm-claude-continuity-live-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' 'live harness opt-in; never default parallel CI'
      ;;
    fm-backend-autodetect-smoke.test.sh|fm-backend-herdr-eventwait-smoke.test.sh|\
    fm-backend-herdr-presentation-e2e.test.sh|fm-backend-herdr-prune-safety-e2e.test.sh|\
    fm-backend-herdr-respawn-idem-e2e.test.sh|fm-backend-herdr-smoke.test.sh|\
    fm-backend-herdr-workspace-per-home-e2e.test.sh)
      printf '%s\n' 'real Herdr-gated; Herdr lane is a later phase'
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' 'cmux GUI backend; never parallel with another cmux mutator'
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' 'zellij optional backend; keep out of pure parallel pool'
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' 'orca backend surface; keep serial until dedicated isolation proof'
      ;;
    *)
      return 1
      ;;
  esac
}

# Exact candidate set from the archived concurrent proof. Adding or removing a
# path requires a new audit and proof archive.
list_parallel_candidates() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-dispatch-select.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-stow-contract.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

list_exclusions_for_report() {
  local base reason
  # Stable report of known serial reasons for the scout-proposed pool classes.
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if reason=$(exclusion_reason "$base"); then
      printf '%s\t%s\n' "$base" "$reason"
    fi
  done <<'EOF'
fm-continuity-pretool-check.test.sh
fm-test-isolation-proof.test.sh
fm-backend-tmux-smoke.test.sh
fm-backend.test.sh
fm-spawn-dispatch-profile.test.sh
fm-spawn-worktree-settle.test.sh
fm-pr-check-security.test.sh
fm-teardown.test.sh
fm-watcher-lock.test.sh
fm-wake-queue.test.sh
fm-afk-inject-e2e.test.sh
fm-backend-herdr-smoke.test.sh
fm-backend-cmux-smoke.test.sh
fm-pi-primary-live-e2e.test.sh
EOF
}

dir_mode() {
  local path=$1
  if stat -f %Lp "$path" >/dev/null 2>&1; then
    stat -f %Lp "$path"
  else
    stat -c %a "$path"
  fi
}

global_git_snapshot() {
  # Empty string when no global config is present or git cannot read it.
  git config --global --list 2>/dev/null | LC_ALL=C sort || true
}

write_json_artifact() {
  local out=$1 started=$2 finished=$3 run_id=$4 total=$5 failed=$6 concurrency=$7 duration=$8 records=$9
  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$concurrency" "$duration" "$records" <<'PY'
import json, sys
out, started, finished, run_id, total, failed, concurrency, duration, records_path = sys.argv[1:10]
scripts = []
with open(records_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, exit_s, dur_s, worker = line.split("\t")
        scripts.append({
            "path": path,
            "exit": int(exit_s),
            "duration_ms": int(dur_s),
            "worker": int(worker),
        })
scripts.sort(key=lambda s: s["path"])
doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "kind": "isolation-proof",
    "concurrency": int(concurrency),
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "production_sharding_enabled": False,
    "fm_test_run_jobs_enabled": False,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-exclusions)
      LIST_EXCLUSIONS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1 (this harness owns its candidate set)"
      ;;
  esac
done

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

if [ "$LIST_EXCLUSIONS" -eq 1 ]; then
  list_exclusions_for_report
  exit 0
fi

CANDIDATES=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  CANDIDATES+=("$s")
done < <(list_parallel_candidates | LC_ALL=C sort -u)

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

[ "${#CANDIDATES[@]}" -gt 0 ] || die "candidate set is empty; refusing isolation proof"

for s in "${CANDIDATES[@]}"; do
  [ -f "$s" ] || die "candidate not found: $s"
done

PROOF_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-isolation-proof.XXXXXX")
chmod 0700 "$PROOF_ROOT" || die "could not chmod 0700 proof root $PROOF_ROOT"
RECORDS="$PROOF_ROOT/records.tsv"
: >"$RECORDS"
trap 'rm -rf "$PROOF_ROOT"' EXIT

GIT_BEFORE=$(global_git_snapshot)
RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-isolation-${RUN_STARTED_MS}-$$"
TOTAL=${#CANDIDATES[@]}
FAILED=0
AGG_RC=0

printf 'FM_ISOLATION_BEGIN %s concurrency=%s candidates=%s\n' \
  "$RUN_STARTED_ISO" "$JOBS" "$TOTAL"

# Worker state arrays parallel to CANDIDATES indices (1-based worker labels).
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()

wait_one_slot() {
  local pid idx work rc duration script mode
  # Wait for the oldest launched worker still recorded.
  pid=${WORKER_PIDS[0]}
  idx=${WORKER_IDX[0]}
  WORKER_PIDS=("${WORKER_PIDS[@]:1}")
  WORKER_IDX=("${WORKER_IDX[@]:1}")
  set +e
  wait "$pid"
  set -e
  work="$PROOF_ROOT/w$idx"
  script=${CANDIDATES[$((idx - 1))]}
  rc=$(cat "$work/out/exit" 2>/dev/null || echo 1)
  duration=$(cat "$work/out/duration_ms" 2>/dev/null || echo 0)
  printf 'FM_ISOLATION_CANDIDATE_END %s %s exit=%s duration_ms=%s worker=%s\n' \
    "$(now_iso)" "$script" "$rc" "$duration" "$idx"
  printf '%s\t%s\t%s\t%s\n' "$script" "$rc" "$duration" "$idx" >>"$RECORDS"
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    AGG_RC=1
    log "candidate failed: $script exit=$rc"
    if [ -s "$work/out/stdout" ]; then
      log "--- stdout ($script) ---"
      tail -n 40 "$work/out/stdout" >&2 || true
    fi
    if [ -s "$work/out/stderr" ]; then
      log "--- stderr ($script) ---"
      tail -n 40 "$work/out/stderr" >&2 || true
    fi
  fi
  # Isolation: worker root must remain mode 0700 and under the proof parent.
  mode=$(dir_mode "$work")
  case "$mode" in
    700|0700) ;;
    *)
      log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
      AGG_RC=1
      FAILED=$((FAILED + 1))
      ;;
  esac
  case "$work" in
    "$PROOF_ROOT"/*) ;;
    *)
      log "isolation failure: worker root escaped proof parent: $work"
      AGG_RC=1
      ;;
  esac
}

idx=0
for script in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  work="$PROOF_ROOT/w$idx"
  # Create then chmod: mkdir -m can still be umask-adjusted on some platforms.
  mkdir -p "$work/tmp" "$work/out"
  chmod 0700 "$work" "$work/tmp" "$work/out" \
    || die "could not chmod 0700 worker roots under $work"
  mode=$(dir_mode "$work")
  case "$mode" in
    700|0700) ;;
    *) die "failed to create mode-0700 worker root at $work (mode=$mode)" ;;
  esac
  mode=$(dir_mode "$work/tmp")
  case "$mode" in
    700|0700) ;;
    *) die "failed to create mode-0700 TMPDIR at $work/tmp (mode=$mode)" ;;
  esac

  printf 'FM_ISOLATION_CANDIDATE_BEGIN %s %s worker=%s\n' \
    "$(now_iso)" "$script" "$idx"

  (
    set +e
    export TMPDIR="$work/tmp"
    export TMP="$work/tmp"
    # Clear ambient fleet overrides so candidates cannot share a live home.
    unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
      FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
    cd "$ROOT" || exit 1
    begin_ms=$(now_ms)
    bash "$script" >"$work/out/stdout" 2>"$work/out/stderr"
    rc=$?
    end_ms=$(now_ms)
    duration=$((end_ms - begin_ms))
    if [ "$duration" -lt 0 ]; then
      duration=0
    fi
    printf '%s\n' "$rc" >"$work/out/exit"
    printf '%s\n' "$duration" >"$work/out/duration_ms"
    exit 0
  ) &
  WORKER_PIDS+=("$!")
  WORKER_IDX+=("$idx")

  # Bound concurrency.
  while [ "${#WORKER_PIDS[@]}" -ge "$JOBS" ]; do
    wait_one_slot
  done
done

while [ "${#WORKER_PIDS[@]}" -gt 0 ]; do
  wait_one_slot
done

GIT_AFTER=$(global_git_snapshot)
if [ "$GIT_BEFORE" != "$GIT_AFTER" ]; then
  log "isolation failure: git config --global changed during the concurrent proof"
  log "--- before ---"
  printf '%s\n' "$GIT_BEFORE" >&2
  log "--- after ---"
  printf '%s\n' "$GIT_AFTER" >&2
  AGG_RC=1
  FAILED=$((FAILED + 1))
fi

# Cross-process artifact check: no candidate may leave debris outside the
# proof-owned TMPDIR tree. Workers only receive TMPDIR under PROOF_ROOT, so any
# residual path under PROOF_ROOT is expected and cleaned by trap. Refuse if a
# worker wrote a fixed global path we know about from audit (none remain after
# the arm-pretool stderr path uses TMPDIR).
if find "$PROOF_ROOT" -type f -name 'fm-arm-pretool-check-claude-stderr.*' 2>/dev/null | grep -q .; then
  : # allowed only under proof roots; nothing to do
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_ISOLATION_SUMMARY total=%s failed=%s concurrency=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION"

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Stable record order for the artifact.
  sort -t$'\t' -k1,1 "$RECORDS" -o "$RECORDS"
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION" "$RECORDS"
  log "wrote isolation proof artifact: $JSON_PATH"
fi

exit "$AGG_RC"
