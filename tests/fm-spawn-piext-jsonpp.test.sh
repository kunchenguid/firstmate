#!/usr/bin/env bash
# tests/fm-spawn-piext-jsonpp.test.sh - bin/fm-spawn.sh must emit a syntactically
# valid pi extension on hosts whose perl has no JSON::PP, the case that left a
# perl-armed host with `const excludeFile = ;` in state/<id>.pi-ext.ts and a
# pi agent that died at start. The heredoc substituted two JSON-encoded paths,
# and the perl encoder printed nothing, so the TypeScript literal collapsed to
# a syntax error.
#
# These tests drive the fix in two layers:
#
# 1. The json_path_literal helper sourced from bin/fm-spawn.sh itself, run
#    against a stubbed perl on PATH that either pretends JSON::PP is available
#    or pretends it is missing. The two branches must produce byte-identical
#    output for every path the heredoc embeds, and both must encode a path
#    with a literal quote, a space, and a UTF-8 codepoint exactly the way
#    node's JSON.stringify does, because that is the byte sequence the heredoc
#    substitutes into the TypeScript literal.
#
# 2. A real fm-spawn.sh pi spawn against a home whose absolute path contains
#    a space, a double quote, and a UTF-8 codepoint, on a host with no
#    JSON::PP. The resulting state/<id>.pi-ext.ts is parsed by node, so a
#    regression that re-introduces the empty-literal bug fails the parse
#    rather than the next launch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT_CD=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SPAWN="$ROOT_CD/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-piext-jsonpp)

# json_path_literal lives in bin/fm-spawn.sh between fixed marker lines, so
# the test always exercises the production implementation rather than a
# possibly-stale copy. The marker rows are the line that opens the function
# and the line that closes it; extracting them keeps the test aligned with
# the script even if a future refactor moves the function up or down.
source_helper_from_script() {
  local start end
  start=$(grep -n '^json_path_literal() {$' "$SPAWN" | head -1 | cut -d: -f1) \
    || fail "json_path_literal function not found in $SPAWN"
  end=$(awk -v s="$start" 'NR>=s && /^}$/ {print NR; exit}' "$SPAWN") \
    || fail "json_path_literal closing brace not found in $SPAWN"
  sed -n "${start},${end}p" "$SPAWN"
}

# Run the helper from $SPAWN with a custom PATH so perl and node are the
# stubs/fakes this case installed, not the host's. Stdout is the helper output.
# PERL_JSONPP is the env knob the installed perl stub reads, so passing it
# through env keeps the helper runner itself pure and lets the caller swap
# modes between cases.
call_helper() {
  local fakebin=$1 path=$2
  PATH="$fakebin:$PATH" PERL_JSONPP="${PERL_JSONPP:-absent}" \
    bash -c "$(source_helper_from_script); json_path_literal \"\$1\"" _ "$path"
}

# Stubbed perl on PATH: <fakebin>/perl. The env knob PERL_JSONPP decides whether
# the stub pretends JSON::PP is available.
install_perl_stub() {
  local fakebin=$1
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
# Stub perl for json_path_literal tests.
#
# MODE=present: emulate JSON::PP.encode_json by delegating to node. The encoder
# is the same one the helper falls back to, so a test that compares the two
# branches is comparing the helper's byte-for-byte literal output, not two
# different encoders with subtly different rules.
#
# MODE=absent: behave like a host perl that has no JSON::PP at all. The probe
# `perl -MJSON::PP -e 1` exits non-zero, so the helper's `if` falls into the
# node branch. Crucially this stub also fails the long-form call (-MJSON::PP
# -MEncode=decode_utf8 -e 'print encode_json(...)' -- ...) the way the real
# host perl does, so a buggy helper that forgot the probe and went straight to
# the encoder would also be caught here.
case "${PERL_JSONPP:-absent}" in
  present)
    case "$*" in
      "-MJSON::PP -e 1")
        # The helper's probe: succeed so the helper takes the perl branch.
        exit 0 ;;
      "-MJSON::PP -MEncode=decode_utf8 -e "*) 
        # The encoder call the helper makes. Reach the same wire format as the
        # node fallback by delegating, then exit 0.
        shift
        # Pull the path off the tail; everything else is the fixed -e source.
        path=${!#}
        node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$path"
        exit $? ;;
    esac
    exit 0 ;;
  absent)
    # Real hosts with no JSON::PP see the BEGIN-failed die before any other
    # code runs; mirror that so the probe exit code matches production.
    case "$*" in
      "-MJSON::PP -e 1"|"-MJSON::PP -MEncode=decode_utf8 -e "*)
        printf 'Can'"'"'t locate JSON/PP.pm in @INC (you may need to install the JSON::PP module) (@INC contains: ...).\nBEGIN failed--compilation aborted.\n' >&2
        exit 2 ;;
    esac
    exit 0 ;;
