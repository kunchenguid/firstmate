#!/usr/bin/env bash
# fm-dispatch-policy.sh - validates and reads the versioned crew dispatch policy.
# Operator schema: docs/configuration.md "Crew dispatch profiles".
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$ROOT}/config}
POLICY_ENVELOPE=

usage() {
  echo 'usage: fm-dispatch-policy.sh validate|mode|limits|profile|describe ...' >&2
  exit 2
}

policy_fail() {
  printf 'invalid dispatch policy: %s\n' "$1" >&2
  return 1
}

policy_snapshot() {
  local source=$1 envelope rc
  command -v node >/dev/null 2>&1 || {
    policy_fail dependency
    return
  }
  if envelope=$(FM_POLICY_SOURCE="$source" node 2>/dev/null <<'NODE'
const fs = require('fs');
const source = process.env.FM_POLICY_SOURCE;
const fd = fs.openSync(source, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
try {
  if (!fs.fstatSync(fd).isFile()) process.exit(1);
  const content = fs.readFileSync(fd);
  try {
    new TextDecoder('utf-8', {fatal: true}).decode(content);
  } catch (_) {
    process.exit(2);
  }
  process.stdout.write(JSON.stringify({content: content.toString('base64')}));
} finally {
  fs.closeSync(fd);
}
NODE
  ); then
    POLICY_ENVELOPE=$envelope
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      policy_fail malformed-json
      return
    fi
    policy_fail source
    return
  fi
}

policy_stream() {
  printf '%s\n' "$POLICY_ENVELOPE" | jq -jr '.content | @base64d' 2>/dev/null
}

policy_has_duplicate_keys() {
  local scanner
  scanner=$(cat <<'NODE'
const fs = require('fs');
const text = fs.readFileSync(0, 'utf8');
JSON.parse(text);
let at = 0;
let duplicate = false;
const ws = () => { while (/\s/.test(text[at] || '')) at += 1; };
const string = () => {
  const start = at++;
  while (at < text.length) {
    const char = text[at++];
    if (char === '"') return JSON.parse(text.slice(start, at));
    if (char === '\\') at += 1;
  }
  throw new Error('unterminated string');
};
const value = () => {
  ws();
  if (text[at] === '{') return object();
  if (text[at] === '[') return array();
  if (text[at] === '"') { string(); return; }
  const match = text.slice(at).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/);
  if (!match) throw new Error('invalid value');
  at += match[0].length;
};
const object = () => {
  const keys = new Set();
  at += 1;
  ws();
  if (text[at] === '}') { at += 1; return; }
  for (;;) {
    ws();
    const key = string();
    if (keys.has(key)) duplicate = true;
    keys.add(key);
    ws();
    if (text[at++] !== ':') throw new Error('missing colon');
    value();
    ws();
    if (text[at] === '}') { at += 1; return; }
    if (text[at++] !== ',') throw new Error('missing comma');
  }
};
const array = () => {
  at += 1;
  ws();
  if (text[at] === ']') { at += 1; return; }
  for (;;) {
    value();
    ws();
    if (text[at] === ']') { at += 1; return; }
    if (text[at++] !== ',') throw new Error('missing comma');
  }
};
value();
ws();
if (at !== text.length) throw new Error('trailing content');
process.exit(duplicate ? 1 : 0);
NODE
  )
  node -e "$scanner" >/dev/null 2>&1
}

