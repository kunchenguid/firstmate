# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.

FM_QUOTA_AXI_MIN=0.1.29
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
      output=$(timeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v gtimeout >/dev/null 2>&1; then
      output=$(gtimeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v perl >/dev/null 2>&1; then
      output=$(perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    else
      return 1
    fi
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
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and (.[0] | type) == "object" and (.[0] |
      .schemaVersion == 5 and (.providers | type) == "array" and
      (([.providers[].provider] | length) == ([.providers[].provider] | unique | length)) and
      all(.providers[];
        (.provider | type) == "string" and (.provider | test($provider_re)) and
        (.quotaSemantics | type) == "object" and
        (.quotaSemantics.status as $s |
          (["known", "partial", "unknown"] | index($s)) != null and
          (.quotaSemantics.effectiveAvailability | type) == "array" and
          (if $s == "known" then
             ((.quotaSemantics.effectiveAvailability | length) > 0 and
              all(.quotaSemantics.effectiveAvailability[]; .status == "known" or .status == "unknown"))
           elif $s == "unknown" then
             all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
           else true end) and
          all(.quotaSemantics.effectiveAvailability[];
            type == "object" and (.scope | type) == "string" and (.scope | length) > 0 and
            ((.scope | test("^\\s|\\s$")) | not) and
            ((.status == "known" and
              (.runway.status as $r |
                ((.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining >= 0 and .effectivePercentRemaining <= 100 and
                 (.runway | type) == "object" and ($r | type) == "string" and
                 (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] | index($r)) != null))) or
             (.status == "unknown" and (has("effectivePercentRemaining") | not) and
              ((has("runway") | not) or ((.runway | type) == "object" and
                (.runway.status as $u | (["unknown", "exhausted_now"] | index($u)) != null)))))
          )
        )
      )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'muse meta'
}

fm_quota_single_provider_for_harness() {
  local harness provider
  while read -r harness provider; do
    if [ "$harness" = "$1" ]; then
      printf '%s\n' "$provider"
      return 0
    fi
  done < <(fm_quota_single_provider_table)
  return 1
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*) printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *) return 1 ;;
      esac
      ;;
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    opencode) printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok) printf 'grok\n' ;;
    kimi) printf 'kimi\n' ;;
    cursor) printf 'cursor\n' ;;
    muse) printf 'meta\n' ;;
    *) return 1 ;;
  esac
}
