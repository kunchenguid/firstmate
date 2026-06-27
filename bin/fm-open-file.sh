#!/usr/bin/env bash
# Open local firstmate-home artifacts in a review surface without dumping content.
# Usage: fm-open-file.sh [--allow-outside] [--lavish] [--tmux] <path> [<path>...]
#
# Single Markdown/text files open in a detached tmux review tab with glow, bat,
# or less. Multiple paths open one WezTerm tab with clickable file:// links.
# --lavish runs lavish-axi for a single HTML artifact in a WezTerm tab by
# default. Use --tmux only when terminal text review is explicitly the right
# surface. Defaults to files under this firstmate home only. Use --allow-outside
# only for an explicitly chosen file outside the home. Directories are not
# supported: the helper is for reports and concrete artifacts, not browsing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

ALLOW_OUTSIDE=0
LAVISH=0
FORCE_TMUX=0

usage() {
  echo "usage: $(basename "$0") [--allow-outside] [--lavish] [--tmux] <path> [<path>...]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-outside) ALLOW_OUTSIDE=1; shift ;;
    --lavish) LAVISH=1; shift ;;
    --tmux) FORCE_TMUX=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

[ "$#" -ge 1 ] || usage

if [ "$LAVISH" -eq 1 ] && [ "$#" -ne 1 ]; then
  echo "error: --lavish expects exactly one HTML file" >&2
  exit 1
fi

if [ "$FORCE_TMUX" -eq 1 ] && [ "$#" -ne 1 ]; then
  echo "error: --tmux opens one terminal review file at a time; omit it to open a clickable WezTerm list" >&2
  exit 1
fi

abs_path() {  # <path> -> canonical absolute path; path must exist
  perl -MCwd=abs_path -e '
    my $p = shift;
    my $abs = abs_path($p);
    exit 1 unless defined $abs;
    print $abs;
  ' "$1"
}

HOME_REAL=$(abs_path "$FM_HOME") || { echo "error: firstmate home does not exist: $FM_HOME" >&2; exit 1; }

FILES_REAL=()
REL_PATHS=()
for INPUT in "$@"; do
  case "$INPUT" in
    /*) CANDIDATE=$INPUT ;;
    *) CANDIDATE=$HOME_REAL/$INPUT ;;
  esac
  FILE_REAL=$(abs_path "$CANDIDATE") || { echo "error: missing path: $INPUT" >&2; exit 1; }

  if [ -d "$FILE_REAL" ]; then
    echo "error: directories are not supported: $INPUT" >&2
    exit 1
  fi
  [ -f "$FILE_REAL" ] || { echo "error: not a regular file: $INPUT" >&2; exit 1; }

  if [ "$ALLOW_OUTSIDE" -ne 1 ]; then
    case "$FILE_REAL" in
      "$HOME_REAL"/*) ;;
      *) echo "error: path is outside firstmate home; pass --allow-outside only for an explicitly chosen safe file" >&2; exit 1 ;;
    esac
  fi

  rel_path=$FILE_REAL
  case "$FILE_REAL" in
    "$HOME_REAL"/*) rel_path=${FILE_REAL#"$HOME_REAL"/} ;;
  esac
  FILES_REAL+=("$FILE_REAL")
  REL_PATHS+=("$rel_path")
done

FILE_REAL=${FILES_REAL[0]}
rel_path=${REL_PATHS[0]}
path_count=${#FILES_REAL[@]}

if [ "$LAVISH" -eq 1 ]; then
  case "$FILE_REAL" in
    *.html|*.htm) ;;
    *) echo "error: --lavish expects an HTML file" >&2; exit 1 ;;
  esac
  command -v lavish-axi >/dev/null 2>&1 || { echo "error: lavish-axi not found on PATH" >&2; exit 1; }
fi

slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs '[:alnum:]_.-' '-' \
    | sed 's/^-*//; s/-*$//'
}

trim_slug() {
  local s=$1
  printf '%.28s' "$s" | sed 's/[.-]*$//; s/-*$//'
}

