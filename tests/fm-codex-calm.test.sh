#!/usr/bin/env bash
# Portable tests for the native Codex Calm fallback.
# These tests prove preference resolution, argument/stream preservation, and
# the absence of execution or storage changes through a disposable fake Codex.
# They do not claim that native Codex's real TUI implements row filtering.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER="$ROOT/bin/fm-codex-calm.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-calm.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fake() {
  local dir=$1
  mkdir -p "$dir"
  cat >"$dir/codex" <<'FAKE'
#!/usr/bin/env bash
set -u
: "${FAKE_LOG:?}"
printf '%s\n' "$@" >"$FAKE_LOG.argv"
cat >"$FAKE_LOG.stdin"
printf 'CAPTAIN_FINAL\nCAPTAIN_BLOCKER\nTOOL_RESULT\n'
printf 'CAPTAIN_DIAGNOSTIC\n' >&2
exit "${FAKE_EXIT:-0}"
FAKE
  chmod +x "$dir/codex"
}

run_case() {
  local name=$1 value=$2 expected=$3
  local home="$TMP_ROOT/$name" fake="$TMP_ROOT/$name/fake" log="$TMP_ROOT/$name/log"
  mkdir -p "$home/config"
  [ "$value" = absent ] || printf '%s\n' "$value" >"$home/config/calm"
  make_fake "$fake"
  : >"$log"
  local out err status
  set +e
  out=$(printf 'CAPTAIN_INPUT\n' | PATH="$fake:$PATH" FAKE_LOG="$log" FM_HOME="$home" \
    "$WRAPPER" exec --model 'model with spaces' --input 'tool result and blocker' 2>"$log.err")
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "$name changed Codex exit status"
  [ "$out" = $'CAPTAIN_FINAL\nCAPTAIN_BLOCKER\nTOOL_RESULT' ] || fail "$name changed stdout"
  [ "$(cat "$log.err")" = $'CAPTAIN_DIAGNOSTIC' ] || fail "$name changed stderr"
  [ "$(cat "$log.stdin")" = $'CAPTAIN_INPUT' ] || fail "$name changed stdin"
  diff -u <(printf '%s\n' "$expected") "$log.argv" >/dev/null || fail "$name passed unexpected arguments"
  pass "$name resolves config/calm and preserves streams"
}

run_case calm-on on $'-c\nhide_agent_reasoning=true\n-c\nshow_raw_agent_reasoning=false\nexec\n--model\nmodel with spaces\n--input\ntool result and blocker'
run_case calm-max max $'-c\nhide_agent_reasoning=true\n-c\nshow_raw_agent_reasoning=false\nexec\n--model\nmodel with spaces\n--input\ntool result and blocker'
run_case calm-off off $'exec\n--model\nmodel with spaces\n--input\ntool result and blocker'
run_case calm-unknown maybe $'exec\n--model\nmodel with spaces\n--input\ntool result and blocker'
run_case calm-absent absent $'exec\n--model\nmodel with spaces\n--input\ntool result and blocker'
run_case calm-multiline $'on\njunk' $'exec\n--model\nmodel with spaces\n--input\ntool result and blocker'

for value in $' on\r\n' $'\ton  \r\n' $' max\r\n'; do
  name="trim-${#value}"
  home="$TMP_ROOT/$name"; fake="$home/fake"; log="$home/log"
  mkdir -p "$home/config"; printf '%s' "$value" >"$home/config/calm"; make_fake "$fake"
  PATH="$fake:$PATH" FAKE_LOG="$log" FM_HOME="$home" "$WRAPPER" status >/dev/null 2>"$home/err" || fail "trimmed $value failed"
  grep -qx -- 'hide_agent_reasoning=true' "$log.argv" || fail "trimmed $value did not enable reasoning suppression"
done
pass 'no-newline, whitespace, and CRLF preferences use the shared parser semantics'

for bad in directory unreadable; do
  home="$TMP_ROOT/bad-$bad"; fake="$home/fake"; log="$home/log"
  mkdir -p "$home/config"; make_fake "$fake"
  if [ "$bad" = directory ]; then mkdir "$home/config/calm"; else printf 'on\n' >"$home/config/calm"; chmod 000 "$home/config/calm"; fi
  PATH="$fake:$PATH" FAKE_LOG="$log" FM_HOME="$home" "$WRAPPER" status >/dev/null 2>"$home/err" || fail "$bad preference path failed"
  ! grep -q 'No such file\|Permission denied\|Is a directory' "$home/err" || fail "$bad preference leaked a read error"
done
pass 'directory and unreadable preference paths fail closed without leaked errors'

caller="$TMP_ROOT/caller"
mkdir -p "$caller/config" "$caller/fake"
printf 'on\n' >"$caller/config/calm"
make_fake "$caller/fake"
caller_log="$caller/log"
PATH="$caller/fake:$PATH" FAKE_LOG="$caller_log" FM_HOME="$caller" \
  "$WRAPPER" -c 'hide_agent_reasoning=false' >/dev/null 2>"$caller/err" || fail 'caller precedence command failed'
expected=$'-c\nhide_agent_reasoning=true\n-c\nshow_raw_agent_reasoning=false\n-c\nhide_agent_reasoning=false'
diff -u <(printf '%s\n' "$expected") "$caller_log.argv" >/dev/null || fail 'caller supplied setting did not remain last'
[ "$(cat "$caller/config/calm")" = on ] || fail 'wrapper mutated calm preference'
pass 'caller supplied settings remain authoritative and config is untouched'

exit_home="$TMP_ROOT/nonzero"
mkdir -p "$exit_home/config" "$exit_home/fake"
make_fake "$exit_home/fake"
set +e
PATH="$exit_home/fake:$PATH" FAKE_LOG="$exit_home/log" FAKE_EXIT=23 FM_HOME="$exit_home" \
  "$WRAPPER" --flag >/dev/null 2>"$exit_home/err"
status=$?
set -e
[ "$status" -eq 23 ] || fail 'native Codex exit status was not preserved'
pass 'native Codex exit status is preserved'

root_home="$TMP_ROOT/root-fallback"
mkdir -p "$root_home/config" "$root_home/fake"
printf 'on\n' >"$root_home/config/calm"
make_fake "$root_home/fake"
PATH="$root_home/fake:$PATH" FAKE_LOG="$root_home/log" FM_HOME= FM_CONFIG_OVERRIDE= \
  FM_ROOT_OVERRIDE="$root_home" "$WRAPPER" status >/dev/null 2>"$root_home/err" || fail 'FM_ROOT_OVERRIDE fallback failed'
grep -qx -- 'hide_agent_reasoning=true' "$root_home/log.argv" || fail 'FM_ROOT_OVERRIDE did not resolve config/calm'
pass 'FM_ROOT_OVERRIDE resolves config/calm when FM_HOME is absent'

override="$TMP_ROOT/override"
mkdir -p "$override" "$caller/ignored"
printf 'on\n' >"$override/calm"
printf 'off\n' >"$caller/ignored/calm"
make_fake "$override/fake"
override_log="$override/log"
PATH="$override/fake:$PATH" FAKE_LOG="$override_log" FM_HOME="$caller" \
  FM_CONFIG_OVERRIDE="$override" "$WRAPPER" status >/dev/null 2>"$override/err" || fail 'config override command failed'
grep -qx -- '-c' "$override_log.argv" || fail 'config override did not enable Calm fallback'
pass 'FM_CONFIG_OVERRIDE takes precedence over FM_HOME'

printf '# all fm-codex-calm tests passed\n'
