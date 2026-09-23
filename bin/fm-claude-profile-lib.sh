# shellcheck shell=bash
# Named Claude profile selection for fm-spawn.sh.
#
# config/claude-profiles.json is the single local, gitignored declaration of
# Claude account stores. Its schema and operator contract live in
# docs/configuration.md "Claude account profiles". This library owns the
# executable selection contract:
#
# - Every declared config_dir is an absolute, readable directory.
# - Every profile is measured independently with exactly
#   CLAUDE_CONFIG_DIR=<dir> quota-axi --provider claude --profile-only --json.
# - One malformed, unreachable, unauthenticated, or invalid profile refuses the
#   whole selection. It is never silently skipped in favor of another account.
# - Applicable all-model/all-product and selected-model rows use quota-axi's
#   existing spendPriority scalar. Exhausted profiles are ineligible, unknown
#   or unrankable profiles remain eligible uncertainty, and the highest ranked
#   profile wins. Equal ranks are settled by lexical profile name so identical
#   evidence is deterministic and array order is never authority.
# - A bound profile is validated in isolation but never reselected. fm-spawn
#   persists both its name and canonical config directory in task metadata and
#   passes them back here on relaunch and recovery.
#
# No function reads, writes, copies, or prints credential-file contents.
# Successful functions set FM_CLAUDE_PROFILE_NAME and
# FM_CLAUDE_PROFILE_CONFIG_DIR. Diagnostics contain only declared profile names
# and config-directory paths, never quota-axi's raw provider output.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

FM_CLAUDE_PROFILE_NAME=
FM_CLAUDE_PROFILE_CONFIG_DIR=

fm_claude_profile_error() {
  printf 'error: Claude profile selection: %s\n' "$1" >&2
  return 1
}

fm_claude_profile_name_valid() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]
}

