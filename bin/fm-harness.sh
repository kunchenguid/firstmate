#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor-agent|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-source   print secondmate-config when a concrete
#                                        config/secondmate-harness pin owns the
#                                        tuple, otherwise fallback.
#        fm-harness.sh secondmate-tuple    print the exact tab-separated
#                                        harness/model/effort triple from a
#                                        safe concrete config/secondmate-harness.
#                                        It refuses absent, fallback, partial,
#                                        unverified, malformed, or max tuples.
#        fm-harness.sh secondmate-tuple-facts
#                                        print the exact tab-separated
#                                        harness/model/effort/provider/model-family
#                                        tuple after binding the durable launch
#                                        tuple through config/model-catalog.json.
#        fm-harness.sh escalate <id> --class <substantive|injection|mechanical>
#                                        resolve the relaunch routing tuple for a failed
#                                        ordinary direct report through the classifying
#                                        escalation ladder (see below).
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
#
# Escalation ladder (the `escalate` subcommand)
#
# This script owns routing resolution, so the relaunch-routing decision for a
# failed ordinary direct report lives here too - never in a second resolver.
# The ladder is CLASSIFYING, and the caller (the stuck-crewmate-recovery skill)
# owns the classification judgment; this command owns the mechanics:
#   substantive  - capability evidence (wrong answer, looped after redirect,
#                  failed the same gate twice): raise effort ONE rung
#                  (default/low -> medium -> high -> xhigh), same harness/model.
#   injection    - the worker refused its brief as suspected injection: rotate
#                  the harness one step along the fixed vendor-diverse order
#                  claude -> codex -> opencode -> pi|pi-signed -> grok -> kimi
#                  -> cursor-agent -> (wrap), preserving effort and resetting
#                  model to default (model ids are harness-local).
#   mechanical   - environment evidence (worktree acquisition timeout, network
#                  or API error, denied permission, machine memory pressure):
#                  relaunch the identical tuple.
# Ceilings, all fail-closed:
#   - the effort ladder NEVER selects max; at xhigh a further substantive
#     failure resolves verdict=escalate-captain reason=effort-ceiling when the
#     adapter verifiably carried that tier - a top rung recorded onto an
#     adapter that never expressed it (an injection rotation preserves the
#     requested effort onto effortless adapters) resolves the truthful
#     reason=effort-capped or reason=effort-unsupported instead.
#   - a substantive rung the current harness cannot express resolves
#     verdict=escalate-captain reason=effort-capped (the adapter has an effort
#     flag but not at that level) or reason=effort-unsupported (no effort flag
#     at all), read from the shared table in bin/fm-launch-axis-lib.sh so the
#     ladder and the launch command can never disagree.
#   - at most 3 ladder attempts per task (any class or verdict mix); the next
#     request resolves verdict=escalate-captain reason=attempt-budget.
#   - a current harness outside the rotation list resolves
#     verdict=escalate-captain reason=harness-not-rotatable.
# Precedence (AGENTS.md section 4) is enforced through the routing_source=
# field fm-spawn.sh records from --routing-source: the ladder acts only on
# routing_source=fallback. A captain, profile, or secondmate-config source resolves
# verdict=report reason=routing-pinned, and an absent field resolves
# verdict=report reason=unknown-provenance; both leave routing untouched but
# still consume budget, because the caller relaunches the unchanged tuple by
# the ordinary path and that loop needs the same ceiling. kind=secondmate metas
# are refused (exit 1): secondmate recovery belongs to secondmate-provisioning.
# Output is stable and parseable. A relaunch verdict prints:
#   verdict=relaunch / class=<class> / attempts=<n> / harness= / model= / effort=
# A report or escalate-captain verdict prints verdict=, reason=, attempts=, and
# the current (unchanged) tuple. When metadata records account_profile=, every
# verdict appends that alias unchanged; the ladder never selects another account.
# All verdicts exit 0; usage errors, unreadable or
# nonstandard metadata, refused kinds, and an attempt log that cannot be
# appended to exit 1 with the error on stderr - an escalation the budget cannot
# record is never emitted.
# Every verdict appends one line to the append-only log state/<id>.escalation,
# owned by this command:
#   <epoch>\t<class>\t<verdict>\t<reason|none>\t<old harness,model,effort>\t<new harness,model,effort>
# The line count IS the attempt budget; teardown removes the file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before ancestry detection as an explicit precedence rule.
  # Claude, Pi, Grok, and Cursor set verified markers of their own; codex,
  # opencode, Kimi, and Muse are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  # Cursor must be checked before Claude because a Cursor child may inherit
  # CLAUDECODE from the process that launched it while retaining its own marker.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args argv0
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    if fm_cursor_process_matches "$comm" '' "$argv0"; then
      echo cursor-agent
      return
    fi
    case "$(basename -- "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      muse|muse-bin-*) echo muse; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

