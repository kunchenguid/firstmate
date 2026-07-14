#!/usr/bin/env bash
# bin/fm-secondmate-retire.sh — retire (decommission) a persistent secondmate.
#
# Usage:
#   fm-secondmate-retire.sh <id> [--force] [--keep-home]
#
# Verb shape mirrors fm-home-seed.sh: the script owns its registry line,
# refuses unsafe input, prints what it did, and exits 0 on success.
#
# Steps (idempotent where possible):
#   1. Look up <id> in $DATA/secondmates.md; extract the recorded home,
#      scope, projects, and the registry line.
#   2. Refuse if the home path does not exist, is not marked as a
#      secondmate home, or is not marked for <id>.
#   3. Refuse if the secondmate has in-flight crewmate meta files in
#      state/ (a spawned crewmate is still owed its own teardown).
#      --force overrides this guard with a printed warning.
#   4. Look for any orca terminal whose session id starts with
#      "fm-secondmate-<id>-" and kill it via bin/fmod when available.
#      This closes the persistent terminal that the secondmate owned.
#      Unknown / already-dead terminals are skipped.
#   5. Remove the secondmate registry line from $DATA/secondmates.md.
#   6. Remove $HOME/.fm-secondmate-home and any $STATE/<id>.*
#      volatile state files. With --keep-home the on-disk home is left
#      intact for inspection; without it, the home is removed
#      (rm -rf) and, if a treehouse-issued worktree under it has an
#      outstanding lease, "treehouse return" is attempted so the pool
#      slot is freed and not held forever.
#   7. Print a summary so the captain can confirm what was retired.
#
# Safety:
#   The home path, the .fm-secondmate-home marker, and the registry line
#   are all required to agree on the same <id>; any disagreement aborts
#   the retire rather than risking deleting the wrong home.
#
# Exit:
#   0  retired successfully (or already retired — idempotent)
#   1  validation refused (prints the reason)
#   2  in-flight crewmate meta files (without --force)
#   3  treehouse return failed (the home, registry, and state are preserved)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  printf 'usage: fm-secondmate-retire.sh <id> [--force] [--keep-home]\n' >&2
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(canonical_dir "$target") || return 1
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(canonical_dir "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

state_dir_is_home_state() {
  local state_dir=$1 state_real
  [ -n "$HOME_STATE_REAL" ] || return 1
  state_real=$(canonical_dir "$state_dir" || true)
  [ -n "$state_real" ] && [ "$state_real" = "$HOME_STATE_REAL" ]
}

list_inflight_meta() {
  local state_dir=$1 meta home_field
  if state_dir_is_home_state "$state_dir"; then
    # Home STATE only contains secondmate-owned meta files; list all of
    # them. This intentionally does NOT prefix-filter so any in-flight
    # child task (regardless of name) is surfaced.
    for meta in "$state_dir/"*.meta; do
      [ -e "$meta" ] || continue
      printf '%s\n' "$meta"
    done
  else
    # Main STATE also contains unrelated firstmate tasks. Defensively
    # match ${ID}-*.meta (true child tasks of this secondmate spawned
    # from the main home would land here) BUT only if the meta records
    # this secondmate's home as its own home field. This prevents
    # overmatching unrelated main-firstmate tasks whose ids share the
    # secondmate id as a prefix (e.g. secondmate id "qa" must not match
    # a main task "qa-fix-login" that lives under a different home).
    for meta in "$state_dir/${ID}-"*.meta; do
      [ -e "$meta" ] || continue
      home_field=$(fm_meta_get "$meta" home 2>/dev/null || true)
      if [ -n "$HOME_PATH" ] && [ "$home_field" = "$HOME_PATH" ]; then
        printf '%s\n' "$meta"
      fi
    done
  fi
}

cleanup_child_meta() {
  local child_meta=$1 child_id child_kind child_backend child_target child_worktree child_project child_orca_worktree_id
  child_id=$(basename "$child_meta" .meta)
  if grep -q '^kind=secondmate$' "$child_meta" 2>/dev/null || grep -qE "^- $child_id( |\$)" "$REG" 2>/dev/null; then
    return 0
  fi
  child_kind=$(fm_meta_get "$child_meta" kind)
  [ -n "$child_kind" ] || child_kind=ship
  child_backend=$(fm_backend_of_meta "$child_meta")
  if [ "$child_backend" = orca ]; then
    child_target=$(fm_meta_get "$child_meta" terminal)
  else
    child_target=$(fm_backend_target_of_meta "$child_meta")
  fi
  if [ -n "$child_target" ]; then
    if [ "$child_backend" = zellij ]; then
      ( unset FM_ROOT_OVERRIDE; FM_HOME=$HOME_PATH FM_ROOT=$HOME_PATH fm_backend_kill "$child_backend" "$child_target" "$(fm_meta_get "$child_meta" zellij_tab_id)" "fm-$child_id" ) >/dev/null 2>&1 || true
    else
      fm_backend_kill "$child_backend" "$child_target" "$(fm_meta_get "$child_meta" zellij_tab_id)" "fm-$child_id" >/dev/null 2>&1 || true
    fi
  fi
  child_worktree=$(fm_meta_get "$child_meta" worktree)
  child_project=$(fm_meta_get "$child_meta" project)
  if [ "$child_backend" = orca ]; then
    child_orca_worktree_id=$(fm_meta_get "$child_meta" orca_worktree_id)
    if [ -n "$child_orca_worktree_id" ]; then
      fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" >/dev/null 2>&1 || {
        printf 'error: could not remove child orca worktree for %s\n' "$child_id" >&2
        return 1
      }
    elif [ -n "$child_worktree" ] && [ -e "$child_worktree" ]; then
      printf 'error: child %s is missing orca_worktree_id; preserving home for retry\n' "$child_id" >&2
      return 1
    fi
  elif [ -n "$child_worktree" ] && [ -e "$child_worktree" ]; then
    if ! worktree_registered_for_project "$child_project" "$child_worktree"; then
      printf 'error: child worktree %s for %s is not registered under %s; preserving home for retry\n' "$child_worktree" "$child_id" "${child_project:-<missing project>}" >&2
      return 1
    fi
    if [ -n "$child_project" ] && [ -d "$child_project" ] && command -v treehouse >/dev/null 2>&1; then
      ( cd "$child_project" && treehouse return --force "$child_worktree" ) >/dev/null 2>&1 && return 0
    fi
    if git -C "$child_project" worktree remove --force "$child_worktree" >/dev/null 2>&1; then
      return 0
    fi
    printf 'error: could not remove child worktree %s for %s; preserving home for retry\n' "$child_worktree" "$child_id" >&2
    return 1
  fi
}

