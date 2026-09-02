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
#   2. that directory holds a preflight.receipt with verdict "pass", and
#   3. the receipt's plan_sha256 still matches benchmark.json's current bytes.
#
# Condition 3 is what makes the receipt a binding rather than a note: editing
# the plan after a passing preflight invalidates every receipt written against
# it, so a relaxed threshold or a swapped packet cannot ride an old pass.
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
  local id=${1-} root receipt plan_hash receipt_hash verdict
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
  return 0
}
