#!/usr/bin/env bash
# fm-failover-lib.sh - classification helpers for active-worker provider
# failover (bin/fm-failover.sh) and the watcher's provider-outage fast path
# (bin/fm-watch.sh).
#
# Pure, side-effect-free predicates only; the mutation mechanics live in
# bin/fm-failover.sh. Callers must have sourced bin/fm-backend.sh first
# (fm_meta_get). docs/provider-failover.md owns the mechanism narrative and the
# backend-support evidence record.
#
# Provider-outage evidence is deliberately a bounded, curated signature set: it
# licenses SURFACING a supervisor-actionable event and re-verification by
# bin/fm-failover.sh, never an automatic switch on its own.

# Signatures of provider quota exhaustion or rate limiting as rendered by the
# OpenAI/Codex-backed CLIs. Case-insensitive extended regex, matched against a
# bounded pane tail and against a task's last status line. FM_FAILOVER_OUTAGE_RE
# overrides the whole set. The bare-429 form requires an error-ish neighbor so a
# diff or doc line merely containing "429" does not fire.
FM_FAILOVER_OUTAGE_RE_DEFAULT='usage limit|rate limit|rate.limit_exceeded|too many requests|insufficient._quota|quota exceeded|exceeded your current quota|out of credits|(error|status|http)[^0-9]*429|429[^0-9]*(rate|quota|too many)'

# How many trailing non-blank pane lines are scanned for outage evidence. Wide
# enough to catch an error block above a composer, bounded so old scrollback
# discussing rate limits cannot fire forever.
FM_FAILOVER_OUTAGE_TAIL_LINES_DEFAULT=25

# fm_failover_route_is_openai: 0 when <meta-file>'s recorded route is
# OpenAI/Codex-backed - harness=codex, or any harness launched with an
# OpenAI-family model (openai*/... provider prefixes, or a gpt-* model name).
fm_failover_route_is_openai() {  # <meta-file>
  local meta=$1 harness model
  harness=$(fm_meta_get "$meta" harness)
  [ "$harness" = codex ] && return 0
  model=$(fm_meta_get "$meta" model)
  fm_failover_model_is_openai "$model"
}

# fm_failover_model_is_openai: 0 when a model string names an OpenAI-family
# model. Used by the route check above and by the candidate-ladder guard that
# refuses OpenAI as a failover destination.
fm_failover_model_is_openai() {  # <model>
  local model=$1
  case "$model" in
    openai*|*/gpt-*|gpt-*) return 0 ;;
  esac
  return 1
}

# fm_failover_harness_or_model_is_openai: 0 when a candidate route
# (harness + model) would land on OpenAI. codex is OpenAI-backed regardless of
# model.
fm_failover_harness_or_model_is_openai() {  # <harness> <model>
  [ "$1" = codex ] && return 0
  fm_failover_model_is_openai "$2"
}

# fm_failover_provider_of_route: print the provider a (harness, model) route
# lands on: openai, anthropic, ollama, xai, a model's own provider prefix, or
# unknown. Used by the provider-hold gate (bin/fm-provider-hold.sh and
# fm-spawn.sh's launch check) and by hold-aware candidate skipping.
fm_failover_provider_of_route() {  # <harness> <model>
  local harness=$1 model=$2
  if fm_failover_harness_or_model_is_openai "$harness" "$model"; then
    printf 'openai'
    return 0
  fi
  case "$model" in
    ollama/*) printf 'ollama'; return 0 ;;
    claude*|anthropic*) printf 'anthropic'; return 0 ;;
  esac
  case "$harness" in
    claude) printf 'anthropic' ;;
    grok) printf 'xai' ;;
    *)
      case "$model" in
        */*) printf '%s' "${model%%/*}" ;;
        *) printf 'unknown' ;;
      esac
      ;;
  esac
}

