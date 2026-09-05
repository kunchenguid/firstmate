# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, plus the
# per-account Codex quota read.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# fm_quota_axi_read_codex_home [--timeout <secs>] <codex-home> [quota-axi flags...]
#   quota-axi reads the Codex account from CODEX_HOME, the same variable the
#   codex CLI reads, so one ChatGPT account's evidence is one read with that
#   account's home exported. This helper expands and validates the home through
#   bin/fm-codex-home-lib.sh (a missing or empty auth.json refuses with that
#   reason on stderr instead of silently reporting the default account), then
#   runs `CODEX_HOME=<expanded> quota-axi --provider codex` with any extra flags
#   appended, so the default TOON, the skill's narrow --json fallback, and the
#   per-account quota watch (bin/fm-procevent-quota.sh --codex-home) share one
#   entry point. With --timeout the read is bounded through fm_run_timed
#   (bin/fm-timeout-lib.sh must already be sourced), so a hung quota-axi ends
#   with 124 instead of stalling the caller. The output is that home's
#   provider-level Codex evidence and bounds only candidates carrying that
#   codexHome (quota-array-dispatch owns how it is ranked).

# shellcheck source=bin/fm-codex-home-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-codex-home-lib.sh"

FM_QUOTA_AXI_MIN=0.1.29

fm_quota_axi_read_codex_home() {
  local home timeout=
  if [ "${1:-}" = --timeout ]; then
    timeout=${2:-}
    case "$timeout" in
      ''|*[!0-9]*|0)
        echo "error: codex quota read needs a positive integer --timeout" >&2
        return 1
        ;;
    esac
    shift 2
  fi
  fm_codex_home_validate "${1:-}" || {
    echo "error: codex quota read refused: $FM_CODEX_HOME_ERROR" >&2
    return 1
  }
  home=$FM_CODEX_HOME_PATH
  shift
  command -v quota-axi >/dev/null 2>&1 || {
    echo "error: quota-axi is not installed" >&2
    return 1
  }
  if [ -n "$timeout" ]; then
    [ "$(type -t fm_run_timed)" = function ] || {
      echo "error: codex quota read --timeout needs bin/fm-timeout-lib.sh" >&2
      return 1
    }
    CODEX_HOME=$home fm_run_timed "$timeout" quota-axi --provider codex "$@" </dev/null
  else
    CODEX_HOME=$home quota-axi --provider codex "$@" </dev/null
  fi
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_json_valid() {
  jq -se '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      .schemaVersion == 5 and
      (.providers | type) == "array" and
      (([.providers[].provider] | length) == ([.providers[].provider] | unique | length)) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}
