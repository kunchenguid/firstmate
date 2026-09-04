#!/usr/bin/env bash
# fm-local-model.sh - the ONE owner of local OpenAI/Anthropic-compatible
# endpoint facts for the claude-local adapter (an LM Studio server by default).
#
# Usage: fm-local-model.sh probe
#        fm-local-model.sh list
#        fm-local-model.sh model-state <model>
#        fm-local-model.sh context-budget <model>
#        fm-local-model.sh headroom <model>
#        fm-local-model.sh preflight <model>
#        fm-local-model.sh check <model>
#        fm-local-model.sh brief-fits <model> <brief-path>
#
# Endpoint: $FM_LOCAL_MODEL_ENDPOINT, default http://127.0.0.1:1234. It must
#           use an explicit http:// or https:// scheme with a non-empty loopback
#           authority (127.0.0.0/8, ::1, localhost); a remote or unreadable host
#           is refused. An empty authority is accepted only for file:// catalog
#           fixtures, which reach no host (see "Local means loopback").
# Ceiling:  $FM_LOCAL_MODEL_MAX_CONTEXT, default 131072 tokens (see "Why a
#           ceiling" below). A value of 0 or a non-integer is refused rather
#           than silently treated as unbounded.
# Timeout:  $FM_LOCAL_MODEL_TIMEOUT, default 10 seconds. It must be a positive
#           integer so curl's zero value can never disable the endpoint bound.
# Baseline: $FM_LOCAL_MODEL_HARNESS_BASELINE, default 60000 tokens - what the
#           harness itself occupies before any task content (see "The baseline
#           is the real boundary").
#
# Exit codes are the contract every caller reads:
#   0  ok
#   2  usage error, including an endpoint whose host is not loopback
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
#
# LOCAL MEANS LOOPBACK
# The captain's constraint is LOCAL work. Every caller bakes this endpoint into
# a worker launch as ANTHROPIC_BASE_URL, so the endpoint decides where the task
# brief, the file contents the worker reads, and its whole tool transcript are
# sent. A hostname pointing off the machine would make "local model" a name for
# shipping the repository to a third party, silently and without error. This
# script resolves the endpoint for every caller, so this is where the invariant
# is enforced: the host must be loopback, or an empty authority (a file:// URL,
# which reaches no host at all).
set -u

ENDPOINT=${FM_LOCAL_MODEL_ENDPOINT:-http://127.0.0.1:1234}
DEFAULT_CEILING=131072

die_usage() { echo "usage: fm-local-model.sh probe|list|model-state|context-budget|headroom|preflight|check|brief-fits [args]" >&2; exit 2; }

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

# Print the endpoint deadline, refusing values that curl would interpret as an
# unbounded or malformed timeout. Validate this before dispatch so every public
# command reports a bad local-runtime configuration as such, rather than
# recasting it as an unreachable endpoint or a blocked worker.
timeout_seconds() {
  local t=${FM_LOCAL_MODEL_TIMEOUT:-10}
  case "$t" in
    ''|*[!0-9]*) echo "error: FM_LOCAL_MODEL_TIMEOUT must be a positive integer (got '$t')" >&2; return 2 ;;
  esac
  [ "$t" -gt 0 ] || { echo "error: FM_LOCAL_MODEL_TIMEOUT must be greater than zero" >&2; return 2; }
  printf '%s\n' "$t"
}

