#!/usr/bin/env bash
# fm-account-pool-lib.sh - the account-pool spawn hook: config/account-pool
# parsing, the harness-to-tool map, the `byokit-accounts pick` invocation, and
# the launch prefix its answer applies. Sourced by bin/fm-spawn.sh and by
# bin/fm-control.sh, whose relaunch preflight resolves the pool before it stops
# the running agent and whose --account <id|next> moves the worker between
# accounts through the same lines.
#
# docs/configuration.md "Worker account pool (config/account-pool)" owns the
# operator-facing contract. A pick answers with folder paths only, so no key,
# token, or login file can reach a launch line, a task record, or a log.
#
# A relaunch-side hook lives here too: the choice validation, the recorded
# account's tool read, its rest, the plan's fixed automatic-move rule, and the
# pre-stop gate that ties them together. The mutation (a rest) is owned by this
# relaunch path alone; a pick is always a read.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_POOL_PICK_SECONDS=${FM_ACCOUNT_POOL_PICK_SECONDS:-120}
FM_ACCOUNT_POOL_REST_SECONDS=${FM_ACCOUNT_POOL_REST_SECONDS:-60}

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

# fm_account_pool_want_valid <choice>: 0 when a relaunch --account value is
# `next` or one account id the pool command can name: letters, digits, dot,
# dash, and underscore, no longer than a roster id. Anything else - an empty
# value, a path, a flag - is malformed, and this home refuses it itself rather
# than handing it to the pool command.
fm_account_pool_want_valid() {
  case "${1:-}" in
    next) return 0 ;;
    -*) return 1 ;;
    *[!A-Za-z0-9._-]* | '') return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# fm_account_pool_select <harness> <config-dir> [<want>]: "id<TAB>var<TAB>folder<TAB>
# unset names" for a mapped harness with a usable pool; nothing when the pool
# is off; one error and non-zero on any refusal, never an ambient login fallback.
# fm-spawn.sh refuses raw launch commands before calling this named-harness hook.
# <want> is the relaunch verb's --account choice: an account id adds --prefer
# to the pick and the answer must be exactly that account, so an account that
# is resting, signed out, or another tool's refuses instead of silently
# launching a different one; `next` picks plainly, because the relaunch verb
# has already rested the recorded account.
fm_account_pool_select() {
  local harness=$1 config=$2 want=${3:-} tool store_var cfg command state out errf rc id var folder shed reason detail shed_bad=0
  local -a prefer_arg=()
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
  case "$want" in
    '' | next) ;;
    *) prefer_arg=(--prefer "$want") ;;
  esac
  out=$(fm_run_timed "$FM_ACCOUNT_POOL_PICK_SECONDS" "$command" pick "$tool" --json "${prefer_arg[@]}" --state "$state" 2>"$errf")
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
  case "$want" in
    '' | next) ;;
    *)
      if [ "$id" != "$want" ]; then
        echo "error: config/account-pool's '$command' answered with account '${id:-none}' rather than the requested account '$want' for a $tool worker; the pool only prefers an account that is ready, so '$want' may be resting, signed out, or another tool's account" >&2
        return 1
      fi
      ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$id" "$var" "$folder" "$shed"
}