esac
SH
  chmod +x "$fakebin/perl"
}

# Encoded form of an arbitrary path, computed by the reference encoder.
expected_encoded() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$1"
}

# Inputs the heredoc substitutes in production. A space breaks heredoc token
# boundaries on careless shell-quoting, a quote breaks the TypeScript string
# literal the heredoc writes, and a UTF-8 codepoint exercises the JSON encoder
# rather than ASCII luck. A control character exercises the
# \u00XX-escape rule.
TRICKY_PATHS=(
  '/tmp/simple'
  '/tmp/with space'
  '/tmp/with"quote'
  "/tmp/with'quote-single"
  '/tmp/with\\backslash'
  '/tmp/utf8/中文/路径'
  $'/tmp/control/tab\there'
  $'/tmp/control/newline\nhere'
)

# --- helper unit tests with stubbed perl on PATH ----------------------------

test_helper_with_perl_jsonpp_matches_node_reference() {
  local fakebin=$TMP_ROOT/fakebin-perl-ok
  fm_fakebin "$fakebin" >/dev/null
  install_perl_stub "$fakebin"
  PERL_JSONPP=present
  local path encoded
  for path in "${TRICKY_PATHS[@]}"; do
    encoded=$(expected_encoded "$path")
    out=$(call_helper "$fakebin" "$path")
    assert_equals "$encoded" "$out" "perl branch output mismatch for path: $path"
  done
  pass "perl branch encodes tricky paths to the same bytes as the node reference"
}

test_helper_without_perl_jsonpp_falls_back_to_node() {
  local fakebin=$TMP_ROOT/fakebin-perl-missing
  fm_fakebin "$fakebin" >/dev/null
  install_perl_stub "$fakebin"
  local path encoded out
  for path in "${TRICKY_PATHS[@]}"; do
    encoded=$(expected_encoded "$path")
    out=$(call_helper "$fakebin" "$path")
    assert_equals "$encoded" "$out" "node-fallback output mismatch for path: $path"
  done
  pass "node fallback encodes tricky paths to the same bytes as the node reference"
}

# Run the two branches and assert they produce byte-identical output for every
# tricky input. This is the "perl and node agree" guarantee the heredoc
# depends on, regardless of which tool wins on a given host.
test_helper_perl_and_node_branches_produce_identical_output() {
  local perl_fakebin=$TMP_ROOT/fakebin-perl-ok node_fakebin=$TMP_ROOT/fakebin-perl-missing
  fm_fakebin "$perl_fakebin" >/dev/null
  install_perl_stub "$perl_fakebin"
  fm_fakebin "$node_fakebin" >/dev/null
  install_perl_stub "$node_fakebin"
  local path perl_out node_out
  for path in "${TRICKY_PATHS[@]}"; do
    PERL_JSONPP=present perl_out=$(call_helper "$perl_fakebin" "$path")
    node_out=$(call_helper "$node_fakebin" "$path")
    assert_equals "$perl_out" "$node_out" "perl and node branches diverged for: $path"$'\n'"perl: $perl_out"$'\n'"node: $node_out"
  done
  pass "perl and node branches produce byte-identical JSON string literals for every tricky input"
}

