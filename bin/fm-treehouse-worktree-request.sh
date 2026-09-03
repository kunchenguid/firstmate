#!/usr/bin/env sh
# This owner is both executed by spawn and sourced when callers need its final cwd.
# shellcheck disable=SC2317
# Internal owner of one durable Treehouse lease request for fm-spawn.sh.
#
# The caller supplies an unused absolute private marker directory and a validated
# lease-holder token. This process publishes owner and result records around the
# one `treehouse get --lease` side effect so an interrupted parent can reconcile
# the exact lease before deciding whether any retry is safe. Ambiguous allocation
# is retained for caller reconciliation instead of issuing another request.
# Usage: fm-treehouse-worktree-request.sh <absolute-marker-dir> <lease-holder>

fm_treehouse_request_marker=${1:-}
fm_treehouse_request_holder=${2:-}
case "$fm_treehouse_request_marker" in /*) ;; *) return 1 2>/dev/null || exit 1 ;; esac
case "$fm_treehouse_request_holder" in ''|*[!A-Za-z0-9._:-]*) return 1 2>/dev/null || exit 1 ;; esac

fm_treehouse_request_result="$fm_treehouse_request_marker/result"
fm_treehouse_request_result_tmp="$fm_treehouse_request_marker/.result.tmp"
fm_treehouse_request_owner="$fm_treehouse_request_marker/owner"
fm_treehouse_request_owner_tmp="$fm_treehouse_request_marker/.owner.tmp"
fm_treehouse_request_get_out=
fm_treehouse_request_get_rc=0
fm_treehouse_request_path=
fm_treehouse_request_leases='[]'
fm_treehouse_request_status_out=
fm_treehouse_request_status_rc=0

fm_treehouse_request_publish() {
  fm_treehouse_request_publish_status=$1
  fm_treehouse_request_publish_rc=$2
  fm_treehouse_request_publish_path=${3:-}
  fm_treehouse_request_publish_leases=$4
  jq -n -S -c \
    --arg schema fm-spawn-worktree-result.v1 \
    --arg status "$fm_treehouse_request_publish_status" \
    --argjson exit_status "$fm_treehouse_request_publish_rc" \
    --arg path "$fm_treehouse_request_publish_path" \
    --arg lease_holder "$fm_treehouse_request_holder" \
    --argjson leases "$fm_treehouse_request_publish_leases" \
    '{schema:$schema,status:$status,exit_status:$exit_status,
      path:(if $path == "" then null else $path end),
      lease_holder:$lease_holder,leases:$leases}' \
    > "$fm_treehouse_request_result_tmp" \
    && chmod 600 "$fm_treehouse_request_result_tmp" \
    && mv -- "$fm_treehouse_request_result_tmp" "$fm_treehouse_request_result"
}

fm_treehouse_request_retryable() {
  fm_treehouse_request_publish retryable "$1" '' '[]'
}

fm_treehouse_request_ambiguous() {
  fm_treehouse_request_publish ambiguous "$1" '' "$2"
}

fm_treehouse_request_adopt_or_compensate() {
  fm_treehouse_request_path=$1
  fm_treehouse_request_leases=$2
  if cd -- "$fm_treehouse_request_path"; then
    fm_treehouse_request_publish ok "$fm_treehouse_request_get_rc" \
      "$(pwd -P)" "$fm_treehouse_request_leases"
    return $?
  fi
  if treehouse return --force --if-lease-holder "$fm_treehouse_request_holder" \
      "$fm_treehouse_request_path"; then
    fm_treehouse_request_retryable "$fm_treehouse_request_get_rc"
    return $?
  fi
  fm_treehouse_request_ambiguous "$fm_treehouse_request_get_rc" \
    "$fm_treehouse_request_leases"
}

umask 077
if ! mkdir -m 700 -- "$fm_treehouse_request_marker"; then
  unset -f fm_treehouse_request_publish fm_treehouse_request_retryable \
    fm_treehouse_request_ambiguous fm_treehouse_request_adopt_or_compensate 2>/dev/null || true
  return 1 2>/dev/null || exit 1
fi
if ! printf '%s\n' "$$" > "$fm_treehouse_request_owner_tmp" \
  || ! chmod 600 "$fm_treehouse_request_owner_tmp" \
  || ! mv -- "$fm_treehouse_request_owner_tmp" "$fm_treehouse_request_owner"; then
  unset -f fm_treehouse_request_publish fm_treehouse_request_retryable \
    fm_treehouse_request_ambiguous fm_treehouse_request_adopt_or_compensate 2>/dev/null || true
  return 1 2>/dev/null || exit 1
fi

fm_treehouse_request_get_out=$(treehouse get --lease \
  --lease-holder "$fm_treehouse_request_holder") || fm_treehouse_request_get_rc=$?
if [ "$fm_treehouse_request_get_rc" -eq 0 ]; then
  case "$fm_treehouse_request_get_out" in
    /*)
      case "$fm_treehouse_request_get_out" in
        *'
'*) ;;
        *)
          fm_treehouse_request_leases=$(jq -n -S -c \
            --arg path "$fm_treehouse_request_get_out" \
            '[{path:$path,lease_id:null}]') || fm_treehouse_request_leases='[]'
          fm_treehouse_request_adopt_or_compensate \
            "$fm_treehouse_request_get_out" "$fm_treehouse_request_leases"
          fm_treehouse_request_done=$?
          unset -f fm_treehouse_request_publish fm_treehouse_request_retryable \
            fm_treehouse_request_ambiguous fm_treehouse_request_adopt_or_compensate 2>/dev/null || true
          return "$fm_treehouse_request_done" 2>/dev/null || exit "$fm_treehouse_request_done"
          ;;
      esac
      ;;
  esac
fi

fm_treehouse_request_status_out=$(treehouse status --json 2>/dev/null) \
  || fm_treehouse_request_status_rc=$?
if [ "$fm_treehouse_request_status_rc" -eq 0 ]; then
  fm_treehouse_request_leases=$(printf '%s' "$fm_treehouse_request_status_out" \
    | jq -e -S -c --arg holder "$fm_treehouse_request_holder" '
        if type != "array" then error("status is not an array") else
          [.[] | select(
              .leased == true and .lease_holder == $holder
              and (.path | type == "string" and startswith("/"))
              and (.lease_id | type == "string" and length > 0))
            | {path:.path,lease_id:.lease_id}]
          | unique_by([.path,.lease_id])
        end
      ' 2>/dev/null) || fm_treehouse_request_status_rc=1
fi
if [ "$fm_treehouse_request_status_rc" -eq 0 ]; then
  fm_treehouse_request_lease_count=$(printf '%s' "$fm_treehouse_request_leases" \
    | jq -r 'length') || fm_treehouse_request_lease_count=-1
  case "$fm_treehouse_request_lease_count" in
    0) fm_treehouse_request_retryable "$fm_treehouse_request_get_rc" ;;
    1)
      fm_treehouse_request_path=$(printf '%s' "$fm_treehouse_request_leases" \
        | jq -er '.[0].path') || fm_treehouse_request_path=
      if [ -n "$fm_treehouse_request_path" ]; then
        fm_treehouse_request_adopt_or_compensate \
          "$fm_treehouse_request_path" "$fm_treehouse_request_leases"
      else
        fm_treehouse_request_ambiguous "$fm_treehouse_request_get_rc" '[]'
      fi
      ;;
    *) fm_treehouse_request_ambiguous "$fm_treehouse_request_get_rc" \
         "$fm_treehouse_request_leases" ;;
  esac
  fm_treehouse_request_done=$?
else
  case "$fm_treehouse_request_get_out" in
    /*)
      case "$fm_treehouse_request_get_out" in
        *'
'*) fm_treehouse_request_leases='[]' ;;
        *) fm_treehouse_request_leases=$(jq -n -S -c \
             --arg path "$fm_treehouse_request_get_out" \
             '[{path:$path,lease_id:null}]') || fm_treehouse_request_leases='[]' ;;
      esac
      ;;
    *) fm_treehouse_request_leases='[]' ;;
  esac
  fm_treehouse_request_ambiguous "$fm_treehouse_request_get_rc" \
    "$fm_treehouse_request_leases"
  fm_treehouse_request_done=$?
fi

unset -f fm_treehouse_request_publish fm_treehouse_request_retryable \
  fm_treehouse_request_ambiguous fm_treehouse_request_adopt_or_compensate 2>/dev/null || true
return "$fm_treehouse_request_done" 2>/dev/null || exit "$fm_treehouse_request_done"
