#!/usr/bin/env bash
# Per-harness Rex program-status evidence guard, run on a private Rex lab server.
# Run explicitly with FM_REX_STATUS_LIVE=1 (it submits prompts to real models).
# For each harness in FM_REX_STATUS_HARNESSES (default: every installed one of
# claude codex opencode pi grok kimi cursor omp), it spawns one trivial scout
# through the normal lifecycle with config/backend=rex, samples the pane's root
# OSC 7501 program-status records until the worker reports done, and prints the
# states each harness published. Absent harnesses are reported, never skipped
# silently; a run that exercised no harness fails rather than passing vacuously.
# Claude Code is the one harness whose program status drives busy_state and
# submit confirmation (FM_BACKEND_REX_STATUS_APPS), so the guard fails naming
# its version if Claude stops publishing `working`, or if its root record still
# reads `working` once the worker has reported done and its turn has ended.
# Other harnesses are evidence for docs/verification/runtime-backends.md, never
# a failure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=
REX_LAB=
TASK=
LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

untimed_status() { sed -E 's/ \[at=[0-9]+\]//g' "$1" 2>/dev/null; }

teardown_task() {
  [ -n "$TASK" ] || return 0
  mkdir -p "$LAB/data/$TASK"
  : > "$LAB/data/$TASK/report.md"
  FM_HOME="$LAB" "$ROOT/bin/fm-decision-hold.sh" complete "$TASK" --none >/dev/null 2>&1 || true
  FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$TASK" >/dev/null 2>&1 || true
  TASK=
}

cleanup() {
  teardown_task
  [ -z "$REX_LAB" ] || "$LAB_HELPER" teardown "$REX_LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fm_live_gate opt-in FM_REX_STATUS_LIVE rex jq treehouse python3

unset TMUX HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER 2>/dev/null || true

harness_bin() {
  case "$1" in
    cursor) printf 'cursor-agent' ;;
    *) printf '%s' "$1" ;;
  esac
}

harness_version() {
  "$(harness_bin "$1")" --version 2>/dev/null | head -1
}