# Parse --help / -h FIRST so a stray help invocation never gets routed
# to the registry as an <id>. Flags are recognized in any position; <id>
# is the first non-flag argument. After the id is captured, any
# remaining args are flags; reject anything else.
FORCE=0
KEEP_HOME=0
ID=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    --keep-home) KEEP_HOME=1; shift ;;
    -*) printf 'error: unknown flag %s\n' "$1" >&2; usage; exit 1 ;;
    *)
      ID=$1
      shift
      break
      ;;
  esac
done
# After the id, accept the same flags again; reject anything else.
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1; shift ;;
    --keep-home) KEEP_HOME=1; shift ;;
    -*) printf 'error: unknown flag %s\n' "$1" >&2; usage; exit 1 ;;
    *) printf 'error: unexpected argument after id: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$ID" ] || { usage; exit 1; }

# 1. Look up the registry line for <id>.
[ -f "$REG" ] || {
  printf 'error: secondmate registry not found at %s\n' "$REG" >&2
  exit 1
}
LINE=$(grep -E "^- $ID( |\$)" "$REG" | head -1 || true)
[ -n "$LINE" ] || {
  printf 'error: secondmate %s is not registered in %s\n' "$ID" "$REG" >&2
  exit 1
}

HOME_PATH=$(printf '%s\n' "$LINE" | sed -nE 's/^[^(]*\(home: ([^;)]*);.*/\1/p')
SCOPE=$(printf '%s\n' "$LINE" | sed -nE 's/^[^(]*\(home: [^;)]*; scope: ([^;)]*);.*/\1/p')
PROJECTS_CSV=$(printf '%s\n' "$LINE" | sed -nE 's/^[^(]*\(home: [^;)]*; scope: [^;)]*; projects: ([^;)]*);.*/\1/p')

