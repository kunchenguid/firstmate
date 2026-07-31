#!/usr/bin/env bash
# fm-auth-preflight.sh - bounded, selected-surface authentication evidence for
# one dispatch tuple.
#
# The semantic dispatch policy is owned once by
# .agents/skills/quota-array-dispatch/SKILL.md. This script owns only the
# deterministic mechanics that must not depend on agent memory: which
# authentication surface a concrete (harness, model) tuple actually uses,
# whether that one surface is usable, and whether that candidate is dispatchable.
# It never selects a candidate and never ranks one.
#
# Why it exists: a locally expired timestamp in ONE credential store used to be
# reported as "the captain is signed out", including for tuples that never read
# that store. The surface is resolved from quota-axi's own emitted auth sources
# rather than from a harness name, so another harness's CLI can never gate a
# tuple that does not use it.
#
# Surface resolution (all grounded in `quota-axi auth --json` output, never
# inferred from a model name alone):
#   harness=pi / pi-signed  -> source `pi:<provider-prefix-of-model>`
#                              (e.g. model=xai/grok-4.5 -> source `pi:xai`)
#   harness=grok            -> the grok provider's own non-Pi sources
#   harness=claude          -> the claude provider's own non-Pi sources
#   harness=codex           -> the codex provider's own non-Pi sources
#   harness=kimi            -> the kimi provider's own non-Pi sources
#   verified harnesses without a quota-axi surface
#                          -> explicit no-auth-evidence with unknown auth/headroom
#   anything else           -> unresolved (quota-axi models no such provider)
# The quota provider is whichever provider actually lists that source, so the
# mapping cannot drift from what the tool emits.
#
# Bounded probe policy. A vendor CLI is launched only when the tuple's OWN
# harness owns the credential store AND a non-destructive discovery command is
# registered for it. Today that is `grok models` alone, under the captain's
# 2026-07-30 `firstmate-grok-auth-preflight` decision. A `harness=pi` tuple
# never launches the Grok CLI, whatever its model provider is. The probe runs at
# most once, with stdin closed and a hard timeout, and the authentication
# verdict is read from the first stdout line because the command exits 0 in both
# the authenticated and unauthenticated cases. Unrecognized output is
# `indeterminate` and is never read as authenticated. `login`, `logout`, and the
# interactive TUI are never invoked; the probe argv is fixed, not caller-supplied.
#
# Quota is read at most twice: once from the caller's intake snapshot or a first
# read, then exactly one retry after the selected-surface preflight for every
# resolved candidate. Any unknown applicable scope makes headroom unknown, and
# unknown headroom never makes a candidate ineligible on its own - that is the
# whole point of the captain's `dispatch-usable-auth-unknown-quota` decision.
#
# Requires a quota-axi at or above the floor owned by bin/fm-quota-axi-lib.sh:
# older builds emit neither `state.authStatus` nor the independent Pi credential
# source, so their data cannot scope a surface at all. An older or missing binary
# is reported as unresolved rather than guessed around.
#
# docs/verification/dispatch-auth.md holds the dated producer-schema and vendor
# probe evidence this script's pinned version and output patterns rest on.
#
# Output: exactly one sanitized `key=value` line on stdout. No token, refresh
# token, header, path, length, prefix, hash, or raw vendor output is ever
# printed, logged, or passed in an argument.
#
#   harness=            the requested harness
#   model=              the requested model
#   provider=           quota-axi provider owning the resolved surface, or none
#   surface=            resolved auth source id (e.g. pi:xai, auth-json), or none
#   authStatus=         usable | expired | unusable | unknown | unresolved (THIS surface)
#   providerAuthStatus= quota-axi's aggregate provider authStatus, or none
#   headroom=           the most conservative known effective percent remaining
#                       across the provider's scopes, or unknown when any
#                       applicable scope is unknown. It is a disclosure fact;
#                       the dispatch owner still reads the applicable scope from
#                       the intake snapshot for ordering.
#   preflight=          not-applicable | authenticated | unauthenticated |
#                       indeterminate | timeout | unavailable
#   probeVersion=       vendor CLI version when a probe ran, else none
#   probeVersionVerified= yes | no | none
#   quotaRetry=         none | known | unknown | failed
#   eligible=           yes | no - whether this candidate may be dispatched
#   reason=             stable slug for the verdict
#
# `eligible=no` means report THIS candidate with its reason, not that the captain
# must be contacted. The dispatch owner drops it from the array and reaches the
# captain only when no eligible candidate remains.
#
# Exit status: 0 when eligible=yes, 3 when eligible=no (fail closed on any
# internal failure), 2 on a usage error. The line is printed in every case
# except a usage error.
#
# Usage:
#   fm-auth-preflight.sh --harness <harness> --model <model>
#     [--auth-json <path>] [--quota-json <path>]
#
#   --auth-json <path>   reuse a captured `quota-axi auth --json` document
#   --quota-json <path>  reuse the intake's `quota-axi --json` snapshot
#
# Environment:
#   FM_AUTH_PREFLIGHT_TIMEOUT   hard per-command bound in seconds (default 20)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

