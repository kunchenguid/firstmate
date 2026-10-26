#!/usr/bin/env bash
# Sealed proof for one README badge pull request.
#
# Runs inside `done-done run -- git -C <repo> show ...`, so the run folder it writes is the sealed
# evidence folder, and every assertion below is written to its own log in plain words.
#
# usage: readme-badge-proof.sh <owner/repo> <pull-number> <head-sha>
#
# What it proves: GitHub's own rendered README of the pull request's head commit renders (not an error
# page), shows the badge or link to https://x.com/umership, and names no other person's handle and no
# Discord invite anywhere in the README. It captures that badge row at 390 and 1280 wide, in light and
# dark, and keeps every capture under 65536 bytes so a merge gate can cite it.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: readme-badge-proof.sh <owner/repo> <pull-number> <head-sha>" >&2
  exit 2
fi

REPO=$1
PULL=$2
SHA=$3
OWN_HANDLE=umership
OWN_LINK="https://x.com/$OWN_HANDLE"
OUT=${DONE_DONE_EVIDENCE_ROOT:?done-done did not set DONE_DONE_EVIDENCE_ROOT}
SLUG=${REPO//\//-}
RAWMARK=$OUT/README.md
LOG=$OUT/assertions.log
URL="https://github.com/$REPO/blob/$SHA/README.md"

case $SHA in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "head sha is not a full 40-character commit id: $SHA" >&2; exit 2 ;;
esac

export CHROME_DEVTOOLS_AXI_SESSION="oxbs-${SLUG}-${PULL}"
cleanup() { chrome-devtools-axi stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }

: > "$LOG"
# done-done hashes the run folder after the command exits, so a dot-name only keeps this out of the way.
WORK=$OUT/.work
mkdir -p "$WORK"

# 0. The README bytes at the pull's own head, straight from the forge: the text the page renders.
for _ in 1 2 3; do
  curl -fsSL --max-time 60 "https://raw.githubusercontent.com/$REPO/$SHA/README.md" -o "$RAWMARK" && break
  sleep 2
done
[ -s "$RAWMARK" ] || fail "could not fetch README.md at $SHA from the forge"
log "README.md at $SHA: $(wc -c < "$RAWMARK") bytes, sha256 $(sha256sum "$RAWMARK" | cut -d' ' -f1)"

# 1. Text assertions over the README itself.
own_links=$(grep -o "x\.com/$OWN_HANDLE" "$RAWMARK" | wc -l | tr -d ' ')
foreign_links=$(grep -oE '(x|twitter)\.com/[A-Za-z0-9_]+' "$RAWMARK" 2>/dev/null \
  | grep -v "x\.com/$OWN_HANDLE" \
  | grep -vE '/(intent|share|home|i|hashtag|search)(/|$)' | sort -u || true)
# An X badge in someone else's name counts the same as a link: both name a person's handle.
foreign_badges=$(grep -oE 'shields\.io/badge/(X|twitter|Twitter)-(%40|@)?[A-Za-z0-9_]+' "$RAWMARK" 2>/dev/null \
  | grep -vE "(%40|@)$OWN_HANDLE" | sort -u || true)
discord=$(grep -oE '(discord\.gg|discord\.com/invite|discordapp\.com/invite|discord\.com/channels)/[A-Za-z0-9_-]+' "$RAWMARK" 2>/dev/null | sort -u || true)

[ "$own_links" -ge 1 ] || fail "the README does not link x.com/$OWN_HANDLE"
[ -z "$foreign_links" ] || fail "the README links another X or Twitter account: $foreign_links"
[ -z "$foreign_badges" ] || fail "the README carries an X badge for another handle: $foreign_badges"
[ -z "$discord" ] || fail "the README carries a Discord invite: $discord"
log "PASS: the badge links to x.com/$OWN_HANDLE ($own_links link to x.com/$OWN_HANDLE in README.md at $SHA)."
log "PASS: no other person's handle appears anywhere in the README (0 links to another X or Twitter account, 0 X badges naming another handle)."
log "PASS: no Discord invite appears anywhere in the README (0 discord.gg or discord.com/invite links)."

# 2. Rendered-page assertions and captures: 390 and 1280 wide, light and dark.
chrome-devtools-axi open "$URL" >/dev/null || fail "could not open $URL in the browser"

captures=""
light_shot=""
dark_shot=""
for width in 390 1280; do
  for theme in light dark; do
    chrome-devtools-axi emulate --viewport "${width}x900x1" --color-scheme "$theme" >/dev/null
    # One digit per condition: anchor, README body, badge image loaded, not an error page, the page
    # title names this repository, and the body really is in the theme asked for.
    ok=no
    for _ in $(seq 1 20); do
      raw=$(chrome-devtools-axi eval "() => { const a = document.querySelector('a[href=\"$OWN_LINK\"]'); const body = document.querySelector('.markdown-body'); const img = a && a.querySelector('img'); const rgb = (getComputedStyle(document.body).backgroundColor.match(/([0-9]+)/g) || ['255', '255', '255']).map(Number); const lum = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255; const theme_ok = '$theme' === 'dark' ? (lum < 0.4 ? 1 : 0) : (lum > 0.8 ? 1 : 0); return [a ? 1 : 0, body ? 1 : 0, !img || img.naturalWidth > 0 ? 1 : 0, /could not be found|404 Not Found/.test(document.body.innerText) ? 0 : 1, document.title.includes('$REPO') ? 1 : 0, theme_ok, body ? body.innerText.trim().length : 0, Math.round(lum * 100)].join(','); }" 2>/dev/null || true)
      # Conditions in order: the badge anchor, the README body, the badge image, no error page, the
      # page title naming this repository, the body drawn in the theme asked for, the body's length,
      # and the page background's luminance in percent.
      flags=$(printf '%s\n' "$raw" | sed -n 's/^result: //p' | tr -cd '0-9,')
      IFS=, read -r c_anchor c_body c_img c_noerror c_title c_theme c_text c_bg <<<"$flags"
      if [ "${c_anchor:-0}" = 1 ] && [ "${c_body:-0}" = 1 ] && [ "${c_img:-0}" = 1 ] &&
         [ "${c_noerror:-0}" = 1 ] && [ "${c_title:-0}" = 1 ] && [ "${c_theme:-0}" = 1 ] &&
         [ "${c_text:-0}" -gt 0 ]; then
        ok=yes
        break
      fi
      sleep 1
    done
    [ "$ok" = yes ] || fail "$REPO at $SHA did not render the README with the @$OWN_HANDLE badge at ${width}w $theme (anchor/body/image/no-error/title/theme: ${flags:-no answer from the page})"

    chrome-devtools-axi eval "() => { const a = document.querySelector('a[href=\"$OWN_LINK\"]'); a.scrollIntoView({ block: 'center', behavior: 'instant' }); return 1; }" >/dev/null
    sleep 1
    geo=$(chrome-devtools-axi eval "() => { const a = document.querySelector('a[href=\"$OWN_LINK\"]'); const r = a.getBoundingClientRect(); const row = a.closest('p, li') || a.parentElement || a; const q = row.getBoundingClientRect(); const prev = row.previousElementSibling; let head_top = -1; if (prev && /^H[1-6]$/.test(prev.tagName)) { const hq = prev.getBoundingClientRect(); if (q.y - hq.bottom < 24) head_top = Math.round(hq.y); } return [window.innerWidth, window.innerHeight, Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height), r.top >= 0 && r.bottom <= window.innerHeight ? 1 : 0, Math.round(q.x), Math.round(q.y), Math.round(q.width), Math.round(q.height), head_top].join(','); }" 2>/dev/null | sed -n 's/^result: //p' | tr -cd '0-9,')
    geometry=${geo//,/ }
    # shellcheck disable=SC2086
    set -- $geometry
    [ "$#" -eq 12 ] || fail "could not measure the @$OWN_HANDLE badge at ${width}w $theme (got: ${geo:-nothing})"
    vw=$1 vh=$2 ax=$3 ay=$4 aw=$5 ah=$6 rx=$8 ry=$9 rw=${10} rh=${11} head_top=${12}
    [ "$7" = 1 ] || fail "the @$OWN_HANDLE link is not in the ${width}w $theme viewport"
    shot=$WORK/$SLUG.$width-$theme.full.png
    chrome-devtools-axi screenshot "$shot" >/dev/null
    # Crop the badge row the badge sits in, with nothing cut: the row's own line box across its
    # paragraph, plus the title line above it when the README carries the link as plain text.
    cx=$(( rx - 12 )); [ "$cx" -lt 0 ] && cx=0
    cw=$(( rx + rw + 12 - cx )); [ $(( cx + cw )) -gt "$vw" ] && cw=$(( vw - cx ))
    # A heading right above the row comes along, so a plain text link shows which README it sits in;
    # otherwise the band is the badge row itself, with nothing cut out of the page around it.
    cy=$(( ry - 10 ))
    if [ "$head_top" -ge 0 ] && [ $(( ry + rh + 10 - (head_top - 4) )) -le 200 ]; then
      cy=$(( head_top - 4 ))
    fi
    [ "$cy" -lt 0 ] && cy=0
    ch=$(( ry + rh + 10 - cy ))
    [ $(( cy + ch )) -gt "$vh" ] && ch=$(( vh - cy ))
    out=$OUT/badge-row.$width-$theme.png
    magick "$shot" -crop "${cw}x${ch}+${cx}+${cy}" +repage "$out"
    bytes=$(wc -c < "$out")
    if [ "$bytes" -ge 65536 ]; then
      out=$OUT/badge-row.$width-$theme.jpg
      magick "$shot" -crop "${cw}x${ch}+${cx}+${cy}" +repage -quality 80 "$out"
      rm -f -- "$OUT/badge-row.$width-$theme.png"
      bytes=$(wc -c < "$out")
    fi
    [ "$bytes" -lt 65536 ] || fail "the $width $theme capture is $bytes bytes, at or over the 65536-byte cap"
    captures="$captures $out"
    if [ "$theme" = light ] && [ -z "$light_shot" ]; then light_shot=$out; fi
    if [ "$theme" = dark ] && [ -z "$dark_shot" ]; then dark_shot=$out; fi
    log "capture $out: $bytes bytes, ${cw}x${ch} crop, page background ${c_bg}% luminance, sha256 $(sha256sum "$out" | cut -d' ' -f1)"
    log "PASS: the page rendered at ${width}w $theme: the README of $REPO at $SHA shows the @$OWN_HANDLE badge, the README body is present, and the page is not an error page (page title names $REPO, body drawn $theme, badge at ${ax},${ay} ${aw}x${ah})."
  done
done

# 3. Light and dark must be different pictures, and all four captures must exist and be small.
if cmp -s "$light_shot" "$dark_shot"; then fail "the light and dark captures are the same image"; fi
for f in $captures; do [ -s "$f" ] || fail "capture $f is empty"; done
log "PASS: four captures, 390 and 1280 wide in light and dark, each under 65536 bytes, and the light and dark pages are demonstrably different pictures."
log "PROVEN: GitHub's rendered README of $REPO pull request #$PULL at $SHA ($URL) shows the @$OWN_HANDLE badge linking to $OWN_LINK, with no other person's handle and no Discord invite."

rm -f -- "$WORK/$SLUG."*.full.png
rmdir -- "$WORK"