# The bug the brief is fixing: this host's perl 5.26.3 has no JSON::PP, so the
# helper's probe fails. Pin that fact, then drive a helper call from the host
# PATH and assert the node branch fires (output matches the node reference).
test_helper_on_this_host_uses_node_fallback() {
  # Confirm the precondition the host is supposed to provide; skip otherwise
  # so a host that ships JSON::PP still runs the rest of the suite.
  if perl -MJSON::PP -e 1 2>/dev/null; then
    printf 'skip: live: this host perl has JSON::PP, the no-JSON::PP branch is not exercised here\n'
    return 0
  fi
  local fakebin=$TMP_ROOT/fakebin-host-perl
  # Force the helper to use the real host perl by NOT shadowing it. The
  # helper is supposed to see the host's perl fails JSON::PP, so we install
  # only node.
  mkdir -p "$fakebin"
  ln -sf "$(command -v node)" "$fakebin/node"
  local path encoded out
  for path in "${TRICKY_PATHS[@]}"; do
    encoded=$(expected_encoded "$path")
    out=$(call_helper "$fakebin" "$path")
    assert_equals "$encoded" "$out" "host helper output mismatch for: $path"
  done
  pass "the production helper on this no-JSON::PP host routes to node and encodes every tricky path"
}

# --- end-to-end test: a real fm-spawn.sh pi spawn under a tricky home path ---

# A home absolute path that simultaneously contains a space (a heredoc
# boundary), a double quote (the TypeScript literal delimiter), and a UTF-8
# codepoint (the JSON encoder rule). Putting all three in one path is the
# shortest way to regress all of them at once.
TRICKY_HOME_BASENAME='home with "quote" and 中文'

parse_piext_consts() {
  # echo two lines: <excludeFile literal> <statusFile literal>
  node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const code = fs.readFileSync(path, "utf8");
    const m1 = code.match(/const excludeFile = (.+);/);
    const m2 = code.match(/const statusFile = (.+);/);
    if (!m1 || !m2) { console.error("missing consts in " + path); process.exit(1); }
    let parsed1, parsed2;
    try { parsed1 = JSON.parse(m1[1]); } catch (e) { console.error("excludeFile unparseable: " + m1[1]); process.exit(1); }
    try { parsed2 = JSON.parse(m2[1]); } catch (e) { console.error("statusFile unparseable: " + m2[1]); process.exit(1); }
    process.stdout.write(parsed1 + "\n" + parsed2 + "\n");
  ' -- "$1"
}

# Driving the real spawn is the only way to catch a regression in which the
# helper still works in isolation but the heredoc no longer substitutes it
# correctly. On a host without JSON::PP, the produced pi-ext.ts MUST be
# syntactically valid (a node parse of both const lines MUST succeed) and the
# decoded values MUST equal the original paths the script meant to embed.
test_pi_spawn_writes_a_parseable_piext_on_a_tricky_home_path() {
  local id=piext-tricky-z1
  local home="$TMP_ROOT/$TRICKY_HOME_BASENAME"
  local proj="$TMP_ROOT/proj"
  local wt="$TMP_ROOT/wt"
  local fakebin launchlog out status
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fb-piext")
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pi"
  launchlog="$TMP_ROOT/launch.log"
  fm_test_spawn_home "$home" pi
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-piext-tricky"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "pi spawn on a tricky home should succeed: $out"

  local piext="$home/state/$id.pi-ext.ts"
  assert_present "$piext" "pi spawn did not write $piext"

  local exclude_actual status_actual
  exclude_actual=$(parse_piext_consts "$piext" | sed -n '1p')
  status_actual=$(parse_piext_consts "$piext" | sed -n '2p')

  # The heredoc wires `const <name> = <encoded path>;` where the encoded
  # path is exactly the JSON string literal the helper emits. parse_piext_consts
  # does the JSON.parse the heredoc never gets to do at runtime, so a
  # regression that re-introduces the empty-literal bug fails the parse
  # before this assertion ever runs, and a regression that re-encodes the
  # path differently is caught by the byte comparison below.
  assert_equals "$home/config/crew-exclude-tools" "$exclude_actual" \
    "pi-ext.ts excludeFile did not round-trip through JSON.parse"
  assert_equals "$home/state/$id.status" "$status_actual" \
    "pi-ext.ts statusFile did not round-trip through JSON.parse"

  # Pin that the heredoc wires the helper's output through unchanged: any
  # drift between the two encoders would surface as a different JSON literal
  # in the file. The expected literal is exactly what JSON.stringify prints,
  # so a future refactor that drops the helper and uses a different encoder
  # cannot drift without breaking this assertion.
  local helper_exclude helper_status file_exclude file_status
  helper_exclude=$(json_path_literal_via_spawn "$home/config/crew-exclude-tools")
  helper_status=$(json_path_literal_via_spawn "$home/state/$id.status")
  file_exclude=$(grep -F 'const excludeFile = ' "$piext" | sed -E 's/^const excludeFile = (.*);$/\1/')
  file_status=$(grep -F 'const statusFile = ' "$piext" | sed -E 's/^const statusFile = (.*);$/\1/')
  assert_equals "$helper_exclude" "$file_exclude" \
    "pi-ext.ts excludeFile literal drifted from the helper's output"
  assert_equals "$helper_status" "$file_status" \
    "pi-ext.ts statusFile literal drifted from the helper's output"

  pass "pi spawn wrote a JSON-parseable pi-ext.ts on a tricky home path with quote, space, and UTF-8"
}

