#!/usr/bin/env bash
# Prime Agent harness identity regression tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prime-agent)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NODE_BIN=$(type -P node) || fail "node is required for Prime manifest identity tests"
ln -s "$NODE_BIN" "$FAKEBIN/node"
PRIME_ENTRY="$TMP_ROOT/pkg/node_modules/prime-agent/dist/bundle/cli.js"
mkdir -p "${PRIME_ENTRY%/*}"
touch "$PRIME_ENTRY"
chmod +x "$PRIME_ENTRY"
printf '%s\n' '{"name":"prime-agent","bin":{"prime-agent":"dist/bundle/cli.js"}}' \
  > "$TMP_ROOT/pkg/node_modules/prime-agent/package.json"
cat > "$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$FAKEBIN/jq"
cat > "$FAKEBIN/uname" <<'SH'
#!/bin/bash
printf '%s\n' "${FM_TEST_UNAME:-$(/usr/bin/uname)}"
SH
chmod +x "$FAKEBIN/uname"
LINKED_ENTRY="$TMP_ROOT/linked-prime/dist/bundle/cli.js"
mkdir -p "${LINKED_ENTRY%/*}"
touch "$LINKED_ENTRY"
chmod +x "$LINKED_ENTRY"
printf '%s\n' '{"name":"prime-agent","bin":{"prime-agent":"dist/bundle/cli.js"}}' \
  > "$TMP_ROOT/linked-prime/package.json"
SPACE_ENTRY="$TMP_ROOT/Linked Prime/dist/bundle/cli.js"
mkdir -p "${SPACE_ENTRY%/*}"
touch "$SPACE_ENTRY"
chmod +x "$SPACE_ENTRY"
printf '%s\n' '{"name":"prime-agent","bin":{"prime-agent":"dist/bundle/cli.js"}}' \
  > "$TMP_ROOT/Linked Prime/package.json"
for shape in node linked foreign argument space; do mkdir -p "$TMP_ROOT/proc-$shape/200"; done
printf '%s\0%s\0' "$NODE_BIN" "$PRIME_ENTRY" > "$TMP_ROOT/proc-node/200/cmdline"
printf '%s\0%s\0' "$NODE_BIN" "$LINKED_ENTRY" > "$TMP_ROOT/proc-linked/200/cmdline"
printf '%s\0%s\0' "$NODE_BIN" '/work/prime-agent/tool.js' > "$TMP_ROOT/proc-foreign/200/cmdline"
printf '%s\0%s\0%s\0' "$NODE_BIN" '/work/tool.js' "$PRIME_ENTRY" > "$TMP_ROOT/proc-argument/200/cmdline"
printf '%s\0%s\0' "$NODE_BIN" "$SPACE_ENTRY" > "$TMP_ROOT/proc-space/200/cmdline"

cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$field:$pid:${FM_TEST_PRIME_SHAPE:-exact}" in
  comm=:200:exact) printf '%s\n' '/opt/prime/bin/prime-agent' ;;
  comm=:200:node) printf '%s\n' '/opt/node/bin/node' ;;
  args=:200:node) printf '/opt/node/bin/node %s\n' "$FM_TEST_PRIME_ENTRY" ;;
  comm=:200:linked) printf '%s\n' '/opt/node/bin/node' ;;
  args=:200:linked) printf '/opt/node/bin/node %s\n' "$FM_TEST_LINKED_ENTRY" ;;
  comm=:200:space) printf '%s\n' '/opt/node/bin/node' ;;
  args=:200:space) printf '/opt/node/bin/node %s\n' "$FM_TEST_SPACE_ENTRY" ;;
  comm=:200:decoy) printf '%s\n' '/opt/prime/bin/prime-agent-helper' ;;
  args=:200:decoy) printf '%s\n' 'prime-agent-helper' ;;
  comm=:200:foreign) printf '%s\n' '/opt/node/bin/node' ;;
  args=:200:foreign) printf '%s\n' '/opt/node/bin/node /work/prime-agent/tool.js' ;;
  comm=:200:argument) printf '%s\n' '/opt/node/bin/node' ;;
  args=:200:argument) printf '/opt/node/bin/node /work/tool.js %s\n' "$FM_TEST_PRIME_ENTRY" ;;
  comm=:200:closer-claude) printf '%s\n' '/opt/claude/bin/claude' ;;
  ppid=:200:closer-claude) printf '%s\n' 300 ;;
  comm=:300:closer-claude) printf '%s\n' '/opt/prime/bin/prime-agent' ;;
  ppid=:300:closer-claude) printf '%s\n' 1 ;;
  comm=:200:weak-claude) printf '%s\n' '/opt/python/bin/python' ;;
  args=:200:weak-claude) printf '%s\n' '/opt/python/bin/python /work/claude_cleanup.py' ;;
  ppid=:200:weak-claude) printf '%s\n' 300 ;;
  comm=:300:weak-claude) printf '%s\n' '/opt/prime/bin/prime-agent' ;;
  ppid=:300:weak-claude) printf '%s\n' 1 ;;
  comm=:200:versioned-claude) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  ppid=:200:versioned-claude) printf '%s\n' 300 ;;
  comm=:300:versioned-claude) printf '%s\n' '/opt/prime/bin/prime-agent' ;;
  ppid=:300:versioned-claude) printf '%s\n' 1 ;;
  comm=:200:basename-priority) printf '%s\n' '/opt/claude/codex' ;;
  comm=:*) printf '%s\n' bash ;;
  args=:*) printf '%s\n' bash ;;
  ppid=:200:*) printf '%s\n' 1 ;;
  ppid=:*) printf '%s\n' 200 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/ps"

detect() {
  env -u CLAUDECODE -u GROK_AGENT PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    PI_CODING_AGENT=true FM_TEST_PRIME_SHAPE="$1" FM_TEST_PRIME_ENTRY="$PRIME_ENTRY" \
    FM_TEST_LINKED_ENTRY="$LINKED_ENTRY" \
    FM_TEST_SPACE_ENTRY="$SPACE_ENTRY" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/proc-$1" \
    "$ROOT/bin/fm-harness.sh"
}

got=$(detect exact)
[ "$got" = prime-agent ] \
  || fail "exact prime-agent ancestry resolved '$got', expected prime-agent"

got=$(detect node)
[ "$got" = prime-agent ] \
  || fail "Prime's node package ancestry resolved '$got', expected prime-agent"

got=$(detect linked)
[ "$got" = prime-agent ] \
  || fail "Prime's linked source-checkout entrypoint resolved '$got', expected prime-agent"

got=$(detect space)
[ "$got" = prime-agent ] \
  || fail "Prime's linked entrypoint containing spaces resolved '$got', expected prime-agent"

got=$(detect decoy)
[ "$got" = pi ] \
  || fail "prime-agent-helper decoy resolved '$got', expected shared-marker Pi fallback"

got=$(detect foreign)
[ "$got" = pi ] \
  || fail "an unrelated script under /prime-agent/ resolved '$got', expected shared-marker Pi fallback"

got=$(detect argument)
[ "$got" = pi ] \
  || fail "Prime's CLI path as a later Node argument resolved '$got', expected shared-marker Pi fallback"

got=$(detect closer-claude)
[ "$got" = claude ] \
  || fail "a closer Claude process with farther Prime ancestry resolved '$got', expected claude"

got=$(detect weak-claude)
[ "$got" = prime-agent ] \
  || fail "a weak Claude-like Python argument with real Prime ancestry resolved '$got', expected prime-agent"

got=$(detect versioned-claude)
[ "$got" = claude ] \
  || fail "a closer versioned Claude install with real Prime ancestry resolved '$got', expected claude"

got=$(detect basename-priority)
[ "$got" = codex ] \
  || fail "an exact codex basename under a Claude path resolved '$got', expected codex"

if PATH="$FAKEBIN" FM_TEST_UNAME=Darwin FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
  /bin/bash -c '. "$1/bin/fm-cursor-lib.sh"; . "$1/bin/fm-prime-lib.sh"; fm_prime_structured_argv_ready' _ "$ROOT"; then
  fail "Darwin structured argv readiness passed without python3"
fi

pass "Prime ancestry outranks its shared Pi marker without widening to similar names"