# True when the argument is a dotted-quad address in 127.0.0.0/8. Every octet
# is checked so a hostname that merely starts with "127." - 127.evil.example -
# can never pass as loopback.
is_loopback_ipv4() {  # <host>
  local ip=$1 rest o1 o2 o3 o4 part
  case "$ip" in *.*.*.*) ;; *) return 1 ;; esac
  o1=${ip%%.*}; rest=${ip#*.}
  o2=${rest%%.*}; rest=${rest#*.}
  o3=${rest%%.*}; o4=${rest#*.}
  for part in "$o1" "$o2" "$o3" "$o4"; do
    case "$part" in ''|*[!0-9]*) return 1 ;; esac
    [ "$part" -le 255 ] || return 1
  done
  [ "$o1" = 127 ]
}

# The host portion of the configured endpoint. Prints the host and returns 0
# for an endpoint whose authority is a plain host, [IPv6] literal, or either
# with a numeric port; an endpoint with no authority at all (file:///path)
# prints the empty string. ANY other shape returns 1 without printing.
#
# The authority ends at the FIRST '/', '?', '#' or '\'. RFC 3986 gives the
# first three; the WHATWG parser Node and undici use for ANTHROPIC_BASE_URL
# also ends it at a backslash, so in http://evil.example\@127.0.0.1 the host
# every client resolves is evil.example, not the loopback address after the
# '@'.
#
# Naming the delimiters is not enough on its own, because each one only has to
# be missed once for a remote host to read as loopback. So this refuses
# anything it cannot account for rather than stripping userinfo and trusting
# the remainder: a surviving '@' or '\', or any character outside a plain host
# or a bracketed IPv6 literal, is a shape no caller here has any reason to
# configure, and it is rejected instead of parsed.
endpoint_host() {
  local rest host port
  # An explicit scheme is required. Without one, ${ENDPOINT#*://} is a no-op and
  # a protocol-relative //evil.example:1234 truncates to an empty authority,
  # making "no authority" and "an authority this parser never reached"
  # indistinguishable. An empty authority is accepted ONLY under file://, which
  # addresses a path on this machine and reaches no host at all; that is the
  # scheme the portable catalog fixtures in tests/ serve from.
  case "$ENDPOINT" in
    http://*|https://*|file://*) : ;;
    *) return 1 ;;
  esac
  rest=${ENDPOINT#*://}
  rest=${rest%%/*}
  rest=${rest%%\?*}
  rest=${rest%%#*}
  rest=${rest%%\\*}
  if [ -z "$rest" ]; then
    case "$ENDPOINT" in
      file://*) printf '\n'; return 0 ;;
    esac
    return 1
  fi
  case "$rest" in
    \[*\])   host=${rest#\[}; host=${host%\]}; port= ;;
    \[*\]:*) host=${rest#\[}; host=${host%%\]*}; port=${rest##*\]:} ;;
    \[*|*\]*) return 1 ;;
    *:*)     host=${rest%%:*}; port=${rest#*:} ;;
    *)       host=$rest; port= ;;
  esac
  case "$rest" in
    \[*) case "$host" in ''|*[!0-9A-Fa-f:]*) return 1 ;; esac ;;
    *)   case "$host" in ''|*[!0-9A-Za-z._-]*) return 1 ;; esac ;;
  esac
  case "$port" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$host"
}

# The local-only invariant, enforced once for every command that touches the
# endpoint. See "Local means loopback" above.
require_loopback_endpoint() {
  local host status=0
  host=$(endpoint_host) || status=$?
  if [ "$status" -eq 0 ]; then
    case "$host" in
      ''|localhost|::1|0:0:0:0:0:0:0:1) return 0 ;;
    esac
    is_loopback_ipv4 "$host" && return 0
  else
    host='unreadable, not a plain host or host:port'
  fi
  cat >&2 <<EOF
error: the local model endpoint '$ENDPOINT' is not on this machine (host: $host).
       claude-local is a LOCAL runtime: the endpoint receives the task brief,
       every file the worker reads, and its whole tool transcript, so it may only
       be a loopback address - 127.0.0.0/8, ::1, or localhost.
       Point FM_LOCAL_MODEL_ENDPOINT at a loopback address (default
       http://127.0.0.1:1234), or run this task on a hosted runtime.
EOF
  exit 2
}

# Fetch the endpoint catalog. Prints the raw body on success; exit 3 when the
# endpoint does not answer within the bounded timeout.
catalog() {
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required to reach the local model endpoint" >&2; exit 3; }
  local body
  body=$(curl -fsS -m "$TIMEOUT" "$ENDPOINT/api/v0/models" 2>/dev/null) || exit 3
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
# A body that parses but is not shaped like a catalog must take the unreadable
# path, NOT the absent-model path. Without this, {"data":{}} iterates an empty
# dict, returns "absent", and check reports "no longer loaded" - a confidently
# wrong diagnosis that sends the operator to reload a model when the real fault
# is that something other than the model server is answering on that port.
if not isinstance(entries, list):
    sys.exit(5)
for e in entries:
    if not isinstance(e, dict) or e.get("id") != want:
        continue
    state = e.get("state") or "unknown"
    ctx = e.get("loaded_context_length") or 0
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

# Print every model id the endpoint serves, one per line, each with its load
# state. This exists because `probe` only proves the endpoint answers and emits
# no ids, so a refusal that points an operator at `probe` to find a model id is
# not actionable. Keeping the listing here keeps this script the single owner of
# endpoint facts.
cmd_list() {
  local body
  body=$(catalog) || exit $?
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required to read the endpoint catalog" >&2; exit 5; }
  python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
    entries = doc["data"]
except Exception:
    sys.exit(5)
if not isinstance(entries, list):
    sys.exit(5)
for e in entries:
    if isinstance(e, dict) and e.get("id"):
        print("%s\t%s" % (e["id"], e.get("state") or "unknown"))
' <<EOF
$body
EOF
}

cmd_model_state() {  # <model>
  local body row
  body=$(catalog) || exit $?
  row=$(catalog_lookup "$1" "$body") || exit $?
  printf '%s\n' "${row%% *}"
}

# The enforced budget: the smaller of what the server actually loaded and the
# firstmate ceiling. Refuses rather than guessing when the model is not loaded
# or does not report a positive loaded window.
cmd_context_budget() {  # <model>
  local body row state ctx cap
  body=$(catalog) || exit $?
  row=$(catalog_lookup "$1" "$body") || exit $?
  state=${row%% *}; ctx=${row##* }
  [ "$state" = loaded ] || exit 4
  if [ "$ctx" -le 0 ]; then
    echo "error: the local model '$1' is loaded but reports no positive loaded context length." >&2
    echo "       Reload it in LM Studio with a positive context length, then retry." >&2
    exit 4
  fi
  cap=$(ceiling) || exit $?
  if [ "$ctx" -gt 0 ] && [ "$ctx" -lt "$cap" ]; then printf '%s\n' "$ctx"; else printf '%s\n' "$cap"; fi
}

cmd_preflight() {  # <model>
  local body row state budget room
  if ! body=$(catalog); then
    cat >&2 <<EOF
error: the local model endpoint at $ENDPOINT is not answering.
       Start the server (LM Studio Developer tab, or 'lms server start') and retry.
       Set FM_LOCAL_MODEL_ENDPOINT to a different loopback port if it serves elsewhere.
EOF
    exit 3
  fi
  row=$(catalog_lookup "$1" "$body") || exit $?
  state=${row%% *}
  case "$state" in
    loaded) : ;;
    absent)
      echo "error: the local model endpoint at $ENDPOINT does not list a model named '$1'." >&2
      echo "       Load it first ('lms load $1'), or pass an id from: fm-local-model.sh list" >&2
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
  if ! row=$(catalog_lookup "$1" "$body" 2>/dev/null); then
    printf 'blocked: the local model endpoint at %s answered with an unreadable catalog; verify that LM Studio is serving /api/v0/models before the worker can make progress\n' "$ENDPOINT"
    return 0
  fi
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
# Every command below reads the endpoint, so the local-only invariant is checked
# once here rather than inside catalog(): `check` swallows catalog failures to
# print its own wake line, and a misconfigured endpoint must not be reported to
# the operator as a server that stopped answering.
require_loopback_endpoint
TIMEOUT=$(timeout_seconds) || exit $?
case "$CMD" in
  probe)          [ "$#" -eq 0 ] || die_usage; cmd_probe ;;
  list)           [ "$#" -eq 0 ] || die_usage; cmd_list ;;
  model-state)    [ "$#" -eq 1 ] || die_usage; cmd_model_state "$1" ;;
  context-budget) [ "$#" -eq 1 ] || die_usage; cmd_context_budget "$1" ;;
  headroom)       [ "$#" -eq 1 ] || die_usage; cmd_headroom "$1" ;;
  preflight)      [ "$#" -eq 1 ] || die_usage; cmd_preflight "$1" ;;
  check)          [ "$#" -eq 1 ] || die_usage; cmd_check "$1" ;;
  brief-fits)     [ "$#" -eq 2 ] || die_usage; cmd_brief_fits "$1" "$2" ;;
  *) die_usage ;;
esac
