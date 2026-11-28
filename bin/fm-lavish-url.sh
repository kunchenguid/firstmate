#!/usr/bin/env bash
# fm-lavish-url.sh - capture a web page into an armed Lavish review snapshot,
# and route the review's feedback to the registered project it belongs to.
#
# Usage:
#   fm-lavish-url.sh snapshot <url> [--mobile]
#   fm-lavish-url.sh path <url>
#   fm-lavish-url.sh resolve <url>
#   fm-lavish-url.sh owns <source-id>
#   fm-lavish-url.sh route <source-id> <sequence> [--file]
#
# snapshot  Render <url> (http or https, public or local, no credentials) in a
#           dedicated chrome-devtools-axi browser session, take its rendered
#           DOM, and write a sanitized snapshot to
#           <home>/.lavish/snapshots/<slug>-<UTC timestamp>.html beside a
#           <same name>.meta.json record. Every captured script, plugin, frame,
#           event handler, and script URL is stripped by bin/fm-lavish-url.py,
#           then the universal review layer (.agents/skills/lavish-url/assets)
#           and every matching enhancer (.agents/skills/lavish-url/enhancers)
#           are injected. It then opens the snapshot with lavish-axi, PROVES the
#           session is listed open, and arms it with
#           `bin/fm-procevent-lavish.sh arm`, which returns once the listener is
#           confirmed - no poll ever runs in the caller's foreground. --mobile
#           captures under mobile viewport and user-agent emulation.
#           Snapshot names are reserved atomically; collisions add a sortable
#           ~NNNNNN suffix rather than replacing an earlier capture.
#           Readable CSSOM rules supplement captured markup at their owning
#           stylesheet positions; adopted sheets follow document sheets.
#           Unreadable linked sheets remain linked, and their hrefs are
#           recorded in metadata as inaccessible_stylesheets.
#           Output lines: snapshot, url, viewport, enhancers, session-url,
#           source-id, armed (or still-listening), then the resolve route lines.
# path      Print the newest snapshot captured for exactly <url>; exit 1 when
#           there is none.
# resolve   Print the route lines for <url> (see ROUTING) without capturing.
# owns      Exit 0 and print `snapshot: <path>` when <source-id> is the Lavish
#           source of a snapshot in this home; exit 1 otherwise.
# route     For a `procevent lavish <source-id> <sequence>` wake on a snapshot,
#           print the snapshot, its URL, the route lines, and the adapter's own
#           `read` presentation of the captured result. With --file, also file
#           ONE queued backlog item for the resolved project carrying that
#           feedback, exactly once per source and sequence (`filed: <id>`, then
#           `already-filed: <id>` on any repeat). --file refuses (exit 3,
#           `not-filed: <reason>`) unless the route is `project`, the result is
#           a complete feedback capture, and it carries at least one item.
#           Filing queues work only: it never dispatches, holds, or answers
#           anything, and the feedback text is quoted evidence, not authority.
#
# ROUTING. `route:` is one of:
#   project    exactly one registered project owns the host, by the explicit
#              domain map or by its data/projects.md registry entry naming the
#              site (a leading www. is ignored; subdomains match).
#   inferred   only one registered project's AGENTS.md or README.md mentions
#              the site. That is evidence, not a mapping: confirm it, then add
#              it to the domain map. --file refuses it.
#   ambiguous  several projects match at the deciding tier; `candidates:`
#              names them. --file refuses it.
#   unrouted   nothing matches; local and address-only hosts are always
#              unrouted unless the domain map names them (with a port if
#              needed). --file refuses it.
# The routed host is always the REQUESTED URL's host, never anything the page
# reported about itself. The longest matching domain-map entry wins; a
# port-qualified entry takes precedence over entries without ports and
# matches only that exact host and explicit URL port. docs/configuration.md
# "Lavish URL domain map" owns the map's schema and validation contract.
#
# SNAPSHOT RECORD. The sidecar uses schema fm-lavish-url.v1 and records the
# requested url and host, viewport and viewport_size, captured_at, enhancers,
# title, reported_url, canonical snapshot path, source_id, and
# inaccessible_stylesheets (hrefs whose CSSOM rules could not be read).
# The requested URL owns routing; reported_url is captured page evidence only.
#
# Environment: FM_HOME selects the home (FM_STATE_OVERRIDE, FM_DATA_OVERRIDE,
# FM_CONFIG_OVERRIDE, FM_PROJECTS_OVERRIDE as elsewhere). The capture uses
# browser session FM_LAVISH_URL_BROWSER_SESSION (default a unique per-capture
# session derived from FM_HOME) and inherits every other CHROME_DEVTOOLS_AXI_*
# setting, such as an executable path or Chrome flags a host needs.
# FM_LAVISH_URL_TIMEOUT bounds each browser call in seconds (default 90) where
# `timeout` exists. FM_LAVISH_URL_SETTLE_MS is the post-load settle (default 800).
#
# Requires python3, jq, chrome-devtools-axi, and lavish-axi.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SKILL_DIR="$FM_ROOT/.agents/skills/lavish-url"
HELPER="$SCRIPT_DIR/fm-lavish-url.py"
SNAPSHOTS="$FM_HOME/.lavish/snapshots"
export FM_HOME

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

