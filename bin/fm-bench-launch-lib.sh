#!/usr/bin/env bash
# fm-bench-launch-lib.sh - fail-closed refusal that keeps a model-routing
# benchmark entrant from launching before its gates have passed.
#
# The adversarial review's launch answer is "no entrant may launch now", and it
# stays that way until the whole correction set is implemented and evidenced.
# A prose rule cannot enforce that: a supervisor reaching for fm-spawn.sh has
# real capability and no reason to remember the gate. This library is the
# capability half, mirroring bin/fm-gate-refuse-lib.sh's chokepoint pattern.
#
# Scope is exactly the reserved benchmark task-id prefix `bench-`. A task id
# that does not start with it is not a benchmark entrant, so ordinary fleet
# spawns take one prefix comparison and are otherwise completely unaffected.
#
# A benchmark entrant may launch only when all of these hold:
#   1. FM_BENCH_ROOT names a benchmark directory,
#   2. that directory holds a preflight.receipt with verdict "pass",
#   3. the receipt's plan_sha256 still matches benchmark.json's current bytes,
#      and
#   4. `fm-bench-gate.sh launch-check` recomputes the receipt's evidence
#      binding over every artifact the preflight validated and still agrees.
#
# Conditions 3 and 4 are what make the receipt a binding rather than a note.
# Editing the plan after a passing preflight invalidates every receipt written
# against it, so a relaxed threshold or a swapped packet cannot ride an old
# pass; and because the evidence binding covers the freeze, manifest,
# allowance, provenance, and evaluator material too, deleting a capture record
# or lowering the measured allowance after a pass revokes the clearance rather
# than leaving it standing. The gate owns that digest, so this library never
# recomputes it independently.
#
# TEST-HARNESS ESCAPE HATCH (FM_BENCH_LAUNCH_BYPASS=1): firstmate's own suite
# spawns fixture tasks whose ids may collide with the reserved prefix. The
# hatch is honoured only when it is set, is never set by any tracked runtime
# path, and mirrors the bypass precedent in bin/fm-gate-refuse-lib.sh.

# Print the sha256 of a file, or nothing when it cannot be hashed.
fm_bench_sha256_file() {  # <path>
  [ -f "$1" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Refuse a benchmark entrant spawn that no passing preflight covers.
# Returns 0 for every non-benchmark task id.
fm_refuse_ungated_benchmark_entrant() {  # <task-id>
  local id=${1-} root receipt plan_hash receipt_hash verdict gate evidence
  case "$id" in
    bench-*) ;;
    *) return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && return 0

  root=${FM_BENCH_ROOT:-}
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "error: benchmark entrant $id has no benchmark directory; launch refused" >&2
    return 1
  fi
  receipt="$root/preflight.receipt"
  if [ ! -f "$receipt" ]; then
    echo "error: benchmark entrant $id has no passing preflight; launch refused" >&2
    return 1
  fi
  verdict=$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -n 1)
  if [ "$verdict" != pass ]; then
    echo "error: benchmark entrant $id preflight verdict is '${verdict:-unreadable}'; launch refused" >&2
    return 1
  fi
  receipt_hash=$(sed -n 's/.*"plan_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -n 1)
  plan_hash=$(fm_bench_sha256_file "$root/benchmark.json") || plan_hash=
  if [ -z "$plan_hash" ] || [ -z "$receipt_hash" ] || [ "$plan_hash" != "$receipt_hash" ]; then
    echo "error: benchmark entrant $id preflight covers a different plan; launch refused" >&2
    return 1
  fi
  gate="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/fm-bench-gate.sh"
  if [ ! -x "$gate" ]; then
    echo "error: benchmark entrant $id cannot recheck its preflight evidence; launch refused" >&2
    return 1
  fi
  if ! evidence=$("$gate" --bench "$root" launch-check 2>&1); then
    echo "error: benchmark entrant $id preflight evidence no longer holds; launch refused" >&2
    printf '%s\n' "$evidence" >&2
    return 1
  fi
  return 0
}

fm_refuse_unconfined_remote_benchmark_entrant() {  # <task-id>
  local id=${1-}
  case "$id" in
    bench-*) ;;
    *) return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && return 0
  echo "error: benchmark entrant $id cannot use its preflight-proven confinement on a remote secondmate route; launch refused" >&2
  return 1
}

