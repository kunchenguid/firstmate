#!/usr/bin/env bash
# Behavior of bin/fm-lavish-open.sh: the one command that opens a Lavish page in
# front of the captain and reports whether the browser launch was refused.
# A PATH stub stands in for lavish-axi; it reports the launch failure the way
# the installed WSL wrapper does unless WSL_INTEROP names the socket the case
# marks as live, and logs every call so retry order is observable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OPEN="$ROOT/bin/fm-lavish-open.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-open)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ARTIFACT="$TMP_ROOT/page.html"
printf '<!doctype html><title>t</title>\n' > "$ARTIFACT"

cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${WSL_INTEROP-}" "$*" >> "$STUB_LOG"
[ "${STUB_RC:-0}" -eq 0 ] || { echo "error: stub refused" >&2; exit "$STUB_RC"; }
if [ -s "$STUB_LOG.seen" ]; then status=resumed; else status=${STUB_STATUS:-opened}; fi
echo seen >> "$STUB_LOG.seen"
printf 'session:\n  file: %s\n  url: "https://host.example:8387/session/abc123"\n  status: %s\n' "$1" "$status"
if [ "${STUB_FAIL:-0}" = 1 ] && [ "${WSL_INTEROP-}" != "${STUB_GOOD_SOCKET-none}" ]; then
  echo "lavish-axi: Windows browser launch failed" >&2
fi
exit 0
SH
chmod +x "$FAKEBIN/lavish-axi"

# make_socket <path> <mtime-epoch>
make_socket() {
  perl -MIO::Socket::UNIX -e '
    my $s = IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die "socket: $!\n";
    utime($ARGV[1], $ARGV[1], $ARGV[0]) or die "utime: $!\n";
  ' "$1" "$2" || fail "cannot create fixture socket $1"
}

RUN="$TMP_ROOT/run-wsl"
mkdir -p "$RUN"
make_socket "$RUN/2_interop" 1000000000
ln -s "$RUN/2_interop" "$RUN/1_interop"
make_socket "$RUN/500_interop" 1700000000
make_socket "$RUN/900_interop" 1800000000
printf 'not a socket\n' > "$RUN/777_interop"

N=0
# run_case <env assignments...> -- <helper args...>; sets OUT, ERR, RC, LOG.
run_case() {
  N=$((N + 1))
  LOG="$TMP_ROOT/calls.$N"
  : > "$LOG"
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  RC=0
  env -u WSL_INTEROP PATH="$FAKEBIN:$PATH" STUB_LOG="$LOG" FM_LAVISH_INTEROP_DIR="$RUN" "${envs[@]}" \
    "$OPEN" "$@" >"$TMP_ROOT/out.$N" 2>"$TMP_ROOT/err.$N" || RC=$?
  OUT=$(cat "$TMP_ROOT/out.$N")
  ERR=$(cat "$TMP_ROOT/err.$N")
}

calls() { cut -d'|' -f1 "$LOG" | tr '\n' ' ' | sed 's/ $//'; }

run_case -- "$ARTIFACT"
expect_code 0 "$RC" "clean launch"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "a launch that reported no failure must not be retried"
assert_contains "$OUT" "status: opened" "the first run's output must be printed"
assert_equals "browser-launch: ok" "$(tail -n 1 "$TMP_ROOT/out.$N")" "clean launch verdict"
pass "a launch with no reported failure runs once and reports ok"

run_case STUB_FAIL=1 STUB_GOOD_SOCKET="$RUN/500_interop" -- "$ARTIFACT"
expect_code 0 "$RC" "recovered launch"
assert_equals " $RUN/900_interop $RUN/500_interop" "$(calls)" "a failed launch must retry with each interop socket newest first and stop at the first that works"
assert_equals "browser-launch: ok" "$(tail -n 1 "$TMP_ROOT/out.$N")" "recovered launch verdict"
assert_contains "$ERR" "browser launch failed" "the first attempt's failure must stay visible on stderr"
assert_not_contains "$OUT" "status: resumed" "only the first run's session output is printed"
pass "a failed launch retries through live interop sockets newest first and reports ok once one works"

run_case STUB_FAIL=1 -- "$ARTIFACT"
expect_code 0 "$RC" "unrecoverable launch keeps lavish-axi's success"
assert_equals " $RUN/900_interop $RUN/500_interop $RUN/1_interop" "$(calls)" "every distinct socket is tried once; a symlink and a non-socket are not extra candidates"
assert_equals "browser-launch: failed https://host.example:8387/session/abc123" "$(tail -n 1 "$TMP_ROOT/out.$N")" "an unrecoverable launch must name the URL to hand the captain"
pass "an unrecoverable launch reports failed with the session URL after one try per socket"

