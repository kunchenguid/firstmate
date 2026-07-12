#!/usr/bin/env bash
# Publish one no-mistakes evidence file as a clickable internal preview URL.
#
# This is the adapter between no-mistakes' `test.evidence.upload_cmd` hook and
# the `html-preview` CLI. Without it, evidence is committed into the branch and
# a reviewer opening an HTML artifact in a MR sees its SOURCE, not the page;
# with it, evidence stays out of git and the MR description carries a link the
# reviewer can actually open.
#
# Contract with no-mistakes (see its docs/reference/repo-config.md):
#   - invoked once per evidence file, the ABSOLUTE path appended as the last argument
#   - NM_EVIDENCE_LABEL / NM_EVIDENCE_RUN_ID / NM_EVIDENCE_BRANCH are exported
#   - success = exit 0 with an absolute http(s) URL as the last non-empty stdout line
#   - anything else is a failure: the run degrades to the local path and warns.
#     So this script fails loudly and NEVER prints a URL it did not get back from
#     html-preview.
#
# Contract with html-preview: `html-preview <file.html>` prints the final URL on
# stdout and exits non-zero with detail on failure. It only accepts HTML, so
# images and text evidence are wrapped in a minimal self-contained HTML page
# (image inlined as a data: URI, text in a <pre>) before publishing. The staging
# path is derived deterministically from the source path, so republishing the
# same evidence file reuses the same URL (html-preview keys its alias on the
# absolute path).
#
# Sensitive-content gate: publishing makes the page visible to the whole
# corporate network, so text-readable evidence (HTML, logs, stdout/stderr, SVG)
# is scanned for credentials and classification markers first, and a suspected
# hit REFUSES to publish. The gate cannot read text baked into a raster
# screenshot - a token visible in a PNG will not be caught. Keep secrets off the
# screen when capturing evidence.
#
# Usage: fm-evidence-publish.sh [--help] <evidence-file>
set -euo pipefail

MAX_BYTES=${FM_EVIDENCE_MAX_BYTES:-12582912} # 12 MiB; data: URIs above this are absurd pages

log() { printf 'fm-evidence-publish: %s\n' "$*" >&2; }
die() {
  log "$*"
  exit 1
}

usage() { echo "usage: fm-evidence-publish.sh <evidence-file>" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ "$#" -ge 1 ] || {
  usage
  exit 1
}

# no-mistakes appends the path as the LAST argument so a hook may carry its own flags.
SRC=${*: -1}
[ -n "$SRC" ] || die "no evidence file given"
[ -f "$SRC" ] || die "not a regular file: $SRC"
ABS=$(cd "$(dirname "$SRC")" && pwd -P)/$(basename "$SRC")
[ -r "$ABS" ] || die "not readable: $ABS"

SIZE=$(wc -c <"$ABS" | tr -d ' ')
[ "$SIZE" -le "$MAX_BYTES" ] || die "evidence file is ${SIZE}B, over the ${MAX_BYTES}B publish cap: $ABS"

HTML_PREVIEW=${FM_HTML_PREVIEW:-html-preview}
command -v "$HTML_PREVIEW" >/dev/null 2>&1 || die "html-preview not on PATH (set FM_HTML_PREVIEW to override)"

BASE=$(basename "$ABS")
STEM=${BASE%.*}
EXT=$(printf '%s' "${BASE##*.}" | tr '[:upper:]' '[:lower:]')
[ "$EXT" != "$BASE" ] || EXT=""

LABEL=${NM_EVIDENCE_LABEL:-}
RUN_ID=${NM_EVIDENCE_RUN_ID:-}
BRANCH=${NM_EVIDENCE_BRANCH:-}

case "$EXT" in
  html | htm) KIND=html ;;
  png | jpg | jpeg | gif | webp | avif | bmp) KIND=image ;;
  svg) KIND=svg ;;
  txt | log | out | err | json | jsonl | ndjson | md | csv | tsv | diff | patch | yaml | yml | xml | ini | conf) KIND=text ;;
  *) die "unsupported evidence type '.${EXT}' ($BASE); html-preview only serves HTML pages, so this one keeps its local path" ;;
esac

