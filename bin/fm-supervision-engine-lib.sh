#!/usr/bin/env bash
# fm-supervision-engine-lib.sh - which headless engine runs the supervision
# host's branch session, and how one engine turn runs (one owner of both).
#
# Sourced, never executed. docs/supervision-host.md owns the host design and
# bin/fm-supervision-host.sh the loop; this file owns two contracts, plus the
# main-session key (fm_supervision_host_main_key) and the attended readiness
# check (fm_supervision_host_attended_ready) the host's parts share.
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

# fm_supervision_host_attended_ready <config-dir> <primary-harness>
# 0 when the attended host's configured engine, executable, node, jq, turn
# bound (perl, timeout, or gtimeout), and primary's mirror writer are ready;
# otherwise 1, with FM_SUPERVISION_HOST_UNREADY naming why. The host's
# attended acceptor runs it on every attended close; the mirror's contents are
# checked later, by the feed that renders the wake.
fm_supervision_host_attended_ready() {
  FM_SUPERVISION_HOST_UNREADY=
  if ! fm_supervision_host_config "$1" "$2" || [ -z "$FM_SUPERVISION_ENGINE" ]; then
    FM_SUPERVISION_HOST_UNREADY="no supervision engine"
  elif ! fm_supervision_engine_bin "$FM_SUPERVISION_ENGINE" >/dev/null 2>&1; then
    FM_SUPERVISION_HOST_UNREADY="the $FM_SUPERVISION_ENGINE engine executable is missing"
  elif ! command -v node >/dev/null 2>&1; then
    FM_SUPERVISION_HOST_UNREADY="node is missing"
  elif ! command -v jq >/dev/null 2>&1; then
    FM_SUPERVISION_HOST_UNREADY="jq is missing"
  elif ! command -v perl >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1 \
    && ! command -v gtimeout >/dev/null 2>&1; then
    FM_SUPERVISION_HOST_UNREADY="none of perl, timeout, or gtimeout can bound the engine turn"
  elif ! "$(dirname "${BASH_SOURCE[0]}")/fm-host-mirror.sh" verified "$2"; then
    FM_SUPERVISION_HOST_UNREADY="no verified dialog mirror for $2"
  fi
  [ -z "$FM_SUPERVISION_HOST_UNREADY" ]
}

# fm_supervision_host_outcomes_drained <config-dir>: 0 when main processes the
# supervision session's outcomes through the drain's BRANCH OUTCOMES section
# (bin/fm-wake-drain.sh): the home opted in and its primary is not Pi, whose
# branch extension owns that path. The drain and the return
# (bin/fm-afk-return.sh) share this check.
fm_supervision_host_outcomes_drained() {
  fm_supervision_host_enabled "$1" || return 1
  case "$("$(dirname "${BASH_SOURCE[0]}")/fm-harness.sh" 2>/dev/null)" in pi|pi-signed) return 1 ;; esac
}

# fm_supervision_host_main_key <state-dir>: print the key of the current main
# session, which changes at every main session start: the session-lock holder,
# a checksum of its process identity (bin/fm-wake-lib.sh fm_pid_identity), and
# a checksum of its session sidecar, so a later session given a recycled lock
# pid never shares it. The host keys its engine conversation and broken-session
# latch to it; the dialog mirror (bin/fm-host-mirror.sh) keys each entry and
# feed to it. When the holder's identity cannot be read, it prints nothing and
# fails, so an attended wake reaches main, a mirror writer records nothing,
# and no conversation, latch, or dialog kept under an earlier key is reused.
# Needs bin/fm-wake-lib.sh sourced first.
fm_supervision_host_main_key() {
  local pid identity
  pid=$(sed -n '1p' "$1/.lock" 2>/dev/null)
  identity=$(fm_pid_identity "$pid" 2>/dev/null) && [ -n "$identity" ] || return 1
  printf '%s:%s:%s\n' "$pid" "$(printf '%s\n' "$identity" | cksum | awk '{ print $1 }')" \
    "$(sed -n '1p' "$1/.lock-session" 2>/dev/null | cksum | awk '{ print $1 }')"
}

# fm_supervision_host_health_key <state-dir>: the key the host's
# broken-session latch (bin/fm-supervision-host.sh, state/.supervision-host-health)
# is kept under: the current main session, engine, and model; fails with no
# main-session key. Needs fm_supervision_host_config first.
fm_supervision_host_health_key() {
  local key
  key=$(fm_supervision_host_main_key "$1") || return 1
  printf '%s|%s|%s\n' "$key" "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL"
}

# fm_supervision_host_paused_until <state-dir>: while that latch holds, from
# the trip until a probe succeeds, print the epoch from which the next wake
# probes the engine (every wake before it reaches main) and succeed; otherwise
# fail. Needs fm_supervision_host_config first.
fm_supervision_host_paused_until() {
  local file="$1/.supervision-host-health" key cooldown retry
  key=$(fm_supervision_host_health_key "$1") || return 1
  [ "$(sed -n 's/^key=//p' "$file" 2>/dev/null | head -n 1)" = "$key" ] || return 1
  cooldown=$(sed -n 's/^cooldown=//p' "$file" 2>/dev/null | head -n 1)
  retry=$(sed -n 's/^retry_after=//p' "$file" 2>/dev/null | head -n 1)
  case "$cooldown" in ''|*[!0-9]*) return 1 ;; esac
  case "$retry" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cooldown" -gt 0 ] || return 1
  printf '%s\n' "$retry"
}

# fm_supervision_host_clock <epoch>: the local time of day it names.
fm_supervision_host_clock() {
  date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf 'the end of its cooldown'
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