VERIFIED_GROK_VERSION=0.2.112

HARNESS=
MODEL=
AUTH_JSON=
QUOTA_JSON=

usage() {
  cat <<'EOF'
fm-auth-preflight.sh - bounded, selected-surface authentication evidence for one
dispatch tuple. Resolves the surface a concrete (harness, model) tuple actually
authenticates through, reports whether that one surface is usable, and decides
whether that candidate is dispatchable. It never selects or ranks a candidate,
and it never launches another harness's CLI.

Usage:
  fm-auth-preflight.sh --harness <harness> --model <model>
    [--auth-json <path>] [--quota-json <path>]

  --auth-json <path>   reuse a captured `quota-axi auth --json` document
  --quota-json <path>  reuse the intake's `quota-axi --json` snapshot

Prints one sanitized key=value line: harness, model, provider, surface,
authStatus, providerAuthStatus, headroom, preflight, probeVersion,
probeVersionVerified, quotaRetry, eligible, reason.

`eligible=no` means report THIS candidate with its reason and drop it from the
array; reach the captain only when no eligible candidate remains.

Exit status: 0 when eligible=yes, 3 when eligible=no (fail closed), 2 on a usage
error. Requires a quota-axi at or above the floor in bin/fm-quota-axi-lib.sh.

Environment:
  FM_AUTH_PREFLIGHT_TIMEOUT   hard per-command bound in seconds (default 20)
EOF
}

