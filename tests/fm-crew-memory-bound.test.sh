#!/usr/bin/env bash
# Behavioral coverage for the enforced crewmate memory bound: config parsing,
# the fail-closed spawn refusal, and - the regression this exists for - proof
# that a crewmate's descendant processes actually land inside the bounded
# cgroup and that exceeding the bound kills the offender rather than the host.
#
# The defect being regressed is precisely a cgroup that existed and enforced a
# limit on the wrong processes, so every membership assertion here reads the
# cgroup a real descendant reports for itself rather than trusting that the
# cgroup was created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-memory-bound)
BOUND="$ROOT/bin/fm-crew-memory-bound.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

CONFIG_DIR="$TMP_ROOT/config"
mkdir -p "$CONFIG_DIR"

# run_bound <bound-value> <args...>: run the command with an explicit bound and
# an isolated config dir, capturing output and exit code into OUT/RC.
OUT=""
RC=0
run_bound() {
  local bound=$1
  shift
  RC=0
  OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="$bound" "$BOUND" "$@" 2>&1) || RC=$?
}

# --- configuration contract -------------------------------------------------

RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" read 2>&1) || RC=$?
expect_code 3 "$RC" "an absent config/crew-memory-bound reports unconfigured"
[ -z "$OUT" ] || fail "unconfigured read must print nothing, got: $OUT"
pass "an absent bound reports unconfigured rather than inventing a default"

run_bound "8G" read
expect_code 0 "$RC" "a MemoryMax-only bound is valid"
assert_contains "$OUT" "max=8G" "MemoryMax is reported"
assert_not_contains "$OUT" "high=" "no MemoryHigh is reported when none is configured"
pass "a MemoryMax-only bound parses"

run_bound "8G 6G" read
expect_code 0 "$RC" "a MemoryMax/MemoryHigh bound is valid"
assert_contains "$OUT" "max=8G" "MemoryMax is reported"
assert_contains "$OUT" "high=6G" "MemoryHigh is reported"
pass "a MemoryMax/MemoryHigh bound parses"

for bad in "8Q" "0G" "-4G" "4G 8G" "8G 6G 4G" "eight"; do
  run_bound "$bad" read
  [ "$RC" = 1 ] || fail "bound '$bad' must be a hard error, got exit $RC"
done
pass "malformed, zero, oversized-high, and extra-token bounds are hard errors"

: > "$CONFIG_DIR/crew-memory-bound"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" read 2>&1) || RC=$?
expect_code 1 "$RC" "an empty config file is a hard error, not an absent bound"
rm -f "$CONFIG_DIR/crew-memory-bound"
pass "an empty bound file is a hard error rather than a silent no-bound"

printf '4G\n8G\n' > "$CONFIG_DIR/crew-memory-bound"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" read 2>&1) || RC=$?
expect_code 1 "$RC" "a multi-line config file is a hard error"
rm -f "$CONFIG_DIR/crew-memory-bound"

printf '8G\n' > "$TMP_ROOT/elsewhere"
ln -s "$TMP_ROOT/elsewhere" "$CONFIG_DIR/crew-memory-bound"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" read 2>&1) || RC=$?
expect_code 1 "$RC" "a symlinked config file is a hard error"
rm -f "$CONFIG_DIR/crew-memory-bound"
pass "unsafe config files are rejected instead of silently followed"

printf '8G 6G\n' > "$CONFIG_DIR/crew-memory-bound"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" read 2>&1) || RC=$?
expect_code 0 "$RC" "a well-formed config file is read"
assert_contains "$OUT" "max=8G" "the file's MemoryMax is used"
assert_contains "$OUT" "source=config/crew-memory-bound" "the file is named as the source"
rm -f "$CONFIG_DIR/crew-memory-bound"
pass "a well-formed config file drives the bound"

