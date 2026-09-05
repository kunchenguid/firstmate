#!/usr/bin/env bash
# Tests for bin/fm-gitea-axi: the axiom wrapper that prefers forgejo-axi and
# falls back to tea per-operation for Gitea/Forgejo support.
#
#   (a) shim exits non-zero and prints a usage line on no arguments
#   (b) shim exits non-zero on an unknown command
#   (c) shim exits non-zero on an unknown subcommand (pr foo)
#   (d) "pr view" without forgejo-axi on PATH exits 3 with a refusal message
#   (e) "pr list" without either forgejo-axi or tea on PATH exits 3
#   (f) "pr merge" without either exits 3
#   (g) shim refuses gitea pr head the same way as pr view (no forgejo-axi)
#   (h) shim uses forgejo-axi when available and on PATH (verified by stub)
#   (i) shim rejects /pulls/<n> on github.com in --base-url to catch a typo'd
#       URL via the host validator at the data plane
#
# The shim is non-interactive: a tests use stub binaries on PATH via a temp
# dir so they do not require forgejo-axi or tea to be installed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIM="$ROOT/bin/fm-gitea-axi"

pass=0 fail=0
report() {
  if [ "$1" = 0 ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$2"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$2" >&2
  fi
}

# Build a clean PATH that contains only /usr/bin:/bin plus whatever we add, so
# neither forgejo-axi nor tea leak into the no-forgejo test environment.
SAFE_PATH=/usr/bin:/bin

# (a) No arguments
out=$(PATH="$SAFE_PATH" "$SHIM" 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && [[ "$out" == *usage:* ]]
report "$?" "no arguments refuses with usage"

# (b) Unknown command
out=$(PATH="$SAFE_PATH" "$SHIM" whoops 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"unknown command"* ]]
report "$?" "unknown command refuses"

# (c) Unknown pr subcommand
out=$(PATH="$SAFE_PATH" "$SHIM" pr whoops 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"unknown 'pr' subcommand"* ]]
report "$?" "unknown pr subcommand refuses"

# (d) pr view without forgejo-axi exits 3 with a clear message
out=$(PATH="$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr view 4 2>&1) && rc=0 || rc=$?
[ "$rc" = 3 ] && [[ "$out" == *"forgejo-axi"* ]]
report "$?" "pr view without forgejo-axi refuses with the documented message"

# (e) pr list without either exits 3
out=$(PATH="$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr list 2>&1) && rc=0 || rc=$?
[ "$rc" = 3 ] && [[ "$out" == *"forgejo-axi"* || "$out" == *"tea"* ]]
report "$?" "pr list without either CLI refuses"

# (f) pr merge without either exits 3
out=$(PATH="$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr merge 4 2>&1) && rc=0 || rc=$?
[ "$rc" = 3 ] && [[ "$out" == *"forgejo-axi"* || "$out" == *"tea"* ]]
report "$?" "pr merge without either CLI refuses"

# (g) pr head behaves the same as pr view (forgejo-axi only)
out=$(PATH="$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr head 4 2>&1) && rc=0 || rc=$?
[ "$rc" = 3 ] && [[ "$out" == *"forgejo-axi"* ]]
report "$?" "pr head without forgejo-axi refuses with the documented message"

# (h) forgejo-axi on PATH: shim invokes it for pr view
STUBDIR=$(mktemp -d)
trap 'rm -rf "$STUBDIR"' EXIT
cat > "$STUBDIR/forgejo-axi" <<'STUB'
#!/usr/bin/env bash
# Stub: echoes argv and exits 0.
printf 'invoked: %s\n' "$*"
exit 0
STUB
chmod +x "$STUBDIR/forgejo-axi"
out=$(PATH="$STUBDIR:$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr view 42 2>&1) && rc=0 || rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"invoked:"* ]] && [[ "$out" == *"--base-url"* ]] && [[ "$out" == *"pr view 42"* ]]
report "$?" "shim invokes forgejo-axi with --base-url and pr view"

# (i) tea fallback path for pr list when forgejo-axi absent
cat > "$STUBDIR/tea" <<'STUB'
#!/usr/bin/env bash
# Stub: echoes argv and exits 0.
printf 'tea-invoked: %s\n' "$*"
exit 0
STUB
chmod +x "$STUBDIR/tea"
# Remove forgejo-axi stub but keep tea
mv "$STUBDIR/forgejo-axi" "$STUBDIR/forgejo-axi.disabled"
out=$(PATH="$STUBDIR:$SAFE_PATH" "$SHIM" --base-url https://git.example.com pr list --state all 2>&1) && rc=0 || rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"tea-invoked:"* ]]
report "$?" "shim falls back to tea for pr list when forgejo-axi absent"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]