fm_claude_profile_resolve_dir() { # <profile-name> <absolute-config-dir>
  local name=$1 path=$2 resolved
  case "$path" in
    /*) ;;
    *) fm_claude_profile_error "profile '$name' has relative config_dir '$path'; every configured path must be absolute"; return 1 ;;
  esac
  [ -d "$path" ] || {
    fm_claude_profile_error "profile '$name' config_dir '$path' is missing or is not a directory"
    return 1
  }
  [ -r "$path" ] && [ -x "$path" ] || {
    fm_claude_profile_error "profile '$name' config_dir '$path' is not readable and searchable"
    return 1
  }
  resolved=$(CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || {
    fm_claude_profile_error "profile '$name' config_dir '$path' cannot be resolved"
    return 1
  }
  case "$resolved" in
    *[[:cntrl:]]*)
      fm_claude_profile_error "profile '$name' config_dir resolves to a path containing a control character"
      return 1
      ;;
  esac
  printf '%s\n' "$resolved"
}

fm_claude_profile_quota_snapshot() { # <profile-name> <canonical-config-dir> <output-file>
  local name=$1 path=$2 output=$3
  if ! CLAUDE_CONFIG_DIR="$path" quota-axi --provider claude --profile-only --json >"$output" 2>/dev/null; then
    fm_claude_profile_error "profile '$name' at '$path' is not authenticated or quota-axi could not read that profile in isolation"
    return 1
  fi
  if ! fm_quota_json_valid <"$output" ||
    ! jq -e '.providers | length == 1 and .[0].provider == "claude"' "$output" >/dev/null 2>&1; then
    fm_claude_profile_error "profile '$name' at '$path' returned invalid isolated Claude quota data"
    return 1
  fi
}

fm_claude_profile_tool_ready() {
  command -v jq >/dev/null 2>&1 || {
    fm_claude_profile_error "jq is required for a named Claude profile binding"
    return 1
  }
  command -v quota-axi >/dev/null 2>&1 || {
    fm_claude_profile_error "quota-axi is required for a named Claude profile binding"
    return 1
  }
  quota-axi --help 2>&1 | grep -F -- '--profile-only' >/dev/null || {
    fm_claude_profile_error "installed quota-axi does not support isolated --profile-only measurement; update quota-axi before launching Claude workers"
    return 1
  }
}

fm_claude_profiles_config_valid() { # <config-file>
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || {
    fm_claude_profile_error "config/claude-profiles.json must be a readable regular file, not a symlink"
    return 1
  }
  jq -e '
    type == "object" and
    (keys == ["profiles"]) and
    (.profiles | type) == "array" and
    (.profiles | length) > 0 and
    (all(.profiles[];
      type == "object" and
      (keys | sort) == ["config_dir", "name"] and
      (.name | type) == "string" and
      (.name | test("^[A-Za-z0-9][A-Za-z0-9._@+-]*$")) and
      (.config_dir | type) == "string" and
      (.config_dir | startswith("/")) and
      ((.config_dir | test("[\u0000-\u001f]")) | not))) and
    (([.profiles[].name] | length) == ([.profiles[].name] | unique | length)) and
    (([.profiles[].config_dir] | length) == ([.profiles[].config_dir] | unique | length))
  ' "$file" >/dev/null 2>&1 || {
    fm_claude_profile_error "config/claude-profiles.json must contain only a non-empty profiles array of unique {name, config_dir} objects; names use letters, digits, . _ @ + -, and config_dir values are unique absolute paths"
    return 1
  }
}

fm_claude_profile_evaluate() { # <snapshot> <name> <path> <model>
  local snapshot=$1 name=$2 path=$3 model=$4
  jq -c --arg name "$name" --arg path "$path" --arg model "$model" '
    .providers[0] as $provider |
    ($model | split("/") | last) as $bare |
    [($provider.quotaSemantics.effectiveAvailability // [])[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and $model != "default" and
       (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )] as $rows |
    if any($rows[]; (.runway.status // "") == "exhausted_now") or
       any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)
    then {name: $name, path: $path, eligible: false, reason: "exhausted"}
    elif (["known", "partial"] | index($provider.quotaSemantics.status)) == null
    then {name: $name, path: $path, eligible: true, unranked: true, reason: "quota semantics unmeasured"}
    elif ($rows | length) == 0
    then {name: $name, path: $path, eligible: true, unranked: true, reason: "no applicable quota row"}
    elif any($rows[]; .status != "known")
    then {name: $name, path: $path, eligible: true, unranked: true, reason: "applicable quota row unknown"}
    elif any($rows[]; (.selection.spendPriority | type) != "number")
    then {name: $name, path: $path, eligible: true, unranked: true, reason: "spendPriority unavailable"}
    else ($rows | min_by(.selection.spendPriority)) as $limiting |
      {name: $name, path: $path, eligible: true, spendPriority: $limiting.selection.spendPriority}
    end
  ' "$snapshot"
}

fm_claude_profile_select() { # <config-file> <model>
  local file=$1 model=${2:-default} tmp candidates count i name path resolved candidate result
  FM_CLAUDE_PROFILE_NAME=
  FM_CLAUDE_PROFILE_CONFIG_DIR=
  fm_claude_profile_tool_ready || return 1
  fm_claude_profiles_config_valid "$file" || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-profiles.XXXXXX") || {
    fm_claude_profile_error "could not create a private quota workspace"
    return 1
  }
  chmod 700 "$tmp" || { rm -rf "$tmp"; return 1; }
  candidates="$tmp/candidates.jsonl"
  : >"$candidates"
  count=$(jq -r '.profiles | length' "$file") || { rm -rf "$tmp"; return 1; }
  for ((i = 0; i < count; i++)); do
    name=$(jq -r --argjson i "$i" '.profiles[$i].name' "$file") || { rm -rf "$tmp"; return 1; }
    path=$(jq -r --argjson i "$i" '.profiles[$i].config_dir' "$file") || { rm -rf "$tmp"; return 1; }
    resolved=$(fm_claude_profile_resolve_dir "$name" "$path") || { rm -rf "$tmp"; return 1; }
    if grep -Fqx -- "$resolved" "$tmp/resolved-paths" 2>/dev/null; then
      rm -rf "$tmp"
      fm_claude_profile_error "profile '$name' resolves to the same config directory as another configured profile: '$resolved'"
      return 1
    fi
    printf '%s\n' "$resolved" >>"$tmp/resolved-paths"
    fm_claude_profile_quota_snapshot "$name" "$resolved" "$tmp/quota-$i.json" || { rm -rf "$tmp"; return 1; }
    candidate=$(fm_claude_profile_evaluate "$tmp/quota-$i.json" "$name" "$resolved" "$model") || {
      rm -rf "$tmp"
      fm_claude_profile_error "could not evaluate isolated quota for profile '$name'"
      return 1
    }
    printf '%s\n' "$candidate" >>"$candidates"
  done
  result=$(jq -sc '
    . as $all |
    [$all[] | select(.eligible and ((.unranked // false) | not))] as $ranked |
    [$all[] | select(.eligible and (.unranked // false))] as $uncertain |
    if ($ranked | length) == 0 then
      {ok: false, uncertain: [$uncertain[].name], exhausted: [$all[] | select(.eligible | not) | .name]}
    else
      ($ranked | map(.spendPriority) | max) as $best |
      ([$ranked[] | select(.spendPriority == $best)] | min_by(.name)) as $chosen |
      {ok: true, chosen: $chosen, uncertain: [$uncertain[].name]}
    end
  ' "$candidates") || { rm -rf "$tmp"; return 1; }
  if [ "$(jq -r '.ok' <<<"$result")" != true ]; then
    local uncertain exhausted
    uncertain=$(jq -r '.uncertain | join(", ")' <<<"$result")
    exhausted=$(jq -r '.exhausted | join(", ")' <<<"$result")
    rm -rf "$tmp"
    if [ -n "$uncertain" ]; then
      fm_claude_profile_error "no configured profile has rankable quota evidence; eligible but unmeasurable profiles: $uncertain${exhausted:+; exhausted profiles: $exhausted}"
    else
      fm_claude_profile_error "every configured profile is exhausted: $exhausted"
    fi
    return 1
  fi
  FM_CLAUDE_PROFILE_NAME=$(jq -r '.chosen.name' <<<"$result")
  FM_CLAUDE_PROFILE_CONFIG_DIR=$(jq -r '.chosen.path' <<<"$result")
  local uncertain
  uncertain=$(jq -r '.uncertain | join(", ")' <<<"$result")
  [ -z "$uncertain" ] || printf 'warning: Claude profiles with unmeasurable quota remained eligible but unranked: %s\n' "$uncertain" >&2
  rm -rf "$tmp"
}

fm_claude_profile_validate_binding() { # <profile-name> <canonical-config-dir>
  local name=$1 path=$2 tmp resolved
  FM_CLAUDE_PROFILE_NAME=
  FM_CLAUDE_PROFILE_CONFIG_DIR=
  fm_claude_profile_name_valid "$name" || {
    fm_claude_profile_error "recorded profile name '$name' is invalid"
    return 1
  }
  fm_claude_profile_tool_ready || return 1
  resolved=$(fm_claude_profile_resolve_dir "$name" "$path") || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-claude-profile.XXXXXX") || {
    fm_claude_profile_error "could not create a private quota snapshot"
    return 1
  }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  fm_claude_profile_quota_snapshot "$name" "$resolved" "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  # shellcheck disable=SC2034 # output globals consumed by the sourcing spawn script
  FM_CLAUDE_PROFILE_NAME=$name
  # shellcheck disable=SC2034 # output globals consumed by the sourcing spawn script
  FM_CLAUDE_PROFILE_CONFIG_DIR=$resolved
}
