#!/usr/bin/env bash
# Default-on analytics-beacon block for every fleet chrome-devtools-axi session.
#
# Why this exists: a fleet browser session once polluted a production PostHog
# project with beacons from automated sweeps. Brief text alone cannot prevent
# that - a task can forget it. This makes the block structural: fm-spawn.sh
# injects the flag this script emits into every crewmate pane before launch, so
# a browser session cannot reach the birdied production analytics endpoints by
# default, with no brief text required.
#
# Mechanism: chrome-devtools-axi has no native request-blocking or host-blocklist
# flag; the strongest lever it honors is CHROME_DEVTOOLS_AXI_CHROME_ARGS, which
# forwards Chrome launch flags but SPLITS ON WHITESPACE with no quoting, so a
# flag whose value contains spaces (e.g. --host-resolver-rules="MAP host ip") is
# shredded. A PAC script delivered as a data: URL is the strongest surviving
# lever: a single spaceless token, no PAC file or running proxy process, honored
# headless. The PAC routes matched analytics HOSTS to a dead proxy (127.0.0.1:9)
# with no DIRECT fallback, so per Chrome proxy semantics the request fails rather
# than silently going direct, and returns DIRECT for everything else.
#
# Why host-level and not path-level: the fleet runs Chrome HEADLESS, and in that
# mode two things rule out per-path blocking of the first-party analytics proxy
# (EXPO_PUBLIC_POSTHOG_HOST=https://birdied.app/ingest, HTTPS):
#   - Chrome STRIPS the path from HTTPS URLs before passing them to a PAC script
#     (since M75), so a PAC can only see the host for HTTPS - a `*/ingest*` rule
#     silently never matches over HTTPS and would give false confidence.
#   - Headless Chrome does not load extensions, so a declarativeNetRequest rule
#     (which does see full HTTPS URLs) cannot be used either.
# A forward proxy cannot see paths inside an HTTPS CONNECT tunnel without MITM.
# So the only headless-viable way to stop the first-party /ingest beacon is to
# block its HOST. This guard blocks the birdied PRODUCTION apex only; staging and
# preview subdomains, localhost, and every non-birdied site stay reachable, so a
# beacon aimed at the production apex from a staging page is still blocked while
# the staging page itself loads. Verified end to end in
# tests/fm-browser-guard-block-live-e2e.test.sh; consequences are recorded in
# docs/browser-guard.md.
#
# What is blocked (by host):
#   - posthog.com and any *.posthog.com host (direct PostHog cloud ingest/app).
#   - birdied.app and www.birdied.app (the production apex; its first-party
#     /ingest analytics proxy lives here and cannot be isolated by path headless).
#
# Opt-out (explicit, loud, documented): set FM_BROWSER_ALLOW_ANALYTICS=1 in the
# environment fm-spawn runs in. fm-spawn then skips the injection and prints a
# visible marker in the pane instead. Use it only for a genuine analytics-testing
# task or a deliberate production-apex visit. See docs/browser-guard.md.
#
# Usage:
#   fm-browser-guard.sh pac          Print the PAC JavaScript.
#   fm-browser-guard.sh data-url     Print the data: URL carrying the PAC.
#   fm-browser-guard.sh chrome-args  Print the single --proxy-pac-url=... token
#                                    for CHROME_DEVTOOLS_AXI_CHROME_ARGS.
#   fm-browser-guard.sh env          Print a shell line that composes the flag
#                                    with any existing CHROME_DEVTOOLS_AXI_CHROME_ARGS;
#                                    intended for `eval "$(fm-browser-guard.sh env)"`
#                                    in a manual/direct chrome-devtools-axi shell.
#   fm-browser-guard.sh classify <url> [host]
#                                    Print BLOCK or ALLOW by running the emitted
#                                    PAC against <url>; used by the portable test.
set -u

# The dead proxy blocked URLs are routed to. Port 9 (discard) is conventionally
# closed; the result carries no DIRECT fallback, so the request fails either way.
BLOCK_PROXY="PROXY 127.0.0.1:9"

