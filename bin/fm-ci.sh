#!/usr/bin/env bash
# fm-ci.sh - the single command policy for Firstmate's one-job Water 7 CI run.
#
# Lanes run one after another in that single job. The upstream portable serial
# partition is retained as its repository-owned shards, but those shards remain
# sequential on the sole Water 7 runner. The only concurrency is bounded
# in-lane --jobs for a lane whose set is proven-isolated; see
# docs/fm-test-portable-shards.md and docs/verification/ci-portable-parallel-jobs.md.
# Lint runs its 32 stable shards serially with FM_LINT_JOBS=1 to bound
# concurrent ShellCheck memory on the shared host without changing diagnostics;
# bin/fm-lint.sh keeps its two-worker default for other callers.
#
# When FM_CI_FAST_LANE_BASE is set by the trusted pull-request workflow, run the
# conservative diff-scoped test selection before the complete serial merge gate.
#
# When GITHUB_STEP_SUMMARY is set, each lane additionally emits its fm-test-run.sh
# timing JSON into a temporary directory under RUNNER_TEMP that an EXIT trap
# discards, and a compact report - the four lane totals, the ten slowest tests,
# tool-bootstrap time, and GITHUB_RUN_ID (literal 'unavailable' when GitHub run
# metadata is absent) - is appended to that file. Without GITHUB_STEP_SUMMARY the
# policy runs ordinary local execution and emits no timing artifacts.
# docs/fm-test-portable-shards.md owns the non-blocking, success-only timing
# contract this path implements.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

FM_CI_HERDR_SESSION=fm-ci-water7
FM_CI_SUMMARY_DIR=
FM_CI_SUMMARY_ENABLED=0
FM_CI_BOOTSTRAP_MS=0
FM_CI_TIMING_INPUTS=()

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

die() {
  printf 'fm-ci: %s\n' "$*" >&2
  exit 1
}

# The summary directory is optional scratch, so its removal can neither fail the
# policy verdict nor depend on reaching the end of the script.
discard_summary_dir() {
  [ -n "$FM_CI_SUMMARY_DIR" ] || return 0
  rm -rf "$FM_CI_SUMMARY_DIR" || true
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required on Water 7"
}

systemd_value() {
  printf '%s\n' "$SYSTEMD_PROPERTIES" | awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }'
}

require_integer_at_least() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be an integer, got ${2:-<empty>}" ;;
  esac
  [ "$2" -ge "$3" ] || die "$1 must be at least $3, got $2"
}

require_water7_host() {
  local unit cpu memory tasks nofile nofile_soft
  [ "${GITHUB_ACTIONS:-}" = true ] || die 'GITHUB_ACTIONS=true is required'
  [ "${RUNNER_NAME:-}" = water-7 ] || die "runner name must be water-7, got ${RUNNER_NAME:-<empty>}"
  [ "${RUNNER_OS:-}" = Linux ] || die "runner OS must be Linux, got ${RUNNER_OS:-<empty>}"
  [ "${RUNNER_ARCH:-}" = X64 ] || die "runner architecture must be X64, got ${RUNNER_ARCH:-<empty>}"
  [ "${GITHUB_REPOSITORY:-}" = pedromuller-del/firstmate ] \
    || die "repository must be pedromuller-del/firstmate, got ${GITHUB_REPOSITORY:-<empty>}"

  unit=actions.runner.pedromuller-del-firstmate.water-7.service
  SYSTEMD_PROPERTIES=$(systemctl show "$unit" \
    --property=LoadState,ActiveState,SubState,UnitFileState,User,CPUQuotaPerSecUSec,MemoryMax,TasksMax,LimitNOFILE,LimitNOFILESoft) \
    || die "could not inspect $unit"
  [ "$(systemd_value LoadState)" = loaded ] || die "$unit is not loaded"
  [ "$(systemd_value ActiveState)" = active ] || die "$unit is not active"
  [ "$(systemd_value SubState)" = running ] || die "$unit is not running"
  [ "$(systemd_value UnitFileState)" = enabled ] || die "$unit is not enabled"
  [ "$(systemd_value User)" = fm-ci-runner ] || die "$unit must run as fm-ci-runner"

  cpu=$(systemd_value CPUQuotaPerSecUSec)
  case "$cpu" in
    *s) cpu=${cpu%s} ;;
    *) die "CPUQuotaPerSecUSec must be expressed in seconds, got ${cpu:-<empty>}" ;;
  esac
  # Floor tracks this policy's own concurrency: the --jobs 2 lane below needs
  # two CPU-seconds per second to run its workers, not one.
  require_integer_at_least CPUQuotaPerSecUSec "$cpu" 2

  memory=$(systemd_value MemoryMax)
  if [ "$memory" != infinity ]; then
    require_integer_at_least MemoryMax "$memory" 536870912
  fi
  tasks=$(systemd_value TasksMax)
  nofile=$(systemd_value LimitNOFILE)
  nofile_soft=$(systemd_value LimitNOFILESoft)
  require_integer_at_least TasksMax "$tasks" 512
  require_integer_at_least LimitNOFILE "$nofile" 65536
  require_integer_at_least LimitNOFILESoft "$nofile_soft" 1024
}

