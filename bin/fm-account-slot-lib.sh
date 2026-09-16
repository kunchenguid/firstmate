#!/usr/bin/env bash
# fm-account-slot-lib.sh - strict home-local account-slot validation and probes.
#
# Sourced, never executed. The public interface is bin/fm-account-slot.sh.
# The registry is config/account-slots.json. It contains logical slot names and
# vendor profile directories, never credentials. Probe output is deliberately
# narrower than quota-axi --full JSON: account identity, provenance attempts,
# source paths, and credential material are validated here and then discarded.

set -u

FM_ACCOUNT_SLOT_ERROR=
FM_ACCOUNT_SLOT_ID=
FM_ACCOUNT_SLOT_HARNESS=
FM_ACCOUNT_SLOT_STORE_PATH=
FM_ACCOUNT_SLOT_EXPECTED_ACCOUNT_ID=

fm_account_slot_fail() {
  FM_ACCOUNT_SLOT_ERROR=$1
  return 1
}

fm_account_slot_stat() { # <mode|owner|links> <path>
  local field=$1 path=$2
  if [ "$(uname)" = Darwin ]; then
    case "$field" in
      mode) /usr/bin/stat -f %Lp "$path" 2>/dev/null ;;
      owner) /usr/bin/stat -f %u "$path" 2>/dev/null ;;
      links) /usr/bin/stat -f %l "$path" 2>/dev/null ;;
      *) return 1 ;;
    esac
  else
    case "$field" in
      mode) stat -c %a "$path" 2>/dev/null ;;
      owner) stat -c %u "$path" 2>/dev/null ;;
      links) stat -c %h "$path" 2>/dev/null ;;
      *) return 1 ;;
    esac
  fi
}