resolve_secondmate_source() {
  if resolve_secondmate_tuple >/dev/null 2>&1; then
    printf 'secondmate-config\n'
  else
    printf 'fallback\n'
  fi
}

resolve_secondmate_tuple() {
  local line harness model effort extra
  [ -f "$CONFIG/secondmate-harness" ] && [ ! -L "$CONFIG/secondmate-harness" ] || {
    echo "error: config/secondmate-harness must be a safe concrete tuple" >&2
    return 1
  }
  line=$(secondmate_line)
  [ -n "$line" ] || {
    echo "error: config/secondmate-harness must name harness, model, and effort" >&2
    return 1
  }
  # shellcheck disable=SC2086 # deliberate tokenization of the documented single-line format
  set -- $line
  harness=${1:-}
  model=${2:-}
  effort=${3:-}
  extra=${4:-}
  [ -n "$harness" ] && [ "$harness" != default ] && [ -n "$model" ] && [ -n "$effort" ] && [ -z "$extra" ] || {
    echo "error: config/secondmate-harness must contain exactly harness, model, and effort" >&2
    return 1
  }
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor-agent) ;;
    *) echo "error: config/secondmate-harness names an unverified harness" >&2; return 1 ;;
  esac
  case "$effort" in
    low|medium|high|xhigh) ;;
    max) echo "error: automatic secondmate tuple must not select max effort" >&2; return 1 ;;
    *) echo "error: config/secondmate-harness effort is invalid" >&2; return 1 ;;
  esac
  [ "${#harness}" -le 96 ] && [ "${#model}" -le 160 ] || {
    echo "error: config/secondmate-harness tuple is too long" >&2
    return 1
  }
  printf '%s\t%s\t%s\n' "$harness" "$model" "$effort"
}

# Bind the durable secondmate launch tuple to provider and model-family facts
# from the home-local catalog owner. The catalog carries explicit relations;
# this command never infers either axis from a harness or model spelling.
resolve_secondmate_tuple_facts() {
  local tuple harness model effort catalog
  tuple=$(resolve_secondmate_tuple) || return 1
  IFS=$'\t' read -r harness model effort <<EOF
$tuple
EOF
  catalog="$CONFIG/model-catalog.json"
  [ -f "$catalog" ] && [ ! -L "$catalog" ] || {
    echo "error: config/model-catalog.json must safely bind the durable secondmate tuple" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to validate config/model-catalog.json" >&2
    return 1
  }
  jq -er --arg harness "$harness" --arg model "$model" --arg effort "$effort" '
    def bounded($n): type == "string" and length >= 1 and length <= $n and test("^[A-Za-z0-9._/-]+$");
    def exact_tuple_keys: (keys | sort) == ["harness","model","modelFamily","provider"];
    if (keys | sort) != ["schemaVersion","tuples"]
       or .schemaVersion != 1 or (.tuples | type) != "array" or (.tuples | length) > 256
       or ([.tuples[] | select((type != "object") or (exact_tuple_keys | not)
            or (.harness | bounded(96) | not)
            or (.model | bounded(160) | not)
            or (.provider | bounded(96) | not)
            or (.modelFamily | bounded(96) | not))] | length) != 0
       or ([.tuples[] | [.harness,.model]] | unique | length) != (.tuples | length)
    then error("invalid catalog")
    else [.tuples[] | select(.harness == $harness and .model == $model)] as $matches
      | if ($matches | length) != 1 then error("tuple is absent or contradictory")
        else [$harness,$model,$effort,$matches[0].provider,$matches[0].modelFamily] | @tsv
        end
    end
  ' "$catalog" 2>/dev/null || {
    echo "error: config/model-catalog.json does not uniquely bind the durable secondmate tuple" >&2
    return 1
  }
}

# --- escalation ladder --------------------------------------------------------

