#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with a configurable model provider, opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#   fm-dispatch-resolve.sh --supports-credential-source <source>
#
# Opt-in gate: FM_DISPATCH_PROVIDER and FM_DISPATCH_MODEL select the provider
#   and model from the environment or $FM_HOME/.env (environment wins). With no
#   provider set, retain the original typesafe.ai/jev-latest key gate exactly.
#   OpenRouter and OpenAI require both their provider selection and a model.
#   The generic systemone provider requires a model and FM_DISPATCH_BASE_URL
#   (http:// or https://) and posts to <base>/v1/systemone; its optional
#   FM_DISPATCH_API_KEY, when absent, means no Authorization header. The openai
#   provider maps the System One request to OpenAI's Decisions API and maps its
#   answer back before validation. The typesafe and openrouter keys come from the
#   environment, else $FM_HOME/.env, else the credential source declared for that
#   provider (below); the openai and systemone keys come from the environment or
#   $FM_HOME/.env only. The selected key lives in a non-exported shell variable
#   and reaches curl through fd 3, never argv, logs, or child environments.
#
# Credential source declaration: the optional $CONFIG/dispatch-credential-sources.json
#   ($CONFIG is FM_CONFIG_OVERRIDE, else $FM_HOME/config) is a JSON object keyed
#   by provider (typesafe or openrouter). Each value says where that provider's
#   key lives and holds no key: {"source": "macos-keychain", "service": "<name>",
#   "account": "<name>"}, where account is optional and no other field is
#   accepted. bin/fm-credential-source-lib.sh owns the schema and its adapters;
#   macos-keychain reads the generic-password item with `security
#   find-generic-password -s <service> [-a <account>] -w`, so only the service
#   and account reach argv. The file is read only when neither the environment
#   nor .env supplied a key, and only the selected provider's entry is used.
#   With no entry for that provider and no key the tool is off as above. An
#   unreadable or invalid file exits 2 naming the problem, never a value. A
#   declared source this host cannot run, or that yields no key within
#   5 seconds, is an error outcome ending "nothing sent", with no network or
#   quota call, so it is not mistaken for an unconfigured resolver.
#
# Capability probe: --supports-credential-source <source> prints "supported"
#   and exits 0, or prints "unsupported" and exits 1, for a source name such as
#   macos-keychain on this host. It reads no declaration, retrieves no
#   credential, and runs no credential tool, so a configuration installer can
#   refuse an unsupported activation before it writes anything.
#
# What it does when on with at least one rule: one POST with the project name and the brief's
#   `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a
#   scout brief (the whole brief when it has neither section), as state and
#   ONE Choice question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. The provider
#   returns the matched rule, a probability per option, and a confidence. Everything
#   after that is jq: the confidence floor (0.6 on the answer confidence, or a
#   rule's declared `min_confidence` on that rule's probability, falling to the
#   most probable other option that clears its own floor), the rule's declared
#   `approval` and `floor`, each profile's declared `provider` and `floor`, the
#   quota rows from ONE quota-axi --json snapshot (schema 5 or 6; each
#   candidate binds to one row through quota_row in
#   bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/...
#   reads its own account's row and an expanded provider with no row for the
#   candidate is unmeasured, never blocked), then the optional preferred_provider
#   family restriction before spendPriority ranks the remaining candidates.
#   An eligible but wholly unrankable preferred family escalates rather than
#   authorizing another family.
#   The model never sees quota, catalogs, approvals, preferred_provider,
#   confidence floors, `why`, or `use`. With no rules, it returns a non-clear
#   result so firstmate keeps using the existing intake.
#
# Shared-quota opt-out: an optional top-level "shared_quota": true in the
#   rules file declares this home draws every provider's usage from one single
#   shared budget, so per-provider quota rows do not describe what is left.
#   With it set, this tool makes no quota-axi call, applies no quota floor or
#   runway gate, ranks nothing by spendPriority, and resolves the matched
#   rule's `use` profiles in declared order; preferred_provider still narrows
#   the pool; declared order then picks within it. Every candidate line still
#   prints, stating quota ranking is off by home declaration. Without the
#   setting, behavior is unchanged. The declared value must be a boolean;
#   anything else is an actionable configuration error.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, the endpoint URL and every string value of the final
#   provider-specific request body (and of any JSON text a string carries) are
#   checked against it before the POST. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most
#   the list line number, never its value, prints nothing on stdout, and exits
#   0 with no network or quota call, exactly like the absent-key off path.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     preferred_provider: <family and preference or fallback decision, when applied>
#     candidate: <harness>:<model> provider=.. scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#        (with the shared-quota opt-out: <harness>:<model> provider=.. -> eligible (quota ranking off: home declares a single shared quota))
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, quota-axi, or declared credential source failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, an unreadable or invalid
#   credential source declaration, missing jq, an unknown provider, a selected
#   non-typesafe provider without a model, or systemone without a valid base
#   URL), which is actionable, never selected around.
#   The capability probe is the one other exit: 1 for an unsupported source.
#
# Environment:
#   FM_DISPATCH_PROVIDER, FM_DISPATCH_MODEL, FM_DISPATCH_BASE_URL,
#   FM_DISPATCH_API_KEY, TYPESAFE_API_KEY, OPENROUTER_API_KEY, and
#   OPENAI_API_KEY are read from the environment or $FM_HOME/.env.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY
OPENROUTER_API_KEY_PRIVATE=${OPENROUTER_API_KEY:-}
export -n OPENROUTER_API_KEY_PRIVATE 2>/dev/null || true
unset OPENROUTER_API_KEY
OPENAI_API_KEY_PRIVATE=${OPENAI_API_KEY:-}
export -n OPENAI_API_KEY_PRIVATE 2>/dev/null || true
unset OPENAI_API_KEY
DISPATCH_API_KEY_PRIVATE=${FM_DISPATCH_API_KEY:-}
export -n DISPATCH_API_KEY_PRIVATE 2>/dev/null || true
unset FM_DISPATCH_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-credential-source-lib.sh
. "$SCRIPT_DIR/fm-credential-source-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
OR_BASE=https://openrouter.ai/api
OR_TIMEOUT=10
SO_TIMEOUT=10
OA_BASE=https://api.openai.com
OA_TIMEOUT=10
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
no_rules() {
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
emit_error() {
  local reason=$1
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
CRED_PATH="$CONFIG/dispatch-credential-sources.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --supports-credential-source)
      [ $# -ge 2 ] || die "--supports-credential-source needs a value"
      if fm_credsrc_supported "$2"; then echo supported; exit 0; fi
      echo unsupported; exit 1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
# declared_key <provider> <private variable>: set the variable from the source
# $CRED_PATH declares for <provider>. Returns 1 when none is declared, which
# leaves the off gate in charge. Past that point nothing is mistaken for an
# unconfigured resolver: an unreadable or invalid declaration is a
# configuration error, and a declared source this host cannot run or that
# yields no key is an error outcome. Nothing is sent in either case.
declared_key() {
  local provider=$1 src problem value rc
  [ -e "$CRED_PATH" ] || [ -L "$CRED_PATH" ] || return 1
  [ -r "$CRED_PATH" ] || die "credential source declaration not readable: $CRED_PATH"
  command -v jq >/dev/null 2>&1 || die "jq required"
  problem=$(fm_credsrc_check "$CRED_PATH" typesafe openrouter) \
    || die "malformed credential source declaration: $CRED_PATH - $problem"
  fm_credsrc_declares "$CRED_PATH" "$provider" || return 1
  src=$(fm_credsrc_field "$CRED_PATH" "$provider" source)
  fm_credsrc_supported "$src" \
    || emit_error "credential source $src declared for $provider is not supported on this host; nothing sent"
  value=$(fm_credsrc_read "$CRED_PATH" "$provider"); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
    if fm_timed_out "$rc"; then
      emit_error "credential source $src declared for $provider did not answer in time; nothing sent"
    fi
    emit_error "credential source $src declared for $provider is unavailable; nothing sent"
  fi
  printf -v "$2" '%s' "$value"
}

# select_key <provider> <KEY_NAME> <private variable>: the selected provider's
# key is the environment copy already in the variable, else KEY_NAME in
# $FM_HOME/.env, else the source declared for the provider. With none of them
# the tool is off, exactly as it was before declarations existed.
select_key() {
  local provider=$1 name=$2 var=$3
  [ -n "${!var}" ] || printf -v "$var" '%s' "$(fmx_env_get "$name" "$FM_HOME/.env")"
  [ -n "${!var}" ] || declared_key "$provider" "$var"
  if [ -z "${!var}" ]; then
    echo "dispatch-resolve: off ($name absent from the environment and $FM_HOME/.env)" >&2
    exit 0
  fi
}

DISPATCH_PROVIDER=${FM_DISPATCH_PROVIDER:-}
[ -n "$DISPATCH_PROVIDER" ] || DISPATCH_PROVIDER=$(fmx_env_get FM_DISPATCH_PROVIDER "$FM_HOME/.env")
DISPATCH_MODEL=${FM_DISPATCH_MODEL:-}
[ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=$(fmx_env_get FM_DISPATCH_MODEL "$FM_HOME/.env")
case "$DISPATCH_PROVIDER" in
  '')
    DISPATCH_PROVIDER=typesafe
    DISPATCH_MODEL=$TS_MODEL
    select_key typesafe TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
    ;;
  typesafe)
    [ -n "$DISPATCH_MODEL" ] || DISPATCH_MODEL=$TS_MODEL
    select_key typesafe TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
    ;;
  openrouter)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openrouter"
    select_key openrouter OPENROUTER_API_KEY OPENROUTER_API_KEY_PRIVATE
    ;;
  systemone)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=systemone"
    DISPATCH_BASE_URL=${FM_DISPATCH_BASE_URL:-}
    [ -n "$DISPATCH_BASE_URL" ] || DISPATCH_BASE_URL=$(fmx_env_get FM_DISPATCH_BASE_URL "$FM_HOME/.env")
    [ -n "$DISPATCH_BASE_URL" ] || die "FM_DISPATCH_BASE_URL required when FM_DISPATCH_PROVIDER=systemone"
    case "$DISPATCH_BASE_URL" in
      http://?*|https://?*) ;;
      *) die "FM_DISPATCH_BASE_URL must start with http:// or https://" ;;
    esac
    DISPATCH_BASE_URL=${DISPATCH_BASE_URL%/}
    # The key is optional: a local host may need none.
    [ -n "$DISPATCH_API_KEY_PRIVATE" ] || DISPATCH_API_KEY_PRIVATE=$(fmx_env_get FM_DISPATCH_API_KEY "$FM_HOME/.env")
    ;;
  openai)
    [ -n "$DISPATCH_MODEL" ] || die "FM_DISPATCH_MODEL required when FM_DISPATCH_PROVIDER=openai"
    [ -n "$OPENAI_API_KEY_PRIVATE" ] || OPENAI_API_KEY_PRIVATE=$(fmx_env_get OPENAI_API_KEY "$FM_HOME/.env")
    if [ -z "$OPENAI_API_KEY_PRIVATE" ]; then
      echo "dispatch-resolve: off (OPENAI_API_KEY absent from the environment and $FM_HOME/.env)" >&2
      exit 0
    fi
    ;;
  *) die "unknown FM_DISPATCH_PROVIDER: $DISPATCH_PROVIDER (expected typesafe, openrouter, systemone, or openai)" ;;