trap cleanup EXIT
REX_LAB=$("$LAB_HELPER" name rexstatus)
"$LAB_HELPER" provision "$REX_LAB" || fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$REX_LAB")
export FM_REX_SERVER
REX_VERSION=$("$LAB_HELPER" run "$REX_LAB" version 2>/dev/null | head -1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-status.XXXXXX") || fail "could not create an isolated lab home"
mkdir -p "$LAB/config" "$LAB/projects/probe" "$LAB/state"
printf 'rex\n' > "$LAB/config/backend"
git -C "$LAB/projects/probe" init -q -b main || fail "could not initialize the probe repository"
git -C "$LAB/projects/probe" config user.email 'rex-status-test@example.invalid'
git -C "$LAB/projects/probe" config user.name 'rex status test'
printf 'Rex program-status probe\n' > "$LAB/projects/probe/README.md"
git -C "$LAB/projects/probe" add README.md
git -C "$LAB/projects/probe" commit -qm 'fixture: initialize program-status probe'

FM_HOME="$LAB"
export FM_HOME
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || fail "could not source the rex adapter"

root_states() {
  fm_backend_rex_block_call "$1" program_status 2>/dev/null \
    | jq -r '[.. | objects | select(has("state") and ((.id // "") == "")) | "\(.app // "?"):\(.state)"] | unique | join(",")' 2>/dev/null
}

HARNESSES=${FM_REX_STATUS_HARNESSES:-claude codex opencode pi grok kimi cursor omp}
EXERCISED=0
REPORT=
CLAUDE_WORKING=skip
CLAUDE_TURN_END=skip
n=0
for harness in $HARNESSES; do
  n=$((n + 1))
  if ! command -v "$(harness_bin "$harness")" >/dev/null 2>&1; then
    REPORT="$REPORT
info - $harness: absent (not installed)"
    continue
  fi
  version=$(harness_version "$harness")
  TASK="fm-test-rex-status-$n-$$"
  STATUS="$LAB/state/$TASK.status"
  mkdir -p "$LAB/data/$TASK"
  FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" probe --scout >/dev/null || fail "could not scaffold the $harness probe brief"
  python3 - "$LAB/data/$TASK/brief.md" "$STATUS" <<'PY'
from pathlib import Path
import sys

brief = Path(sys.argv[1])
status = sys.argv[2]
brief.write_text(brief.read_text().replace("{TASK}", f'''Run a Rex program-status probe.

Append `done [at=<epoch>]: probe finished` to `{status}`, substituting `<epoch>` as rule 4 instructs, and stop.
Do not change project files or make a commit.''').replace("{FIRSTMATE_SPEC}", "Nothing beyond the step above."))
PY
  model_args=()
  [ "$harness" != claude ] || model_args=(--model haiku)
  if ! FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$LAB/projects/probe" --scout --harness "$harness" ${model_args[@]+"${model_args[@]}"} >/dev/null 2>&1; then
    REPORT="$REPORT
info - $harness ($version): could not launch in the lab home"
    TASK=
    continue
  fi
  target=$(awk -F= '/^window=/{print $2}' "$LAB/state/$TASK.meta")
  seen=
  for _ in $(seq 1 90); do
    capture=$(fm_backend_rex_capture "$target" 60 "fm-$TASK" 2>/dev/null || true)
    case "$capture" in
      *'Yes, I trust this folder'* | *'Trust this folder'* | *'Do you trust'*)
        FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" --key Enter >/dev/null 2>&1 || true ;;
    esac
    s=$(root_states "$target")
    [ -z "$s" ] || seen="$seen,$s"
    untimed_status "$STATUS" | grep -q '^done: probe finished' && break
    sleep 2
  done
  s=$(root_states "$target")
  [ -z "$s" ] || seen="$seen,$s"
  finished=no
  untimed_status "$STATUS" | grep -q '^done: probe finished' && finished=yes
  seen=$(printf '%s' "${seen#,}" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -)
  EXERCISED=$((EXERCISED + 1))
  REPORT="$REPORT
info - $harness ($version): root program states [${seen:-none}] finished=$finished"
  if [ "$harness" = claude ]; then
    case ",$seen," in
      *':working,'*) CLAUDE_WORKING=yes ;;
      *) CLAUDE_WORKING="no ($version)" ;;
    esac
    CLAUDE_TURN_END="unproven, the probe did not finish ($version)"
    if [ "$finished" = yes ]; then
      CLAUDE_TURN_END="still working ($version)"
      for _ in $(seq 1 30); do
        rec=$(fm_backend_rex_root_status "$target") || { sleep 2; continue; }
        if [ "${rec%%$'\t'*}" != working ]; then
          CLAUDE_TURN_END=yes
          break
        fi
        sleep 2
      done
    fi
    REPORT="$REPORT
info - $harness ($version): root record leaves working after the turn: $CLAUDE_TURN_END"
  fi
  teardown_task
done

printf '%s\n' "${REPORT#
}"
printf 'info - %s on %s\n' "$(date -u +%Y-%m-%d)" "$REX_VERSION"
[ "$EXERCISED" -gt 0 ] || fail "no harness was exercised, refusing a vacuous pass ($HARNESSES)"
case "$CLAUDE_WORKING" in
  yes) pass "Claude Code still publishes a root working program status on Rex" ;;
  skip) pass "program-status evidence recorded for $EXERCISED harness(es); Claude Code not in this run" ;;
  *) fail "Claude Code stopped publishing a root working program status on Rex: $CLAUDE_WORKING; busy_state and submit confirmation depend on it" ;;
esac
case "$CLAUDE_TURN_END" in
  yes) pass "Claude Code's root program status leaves working once its turn ends" ;;
  skip) ;;
  *) fail "Claude Code's root program status did not leave working after its turn: $CLAUDE_TURN_END; busy_state would read an idle pane as busy" ;;
esac