[ -n "$HOME_PATH" ] || {
  printf 'error: registry line for %s is malformed (no home:)\n' "$ID" >&2
  exit 1
}

printf '[fm-secondmate-retire] id=%s home=%s scope=%s\n' "$ID" "$HOME_PATH" "$SCOPE"

# 2. Validate the home path / marker agreement.
[ -d "$HOME_PATH" ] || {
  printf 'error: registered home %s does not exist\n' "$HOME_PATH" >&2
  exit 1
}
[ -f "$HOME_PATH/$SUB_HOME_MARKER" ] || {
  printf 'error: registered home %s is not marked as a secondmate home (missing %s)\n' "$HOME_PATH" "$SUB_HOME_MARKER" >&2
  exit 1
}
MARKER_ID=$(cat "$HOME_PATH/$SUB_HOME_MARKER")
[ "$MARKER_ID" = "$ID" ] || {
  printf 'error: registered home %s is marked for %s, expected %s\n' "$HOME_PATH" "$MARKER_ID" "$ID" >&2
  exit 1
}
validate_secondmate_home "$ID" "$HOME_PATH" || {
  printf 'error: registered home %s is unsafe: %s\n' "$HOME_PATH" "$VALIDATION_ERROR" >&2
  exit 1
}
HOME_PATH=$VALIDATED_HOME

STATE_DIRS=()
if [ -d "$STATE" ]; then
  STATE_DIRS+=("$STATE")
fi
SECONDMATE_META="$STATE/$ID.meta"
SECONDMATE_BACKEND=
SECONDMATE_TARGET=
if [ -f "$SECONDMATE_META" ]; then
  SECONDMATE_BACKEND=$(fm_backend_of_meta "$SECONDMATE_META")
  SECONDMATE_TARGET=$(fm_backend_target_of_meta "$SECONDMATE_META")
fi
HOME_STATE="$HOME_PATH/state"
HOME_STATE_REAL=""
if [ -d "$HOME_STATE" ]; then
  add_home_state=1
  home_state_real=$(canonical_dir "$HOME_STATE" || true)
  HOME_STATE_REAL=$home_state_real
  for state_dir in "${STATE_DIRS[@]}"; do
    state_dir_real=$(canonical_dir "$state_dir" || true)
    if [ -n "$home_state_real" ] && [ "$home_state_real" = "$state_dir_real" ]; then
      add_home_state=0
      break
    fi
  done
  [ "$add_home_state" -eq 1 ] && STATE_DIRS+=("$HOME_STATE")
fi

# 3. Refuse if there are in-flight crewmate meta files for this secondmate.
#    Each "<id>-<task>.meta" record is a crewmate the secondmate owns;
#    those need their own teardown before the secondmate can be retired.
INFLIGHT=$(
  for state_dir in "${STATE_DIRS[@]}"; do
    list_inflight_meta "$state_dir"
  done | sort -u | head -5
)
if [ -n "$INFLIGHT" ] && [ "$FORCE" -eq 0 ]; then
  printf 'error: secondmate %s has in-flight crewmate meta files:\n' "$ID" >&2
  printf '%s\n' "$INFLIGHT" | sed 's/^/  /' >&2
  printf 'tear down those crewmates first (fm-teardown.sh <task-id>), or pass --force to discard their work.\n' >&2
  exit 2
fi
if [ "$FORCE" -eq 1 ]; then
  for state_dir in "${STATE_DIRS[@]}"; do
    while IFS= read -r child_meta; do
      [ -e "$child_meta" ] || continue
      cleanup_child_meta "$child_meta" || exit 1
    done < <(list_inflight_meta "$state_dir")
  done
fi