require_git_identity() {
  local ident
  [ "${LC_ALL:-}" = C ] || die 'LC_ALL=C is required'
  [ "${LANG:-}" = C ] || die 'LANG=C is required'
  [ -n "${GIT_AUTHOR_NAME:-}" ] || die 'GIT_AUTHOR_NAME is required'
  [ -n "${GIT_AUTHOR_EMAIL:-}" ] || die 'GIT_AUTHOR_EMAIL is required'
  [ "${GIT_COMMITTER_NAME:-}" = "$GIT_AUTHOR_NAME" ] || die 'committer and author names must match'
  [ "${GIT_COMMITTER_EMAIL:-}" = "$GIT_AUTHOR_EMAIL" ] || die 'committer and author emails must match'
  ident=$(git var GIT_AUTHOR_IDENT) || die 'fresh-runner Git author identity is unusable'
  case "$ident" in
    "$GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> "*) ;;
    *) die 'Git did not resolve the workflow-owned author identity' ;;
  esac
}

require_macos_properties() {
  local inventory file hits
  inventory=$(mktemp "${RUNNER_TEMP:-/tmp}/fm-shell-inventory.XXXXXX")
  trap 'rm -f "$inventory"' RETURN
  bin/fm-lint.sh --list-files > "$inventory"
  while IFS= read -r file; do
    bash -n "$file" || die "Bash parse failed for $file"
  done < "$inventory"
  # Every alternative below is written so the pattern cannot match its own
  # source line, which keeps this file inside its own scan.
  hits=$(find bin -type f -name '*.sh' -exec grep -HEn '(^|[;[:space:]])(declare|typeset)[[:space:]]+-[a-zA-Z]*A|(^|[;[:space:]])(mapfile|readarray)([[:space:]]|$)|(^|[;[:space:]])(local|declare)[[:space:]]+-n([[:space:]]|$)|\$\{[^}]*,,|\$\{[^}]*\^\^|&>[>]|(^|[[:space:]])\|&([[:space:]]|$)' {} + || true)
  [ -z "$hits" ] \
    || die "production shell uses syntax unavailable in stock macOS Bash 3.2:
$hits"
  rm -f "$inventory"
  trap - RETURN
}

ensure_tools() {
  local command_name required status tool_dir
  for command_name in bash git tmux jq python3 curl tar node npm rg tasks-axi treehouse systemctl dpkg-deb; do
    require_command "$command_name"
  done
  SHELL=$(command -v bash)
  export SHELL

  tool_dir=${RUNNER_TEMP:?RUNNER_TEMP is required}/fm-ci-tools
  mkdir -p "$tool_dir"
  PATH="$tool_dir:$PATH"
  export PATH

  required=$(bin/fm-lint.sh --required-version)
  if [ "$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2; exit }')" != "$required" ]; then
    bin/fm-install-shellcheck.sh "$tool_dir"
  fi
  [ "$(shellcheck --version 2>/dev/null | awk '/^version:/ { print $2; exit }')" = "$required" ] \
    || die "ShellCheck $required bootstrap failed"

  if [ "$(herdr --version 2>/dev/null | awk '{ print $2; exit }')" != 0.8.0 ]; then
    bin/fm-install-herdr.sh "$tool_dir"
  fi
  [ "$(herdr --version 2>/dev/null | awk '{ print $2; exit }')" = 0.8.0 ] \
    || die 'Herdr 0.8.0 bootstrap failed'

  FM_CHROME_BIN=$(bin/fm-install-chrome.sh "$tool_dir")
  export FM_CHROME_BIN
  [ -x "$FM_CHROME_BIN" ] || die 'user-space Chrome bootstrap failed'

  fm_backend_source herdr || die 'could not load the repository-owned Herdr backend'
  fm_backend_herdr_server_ensure "$FM_CI_HERDR_SESSION" \
    || die "could not ready the dedicated Herdr controller $FM_CI_HERDR_SESSION"
  status=$(fm_backend_herdr_cli "$FM_CI_HERDR_SESSION" status --json 2>/dev/null || true)
  printf '%s' "$status" | jq -e \
    '.client.version == "0.8.0" and (.client.protocol | tonumber) >= 19 and .server.running == true' \
    >/dev/null || die "Herdr 0.8.0 protocol 19+ is not ready for $FM_CI_HERDR_SESSION"
  FM_HERDR_LAB_PROTECTED_SESSION=$FM_CI_HERDR_SESSION
  export FM_HERDR_LAB_PROTECTED_SESSION
}

