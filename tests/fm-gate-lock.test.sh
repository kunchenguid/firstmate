#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
LOCK="$ROOT/bin/fm-gate-lock.sh"
TMP=$(mktemp -d)
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP/runtime"
mkdir -p "$XDG_RUNTIME_DIR"

"$LOCK" run --holder first --timeout 5 -- sh -c 'sleep 3' &
holder=$!
for _ in $(seq 1 50); do
  if "$LOCK" status 2>/dev/null | grep -q 'held: first'; then break; fi
  sleep 0.05
done
"$LOCK" status | grep -Eq 'held: first for [0-9]+s'
start=$(date +%s)
set +e
"$LOCK" run --holder waiter --timeout 1 -- sh -c 'exit 0' >"$TMP/out" 2>"$TMP/err"
result=$?
set -e
[ "$result" -eq 75 ]
[ $(( $(date +%s) - start )) -lt 4 ]
grep -q 'timed out after 1s' "$TMP/err"
wait "$holder"

dollar=$(printf '\044')
command_code="echo ${dollar}${dollar} > \"\$1\"; exec sleep 30"
"$LOCK" run --holder killed --timeout 5 -- sh -c "$command_code" sh "$TMP/command.pid" &
holder=$!
for _ in $(seq 1 50); do
  [ -s "$TMP/command.pid" ] && break
  sleep 0.05
done
[ -s "$TMP/command.pid" ]
kill -9 "$(<"$TMP/command.pid")"
wait "$holder" 2>/dev/null || true
"$LOCK" run --holder successor --timeout 1 -- sh -c 'exit 0'
set +e
"$LOCK" status >"$TMP/free"
result=$?
set -e
[ "$result" -ne 0 ]
grep -q '^free$' "$TMP/free"

injection=$(printf '\044(touch SHOULD_NOT_EXIST)')
printf '%s\n' "$TMP/args with spaces" 'semi;colon' "$injection" > "$TMP/expected"
"$LOCK" run -- sh -c 'printf "%s\n" "$@"' sh "$TMP/args with spaces" 'semi;colon' "$injection" > "$TMP/actual"
diff -u "$TMP/expected" "$TMP/actual"
[ ! -e SHOULD_NOT_EXIST ]
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -- ] || exit 91
shift 2
exec "$@"
EOF
chmod +x "$TMP/fakebin/ssh"
PATH="$TMP/fakebin:$PATH" "$LOCK" run --host fakehost -- printf '%s\n' "$injection" > "$TMP/remote-actual"
diff -u <(printf '%s\n' "$injection") "$TMP/remote-actual"
[ ! -e SHOULD_NOT_EXIST ]
printf 'fm-gate-lock tests passed\n'
