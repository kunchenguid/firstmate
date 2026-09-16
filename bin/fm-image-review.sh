#!/usr/bin/env bash
# fm-image-review.sh - generate a Lavish image-review page for an image tree.
#
# Recursively walks <images-root> in deterministic C-locale sorted order,
# collects .jpg/.jpeg/.png/.webp/.gif files, skips hidden directories and
# files plus every non-image entry, and writes one self-contained review
# page (default <images-root>/.image-review.html). Images stay where they
# are and are referenced with relative paths - nothing is copied or moved,
# and no external CDN dependency is introduced.
#
# The page mirrors the file structure: top-level directory segments become
# tabs, deeper segments become nested collapsible <details> sections (every
# level can be collapsed), and images render as medium lazy-loaded
# thumbnails (~350px) in a grid. Clicking a thumbnail opens a full-size
# lightbox that closes on Esc or backdrop click. Every image carries a
# stable data-image-id equal to its path relative to the root. Each card
# carries a comment input and a select/clear control wired through
# window.lavish.queuePrompt (one queueKey per image, per the lavish-axi
# playbook "input") so queued feedback maps every comment back to its image
# path; a Send-all button calls window.lavish.sendQueuedPrompts().
#
# Usage: fm-image-review.sh <images-root> [--out <path>] [--title <text>]
#   fm-image-review.sh --help
#
# <images-root>   directory to walk (required; must contain at least one
#                 reviewable image).
# --out <path>    page destination. Default <images-root>/.image-review.html.
#                 The parent directory must already exist. Relative image
#                 references are computed from the page's own directory, so
#                 any destination works.
# --title <text>  page heading. Default "Image review: <root basename>".
#
# Determinism: the page is a pure function of the tree, the destination,
# and the title - rerunning over an unchanged tree rewrites identical
# bytes. The default page name is a hidden dotfile, so the walk skips it on
# rerun; a custom --out inside the root is excluded by resolved path.
# Filenames containing newlines are not supported (the walk is
# newline-delimited); every other character is HTML-escaped and URL-quoted.
# Linear lookups deliberately support stock macOS Bash 3.2, so this script
# uses no associative arrays, mapfile, or case-modification expansions.
#
# This is a worktree utility for crewmates, not a supervision script, so it
# does not call fm-guard.sh.
set -eu

usage() {
  echo "usage: fm-image-review.sh <images-root> [--out <path>] [--title <text>]" >&2
}

die() {
  echo "fm-image-review.sh: $*" >&2
  exit 1
}

help() {
  cat <<'EOF'
fm-image-review.sh - generate a Lavish image-review page for an image tree.

Walks the given directory recursively (C-locale sorted, hidden entries and
non-images skipped), then writes a self-contained review page that groups
images by the file structure: top-level directory segments become tabs,
deeper segments become nested collapsible sections, and images render as
medium lazy-loaded thumbnails with a full-size lightbox. Each image card
has a comment input and a select/clear control; queued feedback carries the
image's data-image-id (its path relative to the root), so an agent reading
the Lavish poll maps every comment back to an image path.

  fm-image-review.sh <images-root> [--out <path>] [--title <text>]

Open the generated page with `lavish-axi <page>` and read feedback with
`lavish-axi poll <page>`.
EOF
}

