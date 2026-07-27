#!/usr/bin/env bash
# Stock-macOS-Bash parse compatibility guard for firstmate's shell entry points.
#
# macOS ships GNU bash 3.2.57 as /bin/bash, and a captain may have no newer bash
# anywhere on PATH, so every `#!/usr/bin/env bash` script runs under 3.2 there.
# Bash 3.2 scans a `$( ... )` command substitution for its closing paren with a
# quote tracker that does not skip heredoc bodies. One apostrophe - or any other
# unbalanced quote character - inside a heredoc written INSIDE a command
# substitution makes that scan swallow the rest of the file, so the WHOLE script
# fails to parse, not just the block that holds the text.
#
# Regression history: #166 fixed exactly this in bin/fm-brief.sh, but its guard
# was a grep for the one offending phrase. #945 then reintroduced the class with
# a different word ("firstmate's") and no brief could be scaffolded on a stock
# Mac at all - `bash -n bin/fm-brief.sh` failed outright. Bash 4+ parses the
# construct, so Linux CI never saw either occurrence.
#
# This file therefore owns the CLASS guard rather than any single wording: no
# shell entry point may open a heredoc inside a command substitution. The safe
# shape is a function that emits the body with `cat <<DELIM`, plus a caller that
# captures `VAR=$(fn)`; the heredoc body is then parsed at top level, where quote
# characters are ordinary text and no future edit can re-arm the trap.
#
# Scope is bin/*.sh and bin/backends/*.sh - the scripts the fleet executes on the
# captain's own machine. tests/*.sh still contain the construct (node/jq fixture
# bodies) but parse cleanly under 3.2 today; they run in CI, not as fleet tooling.
#
# The static scan is line-based, so it cannot see a command substitution whose
# heredoc operator lands on a later continuation line. The real-parse sweep below
# covers that whenever a Bash 3.x binary is available (always on macOS, and in
# the CI macos-stock-bash job).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stock-bash-parse)

shell_entry_points() {
  ( cd "$ROOT" && ls bin/*.sh bin/backends/*.sh )
}

# Print "<file>:<line>: <text>" for every line that opens a heredoc inside a
# command substitution. Whole-line comments are skipped so the scripts may
# document the banned shape. `$((` arithmetic and `<<<` here-strings are excluded:
# neither carries a heredoc body, so neither can confuse the 3.2 scanner.
scan_heredoc_in_command_substitution() {  # <base-dir> <file>...
  local base=$1
  shift
  ( cd "$base" && awk '
    /^[[:space:]]*#/ { next }
    /\$\([^()]*<<[^<]/ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
  ' "$@" )
}

bash_version_of() {  # <interpreter>
  # shellcheck disable=SC2016  # single quotes are deliberate: the child bash must
  # expand BASH_VERSION, not this shell.
  "$1" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null
}

# Resolve a Bash 3.x interpreter for the real-parse sweep. FM_STOCK_BASH lets a
# maintainer point at an explicitly installed 3.2 build on a non-macOS box.
stock_bash() {
  local candidate version
  for candidate in "${FM_STOCK_BASH:-}" /bin/bash /usr/bin/bash /usr/local/bin/bash-3.2; do
    [ -n "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    version=$(bash_version_of "$candidate") || continue
    case "$version" in
      3.*) printf '%s\n' "$candidate"; return 0 ;;
    esac
  done
  return 1
}

# The class guard. This is what fails when any script reintroduces the shape,
# regardless of which word carries the quote character.
test_no_heredoc_inside_command_substitution() {
  local hits scripts
  scripts=$(shell_entry_points)
  [ -n "$scripts" ] || fail "no shell entry points found under bin/"
  # shellcheck disable=SC2086  # deliberate word splitting: one awk run over the file list
  hits=$(scan_heredoc_in_command_substitution "$ROOT" $scripts)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "heredoc opened inside a command substitution - stock macOS Bash 3.2 cannot parse these files; emit the body from a function and capture it with VAR=\$(fn)"
  fi
  pass "no bin script opens a heredoc inside a command substitution"
}

# Positive control: prove the scan and the 3.2 parser both reject the defect
# shape, and that the function-based replacement is accepted. Without this the
# guard above could pass by being blind rather than by the tree being clean.
test_defect_shape_is_detected_and_the_safe_shape_is_not() {
  local fixture_dir bad good hits bash32 out rc
  fixture_dir="$TMP_ROOT/fixtures"
  mkdir -p "$fixture_dir"
  bad="$fixture_dir/bad.sh"
  good="$fixture_dir/good.sh"

  # Same body text, same generated output, different construct. One lone
  # apostrophe is the trigger: the 3.2 scanner pairs quote characters, so an
  # ODD count is what runs away past the closing paren.
  cat > "$bad" <<'OUTER'
#!/usr/bin/env bash
BODY=$(cat <<EOF
firstmate's brief text
EOF
)
printf '%s\n' "$BODY"
OUTER
  cat > "$good" <<'OUTER'
#!/usr/bin/env bash
body_text() {
  cat <<'EOF'
firstmate's brief text
EOF
}
BODY=$(body_text)
printf '%s\n' "$BODY"
OUTER

  hits=$(scan_heredoc_in_command_substitution "$fixture_dir" bad.sh)
  [ -n "$hits" ] || fail "the scan failed to flag the defect shape - the class guard would be vacuous"
  hits=$(scan_heredoc_in_command_substitution "$fixture_dir" good.sh)
  [ -z "$hits" ] || fail "the scan flagged the safe function shape: $hits"

  if bash32=$(stock_bash); then
    out=$("$bash32" -n "$bad" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$bash32 parsed the defect shape - this test's premise no longer holds"
    assert_contains "$out" "unexpected EOF" "Bash 3.2 must reject the defect shape with an unexpected-EOF parse error"
    out=$("$bash32" -n "$good" 2>&1); rc=$?
    expect_code 0 "$rc" "Bash 3.2 must parse the function shape cleanly (got: $out)"
    out=$("$bash32" "$good")
    assert_contains "$out" "firstmate's brief text" "the function shape must emit the body verbatim"
    pass "defect shape rejected and safe shape accepted by $bash32 ($(bash_version_of "$bash32"))"
  else
    pass "defect shape detected statically (no Bash 3.x available to also prove the parse failure)"
  fi
}

# Real-parse sweep over the same file set, which also covers the multi-line
# openers the line-based scan cannot see.
test_stock_bash_parses_every_shell_entry_point() {
  local bash32 script broken out
  if ! bash32=$(stock_bash); then
    pass "no Bash 3.x interpreter available; static class guard is the portable proxy here"
    return 0
  fi
  broken=""
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    out=$(cd "$ROOT" && "$bash32" -n "$script" 2>&1) || broken="$broken
$script: $out"
  done <<EOF
$(shell_entry_points)
EOF
  [ -z "$broken" ] || fail "scripts do not parse under $bash32:$broken"
  pass "every bin script parses under $bash32 ($(bash_version_of "$bash32"))"
}

test_no_heredoc_inside_command_substitution
test_defect_shape_is_detected_and_the_safe_shape_is_not
test_stock_bash_parses_every_shell_entry_point
