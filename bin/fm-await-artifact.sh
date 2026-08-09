#!/usr/bin/env bash
# Arm an artifact-ready wake for a task that is waiting on another worker's output.
# Usage: fm-await-artifact.sh <waiting-task-id> <absolute-path>... [--sentinel <regex>]
# It writes state/<waiting-task-id>.check.sh and binds it through
# bin/fm-check-register.sh, so the existing watcher sweep executes it. No new
# process, daemon, or database is involved, and the wake goes to firstmate, never
# to a peer worker.
#
# The generated check prints exactly one line when the artifact is ready and
# nothing otherwise, which is the whole watcher contract (AGENTS.md section 7).
# Readiness has two shapes:
#   default        every path exists as a non-empty regular file AND its
#                  mtime/size signature is unchanged since the previous sweep,
#                  so a half-written report is never announced as ready.
#   --sentinel     every path matches the extended regular expression. A finality
#                  sentinel is the producer's own one-way "this section is
#                  frozen" declaration (bin/fm-brief.sh's scout scaffold), so it
#                  REPLACES the stability heuristic rather than adding to it:
#                  waiting for stability too would delay a per-section wake by a
#                  full sweep, and firing on stability alone would announce an
#                  unmarked partial report, which is exactly what the sentinel
#                  exists to prevent.
# The check fires once. After it prints, it records that fact in
# state/.<waiting-task-id>.await-artifact and stays silent on every later sweep;
# the wake itself is durable in the wake queue. bin/fm-teardown.sh removes the
# check, its trust binding, and that record with the task's other state.
#
# Re-arming the same task replaces an existing await-artifact check (a consumer
# waiting per-section arms one sentinel after another). Any other armed state
# check for that task - a PR merge poll above all - is refused rather than
# clobbered, because those carry their own registration and retirement records.
#
# A malformed regex, a relative path, a missing task, or an unwritable state
# directory refuses here. Arming is the only point where a bad watch can be
# reported at all: the check is silent on every error by design, so a watch that
# could never match would be indistinguishable from an artifact that never lands.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

MARKER='# fm-await-artifact-v1'
SENTINEL=
PATHS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    SENTINEL=$a
    want_value=
    continue
  fi
  case "$a" in
    --sentinel) want_value=sentinel ;;
    --sentinel=*) SENTINEL=${a#--sentinel=} ;;
    --*) echo "error: unknown option $a" >&2; exit 2 ;;
    *) PATHS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --sentinel requires a value" >&2; exit 2; }

[ "${#PATHS[@]}" -ge 2 ] || { echo "error: usage: fm-await-artifact.sh <waiting-task-id> <absolute-path>... [--sentinel <regex>]" >&2; exit 2; }
ID=${PATHS[0]}
PATHS=("${PATHS[@]:1}")
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }

