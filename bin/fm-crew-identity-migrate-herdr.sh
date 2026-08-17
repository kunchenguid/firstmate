#!/usr/bin/env bash
# Safely migrate current Herdr Space titles and legacy active metadata to the
# optional crew-identity layer.
#
# Usage: fm-crew-identity-migrate-herdr.sh [<herdr-session>]
#
# Run this from the lock-owning primary Firstmate session while that primary is
# inside its own Herdr Space. The exact launcher workspace becomes the primary
# migration target. Persistent secondmates and projected task Spaces are read
# only from this home's state/*.meta and exact presentation journals. Every
# rename uses a recorded workspace id and accepts only the exact expected legacy
# title; labels are never selectors. Existing crew metadata is never replaced.
#
# The command captures configured identities into active metadata that predates
# the feature, then renames safe exact bindings. It refuses duplicate identities,
# incomplete metadata, an ambiguous launcher, or a changed Space. It does not
# stop, restart, or otherwise drive any agent lifecycle.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SESSION=${1:-${HERDR_SESSION:-}}

[ -n "$SESSION" ] || {
  echo "error: pass the exact Herdr session or set HERDR_SESSION" >&2
  exit 2
}
[ "$#" -le 1 ] || {
  echo "usage: fm-crew-identity-migrate-herdr.sh [<herdr-session>]" >&2
  exit 2
}

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_backend_source herdr || exit 1

export FM_CREW_IDENTITY_CONFIG="$CONFIG/crew-identities.json"
fm_crew_identity_config_present || {
  echo "error: config/crew-identities.json is absent; there is no identity migration to apply" >&2
  exit 1
}
fm_crew_identity_validate_config || exit 1
ROSTER=$(fm_crew_identity_config_roster) || exit 1

if [ "${FM_CREW_IDENTITY_MIGRATION_SKIP_SESSION_LOCK:-0}" != 1 ] \
   && ! fm_session_lock_owned_by_self "$STATE"; then
  echo "error: crew identity migration must run from the session that owns this home's fleet lock" >&2
  exit 1
fi

ORDER_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$SESSION") || {
  echo "error: could not resolve the exact presentation lock for Herdr session '$SESSION'" >&2
  exit 1
}
fm_lock_try_acquire "$ORDER_LOCK" || {
  echo "error: Herdr presentation changes are already in progress for session '$SESSION'" >&2
  exit 1
}
LOCK_HELD=1
cleanup() {
  if [ "${LOCK_HELD:-0}" = 1 ]; then
    LOCK_HELD=0
    fm_lock_release "$ORDER_LOCK" || true
  fi
}
trap cleanup EXIT

fm_backend_herdr_launcher_identity "$SESSION" || {
  echo "error: current Herdr launcher ancestry does not identify one exact primary Space in session '$SESSION'" >&2
  exit 1
}
FM_CREW_IDENTITY_CONFIG_OVERRIDE="$CONFIG/crew-identities.json" \
  FM_HOME="$FM_HOME" fm_backend_herdr_workspace_identity_rename_exact \
    "$SESSION" "$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID" || {
      echo "error: could not safely migrate the primary Herdr Space title" >&2
      exit 1
    }

capture_identity_metadata() { # <meta> <task-id> <identity>
  local meta=$1 id=$2 identity=$3 lock tmp
  if grep -qE '^(crew_roster|crew_identity)=' "$meta" 2>/dev/null; then
    [ "$(awk -F= '$1 == "crew_roster" {n++} END {print n+0}' "$meta")" -eq 1 ] \
      && [ "$(awk -F= '$1 == "crew_identity" {n++} END {print n+0}' "$meta")" -eq 1 ] \
      && [ "$(fm_meta_get "$meta" crew_roster)" = "$ROSTER" ] \
      && [ "$(fm_meta_get "$meta" crew_identity)" = "$identity" ] || {
        echo "error: active task '$id' already has different or incomplete crew identity metadata" >&2
        return 1
      }
    return 0
  fi
  fm_crew_identity_check_active "$id" "$ROSTER" "$identity" "$STATE" || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_try_acquire "$lock" || {
    echo "error: task '$id' metadata is busy; refusing identity migration" >&2
    return 1
  }
  if grep -qE '^(crew_roster|crew_identity)=' "$meta" 2>/dev/null; then
    fm_lock_release "$lock" || true
    echo "error: task '$id' identity metadata changed during migration" >&2
    return 1
  fi
  tmp=$(mktemp "$STATE/.${id}.identity-meta.XXXXXX") || {
    fm_lock_release "$lock" || true
    return 1
  }
  chmod 0600 "$tmp" || {
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    return 1
  }
  if ! { sed '/^$/d' "$meta"; printf 'crew_roster=%s\ncrew_identity=%s\n' "$ROSTER" "$identity"; } > "$tmp" \
     || ! mv -f "$tmp" "$meta"; then
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  fm_lock_release "$lock" || return 1
}

MIGRATED=1
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  identity=$(fm_crew_identity_assignment agent "$id") || exit 1
  [ "$identity" != unassigned ] || continue
  capture_identity_metadata "$meta" "$id" "$identity" || exit 1
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = herdr ] || continue
  task_session=$(fm_meta_get "$meta" herdr_session)
  [ "$task_session" = "$SESSION" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  workspace=$(fm_meta_get "$meta" herdr_workspace_id)
  [ -n "$workspace" ] || {
    echo "error: Herdr task '$id' has no exact workspace id" >&2
    exit 1
  }
  if [ "$kind" = secondmate ]; then
    home=$(fm_meta_get "$meta" home)
    [ -d "$home" ] || {
      echo "error: secondmate '$id' has no readable home for identity migration" >&2
      exit 1
    }
    FM_CREW_IDENTITY_CONFIG_OVERRIDE="$CONFIG/crew-identities.json" \
      FM_HOME="$home" fm_backend_herdr_workspace_identity_rename_exact \
        "$SESSION" "$workspace" || {
          echo "error: could not safely migrate secondmate '$id' Herdr Space title" >&2
          exit 1
        }
    MIGRATED=$((MIGRATED + 1))
  else
    journal="$STATE/$id$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
    [ -e "$journal" ] || continue
    fm_backend_herdr_projection_identity_rename_exact \
      "$SESSION" "$journal" "$id" "$ROSTER" "$identity" || {
        echo "error: could not safely migrate projected Herdr Space for '$id'" >&2
        exit 1
      }
    MIGRATED=$((MIGRATED + 1))
  fi
done

printf 'migrated %s exact Herdr Space title(s) to configured crew identities\n' "$MIGRATED"
