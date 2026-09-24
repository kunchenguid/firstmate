#!/usr/bin/env bash
# fm-supervision-engine-lib.sh - which headless engine runs the supervision
# host's branch session, and how one engine turn runs (one owner of both).
#
# Sourced, never executed. docs/supervision-host.md owns the host design and
# bin/fm-supervision-host.sh the loop; this file owns two contracts.
#
# THE HOME OPT-IN (config/supervision-host). docs/configuration.md
# "Supervision host" owns the file's schema and its no-engine outcome; this
# file implements it (fm_supervision_host_config) and holds the verified-engine
# list and each engine's default model (docs/supervision-host.md "Engines").
#
# ONE ENGINE TURN (fm_supervision_engine_turn). One prompt to one engine
# conversation, bounded, from the tracked code root, with the environment the
# caller exported (the host exports the branch actor, the lease holder pid,
# the primary-harness pin, and the report-turn id). The runner returns the
# process exit status; the host separately requires a complete successful
# result, a durable report, and acknowledgement before counting a wake handled.
# The turn is bounded by fm_exec_timed
# (bin/fm-timeout-lib.sh), and the engine's descendants are snapshotted once a
# second while it runs, because an engine CLI runs every tool command in a
# process group of its own that the bound's group signal cannot reach: once
# the turn ends, any snapshotted descendant still alive under the same
# identity is reaped (TERM, then KILL). The reap is best-effort for the
# descendants observed while the turn ran, not a bound: a process that a tool
# detaches into a process group of its own and that loses its ancestry to the
# engine between two snapshots is never recorded and survives the turn, the
# same residual bin/fm-timeout-lib.sh names for a descendant that moves into a
# process group of its own. docs/supervision-host.md "Engines" owns the
# verified engine facts each argument list below is built from.
#
# Test seam: FM_SUPERVISION_ENGINE_CLAUDE_BIN names the claude executable
# (default: claude on PATH), so a hermetic test can run a stub engine through
# the real argument construction.

FM_SUPERVISION_ENGINES_VERIFIED='claude'

# fm_supervision_host_enabled <config-dir>: 0 iff this home opted in.
fm_supervision_host_enabled() {
  [ -f "$1/supervision-host" ]
}

fm_supervision_engine_verified() {  # <engine>
  case " $FM_SUPERVISION_ENGINES_VERIFIED " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

fm_supervision_engine_default_model() {  # <engine>
  case "$1" in
    claude) printf 'sonnet\n' ;;
    *) return 1 ;;
  esac
}

# fm_supervision_host_config <config-dir> <primary-harness>
# Returns 1 when the home did not opt in. Otherwise returns 0 and sets
# FM_SUPERVISION_ENGINE and FM_SUPERVISION_ENGINE_MODEL for a usable engine, or
# leaves both empty and sets FM_SUPERVISION_ENGINE_PROBLEM to one plain
# sentence naming why this home has no engine.
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_supervision_host_config() {
  local config=$1 primary=${2:-} line engine model extra
  FM_SUPERVISION_ENGINE=''
  FM_SUPERVISION_ENGINE_MODEL=''
  FM_SUPERVISION_ENGINE_PROBLEM=''
  fm_supervision_host_enabled "$config" || return 1
  line=
  IFS= read -r line < "$config/supervision-host" 2>/dev/null || true
  engine='' model='' extra=''
  read -r engine model extra <<EOF
$line
EOF
  if [ -n "$extra" ]; then
    FM_SUPERVISION_ENGINE_PROBLEM="config/supervision-host holds more than '<engine> [<model>]'"
    return 0
  fi
  case "$engine" in
    ''|default)
      engine=$primary
      if ! fm_supervision_engine_verified "$engine"; then
        FM_SUPERVISION_ENGINE_PROBLEM="the primary harness '${primary:-unknown}' has no verified supervision engine"
        return 0
      fi
      ;;
    *)
      if ! fm_supervision_engine_verified "$engine"; then
        FM_SUPERVISION_ENGINE_PROBLEM="config/supervision-host names '$engine', which is not a verified supervision engine (verified: $FM_SUPERVISION_ENGINES_VERIFIED)"
        return 0
      fi
      ;;
  esac
  case "$model" in
    '') model=$(fm_supervision_engine_default_model "$engine") || model= ;;
    *[!A-Za-z0-9._:/@-]*)
      FM_SUPERVISION_ENGINE_PROBLEM="config/supervision-host names a malformed engine model '$model'"
      return 0
      ;;
  esac
  FM_SUPERVISION_ENGINE=$engine
  FM_SUPERVISION_ENGINE_MODEL=$model
  return 0
}