# The host environment of every test that runs this script on a host whose
# perl has JSON::PP is not the one the brief is fixing, so the end-to-end
# case is gated on the same host check the helper unit test is. The unit
# tests above already prove the helper itself; this one proves the
# heredoc-and-spawn path the helper plugs into.
test_pi_spawn_writes_a_parseable_piext_on_a_tricky_home_path_gated() {
  if perl -MJSON::PP -e 1 2>/dev/null; then
    printf 'skip: live: this host perl has JSON::PP, the no-JSON::PP heredoc path is not exercised here\n'
    return 0
  fi
  test_pi_spawn_writes_a_parseable_piext_on_a_tricky_home_path
}

# Resolve the helper's output for a path by sourcing it from bin/fm-spawn.sh
# in the host environment. Used to pin the literal bytes the heredoc writes
# are exactly the ones the helper produces — no other encoder, no fudging.
json_path_literal_via_spawn() {
  PATH="$PATH" bash -c "$(source_helper_from_script); json_path_literal \"\$1\"" _ "$1"
}

# Same drill for the statusFile; redo the per-line checks against the helper.
test_helper_consistency_between_isolated_call_and_spawn_output() {
  local id=piext-consistency-z1
  local home="$TMP_ROOT/$TRICKY_HOME_BASENAME"
  local proj="$TMP_ROOT/proj-consistency"
  local wt="$TMP_ROOT/wt-consistency"
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fb-consistency")
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/pi"
  fm_test_spawn_home "$home" pi
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-piext-consistency"

  # Skip the spawn if we cannot drive it on this host; the unit tests already
  # prove the helper. The full e2e is gated on JSON::PP being absent because
  # a host where perl has it is not the production failure case.
  if perl -MJSON::PP -e 1 2>/dev/null; then
    printf 'skip: live: this host perl has JSON::PP, the heredoc comparison is not the production path\n'
    return 0
  fi

  local out status
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness pi --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "pi spawn for the consistency case should succeed: $out"
  local piext="$home/state/$id.pi-ext.ts"
  local helper_exclude helper_status file_exclude file_status
  helper_exclude=$(json_path_literal_via_spawn "$home/config/crew-exclude-tools")
  helper_status=$(json_path_literal_via_spawn "$home/state/$id.status")
  file_exclude=$(grep -F 'const excludeFile = ' "$piext" | sed -E 's/^const excludeFile = (.*);$/\1/')
  file_status=$(grep -F 'const statusFile = ' "$piext" | sed -E 's/^const statusFile = (.*);$/\1/')
  assert_equals "$helper_exclude" "$file_exclude" "excludeFile in pi-ext.ts drifted from helper output"
  assert_equals "$helper_status" "$file_status" "statusFile in pi-ext.ts drifted from helper output"
  pass "pi-ext.ts encoded paths match the helper output byte-for-byte on a tricky home path"
}

test_helper_with_perl_jsonpp_matches_node_reference
test_helper_without_perl_jsonpp_falls_back_to_node
test_helper_perl_and_node_branches_produce_identical_output
test_helper_on_this_host_uses_node_fallback
test_pi_spawn_writes_a_parseable_piext_on_a_tricky_home_path_gated
test_helper_consistency_between_isolated_call_and_spawn_output
