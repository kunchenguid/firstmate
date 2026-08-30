#!/usr/bin/env bash
# tests/fm-backend-herdr-schema-probe.test.sh - regression guard for the
# `herdr api schema --json` capability probe in fm_backend_herdr_events_capable
# (bin/backends/herdr.sh).
#
# The probe searches a ~220KB schema for two capability markers. Written as
# `printf '%s' "$schema" | grep -Fq <marker>`, it printed
# `printf: write error: Broken pipe` on the watcher's stderr during ordinary
# arm cycles: `grep -q` exits at the first matching LINE and closes the pipe
# while printf still has most of the payload unwritten.
#
# Three preconditions have to hold together, which is why it read as
# intermittent rather than constant:
#   1. SIGPIPE is ignored in the calling environment, so the failed write is
#      reported as EPIPE instead of killing printf silently.
#   2. The payload exceeds the pipe buffer (64KB on macOS), so the writer is
#      still mid-write when grep leaves.
#   3. The payload is multi-line with the match on an early line, so grep can
#      short-circuit at all - a single-line payload of any size is drained
#      whole, and the marker's position in the real schema decides this.
#
# The fix is a herestring, which bash materializes as a temp file: there is no
# concurrent writer process left to receive SIGPIPE. The exit status was always
# correct (it is grep's, as the last command in the pipeline), so this is a
# stderr-noise regression, not a capability-verdict regression - the assertions
# below check both.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-schema-probe-tests)
mkdir -p "$TMP_ROOT"

# A schema fixture shaped like the hazard: multi-line, well past the pipe
# buffer, with both capability markers on the first line so grep short-circuits
# immediately and leaves the writer blocked with almost everything unwritten.
BIG_SCHEMA_FIXTURE="$TMP_ROOT/schema.json"
{
  printf '{"methods":["events.subscribe","pane.agent_status_changed"],"filler":[\n'
  seq 1 40000
  printf ']}\n'
} > "$BIG_SCHEMA_FIXTURE"

# make_schema_fakebin: a `herdr` stub answering only the two calls the
# capability probe makes - `status --json` (protocol 16, at
# FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL) and `api schema --json` (the large
# fixture above).
make_schema_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n' ;;
  "api schema") cat "${FM_FAKE_SCHEMA_FILE:?}" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# run_capable: call fm_backend_herdr_events_capable against the fixture under a
# shell that IGNORES SIGPIPE, reproducing the watcher's launch environment
# (precondition 1). Echoes stderr, then a final "rc=<n>" line.
run_capable() {  # <fakebin> -> stderr text plus a trailing rc= line
  PATH="$1:$PATH" FM_FAKE_SCHEMA_FILE="$BIG_SCHEMA_FIXTURE" \
    FM_BACKEND_HERDR_EVENT_READER=/nonexistent/reader \
    bash -c '
      trap "" PIPE
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_events_capable sess
      echo "rc=$?"
    ' "$ROOT" 2>&1
}

test_events_capable_silent_on_large_early_matching_schema() {
  local dir fb out
  dir="$TMP_ROOT/capable"; mkdir -p "$dir"
  fb=$(make_schema_fakebin "$dir")
  out=$(run_capable "$fb")
  assert_not_contains "$out" "Broken pipe" \
    "the schema capability probe must not write a broken-pipe error to the watcher's stderr"
  assert_contains "$out" "rc=0" \
    "the schema capability probe must still report a capable schema as capable"
  pass "fm_backend_herdr_events_capable: large early-matching schema probed without a broken-pipe write error"
}

# Positive control for the fixture itself. A regression test that cannot fail is
# worthless, so prove the fixture DOES expose the hazard through the old pipe
# form under the same conditions. grep short-circuit behavior is
# implementation-dependent (ugrep and BSD grep differ on when they stop
# reading), so a control that does not reproduce is reported rather than
# failed - the assertion above stays enforced either way.
test_pipe_form_control_reproduces_broken_pipe() {
  local out
  out=$( FM_FAKE_SCHEMA_FILE="$BIG_SCHEMA_FIXTURE" bash -c '
      trap "" PIPE
      schema=$(cat "$FM_FAKE_SCHEMA_FILE")
      printf "%s" "$schema" | grep -Fq "events.subscribe"
    ' 2>&1 )
  case "$out" in
    *"Broken pipe"*)
      pass "control: the old pipe form still reproduces the broken-pipe write error on this fixture" ;;
    *)
      pass "control: this grep drains the fixture instead of short-circuiting, so the pipe form cannot be exercised here (main assertion still enforced)" ;;
  esac
}

# Static guard, independent of the runtime control above: the probe's two marker
# searches must not reintroduce a pipe, on any grep implementation.
test_events_capable_probe_reads_schema_without_a_pipe() {
  local body
  # Code only: the function's own comment explains the hazard by naming the old
  # pipe form, which would otherwise trip the guard below.
  body=$(awk '/^fm_backend_herdr_events_capable\(\)/,/^}/' "$ROOT/bin/backends/herdr.sh" | grep -v '^[[:space:]]*#')
  [ -n "$body" ] || fail "could not locate fm_backend_herdr_events_capable in bin/backends/herdr.sh"
  assert_contains "$body" "events.subscribe" \
    "fm_backend_herdr_events_capable must still probe for the events.subscribe marker"
  assert_not_contains "$body" '| grep' \
    "fm_backend_herdr_events_capable must search the schema with a herestring, never a pipe (a pipe reintroduces the SIGPIPE race)"
  pass "fm_backend_herdr_events_capable: schema markers are searched without piping the payload"
}

test_events_capable_silent_on_large_early_matching_schema
test_pipe_form_control_reproduces_broken_pipe
test_events_capable_probe_reads_schema_without_a_pipe
