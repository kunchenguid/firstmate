#!/usr/bin/env bash
# tests/fm-backend-herdr-foreground-smoke.test.sh - real-herdr live guard for
# the worktree-acquisition foreground reader
# (bin/backends/herdr.sh fm_backend_herdr_foreground_processes).
#
# bin/fm-spawn.sh's post-`treehouse get` wait reads that function to tell a
# fetch still under way from a shell that has already returned: `treehouse
# get` runs `git fetch origin` BEFORE it enters the worktree subshell, so the
# pane's foreground_cwd reads the project for the whole fetch, exactly as it
# does after a refusal. tests/fm-backend-herdr.test.sh pins the parse with a
# canned `pane process-info` body. This script is the check that notices when
# the REAL client stops answering in that shape, and it names the installed
# version so a release change is attributed rather than mysterious. It is the
# refresh command for the "Worktree acquisition foreground" record in
# docs/verification/runtime-backends.md.
#
# No treehouse pool and no network are touched: the `treehouse` the pane runs
# is a symlink to `sleep` on a temporary PATH, the construction
# tests/fm-tmux-agent-liveness.test.sh uses (a copied platform binary fails
# code signing on macOS arm64). The symlink name is what the shell passes as
# argv[0]; which of the kernel name and the command line preserves it differs
# between macOS and Linux, so the process is looked up the way the spawn wait
# looks it up: by either surface.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-herdr-foreground-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-foreground.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
PROJ="$SCRATCH/proj"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$PROJ" "$FAKEBIN"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
ln -s "$SLEEP_BIN" "$FAKEBIN/treehouse"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}
raw_process_info() {  # <pane_id>
  herdr pane process-info --pane "$1" --session "$SESSION" 2>&1 | tr -d '\n'
}

# Two panes in one lab workspace: one will run the treehouse-named process,
# the other stays an idle shell so the reader is proved to describe only the
# pane it was asked about.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$PROJ") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
ACQ_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-fg-acquiring" "$PROJ" "$SEEDED_TAB_ID") \
  || fail "create_task for the acquiring pane failed"
read -r _ ACQ_PANE <<EOF2
$ACQ_IDS
EOF2
IDLE_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-fg-idle" "$PROJ") \
  || fail "create_task for the idle pane failed"
read -r _ IDLE_PANE <<EOF2
$IDLE_IDS
EOF2
[ -n "$ACQ_PANE" ] && [ -n "$IDLE_PANE" ] || fail "create_task did not return pane ids"

# The temporary PATH goes first so `treehouse` resolves to the symlink and the
# real treehouse, if installed, is never consulted.
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
fm_backend_herdr_send_text_line "$SESSION:$ACQ_PANE" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the fake treehouse on the lab pane's PATH"
fm_backend_herdr_send_text_line "$SESSION:$ACQ_PANE" "treehouse 900" \
  || fail "could not start the treehouse-named process in the lab pane"

