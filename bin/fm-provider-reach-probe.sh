#!/usr/bin/env bash
# fm-provider-reach-probe.sh - one hard-bounded reachability probe of a named
# model-provider endpoint: DNS resolution plus one unauthenticated HTTP request.
#
# This script collects a FACT and renders no verdict. It reads no dispatch
# configuration, holds no provider table, and never decides whether a candidate
# is eligible or which route to take. The dispatching first mate owns that
# judgment from `quota-axi`'s data plus each harness's authoritative model
# catalog (`.agents/skills/quota-array-dispatch/SKILL.md`).
#
# Why it exists: upstream outage was previously visible only by reading worker
# panes, so "the endpoint is down" was never a machine-readable condition at an
# intake. This turns that finding into one bounded call with a readable exit
# status. It is not a service, a daemon, a watcher, or a control plane: nothing
# registers it, it keeps no state, and it runs only when called.
#
# What it deliberately cannot prove: a 2xx establishes only that the endpoint is
# routable and answering. It is never evidence that a model is usable, that a
# credential works, or that a large or long-output request will succeed; this
# home has recorded outages where small requests returned 200 while large ones
# hung. Never record a 2xx as "channel available".
#
# Usage:
#   fm-provider-reach-probe.sh <target> [options]
#   fm-provider-reach-probe.sh --host <authority> [options]
#
# Targets are registered endpoints whose discriminator behavior was verified
# first-hand and recorded in docs/verification/provider-reach.md:
#   xhy      https://api.xhyapi.com/v1/models
#
# Options:
#   --timeout <seconds>   same bound as FM_PROVIDER_REACH_PROBE_TIMEOUT and
#                         preferred over it; must be a positive integer
#   -h, --help            print this usage and exit 0
#
# Output: exactly one line on stdout. No token, key, header, or response body is
# ever printed; the HTTP status code and DNS rcode are protocol facts, not secrets.
#
#   probe=<target> dns=<ok|nxdomain|fail|skipped> http=<code|none> result=<verdict> <detail>
#
# result is evidence, never eligibility. Each verdict carries its own exit status:
#   reachable        0    HTTP 2xx: routable and answering, nothing more proven
#   routed-auth      10   HTTP 401 or 403: a request reached the endpoint and was
#                         refused, so routing works but usability is NOT proven
#   server-error     11   HTTP 5xx or any other code: answered, unhealthy or unknown
#   unreachable      20   connection failed, timeout, or no address: NXDOMAIN or any
#                         other lookup failure prints dns=fail and exits 20 too,
#                         because either way the endpoint could not be connected to
#   invalid-target   2    the registered target cannot yield an authority for a
#                         request, e.g. its base URL has no host part
#   invalid-input    2    unknown target or host, a non-numeric, zero, or negative
#                         --timeout value, duplicate options, a missing option
#                         value, or an unexpected extra argument
#   tool-missing     64   curl is not installed: nothing was probed and the line
#                         says so rather than silently reporting another outcome
# Exit 2 is reserved for usage and target-configuration errors. A running probe
# always prints exactly one line on stdout, including tool-missing and
# invalid-target; invalid-input is the one error path that prints only on stderr.
#
# Environment:
#   FM_PROVIDER_REACH_PROBE_TIMEOUT   hard per-phase bound in seconds; must be a
#                                     positive integer, else the default 10 is
#                                     used. Zero is rejected because `timeout 0`
#                                     and the Perl fallback's `alarm 0` both mean
#                                     "no deadline".
#   FM_PROVIDER_REACH_DNS_TOOL        one resolver CLI, or a whitespace-separated
#                                     preference list tried in order until one that
#                                     is installed answers (default: /usr/bin/dig,
#                                     then /usr/bin/host). Each entry takes the
#                                     bare authority and no other argument, so a
#                                     tool needs its own entry - and a token that
#                                     is not an installed tool is skipped, never
#                                     run. Tests use it to keep DNS deterministic.
#   FM_PROVIDER_REACH_TARGET_BASE     test seam for the registered-target table:
#                                     when FM_TEST_SEAM is 1, this replaces the
#                                     recorded base URL of the named registered
#                                     target. It registers nothing, so an
#                                     unregistered target stays a refusal and an
#                                     unset value keeps the recorded URL.
#                                     Unset outside a test suite.
#   FM_TEST_SEAM                      when 1, allow FM_PROVIDER_REACH_CURL_CMD to
#                                     name the curl executable, so a suite can
#                                     prove the curl-absent branch on a host whose
#                                     /usr/bin/curl cannot otherwise be hidden.
#                                     Unset outside a test suite, so a normal run
#                                     always uses this host's real curl.
set -u

