#!/usr/bin/env bash
# fm-local-model.sh - the ONE owner of local OpenAI/Anthropic-compatible
# endpoint facts for the claude-local adapter (an LM Studio server by default).
#
# Usage: fm-local-model.sh probe
#        fm-local-model.sh model-state <model>
#        fm-local-model.sh context-budget <model>
#        fm-local-model.sh headroom <model>
#        fm-local-model.sh preflight <model>
#        fm-local-model.sh check <model>
#        fm-local-model.sh brief-fits <model> <brief-path>
#
# Endpoint: $FM_LOCAL_MODEL_ENDPOINT, default http://127.0.0.1:1234.
# Ceiling:  $FM_LOCAL_MODEL_MAX_CONTEXT, default 131072 tokens (see "Why a
#           ceiling" below). A value of 0 or a non-integer is refused rather
#           than silently treated as unbounded.
# Baseline: $FM_LOCAL_MODEL_HARNESS_BASELINE, default 60000 tokens - what the
#           harness itself occupies before any task content (see "The baseline
#           is the real boundary").
#
# Exit codes are the contract every caller reads:
#   0  ok
#   2  usage error
#   3  endpoint unreachable (server off, wrong port, or not answering)
#   4  model absent from the endpoint's catalog, or present but not loaded
#   5  the endpoint answered but its catalog could not be parsed
#   6  the brief exceeds the enforced context budget (brief-fits only)
#   7  the model's window has no usable headroom above the harness baseline
#
# WHY THE CATALOG IS THE ONLY MODEL-IDENTITY SOURCE
# Verified against LM Studio 2026-09-01: a POST to /v1/messages carrying a model
# id that is NOT loaded ("definitely-not-loaded-xyz") returned HTTP 200 and was
# answered by the loaded model, with the response's own "model" field naming the
# loaded model rather than the requested one. The request path therefore cannot
# tell "my model is serving" from "some other model is serving", and it can never
# report an eviction. GET /api/v0/models is the authoritative source: it reports a
# per-model "state" of loaded|not-loaded plus the loaded context length. Every
# health verdict here reads that catalog and nothing else.
#
# WHY A CEILING
# The captain's constraint is short-context work only. On the reference machine
# (Apple M1 Max, 64 GB) the model occupies ~41.7 GiB, context memory is charged on
# top of that, and prefill is compute-bound: a single trivial Claude Code turn
# measured 153s wall clock, and a two-turn tool-using exchange measured 309s
# (docs/verification/runtime-backends.md, "claude-local"). Cost grows with the
# prompt, so an unbounded window on this runtime degrades into minutes-per-turn
# rather than failing. The ceiling is a hard bound firstmate applies on top of
# whatever the server reports, so loading a very wide window can never by itself
# turn this into a long-context runtime.
#
# THE BASELINE IS THE REAL BOUNDARY
# The ceiling alone would be theatre, because the dominant consumer of this
# window is not the task - it is the harness. Captured from LM Studio's own
# request log on 2026-09-01, a single `claude -p` turn carrying a one-sentence
# prompt sent ~250 KB of prompt, roughly 60k tokens, before any task content:
# Claude Code's system prompt and full tool schema. Against the 65,536-token
# window the reference model had loaded, that baseline is ~96% of the window.
# So the number that decides whether a task can run here is the HEADROOM above
# that baseline, not the window. `headroom` computes it and `brief-fits` spends
# a bounded share of it; a window with no headroom is refused outright with the
# one action that fixes it, rather than accepted and then silently compacted.
set -u

ENDPOINT=${FM_LOCAL_MODEL_ENDPOINT:-http://127.0.0.1:1234}
DEFAULT_CEILING=131072

die_usage() { echo "usage: fm-local-model.sh probe|model-state|context-budget|headroom|preflight|check|brief-fits [args]" >&2; exit 2; }

# Print the configured ceiling, refusing a value that is not a positive integer
# so a typo can never read as "no limit".
ceiling() {
  local c=${FM_LOCAL_MODEL_MAX_CONTEXT:-$DEFAULT_CEILING}
  case "$c" in
    ''|*[!0-9]*) echo "error: FM_LOCAL_MODEL_MAX_CONTEXT must be a positive integer (got '$c')" >&2; exit 2 ;;
  esac
  [ "$c" -gt 0 ] || { echo "error: FM_LOCAL_MODEL_MAX_CONTEXT must be greater than zero" >&2; exit 2; }
  printf '%s\n' "$c"
}