# HTML-escape a literal for element or attribute context.
html_escape() {
  local s=$1
  s=${s//'&'/'&amp;'}
  s=${s//'<'/'&lt;'}
  s=${s//'>'/'&gt;'}
  s=${s//'"'/'&quot;'}
  s=${s//"'"/'&#39;'}
  printf '%s' "$s"
}

# Percent-quote a relative URL path. Keeps [A-Za-z0-9._~/-] and byte-encodes
# everything else, so UTF-8 filenames survive as valid URL components.
url_quote() {
  local s=$1
  local out='' c i j bytes
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~/-]) out+=$c ;;
      *)
        bytes=$(printf '%s' "$c" | od -An -tx1 | tr -d ' \n')
        for ((j = 0; j < ${#bytes}; j += 2)); do
          out+="%${bytes:j:2}"
        done
        ;;
    esac
  done
  printf '%s' "$out"
}

# Print the path of <to> relative to directory <from>. Both absolute.
relpath() {
  local from=$1 to=$2
  local -a f t
  IFS='/' read -r -a f <<< "${from#/}"
  IFS='/' read -r -a t <<< "${to#/}"
  local max=${#f[@]}
  if [ "${#t[@]}" -lt "$max" ]; then max=${#t[@]}; fi
  local common=0 i
  for ((i = 0; i < max; i++)); do
    if [ "${f[$i]}" != "${t[$i]}" ]; then break; fi
    common=$((i + 1))
  done
  local out=''
  for ((i = common; i < ${#f[@]}; i++)); do out+='../'; done
  for ((i = common; i < ${#t[@]}; i++)); do out+="${t[$i]}/"; done
  out=${out%/}
  printf '%s' "${out:-.}"
}

IMAGE_EXTS='jpg jpeg png webp gif'

is_image_name() {
  local ext
  ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
  local known
  for known in $IMAGE_EXTS; do
    if [ "$ext" = "$known" ]; then return 0; fi
  done
  return 1
}

# tab keys/labels in first-appearance (sorted) order; linear lookup for
# stock macOS Bash 3.2 (no associative arrays).
declare -a TAB_KEYS=()
declare -a TAB_LABELS=()
declare -a IDS=()
declare -a IMGS=()

collect_tab() {
  local key=$1 label=$2 i
  for ((i = 0; i < ${#TAB_KEYS[@]}; i++)); do
    if [ "${TAB_KEYS[$i]}" = "$key" ]; then return 0; fi
  done
  TAB_KEYS+=("$key")
  TAB_LABELS+=("$label")
}

# Emit one image card. Absolute image path plus its root-relative id.
emit_card() {
  local img=$1 id=$2
  local name=${id##*/}
  local id_esc name_esc rel rel_esc
  id_esc=$(html_escape "$id")
  name_esc=$(html_escape "$name")
  rel=$(relpath "$OUT_DIR" "$img")
  rel_esc=$(url_quote "$rel")
  printf '<figure class="card" data-image-id="%s">\n' "$id_esc"
  printf '<button type="button" class="thumbbtn" data-full="%s" data-image-id="%s" aria-label="Open full size: %s">' \
    "$rel_esc" "$id_esc" "$name_esc"
  printf '<img class="thumb" loading="lazy" decoding="async" src="%s" alt="%s"></button>\n' \
    "$rel_esc" "$name_esc"
  printf '<figcaption class="file" title="%s">%s</figcaption>\n' "$id_esc" "$name_esc"
  printf '<form class="fb" data-image-id="%s">\n' "$id_esc"
  printf '<button type="button" class="fb-select">Select</button>\n'
  printf '<input class="fb-comment" type="text" placeholder="Comment..." aria-label="Comment for %s">\n' "$id_esc"
  printf '<button type="submit" class="fb-queue">Queue feedback</button>\n'
  printf '<span class="fb-queued" hidden>queued</span>\n</form>\n</figure>\n'
}

# Walk the collected image list and emit tab panes. A pane opens per tab
# key; inside it a details element opens per path segment deeper than the
# tab, and consecutive images sharing one parent chain share one grid.
emit_panes() {
  local i nseg nsub tab_key l max d j
  local have_pane=0 pane_index=-1 grid_open=0 nopen=0 cur_key=''
  local -a segs=() chain=()
  for ((i = 0; i < ${#IDS[@]}; i++)); do
    IFS='/' read -r -a segs <<< "${IDS[$i]}"
    nseg=${#segs[@]}
    if [ "$nseg" -eq 1 ]; then
      tab_key=''
    else
      tab_key=${segs[0]}
    fi
    if [ "$have_pane" -eq 0 ] || [ "$tab_key" != "$cur_key" ]; then
      if [ "$grid_open" -eq 1 ]; then
        printf '</div>\n'
        grid_open=0
      fi
      if [ "$nopen" -gt 0 ]; then
        for ((d = 0; d < nopen; d++)); do printf '</details>\n'; done
        chain=()
        nopen=0
      fi
      if [ "$have_pane" -eq 1 ]; then printf '</section>\n'; fi
      pane_index=$((pane_index + 1))
      if [ "$pane_index" -eq 0 ]; then
        printf '<section class="pane active" id="pane-%d">\n' "$pane_index"
      else
        printf '<section class="pane" id="pane-%d">\n' "$pane_index"
      fi
      have_pane=1
      cur_key=$tab_key
    fi
    # sub-chain for this image: segs[1..nseg-2] are collapsible levels;
    # segs[nseg-1] is the file name itself and never becomes a level
    if [ "$nseg" -gt 2 ]; then
      nsub=$((nseg - 2))
    else
      nsub=0
    fi
    l=0
    max=$nsub
    if [ "${#chain[@]}" -lt "$max" ]; then max=${#chain[@]}; fi
    for ((j = 0; j < max; j++)); do
      if [ "${segs[$((j + 1))]}" != "${chain[$j]}" ]; then break; fi
      l=$((j + 1))
    done
    if [ "$grid_open" -eq 1 ]; then
      if [ "$nopen" -gt "$l" ] || [ "$nsub" -gt "$l" ]; then
        printf '</div>\n'
        grid_open=0
      fi
    fi
    if [ "$nopen" -gt "$l" ]; then
      for ((d = 0; d < nopen - l; d++)); do printf '</details>\n'; done
      if [ "$l" -gt 0 ]; then chain=("${chain[@]:0:$l}"); else chain=(); fi
      nopen=$l
    fi
    for ((d = nopen; d < nsub; d++)); do
      printf '<details open><summary>%s</summary>\n' "$(html_escape "${segs[$((d + 1))]}")"
      chain+=("${segs[$((d + 1))]}")
      nopen=$((nopen + 1))
    done
    if [ "$grid_open" -eq 0 ]; then
      printf '<div class="grid">\n'
      grid_open=1
    fi
    emit_card "${IMGS[$i]}" "${IDS[$i]}"
  done
  if [ "$grid_open" -eq 1 ]; then printf '</div>\n'; fi
  if [ "$nopen" -gt 0 ]; then
    for ((d = 0; d < nopen; d++)); do printf '</details>\n'; done
  fi
  if [ "$have_pane" -eq 1 ]; then printf '</section>\n'; fi
}

main() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    help
    exit 0
  fi
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi
  local root_arg=$1
  shift
  local out_arg='' title_arg=''
  while [ $# -gt 0 ]; do
    case $1 in
      --out)
        [ $# -ge 2 ] || die "--out needs a path"
        out_arg=$2
        shift 2
        ;;
      --title)
        [ $# -ge 2 ] || die "--title needs text"
        title_arg=$2
        shift 2
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done

  [ -d "$root_arg" ] || die "images root is not a directory: $root_arg"
  ROOT=$(cd "$root_arg" && pwd -P)

  if [ -n "$out_arg" ]; then
    case $out_arg in
      /*) OUT=$out_arg ;;
      *) OUT=$PWD/$out_arg ;;
    esac
  else
    OUT=$ROOT/.image-review.html
  fi
  OUT_DIR=$(cd "$(dirname "$OUT")" 2>/dev/null && pwd -P) \
    || die "--out parent directory does not exist: $(dirname "$OUT")"
  OUT="$OUT_DIR/$(basename "$OUT")"
  if [ -d "$OUT" ]; then
    die "--out points at an existing directory: $OUT"
  fi

  if [ -n "$title_arg" ]; then
    TITLE=$title_arg
  else
    TITLE="Image review: ${ROOT##*/}"
  fi

  # Walk: prune hidden entries at every depth, keep regular files, drop the
  # page itself, then filter to image extensions in C-locale sorted order.
  local path ext
  while IFS= read -r path; do
    if [ "$path" = "$OUT" ]; then continue; fi
    is_image_name "$path" || continue
    IMGS+=("$path")
    IDS+=("${path#"$ROOT"/}")
  done < <(find "$ROOT" -mindepth 1 \( -name '.*' -prune \) -o \( -type f -print \) | LC_ALL=C sort)

  local count=${#IDS[@]}
  if [ "$count" -eq 0 ]; then
    die "no reviewable images ($IMAGE_EXTS) found under $ROOT"
  fi

  local i id_key id_label nseg
  local -a tsegs=()
  for ((i = 0; i < count; i++)); do
    IFS='/' read -r -a tsegs <<< "${IDS[$i]}"
    nseg=${#tsegs[@]}
    if [ "$nseg" -eq 1 ]; then
      id_key=''
      id_label='(root)'
    else
      id_key=${IDS[$i]%%/*}
      id_label=$id_key
    fi
    collect_tab "$id_key" "$id_label"
  done

  # Reorder so all images sharing a tab key are contiguous
  local -a ORDERED_IDS=() ORDERED_IMGS=()
  local j
  for ((j = 0; j < ${#TAB_KEYS[@]}; j++)); do
    for ((i = 0; i < count; i++)); do
      IFS='/' read -r -a tsegs <<< "${IDS[$i]}"
      nseg=${#tsegs[@]}
      if [ "$nseg" -eq 1 ]; then
        id_key=''
      else
        id_key=${IDS[$i]%%/*}
      fi
      if [ "$id_key" = "${TAB_KEYS[$j]}" ]; then
        ORDERED_IDS+=("${IDS[$i]}")
        ORDERED_IMGS+=("${IMGS[$i]}")
      fi
    done
  done
  IDS=("${ORDERED_IDS[@]}")
  IMGS=("${ORDERED_IMGS[@]}")

  {
    cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(html_escape "$TITLE")</title>
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #14161a; color: #e8eaf0; }
body.no-scroll { overflow: hidden; }
.bar { position: sticky; top: 0; z-index: 20; display: flex; flex-wrap: wrap; gap: 10px; align-items: center; padding: 10px 16px; background: #1b1e24; border-bottom: 1px solid #2a2f38; min-width: 0; }
.bar h1 { font-size: 15px; margin: 0; font-weight: 600; overflow-wrap: anywhere; min-width: 0; }
.bar .meta { color: #9aa3b2; font-size: 12px; overflow-wrap: anywhere; }
.banner { padding: 8px 16px; background: #4a2b12; color: #ffd9a8; font-size: 13px; }
.hint { padding: 8px 16px; color: #9aa3b2; font-size: 12.5px; }
.tabs { display: flex; gap: 6px; overflow-x: auto; padding: 8px 16px 0; min-width: 0; }
.tab { border: 1px solid #2a2f38; background: #1b1e24; color: #cdd3de; padding: 7px 14px; border-radius: 8px 8px 0 0; cursor: pointer; font-size: 13px; white-space: nowrap; flex: 0 0 auto; }
.tab.active { background: #2a3040; color: #fff; border-color: #3b4356; }
main { padding: 0 16px 64px; min-width: 0; }
.pane { display: none; padding-top: 12px; min-width: 0; }
.pane.active { display: block; }
details { margin: 10px 0; border: 1px solid #2a2f38; border-radius: 10px; background: #191c21; min-width: 0; }
details details { margin: 10px; }
details > summary { cursor: pointer; padding: 8px 12px; font-weight: 600; font-size: 13.5px; color: #aeb8c8; user-select: none; overflow-wrap: anywhere; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 14px; padding: 4px 12px 14px; min-width: 0; }
.card { margin: 0; border: 1px solid #262b33; border-radius: 10px; background: #14161a; padding: 10px; min-width: 0; }
.card.selected { border-color: #4f8cf0; box-shadow: 0 0 0 1px #4f8cf0 inset; }
.thumbbtn { display: block; width: 100%; padding: 0; border: 0; background: #0e1013; border-radius: 6px; cursor: zoom-in; min-width: 0; }
.thumb { display: block; width: 100%; max-width: 350px; height: 240px; object-fit: contain; margin: 0 auto; }
.file { font-size: 12.5px; color: #cdd3de; margin: 8px 0 6px; overflow-wrap: anywhere; }
.fb { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; min-width: 0; }
.fb-comment { flex: 1 1 140px; min-width: 120px; background: #0e1013; color: #e8eaf0; border: 1px solid #2a2f38; border-radius: 6px; padding: 6px 8px; font-size: 12.5px; }
button { font-family: inherit; }
button.fb-select, button.fb-queue, button#send-all, button#lb-close { background: #2a3040; color: #e8eaf0; border: 1px solid #3b4356; border-radius: 6px; padding: 6px 10px; font-size: 12.5px; cursor: pointer; flex: 0 0 auto; }
button.fb-select:hover, button.fb-queue:hover, button#send-all:hover { background: #343c50; }
button#send-all { background: #2f5d3a; border-color: #3d7a4c; }
button#send-all:disabled { opacity: .5; cursor: default; }
button#lb-close { position: absolute; top: 12px; right: 16px; font-size: 16px; padding: 6px 12px; }
.fb-queued { color: #7cc47c; font-size: 11.5px; flex: 0 0 auto; }
.lightbox { position: fixed; inset: 0; z-index: 50; background: rgba(5, 6, 8, .92); display: none; align-items: center; justify-content: center; cursor: zoom-out; padding: 24px; }
.lightbox.open { display: flex; }
.lb-frame { max-width: min(96vw, 1400px); min-width: 0; }
.lb-frame img { max-width: 100%; max-height: 82vh; display: block; margin: 0 auto; border-radius: 4px; }
.lb-id { margin-top: 8px; color: #9aa3b2; font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; overflow-wrap: anywhere; text-align: center; }
@media (max-width: 480px) {
  .grid { grid-template-columns: 1fr; }
  .thumb { height: 200px; }
}
</style>
</head>
<body>
<header class="bar">
  <h1>$(html_escape "$TITLE")</h1>
  <div class="meta">$count images in ${#TAB_KEYS[@]} groups</div>
  <button id="send-all" type="button">Send all feedback</button>
</header>
<div id="lavish-required" class="banner" hidden>This page is not connected to Lavish. Open it through lavish-axi so feedback reaches the agent.</div>
<div class="hint">Click a thumbnail for full size (Esc or click outside closes it). Select and comment per image, then use Send all feedback - or Lavish's Send to Agent - so the agent receives your comments with their image paths.</div>
<nav class="tabs">
HEAD
    local t cls sel
    for ((t = 0; t < ${#TAB_KEYS[@]}; t++)); do
      cls=''
      sel='false'
      if [ "$t" -eq 0 ]; then
        cls=' active'
        sel='true'
      fi
      printf '<button type="button" class="tab%s" data-pane="pane-%d" role="tab" aria-selected="%s">%s</button>\n' \
        "$cls" "$t" "$sel" "$(html_escape "${TAB_LABELS[$t]}")"
    done
    printf '</nav>\n<main>\n'
    emit_panes
    cat <<TAIL
</main>
<div class="lightbox" id="lightbox" data-lavish-action="lightbox-close">
  <button type="button" id="lb-close" aria-label="Close full size view">&#10005;</button>
  <div class="lb-frame">
    <img id="lb-img" alt="">
    <div class="lb-id" id="lb-id"></div>
  </div>
</div>
<script>
(function () {
  /* Lavish injects window.lavish into the artifact frame after load, so
     availability is re-checked on an interval instead of read once. */
  var queue = null;
  var sendAllFn = null;
  var banner = document.getElementById('lavish-required');
  var sendAll = document.getElementById('send-all');
  function refreshLavish() {
    var l = (typeof window.lavish === 'object' && window.lavish) || null;
    queue = l && typeof l.queuePrompt === 'function' ? l.queuePrompt : null;
    sendAllFn = l && typeof l.sendQueuedPrompts === 'function' ? l.sendQueuedPrompts : null;
    if (banner) banner.hidden = !!queue;
    if (sendAll) sendAll.disabled = !sendAllFn;
  }
  refreshLavish();
  setInterval(refreshLavish, 700);
  if (sendAll) {
    sendAll.addEventListener('click', function () {
      if (sendAllFn) sendAllFn();
    });
  }

  var tabs = Array.prototype.slice.call(document.querySelectorAll('.tab'));
  var panes = Array.prototype.slice.call(document.querySelectorAll('.pane'));
  tabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      tabs.forEach(function (t) { t.classList.remove('active'); t.setAttribute('aria-selected', 'false'); });
      panes.forEach(function (p) { p.classList.remove('active'); });
      tab.classList.add('active');
      tab.setAttribute('aria-selected', 'true');
      var pane = document.getElementById(tab.getAttribute('data-pane'));
      if (pane) pane.classList.add('active');
    });
  });

  var lightbox = document.getElementById('lightbox');
  var lbImg = document.getElementById('lb-img');
  var lbId = document.getElementById('lb-id');
  function closeLightbox() {
    lightbox.classList.remove('open');
    lbImg.removeAttribute('src');
    document.body.classList.remove('no-scroll');
  }
  Array.prototype.slice.call(document.querySelectorAll('.thumbbtn')).forEach(function (btn) {
    btn.addEventListener('click', function () {
      lbImg.src = btn.getAttribute('data-full');
      lbImg.alt = btn.getAttribute('data-image-id');
      lbId.textContent = btn.getAttribute('data-image-id');
      lightbox.classList.add('open');
      document.body.classList.add('no-scroll');
    });
  });
  lightbox.addEventListener('click', function (event) {
    if (event.target === lightbox) closeLightbox();
  });
  var lbClose = document.getElementById('lb-close');
  if (lbClose) lbClose.addEventListener('click', closeLightbox);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && lightbox.classList.contains('open')) closeLightbox();
  });

  Array.prototype.slice.call(document.querySelectorAll('form.fb')).forEach(function (form) {
    var selectBtn = form.querySelector('.fb-select');
    var comment = form.querySelector('.fb-comment');
    var card = form.closest('.card');
    var badge = form.querySelector('.fb-queued');
    selectBtn.addEventListener('click', function () {
      var on = card.classList.toggle('selected');
      selectBtn.textContent = on ? 'Clear selection' : 'Select';
    });
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      if (!queue) return;
      var id = form.getAttribute('data-image-id');
      var text = comment.value.trim();
      var selected = card.classList.contains('selected');
      if (!text && !selected) return;
      var prompt = 'Image "' + id + '": ' + (selected ? 'selected' : 'not selected') +
        (text ? '. Comment: ' + text : '. No comment.');
      queue(prompt, {
        tag: 'image-feedback',
        text: prompt,
        element: form,
        queueKey: 'image-feedback:' + id,
        data: { image: id, comment: text, selected: selected }
      });
      if (badge) badge.hidden = false;
    });
  });
})();
</script>
</body>
</html>
TAIL
  } > "$OUT"

  printf 'image-review: %s (%d images, %d groups)\n' "$OUT" "$count" "${#TAB_KEYS[@]}"
}

main "$@"