# ---- sensitive-content gate -------------------------------------------------
# Refuse rather than best-effort: an internal URL cannot be unpublished.
#
# Every rule is matched case-INSENSITIVELY (see scan_secrets), so each is written
# in whatever case reads best; none may rely on case to stay narrow. The keyword
# rule below still demands a `:`/`=` and a >=16-char value, which is what keeps it
# off ordinary prose - a gate strict enough to reject real evidence just teaches
# people to bypass it, which is worse than no gate.
SECRET_PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----
(AKIA|ASIA)[0-9A-Z]{16}
gh[pousr]_[A-Za-z0-9]{20,}
glpat-[A-Za-z0-9_-]{20,}
xox[a-z]-[A-Za-z0-9-]{10,}
sk-[A-Za-z0-9_-]{20,}
AIza[0-9A-Za-z_-]{35}
npm_[A-Za-z0-9]{36}
eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
authorization[[:space:]]*:[[:space:]]*(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+/=-]{16,}
(api[_-]?key|api[_-]?secret|secret[_-]?key|access[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|session[_-]?token|id[_-]?token|bearer[_-]?token|signing[_-]?key|encryption[_-]?key|private[_-]?key|passwd|password|credential)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_.=-]{16,}
(绝密|机密|密级)'

scan_secrets() {
  # $1 = file to scan, $2 = what it is (for the error message)
  local file=$1 what=$2 pattern hit
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # -e is mandatory: the private-key pattern starts with '-' and would otherwise
    # be parsed as an option, silently disabling that rule.
    # -i is mandatory: the keyword rule spells its alternation in lowercase
    # (api_key, secret_key, password, ...), but the form that actually shows up in
    # a log or env dump is AWS_SECRET_ACCESS_KEY=... - case-sensitively that walked
    # straight through the gate and got published. Erring toward over-refusal is
    # the right side to be wrong on: an internal URL cannot be unpublished.
    # -m1 rather than `| head -1`: under `set -o pipefail`, head closing the pipe
    # after the first line can leave grep dead of SIGPIPE (141), which the `if`
    # then reads as "no match" - a matching secret would sail through.
    if hit=$(LC_ALL=C grep -aEni -m1 -e "$pattern" "$file"); then
      die "refusing to publish $what: suspected secret or classified content matched /${pattern}/ at ${hit%%:*}; publishing exposes it to the whole internal network. Scrub the evidence and re-run."
    fi
  done <<EOF
$SECRET_PATTERNS
EOF
}

# The label and branch are interpolated into the page, so they are gated too.
META_SCAN=$(mktemp)
trap 'rm -f "$META_SCAN"' EXIT
printf '%s\n%s\n%s\n' "$LABEL" "$BRANCH" "$BASE" >"$META_SCAN"
scan_secrets "$META_SCAN" "evidence metadata for $BASE"

case "$KIND" in
  html | svg | text) scan_secrets "$ABS" "$BASE" ;;
  image) log "note: $BASE is a raster image; the secret gate cannot read text rendered inside it" ;;
esac

# ---- staging ----------------------------------------------------------------
# Deterministic per source path so a republish reuses html-preview's alias.
if command -v shasum >/dev/null 2>&1; then
  KEY=$(printf '%s' "$ABS" | shasum -a 256 | cut -c1-16)
else
  KEY=$(printf '%s' "$ABS" | sha256sum | cut -c1-16)
fi
STAGE="${TMPDIR:-/tmp}/fm-evidence-publish/$KEY"
mkdir -p "$STAGE"

esc_html() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
esc_str() { printf '%s' "$1" | esc_html; }

TITLE=$(esc_str "${LABEL:-$BASE}")
SUB=$(esc_str "$BASE${RUN_ID:+ · run $RUN_ID}${BRANCH:+ · $BRANCH}")