die_usage() {
  printf 'fm-auth-preflight: %s\n' "$1" >&2
  printf 'usage: fm-auth-preflight.sh --harness <harness> --model <model> [--auth-json <path>] [--quota-json <path>]\n' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) [ $# -ge 2 ] || die_usage "--harness needs a value"; HARNESS=$2; shift 2 ;;
    --model) [ $# -ge 2 ] || die_usage "--model needs a value"; MODEL=$2; shift 2 ;;
    --auth-json) [ $# -ge 2 ] || die_usage "--auth-json needs a path"; AUTH_JSON=$2; shift 2 ;;
    --quota-json) [ $# -ge 2 ] || die_usage "--quota-json needs a path"; QUOTA_JSON=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$HARNESS" ] || die_usage "--harness is required"
[ -n "$MODEL" ] || die_usage "--model is required"

TIMEOUT=${FM_AUTH_PREFLIGHT_TIMEOUT:-20}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=20 ;; esac

# Bounded execution, mirroring bin/fm-fleet-snapshot.sh's run_timed selection so
# a macOS host without coreutils still gets a hard bound instead of an unbounded
# vendor CLI call. Exit 124 means the bound was hit.
run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

PROVIDER=none
SURFACE=none
AUTH_STATUS=unresolved
PROVIDER_AUTH_STATUS=none
HEADROOM=unknown
PREFLIGHT=not-applicable
PROBE_VERSION=none
PROBE_VERSION_VERIFIED=none
QUOTA_RETRY=none
# Fail closed: an unresolved surface is never dispatchable.
ELIGIBLE=no
REASON=surface-unresolved

emit() {
  printf 'harness=%s model=%s provider=%s surface=%s authStatus=%s providerAuthStatus=%s headroom=%s preflight=%s probeVersion=%s probeVersionVerified=%s quotaRetry=%s eligible=%s reason=%s\n' \
    "$HARNESS" "$MODEL" "$PROVIDER" "$SURFACE" "$AUTH_STATUS" \
    "$PROVIDER_AUTH_STATUS" "$HEADROOM" "$PREFLIGHT" "$PROBE_VERSION" \
    "$PROBE_VERSION_VERIFIED" "$QUOTA_RETRY" "$ELIGIBLE" "$REASON"
  [ "$ELIGIBLE" = yes ] && exit 0
  exit 3
}

finish() {  # <eligible> <reason>
  ELIGIBLE=$1
  REASON=$2
  emit
}

# Resolve the surface from quota-axi's emitted auth sources. Prints
# "<provider> <source-id> <status>"; a missing provider or source prints nothing
# so the caller fails closed.
resolve_surface() {  # <auth-json-path> <harness> <model>
  node - "$@" <<'NODE'
const fs = require("fs");

const args = process.argv.slice(1);
if (args[0] === "-") args.shift();
const [path, harness, model] = args;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function fail() {
  process.exit(1);
}

let document;
try {
  document = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (error) {
  fail();
}

const entries = document && document.auth;
if (!Array.isArray(entries)) fail();

const ownStore = {
  grok: "grok",
  claude: "claude",
  codex: "codex",
  kimi: "kimi",
};
const verifiedHarnesses = new Set([
  "claude",
  "codex",
  "opencode",
  "pi",
  "pi-signed",
  "grok",
  "kimi",
]);

function sourcesFor(providerName) {
  for (const entry of entries) {
    if (isObject(entry) && entry.provider === providerName) {
      return Array.isArray(entry.sources) ? entry.sources : [];
    }
  }
  return null;
}

function collapse(sources) {
  const statuses = sources
    .filter((source) => isObject(source))
    .map((source) => source.status);
  if (statuses.length === 0) return null;
  if (statuses.includes("available")) return "usable";
  if (statuses.includes("expired")) return "expired";
  if (statuses.includes("missing")) return "unusable";
  return null;
}

if (harness === "pi" || harness === "pi-signed") {
  const separator = model.indexOf("/");
  const prefix = separator >= 0 ? model.slice(0, separator) : "";
  if (!prefix) fail();
  const sourceId = `pi:${prefix}`;
  for (const entry of entries) {
    if (!isObject(entry) || typeof entry.provider !== "string" || !Array.isArray(entry.sources)) {
      continue;
    }
    const scoped = entry.sources.filter(
      (source) => isObject(source) && source.source === sourceId,
    );
    if (scoped.length === 0) continue;
    const status = collapse(scoped);
    if (status === null) fail();
    console.log(entry.provider, sourceId, status);
    process.exit(0);
  }
  fail();
}

if (!Object.prototype.hasOwnProperty.call(ownStore, harness) && verifiedHarnesses.has(harness)) {
  const parts = model.split("/");
  if (parts.length !== 2 || parts.some((part) => part.trim() === "")) fail();
  console.log("none none unknown");
  process.exit(0);
}

const providerName = ownStore[harness];
if (!providerName) fail();
const sources = sourcesFor(providerName);
if (!sources || sources.length === 0) fail();
const scoped = sources.filter(
  (source) => isObject(source) && typeof source.source === "string" && !source.source.startsWith("pi:"),
);
if (scoped.length === 0) fail();
const status = collapse(scoped);
if (status === null) fail();
console.log(providerName, scoped.map((source) => source.source).join(","), status);
NODE
}

# Print "<providerAuthStatus> <headroom>" from a quota document. Both fall back
# to "none"/"unknown" rather than being invented.
read_quota() {  # <quota-json-path> <provider>
  node - "$@" <<'NODE'
const fs = require("fs");

const args = process.argv.slice(1);
if (args[0] === "-") args.shift();
const [path, providerName] = args;

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

let document;
try {
  document = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (error) {
  console.log("none unknown");
  process.exit(0);
}

const providers = document && document.providers;
if (!Array.isArray(providers)) {
  console.log("none unknown");
  process.exit(0);
}

let authStatus = "none";
let headroom = "unknown";
for (const entry of providers) {
  if (!isObject(entry) || entry.provider !== providerName) continue;
  if (isObject(entry.state) && typeof entry.state.authStatus === "string") {
    authStatus = entry.state.authStatus;
  }
  if (isObject(entry.quotaSemantics) && Array.isArray(entry.quotaSemantics.effectiveAvailability)) {
    const availability = entry.quotaSemantics.effectiveAvailability;
    const known = availability.filter(
      (scope) =>
        isObject(scope) &&
        scope.status === "known" &&
        typeof scope.effectivePercentRemaining === "number" &&
        Number.isFinite(scope.effectivePercentRemaining),
    );
    if (known.length === availability.length && known.length > 0) {
      headroom = String(
        Math.trunc(Math.min(...known.map((scope) => scope.effectivePercentRemaining))),
      );
    }
  }
  break;
}

console.log(authStatus, headroom);
NODE
}

# One bounded, non-interactive probe of the tuple's own vendor CLI. The argv is
# fixed here rather than composed from input, so no caller can turn this into a
# login, logout, or interactive launch.
probe_grok() {
  local output first rc=0
  command -v grok >/dev/null 2>&1 || { printf 'unavailable\n'; return 0; }
  output=$(run_timed "$TIMEOUT" grok models 2>/dev/null </dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'timeout\n'
    return 0
  fi
  # The exit status is deliberately ignored: grok 0.2.112 exits 0 in both the
  # authenticated and unauthenticated cases, so only the first stdout line
  # discriminates. Raw output is classified here and never printed.
  first=$(printf '%s\n' "$output" | head -n 1)
  case "$first" in
    "You are logged in with "*) printf 'authenticated\n' ;;
    "You are not authenticated."*) printf 'unauthenticated\n' ;;
    *) printf 'indeterminate\n' ;;
  esac
}

grok_version() {
  local output
  command -v grok >/dev/null 2>&1 || { printf 'none\n'; return 0; }
  output=$(run_timed "$TIMEOUT" grok --version 2>/dev/null </dev/null) || { printf 'none\n'; return 0; }
  printf '%s\n' "$output" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1 | grep . || printf 'none\n'
}

# bin/fm-quota-axi-lib.sh owns the floor; bootstrap turns the same check into the
# operator-facing diagnostic. Refusing here keeps a stale binary from producing a
# confident-looking but unscoped verdict in the meantime.
if ! fm_quota_axi_compatible "$TIMEOUT"; then
  finish no "quota-axi-below-$FM_QUOTA_AXI_MIN"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-auth-preflight.XXXXXX") || finish no internal-error
trap 'rm -rf "$TMP"' EXIT

if [ -n "$AUTH_JSON" ]; then
  cp "$AUTH_JSON" "$TMP/auth.json" 2>/dev/null || finish no auth-document-unreadable
else
  run_timed "$TIMEOUT" quota-axi auth --json >"$TMP/auth.json" 2>/dev/null \
    || finish no auth-document-unreadable
fi

if ! resolved=$(resolve_surface "$TMP/auth.json" "$HARNESS" "$MODEL"); then
  finish no surface-unresolved
fi
read -r PROVIDER SURFACE AUTH_STATUS <<< "$resolved"
[ "$AUTH_STATUS" = unknown ] && [ "$PROVIDER" = none ] && [ "$SURFACE" = none ] \
  && finish yes no-auth-evidence
[ -n "$PROVIDER" ] && [ -n "$SURFACE" ] && [ -n "$AUTH_STATUS" ] || finish no surface-unresolved

if [ -n "$QUOTA_JSON" ]; then
  cp "$QUOTA_JSON" "$TMP/quota.json" 2>/dev/null || : >"$TMP/quota.json"
else
  run_timed "$TIMEOUT" quota-axi --provider "$PROVIDER" --json >"$TMP/quota.json" 2>/dev/null || : >"$TMP/quota.json"
fi
read -r PROVIDER_AUTH_STATUS HEADROOM <<< "$(read_quota "$TMP/quota.json" "$PROVIDER")"

# A probe is permitted only when the tuple's own harness owns the credential
# store being tested AND that harness has a verified non-destructive discovery
# command. `harness=pi` is structurally excluded, so a Pi/xAI tuple can never
# reach the Grok CLI.
PROBE_NEEDED=no
case "$AUTH_STATUS" in
  expired|unusable) PROBE_NEEDED=yes ;;