# Fetch the endpoint catalog. Prints the raw body on success; exit 3 when the
# endpoint does not answer within the bounded timeout.
catalog() {
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required to reach the local model endpoint" >&2; exit 3; }
  local body
  body=$(curl -fsS -m "${FM_LOCAL_MODEL_TIMEOUT:-10}" "$ENDPOINT/api/v0/models" 2>/dev/null) || exit 3
  [ -n "$body" ] || exit 3
  printf '%s' "$body"
}

# Print "<state> <loaded_context_length>" for one model id, read from the
# catalog. Prints "absent 0" when the catalog does not list the id at all.
# python3 parses the JSON because the catalog is nested and a grep would
# mis-attribute a field to the wrong model once more than one is listed.
catalog_lookup() {  # <model> <catalog-json>
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required to read the endpoint catalog" >&2; exit 5; }
  FM_LM_MODEL=$1 python3 -c '
import json, os, sys
want = os.environ["FM_LM_MODEL"]
try:
    doc = json.load(sys.stdin)
    entries = doc["data"]
except Exception:
    sys.exit(5)
for e in entries:
    if not isinstance(e, dict) or e.get("id") != want:
        continue
    state = e.get("state") or "unknown"
    ctx = e.get("loaded_context_length") or e.get("max_context_length") or 0
    try:
        ctx = int(ctx)
    except (TypeError, ValueError):
        ctx = 0
    print(state, ctx)
    sys.exit(0)
print("absent", 0)
' <<EOF
$2
EOF
}

cmd_probe() {
  catalog >/dev/null
  printf 'ok: %s is answering\n' "$ENDPOINT"
}

cmd_model_state() {  # <model>
  local body row
  body=$(catalog) || exit $?
  row=$(catalog_lookup "$1" "$body") || exit $?
  printf '%s\n' "${row%% *}"
}

# The enforced budget: the smaller of what the server actually loaded and the
# firstmate ceiling. Refuses rather than guessing when the model is not loaded,
# because an unloaded model reports no meaningful window.
cmd_context_budget() {  # <model>
  local body row state ctx cap
  body=$(catalog) || exit $?
  row=$(catalog_lookup "$1" "$body") || exit $?
  state=${row%% *}; ctx=${row##* }
  [ "$state" = loaded ] || exit 4
  cap=$(ceiling) || exit $?
  if [ "$ctx" -gt 0 ] && [ "$ctx" -lt "$cap" ]; then printf '%s\n' "$ctx"; else printf '%s\n' "$cap"; fi
}

cmd_preflight() {  # <model>
  local body row state budget room
  if ! body=$(catalog); then
    cat >&2 <<EOF
error: the local model endpoint at $ENDPOINT is not answering.
       Start the server (LM Studio Developer tab, or 'lms server start') and retry.
       Set FM_LOCAL_MODEL_ENDPOINT to point at a different host or port.
EOF
    exit 3
  fi
  row=$(catalog_lookup "$1" "$body") || exit $?
  state=${row%% *}
  case "$state" in
    loaded) : ;;
    absent)
      echo "error: the local model endpoint at $ENDPOINT does not list a model named '$1'." >&2
      echo "       Load it first ('lms load $1'), or pass the exact id the endpoint reports." >&2
      exit 4 ;;
    *)
      cat >&2 <<EOF
error: the local model '$1' is listed but not loaded (state: $state).
       LM Studio unloads an idle model on its own TTL and auto-evict settings, so
       this is the expected state after the model has been idle. Load it with
       'lms load $1' and retry.
EOF
      exit 4 ;;
  esac
  budget=$(cmd_context_budget "$1") || exit $?
  room=$(cmd_headroom "$1") || exit $?
  printf 'ok: %s loaded at %s, enforced context budget %s tokens, %s usable after the harness prompt\n' "$1" "$ENDPOINT" "$budget" "$room"
}

# The watcher poll body. Prints exactly one line when firstmate should wake and
# nothing at all otherwise, per the custom-check contract in AGENTS.md section 7.
# Both wake conditions are the failure class this adapter exists to make loud:
# a worker pointed at a dead endpoint or an evicted model otherwise stalls
# silently, because Claude Code retries rather than exiting.
cmd_check() {  # <model>
  local body row state
  if ! body=$(catalog 2>/dev/null); then
    printf 'blocked: the local model server at %s stopped answering; the worker cannot make progress until it is running again\n' "$ENDPOINT"
    return 0
  fi
  row=$(catalog_lookup "$1" "$body" 2>/dev/null) || return 0
  state=${row%% *}
  [ "$state" = loaded ] && return 0
  printf 'blocked: the local model %s is no longer loaded at %s (state: %s); the worker cannot make progress until it is loaded again\n' "$1" "$ENDPOINT" "$state"
}