DEFAULT_TIMEOUT=10
XHY_BASE=https://api.xhyapi.com/v1/models
DNS_DEFAULT_CANDIDATES='/usr/bin/dig /usr/bin/host'

usage() {
  cat <<'EOF'
fm-provider-reach-probe.sh - one hard-bounded reachability probe of a named
model-provider endpoint: DNS resolution plus one unauthenticated HTTP request.
It collects a fact and renders no verdict: it reads no dispatch configuration,
holds no provider table, and never decides dispatch eligibility or routing.

Usage:
  fm-provider-reach-probe.sh <target> [options]
  fm-provider-reach-probe.sh --host <authority> [options]

Registered targets:
  xhy      https://api.xhyapi.com/v1/models

Options:
  --timeout <seconds>   hard per-phase bound (positive integer, default 10);
                        beats FM_PROVIDER_REACH_PROBE_TIMEOUT
  -h, --help            show this help

Prints exactly one line on stdout:
  probe=<target> dns=<ok|nxdomain|fail|skipped> http=<code|none> result=<verdict> <detail>

A 2xx proves routability only - never that a model, credential, or large request
works - so it is recorded as reachable, not as "channel available".
A 401 or 403 means a request reached the endpoint and was refused: routing works,
usability is not proven.

Exit status (verdicts are not eligibility):
  0   reachable       HTTP 2xx
  10  routed-auth     HTTP 401/403
  11  server-error    HTTP 5xx or other code
  20  unreachable     connection failed, timed out, or no address (NXDOMAIN
                      and other lookup failures also exit 20 with dns=fail)
  2   invalid-target  registered target yields no request authority
  2   invalid-input   unknown target/host, bad or repeated --timeout, missing
                      value, or extra argument (stderr only)
  64  tool-missing    curl absent: nothing probed, one line on stdout
EOF
}

# One diagnostic line on stderr, then exit 2. Nothing goes to stdout, so a
# caller never reads a partial probe line for a probe that never ran.
die_input() {
  printf 'fm-provider-reach-probe: %s\n' "$1" >&2
  exit 2
}

TARGET=''
HOST_ARG=''
TIMEOUT_ARG=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host)
      [ -n "${2:-}" ] || die_input "--host needs a value"
      [ -z "$HOST_ARG" ] || die_input "only one --host may be given"
      HOST_ARG=$2; shift 2 ;;
    --timeout)
      [ -n "${2:-}" ] || die_input "--timeout needs a value"
      [ -z "$TIMEOUT_ARG" ] || die_input "only one --timeout may be given"
      TIMEOUT_ARG=$2; shift 2 ;;
    -*) die_input "unknown option: $1" ;;
    *)
      [ -z "$TARGET" ] || die_input "only one target may be probed at a time"
      TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || [ -n "$HOST_ARG" ] || die_input "a target or --host is required"
if [ -n "$TARGET" ] && [ -n "$HOST_ARG" ]; then
  die_input "give either a registered target or --host, not both"
fi