base_for_path() {  # <real-path> <relative-path>
  local real=$1 rel=$2 base_name base_no_ext task_id first_word base
  base_name=$(basename "$real")
  base_no_ext=${base_name%.*}
  case "$rel" in
    data/*/report.md)
      task_id=${rel#data/}
      task_id=${task_id%%/*}
      first_word=${task_id%%-*}
      base="report-$(slug "$first_word")"
      ;;
    .lavish/*.html|.lavish/*.htm)
      base="lavish-$(slug "$base_no_ext")"
      ;;
    *)
      base="file-$(slug "$base_no_ext")"
      ;;
  esac
  trim_slug "$base"
}

tmux_session() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S' || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf '%s\n' firstmate
  fi
}

unique_tmux_name() {  # <session> <base>
  local ses=$1 base=$2 name i suffix keep prefix
  name=$base
  i=2
  while tmux list-windows -t "$ses" -F '#{window_name}' | grep -Fxq "$name"; do
    suffix="-$i"
    keep=$((28 - ${#suffix}))
    [ "$keep" -gt 0 ] || keep=24
    prefix=$(printf "%.*s" "$keep" "$base" | sed 's/[.-]*$//; s/-*$//')
    [ -n "$prefix" ] || prefix="file"
    name="$prefix$suffix"
    i=$((i + 1))
  done
  printf '%s\n' "$name"
}

wezterm_name_exists() {  # <name>
  command -v wezterm >/dev/null 2>&1 || return 1
  wezterm cli list --format json 2>/dev/null | perl -MJSON::PP -0e '
    my $target = shift;
    my $rows = eval { decode_json(<STDIN>) } || [];
    for my $row (@$rows) {
      my $title = $row->{tab_title} || $row->{title} || "";
      exit 0 if $title eq $target;
    }
    exit 1;
  ' "$1"
}

unique_wezterm_name() {  # <base>
  local base=$1 name i suffix keep prefix
  name=$base
  i=2
  while wezterm_name_exists "$name"; do
    suffix="-$i"
    keep=$((28 - ${#suffix}))
    [ "$keep" -gt 0 ] || keep=24
    prefix=$(printf "%.*s" "$keep" "$base" | sed 's/[.-]*$//; s/-*$//')
    [ -n "$prefix" ] || prefix="file"
    name="$prefix$suffix"
    i=$((i + 1))
  done
  printf '%s\n' "$name"
}

spawn_wezterm_tab() {  # <name> <cmd>
  local name=$1 cmd=$2 pane_id
  command -v wezterm >/dev/null 2>&1 || { echo "error: wezterm not found on PATH" >&2; exit 1; }
  pane_id=$(wezterm cli spawn --cwd "$HOME_REAL" "$BASH" -lc "$cmd") || {
    echo "error: could not open WezTerm tab" >&2
    exit 1
  }
  wezterm cli set-tab-title --pane-id "$pane_id" "$name" >/dev/null 2>&1 || true
}

quote() { printf '%q' "$1"; }

file_uri() {  # <absolute-path>
  perl -e '
    my $p = shift;
    $p =~ s#^/##;
    $p =~ s/([^A-Za-z0-9._~\/-])/sprintf("%%%02X", ord($1))/ge;
    print "file:///$p";
  ' "$1"
}

base=$(base_for_path "$FILE_REAL" "$rel_path")
[ -n "$base" ] || base="file"
qfile=$(quote "$FILE_REAL")

if [ "$path_count" -gt 1 ]; then
  first_rel=${REL_PATHS[0]}
  case "$first_rel" in
    data/*/*)
      first_task=${first_rel#data/}
      first_task=${first_task%%/*}
      list_base="links-$(slug "${first_task%%-*}")"
      ;;
    *)
      first_file=$(basename "${FILES_REAL[0]}")
      list_base="links-$(slug "${first_file%.*}")"
      ;;
  esac
  list_base=$(trim_slug "$list_base")
  [ -n "$list_base" ] || list_base=links
  name=$(unique_wezterm_name "$list_base")
  list_file=$(mktemp "${TMPDIR:-/tmp}/firstmate-review-links.XXXXXX") || { echo "error: could not create temporary link list" >&2; exit 1; }
  {
    printf 'Firstmate review links\n\n'
    idx=1
    for n in "${!FILES_REAL[@]}"; do
      uri=$(file_uri "${FILES_REAL[$n]}")
      label=${REL_PATHS[$n]}
      printf '%s. \033]8;;%s\033\\%s\033]8;;\033\\\n' "$idx" "$uri" "$label"
      idx=$((idx + 1))
    done
    printf '\nPress Enter to close this tab.\n'
  } >"$list_file"
  qlist=$(quote "$list_file")
  cmd="trap 'rm -f $qlist' EXIT; cat $qlist; read _"
  spawn_wezterm_tab "$name" "$cmd"
  echo "opened: $path_count files in WezTerm tab $name"
  exit 0
fi

if [ "$LAVISH" -eq 1 ]; then
  cmd="lavish-axi $qfile; status=\$?; printf '\\nlavish-axi exited with status %s. Press Enter to close this tab.' \"\$status\"; read _"
  if [ "$FORCE_TMUX" -eq 1 ]; then
    SES=$(tmux_session) || { echo "error: could not resolve tmux session" >&2; exit 1; }
    CURRENT_TARGET=$(tmux display-message -p '#S:#I' 2>/dev/null || true)
    name=$(unique_tmux_name "$SES" "$base")
    tmux new-window -d -t "$SES" -n "$name" -c "$HOME_REAL" "$BASH" -lc "$cmd"
    if [ -n "$CURRENT_TARGET" ]; then
      tmux select-window -t "$CURRENT_TARGET" 2>/dev/null || true
    fi
    echo "opened: $rel_path with lavish-axi in tmux tab $name"
  else
    name=$(unique_wezterm_name "$base")
    spawn_wezterm_tab "$name" "$cmd"
    echo "opened: $rel_path with lavish-axi in WezTerm tab $name"
  fi
  exit 0
fi

case "$(basename "$FILE_REAL")" in
  *.md|*.markdown|*.mdown) is_markdown=1 ;;
  *) is_markdown=0 ;;
esac

SES=$(tmux_session) || { echo "error: could not resolve tmux session" >&2; exit 1; }
CURRENT_TARGET=$(tmux display-message -p '#S:#I' 2>/dev/null || true)
name=$(unique_tmux_name "$SES" "$base")

if [ "$is_markdown" -eq 1 ]; then
  cmd="if command -v glow >/dev/null 2>&1; then exec glow -p $qfile; elif command -v bat >/dev/null 2>&1; then exec bat --paging=always --style=plain -- $qfile; else exec less -R -- $qfile; fi"
else
  cmd="if command -v bat >/dev/null 2>&1; then exec bat --paging=always --style=plain -- $qfile; else exec less -R -- $qfile; fi"
fi

tmux new-window -d -t "$SES" -n "$name" -c "$HOME_REAL" "$BASH" -lc "$cmd"
if [ -n "$CURRENT_TARGET" ]; then
  tmux select-window -t "$CURRENT_TARGET" 2>/dev/null || true
fi

echo "opened: $rel_path in tmux tab $name"