# --- fail closed ------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# A PATH that carries the ordinary text utilities but no systemd-run at all,
# standing in for a host with no systemd user manager (a container, macOS).
NOSYSTEMD="$TMP_ROOT/nosystemd"
mkdir -p "$NOSYSTEMD"
for tool in bash env sed wc tr date cat cut grep; do
  tool_path=$(command -v "$tool") || fail "test host lacks $tool"
  ln -sf "$tool_path" "$NOSYSTEMD/$tool"
done

RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G" \
  PATH="$NOSYSTEMD" "$BOUND" preflight 2>&1) || RC=$?
expect_code 1 "$RC" "a configured bound with no systemd-run must fail, not degrade"
assert_contains "$OUT" "systemd-run" "the refusal names the missing mechanism"
assert_not_contains "$OUT" "enforced=proven" "an unenforceable bound is never claimed as proven"
pass "a configured bound with no way to enforce it refuses instead of running unbounded"

# systemd-run present but unable to create the scope is the same refusal: the
# bound is only ever claimed after it has been read back from a live cgroup.
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
echo "Failed to connect to bus" >&2
exit 1
SH
chmod +x "$FAKEBIN/systemd-run"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G" \
  PATH="$FAKEBIN:$NOSYSTEMD" "$BOUND" preflight 2>&1) || RC=$?
expect_code 1 "$RC" "a scope that cannot be created must fail the preflight"
assert_contains "$OUT" "could not create a bounded scope" "the refusal reports the scope failure"
pass "a systemd-run that cannot create the scope refuses instead of degrading"

# A systemd-run that reports success but leaves the process in the root cgroup
# is the original defect in miniature, and must still refuse.
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '/\n'
printf 'max\n'
exit 0
SH
chmod +x "$FAKEBIN/systemd-run"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G" \
  PATH="$FAKEBIN:$NOSYSTEMD" "$BOUND" preflight 2>&1) || RC=$?
expect_code 1 "$RC" "a scope whose processes stay in the root cgroup must fail"
assert_contains "$OUT" "root cgroup" "the refusal names the root-cgroup escape"
pass "a scope that reports success but leaves processes in the root cgroup is refused"

# The preflight must prove EVERY limit it sets, not just memory.max. systemd
# starts a scope even when a property write to the kernel fails, so a host with
# the memory controller delegated but no swap accounting would otherwise come up
# with memory.max enforced, swap unbounded, and the mechanism reporting
# "enforced=proven" - and a runaway build would page the host into thrashing
# instead of dying, which is precisely what MemorySwapMax=0 exists to prevent.
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '/user.slice/fake.scope\n'
printf '8589934592\n'
printf 'max\n'
printf 'max\n'
exit 0
SH
chmod +x "$FAKEBIN/systemd-run"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G" \
  PATH="$FAKEBIN:$NOSYSTEMD" "$BOUND" preflight 2>&1) || RC=$?
expect_code 1 "$RC" "a scope whose swap denial never reached the kernel must fail the preflight"
assert_contains "$OUT" "memory.swap.max" "the refusal names the limit that was not enforced"
assert_not_contains "$OUT" "enforced=proven" "a partially enforced bound is never claimed as proven"
pass "a scope enforcing memory.max but not the swap denial is refused rather than proven"

# The same for the soft ceiling: a configured MemoryHigh that did not land is a
# bound the host does not actually hold.
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '/user.slice/fake.scope\n'
printf '8589934592\n'
printf 'max\n'
printf '0\n'
exit 0
SH
chmod +x "$FAKEBIN/systemd-run"
RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G 6G" \
  PATH="$FAKEBIN:$NOSYSTEMD" "$BOUND" preflight 2>&1) || RC=$?
expect_code 1 "$RC" "a configured MemoryHigh that did not land must fail the preflight"
assert_contains "$OUT" "memory.high" "the refusal names the soft ceiling that was not enforced"
pass "a configured MemoryHigh is proven from the kernel too, not assumed from the flag"
rm -f "$FAKEBIN/systemd-run"

RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" wrap fm-x 'claude -p hi' 2>&1) || RC=$?
expect_code 3 "$RC" "wrap on an unconfigured home reports unconfigured"
[ -z "$OUT" ] || fail "wrap must print no launch line when unconfigured, got: $OUT"
pass "wrap never emits a launch line it cannot bind"

# A bound launch runs under `bash -c`, which only replaces itself with the
# harness for one simple command. Anything else leaves the pane reporting a
# shell, which the tmux backend reads as a DEAD agent - so recovery would
# relaunch a crewmate that is still working. Those shapes must be refused, not
# bound. Every built-in launch template is a simple command, so the shapes below
# stand in for the raw-launch escape hatch.
# shellcheck disable=SC2016  # these are launch strings under test, not this shell's expansions
for good in \
  'claude -p hi' \
  'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --model opus "$(/x/op-input.sh encode launch-brief < /x/brief)"' \
  'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(/x/op-input.sh encode launch-brief < /x/brief)"' \
  'codex -c "notify=[\"bash\",\"-c\",\"touch /x/t\"]" "$(/x/op-input.sh encode launch-brief < /x/brief)"'; do
  RC=0
  OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" check-launch "$good" 2>&1) || RC=$?
  expect_code 0 "$RC" "a simple-command launch must remain bindable: $good"$'\n'"$OUT"
done
pass "the built-in launch shapes - env prefixes, quoted command substitution, redirection inside it - stay bindable"

for bad in \
  'claude -p hi > /tmp/log' \
  'claude -p hi | tee /tmp/log' \
  'setup && claude -p hi' \
  'setup; claude -p hi' \
  '(claude -p hi)' \
  'claude -p hi &' \
  'claude -p "unterminated'; do
  RC=0
  OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$BOUND" check-launch "$bad" 2>&1) || RC=$?
  expect_code 1 "$RC" "a launch bash would fork for must be refused: $bad"
  assert_contains "$OUT" "cannot be bound" "the refusal says the launch cannot be bound: $bad"
done
pass "pipelines, lists, redirections, subshells, and unbalanced quoting are refused rather than bound"

RC=0
OUT=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="8G" \
  "$BOUND" wrap fm-x 'claude -p hi | tee /tmp/log' 2>&1) || RC=$?
expect_code 1 "$RC" "wrap must refuse a launch it cannot keep visible to supervision"
assert_not_contains "$OUT" "systemd-run" "no launch line is emitted for a refused shape"
pass "wrap enforces the same shape rule, so nothing reaches a pane that supervision would misread"

# The spawn-level refusal: fm-spawn must abort before creating any window when a
# bound is configured but unenforceable. tmux is faked so backend validation
# passes and the crew-memory preflight is the thing that stops the spawn.
fm_fake_exit0 "$FAKEBIN" tmux
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
echo "Failed to connect to bus" >&2
exit 1
SH
chmod +x "$FAKEBIN/systemd-run"
SPAWN_CONFIG="$TMP_ROOT/spawn-config"
mkdir -p "$SPAWN_CONFIG" "$TMP_ROOT/spawn-state" "$TMP_ROOT/spawn-data"
printf '8G\n' > "$SPAWN_CONFIG/crew-memory-bound"
RC=0
OUT=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$SPAWN_CONFIG" \
  FM_STATE_OVERRIDE="$TMP_ROOT/spawn-state" FM_DATA_OVERRIDE="$TMP_ROOT/spawn-data" \
  FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
  "$SPAWN" fm-bound-refusal "$TMP_ROOT" 2>&1) || RC=$?
[ "$RC" != 0 ] || fail "fm-spawn must refuse when a configured bound cannot be established"
assert_contains "$OUT" "refusing to spawn" "the spawn refusal is explicit"
assert_absent "$TMP_ROOT/spawn-state/fm-bound-refusal.meta" \
  "a refused spawn leaves no task metadata behind"
pass "fm-spawn refuses to launch a crewmate whose bound cannot be established"