fm_account_slot_private_mode() {
  local mode=$1
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  [ $((8#$mode & 8#077)) -eq 0 ]
}

fm_account_slot_secure_file() { # <path> <description>
  local path=$1 description=$2 mode owner links
  [ -f "$path" ] && [ ! -L "$path" ] \
    || { fm_account_slot_fail "$description must be a non-symlink regular file"; return 1; }
  [ -r "$path" ] || { fm_account_slot_fail "$description must be readable"; return 1; }
  mode=$(fm_account_slot_stat mode "$path") \
    || { fm_account_slot_fail "$description permissions cannot be inspected"; return 1; }
  owner=$(fm_account_slot_stat owner "$path") \
    || { fm_account_slot_fail "$description owner cannot be inspected"; return 1; }
  links=$(fm_account_slot_stat links "$path") \
    || { fm_account_slot_fail "$description link count cannot be inspected"; return 1; }
  [ "$owner" = "$(id -u)" ] || { fm_account_slot_fail "$description must be owned by the current user"; return 1; }
  fm_account_slot_private_mode "$mode" \
    || { fm_account_slot_fail "$description must have no group or world permissions"; return 1; }
  [ "$links" = 1 ] || { fm_account_slot_fail "$description must not be hardlinked"; return 1; }
}

fm_account_slot_secure_directory() { # <path> <slot>
  local path=$1 slot=$2 mode owner real
  case "$path" in /*) ;; *) fm_account_slot_fail "slot '$slot' storePath must be absolute"; return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] \
    || { fm_account_slot_fail "slot '$slot' storePath must be an existing non-symlink directory"; return 1; }
  [ -r "$path" ] && [ -x "$path" ] \
    || { fm_account_slot_fail "slot '$slot' storePath must be readable and searchable"; return 1; }
  real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) \
    || { fm_account_slot_fail "slot '$slot' storePath cannot be resolved"; return 1; }
  [ "$real" = "$path" ] \
    || { fm_account_slot_fail "slot '$slot' storePath must use its canonical absolute spelling"; return 1; }
  mode=$(fm_account_slot_stat mode "$path") \
    || { fm_account_slot_fail "slot '$slot' storePath permissions cannot be inspected"; return 1; }
  owner=$(fm_account_slot_stat owner "$path") \
    || { fm_account_slot_fail "slot '$slot' storePath owner cannot be inspected"; return 1; }
  [ "$owner" = "$(id -u)" ] \
    || { fm_account_slot_fail "slot '$slot' storePath must be owned by the current user"; return 1; }
  fm_account_slot_private_mode "$mode" \
    || { fm_account_slot_fail "slot '$slot' storePath must have no group or world permissions"; return 1; }
}

fm_account_slot_registry_shape_error() { # <registry>
  jq -r '
    def slug: type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$");
    def allowed_entry: ["expectedAccountId","harness","storePath"];
    if type != "object" then "top-level value must be an object"
    elif ((keys - ["slots","version"]) | length) > 0 then "unknown top-level field: " + ((keys - ["slots","version"])[0])
    elif .version != 1 then "version must be 1"
    elif (.slots | type) != "object" then "slots must be an object"
    elif (.slots | length) == 0 then "slots must not be empty"
    elif (.slots | has("default")) then "slot ID default is reserved for clearing an account selection"
    elif ([.slots | keys[] | select(slug | not)] | length) > 0 then "slot IDs must be lowercase slugs of at most 63 characters"
    elif ([.slots[] | select(type != "object")] | length) > 0 then "each slot must be an object"
    elif ([.slots | to_entries[] | select(((.value | keys) - allowed_entry | length) > 0)] | length) > 0 then
      "slot " + ([.slots | to_entries[] | select(((.value | keys) - allowed_entry | length) > 0)][0].key) + " has an unknown field"
    elif ([.slots | to_entries[] | select(.value.harness != "claude" and .value.harness != "codex")] | length) > 0 then "slot harness must be claude or codex"
    elif ([.slots | to_entries[] | select((.value.storePath | type) != "string" or (.value.storePath | startswith("/") | not))] | length) > 0 then "each storePath must be an absolute string"
    elif ([.slots | to_entries[] | select((.value.expectedAccountId | type) != "string" or (.value.expectedAccountId | length) == 0 or (.value.expectedAccountId | length) > 512 or (.value.expectedAccountId | test("^\\s|\\s$") ))] | length) > 0 then "each slot must set expectedAccountId as a non-empty trimmed string of at most 512 characters"
    else empty end
  ' "$1" 2>/dev/null
}

fm_account_slot_credential_path() { # <harness> <store-path>
  case "$1" in
    claude) printf '%s' "$2/.credentials.json" ;;
    codex) printf '%s' "$2/auth.json" ;;
    *) return 1 ;;
  esac
}

# Claude scopes its keychain item to the config directory it was signed in
# under - service "Claude Code-credentials-<sha256(storePath)[0:8]>" - so this
# never observes the ambient unsuffixed item, and it reads no secret material:
# find-generic-password without -w returns attributes only.
fm_account_slot_keychain_present() { # <store-path>
  local digest
  command -v security >/dev/null 2>&1 || return 1
  digest=$(printf '%s' "$1" | shasum -a 256 2>/dev/null) || return 1
  digest=${digest%% *}
  [ "${#digest}" -ge 8 ] || return 1
  security find-generic-password -s "Claude Code-credentials-${digest:0:8}" >/dev/null 2>&1
}

fm_account_slot_credential_present() { # <harness> <store-path>
  local credential
  credential=$(fm_account_slot_credential_path "$1" "$2") || return 1
  if [ -e "$credential" ] || [ -L "$credential" ]; then
    return 0
  fi
  [ "$1" = claude ] || return 1
  fm_account_slot_keychain_present "$2"
}

fm_account_slot_validate_registry() { # <config-dir>
  local config=$1 registry="$1/account-slots.json" error rows slot harness path credential canonical seen=
  FM_ACCOUNT_SLOT_ERROR=
  [ -e "$registry" ] || [ -L "$registry" ] \
    || { fm_account_slot_fail "config/account-slots.json is missing"; return 1; }
  fm_account_slot_secure_file "$registry" "config/account-slots.json" || return 1
  command -v jq >/dev/null 2>&1 || { fm_account_slot_fail "jq is required to validate account slots"; return 1; }
  jq -e . "$registry" >/dev/null 2>&1 \
    || { fm_account_slot_fail "config/account-slots.json contains malformed JSON"; return 1; }
  error=$(fm_account_slot_registry_shape_error "$registry") \
    || { fm_account_slot_fail "config/account-slots.json cannot be validated"; return 1; }
  [ -z "$error" ] || { fm_account_slot_fail "config/account-slots.json is invalid - $error"; return 1; }
  rows=$(jq -r '.slots | to_entries[] | [.key,.value.harness,.value.storePath] | @tsv' "$registry") \
    || { fm_account_slot_fail "config/account-slots.json cannot be read"; return 1; }
  while IFS=$'\t' read -r slot harness path; do
    [ -n "$slot" ] || continue
    fm_account_slot_secure_directory "$path" "$slot" || return 1
    canonical=$(CDPATH='' cd -- "$path" && pwd -P) || return 1
    case $'\n'"$seen"$'\n' in
      *$'\n'"$canonical"$'\n'*) fm_account_slot_fail "slot '$slot' duplicates another slot's canonical storePath"; return 1 ;;
    esac
    seen=${seen:+$seen$'\n'}$canonical
    credential=$(fm_account_slot_credential_path "$harness" "$path") \
      || { fm_account_slot_fail "slot '$slot' has no known vendor credential location"; return 1; }
    if [ -e "$credential" ] || [ -L "$credential" ]; then
      fm_account_slot_secure_file "$credential" "slot '$slot' credential file" || return 1
    fi
  done <<< "$rows"
}

fm_account_slot_dispatch_candidate_sets() {
  jq -c '
    def profiles($v): if ($v | type) == "array" then $v else [$v] end;
    ((.rules // [])[]? | profiles(.use)), (if has("default") then profiles(.default) else empty end)
  ' "$1" 2>/dev/null
}

fm_account_slot_validate_dispatch() { # <config-dir> [dispatch-file]
  local config=$1 dispatch=${2:-$1/crew-dispatch.json} registry="$1/account-slots.json" error sets refs duplicates
  FM_ACCOUNT_SLOT_ERROR=
  [ -f "$dispatch" ] || return 0
  sets=$(fm_account_slot_dispatch_candidate_sets "$dispatch") \
    || { fm_account_slot_fail "config/crew-dispatch.json cannot be inspected for accountSlots"; return 1; }
  refs=$(printf '%s\n' "$sets" | jq -sc '[.[][] | select(has("accountSlots"))]') \
    || { fm_account_slot_fail "config/crew-dispatch.json cannot be inspected for accountSlots"; return 1; }
  [ "$(printf '%s' "$refs" | jq 'length')" -gt 0 ] || return 0
  error=$(printf '%s' "$refs" | jq -r '
    def slug: type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$");
    if any(.[]; (.accountSlots | type) != "array" or (.accountSlots | length) == 0) then "accountSlots must be a non-empty array"
    elif any(.[]; any(.accountSlots[]; . == "default")) then "account slot ID default is reserved for clearing an account selection"
    elif any(.[]; any(.accountSlots[]; slug | not)) then "accountSlots entries must be lowercase slot slugs"
    elif any(.[]; ((.accountSlots | length) != (.accountSlots | unique | length))) then "accountSlots entries must be unique"
    elif any(.[]; .harness != "claude" and .harness != "codex") then "accountSlots are supported only for claude and codex profiles"
    else empty end') || { fm_account_slot_fail "config/crew-dispatch.json accountSlots cannot be validated"; return 1; }
  [ -z "$error" ] || { fm_account_slot_fail "config/crew-dispatch.json is invalid - $error"; return 1; }
  # A home with no registry of its own - a secondmate that inherited slotted
  # dispatch rules, say - cannot resolve these references and is not thereby
  # misconfigured. fm_account_slot_resolve refuses the unknown slot at spawn.
  [ -e "$registry" ] || [ -L "$registry" ] || return 0
  fm_account_slot_validate_registry "$config" || return 1
  error=$(jq -nr --argjson profiles "$refs" --slurpfile registry "$registry" '
    [$profiles[] as $p | $p.accountSlots[] as $slot |
      select(($registry[0].slots | has($slot) | not) or $registry[0].slots[$slot].harness != $p.harness) |
      $slot] | if length > 0 then "slot reference is missing or belongs to another harness: " + .[0] else empty end') \
    || { fm_account_slot_fail "account slot references cannot be validated"; return 1; }
  [ -z "$error" ] || { fm_account_slot_fail "$error"; return 1; }
  duplicates=$(printf '%s\n' "$sets" | jq -sr '
    [.[] | [.[] | select(has("accountSlots")) | . as $p | .accountSlots[]
              | [$p.harness,($p.model // "default"),($p.effort // "default"),.] | join("|")]
          | group_by(.) | map(select(length > 1) | .[0])[]]
    | .[0] // empty') \
    || { fm_account_slot_fail "effective account-slot tuples cannot be validated"; return 1; }
  [ -z "$duplicates" ] || { fm_account_slot_fail "duplicate effective dispatch tuple: $duplicates"; return 1; }
}

fm_account_slot_resolve() { # <config-dir> <slot> [harness]
  local config=$1 slot=$2 harness=${3:-} registry="$1/account-slots.json" row
  FM_ACCOUNT_SLOT_ERROR=
  [ "$slot" != default ] || { fm_account_slot_fail "account slot 'default' is reserved for clearing an account selection"; return 1; }
  fm_account_slot_validate_registry "$config" || return 1
  row=$(jq -r --arg slot "$slot" --arg harness "$harness" '
    .slots[$slot] as $s |
    if $s == null then empty
    elif $harness != "" and $s.harness != $harness then "HARNESS_MISMATCH"
    else [$slot,$s.harness,$s.storePath] | @tsv end
  ' "$registry") || { fm_account_slot_fail "slot '$slot' cannot be read"; return 1; }
  [ -n "$row" ] || { fm_account_slot_fail "slot '$slot' is not configured in this home"; return 1; }
  [ "$row" != HARNESS_MISMATCH ] || { fm_account_slot_fail "slot '$slot' does not belong to harness '$harness'"; return 1; }
  IFS=$'\t' read -r FM_ACCOUNT_SLOT_ID FM_ACCOUNT_SLOT_HARNESS FM_ACCOUNT_SLOT_STORE_PATH <<< "$row"
  FM_ACCOUNT_SLOT_EXPECTED_ACCOUNT_ID=$(jq -r --arg slot "$slot" '.slots[$slot].expectedAccountId // empty' "$registry") \
    || { fm_account_slot_fail "slot '$slot' expected account identity cannot be read"; return 1; }
  fm_account_slot_credential_present "$FM_ACCOUNT_SLOT_HARNESS" "$FM_ACCOUNT_SLOT_STORE_PATH" \
    || { fm_account_slot_fail "slot '$slot' is unavailable: its store holds no vendor-managed credential"; return 1; }
}

fm_account_slot_probe() { # <config-dir> <slot>
  local config=$1 slot=$2 harness path raw rc now selector verdict
  FM_ACCOUNT_SLOT_ERROR=
  fm_account_slot_resolve "$config" "$slot" || return 1
  harness=$FM_ACCOUNT_SLOT_HARNESS
  path=$FM_ACCOUNT_SLOT_STORE_PATH
  declare -F fm_quota_axi_probe_capability >/dev/null 2>&1 \
    || { fm_account_slot_fail "internal quota-axi capability check is unavailable"; return 1; }
  fm_quota_axi_probe_capability \
    || { fm_account_slot_fail "$FM_QUOTA_AXI_CAPABILITY_ERROR"; return 1; }
  declare -F fm_run_timed >/dev/null 2>&1 \
    || { fm_account_slot_fail "bounded command execution is unavailable"; return 1; }
  fm_quota_axi_probe_argv "$harness"
  umask 077
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-account-slot.XXXXXX") \
    || { fm_account_slot_fail "private quota probe output cannot be created"; return 1; }
  selector=CLAUDE_CONFIG_DIR
  [ "$harness" = claude ] || selector=CODEX_HOME
  if fm_run_timed 20 env \
      -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
      -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      -u OPENAI_API_KEY -u CODEX_API_KEY \
      "$selector=$path" quota-axi "${FM_QUOTA_AXI_PROBE_ARGV[@]}" \
      >"$raw" 2>/dev/null </dev/null; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$raw"
    if [ "$rc" -eq 124 ]; then
      fm_account_slot_fail "slot '$slot' quota probe timed out"
    else
      fm_account_slot_fail "slot '$slot' quota probe failed"
    fi
    return 1
  fi
  if ! jq -s -e 'length == 1' "$raw" >/dev/null 2>&1; then
    rm -f "$raw"
    fm_account_slot_fail "slot '$slot' returned stale, mismatched, or malformed quota evidence"
    return 1
  fi
  now=$(date +%s)
  verdict=$(jq -r --arg provider "$harness" \
      --arg account_id "$FM_ACCOUNT_SLOT_EXPECTED_ACCOUNT_ID" \
      --argjson now "$now" --argjson max_age 900 --argjson future 60 '
    def epoch: (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
    def recent($v): ($v | type) == "string" and (($v | epoch) as $t | $t != null and $t <= ($now + $future) and $t >= ($now - $max_age));
    def isolated_sources($p): if $p == "claude" then ["oauth-file","keychain"] else ["oauth"] end;
    def sound:
    .schemaVersion == 5 and (.providers | type) == "array" and (.providers | length) == 1 and
    recent(.generatedAt) and
    (.providers[0] as $p |
      $p.provider == $provider and
      ($p.state | type) == "object" and $p.state.status == "fresh" and $p.state.stale == false and
      ($p.account | type) == "object" and ($p.account.accountId | type) == "string" and
      (($p.account.identityStatus? == null) or $p.account.identityStatus == "verified") and
      ([ $p.attempts[]? | select(.status == "success") ] as $succeeded |
        any($succeeded[]; . as $a | (isolated_sources($provider) | index($a.source)) != null) and
        all($succeeded[]; . as $a | ($a.accountId? == null) or ($a.accountId | type) == "string")) and
      ($p.quotaSemantics | type) == "object" and
      ($p.quotaSemantics.status as $s | (["known","partial","unknown"] | index($s)) != null) and
      ($p.quotaSemantics.effectiveAvailability | type) == "array" and
      all($p.quotaSemantics.effectiveAvailability[];
        (.scope | type) == "string" and (.scope | length) > 0 and ((.scope | test("^\\s|\\s$")) | not) and
        (.status == "known" or .status == "unknown") and
        (if .status == "known" then
           (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining >= 0 and .effectivePercentRemaining <= 100 and
           (.runway.status as $r | (["through_reset","projected_exhaustion","exhausted_now","unknown"] | index($r)) != null)
         else (has("effectivePercentRemaining") | not) end) and
        ((.selection? == null) or
          ((.selection.status == "known" and (.selection.spendPriority | type) == "number") or
           (.selection.status == "unknown" and (.selection | has("spendPriority") | not))))
      )
    );
    def matches_expected_identity:
    (.providers[0] as $p |
      $p.account.accountId == $account_id and
      all($p.attempts[]? | select(.status == "success"); (.accountId? == null) or .accountId == $account_id));
    if (try sound catch false) | not then "evidence"
    elif (try matches_expected_identity catch false) | not then "identity"
    else "ok" end
  ' "$raw" 2>/dev/null) || verdict=evidence
  if [ "$verdict" = identity ]; then
    rm -f "$raw"
    fm_account_slot_fail "slot '$slot' quota evidence reports a different account than the expectedAccountId configured for it"
    return 1
  fi
  if [ "$verdict" != ok ]; then
    rm -f "$raw"
    fm_account_slot_fail "slot '$slot' returned stale, mismatched, or malformed quota evidence"
    return 1
  fi
  jq -c --arg slot "$slot" '{schemaVersion,generatedAt,accountSlot:$slot,providers:[.providers[0] | {provider,state:{status:.state.status,stale:.state.stale},quotaSemantics}]}' "$raw"
  rc=$?
  rm -f "$raw"
  [ "$rc" -eq 0 ] || { fm_account_slot_fail "slot '$slot' sanitized quota evidence could not be emitted"; return 1; }
}
