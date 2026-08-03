#!/usr/bin/env bash
# Behavior tests for fm-open-url.sh opener preference order.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPEN_URL="$ROOT/bin/fm-open-url.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-open-url-tests.XXXXXX")
MARKER="$TMP_ROOT/marker"

make_stub_bin() {
  local name=$1
  shift
  mkdir -p "$TMP_ROOT/bin"
  printf '%s\n' "$@" > "$TMP_ROOT/bin/$name"
  chmod +x "$TMP_ROOT/bin/$name"
}

run_open() {
  rm -f "$MARKER"
  PATH="$TMP_ROOT/bin:/usr/bin:/bin" "$OPEN_URL" "$1"
}

# Prefer native wezterm open when it succeeds.
# shellcheck disable=SC2016  # single quotes are deliberate: this is a stub script body, so $1 must expand when the stub runs, not when the test writes it.
make_stub_bin wezterm \
  '#!/usr/bin/env bash' \
  'if [ "$1" = open ]; then echo native > "'"$MARKER"'" ; exit 0; fi' \
  'exit 2'
make_stub_bin wezterm-open \
  '#!/usr/bin/env bash' \
  'echo wrapper > "'"$MARKER"'" ; exit 0'
make_stub_bin open \
  '#!/usr/bin/env bash' \
  'echo macos > "'"$MARKER"'" ; exit 0'
run_open 'http://localhost:3000'
[ "$(cat "$MARKER")" = native ] || fail "expected native wezterm open"
pass 'prefers wezterm open subcommand'

# Fall back to wezterm-open when native subcommand is absent.
make_stub_bin wezterm '#!/usr/bin/env bash' 'exit 2'
run_open 'http://localhost:3011'
[ "$(cat "$MARKER")" = wrapper ] || fail "expected wezterm-open wrapper"
pass 'falls back to wezterm-open'

# Fall back to macOS open when wezterm tools are absent.
rm -f "$TMP_ROOT/bin/wezterm" "$TMP_ROOT/bin/wezterm-open"
run_open 'http://localhost:3012'
[ "$(cat "$MARKER")" = macos ] || fail "expected macOS open"
pass 'falls back to macOS open'

pass 'fm-open-url opener order'

# Non-http(s) targets must be refused before any opener runs: `open`/`xdg-open`
# dispatch on scheme and would otherwise launch a local file, an application, or a
# custom scheme handler.
for bad in \
  'file:///etc/passwd' \
  '/Applications/Calculator.app' \
  'x-apple-shortcut://run?name=whatever' \
  'javascript:alert(1)'; do
  rm -f "$MARKER"
  if PATH="$TMP_ROOT/bin:/usr/bin:/bin" "$OPEN_URL" "$bad" 2>/dev/null; then
    fail "expected refusal for $bad"
  fi
  [ -e "$MARKER" ] && fail "opener ran for refused target $bad"
done
pass 'refuses non-http(s) targets without invoking an opener'

# http and https still pass the guard.
run_open 'https://example.com/ok' || fail 'https target should be accepted'
[ "$(cat "$MARKER")" = macos ] || fail 'expected https to reach the opener'
pass 'accepts http and https'