# The bound covers what builds, not what supervises: a secondmate is a
# persistent idle-by-default supervisor that compiles nothing, and a ceiling
# sized for build lanes that killed its harness would take out a whole home. The
# same unenforceable bound must therefore not stop a secondmate spawn - whatever
# else that spawn does in this stub environment, it must not be refused for the
# crew memory bound.
RC=0
OUT=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$SPAWN_CONFIG" \
  FM_STATE_OVERRIDE="$TMP_ROOT/spawn-state" FM_DATA_OVERRIDE="$TMP_ROOT/spawn-data" \
  FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" \
  "$SPAWN" fm-bound-secondmate --secondmate "$TMP_ROOT" 2>&1) || RC=$?
assert_not_contains "$OUT" "refusing to spawn a crewmate whose builds would be unbounded" \
  "a secondmate spawn is never gated on the crewmate build bound"
pass "the bound applies to crewmates only, so an unenforceable bound never blocks a secondmate"

# --- enforced membership and enforcement ------------------------------------
#
# Everything below needs a live systemd user manager with a delegated memory
# controller. Where that is absent (CI containers, macOS) the mechanism cannot
# be exercised at all, so those checks report and stand down rather than
# passing vacuously.

systemd_user_usable() {
  command -v systemd-run >/dev/null 2>&1 || return 1
  systemd-run --user --scope --quiet --collect -p MemoryMax=64M \
    -- /bin/true >/dev/null 2>&1
}

if ! systemd_user_usable; then
  printf 'note: no usable systemd user manager; cgroup membership and kill checks stood down\n'
  printf 'ok - crew memory bound contract (cgroup checks unavailable on this host)\n'
  exit 0
fi

# The regression. A crewmate pane runs the harness, the harness forks a build,
# and that build forks compilers: the bound is worthless unless a GRANDCHILD of
# the launched line is inside it. Assert on the cgroup those descendants report
# for themselves, and fail loudly if any of them is in the root cgroup - the
# exact state that made the previous guardrail a fiction.
LAUNCH_LINE=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="512M 384M" \
  "$BOUND" wrap fm-membership \
  'bash -c '\''cat /proc/self/cgroup; bash -c "cat /proc/self/cgroup; sh -c \"cat /proc/self/cgroup\""'\''')
[ -n "$LAUNCH_LINE" ] || fail "wrap produced no launch line"

RC=0
OUT=$(eval "$LAUNCH_LINE" 2>&1) || RC=$?
expect_code 0 "$RC" "the bounded launch line runs"

DEPTHS=$(printf '%s\n' "$OUT" | grep -c '^0::/' || true)
[ "$DEPTHS" -eq 3 ] || fail "expected 3 descendant cgroup reports, got $DEPTHS"$'\n'"$OUT"