page_head() {
  cat <<HEAD
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <title>$TITLE</title>
    <style>
      body { margin:0; padding:32px; background:#fafaf9; color:#1c1917;
             font:14px/1.6 -apple-system,'PingFang SC',sans-serif; }
      h1 { font-size:18px; margin:0 0 4px; }
      .sub { color:#78716c; margin-bottom:24px; font-size:12px; }
      .card { background:#fff; border:1px solid #e7e5e4; border-radius:10px;
              overflow:hidden; padding:12px; }
      img { display:block; max-width:100%; height:auto; }
      pre { margin:0; padding:12px; overflow-x:auto; white-space:pre-wrap;
            word-break:break-word; font:12px/1.5 ui-monospace,SFMono-Regular,monospace; }
      .empty { color:#a8a29e; font-style:italic; }
    </style>
  </head>
  <body>
    <h1>$TITLE</h1>
    <div class="sub">$SUB</div>
    <div class="card">
HEAD
}
page_foot() {
  cat <<'FOOT'
    </div>
  </body>
</html>
FOOT
}

mime_of() {
  case "$1" in
    png) echo image/png ;;
    jpg | jpeg) echo image/jpeg ;;
    gif) echo image/gif ;;
    webp) echo image/webp ;;
    avif) echo image/avif ;;
    bmp) echo image/bmp ;;
    svg) echo image/svg+xml ;;
    *) echo application/octet-stream ;;
  esac
}

case "$KIND" in
  html)
    # Publish the page itself, but stage a copy so its relative assets can be
    # resolved: no-mistakes files each artifact under its own ev-<id>/ directory,
    # which breaks sibling `./foo.png` references the agent wrote. Anything left
    # unresolved makes html-preview fail loudly rather than serve a broken page.
    STAGED="$STAGE/$BASE"
    cp "$ABS" "$STAGED"
    SRC_DIR=$(dirname "$ABS")
    # `|| true`: a page with no src/href at all (everything inlined) is the normal
    # case for a self-contained artifact, but grep exits 1 on no-match and pipefail
    # would turn that into a silent publish failure - non-zero exit, no message.
    { grep -oE '(src|href)=("[^"]*"|'"'"'[^'"'"']*'"'"')' "$ABS" || true; } |
      sed -E 's/^(src|href)=//; s/^["'"'"']//; s/["'"'"']$//' | sort -u |
      while IFS= read -r ref; do
        case "$ref" in
          '' | http://* | https://* | //* | data:* | \#* | mailto:* | javascript:*) continue ;;
        esac
        rel=${ref%%\#*}
        rel=${rel%%\?*}
        rel=${rel#./}
        [ -n "$rel" ] || continue
        if [ -f "$SRC_DIR/$rel" ]; then
          mkdir -p "$STAGE/$(dirname "$rel")"
          cp "$SRC_DIR/$rel" "$STAGE/$rel"
          continue
        fi
        # Sibling-evidence rescue: unique basename match one level up.
        found=$(find "$(dirname "$SRC_DIR")" -maxdepth 2 -type f -name "$(basename "$rel")" 2>/dev/null)
        if [ "$(printf '%s\n' "$found" | grep -c .)" = "1" ] && [ -n "$found" ]; then
          mkdir -p "$STAGE/$(dirname "$rel")"
          cp "$found" "$STAGE/$rel"
          log "resolved '$ref' from sibling evidence dir: $found"
        else
          log "warning: '$ref' referenced by $BASE was not found next to it; html-preview will report it"
        fi
      done
    ;;
  image | svg)
    STAGED="$STAGE/$STEM.html"
    DATA_URI="data:$(mime_of "$EXT");base64,$(base64 <"$ABS" | tr -d '\n')"
    {
      page_head
      printf '      <img src="%s" alt="%s" />\n' "$DATA_URI" "$TITLE"
      page_foot
    } >"$STAGED"
    ;;
  text)
    STAGED="$STAGE/$STEM.html"
    {
      page_head
      if [ "$SIZE" -eq 0 ]; then
        printf '      <pre class="empty">(empty file)</pre>\n'
      else
        printf '      <pre>'
        esc_html <"$ABS"
        printf '</pre>\n'
      fi
      page_foot
    } >"$STAGED"
    ;;
esac

# ---- publish ----------------------------------------------------------------
log "publishing $BASE via html-preview ($STAGED)"
OUT=$("$HTML_PREVIEW" "$STAGED") || die "html-preview failed for $BASE (see its output above)"

URL=$(printf '%s\n' "$OUT" | grep -E '^[[:space:]]*https?://[^[:space:]]+[[:space:]]*$' | tail -1 | tr -d '[:space:]')
[ -n "$URL" ] || die "html-preview printed no http(s) URL for $BASE (got: $(printf '%s' "$OUT" | head -3 | tr '\n' ' '))"

printf '%s\n' "$URL"