# Positive integer or the default: `timeout 0` and the Perl fallback's `alarm 0`
# both disable the deadline, so a hung endpoint would otherwise run unbounded.
normalize_timeout() {
  case "$1" in
    ''|0|*[!0-9]*|0[0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] || return 1
  return 0
}

TIMEOUT=${FM_PROVIDER_REACH_PROBE_TIMEOUT:-$DEFAULT_TIMEOUT}
normalize_timeout "$TIMEOUT" || TIMEOUT=$DEFAULT_TIMEOUT
if [ -n "$TIMEOUT_ARG" ]; then
  # An explicit --timeout is a contract violation, not a hint: refuse loudly
  # rather than quietly falling back to the default the caller did not ask for.
  normalize_timeout "$TIMEOUT_ARG" || die_input "--timeout must be a positive integer, got '$TIMEOUT_ARG'"
  TIMEOUT=$TIMEOUT_ARG
fi

# Bounded execution is owned by bin/fm-timeout-lib.sh, so a macOS host without
# coreutils still gets a hard bound instead of an unbounded endpoint call.
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

PROBE=$TARGET
BASE=''
if [ -n "$HOST_ARG" ]; then
  case "$HOST_ARG" in
    *@*) die_input "--host must not contain userinfo" ;;
  esac
  PROBE=host:$HOST_ARG
  BASE=https://$HOST_ARG
elif [ "$TARGET" = xhy ]; then
  PROBE=xhy
  BASE=$XHY_BASE
else
  die_input "no probe is registered for target '$TARGET'"
fi

# A recorded base URL with no host part cannot yield a request authority: that is a
# registration defect, never a healthy probe, so it gets its own verdict before any
# resolver or request runs instead of letting curl invent a connection failure. The
# seam below is the only way to stand such a registration up under test; outside an
# armed suite every target probes the URL recorded above it.
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_PROVIDER_REACH_TARGET_BASE:-}" ]; then
  BASE=$FM_PROVIDER_REACH_TARGET_BASE
fi
AUTHORITY=$(printf '%s\n' "$BASE" | sed -nE 's|^https?://([^/?#]+).*|\1|p')
if [ -z "$AUTHORITY" ]; then
  printf 'probe=%s dns=skipped http=none result=invalid-target base_url_has_no_authority\n' "$PROBE"
  exit 2
fi

DNS=skipped
HTTP=none
DETAIL=''