# emit_pac prints the PAC JavaScript. This is the single source of truth for the
# blocklist; every other subcommand derives from it, and the portable test runs
# these exact bytes.
emit_pac() {
  cat <<'PAC'
function FindProxyForURL(url, host) {
  var BLOCK = "PROXY 127.0.0.1:9";
  host = host.toLowerCase();
  // Direct PostHog cloud endpoints are never legitimate page content for fleet
  // browsing, so block the whole family by host.
  if (host === "posthog.com" || dnsDomainIs(host, ".posthog.com")) {
    return BLOCK;
  }
  // Birdied production apex. Blocked by host, not path: Chrome strips the path
  // from HTTPS URLs before a PAC sees them, so the first-party /ingest analytics
  // proxy on this host can only be stopped by blocking the host. Staging and
  // preview live on subdomains and stay reachable; use the opt-out to reach the
  // production apex deliberately.
  if (host === "birdied.app" || host === "www.birdied.app") {
    return BLOCK;
  }
  return "DIRECT";
}
PAC
}

# Standard PAC helper shims (Mozilla PAC semantics), used only by `classify` to
# evaluate the PAC offline. Chrome supplies these natively at runtime; the live
# guard test proves the real-Chrome behavior, this pins the decision logic.
emit_pac_helpers() {
  cat <<'JS'
function dnsDomainIs(host, domain) {
  return host.length >= domain.length &&
         host.substring(host.length - domain.length) === domain;
}
function shExpMatch(str, shexp) {
  var re = new RegExp('^' + shexp.replace(/[.+^${}()|[\]\\]/g, '\\$&')
                                 .replace(/\*/g, '.*')
                                 .replace(/\?/g, '.') + '$');
  return re.test(str);
}
JS
}

emit_data_url() {
  local b64
  # Unwrapped base64 for macOS/Linux parity: strip any wrapping newlines rather
  # than relying on GNU-only `base64 -w0`.
  b64=$(emit_pac | base64 | tr -d '\n') || return 1
  printf 'data:application/x-ns-proxy-autoconfig;base64,%s' "$b64"
}

emit_chrome_args() {
  local url
  url=$(emit_data_url) || return 1
  printf -- '--proxy-pac-url=%s' "$url"
}

emit_env() {
  local flag
  flag=$(emit_chrome_args) || return 1
  # The caller's shell (not this one) expands ${CHROME_DEVTOOLS_AXI_CHROME_ARGS},
  # so an existing value (e.g. GPU flags) is preserved and composed with. The
  # literal ${...} is deliberate for the caller's eval.
  # shellcheck disable=SC2016
  printf 'export CHROME_DEVTOOLS_AXI_CHROME_ARGS="%s ${CHROME_DEVTOOLS_AXI_CHROME_ARGS:-}"\n' "$flag"
}

classify() {
  local url="$1" host="${2:-}"
  if [ -z "$url" ]; then
    echo "error: classify needs a url" >&2
    return 2
  fi
  if [ -z "$host" ]; then
    host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+).*#\1#' | sed -E 's#:[0-9]+$##')
  fi
  command -v node >/dev/null 2>&1 || { echo "error: node is required for classify" >&2; return 3; }
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-browser-guard.XXXXXX") || return 1
  {
    emit_pac_helpers
    emit_pac
    cat <<'NODE'
var r = FindProxyForURL(process.env.FM_PAC_URL, process.env.FM_PAC_HOST);
console.log(r.indexOf("PROXY") === 0 ? "BLOCK" : "ALLOW");
NODE
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  FM_PAC_URL="$url" FM_PAC_HOST="$host" node "$tmp"
  local rc=$?
  rm -f -- "$tmp"
  return "$rc"
}

: "$BLOCK_PROXY"  # documented above; referenced so the constant is not dead.

cmd="${1:-}"
case "$cmd" in
  pac) emit_pac ;;
  data-url) emit_data_url && printf '\n' ;;
  chrome-args) emit_chrome_args && printf '\n' ;;
  env) emit_env ;;
  classify) shift; classify "${1:-}" "${2:-}" ;;
  ""|-h|--help|help)
    awk 'NR>1 && /^set -u$/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
    ;;
  *)
    echo "error: unknown command: $cmd" >&2
    exit 2
    ;;
esac
