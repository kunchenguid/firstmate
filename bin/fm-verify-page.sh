#!/usr/bin/env bash
# fm-verify-page.sh - real-browser page verification, replacing chrome-devtools-axi
# in firstmate's documented workflow (see docs/known-tool-defects.md for why).
#
# Loads the URL in headless Chromium via playwright-core and reports the final
# HTTP status after redirects, the rendered title and visible text, and
# optionally a screenshot whose existence and non-zero size are checked before
# success is reported. Exits non-zero with the real error on stderr for any
# failure - a browser that cannot start, a navigation error, or a screenshot
# call that did not actually produce a file - and never prints a success line
# for something it did not verify.
#
# Usage:
#   bin/fm-verify-page.sh <url> [--screenshot <path>] [--timeout <ms>] \
#     [--wait-until load|domcontentloaded|networkidle|commit] [--text-max <n>]
#
# On success, prints one JSON object to stdout:
#   {"url", "final_url", "status", "title", "text", "screenshot"}
#
# The playwright-core runtime dependency is vendored locally under
# bin/fm-verify-page/node_modules (gitignored, not part of the tracked repo).
# One-time setup:
#   npm install --prefix bin/fm-verify-page
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/bin/fm-verify-page"

if [ ! -d "$LIB_DIR/node_modules/playwright-core" ]; then
  echo "fm-verify-page: playwright-core is not installed (install: npm install --prefix $LIB_DIR)" >&2
  exit 1
fi

command -v node >/dev/null 2>&1 || { echo "fm-verify-page: node is not installed" >&2; exit 1; }

exec node "$LIB_DIR/verify.mjs" "$@"