esac
case "$DISPATCH_PROVIDER" in
  typesafe) ENDPOINT=$TS_BASE/v1/systemone TIMEOUT=$TS_TIMEOUT KEY_PRIVATE=$TYPESAFE_API_KEY_PRIVATE ;;
  openrouter) ENDPOINT=$OR_BASE/alpha/decisions TIMEOUT=$OR_TIMEOUT KEY_PRIVATE=$OPENROUTER_API_KEY_PRIVATE ;;
  systemone) ENDPOINT=$DISPATCH_BASE_URL/v1/systemone TIMEOUT=$SO_TIMEOUT KEY_PRIVATE=$DISPATCH_API_KEY_PRIVATE ;;
  openai) ENDPOINT=$OA_BASE/v1/decisions TIMEOUT=$OA_TIMEOUT KEY_PRIVATE=$OPENAI_API_KEY_PRIVATE ;;
esac
export -n KEY_PRIVATE 2>/dev/null || true

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("preferred_provider") and (provider_id(.preferred_provider) | not) then "preferred_provider must be a lowercase provider ID (for example codex)"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif has("shared_quota") and (.shared_quota | type) != "boolean" then "shared_quota must be true or false when present"
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
  fi
done)
if [ -n "$missing_provider" ]; then
  missing_provider_detail=''
  while IFS=$'\t' read -r location harness; do
    missing_provider_detail="${missing_provider_detail:+$missing_provider_detail; }$location profiles whose harness lacks one authoritative provider family require provider: $harness"
  done <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $missing_provider_detail"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

