#!/usr/bin/env bash
# fm-crew-dispatch.sh - validate, describe, and narrowly edit crew dispatch config.
#
# Usage:
#   fm-crew-dispatch.sh validate <crew-dispatch.json>
#   fm-crew-dispatch.sh status <crew-dispatch.json>
#   fm-crew-dispatch.sh apply <crew-dispatch.json> <request.json>
#
# This command is the executable owner of dispatch-file validation used by both
# bootstrap and Mission Control edits. docs/configuration.md "Crew dispatch
# profiles" remains the canonical schema owner; this command enforces that
# schema and never selects a rule or profile.
#
# validate  Exit 0 for a valid file. Exit 1 and print one short reason for a
#           missing, malformed, or invalid file. The caller owns any diagnostic
#           prefix around that reason.
# status    Print one JSON object for Mission Control. An absent file is a normal
#           {present:false,status:"absent"} result. A present file includes its
#           current validation verdict and its raw bytes for an expandable view;
#           valid files also include the parsed config unchanged.
# apply     Apply one already-normalized `dispatch` board request. V1 changes
#           only model and effort on an existing use/default profile. Stable rule
#           and profile ids identify the target, while rendered revisions refuse
#           a target that changed after the board was rendered. The complete
#           candidate is validated by this same command before a same-directory temporary is
#           atomically promoted. Any refusal leaves the original file unchanged.
#
# Request shape:
#   {"intent":"dispatch","scope":"rule","rule_id":"visual-ui",
#    "profile_id":"codex-primary","model":"model-id","effort":"high",
#    "expected_rule_revision":"sha256","expected_profile_revision":"sha256"}
# or scope `default` with no `rule_id`. Empty model or effort removes that
# optional field. Adding, deleting, reordering, changing `when`, and changing a
# harness are deliberately unsupported.
#
# Exit codes: 0 success, 1 invalid/refused/runtime failure, 2 usage error.
set -u