# fm_failover_provider_name_valid: hold-file safety - provider names are plain
# lowercase slugs, never paths.
fm_failover_provider_name_valid() {  # <provider>
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_failover_hold_path: the durable provider-hold marker for <provider> under
# <state-dir>. Presence means: verified exhaustion was recorded and NEW
# launches on this provider are refused - deliberately independent of any
# quota cache, so a stale quota read can never re-open a held provider.
# bin/fm-provider-hold.sh owns creation, listing, and verified release.
fm_failover_hold_path() {  # <state-dir> <provider>
  printf '%s/.provider-hold-%s' "$1" "$2"
}

# fm_failover_provider_held: 0 when <provider> has an active hold in
# <state-dir>. An unknown provider is never held.
fm_failover_provider_held() {  # <state-dir> <provider>
  local state=$1 provider=$2
  [ "$provider" != unknown ] || return 1
  fm_failover_provider_name_valid "$provider" || return 1
  [ -e "$(fm_failover_hold_path "$state" "$provider")" ]
}

# --- provider-usage pressure -------------------------------------------------
#
# Snapshots live at state/.provider-usage-<provider>, written only by
# bin/fm-provider-usage.sh (recorded_at=, source=, session_pct=, week_pct=,
# reset=, repeated model_pct=<model>=<n> lines). Pressure informs NEW-launch
# exclusion and planned safe-checkpoint handoffs; it NEVER releases a verified
# provider hold - a hold is authoritative over any quota telemetry, fresh or
# stale, and clears only through bin/fm-provider-hold.sh's probe-verified
# release.
FM_PROVIDER_SESSION_AVOID_PCT_DEFAULT=70
FM_PROVIDER_SESSION_HANDOFF_PCT_DEFAULT=85
FM_PROVIDER_WEEK_AVOID_PCT_DEFAULT=90
FM_PROVIDER_USAGE_MAX_AGE_SECS_DEFAULT=1800

fm_failover_usage_path() {  # <state-dir> <provider>
  printf '%s/.provider-usage-%s' "$1" "$2"
}

# fm_failover_provider_pressure: print one line "<verdict> <detail>", verdict
# one of:
#   unknown - no snapshot, unreadable values, or older than
#             FM_PROVIDER_USAGE_MAX_AGE_SECS. Unknown telemetry never blocks a
#             launch (error-based supervision and holds remain the backstop).
#   handoff - session use at/above the handoff threshold: prepare a
#             safe-checkpoint provider handoff for active workers.
#   avoid   - session use at/above the avoid threshold, or a weekly or
#             matching model window at/above the weekly threshold: exclude the
#             provider from NEW launches.
#   ok      - fresh telemetry below every threshold.
fm_failover_provider_pressure() {  # <state-dir> <provider> [<model>]
  local state=$1 provider=$2 model=${3:-} usage now recorded age line
  local session_pct='' week_pct='' model_hit='' model_name model_val
  local avoid=${FM_PROVIDER_SESSION_AVOID_PCT:-$FM_PROVIDER_SESSION_AVOID_PCT_DEFAULT}
  local handoff=${FM_PROVIDER_SESSION_HANDOFF_PCT:-$FM_PROVIDER_SESSION_HANDOFF_PCT_DEFAULT}
  local week_avoid=${FM_PROVIDER_WEEK_AVOID_PCT:-$FM_PROVIDER_WEEK_AVOID_PCT_DEFAULT}
  local max_age=${FM_PROVIDER_USAGE_MAX_AGE_SECS:-$FM_PROVIDER_USAGE_MAX_AGE_SECS_DEFAULT}
  usage=$(fm_failover_usage_path "$state" "$provider")
  [ -f "$usage" ] || { printf 'unknown no usage snapshot for %s\n' "$provider"; return 0; }
  recorded=$(sed -n 's/^recorded_at=//p' "$usage" | head -1)
  case "$recorded" in ''|*[!0-9]*) printf 'unknown unreadable snapshot for %s\n' "$provider"; return 0 ;; esac
  now=$(date +%s)
  age=$((now - recorded))
  if [ "$age" -gt "$max_age" ]; then
    printf 'unknown snapshot for %s is stale (age %ss > %ss)\n' "$provider" "$age" "$max_age"
    return 0
  fi
  session_pct=$(sed -n 's/^session_pct=//p' "$usage" | head -1)
  week_pct=$(sed -n 's/^week_pct=//p' "$usage" | head -1)
  case "$session_pct" in *[!0-9]*) session_pct= ;; esac
  case "$week_pct" in *[!0-9]*) week_pct= ;; esac
  if [ -n "$session_pct" ] && [ "$session_pct" -ge "$handoff" ]; then
    printf 'handoff %s session use %s%% >= %s%% (source %s)\n' "$provider" "$session_pct" "$handoff" "$(sed -n 's/^source=//p' "$usage" | head -1)"
    return 0
  fi
  if [ -n "$session_pct" ] && [ "$session_pct" -ge "$avoid" ]; then
    printf 'avoid %s session use %s%% >= %s%%\n' "$provider" "$session_pct" "$avoid"
    return 0
  fi
  if [ -n "$week_pct" ] && [ "$week_pct" -ge "$week_avoid" ]; then
    printf 'avoid %s weekly use %s%% >= %s%%\n' "$provider" "$week_pct" "$week_avoid"
    return 0
  fi
  if [ -n "$model" ] && [ "$model" != default ]; then
    # A recorded model key is a short window identity (quota-axi's id, e.g.
    # "fable", or a hand-recorded name); it matches when the launch model
    # contains it, so "fable" gates "claude-fable-5[1m]" and
    # "kimi-k2.7-code" gates "ollama/kimi-k2.7-code".
    while IFS= read -r line; do
      model_name=${line%=*}
      model_val=${line##*=}
      [ -n "$model_name" ] || continue
      case "$model_val" in ''|*[!0-9]*) continue ;; esac
      case "$model" in
        *"$model_name"*)
          if [ "$model_val" -ge "$week_avoid" ]; then
            model_hit="$model_name=$model_val"
            break
          fi
          ;;
      esac
    done <<EOF
