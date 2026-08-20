#!/usr/bin/env bash
# fm-ci.sh - the single command policy for Firstmate's serial Water 7 CI job.
#
# When FM_CI_FAST_LANE_BASE is set by the trusted pull-request workflow, run the
# conservative diff-scoped test selection before the complete serial merge gate.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

FM_CI_HERDR_SESSION=fm-ci-water7

die() {
  printf 'fm-ci: %s\n' "$*" >&2
  exit 1
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
  require_integer_at_least CPUQuotaPerSecUSec "$cpu" 1

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
  for command_name in bash git tmux jq python3 curl tar node npm rg tasks-axi treehouse systemctl; do
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

  if [ "$(herdr --version 2>/dev/null | awk '{ print $2; exit }')" != 0.7.4 ]; then
    bin/fm-install-herdr.sh "$tool_dir"
  fi
  [ "$(herdr --version 2>/dev/null | awk '{ print $2; exit }')" = 0.7.4 ] \
    || die 'Herdr 0.7.4 bootstrap failed'

  fm_backend_source herdr || die 'could not load the repository-owned Herdr backend'
  fm_backend_herdr_server_ensure "$FM_CI_HERDR_SESSION" \
    || die "could not ready the dedicated Herdr controller $FM_CI_HERDR_SESSION"
  status=$(fm_backend_herdr_cli "$FM_CI_HERDR_SESSION" status --json 2>/dev/null || true)
  printf '%s' "$status" | jq -e \
    '.client.version == "0.7.4" and (.client.protocol | tonumber) >= 16 and .server.running == true' \
    >/dev/null || die "Herdr 0.7.4 protocol 16+ is not ready for $FM_CI_HERDR_SESSION"
  FM_HERDR_LAB_PROTECTED_SESSION=$FM_CI_HERDR_SESSION
  export FM_HERDR_LAB_PROTECTED_SESSION
}

run_invariants() {
  local tracked
  [ "$(readlink CLAUDE.md)" = AGENTS.md ] || die 'CLAUDE.md must link to AGENTS.md'
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

require_water7_host
require_git_identity
ensure_tools
require_macos_properties
run_invariants
bin/fm-lint.sh
bin/fm-test-run.sh --check-coverage
run_pr_fast_lane
bin/fm-test-run.sh --lane portable-parallel-1
bin/fm-test-run.sh --lane portable-parallel-2
bin/fm-test-run.sh --lane portable-serial
bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
