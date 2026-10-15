#!/usr/bin/env bash
# fm-account-pool-lib.sh - the account-pool spawn hook: config/account-pool
# parsing, the harness-to-tool map, the `byokit-accounts pick` invocation, and
# the launch prefix its answer applies. Sourced by bin/fm-spawn.sh and by
# bin/fm-control.sh, whose relaunch preflight resolves the pool before it stops
# the running agent.
#
# docs/configuration.md "Worker account pool (config/account-pool)" owns the
# operator-facing contract. A pick answers with folder paths only, so no key,
# token, or login file can reach a launch line, a task record, or a log.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_POOL_PICK_SECONDS=${FM_ACCOUNT_POOL_PICK_SECONDS:-120}

# fm_account_pool_tool <harness>: the pool tool, or non-zero for an unmapped one.
fm_account_pool_tool() {
  case "$1" in
  claude) printf '%s\n' claude ;;
  codex) printf '%s\n' codex ;;
  pi | pi-signed) printf '%s\n' pi ;;
  *) return 1 ;;
  esac
}

# fm_account_pool_store_var <tool>: the environment variable a launch assigns
# the picked account folder to, or non-zero for an unmapped tool.
fm_account_pool_store_var() {
  case "$1" in
  claude) printf '%s\n' CLAUDE_CONFIG_DIR ;;
  codex) printf '%s\n' CODEX_HOME ;;
  pi) printf '%s\n' PI_CODING_AGENT_DIR ;;
  *) return 1 ;;
  esac
}

# fm_account_pool_config <config-dir>: "command<TAB>state" for a usable
# config/account-pool; nothing when the file is absent; one error otherwise.
fm_account_pool_config() {
  local config=$1 file command state line
  file=$config/account-pool
  command=byokit-accounts
  state=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/account-pool must be a readable regular file naming the pool folder: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
    command=*) command=${line#command=} ;;
    state=*) state=${line#state=} ;;
    esac
  done <"$file"
  case "$state" in
  /*) ;;
  *)
    echo "error: config/account-pool must name the pool folder with one absolute state=<pool folder> line (blank lines and # comments are ignored): $file" >&2
    return 1
    ;;
  esac
  case "$command" in
  /*) ;;
  */*)
    echo "error: config/account-pool's command= must be an absolute path to byokit-accounts: $file" >&2
    return 1
    ;;
  esac
  printf '%s\t%s\n' "$command" "$state"
}

# fm_account_pool_detail <pick-json>: one fragment naming each account row and
# why it cannot take a worker. Reads names and states only.
fm_account_pool_detail() {
  jq -r '[ .rows[]? | select(type == "object") | "\(.name // .id // "an account") " +
    (if .state == "resting" then "resting" elif .state == "signed_out" then "signed out"
     elif .state == "signing" then "still signing in" elif .state == "not_included" then "not set up"
     else "not ready" end) ] | join(", ")' <<<"${1:-}" 2>/dev/null
}

# fm_account_pool_select <harness> <config-dir>: "id<TAB>var<TAB>folder<TAB>
# unset names" for a mapped harness with a usable pool; nothing when the pool
# is off; one error and non-zero on any refusal, never an ambient login fallback.
# fm-spawn.sh refuses raw launch commands before calling this named-harness hook.
fm_account_pool_select() {
  local harness=$1 config=$2 tool store_var cfg command state out errf rc id var folder shed reason detail shed_bad=0
  tool=$(fm_account_pool_tool "$harness") || return 0
  cfg=$(fm_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || return 0
  store_var=$(fm_account_pool_store_var "$tool") || return 1
  command=${cfg%%$'\t'*}
  state=${cfg#*$'\t'}
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  out=$(fm_run_timed "$FM_ACCOUNT_POOL_PICK_SECONDS" "$command" pick "$tool" --json --state "$state" 2>"$errf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # A failed pick answers with the contract JSON on stdout and one sentence on stderr.
    reason=
    if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then
      reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
      detail=$(fm_account_pool_detail "$out")
    fi
    [ -n "$reason" ] || reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot start a $tool worker: $reason${detail:+ ($detail)}; add or sign in to an account with '$command add $tool', then retry" >&2
    return 1
  fi
  rm -f "$errf"
  id=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  var=$(printf '%s' "$out" | jq -r 'if (.set | type) == "object" and (.set | length) == 1 then (.set | keys[0]) else empty end' 2>/dev/null)
  folder=$(printf '%s' "$out" | jq -r --arg v "$var" 'if $v == "" then empty else (.set[$v] // empty) end' 2>/dev/null)
  if ! shed=$(printf '%s' "$out" | jq -r '
      .unset // []
      | if type == "array" and all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*\\z"))
        then .[] else error("the unset list is not an array of variable names") end' 2>/dev/null); then
    shed=
    shed_bad=1
  fi
  shed=$(printf '%s' "$shed" | tr '\n' ' ')
  shed=${shed% }
  case "$id" in '' | *[!A-Za-z0-9._-]*) id= ;; esac
  case "$var" in "$store_var") ;; *) var= ;; esac
  case "$folder" in /*) ;; *) folder= ;; esac
  if [ -n "$folder" ] && { [ ! -d "$folder" ] || [ ! -r "$folder" ] || [ ! -x "$folder" ]; }; then
    folder=
  fi
  if [ -z "$id" ] || [ -z "$var" ] || [ -z "$folder" ] || [ "$shed_bad" = 1 ]; then
    echo "error: config/account-pool's '$command' answered with an unusable $tool account selection; expected an account id and one absolute account folder, with no secret" >&2
    return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "$var" "$folder" "$shed"
}
