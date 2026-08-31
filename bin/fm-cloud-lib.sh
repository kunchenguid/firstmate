#!/usr/bin/env bash
# fm-cloud-lib.sh - shared cloud-kick bridge paths, hashing, and acceptance.
#
# Source this library; it is not a CLI entrypoint.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CLOUD_KICK_FILE="$STATE/cloud-kick.md"
CLOUD_DONE_FILE="$STATE/cloud-kick.done"
CLOUD_BERICHT_FILE="$STATE/cloud-bericht.md"
CLOUD_BRUECKE_ENV="$STATE/bruecke.env"

fm_cloud_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_cloud_bruecke_configured() {
  [ -r "$CLOUD_BRUECKE_ENV" ]
}

fm_cloud_load_bruecke() {
  # shellcheck disable=SC1090
  . "$CLOUD_BRUECKE_ENV"
}

fm_cloud_kick_hash() {
  local hash
  [ -s "$CLOUD_KICK_FILE" ] || return 1
  hash=$(fm_cloud_sha256 "$CLOUD_KICK_FILE") || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

fm_cloud_done_hash() {
  local hash
  [ -r "$CLOUD_DONE_FILE" ] || return 1
  hash=$(tr -d '[:space:]' < "$CLOUD_DONE_FILE")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

fm_cloud_kick_is_new() {
  local kick done
  kick=$(fm_cloud_kick_hash) || return 1
  done=$(fm_cloud_done_hash) || return 0
  [ "$kick" != "$done" ]
}

fm_cloud_mark_done() {
  local hash
  hash=$(fm_cloud_kick_hash) || return 1
  printf '%s\n' "$hash" > "$CLOUD_DONE_FILE"
}

fm_cloud_annahme_try() {
  local hash summary lib="$FM_ROOT/bin/fm-wake-lib.sh"
  fm_cloud_bruecke_configured || return 0
  fm_cloud_kick_is_new || return 0
  hash=$(fm_cloud_kick_hash) || return 1
  summary=$(head -n 1 "$CLOUD_KICK_FILE" | tr '\n\t' '  ' | cut -c1-80)
  [ -n "${summary//[[:space:]]/}" ] || summary='neuer Cloud-Kick'
  [ -r "$lib" ] || {
    printf 'fm-cloud: kick gespeichert aber Wake fehlgeschlagen (fehlendes %s)\n' "$lib" >&2
    return 1
  }
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  fm_wake_append check cloud-kick "check: cloud-kick neu - $summary" || return 1
  fm_cloud_mark_done || return 1
  printf 'cloud-kick angenommen\n'
}