# 4. Kill any persistent Orca terminal the secondmate owned.
#    FM_SECONDMATE_RETIRE_FMOD lets tests stub the fmod binary without
#    touching the real firstmate bin/fmod; defaults to the real one.
#    We kill by EXACT recorded target id (SECONDMATE_TARGET from the
#    secondmate's own meta), never by a prefix match. A prefix match
#    overmatches nested secondmate ids (e.g. retiring "qa" would
#    silently kill "qa-prod" which has its own registry entry).
FMOD_BIN="${FM_SECONDMATE_RETIRE_FMOD:-$SCRIPT_DIR/fmod}"
ALL_ORCA_SIDS=
ORCA_LIST_OK=0
if [ -x "$FMOD_BIN" ]; then
  ORCA_LIST_JSON=$("$FMOD_BIN" list 2>/dev/null) || {
    ORCA_LIST_JSON=
    ORCA_LIST_OK=1
  }
  ALL_ORCA_SIDS=$(printf '%s\n' "$ORCA_LIST_JSON" | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
except Exception:
  sys.exit(1)
for s in data:
  sid = s.get('sessionId') or s.get('id') or ''
  if sid:
    print(sid)
" 2>/dev/null) || {
    ALL_ORCA_SIDS=
    ORCA_LIST_OK=1
  }
fi
if [ -z "$FMOD_BIN" ] || [ ! -x "$FMOD_BIN" ]; then
  if { [ -f "$CONFIG/backend" ] && [ "$(cat "$CONFIG/backend" 2>/dev/null || true)" = orca ]; } || [ "$SECONDMATE_BACKEND" = orca ]; then
    printf 'error: no bin/fmod; home, registry, and state preserved\n' >&2
    exit 1
  fi
fi
if [ -n "$SECONDMATE_BACKEND" ] && [ -n "$SECONDMATE_TARGET" ]; then
  case "$SECONDMATE_BACKEND" in
    orca)
      if [ -x "$FMOD_BIN" ]; then
        if "$FMOD_BIN" kill "$SECONDMATE_TARGET" --immediate >/dev/null 2>&1; then
          printf '  ✓ killed recorded orca terminal %s\n' "$SECONDMATE_TARGET"
        else
          if [ "$ORCA_LIST_OK" -ne 0 ]; then
            printf 'error: could not confirm recorded orca terminal %s is absent; home, registry, and state preserved\n' "$SECONDMATE_TARGET" >&2
            exit 1
          fi
          case " $ALL_ORCA_SIDS " in
            *" $SECONDMATE_TARGET "*)
              printf 'error: could not kill recorded orca terminal %s; home, registry, and state preserved\n' "$SECONDMATE_TARGET" >&2
              exit 1
              ;;
          esac
        fi
      else
        printf 'error: no bin/fmod for recorded orca terminal %s; home, registry, and state preserved\n' "$SECONDMATE_TARGET" >&2
        exit 1
      fi
      ;;
    *)
      if fm_backend_kill "$SECONDMATE_BACKEND" "$SECONDMATE_TARGET" >/dev/null 2>&1; then
        printf '  ✓ closed %s endpoint %s\n' "$SECONDMATE_BACKEND" "$SECONDMATE_TARGET"
      else
        printf '  ! could not close %s endpoint %s (already gone?)\n' "$SECONDMATE_BACKEND" "$SECONDMATE_TARGET" >&2
      fi
      ;;
  esac
fi

# 5. Release a treehouse lease before removing firstmate-owned records so
#    failures preserve enough state for a safe retry.
HOME_REMOVED=0
HOME_DISPOSITION='kept; --keep-home'
LEASE_RETURNED=0
if [ "$KEEP_HOME" -eq 0 ] && worktree_registered_for_project "$FM_ROOT" "$HOME_PATH"; then
  if command -v treehouse >/dev/null 2>&1; then
    if ( cd "$FM_ROOT" && treehouse return --force "$HOME_PATH" >/dev/null 2>&1 ); then
      LEASE_RETURNED=1
      printf '  ✓ released treehouse lease for %s\n' "$HOME_PATH"
    else
      printf 'error: treehouse return failed for %s; home, registry, and state preserved\n' "$HOME_PATH" >&2
      exit 3
    fi
  else
    printf 'error: treehouse command not found for %s; home, registry, and state preserved\n' "$HOME_PATH" >&2
    exit 3
  fi
