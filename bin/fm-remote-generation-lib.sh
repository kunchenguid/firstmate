#!/usr/bin/env bash

fm_remote_generation_resolve() {
  local ledger active route response tmp line config data
  config=${CONFIG:-$FM_HOME/config}
  data=${DATA:-$FM_HOME/data}
  ledger=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" \
    "$SCRIPT_DIR/fm-fleet-seats.sh" show "$ID") || return 1
  active=$(printf '%s\n' "${ledger:-null}" | jq -c '[.incarnations[]? | select(.lifecycle == "reserved" or .lifecycle == "confirmed")]') || return 1
  if [ "$active" != '[]' ]; then
    route=$(printf '%s\n' "$active" | jq -ce --arg host "$(fm_meta_get "$META" remote_host)" \
      --arg root "$(fm_meta_get "$META" remote_root)" --arg home "$(fm_meta_get "$META" home)" '
      select(length == 1) | .[0] | select(.lifecycle == "confirmed" and .startup_confirmed == true
        and .route.placement == "remote" and .route.backend == "herdr"
        and .route.host == $host and .route.remote_root == $root and .route.home == $home
        and .route.spawn_gen == .generation and (.route.target | type == "string" and length > 0))') || {
      echo "error: remote generations are unresolved or do not match the registered route; preserving the host home" >&2
      return 1
    }
    FM_REMOTE_GENERATION=$(printf '%s\n' "$route" | jq -r .generation)
    FM_REMOTE_TARGET=$(printf '%s\n' "$route" | jq -r .route.target)
  else
    if ! response=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh route "$ID" </dev/null); then
      [ "${1:-}" = retire ] || return 1
      FM_REMOTE_GENERATION=$(fm_meta_get "$META" remote_spawn_gen)
      FM_REMOTE_TARGET=$(fm_meta_get "$META" remote_target)
      case "$FM_REMOTE_GENERATION" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      [ -n "$FM_REMOTE_TARGET" ] || return 1
      return 0
    fi
    [ "$(printf '%s\n' "$response" | sed -n 's/^schema=//p')" = fm-remote-secondmate-control.v1 ] \
      && [ "$(printf '%s\n' "$response" | sed -n 's/^backend=//p')" = herdr ] || return 1
    FM_REMOTE_GENERATION=$(printf '%s\n' "$response" | sed -n 's/^spawn_gen=//p')
    FM_REMOTE_TARGET=$(printf '%s\n' "$response" | sed -n 's/^target=//p')
  fi
  case "$FM_REMOTE_GENERATION" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -n "$FM_REMOTE_TARGET" ] || return 1
  if [ "$(sed -n 's/^remote_spawn_gen=//p' "$META")" = "$FM_REMOTE_GENERATION" ] &&
    [ "$(sed -n 's/^remote_target=//p' "$META")" = "$FM_REMOTE_TARGET" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.remote-generation-$ID.XXXXXX") || return 1
  {
    printf 'remote_spawn_gen=%s\nremote_target=%s\n' "$FM_REMOTE_GENERATION" "$FM_REMOTE_TARGET"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in remote_spawn_gen=*|remote_target=*) ;; *) printf '%s\n' "$line" ;; esac
    done < "$META"
  } > "$tmp" && mv -f -- "$tmp" "$META" && return 0
  rm -f -- "$tmp"
  return 1
}
