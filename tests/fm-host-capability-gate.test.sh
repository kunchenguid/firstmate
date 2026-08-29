#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for the host-capability gate (tests/host-capability-gate.sh)
# and the STRUCTURAL GUARD over its skip set (tests/host-capabilities.tsv).
#
# The guard exists because a skip set is the one kind of test change that makes
# the suite look better while covering less. This program has already paid for
# that once: a unit gated on `command -v pi` skipped silently in CI, and two
# mutations of the code it guarded passed green. So the set of host-coupled
# units is pinned three ways here - registry versus real call sites, an exact
# literal count, and the required call shape - and any drift is a red diff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/tests/host-capability-gate.sh"
REGISTRY="$ROOT/tests/host-capabilities.tsv"
CI="$ROOT/.github/workflows/ci.yml"
RUN_SH="$ROOT/tests/run.sh"

# The exact number of host-coupled units in the sealed suite. Adding or removing
# one is a deliberate act that must move this literal in the same diff, where a
# reviewer sees it.
EXPECTED_GATED_UNITS=52

# Static scan of every real call site: file, capability, label, and the tail
# that decides what happens on a skip.
call_sites() {
  grep -n '^[[:space:]]*fm_require_host_capability ' "$ROOT"/tests/*.sh \
    | sed "s#^$ROOT/##"
}

test_registry_and_call_sites_are_the_same_set() {
  local tmp declared observed
  tmp=$(fm_test_tmproot fm-host-capability-registry)
  declared="$tmp/declared.txt"
  observed="$tmp/observed.txt"

  awk -F '\t' '$1 == "unit" { print $2 "\t" $3 "\t" $4 }' "$REGISTRY" \
    | LC_ALL=C sort > "$declared"
  [ -s "$declared" ] || fail "the host-capability registry declares no gated units"

  call_sites | python3 -c '
import re, sys
for raw in sys.stdin:
    path, _, rest = raw.partition(":")
    _, _, rest = rest.partition(":")
    match = re.match(
        r"""\s*fm_require_host_capability\s+([A-Za-z0-9-]+)\s+"([^"]+)"\s*\|\|\s*(return|exit)\s+0\s*$""",
        rest.rstrip("\n"),
    )
    if not match:
        sys.stderr.write("malformed call site: %s: %s" % (path, rest))
        raise SystemExit(3)
    print("%s\t%s\t%s" % (path, match.group(2), match.group(1)))
' | LC_ALL=C sort > "$observed" \
    || fail "a fm_require_host_capability call site is not the required shape: fm_require_host_capability <capability> \"<label>\" || return 0"

  cmp -s "$declared" "$observed" || {
    printf '# --- declared in tests/host-capabilities.tsv, not gated in a test ---\n' >&2
    comm -23 "$declared" "$observed" >&2
    printf '# --- gated in a test, not declared in tests/host-capabilities.tsv ---\n' >&2
    comm -13 "$declared" "$observed" >&2
    fail "the host-coupled unit registry and the real gate call sites are not the same set"
  }
  pass "every gated unit is declared and every declared unit is really gated"
}

test_gated_unit_count_is_pinned_to_a_literal() {
  local declared
  declared=$(awk -F '\t' '$1 == "unit"' "$REGISTRY" | wc -l | tr -d ' ')
  [ "$declared" -eq "$EXPECTED_GATED_UNITS" ] \
    || fail "the host-coupled skip set is $declared units, not the pinned $EXPECTED_GATED_UNITS; move the literal in the same diff that moves the set"
  pass "the host-coupled skip set is pinned at exactly $EXPECTED_GATED_UNITS units"
}

test_every_referenced_capability_is_defined_once() {
  local tmp defined used missing
  tmp=$(fm_test_tmproot fm-host-capability-defs)
  defined="$tmp/defined.txt"
  used="$tmp/used.txt"
  awk -F '\t' '$1 == "capability" { print $2 }' "$REGISTRY" | LC_ALL=C sort > "$defined"
  [ "$(LC_ALL=C sort "$defined" | uniq -d | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "a capability is defined more than once in tests/host-capabilities.tsv"
  awk -F '\t' '$1 == "unit" { print $4 }' "$REGISTRY" | LC_ALL=C sort -u > "$used"
  missing=$(comm -13 "$defined" "$used")
  [ -z "$missing" ] || fail "units reference undefined capabilities: $missing"
  # Every definition must carry platforms and a description; the skip line reads
  # them out loud, and an empty one produces an unexplained skip.
  local incomplete
  incomplete=$(awk -F '\t' '$1 == "capability" && ($3 == "" || $4 == "") { print $2 }' "$REGISTRY")
  [ -z "$incomplete" ] || fail "capabilities have no platforms or no description: $incomplete"
  pass "every referenced capability is defined exactly once with platforms and a description"
}

# --- behavior: the gate itself ----------------------------------------------

drive_gate() { # <platform> <declaration> <capability> <label>
  local platform=$1 declaration=$2 capability=$3 label=$4 tmp fakebin
  tmp=$(fm_test_tmproot fm-host-capability-drive)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -s ] && { printf '%s\n' "$platform"; exit 0; }
exec /usr/bin/uname "\$@"
SH
  chmod +x "$fakebin/uname"
  PATH="$fakebin:$PATH" FM_TEST_HOST_CAPABILITIES_ABSENT="$declaration" \
    FM_TEST_CURRENT_TEST=tests/fm-host-capability-gate.test.sh \
    bash -c '
      set -u
      . "$1"
      if fm_require_host_capability "$2" "$3"; then
        printf "GATE_RAN\n"
      else
        printf "GATE_SKIPPED\n"
      fi
    ' _ "$GATE" "$capability" "$label" 2>&1
}

test_declared_absence_skips_loudly_off_darwin() {
  local out status=0
  out=$(drive_gate Linux real-tmux-server real-tmux-server whole-file) || status=$?
  [ "$status" -eq 0 ] || fail "the gate did not exit cleanly on a declared absence: $out"
  assert_contains "$out" "GATE_SKIPPED" "a declared-absent capability did not skip its unit"
  assert_contains "$out" "FM_HOST_CAPABILITY_SKIP" "the skip carried no machine-greppable marker"
  assert_contains "$out" "requires host capability 'real-tmux-server'" \
    "the skip did not name the capability"
  assert_contains "$out" "tmux server" "the skip did not say what the capability is"
  assert_contains "$out" "declared it absent by name in FM_TEST_HOST_CAPABILITIES_ABSENT" \
    "the skip did not say why the capability was unavailable"
  pass "a declared absence skips the unit loudly, naming the capability and the reason"
}

test_undeclared_capability_runs_the_unit() {
  local out
  out=$(drive_gate Linux "" real-tmux-server whole-file)
  assert_contains "$out" "GATE_RAN" "the gate skipped a unit on a host that declared nothing absent"
  assert_not_contains "$out" "FM_HOST_CAPABILITY_SKIP" "a running unit still printed a skip line"

  # A declaration of some OTHER capability must not touch this one, and the skip
  # it does produce must describe the capability that was asked for.
  out=$(drive_gate Linux system-openat-binding real-tmux-server whole-file)
  assert_contains "$out" "GATE_RAN" "declaring one capability absent skipped a different one"
  # The requested capability is deliberately NOT last in the declaration: the
  # gate must describe the capability that was asked for, not whichever name it
  # happened to look up most recently while validating the declaration.
  out=$(drive_gate Linux "real-tmux-server,system-openat-binding" real-tmux-server whole-file)
  assert_contains "$out" "GATE_SKIPPED" "a capability named in a multi-name declaration still ran"
  assert_contains "$out" "requires host capability 'real-tmux-server' (a host that can start a real tmux server" \
    "the skip described some other declared capability instead of the one asked for"
  pass "a host that declares nothing runs the unit, and a declaration only affects the capabilities it names"
}

test_darwin_may_not_declare_any_capability_absent() {
  local out status=0
  out=$(drive_gate Darwin real-tmux-server real-tmux-server whole-file) || status=$?
  [ "$status" -eq 97 ] \
    || fail "Darwin accepted a host-capability absence declaration (status $status): $out"
  assert_contains "$out" "macOS always runs the host-coupled units" \
    "the Darwin refusal did not explain itself"
  assert_not_contains "$out" "GATE_SKIPPED" "Darwin skipped a host-coupled unit"
  pass "a Darwin host cannot declare a capability absent, so macOS coverage cannot be switched off"
}

test_unsupported_platform_skips_without_any_declaration() {
  local out
  out=$(drive_gate Darwin "" passwordless-root-escalation linux_systemd_drop_integration)
  assert_contains "$out" "GATE_SKIPPED" "a Linux-only capability ran on Darwin"
  assert_contains "$out" "this platform (Darwin) cannot provide it" \
    "the platform skip did not name the platform"
  pass "a capability no platform-native host can provide skips on that platform"
}

test_unknown_capability_names_are_refused_not_skipped() {
  local out status=0
  out=$(drive_gate Linux "" not-a-real-capability whole-file) || status=$?
  [ "$status" -eq 97 ] || fail "an unknown capability did not refuse (status $status): $out"
  assert_contains "$out" "unknown capability 'not-a-real-capability'" \
    "the refusal did not name the unknown capability"
  assert_not_contains "$out" "GATE_SKIPPED" "an unknown capability silently skipped its unit"
  assert_not_contains "$out" "GATE_RAN" "an unknown capability silently ran its unit"

  status=0
  out=$(drive_gate Linux typo-capability real-tmux-server whole-file) || status=$?
  [ "$status" -eq 97 ] || fail "a misspelled declaration did not refuse (status $status): $out"
  assert_contains "$out" "unknown capability 'typo-capability'" \
    "the refusal did not name the misspelled declaration"
  pass "unknown capability names refuse the run instead of skipping or passing"
}

# --- behavior: the wiring around the gate ------------------------------------

test_suite_runner_announces_a_reduced_run() {
  assert_grep 'FM_HOST_CAPABILITY_DECLARATION absent=' "$RUN_SH" \
    "tests/run.sh does not announce a declared host-capability absence before running"
  pass "the suite runner prints the declaration once per invocation"
}

test_ci_never_declares_a_capability_absent() {
  assert_no_grep 'FM_TEST_HOST_CAPABILITIES_ABSENT' "$CI" \
    "CI declares a host capability absent, which would silently drop coverage from the required checks"
  pass "CI declares nothing absent, so every host-coupled unit still runs there"
}

test_registry_and_call_sites_are_the_same_set
test_gated_unit_count_is_pinned_to_a_literal
test_every_referenced_capability_is_defined_once
test_declared_absence_skips_loudly_off_darwin
test_undeclared_capability_runs_the_unit
test_darwin_may_not_declare_any_capability_absent
test_unsupported_platform_skips_without_any_declaration
test_unknown_capability_names_are_refused_not_skipped
test_suite_runner_announces_a_reduced_run
test_ci_never_declares_a_capability_absent
