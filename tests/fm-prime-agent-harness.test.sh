#!/usr/bin/env bash
# Behavior tests for Prime Agent registration and Pi-family harness detection.
#
# Prime Agent exports the same PI_CODING_AGENT marker as Pi, so the tests drive
# both sides of that boundary and preserve Pi and Claude detection when Prime
# Agent markers are absent or stale. They also pin the precedence floor: the
# Prime Agent split sits below the cursor, gemini, rovo, and omp marker arms, and
# above the CLAUDECODE fast path. grok is deliberately out of scope - GROK_AGENT=1
# is tested after the unmarked Pi result already, so grok started inside any
# Pi-family session has always resolved to that family, and reordering it is
# broader than this slice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-prime-agent-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# bin/fm-harness.sh reads verified ENV markers before ancestry, and a suite run
# from inside one of those harnesses inherits its marker, which outranks
# everything these cases set up: with an ambient CURSOR_AGENT=1 every assertion
# below would resolve "cursor". Drop every foreign marker so the asserted
# verdict does not depend on which harness launched the suite; each case states
# the marker it means to test.
scrubbed() {  # <env assignment>... <command> [arg]...
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS -u PI_CODING_AGENT \
    -u PRIME_AGENT_CODING_AGENT_DIR -u PRIME_AGENT_INTERNAL_DAEMON_WORKER \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
    -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
    "$@"
}

detect() {  # <env assignment>...
  scrubbed "$@" "$HARNESS"
}

# A process whose kernel-recorded identity is the bare name under test: a
# SYMLINK to the system shell, never a copy (a copied platform binary fails
# macOS code signing), which is what `ps -o comm=` reports on both platforms.
# Every `-c` body ends in a no-op so bash does not exec-optimize the single
# command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in prime-agent omp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# A ps shim whose only named ancestor is <comm>: pid 4242 answers with that
# name, every other pid answers as a plain shell parented to it, and 4242's own
# parent is pid 1, so the walk terminates. Fabricating the chain keeps the
# ancestry cases independent of whatever really launched the suite.
make_ps_ancestor() {  # <dir> <comm> -> echoes <bindir>
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "\$@"; do
  [ "\$prev" = -o ] && field=\$arg
  [ "\$prev" = -p ] && pid=\$arg
  prev=\$arg
done
case "\$field:\$pid" in
  comm=:4242) printf '/opt/prime-agent/bin/%s\n' '$comm' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s' "$fakebin"
}

test_detection_splits_the_pi_family() {
  local out psbin

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent)
  [ "$out" = prime-agent ] || fail "the Prime Agent launch marker selected '$out'"

  # Prime Agent's own values are session-wide and inherited, so they are not
  # detection evidence in this slice: an unmarked Prime Agent session stays
  # Pi-family exactly as it did before the adapter was registered.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/home/x/.prime/agent)
  [ "$out" = pi ] || fail "an ambient Prime Agent tool value selected '$out', not pi"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = pi ] || fail "an ambient Prime Agent daemon value selected '$out', not pi"

  # The same Pi-family marker without a Prime Agent signal must remain Pi.
  out=$(detect PI_CODING_AGENT=true)
  [ "$out" = pi ] || fail "unmarked Pi detection changed to '$out'"

  # An explicit Pi identity wins over stale Prime Agent values inherited from a
  # shared supervisor environment.
  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = pi ] || fail "explicit Pi detection was relabelled '$out'"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = pi-signed ] || fail "explicit Pi-signed detection was relabelled '$out'"

  # With CLAUDECODE also present the marker is ambiguous in both directions, so
  # the ancestry decides. A resident Prime Agent worker inherits CLAUDECODE from
  # its supervisor and has prime-agent in its chain; a claude pane opened by hand
  # inside a Prime Agent session inherits the same marker and does not. The
  # decoy ancestor is named prime-agent-helper, so the anchored match is what
  # keeps that pane claude rather than a prefix match on the chain.
  psbin=$(make_ps_ancestor "$TMP_ROOT/prime-worker" prime-agent)
  out=$(detect PATH="$psbin:$BASE_PATH" PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent CLAUDECODE=1)
  [ "$out" = prime-agent ] || fail "Prime Agent detection lost to inherited Claude marker"

  psbin=$(make_ps_ancestor "$TMP_ROOT/claude-pane" prime-agent-helper)
  out=$(detect PATH="$psbin:$BASE_PATH" PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent CLAUDECODE=1)
  [ "$out" = claude ] || fail "a leaked Prime Agent launch marker relabelled a claude pane '$out'"

  out=$(detect PATH="$psbin:$BASE_PATH" PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x \
    PRIME_AGENT_INTERNAL_DAEMON_WORKER=1 CLAUDECODE=1)
  [ "$out" = claude ] || fail "an inherited Prime Agent environment relabelled a claude pane '$out'"

  # Prime-specific values are ignored without the Pi-family marker.
  out=$(detect CLAUDECODE=1 PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = claude ] || fail "a stale Prime Agent marker changed Claude detection to '$out'"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=)
  [ "$out" = pi ] || fail "an empty launch marker changed Pi detection to '$out'"

  pass "Prime Agent detection splits its Pi-family marker without relabelling Pi or Claude"
}

