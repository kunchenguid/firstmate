#!/usr/bin/env bash
# Optional typed alignment check: no-key no-network, bounded conservative verdicts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-align-decide)
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$TMP_ROOT/home" LOG="$TMP_ROOT/log" CANNED="$TMP_ROOT/response"
RESPONSE=$CANNED
unset FM_ROOT_OVERRIDE TYPESAFE_API_KEY
mkdir -p "$FM_HOME" "$TMP_ROOT/bin"
printf 'Rename this private note.\n' > "$TMP_ROOT/request"
cat > "$TMP_ROOT/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LOG"
cat > "$LOG.body"
cat <&3 > "$LOG.header"
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$CANNED" "$2"; shift; fi
  shift
done
printf '%s' "${HTTP:-200}"
FAKE
chmod +x "$TMP_ROOT/bin/curl"
export PATH="$TMP_ROOT/bin:$PATH"
tool="$ROOT/bin/fm-align-decide.sh"
result=$("$tool" "$TMP_ROOT/request" --eligible 2> "$TMP_ROOT/stderr")
[ -z "$result" ] && [ ! -e "$LOG" ]
grep -qx 'align-decide: off' "$TMP_ROOT/stderr"
printf 'TYPESAFE_API_KEY=file-secret\n' > "$FM_HOME/.env"
[ "$("$tool" "$TMP_ROOT/request")" = 'align-decide: discuss' ]
[ ! -e "$LOG" ]
printf '%s\n' '{"answers":{"lane":{"choice":"fast","confidence":0.95,"probabilities":{"fast":0.95,"discuss":0.05}}}}' > "$RESPONSE"
[ "$("$tool" "$TMP_ROOT/request" --eligible)" = 'align-decide: fast' ]
grep -q 'Bearer file-secret' "$LOG.header"
if grep -q secret "$LOG"; then echo 'secret leaked into argv' >&2; exit 1; fi
export TYPESAFE_API_KEY=environment-secret
[ "$("$tool" "$TMP_ROOT/request" --eligible)" = 'align-decide: fast' ]
grep -q 'Bearer environment-secret' "$LOG.header"
jq -e '.model == "jev-latest" and .questions.lane.type == "choice" and (.state.request | contains("Rename"))' "$LOG.body" >/dev/null
for response in '{}' '{"answers":{"lane":{"choice":"fast","confidence":0.2,"probabilities":{"fast":0.95,"discuss":0.05}}}}' '{"answers":{"lane":{"choice":"fast","confidence":1,"probabilities":{"fast":1,"discuss":1}}}}' '{"answers":{"lane":{"choice":"discuss","confidence":1,"probabilities":{"fast":0,"discuss":1}}}}'; do
  printf '%s\n' "$response" > "$RESPONSE"
  [ "$("$tool" "$TMP_ROOT/request" --eligible)" = 'align-decide: discuss' ]
done
HTTP=503 "$tool" "$TMP_ROOT/request" --eligible | grep -qx 'align-decide: discuss'
printf 'ok - typed alignment check\n'