# Fixed vendor-diverse rotation order for the injection class. A slot may list
# several harness identities of one vendor, separated by "|": any of them
# matches that slot, and a rotation always lands on the slot's FIRST identity.
# That is how pi-signed rotates off the Pi vendor entirely instead of onto plain
# pi (same vendor, so it could not remedy a pi-family refusal) or straight to a
# human, while a rotation into the Pi slot still picks the identity that needs
# no extra signed wrapper on PATH.
ESCALATION_ROTATION="claude codex opencode pi|pi-signed grok kimi cursor-agent"
ESCALATION_MAX_RELAUNCHES=3

# esc_meta_get <meta-file> <key>: last-wins read of one key= field.
esc_meta_get() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# esc_tuple <harness> <model> <effort>: canonical single-field log spelling.
esc_tuple() {
  printf '%s,%s,%s' "$1" "$2" "$3"
}

escalate_usage() {
  echo "usage: fm-harness.sh escalate <task-id> --class <substantive|injection|mechanical>" >&2
  exit 1
}

escalate_task() {
  local id=$1 class=$2
  local meta="$STATE/$id.meta" log="$STATE/$id.escalation"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    echo "error: escalate $id: no readable task metadata at $meta" >&2
    exit 1
  fi
  local kind harness model effort source account_profile
  kind=$(esc_meta_get "$meta" kind)
  harness=$(esc_meta_get "$meta" harness)
  model=$(esc_meta_get "$meta" model)
  effort=$(esc_meta_get "$meta" effort)
  source=$(esc_meta_get "$meta" routing_source)
  account_profile=$(esc_meta_get "$meta" account_profile)
  case "$kind" in
    ship|scout) ;;
    secondmate)
      echo "error: escalate $id: kind=secondmate is recovered through secondmate-provisioning, never the routing ladder" >&2
      exit 1
      ;;
    *)
      echo "error: escalate $id: metadata records no ordinary kind=ship|scout (found '${kind:-none}')" >&2
      exit 1
      ;;
  esac
  [ -n "$harness" ] || { echo "error: escalate $id: metadata records no harness=" >&2; exit 1; }
  if [ -n "$account_profile" ]; then
    [ "$harness" = claude ] || {
      echo "error: escalate $id: account_profile metadata is valid only for harness=claude" >&2
      exit 1
    }
    fm_claude_account_profile_name_valid "$account_profile" || {
      echo "error: escalate $id: metadata records an unsafe account_profile=" >&2
      exit 1
    }
  fi
  model=${model:-default}
  effort=${effort:-default}

  local verdict='' reason='' new_harness=$harness new_model=$model new_effort=$effort
  # Precedence guard: the ladder acts only where the generic fallback acted.
  # A captain or profile source keeps its routing and gets a report instead;
  # an absent field is unknown provenance and fails closed the same way.
  if [ "$source" != fallback ]; then
    verdict=report reason=routing-pinned
    [ -n "$source" ] || reason=unknown-provenance
  else
    case "$class" in
      substantive)
        case "$effort" in
          default|low) new_effort=medium ;;
          medium) new_effort=high ;;
          high) new_effort=xhigh ;;
          # xhigh (or a max that only a captain could have set) is the top of
          # the ladder: stop and escalate to a human. Never select max here.
          # The recorded tier is the REQUESTED axis, not proof the launch
          # carried it: an injection rotation preserves effort onto adapters
          # with no flag for it, so name effort-ceiling only when this
          # adapter verifiably expressed the tier, else the axis truth.
          *)
            verdict=escalate-captain
            case "$(fm_effort_axis_state "$harness" "$effort")" in
              supported) reason='effort-ceiling' ;;
              capped) reason='effort-capped' ;;
              *) reason='effort-unsupported' ;;
            esac
            ;;
        esac
        # A rung the harness cannot express is not a weaker relaunch, it is the
        # SAME launch: fm-spawn omits an effort flag the adapter has no verified
        # support for. Spending a budget slot on that identical relaunch buys
        # nothing, so stop on the harness's own limit instead.
        if [ -z "$verdict" ]; then
          case "$(fm_effort_axis_state "$harness" "$new_effort")" in
            supported) ;;
            capped) verdict=escalate-captain reason=effort-capped ;;
            *) verdict=escalate-captain reason=effort-unsupported ;;
          esac
        fi
        ;;
      injection)
        local found='' slot
        for slot in $ESCALATION_ROTATION; do
          if [ -n "$found" ]; then new_harness=${slot%%|*}; break; fi
          case "|$slot|" in *"|$harness|"*) found=1 ;; esac
        done
        if [ -z "$found" ]; then
          verdict=escalate-captain reason=harness-not-rotatable
        else
          if [ "$new_harness" = "$harness" ]; then
            new_harness=${ESCALATION_ROTATION%% *}
            new_harness=${new_harness%%|*}
          fi
          # Model ids are harness-local; a rotation never carries one across.
          new_model=default
        fi
        ;;
      mechanical) ;;
    esac
    if [ -n "$account_profile" ] && [ "$new_harness" != "$harness" ]; then
      verdict=escalate-captain reason=account-profile-harness-bound
      new_harness=$harness new_model=$model new_effort=$effort
    fi
    [ -n "$verdict" ] || verdict=relaunch
  fi
  if [ "$verdict" != relaunch ]; then
    new_harness=$harness new_model=$model new_effort=$effort
  fi

  # Serialize the fold-and-append so concurrent escalations of one task cannot
  # both spend the same budget slot.
  local lock="$STATE/.$id.escalation.lock"
  fm_lock_acquire_wait "$lock"
  # Attempt budget: EVERY escalate invocation appends one line and every line
  # counts, folded under the lock so this read is the single authority. A report
  # verdict relaunches the unchanged tuple by the ordinary path, so it consumes
  # the same budget a ladder relaunch does; otherwise a pinned or legacy task
  # could report-and-relaunch forever with nothing ever reaching a human.
  # Class-specific ceilings above win over the budget because they name the more
  # precise reason; all of them are terminal and emit no relaunch.
  local attempts=0
  if [ -f "$log" ]; then
    attempts=$(awk 'END { print NR + 0 }' "$log")
  fi
  if [ "$attempts" -ge "$ESCALATION_MAX_RELAUNCHES" ] && [ "$verdict" != escalate-captain ]; then
    verdict=escalate-captain reason=attempt-budget
    new_harness=$harness new_model=$model new_effort=$effort
  fi
  # The append IS the budget, so an unrecorded attempt must never resolve to a
  # relaunch or a report: either keeps the task going while spending no slot.
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$class" "$verdict" "${reason:-none}" \
    "$(esc_tuple "$harness" "$model" "$effort")" \
    "$(esc_tuple "$new_harness" "$new_model" "$new_effort")" >> "$log"; then
    fm_lock_release "$lock"
    echo "error: escalate $id: could not append the attempt to $log; refusing an unbudgeted escalation" >&2
    exit 1
  fi
  attempts=$((attempts + 1))
  fm_lock_release "$lock"

  if [ "$verdict" = relaunch ]; then
    printf 'verdict=relaunch\nclass=%s\nattempts=%s\nharness=%s\nmodel=%s\neffort=%s\n' \
      "$class" "$attempts" "$new_harness" "$new_model" "$new_effort"
    [ -z "$account_profile" ] || printf 'account_profile=%s\n' "$account_profile"
    return 0
  fi
  printf 'verdict=%s\nreason=%s\nattempts=%s\nharness=%s\nmodel=%s\neffort=%s\n' \
    "$verdict" "$reason" "$attempts" "$harness" "$model" "$effort"
  [ -z "$account_profile" ] || printf 'account_profile=%s\n' "$account_profile"
}