for p in "${PATHS[@]}"; do
  case "$p" in
    /*) ;;
    *) echo "error: dependency path must be absolute: $p" >&2; exit 2 ;;
  esac
  case "$p" in
    *$'\n'*) echo "error: dependency path must not contain a newline" >&2; exit 2 ;;
  esac
done
if [ -n "$SENTINEL" ]; then
  case "$SENTINEL" in
    *$'\n'*) echo "error: --sentinel must not contain a newline" >&2; exit 2 ;;
  esac
  # A regex grep cannot compile would make the check silent forever. Exit 1 is a
  # clean no-match against empty input; anything above it is a compile error.
  sentinel_rc=0
  printf '' | grep -Eq -- "$SENTINEL" 2>/dev/null || sentinel_rc=$?
  [ "$sentinel_rc" -le 1 ] \
    || { echo "error: --sentinel is not a valid extended regular expression" >&2; exit 2; }
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] \
  || { echo "error: no task metadata for $ID; arm the wake on a live task" >&2; exit 1; }
CHECK="$STATE/$ID.check.sh"
RECORD="$STATE/.$ID.await-artifact"
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
if [ -e "$CHECK" ] || [ -L "$CHECK" ]; then
  { [ -f "$CHECK" ] && [ ! -L "$CHECK" ] && head -n 1 "$CHECK" 2>/dev/null | grep -Fqx -- "$MARKER"; } \
    || { echo "error: a different state check is already armed for $ID; retire it through its own owner before arming an artifact wake" >&2; exit 1; }
fi
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
  || { echo "error: custom check path is unavailable" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$RECORD" "$STATE_DEVICE" \
  || { echo "error: await-artifact record path is unavailable" >&2; exit 1; }

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

QUOTED_PATHS=
for p in "${PATHS[@]}"; do
  QUOTED_PATHS="${QUOTED_PATHS}${QUOTED_PATHS:+ }$(shell_quote "$p")"
done
Q_STATE=$(shell_quote "$STATE")
Q_RECORD=$(shell_quote "$RECORD")
Q_SENTINEL=$(shell_quote "$SENTINEL")

umask 077
TMP=$(mktemp "$STATE/.fm-await-artifact-check.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
cat > "$TMP" <<EOF
$MARKER
# Generated by bin/fm-await-artifact.sh; bin/fm-check-register.sh binds these
# exact bytes and the watcher refuses to execute a mismatch. Do not edit: rerun
# the generator instead. Prints one line when the artifact is ready, nothing
# otherwise, including on every error.
set -u
LC_ALL=C
export LC_ALL

state=$Q_STATE
record=$Q_RECORD
sentinel=$Q_SENTINEL
paths=($QUOTED_PATHS)

[ -d "\$state" ] && [ ! -L "\$state" ] || exit 0

file_signature() {
  if [ "\$(uname)" = Darwin ]; then
    stat -f '%m/%z' "\$1" 2>/dev/null
  else
    stat -c '%Y/%s' "\$1" 2>/dev/null
  fi
}

record_write() {
  local tmp
  tmp=\$(mktemp "\$state/.fm-await-artifact.XXXXXX" 2>/dev/null) || return 1
  { printf 'fm-await-artifact-v1\n%s\n' "\$1" > "\$tmp" \
    && chmod 0600 "\$tmp" \
    && mv -f -- "\$tmp" "\$record"; } && return 0
  rm -f -- "\$tmp"
  return 1
}

prior=
if [ -f "\$record" ] && [ ! -L "\$record" ]; then
  version=
  { IFS= read -r version && IFS= read -r prior; } < "\$record" || true
  [ "\$version" = fm-await-artifact-v1 ] || prior=
  [ "\$prior" = fired ] && exit 0
fi

signature=
for p in "\${paths[@]}"; do
  [ -f "\$p" ] && [ -s "\$p" ] || exit 0
  if [ -n "\$sentinel" ]; then
    grep -Eq -- "\$sentinel" "\$p" 2>/dev/null || exit 0
  else
    entry=\$(file_signature "\$p") || exit 0
    [ -n "\$entry" ] || exit 0
    signature="\${signature}\${signature:+ }\$entry"
  fi
done

# Without a producer-declared sentinel, one unchanged sweep is the only evidence
# the file is finished rather than mid-write.
if [ -z "\$sentinel" ] && [ "\$prior" != "seen \$signature" ]; then
  record_write "seen \$signature"
  exit 0
fi

# A record that cannot be persisted would re-fire every sweep, so stay silent.
record_write fired || exit 0
if [ -n "\$sentinel" ]; then
  printf 'artifact ready (sentinel): %s\n' "\${paths[*]}"
else
  printf 'artifact ready: %s\n' "\${paths[*]}"
fi
EOF
chmod 0700 "$TMP" || exit 1
# Clear the previous wait's record BEFORE publishing, so an interruption can
# only leave a check that fires once too often, never one whose stale "fired"
# record silently suppresses the new wait.
rm -f -- "$RECORD"
fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$CHECK" || exit 1
TMP=
"$SCRIPT_DIR/fm-check-register.sh" "$ID" >/dev/null || {
  rm -f -- "$CHECK"
  echo "error: could not register the artifact wake" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