$(sed -n 's/^model_pct=//p' "$usage")
EOF
    if [ -n "$model_hit" ]; then
      printf 'avoid %s model window %s (%s%% >= %s%%)\n' "$provider" "${model_hit%=*}" "${model_hit##*=}" "$week_avoid"
      return 0
    fi
  fi
  if [ -z "$session_pct" ] && [ -z "$week_pct" ]; then
    printf 'unknown snapshot for %s carries no readable percentages\n' "$provider"
    return 0
  fi
  printf 'ok %s session %s%% week %s%%\n' "$provider" "${session_pct:-?}" "${week_pct:-?}"
}

# fm_failover_outage_evidence: print the first provider-outage evidence line
# found in the trailing FM_FAILOVER_OUTAGE_TAIL_LINES non-blank lines of the
# text on stdin-argument <text>, and return 0; print nothing and return 1 when
# no signature matches.
fm_failover_outage_evidence() {  # <text>
  local text=$1 hit
  hit=$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' \
    | tail -"${FM_FAILOVER_OUTAGE_TAIL_LINES:-$FM_FAILOVER_OUTAGE_TAIL_LINES_DEFAULT}" \
    | grep -m1 -iE "${FM_FAILOVER_OUTAGE_RE:-$FM_FAILOVER_OUTAGE_RE_DEFAULT}" || true)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# fm_failover_outage_dedupe_key: normalize outage evidence for the watcher's
# once-per-outage marker - digits are stripped so a ticking retry countdown
# ("retrying in 23s") cannot re-fire the wake every poll.
fm_failover_outage_dedupe_key() {  # <evidence-text>
  printf '%s' "$1" | tr -d '0-9' | tr -s '[:space:]' ' '
}

# The default destination ladder, best first. OpenAI is never a member and an
# FM_FAILOVER_CANDIDATES override ("harness:model" tokens, whitespace-separated)
# is still filtered through the OpenAI guard by the consumer.
FM_FAILOVER_CANDIDATES_DEFAULT='claude:claude-fable-5[1m] pi:ollama/kimi-k2.7-code pi:ollama/glm-5.2'

# fm_failover_candidates: print the effective candidate list, one
# "harness:model" token per line, refusing any OpenAI-backed entry loudly.
fm_failover_candidates() {
  local list token harness model
  list=${FM_FAILOVER_CANDIDATES:-$FM_FAILOVER_CANDIDATES_DEFAULT}
  for token in $list; do
    harness=${token%%:*}
    model=${token#*:}
    if [ -z "$harness" ] || [ -z "$model" ] || [ "$model" = "$token" ]; then
      echo "error: malformed failover candidate '$token' (expected harness:model)" >&2
      return 1
    fi
    if fm_failover_harness_or_model_is_openai "$harness" "$model"; then
      echo "error: failover candidate '$token' is OpenAI-backed; OpenAI is never a failover destination" >&2
      return 1
    fi
    printf '%s\n' "$token"
  done
}

# fm_failover_probe_classify: classify a candidate probe's outcome from its
# exit code and combined output. Prints one of:
#   available     - the probe completed (exit 0)
#   unavailable   - the provider itself is not usable right now: auth missing,
#                   quota/rate exhaustion, unknown/unpulled model, connection
#                   failure, or a probe timeout (exit 124)
#   inconclusive  - the probe failed some other way; the caller must STOP and
#                   report rather than silently advancing past a provider that
#                   may be fine (distinguishing provider unavailability from an
#                   ordinary failure is the whole point of the probe).
fm_failover_probe_classify() {  # <exit-code> <output>
  local code=$1 out=$2
  if [ "$code" = 0 ]; then
    printf 'available'
    return 0
  fi
  if [ "$code" = 124 ]; then
    printf 'unavailable'
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'not logged in|log ?in|authentication|unauthorized|api key|credential|usage limit|rate limit|rate.limit|too many requests|quota|out of credits|model.*not (found|available|installed)|unknown model|invalid model|no such model|connection refused|could not connect|connect(ion)? (error|failed)|network error|ollama.*(not running|unreachable)'; then
    printf 'unavailable'
    return 0
  fi
  printf 'inconclusive'
}

# fm_failover_backend_supported: 0 when <backend> carries every proof the
# failover path requires - a verified agent-process liveness classifier
# (fm_backend_agent_alive) for the no-second-agent and old-agent-exit proofs,
# and a verified live-process command/model read for post-relaunch
# verification. On refusal, prints the concrete missing proof to stderr.
# Evidence record: docs/provider-failover.md "Backend support".
fm_failover_backend_supported() {  # <backend>
  case "$1" in
    tmux) return 0 ;;
    herdr)
      echo "backend herdr: agent liveness is verified but a live process command/model read is not; provider failover refuses rather than claiming unverified support (docs/provider-failover.md)" >&2
      return 1
      ;;
    zellij|orca|cmux)
      echo "backend $1: no verified agent-process liveness classifier (fm_backend_agent_alive reports unknown); provider failover refuses rather than claiming unverified support (docs/provider-failover.md)" >&2
      return 1
      ;;
    *)
      echo "backend $1: unknown backend; provider failover refuses" >&2
      return 1
      ;;
  esac
}