if [ "$RULE_COUNT" -eq 0 ]; then
  no_rules
fi

RESP_FILE=$(mktemp) || die "mktemp failed"
QUOTA=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$QUOTA" "$TASK_TEXT"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$RESP_FILE" "$QUOTA" "$TASK_TEXT" "$SEND_TEXT"' EXIT

never_send_off() {
  echo "dispatch-resolve: off ($1; nothing sent)" >&2
  exit 0
}

# Checks the endpoint and every string the final request body carries,
# including strings inside JSON text such as OpenAI's serialized input, so no
# text reaches the network unchecked. grep's own stderr is discarded because
# it can echo the pattern.
never_send_check() {
  local list value n=0 rc
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; } \
    || never_send_off "$NEVER_SEND_PATH is not a readable regular file"
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  jq -r --arg endpoint "$ENDPOINT" '
    $endpoint, (.. | strings | ., (try (fromjson | .. | strings) catch empty))
    | gsub("\\s+"; " ")' <<<"$BODY" > "$SEND_TEXT" 2>/dev/null \
    || never_send_off "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null) \
    || never_send_off "could not read $NEVER_SEND_PATH"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) never_send_off "brief text matches $NEVER_SEND_PATH line $n" ;;
      1) ;;
      *) never_send_off "could not check the request text against $NEVER_SEND_PATH line $n" ;;
    esac
  done <<<"$list"
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
SECTIONS=$(task_sections)
if [ -n "$SECTIONS" ]; then
  { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
else
  cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
fi
LAT_MS=null
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
  REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$DISPATCH_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        }
      }
    }')
  # OpenAI's Decisions API takes text input and a named choices array, so the
  # same state and Choice question are rewritten into its shape.
  if [ "$DISPATCH_PROVIDER" = openai ]; then
    BODY=$(jq -c '{
      model,
      input: (.state | tojson),
      questions: [{
        type: "choice", name: "rule", instructions: .questions.rule.instructions,
        choices: [.questions.rule.criteria | to_entries[] | {value: .key, description: .value}]
      }]
    }' <<<"$REQUEST") || emit_error "could not build the OpenAI request"
  else
    BODY=$REQUEST
  fi
  never_send_check
  T0=$(fm_timing_now_ms)
  if [ -n "$KEY_PRIVATE" ]; then
    HTTP=$(printf '%s' "$BODY" | curl -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$KEY_PRIVATE") \
      --data-binary @- 2>/dev/null) || HTTP=000
  else
    HTTP=$(printf '%s' "$BODY" | curl -sS --max-time "$TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null) || HTTP=000
  fi
  T1=$(fm_timing_now_ms)
  LAT_MS=$(( T1 - T0 ))
  if [ "$DISPATCH_PROVIDER" = typesafe ]; then
    [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
  else
    [ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms"
  fi
  # Map an OpenAI answer back to the System One shape the shared validation
  # below checks. A refusal, a missing or duplicated rule answer, or duplicated
  # option values is not a rule Choice answer. Usage is display-only, so it is
  # kept only when both token counts are numeric.
  if [ "$DISPATCH_PROVIDER" = openai ]; then
    jq -e '
      (.answers | type) == "array" and
      ([.answers[] | select(type == "object" and .name == "rule")]) as $rule |
      ($rule | length) == 1 and $rule[0].type == "choice" and
      ($rule[0].probabilities | type) == "array" and
      all($rule[0].probabilities[]; type == "object" and (.value | type) == "string") and
      ($rule[0].probabilities | map(.value) | length) == ($rule[0].probabilities | map(.value) | unique | length)' \
      "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"
    if ! jq --arg model "$DISPATCH_MODEL" '
      ([.answers[] | select(type == "object" and .name == "rule")][0]) as $a |
      {
        model: (if (.model | type) == "string" then .model else $model end),
        answers: {rule: {
          choice: $a.choice, confidence: $a.confidence,
          probabilities: ($a.probabilities | map({key: .value, value: .probability}) | from_entries)
        }}
      }
      + (if (.usage.input_tokens | type) == "number" and (.usage.output_tokens | type) == "number"
         then {usage: {input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens}} else {} end)' \
      "$RESP_FILE" > "$RESP_FILE.mapped" 2>/dev/null || ! mv "$RESP_FILE.mapped" "$RESP_FILE"; then
      rm -f "$RESP_FILE.mapped"
      emit_error "response is not a rule Choice answer"
    fi
  fi
jq -e --slurpfile rules "$RULES" '
    (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
    (.answers.rule.choice | type) == "string" and
    (.answers.rule.confidence | type) == "number" and
    .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
    (.answers.rule.probabilities | type) == "object" and
    ((.answers.rule.probabilities | keys | sort) == $choices) and
    all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and
       (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a rule Choice answer"

# ---- quota evidence: one quota-axi --json snapshot, skipped entirely under the
# ---- shared-quota opt-out (a stub keeps the slurpfile contract intact) ---------
SQ=false
SHARED_QUOTA=$(jq -r '.shared_quota // false' "$RULES" 2>/dev/null) || SHARED_QUOTA=false
if [ "$SHARED_QUOTA" = true ]; then
  printf '{"providers":[]}\n' > "$QUOTA"
  SQ=true
else
  command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
  quota-axi --json > "$QUOTA" 2>/dev/null || emit_error "quota-axi --json failed"
  fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"
fi

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" --argjson sq "$SQ" \
  --slurpfile resp "$RESP_FILE" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" "$FM_QUOTA_ROW_JQ"'
  ($resp[0]) as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($r.answers.rule) as $a |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p; $lane): quota_row($q; $p; $lane);
  def rows($p; $lane): (prov($p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def measured($p; $lane):
    (prov($p; $lane) != null and (["known", "partial"] | index(prov($p; $lane).quotaSemantics.status)) != null);
  def applicable($p; $lane; $m):
    (bare($m)) as $bare |
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if $sq then
      {profile: $c, provider: $p, eligible: true, sq: true, reason: "ok"}
    elif $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true,
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      (applicable($p; $lane; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
  def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
  ($a.choice) as $picked |
  (confidence_floor($picked)) as $picked_floor |
  # A declared floor is checked against the probability of that option whether
  # it is the pick or a runner-up, so a runner-up never needs weaker support
  # than it would as the pick. Only a rule that declares its own floor falls
  # through to a runner-up, so a file with no declared floors keeps the single
  # global floor on the answer confidence exactly.
  (if declared_confidence($picked) | not then
     (if $a.confidence >= $picked_floor then {below: false} else {below: true, global: true} end)
   elif $a.probabilities[$picked] >= $picked_floor then {below: false}
   else
     ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
       | sort_by(-.value)) as $ok |
     if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
     elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
     else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
   end) as $fb |
  (if $fb.to then $fb.to else $picked end) as $choice |
  (rule_at($choice)) as $rule |
  (if $sq or $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider; "") end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unknown" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $picked,
    rule_when: when_of($picked),
    confidence: $a.confidence, probabilities: $a.probabilities
  }
  + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end)
  as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $fb.below and $fb.global then
    $ev + {status: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)", candidates: ($answer_use | map(evaluate(.)))}
  elif $fb.below and ($fb.to | not) then
    $ev + {status: "ambiguous", reason: "\($picked) probability \($a.probabilities[$picked]) below its floor \($picked_floor); \($fb.why)", candidates: ($answer_use | map(evaluate(.)))}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: ($answer_use | map(evaluate(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(evaluate(.))) as $cands |
    ([$cands[] | select(.provider == $cfg.preferred_provider)]) as $family |
    ([$family[] | select(.eligible)]) as $preferred |
    (if ($preferred | length) > 0 then $preferred else $cands end) as $pool |
    ($ev + (if $cfg.preferred_provider == null then {}
      else {preferred_provider: ($cfg.preferred_provider + ": " +
        (if ($family | length) == 0 then "not in matched profiles; preserve the selected rule"
         elif ($preferred | length) > 0 then "prefer eligible family candidates"
         else "fall back; every matched family candidate is ineligible" end))} end)) as $ev |
    ([$pool[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate",
      reason: ("no rankable eligible candidate" +
        (if ($preferred | length) > 0 then " in preferred provider \($cfg.preferred_provider); uncertainty does not authorize fallback" else "" end)),
      note: $sel.note, candidates: $cands}
    else
      (if $sq then ($elig | first) else ($elig | max_by(.spendPriority)) end) as $best |
      (if $sq then 1 else ([$elig[] | select(.spendPriority == $best.spendPriority)] | length) end) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .preferred_provider then "  preferred_provider: \(.preferred_provider | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .sq then "eligible (quota ranking off: home declares a single shared quota)" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