usage() {
  sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() { printf '%s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

validate_file() {  # <path>
  local file=$1 err
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'file is absent or unsafe\n'; return 1; }
  jq -e . "$file" >/dev/null 2>&1 || { printf 'malformed JSON\n'; return 1; }
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","pi-signed","grok","kimi"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def safe_id($value):
      if ($value | type) == "string"
      then ($value | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$"))
      else false end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + [(.rules // [])[]? | profiles(.fallback?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end)
        + (if has("default_fallback") then [profiles(.default_fallback)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)))
      or ($items | any(has("provider") and (((.provider | type) != "string") or (.provider | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model, effort, and provider must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("fallback") and (.fallback | type) != "object" and (.fallback | type) != "array")] | length > 0 then "fallback must be a profile object or non-empty profile array"
    elif [(.rules // [])[]? | select(has("fallback") and (.fallback | type) == "array" and (.fallback | length) == 0)] | length > 0 then "fallback needs at least one profile"
    elif [(.rules // [])[]? | profiles(.fallback?)[]? | select(type != "object")] | length > 0 then "each fallback profile must be an object"
    elif [(.rules // [])[]? | profiles(.fallback?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each fallback profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.fallback?)[]?]) then "fallback profile model, effort, and provider must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("independent") and (.independent | type) != "boolean")] | length > 0 then "independent must be true or false"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model, effort, and provider must be non-empty strings when present"
    elif has("default_fallback") and ((.default_fallback | type) != "object" and (.default_fallback | type) != "array") then "default_fallback must be a profile object or non-empty profile array"
    elif has("default_fallback") and ((.default_fallback | type) == "array" and (.default_fallback | length) == 0) then "default_fallback needs at least one profile"
    elif has("default_fallback") and ([profiles(.default_fallback)[]? | select(type != "object")] | length) > 0 then "each default_fallback profile must be an object"
    elif has("default_fallback") and ([profiles(.default_fallback)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default_fallback profile needs harness"
    elif has("default_fallback") and malformed_optional_fields([profiles(.default_fallback)[]?]) then "default_fallback profile model, effort, and provider must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        elif [(.rules // [])[]? | select((safe_id(.id?)) | not)] | length > 0 then "each rule needs a stable id"
        elif ([[(.rules // [])[]?.id] | group_by(.)[] | select(length > 1)] | length) > 0 then "rule ids must be unique"
        elif [configured_profiles[] | select((safe_id(.id?)) | not)] | length > 0 then "each profile needs a stable id"
        elif ([configured_profiles | map(.id) | group_by(.)[] | select(length > 1)] | length) > 0 then "profile ids must be unique"
        else empty
        end
    end
  ' "$file" 2>/dev/null) || { printf 'validation could not read the file\n'; return 1; }
  [ -z "$err" ] || { printf '%s\n' "$err"; return 1; }
  return 0
}

config_revisions() {  # <path>
  perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    local $/;
    open(my $fh, "<", $ARGV[0]) or exit 1;
    binmode($fh);
    my $config = decode_json(<$fh> // "");
    my $json = JSON::PP->new->canonical->allow_nonref;
    sub revision { sha256_hex($json->encode($_[0])) }
    sub profiles { ref($_[0]) eq "ARRAY" ? @{$_[0]} : ($_[0]) }
    my @rules;
    for my $rule (@{$config->{rules} // []}) {
      push @rules, {id => $rule->{id}, revision => revision($rule),
        profiles => [map { {id => $_->{id}, revision => revision($_)} } profiles($rule->{use})]};
    }
    my $default = undef;
    if (exists $config->{default}) {
      $default = {revision => revision($config->{default}),
        profiles => [map { {id => $_->{id}, revision => revision($_)} } profiles($config->{default})]};
    }
    print $json->encode({rules => \@rules, default => $default});
  ' "$1"
}

status_file() {  # <path>
  local file=$1 reason raw config revisions
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    jq -nc '{present:false,status:"absent",error:null,config:null,raw:null}'
    return 0
  fi
  if [ ! -f "$file" ] || [ -L "$file" ]; then
    jq -nc '{present:true,status:"invalid",error:"file is unsafe",config:null,raw:null}'
    return 0
  fi
  if reason=$(validate_file "$file"); then
    config=$(jq -c . "$file") || die "could not read dispatch config"
    raw=$(jq . "$file") || die "could not format dispatch config"
    revisions=$(config_revisions "$file") || die "could not revise dispatch config"
    jq -nc --argjson config "$config" --argjson revisions "$revisions" --arg raw "$raw" \
      '{present:true,status:"valid",error:null,config:$config,revisions:$revisions,raw:$raw}'
  else
    raw=$(LC_ALL=C head -c 1048576 "$file" 2>/dev/null || true)
    jq -nc --arg error "$reason" --arg raw "$raw" \
      '{present:true,status:"invalid",error:$error,config:null,raw:$raw}'
  fi
}

apply_request_locked() {  # <path> <request-json>
  local file=$1 request_file=$2 scope rule_id profile_id model effort
  local expected_rule_revision expected_profile_revision current_rule_revision current_profile_revision
  local revisions dir base source tmp reason assignment
  [ -f "$request_file" ] && [ ! -L "$request_file" ] || die "request file is absent or unsafe"
  jq -e 'type == "object" and .intent == "dispatch"
    and (.scope == "rule" or .scope == "default")
    and (.profile_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$"))
    and (.model | type == "string" and length <= 300)
    and (.effort | type == "string" and length <= 20)
    and (.expected_rule_revision | type == "string" and test("^[0-9a-f]{64}$"))
    and (.expected_profile_revision | type == "string" and test("^[0-9a-f]{64}$"))
    and ((.scope == "rule" and (.rule_id | type == "string"
      and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")))
      or (.scope == "default" and (has("rule_id") | not)))' "$request_file" >/dev/null 2>&1 \
    || die "dispatch edit request is malformed"
  scope=$(jq -r '.scope' "$request_file")
  rule_id=$(jq -r '.rule_id // ""' "$request_file")
  profile_id=$(jq -r '.profile_id' "$request_file")
  model=$(jq -r '.model' "$request_file")
  effort=$(jq -r '.effort' "$request_file")
  expected_rule_revision=$(jq -r '.expected_rule_revision' "$request_file")
  expected_profile_revision=$(jq -r '.expected_profile_revision' "$request_file")
  dir=${file%/*}; base=${file##*/}
  [ "$dir" != "$file" ] || dir=.
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "dispatch config directory is unsafe"
  [ -f "$file" ] && [ ! -L "$file" ] || die "file is absent or unsafe"
  source=$(umask 077; mktemp "$dir/.${base}.source.XXXXXX") || die "could not stage dispatch source"
  if ! cp -- "$file" "$source"; then
    rm -f -- "$source"
    die "could not stage dispatch source"
  fi
  if ! reason=$(validate_file "$source"); then
    rm -f -- "$source"
    die "$reason"
  fi
  if ! revisions=$(config_revisions "$source"); then
    rm -f -- "$source"
    die "could not revise dispatch config"
  fi
  if [ "$scope" = rule ]; then
    current_rule_revision=$(printf '%s' "$revisions" | jq -r --arg rule_id "$rule_id" \
      '[.rules[] | select(.id == $rule_id) | .revision] | first // ""')
    current_profile_revision=$(printf '%s' "$revisions" | jq -r --arg rule_id "$rule_id" \
      --arg profile_id "$profile_id" \
      '[.rules[] | select(.id == $rule_id) | .profiles[] | select(.id == $profile_id) | .revision]
       | first // ""')
  else
    current_rule_revision=$(printf '%s' "$revisions" | jq -r '.default.revision // ""')
    current_profile_revision=$(printf '%s' "$revisions" | jq -r --arg profile_id "$profile_id" \
      '[.default.profiles[] | select(.id == $profile_id) | .revision] | first // ""')
  fi
  if [ "$current_rule_revision" != "$expected_rule_revision" ] \
      || [ "$current_profile_revision" != "$expected_profile_revision" ]; then
    rm -f -- "$source"
    die "dispatch rule or profile changed; regenerate the board and try again"
  fi

  if ! tmp=$(umask 077; mktemp "$dir/.${base}.edit.XXXXXX"); then
    rm -f -- "$source"
    die "could not stage dispatch edit"
  fi
  if ! jq --arg scope "$scope" --arg rule_id "$rule_id" --arg profile_id "$profile_id" \
      --arg model "$model" --arg effort "$effort" '
      def changed($model; $effort):
        (if $model == "" then del(.model) else .model = $model end)
        | (if $effort == "" then del(.effort) else .effort = $effort end);
      def changed_profile($profile_id; $model; $effort):
        if type == "array" then
          if any(.[]; .id == $profile_id)
          then map(if .id == $profile_id then changed($model; $effort) else . end)
          else error("dispatch profile no longer exists") end
        elif .id == $profile_id then changed($model; $effort)
        else error("dispatch profile no longer exists") end;
      if $scope == "rule" then
        if any(.rules[]; .id == $rule_id)
        then .rules |= map(if .id == $rule_id
          then .use |= changed_profile($profile_id; $model; $effort) else . end)
        else error("dispatch rule no longer exists") end
      else
        if has("default") then .default |= changed_profile($profile_id; $model; $effort)
        else error("default dispatch profile no longer exists") end
      end
    ' "$source" > "$tmp"; then
    rm -f -- "$source" "$tmp"
    die "could not build dispatch candidate"
  fi
  if ! reason=$(validate_file "$tmp"); then
    rm -f -- "$source" "$tmp"
    die "$reason"
  fi
  assignment=$(jq -c --arg scope "$scope" --arg rule_id "$rule_id" --arg profile_id "$profile_id" '
    def profiles($value): if ($value | type) == "array" then $value else [$value] end;
    (if $scope == "rule" then [.rules[] | select(.id == $rule_id) | profiles(.use)[]]
     else [profiles(.default)[]] end)
    | map(select(.id == $profile_id)) | first
    | {harness, model:(.model // "harness default"), effort:(.effort // "harness default"), provider:(.provider // null)}
  ' "$tmp") || { rm -f -- "$source" "$tmp"; die "dispatch candidate assignment could not be read"; }
  chmod 0600 "$tmp" || { rm -f -- "$source" "$tmp"; die "could not secure dispatch candidate"; }
  cmp -s "$source" "$file" \
    || { rm -f -- "$source" "$tmp"; die "dispatch config changed while applying; regenerate the board and try again"; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$source" "$tmp"; die "could not publish dispatch edit"; }
  rm -f -- "$source"
  printf '%s\n' "$assignment"
}

apply_request() {  # <path> <request-json>
  local file=$1 request_file=$2 dir base lock lock_dir
  dir=${file%/*}; base=${file##*/}
  [ "$dir" != "$file" ] || dir=.
  [ "$base" = crew-dispatch.json ] || die "dispatch config path must end in crew-dispatch.json"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "dispatch config directory is unsafe"
  lock_dir=$(cd "$dir" 2>/dev/null && pwd -P) || die "dispatch config directory is unsafe"
  FM_STATE_OVERRIDE=${FM_STATE_OVERRIDE:-$lock_dir}
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
  lock="$lock_dir/.fm-inherit-crew-dispatch.json.lock"
  (
    fm_lock_acquire_wait "$lock" || die "could not lock dispatch config"
    trap 'fm_lock_release "$lock" || true' EXIT
    apply_request_locked "$file" "$request_file"
  )
}

case "${1-}" in
  validate) [ "$#" -eq 2 ] || usage; validate_file "$2" ;;
  status) [ "$#" -eq 2 ] || usage; status_file "$2" ;;
  apply) [ "$#" -eq 3 ] || usage; apply_request "$2" "$3" ;;
  -h|--help|help|'') usage ;;
  *) usage ;;
esac
