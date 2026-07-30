#!/usr/bin/env bash
# Open a URL for captain manual testing.
#
# Preference order:
#   1. wezterm open (native subcommand when the installed wezterm provides it)
#   2. wezterm-open (captain wrapper at ~/.local/bin/wezterm-open)
#   3. macOS open or Linux xdg-open
#
# Usage:
#   fm-open-url.sh <url>
set -eu

url="${1:?usage: fm-open-url.sh <url>}"

case "$url" in
  --help|-h)
    echo "usage: fm-open-url.sh <http(s)-url>"
    exit 0
    ;;
esac

# Only hand http(s) to the opener. `open` and `xdg-open` dispatch on scheme and
# will happily launch a local file, an application, or a custom scheme handler, so
# an unvalidated argument reaching here turns "open a review URL" into "open
# whatever this string names".
case "$url" in
  http://*|https://*) ;;
  *)
    echo "fm-open-url: refusing non-http(s) target: $url" >&2
    exit 2
    ;;
esac

if command -v wezterm >/dev/null 2>&1; then
  if wezterm open "$url" >/dev/null 2>&1; then
    exit 0
  fi
fi

if command -v wezterm-open >/dev/null 2>&1; then
  if wezterm-open "$url" >/dev/null 2>&1; then
    exit 0
  fi
fi

if command -v open >/dev/null 2>&1; then
  open "$url" >/dev/null 2>&1 || true
  exit 0
fi

if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url" >/dev/null 2>&1 || true
  exit 0
fi

echo "fm-open-url: no URL opener found for $url" >&2
exit 1
