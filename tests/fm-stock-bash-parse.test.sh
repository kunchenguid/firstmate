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
# The static scan reads one line at a time and tracks nesting only within that
# line, so it cannot see a command substitution whose heredoc operator lands on a
# later continuation line. The real-parse sweep below covers that whenever a Bash
# 3.x binary is available (always on macOS, and in the CI macos-stock-bash job).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stock-bash-parse)

shell_entry_points() {
  ( cd "$ROOT" && ls bin/*.sh bin/backends/*.sh )
}

# Print "<file>:<line>: <text>" for every line that opens a heredoc inside a
# command substitution. Whole-line comments are skipped so the scripts may keep
# documenting the banned shape in prose.
#
# Per line the scan first rewrites `<<<` here-strings to inert text - they carry
# no heredoc body, so they cannot confuse the 3.2 scanner - and then walks the
# remaining characters, pushing `$(` as a command substitution, `$((` as
# arithmetic and a bare `(` as a grouping paren. A `<<` is reported when the
# nearest enclosing construct that is not a grouping paren is a command
# substitution. That keeps arithmetic left shifts silent while still catching a
# command substitution whose command text contains parentheses before the
# heredoc operator - the jq/awk filter shape a "no parens in between" pattern
# walks straight past.
scan_heredoc_in_command_substitution() {  # <base-dir> <file>...
  local base=$1
  shift
  ( cd "$base" && awk '
    function opens_heredoc_in_command_substitution(line,   s, n, i, c1, c2, c3, depth, j, stack) {
      s = line
      gsub(/<<</, "@@@", s)
      n = length(s)
      depth = 0
      i = 1
      while (i <= n) {
        c1 = substr(s, i, 1)
        c2 = substr(s, i, 2)
        c3 = substr(s, i, 3)
        if (c3 == "$((") { stack[++depth] = "arith"; i += 3; continue }
        if (c2 == "$(")  { stack[++depth] = "cmdsub"; i += 2; continue }
        if (c2 == "<<") {
          for (j = depth; j >= 1; j--) {
            if (stack[j] == "arith") break
            if (stack[j] == "cmdsub") return 1
          }
          i += 2
          continue
        }
        if (c1 == "(") { stack[++depth] = "paren"; i++; continue }
        if (c1 == ")") {
          if (depth > 0 && stack[depth] == "arith" && c2 == "))") { depth--; i += 2; continue }
          if (depth > 0) depth--
          i++
          continue
        }
        i++
      }
      return 0
    }
    /^[[:space:]]*#/ { next }
    opens_heredoc_in_command_substitution($0) { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
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

# Positive control: prove the scan and the 3.2 parser agree on every fixture -
# the defect shapes are rejected, the safe shapes are accepted. Without this the
# guard above could pass by being blind rather than by the tree being clean, and
# each benign fixture pins a shape the scan must never mistake for the defect.
DEFECT_FIXTURES="bad.sh bad-filter.sh bad-nested.sh"
SAFE_FIXTURES="good.sh good-benign.sh"

test_defect_shapes_are_detected_and_safe_shapes_are_not() {
  local fixture_dir name hits bash32 out rc
  fixture_dir="$TMP_ROOT/fixtures"
  mkdir -p "$fixture_dir"

  # Same body text, same generated output, different construct. One lone
  # apostrophe is the trigger: the 3.2 scanner pairs quote characters, so an
  # ODD count is what runs away past the closing paren.
  cat > "$fixture_dir/bad.sh" <<'OUTER'
#!/usr/bin/env bash
BODY=$(cat <<EOF
firstmate's brief text
EOF
)
printf '%s\n' "$BODY"
OUTER
  # The jq/awk filter shape: parentheses sit in the command text between `$(`
  # and the heredoc operator. bin/fm-fleet-snapshot.sh carried exactly this.
  cat > "$fixture_dir/bad-filter.sh" <<'OUTER'
#!/usr/bin/env bash
RECORDS=$(jq -Rn 'capture("^- (?<id>[^ ]+)")' <<EOF
firstmate's brief text
EOF
)
printf '%s\n' "$RECORDS"
OUTER
  # Same blind spot reached through a nested command substitution in the
  # command text rather than through a quoted filter argument.
  cat > "$fixture_dir/bad-nested.sh" <<'OUTER'
#!/usr/bin/env bash
STAMPED=$(printf '%s' "$(date +%s)" <<EOF
firstmate's brief text
EOF
)
printf '%s\n' "$STAMPED"
OUTER
  cat > "$fixture_dir/good.sh" <<'OUTER'
#!/usr/bin/env bash
body_text() {
  cat <<'EOF'
firstmate's brief text
EOF
}
BODY=$(body_text)
printf '%s\n' "$BODY"
OUTER
  # Shapes that carry no heredoc body and must stay silent: a `<<<` here-string
  # inside a command substitution (bin/fm-kimi-turnend-hook.sh uses this one),
  # an arithmetic left shift, a plain subshell, and a whole-line comment that
  # documents the banned shape in prose.
  cat > "$fixture_dir/good-benign.sh" <<'OUTER'
#!/usr/bin/env bash
# The banned shape, named but not used: BODY=$(cat <<EOF ... ) breaks Bash 3.2.
PAYLOAD='{"a":1}'
PICKED=$(jq -er 'select(.a) | .a' <<< "$PAYLOAD" 2>/dev/null) || PICKED=
WIDTH=$(( 1 << 2 ))
NESTED=$( ( printf '%s' "$PICKED" ) )
printf '%s %s %s\n' "$PICKED" "$WIDTH" "$NESTED"
OUTER

  for name in $DEFECT_FIXTURES; do
    hits=$(scan_heredoc_in_command_substitution "$fixture_dir" "$name")
    [ -n "$hits" ] || fail "the scan failed to flag the defect shape in $name - the class guard would be vacuous there"
  done
  for name in $SAFE_FIXTURES; do
    hits=$(scan_heredoc_in_command_substitution "$fixture_dir" "$name")
    [ -z "$hits" ] || fail "the scan flagged a safe shape in $name: $hits"
  done

  if bash32=$(stock_bash); then
    for name in $DEFECT_FIXTURES; do
      out=$("$bash32" -n "$fixture_dir/$name" 2>&1); rc=$?
      [ "$rc" -ne 0 ] || fail "$bash32 parsed the defect shape in $name - this test's premise no longer holds"
      assert_contains "$out" "unexpected EOF" "Bash 3.2 must reject $name with an unexpected-EOF parse error"
    done
    for name in $SAFE_FIXTURES; do
      out=$("$bash32" -n "$fixture_dir/$name" 2>&1); rc=$?
      expect_code 0 "$rc" "Bash 3.2 must parse $name cleanly (got: $out)"
    done
    out=$("$bash32" "$fixture_dir/good.sh")
    assert_contains "$out" "firstmate's brief text" "the function shape must emit the body verbatim"
    pass "defect shapes rejected and safe shapes accepted by $bash32 ($(bash_version_of "$bash32"))"
  else
    pass "defect shapes detected statically (no Bash 3.x available to also prove the parse failures)"
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
test_defect_shapes_are_detected_and_safe_shapes_are_not
test_stock_bash_parses_every_shell_entry_point
