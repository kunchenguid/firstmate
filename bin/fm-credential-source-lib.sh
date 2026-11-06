# shellcheck shell=bash
# Declared credential sources for provider keys.
# Usage: . bin/fm-credential-source-lib.sh
#
# This file is the single owner of the credential-source declaration: a JSON
# object keyed by provider whose values say WHERE that provider's key lives and
# never hold the key itself, for example
#   {"typesafe": {"source": "macos-keychain", "service": "typesafe-api-key"}}
# bin/fm-dispatch-resolve.sh reads it only after the environment and .env have
# supplied no key, and bin/fm-bootstrap.sh only checks whether it declares a
# typesafe source; docs/configuration.md "Typed dispatch resolution" owns the
# file's location and the operator contract.
#
# A source is an adapter: FM_CREDSRC_SCHEMA names each adapter and its fields,
# fm_credsrc_supported says whether this host can run it, and fm_credsrc_read
# fetches the key through it. macos-keychain is the first. A further adapter
# adds one schema entry and one arm to those two functions; nothing here knows
# which provider is asking, so the shared surface binds to no one OS or vendor.
#
# Secret containment: a key leaves fm_credsrc_read on stdout for the caller's
# command substitution and nowhere else. It is never an argument, an
# environment variable, a file, or a log line. An adapter passes only the
# fields that identify the item to its tool, and discards the tool's stderr
# because that can echo what it was given. fm_credsrc_supported never runs the
# tool, so asking whether a source is available retrieves no credential.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# Adapter name -> the fields it takes. A declaration holds "source" plus
# exactly these fields, so no field exists for a credential value to sit in.
FM_CREDSRC_SCHEMA='{"macos-keychain":{"required":["service"],"optional":["account"]}}'

# Seconds one adapter read may take, so an access prompt nobody answers cannot
# hold the caller.
FM_CREDSRC_TIMEOUT=5

# fm_credsrc_supported <source>
# Succeed when <source> names an adapter this host can run. It checks the host
# and that the adapter's tool is on PATH, and runs nothing else.
fm_credsrc_supported() {
  case "${1:-}" in
    macos-keychain)
      [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# fm_credsrc_check <file> <provider>...
# Succeed, printing nothing, when <file> is one JSON object whose keys are all
# among the named providers and whose values are well-formed declarations.
# Otherwise print the first problem on one line and fail. A problem names the
# provider, the field, or the allowed values; it never prints a declared value.
fm_credsrc_check() {
  local file=$1 providers problem
  shift
  providers=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
  problem=$(jq -rs --argjson schema "$FM_CREDSRC_SCHEMA" --argjson providers "$providers" '
    def flat: explode | map(if . < 32 or . == 127 then 63 else . end) | implode;
    def plain: type == "string" and length > 0 and (explode | all(. >= 32 and . != 127));
    def entry($name; $d):
      if ($d | type) != "object" then "\($name) must be an object with a source"
      elif ($d | has("source") | not) then "\($name) needs a source"
      elif ($d.source | type) != "string" or ($schema | has($d.source) | not) then
        "\($name) source must be one of \($schema | keys | join(", "))"
      else
        $schema[$d.source] as $f
        | (["source"] + $f.required + $f.optional) as $allowed
        | ([$d | keys_unsorted[] | select(. as $k | $allowed | index($k) | not)]) as $extra
        | ([$f.required[] | . as $k | select(($d[$k] | plain) | not)]) as $bad_required
        | ([$f.optional[] | . as $k | select($d | has($k)) | select(($d[$k] | plain) | not)]) as $bad_optional
        | if ($extra | length) > 0 then
            "\($name) has unknown field \($extra[0] | flat) (allowed: \($allowed | join(", "))); credential values do not belong in this file"
          elif ($bad_required | length) > 0 then
            "\($name) \($bad_required[0]) must be a non-empty string without control characters"
          elif ($bad_optional | length) > 0 then
            "\($name) \($bad_optional[0]) must be a non-empty string without control characters when present"
          else empty end
      end;
    if length != 1 then "must hold exactly one JSON object"
    elif (.[0] | type) != "object" then "top-level value must be an object keyed by provider"
    else
      .[0] as $doc
      | ([$doc | keys_unsorted[] | select(. as $k | $providers | index($k) | not)]) as $unknown
      | if ($unknown | length) > 0 then
          "unknown provider \($unknown[0] | flat) (expected \($providers | join(" or ")))"
        else first(($doc | to_entries[] | entry(.key; .value)), empty)
        end
    end' "$file" 2>/dev/null) || problem='not JSON'
  if [ -z "$problem" ]; then
    return 0
  fi
  printf '%s\n' "$problem"
  return 1
}

# fm_credsrc_declares <file> <provider>
# Succeed when <file> declares a source for <provider>.
fm_credsrc_declares() {
  jq -e --arg p "$2" 'has($p)' "$1" >/dev/null 2>&1
}

# fm_credsrc_field <file> <provider> <field>
# Print one declared field of <provider>'s source, or nothing when it is absent.
# Call only on a file fm_credsrc_check accepted, which keeps every value on one
# printable line.
fm_credsrc_field() {
  jq -r --arg p "$2" --arg f "$3" '.[$p][$f] // empty' "$1"
}

# fm_credsrc_read <file> <provider>
# Print the key <provider>'s declared source yields. Status 0 means a non-empty
# read; fm_timed_out accepts the status when the source did not answer within
# its bound; any other status means the source holds no readable key. Call only
# on a file fm_credsrc_check accepted and fm_credsrc_supported agreed to run.
fm_credsrc_read() {
  local src service account
  src=$(fm_credsrc_field "$1" "$2" source)
  case "$src" in
    macos-keychain)
      service=$(fm_credsrc_field "$1" "$2" service)
      account=$(fm_credsrc_field "$1" "$2" account)
      fm_credsrc_macos_keychain "$service" "$account"
      ;;
    *) return 1 ;;
  esac
}

# macos-keychain: one generic-password read, bounded by FM_CREDSRC_TIMEOUT.
# Only the service and, when declared, the account reach argv; the key comes
# back on stdout.
fm_credsrc_macos_keychain() {  # <service> [<account>]
  if [ -n "${2:-}" ]; then
    fm_run_timed "$FM_CREDSRC_TIMEOUT" security find-generic-password -s "$1" -a "$2" -w 2>/dev/null </dev/null
  else
    fm_run_timed "$FM_CREDSRC_TIMEOUT" security find-generic-password -s "$1" -w 2>/dev/null </dev/null
  fi
}