while IFS= read -r line; do
  case "$line" in
    0::/) fail "a descendant of the bounded launch landed in the ROOT cgroup - the bound covers nothing"$'\n'"$OUT" ;;
    0::/*fm-crew-fm-membership*) : ;;
    *) fail "a descendant landed outside the crew scope: $line"$'\n'"$OUT" ;;
  esac
done < <(printf '%s\n' "$OUT" | grep '^0::/')
pass "the launched process, its child, and its grandchild all land in the bounded cgroup"

# The bound must be the kernel's, not a claim: read memory.max and swap back out
# of the live cgroup rather than trusting the flags that were passed in.
# shellcheck disable=SC2016  # expands in the probed shell inside the scope
LIMITS=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="512M 384M" \
  "$BOUND" wrap fm-limits \
  'sh -c '\''p=$(cut -d: -f3 /proc/self/cgroup); cat /sys/fs/cgroup$p/memory.max /sys/fs/cgroup$p/memory.high /sys/fs/cgroup$p/memory.swap.max'\''')
RC=0
OUT=$(eval "$LIMITS" 2>&1) || RC=$?
expect_code 0 "$RC" "the limits probe runs"
# Compared line by line, not by substring: "0" is a substring of every byte count
# here, so a substring check on the swap line could never fail and the swap half
# of the guarantee - which is not a tunable - would have no coverage at all.
LIMIT_MAX=$(printf '%s\n' "$OUT" | sed -n '1p')
LIMIT_HIGH=$(printf '%s\n' "$OUT" | sed -n '2p')
LIMIT_SWAP=$(printf '%s\n' "$OUT" | sed -n '3p')
[ "$LIMIT_MAX" = 536870912 ] || fail "memory.max must be the configured 512M, got '$LIMIT_MAX'"$'\n'"$OUT"
[ "$LIMIT_HIGH" = 402653184 ] || fail "memory.high must be the configured 384M, got '$LIMIT_HIGH'"$'\n'"$OUT"
[ "$LIMIT_SWAP" = 0 ] || fail "memory.swap.max must be 0 so a runaway cannot page the host instead of dying, got '$LIMIT_SWAP'"$'\n'"$OUT"
pass "the kernel reports the configured limits, swap included, on the crew cgroup"

# Exceeding the bound must kill the offending build and leave the host alone. A
# sentinel started outside the scope stands in for the rest of the host: it must
# still be running once the allocator inside the scope is killed.
#
# Its margin is deliberately far longer than any plausible allocator runtime. The
# hog below grows a bash string, which is quadratic in copying and can take a
# long time on exactly the loaded build host this feature targets. A sentinel
# that could finish first would turn that into "the bound took the host with it",
# reporting a timing race as the feature's worst failure mode.
#
# It holds no test file descriptor and its timer pid is recorded, so the long
# margin costs nothing at teardown: an orphaned timer would otherwise keep this
# script's stdout open for its whole duration.
SENTINEL_OUT="$TMP_ROOT/sentinel"
SENTINEL_TIMER_PIDFILE="$TMP_ROOT/sentinel.timer"
( sleep 600 & printf '%s\n' "$!" > "$SENTINEL_TIMER_PIDFILE"; wait; printf 'alive\n' > "$SENTINEL_OUT" ) \
  </dev/null >/dev/null 2>&1 &
SENTINEL_PID=$!

cat > "$TMP_ROOT/hog.sh" <<'SH'
#!/usr/bin/env bash
# Touch every page so the cgroup charges it, well past the 128M bound.
chunk=$(printf 'x%.0s' $(seq 1 100000))
buf=""
for _ in $(seq 1 4000); do
  buf="$buf$chunk"
done
printf 'survived\n'
SH
chmod +x "$TMP_ROOT/hog.sh"

HOG_LINE=$(FM_CONFIG_OVERRIDE="$CONFIG_DIR" FM_CREW_MEMORY_BOUND="128M" \
  "$BOUND" wrap fm-kill "$TMP_ROOT/hog.sh")
RC=0
OUT=$(eval "$HOG_LINE" 2>&1) || RC=$?
[ "$RC" != 0 ] || fail "a build that exceeded its bound was allowed to finish"$'\n'"$OUT"
assert_not_contains "$OUT" "survived" "the over-bound build must not reach completion"
pass "a build that exceeds the bound is killed (exit $RC)"

kill -0 "$SENTINEL_PID" 2>/dev/null || fail "the out-of-scope sentinel died: the bound took the host with it"
# The sentinel goes first: its timer is what would write the completion marker,
# so reaping the timer before its parent would forge the very thing the marker
# below is meant to rule out.
kill "$SENTINEL_PID" 2>/dev/null || true
wait "$SENTINEL_PID" 2>/dev/null || true
kill "$(cat "$SENTINEL_TIMER_PIDFILE" 2>/dev/null)" 2>/dev/null || true
assert_absent "$SENTINEL_OUT" "sentinel should have been killed by the test, not completed"
pass "processes outside the bound survive the kill: the build dies, the host does not"