validate_url() {  # <url>
  local url=$1
  case "$url" in
    *[[:space:]]*|*$'\n'*) die "the URL must not contain whitespace" ;;
  esac
  [ "${#url}" -le 2048 ] || die "the URL is longer than 2048 characters"
  python3 - "$url" <<'PY' || die "only http and https URLs with a host and no credentials can be captured: $url"
import sys
from urllib.parse import urlsplit
try:
    parts = urlsplit(sys.argv[1])
    ok = parts.scheme in ("http", "https") and bool(parts.hostname) and parts.username is None and parts.password is None
    parts.port
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

# Lower-case host and path, every other run of characters a single dash.
url_slug() {  # <url>
  python3 - "$1" <<'PY'
import re, sys
from urllib.parse import urlsplit
parts = urlsplit(sys.argv[1])
raw = (parts.hostname or "") + ("-" + str(parts.port) if parts.port else "") + parts.path
slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")[:60].strip("-")
print(slug or "page")
PY
}

realpath_of() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

bounded() {  # <command...>
  if command -v timeout >/dev/null 2>&1; then
    timeout "${FM_LAVISH_URL_TIMEOUT:-90}" "$@"
  else
    "$@"
  fi
}

browser() {  # <args...>
  CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" bounded chrome-devtools-axi "$@"
}

browser_ok() {  # <label> <args...>
  local label=$1 out
  shift
  out=$(browser "$@" 2>&1) || die "capture browser failed to $label: $(printf '%s' "$out" | head -5)"
  if printf '%s\n' "$out" | grep -q '^error:'; then
    die "capture browser failed to $label: $(printf '%s' "$out" | head -5)"
  fi
  printf '%s\n' "$out"
}

route_lines() {  # <url>
  python3 "$HELPER" route --url "$1" --registry "$DATA/projects.md" \
    --projects "$PROJECTS" --domains "$CONFIG/lavish-url-domains"
}

# The server's own listing, keyed on the canonical artifact path; only a live
# session is listed `open` (the same proof bin/fm-bearings-board.sh relies on).
session_listed_open() {  # <canonical-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

cmd_snapshot() {
  local url='' mobile=0 viewport=desktop size slug ts snap meta tmp real sid out session_url arm_out routed
  local settle claim cleanup suffix=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mobile) mobile=1; shift ;;
      --*) usage ;;
      *) [ -z "$url" ] || usage; url=$1; shift ;;
    esac
  done
  [ -n "$url" ] || usage
  need python3
  need jq
  need chrome-devtools-axi
  need lavish-axi
  validate_url "$url"
  # Resolve the route before anything is captured or armed, so a malformed
  # domain map refuses the capture instead of leaving an armed snapshot.
  routed=$(route_lines "$url") || die "cannot resolve the project route for $url"
  settle=${FM_LAVISH_URL_SETTLE_MS:-800}
  case "$settle" in ''|*[!0-9]*) die "FM_LAVISH_URL_SETTLE_MS must be a whole number of milliseconds" ;; esac

  BROWSER_SESSION=${FM_LAVISH_URL_BROWSER_SESSION:-$(python3 - "$FM_HOME" <<'PYSESSION'
import hashlib, sys, uuid
print("fm-lavish-url-" + hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12] + "-" + uuid.uuid4().hex)
PYSESSION
)}
  size=1440x900
  if [ "$mobile" = 1 ]; then
    viewport=mobile
    size=390x844
  fi

  mkdir -p "$SNAPSHOTS" || die "cannot create $SNAPSHOTS"
  slug=$(url_slug "$url")
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  claim="$SNAPSHOTS/$slug-$ts"
  while :; do
    if python3 - "$claim.claim" <<'PYCLAIM'