# The tokens the harness itself occupies before any task content. Configurable
# because it is a measured property of the harness version, not a constant.
baseline() {
  local b=${FM_LOCAL_MODEL_HARNESS_BASELINE:-60000}
  case "$b" in
    ''|*[!0-9]*) echo "error: FM_LOCAL_MODEL_HARNESS_BASELINE must be a non-negative integer (got '$b')" >&2; exit 2 ;;
  esac
  printf '%s\n' "$b"
}

# Usable tokens = budget - harness baseline. Exits 7 when the window cannot even
# hold the harness, which is a real configuration this runtime hits by default.
cmd_headroom() {  # <model>
  local budget base room
  budget=$(cmd_context_budget "$1") || exit $?
  base=$(baseline) || exit $?
  room=$(( budget - base ))
  if [ "$room" -le 0 ]; then
    cat >&2 <<EOF
error: the local model '$1' has no usable context headroom.
       Its enforced budget is $budget tokens and the harness itself occupies about
       $base before any task content, leaving $room.
       Raise the model's loaded context length in LM Studio (its maximum is well
       above what is loaded now) and retry, or run this task on a hosted runtime.
EOF
    exit 7
  fi
  printf '%s\n' "$room"
}

# Refuse a brief that obviously exceeds what is left for the task. The estimate
# is deliberately crude - bytes/4 - because the endpoint implements no
# token-counting route (POST /v1/messages/count_tokens returned "Unexpected
# endpoint or method", verified 2026-09-01), so no exact count is available
# without spending a full prefill. It is compared against
# FM_LOCAL_MODEL_BRIEF_SHARE percent of the HEADROOM (default 25) rather than
# the whole window, because the brief is only the first turn's input: every file
# the worker reads and every later turn is charged against the same headroom.
cmd_brief_fits() {  # <model> <brief-path>
  local model=$1 path=$2 room share bytes est allowed
  [ -f "$path" ] || { echo "error: brief '$path' is not a readable file" >&2; exit 2; }
  room=$(cmd_headroom "$model") || exit $?
  share=${FM_LOCAL_MODEL_BRIEF_SHARE:-25}
  case "$share" in ''|*[!0-9]*) echo "error: FM_LOCAL_MODEL_BRIEF_SHARE must be an integer percent (got '$share')" >&2; exit 2 ;; esac
  { [ "$share" -gt 0 ] && [ "$share" -le 100 ]; } || { echo "error: FM_LOCAL_MODEL_BRIEF_SHARE must be between 1 and 100" >&2; exit 2; }
  bytes=$(wc -c < "$path" | tr -d '[:space:]')
  est=$(( bytes / 4 ))
  allowed=$(( room * share / 100 ))
  if [ "$est" -gt "$allowed" ]; then
    cat >&2 <<EOF
error: this brief is too large for the local model runtime.
       Brief is ~$est tokens; the limit is $allowed (${share}% of the $room tokens
       left after the harness's own prompt).
       claude-local is verified for SHORT-CONTEXT work only. Give this task to a
       hosted runtime, or split it into a smaller brief.
EOF
    exit 6
  fi
  printf 'ok: brief ~%s tokens, within the %s-token allowance\n' "$est" "$allowed"
}

[ "$#" -ge 1 ] || die_usage
CMD=$1; shift
case "$CMD" in
  probe)          [ "$#" -eq 0 ] || die_usage; cmd_probe ;;
  model-state)    [ "$#" -eq 1 ] || die_usage; cmd_model_state "$1" ;;
  context-budget) [ "$#" -eq 1 ] || die_usage; cmd_context_budget "$1" ;;
  headroom)       [ "$#" -eq 1 ] || die_usage; cmd_headroom "$1" ;;
  preflight)      [ "$#" -eq 1 ] || die_usage; cmd_preflight "$1" ;;
  check)          [ "$#" -eq 1 ] || die_usage; cmd_check "$1" ;;
  brief-fits)     [ "$#" -eq 2 ] || die_usage; cmd_brief_fits "$1" "$2" ;;
  *) die_usage ;;
esac