# cursor, gemini, and rovo do NOT scrub the environment they are started in, so
# one of them launched by hand inside a Prime Agent session carries the
# Pi-family and Prime Agent launch markers alongside its own. Their markers are
# tested above the Prime Agent split and must keep winning; the split itself
# outranks the CLAUDECODE fast path only.
test_cursor_gemini_and_rovo_outrank_the_prime_agent_split() {
  local out case_ expected marker
  for case_ in \
    cursor:CURSOR_AGENT=1 \
    cursor:CURSOR_INVOKED_AS=cursor-agent \
    gemini:GEMINI_CLI=1 \
    rovo:ATLASSIAN_AGENT_TYPE=rovo \
    rovo:ROVODEV_CLI=1; do
    expected=${case_%%:*}
    marker=${case_#*:}
    out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent "$marker")
    [ "$out" = "$expected" ] || fail "$marker inside a Prime Agent session detected '$out', not '$expected'"
  done
  pass "fm-harness: the cursor, gemini, and rovo markers outrank inherited Prime Agent markers"
}

# The launch marker is the only evidence. A real prime-agent ancestor carrying
# no marker resolves exactly as it did before the adapter was registered, and
# the ancestry walk is consulted only to corroborate the marker under an
# inherited CLAUDECODE.
test_ancestry_alone_does_not_select_prime_agent() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed PI_CODING_AGENT=true PATH="$bin:$BASE_PATH" \
    "$bin/prime-agent" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi ] || fail "a markerless prime-agent ancestor detected '$out', not pi"

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed CLAUDECODE=1 PATH="$bin:$BASE_PATH" \
    "$bin/prime-agent" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a claude pane under a prime-agent ancestor detected '$out', not claude"

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent PATH="$bin:$BASE_PATH" \
    "$bin/prime-agent" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = prime-agent ] || fail "the launch marker under a prime-agent ancestor detected '$out'"

  # omp needs a real omp ancestor for its own marker, so the precedence check
  # that env markers alone cannot make belongs here.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(scrubbed FM_OMP_HARNESS=omp PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent \
    PATH="$bin:$BASE_PATH" "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "an omp session started inside a Prime Agent session detected '$out', not omp"

  pass "fm-harness: a prime-agent ancestor alone never claims the identity; the launch marker does"
}

# A spawnable worker must also be controllable: fm-control refuses every verb on
# a harness with no verified mechanics, so the tables are asserted here against
# Prime Agent's verified facts rather than left to the launch slice.
test_prime_agent_control_table() {
  local wiring
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported prime-agent || fail "prime-agent is not a supported control harness"
  [ "$(fm_control_harness_family prime-agent)" = prime-agent ] || fail "prime-agent harness family lookup failed"
  [ "$(fm_control_interrupt_key prime-agent)" = Escape ] || fail "prime-agent interrupt key is not Escape"
  [ "$(fm_control_interrupt_repeat prime-agent)" = 1 ] || fail "prime-agent interrupt repeat is not 1"
  fm_control_interrupt_clear_key prime-agent >/dev/null \
    || fail "prime-agent has no verified interrupt clear-key entry"
  [ -z "$(fm_control_interrupt_clear_key prime-agent)" ] || fail "prime-agent should need no interrupt clear key"
  [ "$(fm_control_interrupt_ack_source prime-agent)" = none ] || fail "prime-agent interrupt ack source is not none"
  [ "$(fm_control_exit_command prime-agent)" = /quit ] || fail "prime-agent exit command is not /quit"
  fm_control_harness_supports_kind prime-agent ship || fail "prime-agent should support ship tasks"
  fm_control_harness_supports_kind prime-agent scout || fail "prime-agent should support scout tasks"
  if fm_control_harness_supports_kind prime-agent secondmate; then
    fail "prime-agent should never support secondmate tasks"
  fi
  wiring=$(fm_control_harness_wiring_paths prime-agent /wt /state t1)
  [ "$wiring" = "/state/t1.prime-ext.ts" ] \
    || fail "prime-agent wiring paths did not list its turn-end extension, got '$wiring'"
  pass "fm-control-lib: prime-agent's lifecycle table matches its verified facts"
}

test_detection_splits_the_pi_family
test_cursor_gemini_and_rovo_outrank_the_prime_agent_split
test_ancestry_alone_does_not_select_prime_agent
test_prime_agent_control_table