# fm_failover_exit_command: the composer command that exits <harness>'s
# interactive session. Mechanics mirror of the harness-adapters skill's
# verified exit facts; that skill stays the knowledge owner.
fm_failover_exit_command() {  # <harness>
  case "$1" in
    claude|opencode|grok) printf '/exit' ;;
    codex|pi) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# fm_failover_pane_process_args: print "pid ppid args" rows for the pane's
# root process and every live descendant, resolved with a fixed-point closure
# over one `ps -ax` snapshot so child rows are found regardless of pid order.
# tmux-only today (docs/provider-failover.md records the empirical basis);
# other backends are refused earlier by fm_failover_backend_supported.
fm_failover_pane_process_args() {  # <backend> <target>
  local backend=$1 target=$2 pane_pid
  case "$backend" in
    tmux)
      pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      case "$pane_pid" in ''|*[!0-9]*) return 1 ;; esac
      ps -ax -o pid=,ppid=,args= 2>/dev/null | awk -v root="$pane_pid" '
        {pid[NR]=$1; pp[NR]=$2; line[NR]=$0}
        END{
          keep[root]=1; changed=1
          while (changed) {
            changed=0
            for (i=1; i<=NR; i++) if (!(pid[i] in keep) && (pp[i] in keep)) {keep[pid[i]]=1; changed=1}
          }
          for (i=1; i<=NR; i++) if (pid[i] in keep) print line[i]
        }'
      ;;
    *)
      return 1
      ;;
  esac
}