import os, sys
try:
    os.mkdir(sys.argv[1])
except FileExistsError:
    sys.exit(2)
except OSError as exc:
    print("cannot reserve snapshot name: %s" % exc, file=sys.stderr)
    sys.exit(1)
PYCLAIM
    then
      [ ! -e "$claim.html" ] && break
      rmdir "$claim.claim"
    elif [ "$?" != 2 ]; then
      die "cannot reserve snapshot name: $claim"
    fi
    suffix=$((suffix + 1))
    claim="$SNAPSHOTS/$slug-$ts~$(printf '%06d' "$suffix")"
  done
  snap="$claim.html"
  meta="$claim.meta.json"
  tmp=$(mktemp -d "$SNAPSHOTS/.capture.XXXXXX") || die "cannot create a temporary directory"
  printf -v cleanup 'browser stop >/dev/null 2>&1 || true; rm -rf -- %q; rmdir -- %q' "$tmp" "$claim.claim"
  # The paths are deliberately shell-quoted now, before function locals expire.
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT

  # Emulation is set on a blank page first so the target URL loads under it.
  browser_ok "open a blank page" open about:blank >/dev/null
  if [ "$mobile" = 1 ]; then
    browser_ok "emulate a mobile device" emulate --viewport "390x844x3,mobile,touch" \
      --user-agent "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" >/dev/null
  else
    browser_ok "set a desktop viewport" emulate --viewport "1440x900x1" >/dev/null
  fi
  browser_ok "load $url" open "$url" >/dev/null
  browser_ok "let the page settle" eval "async () => { if (document.readyState !== 'complete') { await new Promise((resolve) => { addEventListener('load', resolve, { once: true }); setTimeout(resolve, 15000); }); } await new Promise((resolve) => setTimeout(resolve, $settle)); return document.readyState; }" >/dev/null
  browser eval --full "() => {
    const styles = [], inaccessible = [];
    for (const node of document.querySelectorAll('[data-fm-captured-sheet]')) node.removeAttribute('data-fm-captured-sheet');
    for (const sheet of [...document.styleSheets, ...document.adoptedStyleSheets]) {
      if (sheet.disabled) continue;
      try {
        let css = Array.from(sheet.cssRules, rule => rule.cssText).join('\n');
        const media = sheet.media && sheet.media.mediaText;
        if (media) css = '@media ' + media + ' {' + css + '}';
        const owner = sheet.ownerNode;
        if (owner) owner.setAttribute('data-fm-captured-sheet', String(styles.length));
        styles.push({ css, baseURI: sheet.href || document.baseURI, owner: owner ? styles.length : null });
      } catch (_) { if (sheet.href) inaccessible.push(sheet.href); }
    }
    return { url: location.href, baseURI: document.baseURI, title: document.title, html: document.documentElement.outerHTML, styles, inaccessible_stylesheets: inaccessible };
  }" \
    > "$tmp/eval.txt" 2>&1 || die "capture browser failed to read the page: $(head -5 "$tmp/eval.txt")"
  python3 "$HELPER" decode-eval "$tmp/eval.txt" > "$tmp/capture.json" \
    || die "the capture browser did not return a complete page for $url"

  out=$(python3 "$HELPER" build --capture "$tmp/capture.json" --url "$url" --viewport "$viewport" \
    --viewport-size "$size" --skill-dir "$SKILL_DIR" --out "$tmp/snapshot.html" \
    --meta-out "$tmp/meta.json" --captured-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)") \
    || die "cannot build the snapshot for $url"
  chmod 0600 "$tmp/snapshot.html" "$tmp/meta.json" 2>/dev/null || true
  mv -f -- "$tmp/snapshot.html" "$snap" || die "cannot publish $snap"
  real=$(realpath_of "$snap") || die "cannot resolve $snap"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$snap") || die "cannot derive the Lavish source id for $snap"
  if ! { jq --arg snap "$real" --arg sid "$sid" '.snapshot = $snap | .source_id = $sid' "$tmp/meta.json" > "$tmp/meta.final" \
    && chmod 0600 "$tmp/meta.final" && mv -f -- "$tmp/meta.final" "$meta"; }; then
    die "cannot record $meta"
  fi
  printf 'snapshot: %s\n' "$real"
  printf 'url: %s\n' "$url"
  printf 'viewport: %s %s\n' "$viewport" "$size"
  printf '%s\n' "$out"

  # Live-session verification: an exit status alone cannot tell a live
  # session from a refused one, so the server's own listing must show it open
  # before anything arms a poll on it.
  # A snapshot that never reaches a live session is withdrawn, not left behind.
  if ! out=$(lavish-axi "$snap"); then
    rm -f -- "$snap" "$meta"
    die "lavish-axi could not open $snap"
  fi
  session_url=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*url:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)
  if ! session_listed_open "$real"; then
    rm -f -- "$snap" "$meta"
    die "the Lavish session for $snap is not listed open; refusing to arm it"
  fi
  printf 'session-url: %s\n' "${session_url:-unknown}"
  printf 'source-id: %s\n' "$sid"

  arm_out=$("$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$snap") || die "cannot arm $snap as a process-event source"
  printf '%s\n' "$arm_out" | grep -E '^(armed|still-listening):' || die "arming $snap reported no listener"
  printf '%s\n' "$routed"
}

