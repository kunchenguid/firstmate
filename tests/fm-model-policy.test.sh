#!/usr/bin/env bash
# Behavior tests for the forbidden-model policy library (bin/fm-model-policy-lib.sh).
#
# The policy exists so a model an operator has ruled out cannot come back through
# an edited profile, an omitted model, or a vendor's changing default. These
# cases drive the decision function through its public interface with real files
# on disk; the two enforcement points that consume it are covered where they
# refuse, in tests/fm-spawn-dispatch-profile.test.sh and tests/fm-bootstrap.test.sh.
#
# Every case that expects a refusal also asserts the reason, because a refusal
# for the wrong reason is how a policy silently stops covering what it claims to.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-model-policy-lib.sh
. "$ROOT/bin/fm-model-policy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-policy)

# make_config <name> [<denylist body>]: a config dir, with the policy file only
# when a body is given, so the absent-file case is a real absence.
make_config() {
  local name=$1 dir
  dir="$TMP_ROOT/$name/config"
  mkdir -p "$dir"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$2" > "$dir/model-denylist"
  fi
  printf '%s\n' "$dir"
}

# check <config-dir> <model>: run the model gate, print its reason, return its code.
check() {
  FM_MODEL_POLICY_ERROR=""
  if fm_model_policy_check "$1" "$2"; then
    return 0
  fi
  printf '%s\n' "$FM_MODEL_POLICY_ERROR"
  return 1
}

check_command() {
  FM_MODEL_POLICY_ERROR=""
  if fm_model_policy_check_command "$1" "$2"; then
    return 0
  fi
  printf '%s\n' "$FM_MODEL_POLICY_ERROR"
  return 1
}

test_absent_file_is_no_policy() {
  local config
  config=$(make_config absent)
  check "$config" fable || fail "an absent policy file must not refuse any model"
  check "$config" "" || fail "an absent policy file must not require an explicit model"
  pass "a home with no policy file is unaffected"
}

test_denied_fragment_matches_every_spelling() {
  local config out model
  config=$(make_config fragments 'fable')
  for model in fable claude-fable-5 anthropic/claude-fable-5 CLAUDE-FABLE-5; do
    out=$(check "$config" "$model") \
      && fail "model '$model' must be refused by the fragment 'fable'"
    assert_contains "$out" "model '$model' matches 'fable' in config/model-denylist" \
      "refusal for '$model' must name the model and the matched entry"
  done
  pass "a denied fragment refuses every spelling that contains it, in any case"
}

test_permitted_model_launches() {
  local config
  config=$(make_config permitted 'fable')
  check "$config" claude-opus-5 || fail "a model the policy does not name must be permitted"
  check "$config" ANTHROPIC/CLAUDE-OPUS-5 || fail "case alone must not refuse a permitted model"
  pass "a model no entry matches stays permitted"
}

test_unnamed_model_is_refused_by_default() {
  local config out
  config=$(make_config unnamed 'fable')
  out=$(check "$config" "") && fail "an unnamed model must be refused by default"
  assert_contains "$out" "no model is named" "refusal must say the model is unnamed"
  assert_contains "$out" "allow-unspecified-model" "refusal must name the directive that accepts harness defaults"
  # `default` is the sentinel fm-spawn records for an unnamed model, so it must
  # be read as one rather than as a model literally called "default".
  out=$(check "$config" default) && fail "the 'default' sentinel must be read as an unnamed model"
  assert_contains "$out" "no model is named" "the 'default' sentinel must refuse as unnamed"
  out=$(check "$config" '   ') && fail "whitespace must be read as an unnamed model"
  assert_contains "$out" "no model is named" "whitespace must refuse as unnamed"
  pass "an unnamed model is refused, because the vendor default would decide instead"
}