run_invariants() {
  local tracked
  [ -f CLAUDE.md ] && [ ! -L CLAUDE.md ] \
    || die 'CLAUDE.md must be a regular @AGENTS.md pointer'
  if ! cmp -s CLAUDE.md - <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
  then
    die 'CLAUDE.md must contain the canonical @AGENTS.md pointer'
  fi
  [ "$(readlink .claude/skills)" = ../.agents/skills ] \
    || die '.claude/skills must link to ../.agents/skills'
  tracked=$(git ls-files -- data state config projects .no-mistakes)
  [ -z "$tracked" ] || die "personal fleet paths are tracked:\n$tracked"
}

run_pr_fast_lane() {
  local base=${FM_CI_FAST_LANE_BASE:-}
  [ -n "$base" ] || return 0
  bin/fm-test-run.sh --changed --base "$base" --fail-on-gate-skip 'herdr not found'
}

run_lane() {
  local name=$1 timing_path
  shift
  if [ "$FM_CI_SUMMARY_ENABLED" -eq 1 ]; then
    timing_path="$FM_CI_SUMMARY_DIR/$name.json"
    bin/fm-test-run.sh "$@" --json "$timing_path"
    FM_CI_TIMING_INPUTS+=("$timing_path")
  else
    bin/fm-test-run.sh "$@"
  fi
}

run_portable_serial_shards() {
  local lane found=0
  while IFS= read -r lane; do
    case "$lane" in
      portable-serial-[0-9]*of[0-9]*)
        found=1
        run_lane "$lane" --lane "$lane"
        ;;
    esac
  done < <(bin/fm-test-run.sh --list-lanes)
  [ "$found" -eq 1 ] || die 'fm-test-run reported no portable serial shard lanes'
}

write_step_summary() {
  [ "$FM_CI_SUMMARY_ENABLED" -eq 1 ] || return 0
  local aggregate="$FM_CI_SUMMARY_DIR/aggregate.json"
  bin/fm-test-run.sh --aggregate-json "$aggregate" \
    "${FM_CI_TIMING_INPUTS[@]}" >/dev/null || return 1
  python3 - "$GITHUB_STEP_SUMMARY" "$FM_CI_BOOTSTRAP_MS" "${GITHUB_RUN_ID:-unavailable}" "$aggregate" <<'PY'
import json
import sys

out, bootstrap_ms, run_id, aggregate_path = sys.argv[1:]


def step_aside(message):
    sys.stderr.write(f"fm-ci: {message}\n")
    raise SystemExit(1)


try:
    with open(aggregate_path, encoding="utf-8") as fh:
        aggregate = json.load(fh)
except (OSError, ValueError) as exc:
    step_aside(f"unusable aggregate timing JSON {aggregate_path}: {exc}")
lanes = []
for lane in aggregate.get("lanes") or []:
    selection = lane.get("selection", "")
    name = selection.split("=", 1)[-1].split(";", 1)[0]
    lanes.append((name, int((lane.get("summary") or {}).get("duration_ms") or 0)))
try:
    with open(out, "a", encoding="utf-8") as fh:
        fh.write("## Water 7 CI timing\n\n")
        fh.write("| Lane | Total |\n| --- | ---: |\n")
        for name, duration in lanes:
            fh.write(f"| {name} | {duration} ms |\n")
        fh.write("\n")
        fh.write(f"Tool bootstrap: {int(bootstrap_ms)} ms\n")
        fh.write(f"GitHub run id: {run_id}\n\n")
        fh.write("| Rank | Test | Timing |\n| ---: | --- | ---: |\n")
        for rank, row in enumerate((aggregate.get("slowest") or [])[:10], 1):
            fh.write(f"| {rank} | {row.get('path', 'unknown')} | {int(row.get('duration_ms') or 0)} ms |\n")
except OSError as exc:
    step_aside(f"could not write the GitHub step summary {out}: {exc}")
PY
}

require_water7_host
require_git_identity
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if FM_CI_SUMMARY_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/fm-ci-summary.XXXXXX"); then
    trap discard_summary_dir EXIT
    FM_CI_SUMMARY_ENABLED=1
    bootstrap_started=$(now_ms)
  else
    printf 'fm-ci: could not prepare optional GitHub step summary\n' >&2
  fi
fi
ensure_tools
if [ "$FM_CI_SUMMARY_ENABLED" -eq 1 ]; then
  FM_CI_BOOTSTRAP_MS=$(( $(now_ms) - bootstrap_started ))
fi
require_macos_properties
run_invariants
# Keep the shared-host lint memory bound described in this script's header.
FM_LINT_JOBS=1 bin/fm-lint.sh
bin/fm-test-run.sh --check-coverage
run_pr_fast_lane
run_lane portable-parallel-1 --jobs 2 --lane portable-parallel-1
run_lane portable-parallel-2 --lane portable-parallel-2
run_portable_serial_shards
run_lane real-herdr-gated --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
if ! write_step_summary; then
  printf 'fm-ci: could not publish optional GitHub step summary\n' >&2
fi
