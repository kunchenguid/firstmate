#!/bin/sh
# Durable Lavish protocol, failure recovery, migration, and no-resident-resource
# behavior.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

test_intake_requires_store_forward_protocol() {
  test_root=$(mktemp -d)
  trap 'rm -rf "$test_root"' EXIT INT TERM
  mkdir -p "$test_root/bin" "$test_root/home"
  cat > "$test_root/bin/lavish-axi" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${LAVISH_TEST_VERSION:?}"
  exit 0
fi
printf '%s\n' "$*" >> "${LAVISH_TEST_CALL_LOG:?}"
SH
  chmod +x "$test_root/bin/lavish-axi"

  PATH="$test_root/bin:$PATH" \
    FM_HOME="$test_root/home" \
    LAVISH_TEST_VERSION='lavish-axi 1.0.0' \
    LAVISH_TEST_CALL_LOG="$test_root/calls" \
    "$ROOT/bin/fm-lavish-intake.sh"
  [ ! -e "$test_root/calls" ]

  PATH="$test_root/bin:$PATH" \
    FM_HOME="$test_root/home" \
    LAVISH_TEST_VERSION='lavish-axi 1.0.0 (store-forward protocol 1)' \
    LAVISH_TEST_CALL_LOG="$test_root/calls" \
    "$ROOT/bin/fm-lavish-intake.sh"
  [ "$(cat "$test_root/calls")" = "intake --home $test_root/home" ]

  rm -rf "$test_root"
  trap - EXIT INT TERM
}

test_intake_requires_store_forward_protocol

[ "${FM_TEST_FOCUSED:-}" != intake-version-marker ] || exit 0

npm ci --ignore-scripts --prefix "$ROOT/tools/lavish"
exec npm run check --prefix "$ROOT/tools/lavish"