# ---- phase 1: name resolution ------------------------------------------------
# Best-effort and separately reported: a resolver tool's absence or its own odd
# output never becomes an outage claim. When the lookup already found no address
# the HTTP phase is skipped, because dialing a name with no address adds noise,
# not information.
#
# Availability is decided per candidate inside dns_probe, never by testing the
# whole configured value as one executable: an override may be a preference list,
# and `command -v "dig host"` fails while dig itself sits right there on PATH.
# A pre-gate over the combined string silently skipped the resolver that was
# actually installed and reported a lookup that never ran as dns=skipped.
dns_probe() {
  local tool out rc first
  # The override is one tool or a whitespace-separated preference list; unset
  # means this host's own candidates in order.
  for tool in ${FM_PROVIDER_REACH_DNS_TOOL:-$DNS_DEFAULT_CANDIDATES}; do
    [ -n "$tool" ] || continue
    case "$tool" in
      /*) [ -x "$tool" ] || continue ;;
      *) command -v "$tool" >/dev/null 2>&1 || continue ;;
    esac
    # Both candidates take the bare authority and no category argument. macOS
    # ships /usr/bin/dscacheutil, whose `-q` requires a valid directory-service
    # category (`host` is not one), so it answers any name with its usage block
    # and exit 64; calling it here recorded "the resolver errored" for names that
    # `dig` and `host` both reported as NXDOMAIN. It is therefore not a candidate.
    out=$(fm_run_timed "$TIMEOUT" "$tool" "$AUTHORITY" 2>/dev/null </dev/null) && rc=0 || rc=$?
    if [ "$rc" -eq 124 ]; then
      printf 'fail timeout_after_%ss\n' "$TIMEOUT"
      return 0
    fi
    first=$(printf '%s\n' "$out" | head -n 1)
    # A successful answer naming no address is the same finding as NXDOMAIN for
    # routing purposes, so both classes are checked before exit status.
    if printf '%s\n' "$out" | grep -qiE 'NXDOMAIN|no answer|not found'; then
      printf 'nxdomain %s\n' "${first:-no-address}"
      return 0
    fi
    if printf '%s\n' "$out" | grep -qiE 'SERVFAIL|FORMERR|REFUSED|timed out'; then
      printf 'fail rc=%s\n' "$rc"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'fail rc=%s\n' "$rc"
      return 0
    fi
    if printf '%s\n' "$out" | grep -qE '(^|[[:space:]])([0-9]{1,3}\.){3}[0-9]{1,3}([[:space:]]|$)|(^|[[:space:]])[0-9a-fA-F]*:[0-9a-fA-F:]+([[:space:]]|$)'; then
      printf 'ok %s\n' "${first:-address}"
      return 0
    fi
    printf 'nxdomain no-address\n'
    return 0
  done
  return 1
}

DNS_RESULT=$(dns_probe)
if [ -n "$DNS_RESULT" ]; then
  DNS=${DNS_RESULT%% *}
  DETAIL="${DETAIL} dns_detail=${DNS_RESULT#* }"
else
  DNS=skipped
  DETAIL="${DETAIL} dns_tool_missing"
fi

# ---- emit terminal DNS-only results ------------------------------------------
if [ "$DNS" = nxdomain ] || [ "$DNS" = fail ]; then
  printf 'probe=%s dns=%s http=none result=unreachable%s\n' "$PROBE" "$DNS" "$DETAIL"
  exit 20
fi

# ---- phase 2: one unauthenticated HTTP request -------------------------------
# Only an armed test suite may redirect the request away from this host's curl; a
# leaked variable alone does nothing without the suite marker. Resolving the
# executable is one check, so "this surface cannot be probed" stays its own
# outcome (exit 64) rather than collapsing into a connection failure.
CURL_CMD=curl
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_PROVIDER_REACH_CURL_CMD:-}" ]; then
  CURL_CMD=$FM_PROVIDER_REACH_CURL_CMD
fi
command -v "$CURL_CMD" >/dev/null 2>&1 || {
  printf 'probe=%s dns=%s http=none result=tool-missing curl_not_installed%s\n' "$PROBE" "$DNS" "$DETAIL"
  exit 64
}

http_output=$(mktemp 2>/dev/null) || http_output=/tmp/fm-provider-reach-probe.$$
trap 'rm -f "$http_output"' EXIT
HTTP_CODE=$(fm_run_timed "$TIMEOUT" "$CURL_CMD" -q -sS -o "$http_output" -w '%{http_code}' \
  --max-time "$TIMEOUT" "$BASE" </dev/null 2>/dev/null) || HTTP_CODE=000
case "$HTTP_CODE" in
  ''|*[!0-9]*) HTTP_CODE=000 ;;
esac
HTTP=$HTTP_CODE

RESULT=unreachable
case "$HTTP_CODE" in
  2??) RESULT=reachable ;;
  401|403) RESULT=routed-auth ;;
  000) RESULT=unreachable ;;
  5??) RESULT=server-error ;;
  *) RESULT=server-error ;;
esac
if [ "$HTTP_CODE" = 000 ]; then
  DETAIL="${DETAIL} reason=no_connection"
fi

printf 'probe=%s dns=%s http=%s result=%s%s\n' "$PROBE" "$DNS" "$HTTP" "$RESULT" "$DETAIL"
case "$RESULT" in
  reachable) exit 0 ;;
  routed-auth) exit 10 ;;
  server-error) exit 11 ;;
  *) exit 20 ;;
esac
