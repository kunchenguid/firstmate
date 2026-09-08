#!/usr/bin/env bash
# The claude launch template must carry the minimal tool surface, and the
# brief's tools: line must be the only thing that widens it.
set -u
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

# The non-secondmate claude template is the one carrying the minimal surface
# (a secondmate is exempt - see docs/configuration.md); its printf line is the
# only one that pairs --strict-mcp-config with --mcp-config, so grep on that
# pairing rather than on `claude) printf`, which no longer names a single line.
TEMPLATE=$(grep -n -- '--strict-mcp-config --mcp-config' "$ROOT/bin/fm-spawn.sh" | head -1)

case "$TEMPLATE" in
  *"--strict-mcp-config"*) echo "ok - template pins strict MCP config" ;;
  *) echo "FAIL - template does not pass --strict-mcp-config"; FAIL=1 ;;
esac

case "$TEMPLATE" in
  *"__MCPCONFIG__"*) echo "ok - template carries the per-task MCP config placeholder" ;;
  *) echo "FAIL - no MCP config placeholder in the template"; FAIL=1 ;;
esac

case "$TEMPLATE" in
  *"--setting-sources"*) echo "ok - template pins its setting sources" ;;
  *) echo "FAIL - template does not pin --setting-sources"; FAIL=1 ;;
esac

write_brief() {  # <file> <tools-line>
  cat > "$1" <<EOF
# Task
## Captain's intent
Do the thing.

## Firstmate spec
Scout: knowledge deliverable only.
$2
EOF
}

write_brief "$TMP/none.md" ""
GOT=$(fm_brief_tools "$TMP/none.md")
if [ -z "$GOT" ]; then
  echo "ok - no tools line means no extras"
else
  echo "FAIL - expected empty, got '$GOT'"; FAIL=1
fi

write_brief "$TMP/browser.md" "tools: browser context7"
GOT=$(fm_brief_tools "$TMP/browser.md")
if [ "$GOT" = "browser context7" ]; then
  echo "ok - extras parsed"
else
  echo "FAIL - expected 'browser context7', got '$GOT'"; FAIL=1
fi

write_brief "$TMP/bogus.md" "tools: browser nonsense"
GOT=$(fm_brief_tools "$TMP/bogus.md" 2>/dev/null)
case "$GOT" in
  *nonsense*) echo "FAIL - an unrecognized extra was accepted"; FAIL=1 ;;
  *) echo "ok - an unrecognized extra is dropped" ;;
esac

exit "$FAIL"
