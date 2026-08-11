#!/usr/bin/env bash
# fm-account-env.sh — apply a registered account's auth isolation (Phase 4).
#
# Consumes fm-accounts-lib.sh. Two consumers, two mechanisms:
#
#   * fm-spawn-acct.sh (SUPERVISED paned spawns) -> fm_account_prepare_supervised_spawn
#     Exports nonsecret account isolation for fm-spawn's canonical launch
#     template. config-dir methods only: an env PREFIX for a config dir is not a
#     secret, but an api-key on argv WOULD be — so api-key accounts are refused
#     here and routed to the exec shim.
#
#   * fm-account-exec.sh / direct launches -> fm_account_apply_env
#     Exports the isolation env in THIS process (incl. api-key read from key_file),
#     then the caller execs the CLI. The secret lands only in the child's env,
#     never on argv, never in a log.

_fm_acct_lib() { # source fm-accounts-lib.sh once
  [ -n "${_FM_ACCT_LIB_LOADED:-}" ] && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-accounts-lib.sh disable=SC1091
  . "$d/fm-accounts-lib.sh"
  _FM_ACCT_LIB_LOADED=1
}

fm_account_prepare_supervised_spawn() { # name
  _fm_acct_lib
  local name=$1 line harness iso env flag cdir kfile
  unset FM_SPAWN_ACCOUNT_ENV_NAME FM_SPAWN_ACCOUNT_ENV_VALUE
  unset FM_SPAWN_ACCOUNT_ARGV_FLAG FM_SPAWN_ACCOUNT_ARGV_VALUE
  FM_ACCOUNT_SUPERVISED_HARNESS=
  fm_account_validate "$name" || return 1
  line=$(fm_account_resolve "$name")
  IFS=$'\t' read -r harness iso env flag cdir kfile <<<"$line"
  case "$iso" in
    config-dir-env)
      export FM_SPAWN_ACCOUNT_ENV_NAME=$env
      export FM_SPAWN_ACCOUNT_ENV_VALUE=$cdir
      ;;
    config-dir-flag)
      export FM_SPAWN_ACCOUNT_ARGV_FLAG=$flag
      export FM_SPAWN_ACCOUNT_ARGV_VALUE=$cdir
      ;;
    api-key-env)
      echo "fm-account: '$name' uses api-key isolation; a supervised spawn would put the key on argv. Use fm-account-exec.sh for a direct launch." >&2
      return 2 ;;
    *) echo "fm-account: $name unknown isolation '$iso'" >&2; return 1 ;;
  esac
  # shellcheck disable=SC2034
  FM_ACCOUNT_SUPERVISED_HARNESS=$harness
}

# Apply isolation to THIS process's environment (direct/exec launches).
# MUST be called directly (NOT inside $(...)) so the exports land in the caller's
# shell rather than a dead subshell. config-dir-env / api-key-env export the env;
# config-dir-flag sets FM_ACCT_ARGV_SUFFIX_ARGS to the flag/dir pair for the
# caller to splice into argv (a flag cannot be an env). api-key reads key_file (0600,
# own home); the key is exported, never echoed.
fm_account_apply_env() { # name  -> exports env; sets FM_ACCT_ARGV_SUFFIX_ARGS
  _fm_acct_lib
  local name=$1 line harness iso env flag cdir kfile key
  FM_ACCT_ARGV_SUFFIX=""
  FM_ACCT_ARGV_SUFFIX_ARGS=()
  fm_account_validate "$name" || return 1
  line=$(fm_account_resolve "$name")
  IFS=$'\t' read -r harness iso env flag cdir kfile <<<"$line"
  # shellcheck disable=SC2034 # FM_ACCT_ARGV_SUFFIX is read by callers (fm-account-exec.sh) after sourcing.
  case "$iso" in
    config-dir-env)  export "$env=$cdir" ;;
    config-dir-flag) FM_ACCT_ARGV_SUFFIX="$flag $cdir"; FM_ACCT_ARGV_SUFFIX_ARGS=("$flag" "$cdir") ;;
    api-key-env)
      [ -r "$kfile" ] || { echo "fm-account: key_file unreadable: $kfile" >&2; return 1; }
      key=$(head -n1 "$kfile"); [ -n "$key" ] || { echo "fm-account: key_file empty: $kfile" >&2; return 1; }
      export "$env=$key" ;;
    *) echo "fm-account: $name unknown isolation '$iso'" >&2; return 1 ;;
  esac
}
