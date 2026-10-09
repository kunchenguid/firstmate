#!/usr/bin/env bash
# bin/fm-require-cmd.sh resolves an unavailable command to a discovered executable,
# refuses with an actionable diagnostic, and makes completion depend on a verified
# artifact rather than on the command's exit status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-require-cmd-tests)
REQUIRE="$ROOT/bin/fm-require-cmd.sh"

fake_tool() {  # <name> <body>
  local name="$TMP_ROOT/bin/$1"
  mkdir -p "$TMP_ROOT/bin"
  printf '%s\n' '#!/usr/bin/env bash' "$2" > "$name"
  chmod +x "$name"
  printf '%s\n' "$name"
}

test_path_command_resolves() {
  local out
  out=$("$REQUIRE" --resolve-only sh) || fail "resolving sh failed"
  case "$out" in
    */sh) ;;
    *) fail "sh did not resolve to an executable path: $out" ;;
  esac
  [ -x "$out" ] || fail "resolved path is not executable: $out"
  pass "a command on PATH resolves to its executable path"
}

test_slash_command_is_taken_as_a_path() {
  local tool out
  tool=$(fake_tool slash-tool 'echo ran')
  out=$("$REQUIRE" --resolve-only "$tool") || fail "resolving a slash command failed"
  [ "$out" = "$tool" ] || fail "a slash command resolved elsewhere: $out"
  pass "a command written as a path resolves to itself"
}

test_npx_cache_resolves() {
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/.npm/_npx/abc123/node_modules/.bin"
  printf '%s\n' '#!/usr/bin/env bash' 'echo ran' > "$home/.npm/_npx/abc123/node_modules/.bin/cached-tool"
  chmod +x "$home/.npm/_npx/abc123/node_modules/.bin/cached-tool"
  out=$(HOME="$home" "$REQUIRE" --resolve-only cached-tool) || fail "an npx-cached tool did not resolve"
  [ "$out" = "$home/.npm/_npx/abc123/node_modules/.bin/cached-tool" ] ||
    fail "resolved the wrong npx-cached tool: $out"
  pass "a never-installed-globally npx cache tool resolves to its executable"
}

test_unavailable_command_is_actionable() {
  local first second home out rc
  first="$TMP_ROOT/path-first"
  second="$TMP_ROOT/path-second"
  home="$TMP_ROOT/home"
  mkdir -p "$first" "$second" "$home"
  out=$(PATH="$first:$second" HOME="$home" "$BASH" "$REQUIRE" --resolve-only definitely-not-a-real-command 2>&1)
  rc=$?
  [ "$rc" -eq 127 ] || fail "an unavailable command did not exit 127 (got $rc)"
  assert_contains "$out" "definitely-not-a-real-command" "the diagnostic did not name the command"
  assert_contains "$out" "$first" "the diagnostic omitted the first PATH location"
  assert_contains "$out" "$second" "the diagnostic omitted the second PATH location"
  assert_contains "$out" "$home/.local/bin" "the diagnostic omitted a fallback location"
  pass "an unavailable command exits 127 naming every searched location"
}

test_resolve_only_does_not_run() {
  local tool marker
  # shellcheck disable=SC2016
  tool=$(fake_tool marker-tool 'touch "$1"')
  marker="$TMP_ROOT/ran"
  "$REQUIRE" --resolve-only "$tool" "$marker" >/dev/null || fail "resolve-only failed"
  [ ! -e "$marker" ] || fail "--resolve-only ran the command"
  pass "--resolve-only resolves without running the command"
}

test_run_passes_arguments_and_status() {
  local tool out rc
  # shellcheck disable=SC2016
  tool=$(fake_tool arg-tool 'echo "got:$1"; exit 7')
  out=$("$REQUIRE" "$tool" hello 2>/dev/null)
  rc=$?
  [ "$rc" -eq 7 ] || fail "a failing command did not propagate its status (got $rc)"
  assert_contains "$out" "got:hello" "arguments were not passed through"
  pass "run mode forwards arguments and propagates the command's exit status"
}

test_artifact_completion_gate() {
  local tool artifact out rc
  tool=$(fake_tool artifact-tool "printf 'analysis only\\n'")
  artifact="$TMP_ROOT/synthesis"

  out=$("$REQUIRE" --expect-artifact "$artifact" "$tool" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an analysis-only run with no artifact exited 0"
  assert_contains "$out" "produced no artifact" "the missing-artifact diagnostic was not actionable"

  : > "$artifact"
  "$REQUIRE" --expect-artifact "$artifact" "$tool" >/dev/null 2>&1 &&
    fail "an empty artifact file passed the completion gate"

  mkdir -p "$artifact.d"
  "$REQUIRE" --expect-artifact "$artifact.d" "$tool" >/dev/null 2>&1 &&
    fail "an empty artifact directory passed the completion gate"
  printf 'synthesis\n' > "$artifact.d/AGENTS.md"
  "$REQUIRE" --expect-artifact "$artifact.d" "$tool" >/dev/null 2>&1 ||
    fail "a populated artifact directory failed the completion gate"

  printf 'synthesis\n' > "$artifact"
  out=$("$REQUIRE" --expect-artifact "$artifact" "$tool" 2>&1) ||
    fail "a non-empty artifact failed the completion gate"
  assert_contains "$out" "verified $artifact" "success did not name the verified artifact"
  pass "completion depends on a non-empty artifact, not on exit status"
}

test_nonexecutable_slash_path_is_named() {
  local out rc
  out=$("$REQUIRE" --resolve-only "$TMP_ROOT/absent-tool" 2>&1)
  rc=$?
  [ "$rc" -eq 127 ] || fail "a missing slash path did not exit 127 (got $rc)"
  assert_contains "$out" "not an executable file" "the diagnostic did not say the path was the problem"
  pass "a command written as a missing path is named as the problem"
}

test_path_command_resolves
test_slash_command_is_taken_as_a_path
test_npx_cache_resolves
test_unavailable_command_is_actionable
test_resolve_only_does_not_run
test_run_passes_arguments_and_status
test_artifact_completion_gate
test_nonexecutable_slash_path_is_named
echo "# all fm-require-cmd tests passed"