esac

# Exactly one quota re-read, ever, after the selected-surface preflight. It
# refreshes headroom and the aggregate provider status but never changes the
# authentication verdict.
quota_retry_once() {
  local retry_auth retry_headroom
  if ! run_timed "$TIMEOUT" quota-axi --provider "$PROVIDER" --json >"$TMP/quota-retry.json" 2>/dev/null; then
    QUOTA_RETRY=failed
    return 0
  fi
  read -r retry_auth retry_headroom <<< "$(read_quota "$TMP/quota-retry.json" "$PROVIDER")"
  PROVIDER_AUTH_STATUS=$retry_auth
  HEADROOM=$retry_headroom
  if [ "$HEADROOM" = unknown ]; then QUOTA_RETRY=unknown; else QUOTA_RETRY=known; fi
}

if [ "$PROBE_NEEDED" = yes ] && [ "$HARNESS" = grok ]; then
  PROBE_VERSION=$(grok_version)
  if [ "$PROBE_VERSION" = "$VERIFIED_GROK_VERSION" ]; then
    PROBE_VERSION_VERIFIED=yes
  else
    PROBE_VERSION_VERIFIED=no
  fi
  PREFLIGHT=$(probe_grok)
fi
quota_retry_once

case "$PREFLIGHT" in
  authenticated) finish yes auth-usable-preflight ;;
  unauthenticated) finish no auth-unusable-preflight ;;
  timeout) finish no preflight-timeout ;;
  indeterminate) finish no preflight-indeterminate ;;
  unavailable) finish no preflight-unavailable ;;
esac

case "$AUTH_STATUS" in
  usable)
    # Usable authentication with unmeasurable headroom stays eligible; the
    # dispatch record discloses the unknown rather than asking the captain to
    # log in. Captain decision `dispatch-usable-auth-unknown-quota`, 2026-07-30.
    if [ "$HEADROOM" = unknown ]; then
      finish yes auth-usable-headroom-unknown
    fi
    finish yes auth-usable
    ;;
  expired)
    # The owning vendor CLI renews its own short-lived access token on next use,
    # so an aged-out session is not a captain action and has no useful remedy
    # for a borrowed Pi credential at all.
    finish yes auth-expired-vendor-renews
    ;;
  unusable)
    finish no auth-unusable
    ;;
esac

finish no surface-unresolved