fi

# 6. Remove the registry line.
tmp="$REG.tmp.$$"
grep -vE "^- $ID( |\$)" "$REG" > "$tmp" || true
mv "$tmp" "$REG"
printf '  ✓ removed registry line for %s\n' "$ID"

# 7. Clean state files for the secondmate and the .fm-secondmate-home
#    marker. The marker is a firstmate-owned file that says "this home
#    is a registered secondmate home of id X" — once retired, the home
#    is no longer registered, so the marker is stale. Delete it even
#    under --keep-home; --keep-home only spares the operator's own
#    project data, not firstmate's bookkeeping.
if [ "${#STATE_DIRS[@]}" -gt 0 ]; then
  CLEAN_IDS=$ID
  if [ "$FORCE" -eq 1 ]; then
    for state_dir in "${STATE_DIRS[@]}"; do
      while IFS= read -r child_meta; do
        [ -e "$child_meta" ] || continue
        child_id=$(basename "$child_meta" .meta)
        if grep -q '^kind=secondmate$' "$child_meta" 2>/dev/null || grep -qE "^- $child_id( |\$)" "$REG" 2>/dev/null; then
          continue
        fi
        case " $CLEAN_IDS " in
          *" $child_id "*) ;;
          *) CLEAN_IDS="$CLEAN_IDS $child_id" ;;
        esac
      done < <(list_inflight_meta "$state_dir")
    done
  fi
  COUNT=0
  for state_dir in "${STATE_DIRS[@]}"; do
    for clean_id in $CLEAN_IDS; do
      for state_file in \
        "$state_dir/$clean_id.status" \
        "$state_dir/$clean_id.turn-ended" \
        "$state_dir/$clean_id.check.sh" \
        "$state_dir/$clean_id.meta" \
        "$state_dir/$clean_id.pi-ext.ts" \
        "$state_dir/$clean_id.heartbeat" \
        "$state_dir/$clean_id.grok-turnend-token"; do
        if [ -e "$state_file" ] || [ -L "$state_file" ]; then
          rm -f -- "$state_file"
          COUNT=$((COUNT + 1))
        fi
      done
    done
  done
  [ "$COUNT" -gt 0 ] && printf '  ✓ removed %d state file(s) for %s\n' "$COUNT" "$ID" || true
fi
if [ -f "$HOME_PATH/$SUB_HOME_MARKER" ]; then
  rm -f "$HOME_PATH/$SUB_HOME_MARKER"
  if [ "$KEEP_HOME" -eq 0 ]; then
    printf '  ✓ removed marker %s/%s\n' "$HOME_PATH" "$SUB_HOME_MARKER"
  else
    printf '  ✓ removed marker %s/%s (--keep-home: home retained)\n' "$HOME_PATH" "$SUB_HOME_MARKER"
  fi
fi

# 8. Optional: remove the on-disk home.
if [ "$KEEP_HOME" -eq 0 ]; then
  if [ "$LEASE_RETURNED" -eq 1 ]; then
    HOME_REMOVED=1
    HOME_DISPOSITION='returned to treehouse'
    printf '  ✓ returned home %s to treehouse\n' "$HOME_PATH"
  else
    rm -rf "$HOME_PATH"
    HOME_REMOVED=1
    HOME_DISPOSITION='removed'
    printf '  ✓ removed home %s\n' "$HOME_PATH"
  fi
fi

# 9. Summary.
printf '\nretired secondmate %s\n' "$ID"
if [ "$HOME_REMOVED" -eq 1 ]; then
  printf '  home:       %s (%s)\n' "$HOME_PATH" "$HOME_DISPOSITION"
else
  printf '  home:       %s (%s)\n' "$HOME_PATH" "$HOME_DISPOSITION"
fi
printf '  scope:      %s\n' "$SCOPE"
printf '  projects:   %s\n' "$PROJECTS_CSV"
[ "$FORCE" -eq 1 ] && printf '  forced:     yes (in-flight crewmate meta files discarded)\n' || true
exit 0