run_case STUB_FAIL=1 WSL_INTEROP="$RUN/900_interop" -- "$ARTIFACT"
assert_equals "$RUN/900_interop $RUN/500_interop $RUN/1_interop" "$(calls)" "the caller's own interop socket must not be retried"
pass "the inherited interop socket is not tried twice"

run_case STUB_FAIL=1 STUB_GOOD_SOCKET="$RUN/900_interop" -- "$ARTIFACT" --reopen
assert_equals "|$ARTIFACT --reopen
$RUN/900_interop|$ARTIFACT --reopen" "$(cat "$LOG")" "--reopen must reach every attempt"
pass "--reopen is passed to every attempt"

run_case STUB_FAIL=1 STUB_STATUS=user-ended -- "$ARTIFACT"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "a refused user-ended session must not be retried"
assert_equals "browser-launch: skipped" "$(tail -n 1 "$TMP_ROOT/out.$N")" "user-ended verdict"
pass "a session the captain ended reports skipped and is never retried"

run_case STUB_FAIL=1 STUB_RC=3 -- "$ARTIFACT"
expect_code 3 "$RC" "lavish-axi's own failure"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "a failed open must not be retried"
assert_not_contains "$OUT" "browser-launch:" "a failed open prints no launch verdict"
pass "a failed open keeps lavish-axi's exit status and prints no verdict"

run_case STUB_FAIL=1 FM_LAVISH_INTEROP_DIR="$TMP_ROOT/no-such-dir" -- "$ARTIFACT"
assert_equals 1 "$(wc -l < "$LOG" | tr -d ' ')" "without interop sockets there is nothing to retry"
assert_equals "browser-launch: failed https://host.example:8387/session/abc123" "$(tail -n 1 "$TMP_ROOT/out.$N")" "no-socket verdict"
pass "a host without WSL interop sockets reports failed after one attempt"

run_case -- "$TMP_ROOT/missing.html"
expect_code 1 "$RC" "missing artifact"
assert_equals 0 "$(wc -l < "$LOG" | tr -d ' ')" "a missing artifact must not reach lavish-axi"
run_case -- "$ARTIFACT" --bogus
expect_code 2 "$RC" "unknown option"
pass "a missing artifact or unknown option is refused before lavish-axi runs"

# Page artifacts must live under the home's persistent data/ directory: a page
# in shared /tmp, a scratchpad, a pool worktree or a .lavish/ directory is lost
# on reboot or slot return.
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/task" "$TMP_ROOT/pool/.treehouse/slot/.lavish" "$TMP_ROOT/agent/scratchpad"
printf '<!doctype html><title>t</title>\n' > "$HOME_DIR/data/task/page.html"
printf '<!doctype html><title>t</title>\n' > "$TMP_ROOT/pool/.treehouse/slot/.lavish/page.html"
printf '<!doctype html><title>t</title>\n' > "$TMP_ROOT/agent/scratchpad/page.html"
ln -s "$TMP_ROOT/agent/scratchpad/page.html" "$HOME_DIR/data/task/link.html"

run_case FM_LAVISH_ALLOW_EPHEMERAL= FM_HOME="$HOME_DIR" -- "$HOME_DIR/data/task/page.html"
expect_code 0 "$RC" "an artifact under the home's data/ opens"
assert_equals "browser-launch: ok" "$(tail -n 1 "$TMP_ROOT/out.$N")" "persistent artifact verdict"
for bad in "$TMP_ROOT/pool/.treehouse/slot/.lavish/page.html" "$TMP_ROOT/agent/scratchpad/page.html"; do
  run_case FM_LAVISH_ALLOW_EPHEMERAL= FM_HOME="$HOME_DIR" -- "$bad"
  expect_code 1 "$RC" "an ephemeral artifact is refused: $bad"
  assert_equals 0 "$(wc -l < "$LOG" | tr -d ' ')" "a refused artifact must not reach lavish-axi"
  assert_contains "$ERR" "$HOME_DIR/data/" "the refusal must name the persistent directory"
done
run_case FM_LAVISH_ALLOW_EPHEMERAL= FM_HOME="$HOME_DIR/none" -- "$ARTIFACT"
expect_code 1 "$RC" "an artifact in the shared temp directory is refused"
run_case FM_LAVISH_ALLOW_EPHEMERAL= FM_HOME="$HOME_DIR" -- "$HOME_DIR/data/task/link.html"
expect_code 1 "$RC" "a data/ symlink to an ephemeral file is refused by its physical path"
pass "only persistent data/ artifacts open; temp, scratchpad, pool and .lavish pages are refused"
