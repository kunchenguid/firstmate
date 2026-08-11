#!/usr/bin/env bash
# fm-accounts-lib.sh — per-operator multi-account registry.
#
# Reads config/accounts.json; resolves + validates accounts against the verified
# per-CLI config-dir / auth-isolation matrix in docs/fleet-addon.md.
#
# Three isolation methods (verified 2026-07-26):
#   config-dir-env   set <env>=<config_dir> for the child only (claude/codex/pi)
#   config-dir-flag  pass <flag> <config_dir> in argv           (cline)
#   api-key-env      set <env>=<key> for the child only         (grok/cursor-agent)
#
# Secrets never live here. api-key accounts store a key_file path (0600, in the
# operator's OWN home); fm-account-exec.sh reads the key for direct launches — it
# is never printed, never committed, never placed on argv.
#
# accounts.json schema (one entry per account name):
#   { "<name>": { "provider":"...", "harness":"...", "isolation":"...",
#                 "env":"<ENV>"|null, "flag":"<flag>"|null,
#                 "config_dir":"<path>"|null, "key_file":"<path>"|null,
#                 "scopes":["..."] } }

_FM_ACCOUNTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-home-boundary-lib.sh
. "$_FM_ACCOUNTS_LIB_DIR/fm-home-boundary-lib.sh"
unset _FM_ACCOUNTS_LIB_DIR

# Verified harness -> expected "<isolation>\t<env-or-flag>" (matrix source of truth).
fm_account_expect() { # harness
  case "$1" in
    claude)       printf 'config-dir-env\tCLAUDE_CONFIG_DIR\n' ;;
    codex)        printf 'config-dir-env\tCODEX_HOME\n' ;;
    pi)           printf 'config-dir-env\tPI_CODING_AGENT_DIR\n' ;;
    cline)        printf 'config-dir-flag\t--config\n' ;;
    grok)         printf 'api-key-env\tGROK_API_KEY\n' ;;
    cursor-agent) printf 'api-key-env\tCURSOR_API_KEY\n' ;;
    *) return 1 ;;
  esac
}

fm_accounts_file() {
  printf '%s\n' "${FM_ACCOUNTS_FILE:-${FM_HOME:-.}/config/accounts.json}"
}

# Refuse a path resolving into ANOTHER operator's home (cross-uid safety). Own
# home, /tmp, /opt are allowed. Empty path => allowed (method may not use one).
fm_account_assert_safe_path() { # path
  local p rp owner me; p=${1:-}
  [ -n "$p" ] && [ "$p" != "-" ] || return 0
  rp=$(fm_home_boundary_resolve "$p")
  me=$(id -un)
  owner=$(fm_home_boundary_private_owner "$rp" || true)
  if [ -n "$owner" ] && [ "$owner" != "$me" ]; then
    echo "fm-accounts: refusing foreign-home path: $rp" >&2
    return 1
  fi
  return 0
}

# resolve: print TSV harness<TAB>isolation<TAB>env<TAB>flag<TAB>config_dir<TAB>key_file
# missing fields -> "-". Exit 1 if the registry or account is absent.
fm_account_resolve() { # name
  local name=$1 f; f=$(fm_accounts_file)
  [ -f "$f" ] || { echo "fm-accounts: no registry at $f" >&2; return 1; }
  jq -e --arg n "$name" 'has($n)' "$f" >/dev/null 2>&1 \
    || { echo "fm-accounts: unknown account: $name" >&2; return 1; }
  jq -r --arg n "$name" '
    .[$n] | [
      (.harness // "-"), (.isolation // "-"),
      (.env // "-"), (.flag // "-"),
      (.config_dir // "-"), (.key_file // "-")
    ] | @tsv' "$f"
}

# validate: harness known; isolation matches the harness's expected method +
# env/flag; required method fields present; paths cross-uid-safe. Exit 0/1.
fm_account_validate() { # name
  local name=$1 line harness iso env flag cdir kfile exp exp_iso exp_ef
  line=$(fm_account_resolve "$name") || return 1
  IFS=$'\t' read -r harness iso env flag cdir kfile <<<"$line"
  exp=$(fm_account_expect "$harness") \
    || { echo "fm-accounts: unknown harness: $harness" >&2; return 1; }
  exp_iso=$(printf '%s' "$exp" | cut -f1)
  exp_ef=$(printf '%s' "$exp" | cut -f2)
  [ "$iso" = "$exp_iso" ] \
    || { echo "fm-accounts: $name isolation '$iso' != expected '$exp_iso' for $harness" >&2; return 1; }
  case "$iso" in
    config-dir-env)
      [ "$env" = "$exp_ef" ] || { echo "fm-accounts: $name env '$env' != '$exp_ef'" >&2; return 1; }
      [ "$cdir" != "-" ]     || { echo "fm-accounts: $name missing config_dir" >&2; return 1; }
      fm_account_assert_safe_path "$cdir" || return 1 ;;
    config-dir-flag)
      [ "$flag" = "$exp_ef" ] || { echo "fm-accounts: $name flag '$flag' != '$exp_ef'" >&2; return 1; }
      [ "$cdir" != "-" ]      || { echo "fm-accounts: $name missing config_dir" >&2; return 1; }
      fm_account_assert_safe_path "$cdir" || return 1 ;;
    api-key-env)
      [ "$env" = "$exp_ef" ] || { echo "fm-accounts: $name env '$env' != '$exp_ef'" >&2; return 1; }
      [ "$kfile" != "-" ]    || { echo "fm-accounts: $name missing key_file" >&2; return 1; }
      fm_account_assert_safe_path "$kfile" || return 1 ;;
    *) echo "fm-accounts: $name unknown isolation '$iso'" >&2; return 1 ;;
  esac
  return 0
}

