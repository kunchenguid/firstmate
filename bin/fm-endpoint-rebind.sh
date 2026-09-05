#!/usr/bin/env bash
# Repair one legacy Herdr task record that predates endpoint_task_id.
#
# Usage: fm-endpoint-rebind.sh <task-id>
#
# This is the only supported re-binding path for an opaque Herdr endpoint.
# It never infers ownership from a label alone and never relaxes teardown's
# metadata-only authorization guard. Before atomically adding the binding, it:
#   - acquires the task's existing spawn lock;
#   - validates the complete prospective metadata record through teardown's
#     unchanged endpoint validator;
#   - refuses another task record that claims the same worktree, tab, or pane;
#   - verifies the exact live pane/tab/workspace relationships, unique fm-<id>
#     task label, and canonical foreground cwd equal to the recorded worktree;
#   - repeats the endpoint snapshot and competing-record scan, then requires the source
#     metadata bytes to be unchanged before publishing.
# Existing correct bindings are a validated no-op. Empty, duplicate, mismatched,
# non-Herdr, missing-live-endpoint, relabeled, moved, or ambiguous records are
# preserved and refused.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: usage: fm-endpoint-rebind.sh <task-id>" >&2
  exit 2
fi
ID=$1
fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "REFUSED: task $ID has no regular endpoint metadata at $META; preserving task state." >&2
  exit 1
}

LOCK="$STATE/.spawn-$ID.lock"
LOCK_HELD=0
SNAPSHOT=
CANDIDATE=
cleanup() {
  [ -z "$SNAPSHOT" ] || rm -f -- "$SNAPSHOT"
  [ -z "$CANDIDATE" ] || rm -f -- "$CANDIDATE"
  if [ "$LOCK_HELD" -eq 1 ]; then
    LOCK_HELD=0
    fm_lock_release "$LOCK" || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if ! fm_lock_try_acquire "$LOCK"; then
  echo "REFUSED: task $ID is being created or recovered; preserving task state." >&2
  exit 1
fi
LOCK_HELD=1

binding_count=$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)
case "$binding_count" in
  0) ;;
  1)
    binding=$(fm_backend_meta_exact_value "$META" endpoint_task_id) || {
      echo "REFUSED: task $ID has an empty endpoint task binding; preserving task state." >&2
      exit 1
    }
    [ "$binding" = "$ID" ] || {
      echo "REFUSED: endpoint metadata belongs to task $binding, not $ID; preserving task state." >&2
      exit 1
    }
    fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
    printf 'endpoint binding for task %s is already valid\n' "$ID"
    exit 0
    ;;
  *)
    echo "REFUSED: task $ID has an ambiguous endpoint task binding; preserving task state." >&2
    exit 1
    ;;
esac

backend=$(fm_backend_meta_exact_value "$META" backend 2>/dev/null || true)
[ "$backend" = herdr ] || {
  echo "REFUSED: verified legacy endpoint re-binding currently supports Herdr metadata only; preserving task state." >&2
  exit 1
}

SNAPSHOT=$(umask 077; mktemp "$STATE/.$ID.endpoint-rebind-source.XXXXXX") || exit 1
CANDIDATE=$(umask 077; mktemp "$STATE/.$ID.endpoint-rebind-candidate.XXXXXX") || exit 1
cp -- "$META" "$SNAPSHOT"
cmp -s "$SNAPSHOT" "$META" || {
  echo "REFUSED: endpoint metadata for task $ID changed while it was being read; preserving task state." >&2
  exit 1
}
{
  cat "$SNAPSHOT"
  if [ -s "$SNAPSHOT" ] \
    && [ "$(tail -c 1 "$SNAPSHOT" | wc -l | tr -d '[:space:]')" -eq 0 ]; then
    printf '\n'
  fi
  printf 'endpoint_task_id=%s\n' "$ID"
} > "$CANDIDATE"
fm_backend_validate_task_endpoint "$CANDIDATE" "$ID" || exit 1