cmd_path() {
  local url=${1-} slug candidate latest=''
  [ -n "$url" ] && [ "$#" -eq 1 ] || usage
  need python3
  need jq
  validate_url "$url"
  slug=$(url_slug "$url")
  [ -d "$SNAPSHOTS" ] || exit 1
  for candidate in "$SNAPSHOTS/$slug"-*.meta.json; do
    [ -f "$candidate" ] || continue
    [ "$(jq -r '.url // empty' "$candidate" 2>/dev/null)" = "$url" ] || continue
    [ -f "${candidate%.meta.json}.html" ] || continue
    latest="${candidate%.meta.json}.html"
  done
  [ -n "$latest" ] || exit 1
  printf '%s\n' "$latest"
}

cmd_resolve() {
  local url=${1-}
  [ -n "$url" ] && [ "$#" -eq 1 ] || usage
  need python3
  validate_url "$url"
  route_lines "$url" || die "cannot resolve the project route for $url"
}

# Print the snapshot whose recorded source id is <source-id>.
snapshot_for_source() {  # <source-id>
  local sid=$1 candidate
  [ -d "$SNAPSHOTS" ] || return 1
  for candidate in "$SNAPSHOTS"/*.meta.json; do
    [ -f "$candidate" ] || continue
    if [ "$(jq -r '.source_id // empty' "$candidate" 2>/dev/null)" = "$sid" ]; then
      printf '%s\n' "${candidate%.meta.json}.html"
      return 0
    fi
  done
  return 1
}

valid_source_id() {  # <source-id>
  [ "${#1}" -eq 23 ] || return 1
  case "$1" in lavish-*) ;; *) return 1 ;; esac
  case "${1#lavish-}" in *[!0-9a-f]*) return 1 ;; esac
}

cmd_owns() {
  local sid=${1-} snap
  [ -n "$sid" ] && [ "$#" -eq 1 ] || usage
  need jq
  valid_source_id "$sid" || exit 1
  snap=$(snapshot_for_source "$sid") || exit 1
  printf 'snapshot: %s\n' "$snap"
}

not_filed() { printf 'not-filed: %s\n' "$1"; exit 3; }

cmd_route() {
  local sid='' seq='' file=0 snap meta url result routed project lifecycle presentation
  local claim filed title body task out items
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=1; shift ;;
      --*) usage ;;
      *)
        if [ -z "$sid" ]; then sid=$1
        elif [ -z "$seq" ]; then seq=$1
        else usage
        fi
        shift
        ;;
    esac
  done
  [ -n "$sid" ] && [ -n "$seq" ] || usage
  need python3
  need jq
  valid_source_id "$sid" || die "not a Lavish source id: $sid"
  case "$seq" in ''|*[!0-9]*) die "the sequence must be a whole number: $seq" ;; esac
  snap=$(snapshot_for_source "$sid") || die "$sid is not a lavish-url snapshot source in this home"
  meta="${snap%.html}.meta.json"
  url=$(jq -r '.url // empty' "$meta") || die "cannot read $meta"
  [ -n "$url" ] || die "$meta records no URL"
  result="$STATE/procevent-inbox/$sid.$seq.result"
  [ -f "$result" ] && [ ! -L "$result" ] || die "no captured result at $result"

  routed=$(route_lines "$url") || die "cannot resolve the project route for $url"
  lifecycle=$("$SCRIPT_DIR/fm-procevent-lavish.sh" classify "$result") || die "cannot classify $result"
  presentation=$("$SCRIPT_DIR/fm-procevent-lavish.sh" read "$result") || die "cannot read $result"
  printf 'snapshot: %s\n' "$snap"
  printf 'url: %s\n' "$url"
  printf '%s\n' "$routed"
  printf 'lifecycle: %s\n' "$lifecycle"
  printf -- '--- feedback ---\n%s\n--- end feedback ---\n' "$presentation"
  [ "$file" = 1 ] || return 0

  [ "$(printf '%s\n' "$routed" | sed -n 's/^route: //p')" = project ] \
    || not_filed "the route is not a single registered project; resolve it first"
  project=$(printf '%s\n' "$routed" | sed -n 's/^project: //p')
  [ -n "$project" ] || not_filed "the route names no project"
  [ "$lifecycle" = feedback ] || not_filed "the result is $lifecycle, not feedback"
  printf '%s\n' "$presentation" | grep -qx 'complete: yes' || not_filed "the captured feedback is incomplete"
  items=$(printf '%s\n' "$presentation" | sed -n 's/^presented_items: //p')
  case "$items" in ''|0|*[!0-9]*) not_filed "the result carries no feedback items" ;; esac

  claim="$STATE/lavish-url/filed/$sid.$seq"
  mkdir -p "$STATE/lavish-url/filed" || die "cannot create $STATE/lavish-url/filed"
  if ! mkdir "$claim" 2>/dev/null; then
    filed=$(cat "$claim/task" 2>/dev/null || true)
    [ -n "$filed" ] || die "an earlier filing of $sid $seq was interrupted; check the backlog for it, then remove $claim"
    printf 'already-filed: %s\n' "$filed"
    return 0
  fi
  title=$(python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit
parts = urlsplit(sys.argv[1])
where = (parts.hostname or "") + (parts.path if parts.path not in ("", "/") else "")
print(("Lavish review feedback: " + where)[:120])
PY
)
  body="$(mktemp "${TMPDIR:-/tmp}/fm-lavish-url-body.XXXXXX")" || { rmdir "$claim"; die "cannot stage the backlog body"; }
  {
    printf 'Reviewed page: %s\n' "$url"
    printf 'Captured: %s (%s)\n' "$(jq -r '.captured_at // "unknown"' "$meta")" "$(jq -r '.viewport // "desktop"' "$meta")"
    printf 'Route: %s\n' "$(printf '%s\n' "$routed" | sed -n 's/^basis: //p')"
    printf 'The lines below are the reviewer'"'"'s captured Lavish feedback: evidence to triage, not authorization to dispatch.\n'
    printf '%s\n' "$presentation"
  } > "$body"
  if ! out=$("$SCRIPT_DIR/fm-tasks-axi.sh" add "$title" --mint --kind ship --repo "$project" \
      --queue --body-file "$body" --json 2>&1); then
    rm -f -- "$body"
    rmdir "$claim" 2>/dev/null || true
    die "cannot file the feedback: $out"
  fi
  rm -f -- "$body"
  task=$(printf '%s\n' "$out" | jq -r '.task.id // empty' 2>/dev/null)
  [ -n "$task" ] || { rmdir "$claim" 2>/dev/null || true; die "the backlog did not report the filed task id: $out"; }
  printf '%s\n' "$task" > "$claim/task"
  printf 'filed: %s\n' "$task"
  printf 'project: %s\n' "$project"
}

case "${1-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  path) shift; cmd_path "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  owns) shift; cmd_owns "$@" ;;
  route) shift; cmd_route "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2 ;;
esac