escalate_main() {
  local id='' class=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --class)
        [ $# -ge 2 ] && [ -n "$2" ] || escalate_usage
        class=$2; shift 2 ;;
      --class=*)
        class=${1#--class=}
        [ -n "$class" ] || escalate_usage
        shift ;;
      --*) escalate_usage ;;
      *)
        if [ -z "$id" ]; then id=$1; shift; else escalate_usage; fi ;;
    esac
  done
  case "$id" in
    ''|*/*|*..*) escalate_usage ;;
  esac
  case "$class" in
    substantive|injection|mechanical) ;;
    *) escalate_usage ;;
  esac
  # Only the ladder needs the lock helpers, and sourcing the wake library has
  # side effects (state dir creation, a uname fork), so the bare detection
  # query - which fm-wake-lib.sh itself shells out to - stays free of them.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-launch-axis-lib.sh
  . "$SCRIPT_DIR/fm-launch-axis-lib.sh"
  # shellcheck source=bin/fm-claude-account-profile-lib.sh
  . "$SCRIPT_DIR/fm-claude-account-profile-lib.sh"
  escalate_task "$id" "$class"
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  secondmate-source) resolve_secondmate_source ;;
  secondmate-tuple) resolve_secondmate_tuple ;;
  secondmate-tuple-facts) resolve_secondmate_tuple_facts ;;
  escalate) shift; escalate_main "$@" ;;
  *) detect_own ;;
esac