# fm_account_pool_recorded_tool <command> <state> <id>: the pool tool of the
# account a running worker launched on, read from the pool command's own
# roster. One error and non-zero when the pool cannot answer, so a relaunch
# refuses instead of guessing which kind of account it is being asked to move.
fm_account_pool_recorded_tool() {
  local command=$1 state=$2 id=$3 out errf rc tool reason
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  out=$(fm_run_timed "$FM_ACCOUNT_POOL_PICK_SECONDS" "$command" status "$id" --json --state "$state" 2>"$errf")
  rc=$?
  tool=$(printf '%s' "$out" | jq -r '.tool // empty' 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$tool" ]; then
    reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot read the running worker's account $id: $reason" >&2
    return 1
  fi
  rm -f "$errf"
  printf '%s\n' "$tool"
}

# fm_account_pool_rest <command> <state> <id>: rest one pool account so the
# next pick moves off it. The account's own default rest applies, and the
# operator returns it with '<command> unrest <id>'. One error and non-zero on
# refusal; the relaunch verb runs this before the old agent stops, so a
# refused rest leaves the running worker untouched.
fm_account_pool_rest() {
  local command=$1 state=$2 id=$3 errf rc reason
  errf=$(mktemp "${TMPDIR:-/tmp}/fm-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  fm_run_timed "$FM_ACCOUNT_POOL_REST_SECONDS" "$command" rest "$id" --json --state "$state" >/dev/null 2>"$errf"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot rest account $id: $reason; it stays on the pick's list until it rests" >&2
    return 1
  fi
  rm -f "$errf"
}

# The tools a relaunch may move a worker between automatically, fixed in code
# from the account-pool plan's terms review (plan v2 section 3): Claude,
# Codex, and Pi subscription logins allow it; OpenCode Go does not, so an
# automatic move refuses a Go account, a worker that runs on an opencode-go
# provider, and a replacement that would run one. Deliberately not a config
# value.
FM_ACCOUNT_POOL_AUTO_TOOLS="claude codex pi"

# fm_account_pool_next_ok <tool> <from-model> <to-model> <task-id>: 0 when
# this relaunch may move the worker automatically; otherwise one plain error
# naming the manual command, and 1.
fm_account_pool_next_ok() {
  local tool=$1 from_model=$2 to_model=$3 task=$4
  case " $FM_ACCOUNT_POOL_AUTO_TOOLS " in
    *" $tool "*) ;;
    *)
      echo "error: '--account next' cannot move an account of tool '$tool' automatically; move this worker by hand with 'bin/fm-control.sh $task relaunch --account <id>'" >&2
      return 1
      ;;
  esac
  case "$from_model$to_model" in
    *opencode-go*)
      echo "error: '--account next' cannot move a worker on the opencode-go provider automatically; move this worker by hand with 'bin/fm-control.sh $task relaunch --account <id>'" >&2
      return 1
      ;;
  esac
  return 0
}

# fm_account_pool_relaunch_pre <harness> <config-dir> <choice> <recorded-id>
#   <model> <task-id>: the relaunch-time account gate's read-only half. Every
#   refusal the verb can reach without touching the pool happens here, while
#   nothing has changed: a malformed choice, an unmapped harness, no pool, a
#   missing or unreadable recorded account, or an account the plan forbids
#   moving automatically. The rest and the pick that prove the move run in
#   fm_account_pool_relaunch_commit, which the caller takes last, after every
#   cheaper refusal has passed.
fm_account_pool_relaunch_pre() {
  local harness=$1 config=$2 choice=$3 recorded=$4 from_model=$5 to_model=$6 task=$7 cfg command state recorded_tool
  fm_account_pool_want_valid "$choice" || {
    echo "error: --account takes 'next' or one account id, not '$choice'" >&2
    return 1
  }
  fm_account_pool_tool "$harness" >/dev/null || {
    echo "error: --account applies to the harnesses whose pool tool exists (claude, codex, pi, pi-signed), not '$harness'" >&2
    return 1
  }
  cfg=$(fm_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || {
    echo "error: --account needs this home's account pool: config/account-pool naming state=<pool folder>" >&2
    return 1
  }
  if [ "$choice" = next ]; then
    [ -n "$recorded" ] || {
      echo "error: '--account next' moves the account the running worker launched on, and task $task records none; move it with '--account <id>' instead" >&2
      return 1
    }
    command=${cfg%%$'\t'*}
    state=${cfg#*$'\t'}
    recorded_tool=$(fm_account_pool_recorded_tool "$command" "$state" "$recorded") || return 1
    fm_account_pool_next_ok "$recorded_tool" "$from_model" "$to_model" "$task" || return 1
  fi
}

# fm_account_pool_relaunch_commit <harness> <config-dir> <choice> <recorded-id>:
# the account gate's mutating half and a relaunch's last pre-stop step, taken
# only after fm_account_pool_relaunch_pre and every cheaper refusal have
# passed. For 'next' the recorded account rests here, and the canary pick
# below proves the replacement launch can answer without it; an explicit id
# only picks, and the answer must be exactly that account.
fm_account_pool_relaunch_commit() {
  local harness=$1 config=$2 choice=$3 recorded=$4 cfg command state
  cfg=$(fm_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || {
    echo "error: --account needs this home's account pool: config/account-pool naming state=<pool folder>" >&2
    return 1
  }
  command=${cfg%%$'\t'*}
  state=${cfg#*$'\t'}
  if [ "$choice" = next ]; then
    fm_account_pool_rest "$command" "$state" "$recorded" || return 1
  fi
  fm_account_pool_select "$harness" "$config" "$choice" >/dev/null || return 1
}