test_directive_accepts_harness_defaults_without_weakening_the_denylist() {
  local config out
  config=$(make_config directive 'fable
allow-unspecified-model')
  check "$config" "" || fail "the directive must accept an unnamed model"
  check "$config" default || fail "the directive must accept the 'default' sentinel"
  out=$(check "$config" claude-fable-5) \
    && fail "the directive must not weaken the denied fragments"
  assert_contains "$out" "matches 'fable'" "denied fragments must still refuse under the directive"
  pass "allow-unspecified-model accepts harness defaults and nothing else"
}

test_comments_and_blank_lines_are_not_entries() {
  local config out
  config=$(make_config comments '# opus is what this account may use

   fable   # trailing comment and surrounding space
'  )
  check "$config" claude-opus-5 || fail "a commented line must not become a denied fragment"
  out=$(check "$config" claude-fable-5) && fail "a trimmed entry must still deny"
  assert_contains "$out" "matches 'fable'" "the trimmed entry must be reported without its comment or spaces"
  pass "comments and surrounding whitespace are not part of an entry"
}

test_alias_is_denied_only_when_listed() {
  local config out
  # The honest boundary: Firstmate cannot resolve a vendor alias to the model it
  # picks without asking the vendor, so an alias is denied only by name. This
  # case pins both halves so the limitation cannot be mistaken for coverage.
  config=$(make_config alias-unlisted 'fable')
  check "$config" best || fail "an unlisted alias is outside what a denied fragment can see"
  config=$(make_config alias-listed 'fable
best')
  out=$(check "$config" best) && fail "a listed alias must be refused"
  assert_contains "$out" "model 'best' matches 'best'" "the alias refusal must name the listed entry"
  pass "a vendor alias is denied when listed, and an unlisted one is not seen"
}

test_unusable_policy_file_refuses_rather_than_evaporating() {
  local config out
  config=$(make_config symlink)
  ln -s /dev/null "$config/model-denylist"
  out=$(check "$config" claude-opus-5) && fail "a symlinked policy file must refuse"
  assert_contains "$out" "symlinked" "the refusal must say the policy file is symlinked"

  config=$(make_config directory)
  mkdir "$config/model-denylist"
  out=$(check "$config" claude-opus-5) && fail "a policy directory must refuse"
  assert_contains "$out" "not a regular file" "the refusal must say the policy file is not a regular file"

  config=$(make_config unreadable 'fable')
  chmod 000 "$config/model-denylist"
  if [ -r "$config/model-denylist" ]; then
    # Running as a user that bypasses the mode (root); the case cannot be staged.
    printf '# skipped unreadable-file case: this user reads mode 000 files\n'
  else
    out=$(check "$config" claude-opus-5) && fail "an unreadable policy file must refuse"
    assert_contains "$out" "could not be read" "the refusal must say the policy file could not be read"
  fi
  chmod 644 "$config/model-denylist"
  pass "a policy file that cannot be trusted refuses instead of evaporating"
}

test_empty_policy_file_still_requires_an_explicit_model() {
  local config out
  config=$(make_config empty '# nothing denied yet')
  check "$config" claude-opus-5 || fail "an empty policy must permit a named model"
  out=$(check "$config" "") && fail "a present policy file must still require an explicit model"
  assert_contains "$out" "no model is named" "the refusal must say the model is unnamed"
  pass "the file's presence activates the policy even before any entry is listed"
}

test_launch_command_scan_covers_operator_written_shell() {
  local config out
  config=$(make_config raw 'fable')
  out=$(check_command "$config" 'claude --model claude-fable-5 --dangerously-skip-permissions') \
    && fail "a launch command carrying a denied fragment must refuse"
  assert_contains "$out" "launch command contains 'fable'" "the refusal must name the matched entry"
  check_command "$config" 'claude --model claude-opus-5' \
    || fail "a launch command with a permitted model must not refuse"
  # The unnamed-model rule cannot be decided from arbitrary shell, so a command
  # with no model flag is deliberately not refused on that ground.
  check_command "$config" 'some-harness --yolo' \
    || fail "a launch command with no model flag must not trip the unnamed-model rule"
  pass "a raw launch command is scanned for denied fragments only"
}

test_absent_file_leaves_the_launch_command_scan_off() {
  local config
  config=$(make_config raw-absent)
  check_command "$config" 'claude --model claude-fable-5' \
    || fail "with no policy file, no launch command may be refused"
  pass "the launch command scan is off in a home with no policy"
}

test_absent_file_is_no_policy
test_denied_fragment_matches_every_spelling
test_permitted_model_launches
test_unnamed_model_is_refused_by_default
test_directive_accepts_harness_defaults_without_weakening_the_denylist
test_comments_and_blank_lines_are_not_entries
test_alias_is_denied_only_when_listed
test_unusable_policy_file_refuses_rather_than_evaporating
test_empty_policy_file_still_requires_an_explicit_model
test_launch_command_scan_covers_operator_written_shell
test_absent_file_leaves_the_launch_command_scan_off

echo "# all fm-model-policy tests passed"