# fm_failover_nested_agents: print one "harness<TAB>model<TAB>args" row for
# every LIVE agent process inside the endpoint's process tree BEYOND the outer
# worker itself - e.g. a No Mistakes pipeline step still running a native
# `codex exec resume` review agent under an outer Fable worker. The first row
# matching <outer-harness> is the outer agent and is skipped; every other
# claude/codex/pi/grok/opencode process is reported with its --model value when
# present ("unknown" otherwise). Pipeline-owned agents must be inspected and
# reported separately from the outer route, and never interrupted or restarted
# by a failover: bin/fm-failover.sh refuses to exit an outer agent while one is
# live. Prints nothing (status 0) when no nested agent is found; non-zero only
# when the tree itself is unreadable.
fm_failover_nested_agents() {  # <backend> <target> <outer-harness>
  local backend=$1 target=$2 outer=$3 rows
  rows=$(fm_failover_pane_process_args "$backend" "$target") || return 1
  printf '%s\n' "$rows" | awk -v outer="$outer" '
    {
      args=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", args)
      n=split(args, w, /[[:space:]]+/)
      h=""
      for (i=1; i<=n; i++) {
        tok=w[i]
        if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (tok ~ /^-/) break
        sub(/^.*\//, "", tok)
        if (tok == "claude" || tok == "codex" || tok == "pi" || tok == "grok" || tok == "opencode") { h=tok; break }
      }
      if (h == "") next
      if (h == outer && !outer_seen) { outer_seen=1; next }
      model="unknown"
      for (i=1; i<n; i++) if (w[i] == "--model") { model=w[i+1]; break }
      printf "%s\t%s\t%s\n", h, model, args
    }'
}

# fm_failover_live_route_verified: 0 when the pane's live process tree contains
# a process actually running <harness> with <model> on its command line - the
# post-relaunch proof that the switch is real, not just recorded. A default
# model only requires the harness process. Fixed-string matching so bracketed
# model names ("claude-fable-5[1m]") cannot be misread as a regex.
fm_failover_live_route_verified() {  # <backend> <target> <harness> <model>
  local backend=$1 target=$2 harness=$3 model=$4 rows matched
  rows=$(fm_failover_pane_process_args "$backend" "$target") || return 1
  # A harness may run as its own binary (claude, codex, grok) or through an
  # interpreter whose script path names it (pi execs into node with the pi
  # script as an argument - docs/tmux-backend.md "Known gaps"), so the harness
  # name is accepted at any command-position token: env assignments are
  # skipped, then every token up to the first flag-like token is checked by
  # basename.
  matched=$(printf '%s\n' "$rows" | awk -v h="$harness" '
    {
      args=$0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", args)
      n=split(args, w, /[[:space:]]+/)
      for (i=1; i<=n; i++) {
        tok=w[i]
        if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (tok ~ /^-/) break
        sub(/^.*\//, "", tok)
        if (tok == h) { print args; exit }
      }
    }')
  [ -n "$matched" ] || return 1
  if [ -n "$model" ] && [ "$model" != default ]; then
    printf '%s' "$matched" | grep -qF -- "--model $model" || return 1
  fi
  printf '%s\n' "$matched"
}