SESSION=$(fm_backend_meta_exact_value "$CANDIDATE" herdr_session)
WORKSPACE=$(fm_backend_meta_exact_value "$CANDIDATE" herdr_workspace_id)
TAB=$(fm_backend_meta_exact_value "$CANDIDATE" herdr_tab_id)
PANE=$(fm_backend_meta_exact_value "$CANDIDATE" herdr_pane_id)
WINDOW=$(fm_backend_meta_exact_value "$CANDIDATE" window)
WORKTREE=$(fm_backend_meta_exact_value "$CANDIDATE" worktree)
WORKTREE_REAL=$(CDPATH='' cd -- "$WORKTREE" 2>/dev/null && pwd -P) || {
  echo "REFUSED: recorded Herdr worktree for task $ID is absent or unreadable; preserving task state." >&2
  exit 1
}

# Read one octal file mode from whichever stat flavor this host actually has,
# probed by trying BSD syntax and accepting only a well-formed octal answer.
# GNU coreutils can shadow BSD stat (and the reverse), so the installed flavor
# is not derivable from the OS name.
legacy_endpoint_file_mode() {  # <file>
  local mode
  mode=$(stat -f %Lp "$1" 2>/dev/null) || mode=
  case "$mode" in
    ''|*[!0-7]*) mode=$(stat -c %a "$1" 2>/dev/null) || mode= ;;
  esac
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  printf '%s\n' "$mode"
}

legacy_endpoint_has_competing_claim() {
  local other other_id other_worktree other_worktree_real
  for other in "$STATE"/*.meta; do
    [ -e "$other" ] || [ -L "$other" ] || continue
    [ "$other" != "$META" ] || continue
    if [ ! -f "$other" ] || [ -L "$other" ]; then
      echo "REFUSED: task endpoint ownership cannot be verified while another task record is unsafe; preserving task state." >&2
      return 0
    fi
    other_id=$(basename "$other" .meta)
    while IFS= read -r other_worktree; do
      other_worktree=${other_worktree#worktree=}
      [ -n "$other_worktree" ] || continue
      if [ "$other_worktree" = "$WORKTREE" ]; then
        echo "REFUSED: task $other_id also claims the recorded worktree for task $ID; preserving task state." >&2
        return 0
      fi
      other_worktree_real=$(CDPATH='' cd -- "$other_worktree" 2>/dev/null && pwd -P) || continue
      if [ "$other_worktree_real" = "$WORKTREE_REAL" ]; then
        echo "REFUSED: task $other_id also claims the recorded worktree for task $ID; preserving task state." >&2
        return 0
      fi
    done < <(grep '^worktree=' "$other" 2>/dev/null || true)
    grep -Fqx -- 'backend=herdr' "$other" || continue
    if grep -Fqx -- "window=$WINDOW" "$other" \
      || grep -Fqx -- "herdr_tab_id=$TAB" "$other" \
      || grep -Fqx -- "herdr_pane_id=$PANE" "$other"; then
      echo "REFUSED: task $other_id also claims the recorded Herdr endpoint for task $ID; preserving task state." >&2
      return 0
    fi
  done
  return 1
}

if legacy_endpoint_has_competing_claim; then
  exit 1
fi
fm_backend_source herdr || exit 1
fm_backend_herdr_verify_task_binding \
  "$SESSION" "$WORKSPACE" "$TAB" "$PANE" "$ID" "$WORKTREE" || exit 1
if legacy_endpoint_has_competing_claim; then
  exit 1
fi
if [ ! -f "$META" ] || [ -L "$META" ] || ! cmp -s "$SNAPSHOT" "$META"; then
  echo "REFUSED: endpoint metadata for task $ID changed during ownership verification; preserving task state." >&2
  exit 1
fi

META_MODE=$(legacy_endpoint_file_mode "$META") || META_MODE=
case "$META_MODE" in
  ''|*[!0-7]*)
    echo "REFUSED: file mode of endpoint metadata for task $ID could not be read; preserving task state." >&2
    exit 1
    ;;
esac
chmod "$META_MODE" "$CANDIDATE" || {
  echo "REFUSED: repaired endpoint metadata for task $ID could not keep the recorded file mode; preserving task state." >&2
  exit 1
}
mv -f -- "$CANDIDATE" "$META"
CANDIDATE=
printf 'verified endpoint binding recorded for task %s\n' "$ID"