fm_account_list() { # -> account names, one per line
  local f; f=$(fm_accounts_file); [ -f "$f" ] || return 0
  jq -r 'keys[]' "$f"
}

fm_account_list_by_harness() { # harness -> matching account names (file order)
  local h=$1 f; f=$(fm_accounts_file); [ -f "$f" ] || return 0
  jq -r --arg h "$h" 'to_entries[] | select(.value.harness==$h) | .key' "$f"
}

# --- quota-aware account selection (Phase 4, Task 12) -------------------------
#
# quota-axi reports headroom PER PROVIDER for the CURRENTLY-authenticated account
# (oauth/keychain) — it cannot see several accounts at once. So per-account
# headroom is obtained by running quota-axi UNDER each account's isolation (the
# same env/flag the spawn uses). The binding constraint for an account is the
# minimum percentRemaining across its windows. Pick the account with the most
# binding headroom; ties -> first registered. Guards: unsupported provider or
# quota-axi absent -> first registered (+ a note on stderr).

# harness -> quota-axi --provider value; nonzero if quota-axi has no coverage.
fm_account_quota_provider() { # harness
  case "$1" in
    claude) echo claude ;;
    codex)  echo codex ;;
    grok)   echo grok ;;
    cursor-agent) echo cursor ;;
    kimi)   echo kimi ;;
    *) return 1 ;;   # pi, cline: not covered by quota-axi
  esac
}

# Run quota-axi under one account's isolation; echo its min percentRemaining.
_fm_account_headroom() { # iso env cdir kfile qbin prov
  local iso=$1 env=$2 cdir=$3 kfile=$4 qbin=$5 prov=$6 out key
  case "$iso" in
    config-dir-env)  out=$(env "$env=$cdir" "$qbin" --provider "$prov" --json 2>/dev/null) ;;
    # The isolation is a flag on the HARNESS's own argv; quota-axi has no equivalent,
    # so there is no way to point it at this account. Report nothing rather than the
    # currently-authed account's headroom, which would make every flag-isolated
    # account of a harness look identical and turn fm_account_pick into a coin flip.
    config-dir-flag) return 0 ;;
    api-key-env)
      [ -r "$kfile" ] || return 0
      key=$(head -n1 "$kfile"); [ -n "$key" ] || return 0
      out=$(export "$env=$key"; "$qbin" --provider "$prov" --json 2>/dev/null) ;;
    *) return 0 ;;
  esac
  printf '%s' "$out" | jq -r --arg p "$prov" '
    [.providers[] | select(.provider==$p) | .windows[].percentRemaining] | min // empty' 2>/dev/null
}

# fm_account_pick(harness) -> the registered account with the most headroom.
fm_account_pick() { # harness
  local harness=$1 prov qbin best="" best_hr=-1 acct hr line _h iso env flag cdir kfile
  local -a accts
  mapfile -t accts < <(fm_account_list_by_harness "$harness")
  [ "${#accts[@]}" -gt 0 ] || { echo "fm-account: no accounts for harness '$harness'" >&2; return 1; }
  if [ "${#accts[@]}" -eq 1 ]; then printf '%s\n' "${accts[0]}"; return 0; fi
  prov=$(fm_account_quota_provider "$harness") \
    || { printf '%s\n' "${accts[0]}"; echo "fm-account: no quota provider for '$harness'; picked first (${accts[0]})" >&2; return 0; }
  qbin="${QUOTA_AXI_BIN:-quota-axi}"
  command -v "$qbin" >/dev/null 2>&1 \
    || { printf '%s\n' "${accts[0]}"; echo "fm-account: quota-axi absent; picked first (${accts[0]})" >&2; return 0; }
  for acct in "${accts[@]}"; do
    line=$(fm_account_resolve "$acct") || continue
    IFS=$'\t' read -r _h iso env flag cdir kfile <<<"$line"
    hr=$(_fm_account_headroom "$iso" "$env" "$cdir" "$kfile" "$qbin" "$prov")
    [ -n "$hr" ] || hr=-1
    if awk -v a="$hr" -v b="$best_hr" 'BEGIN{exit !((a+0)>(b+0))}'; then best_hr=$hr; best=$acct; fi
  done
  [ -n "$best" ] && printf '%s\n' "$best" || printf '%s\n' "${accts[0]}"
}