fm_bench_wrap_entrant_launch() {  # <task-id> <worktree> <shell-command>
  local id=${1-} worktree=${2-} command=${3-} root wrapped isolation_hash receipt_hash
  case "$id" in
    bench-*) ;;
    *) printf '%s' "$command"; return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && { printf '%s' "$command"; return 0; }
  fm_refuse_ungated_benchmark_entrant "$id" || return 1
  root=${FM_BENCH_ROOT:-}
  receipt_hash=$(sed -n 's/.*"isolation_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/preflight.receipt" | head -n 1)
  isolation_hash=$(fm_bench_sha256_file "$root/isolation.json") || isolation_hash=
  if [ -z "$receipt_hash" ] || [ -z "$isolation_hash" ] || [ "$receipt_hash" != "$isolation_hash" ]; then
    echo "error: benchmark entrant $id preflight does not cover the current isolation layout; launch refused" >&2
    return 1
  fi
  wrapped=$(python3 - "$root/isolation.json" "$id" "$worktree" "$command" <<'PY'
import json
import os
import shlex
import shutil
import sys
from pathlib import Path

path, entrant_id, worktree, command = sys.argv[1:]
try:
    record = json.loads(Path(path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"cannot read isolation.json: {exc}")
wrapper = record.get("launch_wrapper")
entrants = record.get("entrants")
if not isinstance(wrapper, list) or not wrapper or not all(isinstance(item, str) and item for item in wrapper):
    raise SystemExit("isolation.json has no launch-capable confinement wrapper")
if not isinstance(entrants, list):
    raise SystemExit("isolation.json has no provisioned entrants")
entrant = next((item for item in entrants if isinstance(item, dict) and item.get("id") == entrant_id), None)
if entrant is None:
    raise SystemExit(f"isolation.json has no entrant {entrant_id}")
declared_root = Path(str(entrant.get("root", ""))).resolve()
if not declared_root.is_dir() or Path(worktree).resolve() != declared_root:
    raise SystemExit("spawn worktree is not the preflight-proven entrant root")
private = {}
for key in ("private_object_store", "private_tmp", "private_home", "private_session"):
    value = entrant.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"entrant {entrant_id} has no {key}")
    target = Path(value).resolve()
    if not target.is_dir():
        raise SystemExit(f"entrant {entrant_id} private path is unavailable: {key}")
    try:
        target.relative_to(declared_root)
    except ValueError:
        raise SystemExit(f"entrant {entrant_id} private path escapes its proven root: {key}")
    private[key] = str(target)
dynamic = {
    "{root}": str(declared_root),
    "{provider_network}": str(entrant.get("provider_network", "")),
    "{provider_proxy}": str(entrant.get("provider_proxy", "")),
    "{provider_proxy_container}": str(entrant.get("provider_proxy_container", "")),
}
if any(not value for value in dynamic.values()):
    raise SystemExit(f"entrant {entrant_id} has no dedicated provider boundary")
argv = [dynamic.get(item, item.replace("{root}", str(declared_root))) for item in wrapper]
launcher = argv[0]
if "/" in launcher:
    if not Path(launcher).is_file() or not os.access(launcher, os.X_OK):
        raise SystemExit(f"verified confinement wrapper is unavailable: {launcher}")
elif shutil.which(launcher) is None:
    raise SystemExit(f"verified confinement wrapper is unavailable: {launcher}")
env = [f"BENCH_PRIVATE_ROOT={declared_root}", f"BENCH_PRIVATE_OBJECT_STORE={private['private_object_store']}", f"BENCH_PRIVATE_TMP={private['private_tmp']}", f"BENCH_PRIVATE_HOME={private['private_home']}", f"BENCH_PRIVATE_SESSION={private['private_session']}"]
print(" ".join(shlex.quote(item) for item in ["env", *env, *argv, "/bin/sh", "-lc", command]))
PY
) || {
    echo "error: benchmark entrant $id cannot use its preflight-proven confinement; launch refused" >&2
    return 1
  }
  printf '%s' "$wrapped"
}