policy_validate() {
  local err
  command -v jq >/dev/null 2>&1 || {
    policy_fail dependency
    return
  }
  command -v node >/dev/null 2>&1 || {
    policy_fail dependency
    return
  }
  if ! policy_stream | jq -e . >/dev/null 2>&1; then
    policy_fail malformed-json
    return
  fi
  if ! policy_stream | policy_has_duplicate_keys; then
    policy_fail duplicate-key
    return
  fi
  err=$(policy_stream | jq -r '
    def verified($h):
      ["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","muse"] | index($h);
    def route_identifier($value):
      (($value | type) == "string")
      and (($value | length) >= 1)
      and (($value | length) <= 128)
      and ($value | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"));
    def account_identifier($value):
      (($value | type) == "string")
      and (($value | length) >= 1)
      and (($value | length) <= 128)
      and ($value | test("^[a-z0-9][a-z0-9-]*$"));
    def work_type($value):
      (($value | type) == "string")
      and (($value | length) >= 1)
      and (($value | length) <= 64)
      and ($value | test("^[a-z0-9][a-z0-9._-]*$"));
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def forbidden:
      ["apiKey","token","secret","password","cookie","authorization"];
    def credential_field:
      [paths as $path
       | ($path[-1] | tostring) as $key
       | select(forbidden | index($key))
       | $key] | first;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
       + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def routing_error:
      {canary:3,automatic:6,burst:8,perLane:2} as $default_limits
      | if has("routing") and (.routing | type) != "object" then "routing must be an object"
        elif ((.routing.mode // "automatic") | IN("off","simulate","canary","automatic") | not) then "invalid routing mode"
        elif ((.routing.limits // $default_limits) | type) != "object" then "routing limits must be an object"
        elif ((.routing.limits // $default_limits).canary) != 3 then "routing limit canary must be 3"
        elif ((.routing.limits // $default_limits).automatic) != 6 then "routing limit automatic must be 6"
        elif ((.routing.limits // $default_limits).burst) != 8 then "routing limit burst must be 8"
        elif ((.routing.limits // $default_limits).perLane) != 2 then "routing limit perLane must be 2"
        else "ok"
        end;
    def v1:
      if has("rules") and (.rules | type) != "array" then "rules must be an array"
      elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
      elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
      elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
      elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
      elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
      elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
      elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
      elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
      elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then "unknown select: " + ([(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | unique | join(", "))
      elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
      elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
      elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
      elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
      elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
      else
        (configured_profiles | map(.harness) | map(select(. != null))
         | map(select(. as $h | verified($h) | not)) | unique) as $bad_harnesses
        | (configured_profiles | map({h:.harness,e:.effort}) | map(select(.e != null))
           | map(select((.h | type) == "string" and verified(.h)))
           | map(select(. as $p | effort_ok($p.h; $p.e) | not))
           | map("\(.h):\(.e)") | unique) as $bad_efforts
        | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
          elif ($bad_efforts | length) > 0 then "invalid effort: " + ($bad_efforts | join(", "))
          else "ok" end
      end;
    def profile_error($id; $profile):
      if ($profile | type) != "object" then "profile " + $id + " must be an object"
      elif ($profile.harness? | type) != "string" or ($profile.harness | length) == 0 then "profile " + $id + " needs harness"
      elif ["claude","codex","pi","pi-signed"] | index($profile.harness) | not then "unsupported version 2 harness: " + $profile.harness
      elif verified($profile.harness) | not then "unverified harness: " + $profile.harness
      elif (($profile | has("model") | not)
            or (($profile.model | type) != "string")
            or ($profile.model == "default")
            or (($profile.model | length) == 0)
            or (($profile.model | length) > 256)
            or (($profile.model | test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$") | not)))
        then "profile " + $id + " needs a concrete model"
      elif $profile | has("effort") and (((.effort | type) != "string") or (.effort | length) == 0) then "profile " + $id + " effort must be a non-empty string"
      elif effort_ok($profile.harness; $profile.effort) | not then "invalid effort: " + $profile.harness + ":" + $profile.effort
      elif (route_identifier($profile.provider) | not) then "profile " + $id + " needs provider"
      elif (route_identifier($profile.lane) | not) then "profile " + $id + " needs lane"
      elif $profile | has("account") and (account_identifier(.account) | not) then "profile " + $id + " account must be a lowercase identifier"
      elif ($profile.harness == "claude" or $profile.harness == "codex") and ($profile | has("account") | not) then "native claude and codex profiles need account"
      elif ($profile.harness == "pi" or $profile.harness == "pi-signed") and ($profile | has("account")) then "pi and pi-signed profiles cannot set account"
      elif ($profile.reasoningClass? | type) != "string" or (["basic","standard","strong","maximum"] | index($profile.reasoningClass) | not) then "profile " + $id + " has invalid reasoningClass"
      elif ($profile.workTypes? | type) != "array" or ($profile.workTypes | length) == 0 or ($profile.workTypes | any(work_type(.) | not)) then "profile " + $id + " needs non-empty workTypes"
      else "ok"
      end;
    def v2:
      {canary:3,automatic:6,burst:8,perLane:2} as $default_limits
      | {failures:3,windowSeconds:900,cooldownSeconds:1800} as $default_breaker
      | if has("routing") and (.routing | type) != "object" then "routing must be an object"
        elif ((.routing.mode // "automatic") | IN("off","simulate","canary","automatic") | not) then "invalid routing mode"
        elif ((.routing.limits // $default_limits) | type) != "object" then "routing limits must be an object"
        elif ((.routing.limits // $default_limits).canary) != 3 then "routing limit canary must be 3"
        elif ((.routing.limits // $default_limits).automatic) != 6 then "routing limit automatic must be 6"
        elif ((.routing.limits // $default_limits).burst) != 8 then "routing limit burst must be 8"
        elif ((.routing.limits // $default_limits).perLane) != 2 then "routing limit perLane must be 2"
        elif ((.routing.circuitBreaker // $default_breaker) | type) != "object" then "circuitBreaker must be an object"
        elif ((.routing.circuitBreaker // $default_breaker).failures) != 3 then "circuitBreaker failures must be 3"
        elif ((.routing.circuitBreaker // $default_breaker).windowSeconds) != 900 then "circuitBreaker windowSeconds must be 900"
        elif ((.routing.circuitBreaker // $default_breaker).cooldownSeconds) != 1800 then "circuitBreaker cooldownSeconds must be 1800"
        elif ((.routing.transientRetries // 1) != 1) then "transientRetries must be 1"
        elif has("profiles") and (.profiles | type) != "object" then "profiles must be an object"
        elif [(.profiles // {}) | keys[] | select(route_identifier(.) | not)] | length > 0 then "profile identifiers must be non-empty"
        elif has("rules") and (.rules | type) != "array" then "rules must be an array"
        elif [(.rules // [])[]? | select((type != "object") or ((.when? | type) != "string") or (.when | length) == 0 or ((.use? | type) != "array") or (.use | length) == 0 or (.use | any(route_identifier(.) | not)))] | length > 0 then "each version 2 rule needs non-empty when and named use profiles"
        elif has("default") and ((.default | type) != "array" or (.default | length) == 0 or (.default | any(route_identifier(.) | not))) then "version 2 default needs named profiles"
        else
          (.profiles // {}) as $profiles
          | [$profiles | to_entries[] | select(profile_error(.key; .value) != "ok") | profile_error(.key; .value)] as $profile_errors
          | if ($profile_errors | length) > 0 then $profile_errors[0]
            else
              ([((.rules // [])[]? | .use[]?), (if has("default") then .default[] else empty end)]
               | map(select($profiles[.] == null)) | unique) as $unknown
              | if ($unknown | length) > 0 then "unknown named profile: " + $unknown[0] else "ok" end
            end
        end;
    def v1_reason($error):
      if $error == "ok" then "ok"
      elif ($error | startswith("unknown select:")) then "selector"
      elif (($error | startswith("unverified harness:"))
            or ($error | startswith("invalid effort:"))
            or ($error | contains("profile"))) then "profile"
      else "schema"
      end;
    def v2_reason($error):
      if $error == "ok" then "ok"
      elif (($error | startswith("circuitBreaker"))
            or ($error | startswith("transientRetries"))) then "routing"
      elif ($error | startswith("unknown named profile:")) then "reference"
      elif (($error | startswith("each version 2 rule"))
            or ($error | startswith("version 2 default"))) then "schema"
      else "profile"
      end;
    if type != "object" then "schema"
    elif credential_field != null then "forbidden-field"
    elif ((.schemaVersion // 1) != 1 and (.schemaVersion // 1) != 2) then "schema"
    elif routing_error != "ok" then "routing"
    elif (.schemaVersion // 1) == 1 then v1_reason(v1)
    else v2_reason(v2)
    end
  ' 2>/dev/null) || {
    policy_fail schema
    return
  }
  [ "$err" = ok ] || {
    case "$err" in
      forbidden-field|routing|schema|selector|profile|reference) ;;
      *) err=schema ;;
    esac
    policy_fail "$err"
    return
  }
}

policy_read() {
  local output
  if ! output=$(policy_stream | jq "$@" 2>/dev/null); then
    policy_fail read
    return
  fi
  printf '%s\n' "$output"
}

case ${1:-} in
  validate)
    file=${2:-$CONFIG_DIR/crew-dispatch.json}
    policy_snapshot "$file"
    policy_validate
    ;;
  mode)
    file=${2:-$CONFIG_DIR/crew-dispatch.json}
    policy_snapshot "$file"
    policy_validate
    policy_read -r '.routing.mode // "automatic"'
    ;;
  limits)
    file=${2:-$CONFIG_DIR/crew-dispatch.json}
    policy_snapshot "$file"
    policy_validate
    policy_read -c '.routing.limits // {canary:3,automatic:6,burst:8,perLane:2}'
    ;;
  profile)
    [ "$#" -ge 2 ] || usage
    id=$2
    file=${3:-$CONFIG_DIR/crew-dispatch.json}
    case "$id" in
      ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) policy_fail profile-id; exit 1 ;;
    esac
    [ "${#id}" -le 128 ] || { policy_fail profile-id; exit 1; }
    policy_snapshot "$file"
    policy_validate
    # jq expands $id inside its own literal program.
    # shellcheck disable=SC2016
    policy_read -ce --arg id "$id" '
      .profiles[$id]
      | select(type == "object")
      | {
          id:$id,
          harness:.harness,
          provider:.provider,
          lane:.lane,
          reasoningClass:.reasoningClass,
          workTypes:.workTypes
        }
        + (if has("model") then {model:.model} else {} end)
        + (if has("effort") then {effort:.effort} else {} end)
        + (if has("account") then {account:.account} else {} end)
    ' || exit 1
    ;;
  describe)
    file=${2:-$CONFIG_DIR/crew-dispatch.json}
    policy_snapshot "$file"
    policy_validate
    policy_read -c '{schemaVersion:(.schemaVersion // 1),mode:(.routing.mode // "automatic")}'
    ;;
  *)
    usage
    ;;
esac