# fm_backend_herdr_foreground_processes prints `<name>TAB<cwd>TAB<cmdline>`,
# one line per foreground process, and an empty middle field keeps its slot.
# Parameter expansion rather than `read`, because a tab in IFS is whitespace
# to `read` and an empty cwd would shift the cmdline into its place.
split_report_line() {  # <line> -> FG_NAME FG_CWD FG_CMDLINE
  local rest
  FG_NAME=${1%%$'\t'*}
  rest=${1#*$'\t'}
  [ "$rest" != "$1" ] || rest=
  FG_CWD=${rest%%$'\t'*}
  FG_CMDLINE=${rest#*$'\t'}
  [ "$FG_CMDLINE" != "$rest" ] || FG_CMDLINE=
}
line_names_treehouse() {  # <name> <cmdline>, the spawn wait's own test
  [ "${1##*/}" != treehouse ] || return 0
  case " $2 " in
    *"/treehouse "*|*" treehouse "*) return 0 ;;
  esac
  return 1
}
treehouse_line_in() {  # <report> -> the first line naming treehouse, or nothing
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    split_report_line "$line"
    if line_names_treehouse "$FG_NAME" "$FG_CMDLINE"; then
      printf '%s\n' "$line"
      return 0
    fi
  done <<EOF2
$1
EOF2
  return 1
}

FG_REPORT=
TREEHOUSE_LINE=
for _ in $(seq 1 100); do
  FG_REPORT=$(fm_backend_herdr_foreground_processes "$SESSION:$ACQ_PANE" 2>/dev/null || true)
  if TREEHOUSE_LINE=$(treehouse_line_in "$FG_REPORT"); then
    break
  fi
  sleep 0.1
done
[ -n "$TREEHOUSE_LINE" ] \
  || version_fail "the foreground reader never named the running treehouse process; report=[$(printf '%s' "$FG_REPORT" | tr '\n\t' ' ,')]. Raw process-info: $(raw_process_info "$ACQ_PANE")"
split_report_line "$TREEHOUSE_LINE"
[ -n "$FG_CWD" ] \
  || version_fail "pane process-info carries no cwd for the treehouse process, so the spawn wait cannot see where the acquisition runs; line=[$(printf '%s' "$TREEHOUSE_LINE" | tr '\t' ',')]. Raw process-info: $(raw_process_info "$ACQ_PANE")"
FG_CWD_REAL=$(cd "$FG_CWD" 2>/dev/null && pwd -P) \
  || version_fail "the cwd pane process-info reports for the treehouse process does not exist: $FG_CWD"
[ "$FG_CWD_REAL" = "$PROJ_REAL" ] \
  || version_fail "the treehouse process cwd should be the pane's own directory $PROJ_REAL, got $FG_CWD"
line_names_treehouse "" "$FG_CMDLINE" \
  || version_fail "pane process-info carries no cmdline (or argv) naming treehouse for the process; line=[$(printf '%s' "$TREEHOUSE_LINE" | tr '\t' ',')]. Raw process-info: $(raw_process_info "$ACQ_PANE")"
pass "real herdr $HERDR_VERSION: the foreground reader names a running treehouse process (name=$FG_NAME) with its cwd and cmdline"

# The idle pane's own foreground (its shell, plus any transient prompt helper)
# must be reported, and must never name the treehouse running next door.
IDLE_REPORT=
for _ in $(seq 1 50); do
  IDLE_REPORT=$(fm_backend_herdr_foreground_processes "$SESSION:$IDLE_PANE" 2>/dev/null || true)
  [ -z "$IDLE_REPORT" ] || break
  sleep 0.1
done
[ -n "$IDLE_REPORT" ] \
  || version_fail "the foreground reader printed nothing for the idle shell pane. Raw process-info: $(raw_process_info "$IDLE_PANE")"
if treehouse_line_in "$IDLE_REPORT" >/dev/null; then
  fail "the idle shell pane must not name treehouse; report=[$(printf '%s' "$IDLE_REPORT" | tr '\n\t' ' ,')]"
fi
pass "real herdr $HERDR_VERSION: the idle shell pane is reported without naming treehouse"

# A pane the session does not have is a failed read: nothing printed, so the
# spawn wait falls back to the pane's own text rather than trusting a stranger.
MISSING_REPORT=$(fm_backend_herdr_foreground_processes "$SESSION:w99:p99" 2>/dev/null || true)
[ -z "$MISSING_REPORT" ] \
  || fail "the foreground reader printed a report for a pane the session does not have: [$(printf '%s' "$MISSING_REPORT" | tr '\n\t' ' ,')]"
pass "real herdr: a pane the session does not have prints nothing"

# Stop the fake treehouse before the lab session is torn down so no 900s sleep
# outlives the test.
for pid in $(herdr pane process-info --pane "$ACQ_PANE" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[]?.pid // empty' 2>/dev/null); do
  kill "$pid" 2>/dev/null || true
done
