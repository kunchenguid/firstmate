#!/usr/bin/env bash
# tests/fm-progress-label-herdr-e2e.test.sh - real-Herdr guard for the
# display-only progress label suffix (bin/backends/herdr.sh
# fm_backend_herdr_projection_progress_apply, driven by bin/fm-progress-lib.sh).
#
# The rename primitive, the read-back that verifies it, and the focus it must
# leave alone are all vendor behavior, so a fake `herdr` can only confirm the
# assumption written into the fake. This suite talks to a REAL herdr server on
# a private, named, throwaway lab session (never the default session; see
# tests/herdr-test-safety.sh) and proves, on the installed release:
#   - a bound version 2 projection's workspace is renamed to its journaled base
#     plus the suffix, with the token still the label's last segment
#   - the rename does not move the captain's focused workspace or tab
#   - an unchanged suffix is a no-op and a changed suffix replaces the segment
#   - a label changed by hand is left alone, reported as hand-changed with
#     status 1 (the library owns warning once per reason)
#   - a task without a version 2 journal is skipped silently with status 2
# Skips cleanly when herdr, jq, or a running default session is unavailable.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-progress-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-label.XXXXXX")
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "skip: could not prepare an isolated Herdr lab session"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
fm_backend_herdr_version_check || fail "version_check failed against the installed herdr"
RELEASE=$(herdr status --json 2>/dev/null | jq -r '.client.version // "unknown"')

STATE="$SCRATCH/state"
mkdir -p "$STATE"
ID=progress-e2e
TOKEN=$(fm_backend_herdr_projection_id) || fail "could not mint a projection token"
BASE=$(fm_backend_herdr_projection_workspace_label "$ID" "$TOKEN")

# The home workspace first (focused, as the first workspace of a new session
# must be), then the projected child created flat with the base label.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
PARENT_WS=${CONTAINER_RAW%%$'\t'*}
PARENT_WS=${PARENT_WS#*:}
CREATE=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd /tmp --label "$BASE" --no-focus 2>/dev/null) \
  || fail "workspace create failed"
WS=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id // empty')
TAB=$(printf '%s' "$CREATE" | jq -r '.result.tab.tab_id // empty')
PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WS" ] && [ -n "$TAB" ] && [ -n "$PANE" ] || fail "workspace create returned incomplete ids: $CREATE"

live_label() {  # <workspace-id>
  fm_backend_herdr_cli "$SESSION" workspace get "$1" 2>/dev/null | jq -r '.result.workspace.label // empty'
}

[ "$(live_label "$WS")" = "$BASE" ] || fail "the projected workspace did not start with its base label"

# A version 2 binding, exactly as fm-spawn publishes after convergence.
fm_backend_herdr_projection_journal_create "$STATE" "$ID" >/dev/null || fail "journal create failed"
JOURNAL=$(fm_backend_herdr_projection_journal_path "$STATE" "$ID")
printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$ID" "$TOKEN" > "$JOURNAL"
fm_backend_herdr_projection_journal_bind "$JOURNAL" "$ID" "$SCRATCH" "$SESSION" "$WS" "$TAB" "$PANE" \
  "$PARENT_WS" "$(fm_backend_herdr_workspace_label)" "$BASE" "fm-$ID" || fail "journal bind failed"

FOCUS_BEFORE=$(fm_backend_herdr_projection_focus_snapshot "$SESSION") || fail "could not snapshot focus"

fm_backend_herdr_projection_progress_apply "$STATE" "$ID" " · validating · ~25 min" \
  || fail "progress apply must succeed on a bound projection"
[ "$(live_label "$WS")" = "└ $ID · validating · ~25 min · p:$TOKEN" ] \
  || fail "live label after apply: $(live_label "$WS")"
printf '%s\n' "$(live_label "$WS")" | grep -Eq '^└ .+ · p:[A-Za-z0-9_-]{22}$' \
  || fail "the decorated label must keep the projected child grammar"
pass "real herdr $RELEASE: a bound projection's workspace is renamed to base plus suffix with the token last"

FOCUS_AFTER=$(fm_backend_herdr_projection_focus_snapshot "$SESSION") || fail "could not re-snapshot focus"
[ "$FOCUS_AFTER" = "$FOCUS_BEFORE" ] || fail "the rename moved focus: before '$FOCUS_BEFORE' after '$FOCUS_AFTER'"
pass "real herdr $RELEASE: the rename leaves the focused workspace and tab unchanged"

fm_backend_herdr_projection_progress_apply "$STATE" "$ID" " · validating · ~25 min" \
  || fail "an unchanged suffix must be a successful no-op"
fm_backend_herdr_projection_progress_apply "$STATE" "$ID" " · ci · 5 to 15 min" \
  || fail "a changed suffix must apply"
[ "$(live_label "$WS")" = "└ $ID · ci · 5 to 15 min · p:$TOKEN" ] \
  || fail "live label after the second apply: $(live_label "$WS")"
[ "$(fm_backend_herdr_projection_label_base "$(live_label "$WS")")" = "$BASE" ] \
  || fail "the base must be recoverable from the live decorated label"
pass "real herdr $RELEASE: an unchanged suffix is a no-op and a changed suffix replaces the segment"

fm_backend_herdr_cli "$SESSION" workspace rename "$WS" "my own name" >/dev/null 2>&1 \
  || fail "hand rename failed"
if fm_backend_herdr_projection_progress_apply "$STATE" "$ID" " · ready" 2> "$SCRATCH/warn"; then
  fail "a hand-changed label must refuse"
else
  rc=$?
fi
[ "$rc" -eq 1 ] || fail "a hand-changed label must refuse with status 1, got $rc"
[ "$FM_BACKEND_HERDR_PROGRESS_REASON" = hand-changed ] || fail "a hand-changed label must report its reason, got '$FM_BACKEND_HERDR_PROGRESS_REASON'"
[ ! -s "$SCRATCH/warn" ] || fail "the adapter reports the reason and leaves the warning to its caller: $(cat "$SCRATCH/warn")"
[ "$(live_label "$WS")" = "my own name" ] || fail "a hand-changed label must survive"
pass "real herdr $RELEASE: a label changed by hand is left alone and reported as hand-changed"

rm -f "$JOURNAL"
if fm_backend_herdr_projection_progress_apply "$STATE" "$ID" " · ready" 2> "$SCRATCH/warn2"; then
  fail "a task without a journal must not apply"
else
  rc=$?
fi
[ "$rc" -eq 2 ] || fail "a task without a journal must skip with status 2, got $rc"
[ ! -s "$SCRATCH/warn2" ] || fail "skipping must be silent: $(cat "$SCRATCH/warn2")"
pass "real herdr $RELEASE: a task without a version 2 journal is skipped silently"

pass "real Herdr lab validation completed on Herdr $RELEASE with the default-session tripwire intact"
