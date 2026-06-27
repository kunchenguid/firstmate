#!/usr/bin/env bash
# Open a local firstmate-home file in a detached tmux review window.
# Usage: fm-open-file.sh [--allow-outside] [--lavish] <path>
#
# Defaults to files under this firstmate home only. Use --allow-outside only for
# an explicitly chosen file outside the home. Directories are intentionally not
# supported: the helper is for reports and concrete artifacts, not browsing.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

ALLOW_OUTSIDE=0
LAVISH=0

usage() {
  echo "usage: $(basename "$0") [--allow-outside] [--lavish] <path>" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-outside) ALLOW_OUTSIDE=1; shift ;;
    --lavish) LAVISH=1; shift ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

[ "$#" -eq 1 ] || usage
INPUT=$1

abs_path() {  # <path> -> canonical absolute path; path must exist
  perl -MCwd=abs_path -e '
    my $p = shift;
    my $abs = abs_path($p);
    exit 1 unless defined $abs;
    print $abs;
  ' "$1"
}

HOME_REAL=$(abs_path "$FM_HOME") || { echo "error: firstmate home does not exist: $FM_HOME" >&2; exit 1; }
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

if [ "$LAVISH" -eq 1 ]; then
  case "$FILE_REAL" in
    *.html|*.htm) ;;
    *) echo "error: --lavish expects an HTML file" >&2; exit 1 ;;
  esac
  command -v lavish-axi >/dev/null 2>&1 || { echo "error: lavish-axi not found on PATH" >&2; exit 1; }
fi

if [ -n "${TMUX:-}" ]; then
  SES=$(tmux display-message -p '#S') || { echo "error: could not resolve current tmux session" >&2; exit 1; }
  CURRENT_TARGET=$(tmux display-message -p '#S:#I' 2>/dev/null || true)
else
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  SES=firstmate
  CURRENT_TARGET=
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

base_name=$(basename "$FILE_REAL")
base_no_ext=${base_name%.*}
case "$rel_path" in
  data/*/report.md)
    task_id=${rel_path#data/}
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
base=$(trim_slug "$base")
[ -n "$base" ] || base=file

name=$base
i=2
while tmux list-windows -t "$SES" -F '#{window_name}' | grep -Fxq "$name"; do
  suffix="-$i"
  keep=$((28 - ${#suffix}))
  [ "$keep" -gt 0 ] || keep=24
  prefix=$(printf "%.*s" "$keep" "$base" | sed 's/[.-]*$//; s/-*$//')
  [ -n "$prefix" ] || prefix=file
  name="$prefix$suffix"
  i=$((i + 1))
done

quote() { printf '%q' "$1"; }
qfile=$(quote "$FILE_REAL")

case "$base_name" in
  *.md|*.markdown|*.mdown) is_markdown=1 ;;
  *) is_markdown=0 ;;
esac

if [ "$LAVISH" -eq 1 ]; then
  cmd="lavish-axi $qfile; status=\$?; printf '\\nlavish-axi exited with status %s. Press Enter to close this window.' \"\$status\"; read _"
elif [ "$is_markdown" -eq 1 ]; then
  cmd="if command -v glow >/dev/null 2>&1; then exec glow -p $qfile; elif command -v bat >/dev/null 2>&1; then exec bat --paging=always --style=plain -- $qfile; else exec less -R -- $qfile; fi"
else
  cmd="if command -v bat >/dev/null 2>&1; then exec bat --paging=always --style=plain -- $qfile; else exec less -R -- $qfile; fi"
fi

tmux new-window -d -t "$SES" -n "$name" -c "$HOME_REAL" "$BASH" -lc "$cmd"
if [ -n "$CURRENT_TARGET" ]; then
  tmux select-window -t "$CURRENT_TARGET" 2>/dev/null || true
fi

echo "opened: $rel_path in tmux tab $name"
