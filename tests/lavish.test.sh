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
  [ ! -e "$test_root/calls" ]

  PATH="$test_root/bin:$PATH" \
    FM_HOME="$test_root/home" \
    LAVISH_TEST_VERSION='lavish-axi 1.1.0 (store-forward protocol 1)' \
    LAVISH_TEST_CALL_LOG="$test_root/calls" \
    "$ROOT/bin/fm-lavish-intake.sh"
  [ "$(cat "$test_root/calls")" = "intake --home $test_root/home" ]

  rm -rf "$test_root"
  trap - EXIT INT TERM
}

test_wake_can_disable_visible_queue() {
  test_root=$(mktemp -d)
  trap 'rm -rf "$test_root"' EXIT INT TERM
  home="$test_root/home"
  mkdir -p "$home/state" "$home/data/decisions/demo"
  printf 'answer\n' > "$home/data/decisions/demo/answer.toon"
  digest="sha256:$(shasum -a 256 "$home/data/decisions/demo/answer.toon" | awk '{print $1}')"

  out=$(
    FM_LAVISH_QUEUE_DISABLE=1 \
      "$ROOT/bin/fm-lavish-wake.sh" \
        --home "$home" \
        --decision demo \
        --answer "$home/data/decisions/demo/answer.toon" \
        --digest "$digest" \
        --destination data/replies/demo.toon
  )
  case "$out" in
    *'lavish-delivery: prompt queue disabled for demo'*) ;;
    *) echo "missing disabled queue line: $out" >&2; exit 1 ;;
  esac
  grep -F 'lavish:demo' "$home/state/.wake-queue" >/dev/null \
    || { echo "wake record was not appended" >&2; exit 1; }

  rm -rf "$test_root"
  trap - EXIT INT TERM
}

test_intake_requires_store_forward_protocol
test_wake_can_disable_visible_queue

[ "${FM_TEST_FOCUSED:-}" != intake-version-marker ] || exit 0

npm ci --ignore-scripts --prefix "$ROOT/tools/lavish"
exec npm run check --prefix "$ROOT/tools/lavish"