# fm_supervision_engine_bin <engine>: print the executable, or fail with a
# plain reason on stderr.
fm_supervision_engine_bin() {
  local bin
  case "$1" in
    claude)
      bin=${FM_SUPERVISION_ENGINE_CLAUDE_BIN:-}
      [ -n "$bin" ] || bin=$(command -v claude 2>/dev/null || true)
      ;;
    *) bin= ;;
  esac
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    echo "the $1 engine executable was not found on PATH" >&2
    return 1
  fi
  printf '%s\n' "$bin"
}

# Print a process's identity (bin/fm-wake-lib.sh fm_pid_identity) on one
# line, the form the descendant ledger records and compares.
_fm_engine_identity() {  # <pid>
  local identity
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" | tr '\t\n' '  ' | sed 's/ *$//'
}

# Print "<pid> <ppid>" for every process.
_fm_engine_process_table() {
  ps -A -o pid= -o ppid= 2>/dev/null
}

# _fm_engine_snapshot_descendants <root-pid> <ledger-file>: record every
# current descendant of <root-pid> as "<pid>\t<identity>". A pid that is still
# a descendant is re-recorded under its current identity, because a process
# first seen between its fork and its exec carries its parent's command line;
# a pid that is no longer a descendant keeps the last identity it was seen
# with, which is what the reap matches once the engine has exited.
_fm_engine_snapshot_descendants() {
  local root=$1 ledger=$2 table pids pid identity fresh
  table=$(_fm_engine_process_table) || return 0
  pids=$(printf '%s\n' "$table" | awk -v root="$root" '
    { parent[$1] = $2; seen[$1] = 1 }
    END {
      for (pid in seen) {
        p = parent[pid]; depth = 0
        while (p != "" && p != "0" && p != "1" && depth < 64) {
          if (p == root) { print pid; break }
          p = parent[p]; depth++
        }
      }
    }')
  [ -n "$pids" ] || return 0
  fresh=
  for pid in $pids; do
    identity=$(_fm_engine_identity "$pid") || continue
    fresh="$fresh$pid	$identity
"
  done
  [ -n "$fresh" ] || return 0
  {
    printf '%s' "$fresh" | awk -F '\t' '{ print $1 }' > "$ledger.pids"
    awk -F '\t' 'NR == FNR { now[$1] = 1; next } !($1 in now)' "$ledger.pids" "$ledger" 2>/dev/null
    printf '%s' "$fresh"
  } > "$ledger.next" && mv -f "$ledger.next" "$ledger"
  rm -f "$ledger.pids" "$ledger.next" 2>/dev/null || true
}

# _fm_engine_reap <ledger-file>: TERM, then KILL, every recorded descendant
# that is still alive under its recorded identity. A recycled pid never
# matches its recorded identity, so it is never signalled.
_fm_engine_reap() {
  local ledger=$1 pid identity current signal survivors i
  [ -s "$ledger" ] || return 0
  for signal in TERM KILL; do
    survivors=0
    while IFS="$(printf '\t')" read -r pid identity; do
      fm_pid_alive "$pid" || continue
      current=$(_fm_engine_identity "$pid") || continue
      [ "$current" = "$identity" ] || continue
      kill "-$signal" "$pid" 2>/dev/null || true
      survivors=$((survivors + 1))
    done < "$ledger"
    [ "$survivors" -gt 0 ] || return 0
    [ "$signal" = KILL ] && return 0
    i=0
    while [ "$i" -lt 20 ]; do
      sleep 0.1
      i=$((i + 1))
    done
  done
}

# fm_supervision_engine_turn <engine> <model> <prompt-file> <message-file>
#     <session-id> <new|resume> <timeout-seconds> <result-file> <error-file>
#     [<pid-file>]
# Runs one bounded engine turn from $FM_ROOT and returns the engine's exit
# status (124 or 137 when the bound was hit, 127 when the engine could not
# run). <result-file> receives the engine's machine-readable result and
# <error-file> its diagnostics. While the turn runs, <pid-file> (when given)
# holds the bounded process's pid and identity, so a restarted host can stop
# an engine its crashed predecessor left running.
fm_supervision_engine_turn() {
  local engine=$1 model=$2 prompt=$3 message=$4 session=$5 mode=$6 timeout=$7 result=$8 errors=$9
  local pid_file=${10:-} bin grace ledger watched rc home_phys root_phys state_phys identity recorded
  local -a args
  bin=$(fm_supervision_engine_bin "$engine" 2>"$errors") || return 127
  case "$timeout" in ''|0*|*[!0-9]*) timeout=1200 ;; esac
  grace=${FM_SUPERVISION_ENGINE_GRACE:-30}
  case "$grace" in ''|0*|*[!0-9]*) grace=30 ;; esac
  case "$engine" in
    claude)
      # The prompt is the first positional argument, ahead of the variadic
      # tool and directory options that would otherwise absorb it.
      # shellcheck disable=SC2054 # Bash,Read is one --tools value.
      args=(-p "$(cat "$message")" --safe-mode --system-prompt-file "$prompt"
        --tools Bash,Read --permission-mode dontAsk --allowedTools Bash Read
        --model "$model" --output-format json)
      root_phys=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || root_phys=$FM_ROOT
      home_phys=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || home_phys=$FM_HOME
      state_phys=$(cd "$STATE" 2>/dev/null && pwd -P) || state_phys=$STATE
      # Claude path-checks direct file reads against its working directories,
      # so a home or state directory outside the code root is added.
      [ "$home_phys" = "$root_phys" ] || args+=(--add-dir "$home_phys")
      case "$state_phys/" in
        "$home_phys"/*|"$root_phys"/*) ;;
        *) args+=(--add-dir "$state_phys") ;;
      esac
      if [ "$mode" = new ]; then
        args+=(--session-id "$session")
      else
        args+=(--resume "$session")
      fi
      ;;
    *)
      printf 'no engine turn is defined for %s\n' "$engine" > "$errors"
      return 127
      ;;
  esac
  ledger=$(mktemp "$STATE/.supervision-host-descendants.XXXXXX") || return 127
  (
    cd "$FM_ROOT" || exit 127
    fm_exec_timed "$timeout" "$grace" "$bin" "${args[@]}"
  ) </dev/null >"$result" 2>"$errors" &
  watched=$!
  recorded=
  while fm_pid_alive "$watched"; do
    # The bounded process is this shell's unreaped child, so its pid cannot
    # be recycled here; its identity is refreshed until the subshell's exec
    # into the watchdog has settled.
    if [ -n "$pid_file" ]; then
      identity=$(_fm_engine_identity "$watched" || true)
      if [ -n "$identity" ] && [ "$identity" != "$recorded" ]; then
        printf '%s\t%s\n' "$watched" "$identity" > "$pid_file" 2>/dev/null || true
        recorded=$identity
      fi
    fi
    _fm_engine_snapshot_descendants "$watched" "$ledger"
    sleep 1
  done
  wait "$watched"
  rc=$?
  [ -z "$pid_file" ] || rm -f "$pid_file" 2>/dev/null || true
  _fm_engine_reap "$ledger"
  rm -f "$ledger" 2>/dev/null || true
  return "$rc"
}

# fm_supervision_engine_result <engine> <result-file> [<prior-conversation-cost>]:
# print one line "error=0|1 cost=<usd> conversation_cost=<usd> input=<n>
# cache_read=<n> cache_write=<n> output=<n> turns=<n>" from the engine's
# machine-readable result, where cost is this turn's and conversation_cost the
# conversation's running total (the caller records it and passes it back for
# the next turn; 0 for a new conversation). Claude's total_cost_usd is that
# running total on a resumed conversation, while its usage and num_turns are
# per turn. error=0 only for a complete success result: type "result",
# subtype "success", is_error false, and finite total_cost_usd, num_turns, and
# the four usage token counts; any other shape is error=1. Returns 1 when the
# result cannot be read. The host treats both as a failed turn.
fm_supervision_engine_result() {
  case "$1" in
    claude)
      # shellcheck disable=SC2016 # A literal Node program; ${...} is JavaScript.
      node -e '
        const fs = require("node:fs");
        let j;
        try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
        if (!j || typeof j !== "object") process.exit(1);
        const u = j.usage && typeof j.usage === "object" ? j.usage : {};
        const finite = (v) => typeof v === "number" && Number.isFinite(v);
        const n = (v) => (finite(v) ? v : 0);
        const complete = j.type === "result" && j.subtype === "success" && j.is_error === false
          && finite(j.total_cost_usd) && finite(j.num_turns) && finite(u.input_tokens)
          && finite(u.cache_read_input_tokens) && finite(u.cache_creation_input_tokens) && finite(u.output_tokens);
        const error = complete ? 0 : 1;
        const total = n(j.total_cost_usd);
        const prior = Number(process.argv[2]);
        const turn = Number.isFinite(prior) && prior >= 0 && prior <= total ? total - prior : total;
        const usd = (v) => Number(v.toFixed(6));
        process.stdout.write(`error=${error} cost=${usd(turn)} conversation_cost=${usd(total)} input=${n(u.input_tokens)} cache_read=${n(u.cache_read_input_tokens)} cache_write=${n(u.cache_creation_input_tokens)} output=${n(u.output_tokens)} turns=${n(j.num_turns)}\n`);
      ' "$2" "${3:-0}" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}
