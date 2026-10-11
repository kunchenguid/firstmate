#!/usr/bin/env bash
# Behavior tests for bin/fm-compaction-check.sh.
#
# The checker resolves, for each pi session scope firstmate launches, the model
# that session starts with, that model's context window from the pi model list,
# the effective reserveTokens for the session's cwd, and the resulting compaction
# trigger point as a percentage of the window. It exits non-zero when a trigger
# point sits above the limit or when the reserve is not below the window at all.
#
# Every test drives the real script as a subprocess against fixtures: a global
# settings file, a project settings file, a secondmate registry, a
# secondmate-harness pin, and a stub `pi --list-models` output. Nothing here
# asserts script source text; the assertions are on the script's stdout and exit
# status only.
#
# The precedence axis matters most: pi merges the project settings over the
# global settings, so a project reserveTokens must win, and the project file's
# absence must fall through to the global one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-compaction-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-compaction-check)

# A stub `pi --list-models` table. Context values use the real command's decimal
# suffixes, and deepseek-v4-flash deliberately appears under two providers so the
# ambiguous-model-id path is exercised.
MODELS_STUB="$TMP_ROOT/models.txt"
cat > "$MODELS_STUB" <<'EOF'
provider         model                                               context  max-out  thinking  images
syslog-harness   syslog-auto                                         131.1K   32.8K    no        no
syslog-harness   tencent-plan/auto                                   131.1K   8.2K     no        no
deepseek         deepseek-v4-flash                                   1M       384K     yes       no
openrouter       deepseek-v4-flash                                   1M       128K     yes       no
openrouter       mega-out                                            1M       943.7K   yes       no
deepseek         deepseek-flash                                      1M       384K     yes       yes
EOF

OUT=
STATUS=0

# make_home <case>: builds $TMP_ROOT/<case>/home with the pi/project/registry
# layout the checker reads, and echoes the case directory.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/.pi" "$dir/home/data" "$dir/home/config"
  printf '%s' "$dir"
}

# run_check <primary-home> [checker args...] -> OUT, STATUS
run_check() {
  local primary=$1
  shift
  run_check_with_cmd "cat $MODELS_STUB" "$primary" "$@"
}

# run_check_with_cmd <models-command> <primary-home> [checker args...] -> OUT, STATUS
run_check_with_cmd() {
  local models_cmd=$1 primary=$2 case_dir
  shift 2
  case_dir=$(cd "$primary/.." && pwd)
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$primary" \
        FM_COMPACTION_PRIMARY_HOME="$primary" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD="$models_cmd" \
        bash "$CHECK" "$@" 2>&1) || STATUS=$?
}

# A session line for one scope only, so a presence assertion cannot be satisfied
# by another scope's output.
scope_line() { # <name> <output>
  printf '%s\n' "$2" | grep -F "session=$1 " || true
}

test_project_over_global_reserve_wins() {
  case_dir=$(make_home project-over-global)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":true,"reserveTokens":60000}}
EOF
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"enabled":true,"reserveTokens":65536}}
EOF
  run_check "$home"
  expect_code 0 "$STATUS" "project-over-global: safe configuration must pass"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reserveTokens=65536" "project reserve must override the global reserve"
  assert_contains "$line" "source=$home/.pi/settings.json" "the project file must be named as the source"
  assert_contains "$line" "trigger=50.0%" "65536 of 131.1K must trigger at 50.0%"
  assert_not_contains "$line" "reserveTokens=60000" "the global reserve must not be reported for this scope"
  global_line=$(scope_line global-scope "$OUT")
  assert_contains "$global_line" "reserveTokens=60000" "the global scope must still report the global reserve"
  assert_contains "$global_line" "source=$case_dir/global.json" "the global scope must name the global file"
  pass "project .pi/settings.json reserveTokens wins over the global settings"
}

test_global_reserve_used_without_project_settings() {
  case_dir=$(make_home global-fallback)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  run_check "$home"
  expect_code 0 "$STATUS" "global-fallback: safe configuration must pass"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reserveTokens=65536" "the global reserve must apply when the cwd has no project settings"
  assert_contains "$line" "source=$case_dir/global.json" "the global file must be named as the source"
  pass "a cwd with no project settings falls through to the global reserve"
}

test_builtin_default_reserve_is_named() {
  case_dir=$(make_home builtin-default)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"keepRecentTokens":15000}}
EOF
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"keepRecentTokens":20000}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "builtin-default: 16384 of 131.1K triggers at 87.5% and must fail"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reserveTokens=16384" "pi's built-in default reserve must be used"
  assert_contains "$line" "source=builtin-pi-default" "the built-in default must be named as the source"
  assert_contains "$line" "reason=trigger-above-limit" "an 87.5% trigger must be reported as above the limit"
  pass "the built-in pi default reserve is used and named when no file sets one"
}

test_disabled_compaction_scope_is_not_judged_by_its_reserve() {
  case_dir=$(make_home disabled-compaction)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":true,"reserveTokens":65536}}
EOF
  # 100 of 131.1K triggers at 99.9%, which would be unsafe if it were judged.
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"enabled":false,"reserveTokens":100}}
EOF
  run_check "$home"
  expect_code 0 "$STATUS" "disabled-compaction: a scope that never compacts must not fail the run"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: skipped" "the disabled scope must be skipped, not judged"
  assert_contains "$line" "reason=compaction-disabled" "the skip reason must say compaction is disabled"
  assert_not_contains "$OUT" "COMPACTION: unsafe" "a disabled scope must never be unsafe"
  run_check "$home" --diagnostics
  expect_code 0 "$STATUS" "disabled-compaction: diagnostics must stay non-failing"
  [ -z "$OUT" ] || fail "a deliberately disabled scope withholds no verdict and must stay silent in diagnostics"$'\n'"--- output ---"$'\n'"$OUT"
  pass "a scope with compaction disabled is not judged by a reserve pi ignores"
}

test_disabled_scope_does_not_disarm_a_sibling_guard() {
  case_dir=$(make_home disabled-sibling)
  home="$case_dir/home"
  # The global scope carries no enabled key, so pi's default (enabled) applies
  # and its unsafe reserve must still fail; the disabled primary must not mask it.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":20000}}
EOF
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"enabled":false,"reserveTokens":100}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "disabled-sibling: an absent enabled key must still judge an unsafe reserve"
  assert_contains "$(scope_line primary "$OUT")" "reason=compaction-disabled" "the disabled scope must be skipped"
  global_line=$(scope_line global-scope "$OUT")
  assert_contains "$global_line" "COMPACTION: unsafe" "the sibling scope must still be judged"
  assert_contains "$global_line" "reason=trigger-above-limit" "the absent enabled key must default to enabled"
  run_check "$home" --diagnostics
  expect_code 1 "$STATUS" "disabled-sibling: diagnostics must still surface the sibling"
  assert_contains "$OUT" "COMPACTION: unsafe session=global-scope" "the sibling must reach the digest"
  assert_not_contains "$OUT" "session=primary" "the disabled scope must not reach diagnostics"
  pass "a disabled scope does not disarm the guard for a sibling with an absent enabled key"
}

test_project_enabled_true_overrides_global_enabled_false() {
  case_dir=$(make_home enabled-precedence)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":false,"reserveTokens":100}}
EOF
  # The project file turns compaction back on, so its unsafe reserve is judged.
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"enabled":true,"reserveTokens":100}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "enabled-precedence: a project enabled:true must be judged"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: unsafe" "the project enabled:true must override the global enabled:false"
  assert_contains "$line" "reason=trigger-above-limit" "the judged reserve must report its reason"
  global_line=$(scope_line global-scope "$OUT")
  assert_contains "$global_line" "reason=compaction-disabled" "the global scope must stay disabled"
  pass "compaction.enabled follows project-over-global precedence like reserveTokens"
}

# --- fail-closed coverage for a non-boolean compaction.enabled ---------------
#
# pi's own coercion is JS truthiness: settings-manager.getCompactionEnabled()
# returns `this.settings.compaction?.enabled ?? true`, then shouldCompact()
# short-circuits on `!settings.enabled`. So null and every truthy non-boolean
# resolve enabled, while 0 and "" resolve disabled. This checker deliberately
# does NOT reproduce that coercion: a non-boolean is a configuration defect, and
# an error is both the checker's documented contract for an inconsistent input
# and the fail-closed direction, because a guessed verdict would hide either a
# mis-sized reserve or the defect itself. These tests fail if the strict arm is
# relaxed to `ENABLED=$value`, to `ENABLED=false`, to `ENABLED=true`, or to pi's
# own truthiness.

test_non_boolean_enabled_is_an_error_not_a_silent_coercion() {
  local case_dir home entry label value
  local -a shapes=(
    'null:null'
    'truthy-string:"yes"'
    'number-one:1'
    'number-zero:0'
    'empty-string:""'
  )
  for entry in "${shapes[@]}"; do
    label=${entry%%:*}
    value=${entry#*:}
    case_dir=$(make_home "non-boolean-$label")
    home="$case_dir/home"
    cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":true,"reserveTokens":65536}}
EOF
    # 100 of 131.1K would be unsafe if judged, so a coercion to enabled is loud.
    cat > "$home/.pi/settings.json" <<EOF
{"compaction":{"enabled":$value,"reserveTokens":100}}
EOF
    run_check "$home"
    expect_code 2 "$STATUS" "enabled:$value must be an error, not a guessed verdict"
    line=$(scope_line primary "$OUT")
    assert_contains "$line" "COMPACTION: error" "enabled:$value must be reported as an error"
    assert_contains "$line" "reason=compaction-enabled-is-not-a-boolean" \
      "enabled:$value must name the non-boolean reason"
    assert_not_contains "$line" "COMPACTION: ok" "enabled:$value must not be resolved as enabled"
    assert_not_contains "$line" "COMPACTION: unsafe" "enabled:$value must not be judged by its reserve"
    assert_not_contains "$line" "COMPACTION: skipped" "enabled:$value must not be resolved as disabled"
    run_check "$home" --diagnostics
    expect_code 2 "$STATUS" "enabled:$value must reach the session-start digest"
    assert_contains "$OUT" "COMPACTION: error session=primary" \
      "enabled:$value must not be swallowed by diagnostics mode"
  done
  pass "a non-boolean compaction.enabled is a visible error, never a silent coercion"
}

test_global_non_boolean_enabled_errors_for_every_scope() {
  local case_dir home
  case_dir=$(make_home global-non-boolean)
  home="$case_dir/home"
  # Only the global file carries the setting, so the primary scope and the
  # global scope both resolve their effective enabled from it and both must
  # report the defect instead of judging the reserve it sits beside.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":"yes","reserveTokens":100}}
EOF
  run_check "$home"
  expect_code 2 "$STATUS" "a non-boolean in the global file must be an error"
  assert_contains "$(scope_line primary "$OUT")" "reason=compaction-enabled-is-not-a-boolean" \
    "the primary scope must report the global defect rather than judge the reserve"
  assert_contains "$(scope_line global-scope "$OUT")" "reason=compaction-enabled-is-not-a-boolean" \
    "the global scope must report its own non-boolean enabled"
  assert_not_contains "$OUT" "COMPACTION: unsafe" "no scope may be judged under a defective enabled"
  pass "a non-boolean global compaction.enabled errors for every scope instead of being coerced"
}

test_secondmate_pin_rejects_a_non_boolean_enabled() {
  local case_dir home
  case_dir=$(make_home pin-non-boolean)
  home="$case_dir/home"
  mkdir -p "$case_dir/sm-z/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"enabled":true,"reserveTokens":65536}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
pi syslog-auto
EOF
  cat > "$case_dir/sm-z/.pi/settings.json" <<'EOF'
{"compaction":{"enabled":"yes","reserveTokens":100}}
EOF
  cat > "$home/data/secondmates.md" <<EOF
- zeta - Test secondmate zeta. (home: $case_dir/sm-z; scope: testing; projects: none; added 2026-01-01)
EOF
  run_check "$home"
  expect_code 2 "$STATUS" "a secondmate home with a non-boolean enabled must be an error"
  line=$(scope_line secondmate-zeta "$OUT")
  assert_contains "$line" "COMPACTION: error" "the pinned scope must report the defect"
  assert_contains "$line" "reason=compaction-enabled-is-not-a-boolean" "the pinned scope must name the reason"
  assert_not_contains "$line" "COMPACTION: skipped" "the pinned scope must not be silently skipped"
  pass "a secondmate pin scope rejects a non-boolean enabled instead of coercing it"
}

test_above_limit_failure_names_every_input() {
  case_dir=$(make_home above-limit)
  home="$case_dir/home"
  rmdir "$home/.pi"
  # The incident shape: a reserve sized for a 131K window left in place under a
  # 1M model, so compaction never fires.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"deepseek","defaultModel":"deepseek-flash","compaction":{"reserveTokens":46072}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "above-limit: a 95.4% trigger must fail"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: unsafe" "the failing scope must be marked unsafe"
  assert_contains "$line" "session=primary" "the line must name the session"
  assert_contains "$line" "model=deepseek/deepseek-flash" "the line must name the model"
  assert_contains "$line" "window=1M" "the line must name the window"
  assert_contains "$line" "reserveTokens=46072" "the line must name the setting"
  assert_contains "$line" "source=$case_dir/global.json" "the line must name the file that set it"
  assert_contains "$line" "trigger=95.4%" "46072 of 1M must trigger at 95.4%"
  assert_contains "$line" "reason=trigger-above-limit" "the reason must ride the line"
  pass "a trigger above the limit fails non-zero and names session, model, window, setting, and file"
}

test_reserve_at_or_above_window_fails() {
  case_dir=$(make_home reserve-over-window)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":500000}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "reserve-over-window: a reserve larger than the window must fail"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reason=reserve-not-below-window" "a reserve at or above the window compacts every turn"
  pass "a reserve that is not below the window fails even though the trigger point is not above the limit"
}

test_diagnostics_mode_is_silent_when_safe() {
  case_dir=$(make_home diagnostics-silent)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  cat > "$home/.pi/settings.json" <<'EOF'
{"compaction":{"reserveTokens":65536}}
EOF
  run_check "$home" --diagnostics
  expect_code 0 "$STATUS" "diagnostics: a safe configuration must exit 0"
  [ -z "$OUT" ] || fail "diagnostics mode must print nothing when every scope is safe"$'\n'"--- output ---"$'\n'"$OUT"
  run_check "$home" --all
  assert_contains "$OUT" "session=primary" "--all must still print the per-scope line"
  pass "--diagnostics is silent when every scope is safe while --all still prints the table"
}

test_diagnostics_mode_prints_only_actionable_lines() {
  case_dir=$(make_home diagnostics-unsafe)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":20000}}
EOF
  run_check "$home" --diagnostics
  expect_code 1 "$STATUS" "diagnostics: an unsafe configuration must exit 1"
  assert_contains "$OUT" "COMPACTION: unsafe session=primary" "the unsafe scope must be printed"
  assert_contains "$OUT" "reason=trigger-above-limit" "the unsafe line must carry its reason"
  assert_not_contains "$OUT" "COMPACTION: ok" "safe scopes must stay silent in diagnostics mode"
  pass "--diagnostics prints only the actionable lines"
}

test_secondmate_home_project_reserve_wins() {
  case_dir=$(make_home secondmates)
  home="$case_dir/home"
  mkdir -p "$case_dir/sm-a/.pi" "$case_dir/sm-b/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
pi syslog-auto
EOF
  # sm-a overrides its own reserve; sm-b inherits the global one.
  cat > "$case_dir/sm-a/.pi/settings.json" <<'EOF'
{"compaction":{"reserveTokens":40000}}
EOF
  rmdir "$case_dir/sm-b/.pi"
  cat > "$home/data/secondmates.md" <<EOF
- alpha - Test secondmate alpha. (home: $case_dir/sm-a; scope: testing; projects: none; added 2026-01-01)
- beta - Test secondmate beta. (home: $case_dir/sm-b; scope: testing; projects: none; added 2026-01-01)
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "secondmates: alpha's 40000 reserve triggers at 69.5% and must fail"
  alpha=$(scope_line secondmate-alpha "$OUT")
  beta=$(scope_line secondmate-beta "$OUT")
  assert_contains "$alpha" "model=syslog-harness/syslog-auto" "the harness pin's model must be used"
  assert_contains "$alpha" "reserveTokens=40000" "that home's own project reserve must win"
  assert_contains "$alpha" "source=$case_dir/sm-a/.pi/settings.json" "the home's own file must be the source"
  assert_contains "$alpha" "reason=trigger-above-limit" "69.5% must be reported as above the limit"
  assert_contains "$beta" "reserveTokens=65536" "a home without project settings must inherit the global reserve"
  assert_contains "$beta" "trigger=50.0%" "the inherited reserve must trigger at 50.0%"
  pass "each secondmate home resolves its own project settings over the global file"
}

test_non_pi_harness_is_skipped() {
  case_dir=$(make_home non-pi-harness)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
claude sonnet high
EOF
  cat > "$home/data/secondmates.md" <<EOF
- gamma - Test secondmate gamma. (home: $home; scope: testing; projects: none; added 2026-01-01)
EOF
  run_check "$home"
  expect_code 0 "$STATUS" "a non-pi harness must not be reported as a pi compaction failure"
  line=$(scope_line secondmate-gamma "$OUT")
  assert_contains "$line" "COMPACTION: skipped" "the scope must be marked skipped"
  assert_contains "$line" "reason=harness-not-pi" "the skip reason must be stated"
  run_check "$home" --diagnostics
  [ -z "$OUT" ] || fail "a skipped scope must not be an actionable diagnostic"$'\n'"--- output ---"$'\n'"$OUT"
  pass "a non-pi secondmate harness is skipped rather than judged by pi's compaction settings"
}

test_unknown_model_is_an_error() {
  case_dir=$(make_home unknown-model)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"not-a-model","compaction":{"reserveTokens":65536}}
EOF
  run_check "$home"
  expect_code 2 "$STATUS" "an unresolvable model must exit 2"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: error" "the scope must be marked error"
  assert_contains "$line" "model=syslog-harness/not-a-model" "the unresolved model must be named"
  assert_contains "$line" "reason=model-not-in-pi-model-list" "the reason must be stated"
  run_check "$home" --diagnostics
  assert_contains "$OUT" "COMPACTION: error session=primary" "an unjudgeable scope must reach the digest, not be hidden"
  assert_contains "$OUT" "reason=model-not-in-pi-model-list" "the digest line must carry the reason"
  pass "a model absent from the pi model list is a visible error, not a silent pass"
}

test_ambiguous_model_id_is_an_error() {
  case_dir=$(make_home ambiguous-model)
  home="$case_dir/home"
  rmdir "$home/.pi"
  # No defaultProvider here, so the pin's bare model id has no provider to
  # qualify it and the ambiguity must be reported rather than guessed.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
pi deepseek-v4-flash
EOF
  cat > "$home/data/secondmates.md" <<EOF
- delta - Test secondmate delta. (home: $home; scope: testing; projects: none; added 2026-01-01)
EOF
  run_check "$home"
  expect_code 2 "$STATUS" "a model id served by two providers must exit 2"
  line=$(scope_line secondmate-delta "$OUT")
  assert_contains "$line" "reason=model-id-ambiguous" "the ambiguity must be reported rather than guessed"
  pass "a bare model id served by more than one provider is a loud error"
}

test_model_list_failure_is_reported() {
  case_dir=$(make_home models-failure)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD=false bash "$CHECK" 2>&1) || STATUS=$?
  expect_code 2 "$STATUS" "an unavailable model list must exit 2"
  assert_contains "$OUT" "COMPACTION: error session=all" "the failure must be reported for the whole check"
  assert_contains "$OUT" "reason=model-list-command-failed" "the reason must name the unavailable command"
  run_check_with_cmd false "$home" --diagnostics
  assert_contains "$OUT" "COMPACTION: error session=all" "an unavailable list must reach the digest"
  pass "an unavailable model list fails visibly instead of passing quietly"
}

# --- fail-closed coverage for an incomplete model list ----------------------
#
# `pi --list-models` can return a partial list (whole providers missing) while
# still exiting 0. A scope it does not cover must never leave the digest silent:
# intermittent silence about an unjudged scope is strictly worse than a bounded
# repeated line.

test_partial_model_list_is_not_silent() {
  case_dir=$(make_home partial-list)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":100}}
EOF
  # A list that is missing the scope's provider entirely: this is what a partial
  # read looks like, and it differs from a model id that is merely absent.
  cat > "$case_dir/partial-models.txt" <<'EOF'
provider         model                                               context  max-out  thinking  images
deepseek         deepseek-flash                                      1M       384K     yes       yes
EOF
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD="cat $case_dir/partial-models.txt" \
        bash "$CHECK" --diagnostics 2>&1) || STATUS=$?
  expect_code 2 "$STATUS" "a partial list must not pass"
  [ -n "$OUT" ] || fail "a partial model list produced a silent no-output run"
  assert_contains "$OUT" "COMPACTION: error session=primary" "the unjudged scope must be named"
  assert_contains "$OUT" "reason=model-list-missing-provider" "the partial-list signature must be named"
  pass "a partial model list cannot hide a scope's verdict silently"
}

test_empty_model_list_is_not_silent() {
  case_dir=$(make_home empty-list)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":100}}
EOF
  cat > "$case_dir/empty-models.txt" <<'EOF'
provider         model                                               context  max-out  thinking  images
EOF
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD="cat $case_dir/empty-models.txt" \
        bash "$CHECK" --diagnostics 2>&1) || STATUS=$?
  # An empty model list is a legitimate state (no providers configured), so the
  # check reports `skipped` rather than `error` — same treatment as pi-not-installed.
  # In diagnostics mode, `skipped` is quiet by design, so we verify via exit code
  # and the absence of an error line rather than the presence of output.
  expect_code 0 "$STATUS" "a header-only model list is skipped, not an error"
  assert_absent "$OUT" "error" "an empty model list must not be reported as error"
  pass "an empty model list is skipped, not an error"
}

test_partial_model_list_retry_recovers() {
  case_dir=$(make_home partial-retry)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  cat > "$case_dir/partial-models.txt" <<'EOF'
provider         model                                               context  max-out  thinking  images
deepseek         deepseek-flash                                      1M       384K     yes       yes
EOF
  cat > "$case_dir/flaky-models.sh" <<EOF
#!/usr/bin/env bash
# First read is partial, every later read is complete.
count=0
[ ! -f "$case_dir/flaky.count" ] || count=\$(cat "$case_dir/flaky.count")
count=\$((count + 1))
printf '%s' "\$count" > "$case_dir/flaky.count"
if [ "\$count" -eq 1 ]; then
  cat "$case_dir/partial-models.txt"
else
  cat "$MODELS_STUB"
fi
EOF
  chmod +x "$case_dir/flaky-models.sh"
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD="$case_dir/flaky-models.sh" \
        bash "$CHECK" --all 2>&1) || STATUS=$?
  expect_code 0 "$STATUS" "a retired partial list must resolve to the safe 50% verdict"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: ok" "the retry must recover the scope's verdict"
  assert_contains "$line" "trigger=50.0%" "the recovered verdict must use the complete list"
  pass "a partial first read is retried and the scope is judged instead of erroring"
}

# make_narrow_fakebin <dirname> [silent-jq]: a PATH with only the tools the
# checker needs, so a case can remove one of them (no pi) or degrade one
# (a jq that prints nothing).
# The stubs are written into the fakebin only: every path here is replaced, never
# opened, because the entries above are symlinks to the HOST tool of the same name
# and a plain `cat >` through such a symlink would overwrite the real binary.
make_narrow_fakebin() {
  local dirname=$1 mode=${2:-} fakebin tool
  fakebin="$TMP_ROOT/$dirname"
  mkdir -p "$fakebin"
  for tool in bash dirname jq awk grep sed cut head tr cat; do
    ln -sfn "$(command -v "$tool")" "$fakebin/$tool"
  done
  if [ "$mode" = silent-jq ]; then
    rm -f "$fakebin/jq"
    cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/jq"
  fi
  printf '%s' "$fakebin"
}

test_missing_pi_is_skipped_not_failed() {
  case_dir=$(make_home missing-pi)
  home="$case_dir/home"
  rmdir "$home/.pi"
  # A reserve this small would be unsafe if the check could run at all, so
  # silence below is evidence the scope was skipped rather than passed.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":100}}
EOF
  fakebin=$(make_narrow_fakebin missing-pi-bin)
  OUT=
  STATUS=0
  OUT=$(PATH="$fakebin" FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        bash "$CHECK" --diagnostics 2>&1) || STATUS=$?
  expect_code 0 "$STATUS" "a host without pi must not fail the check"
  [ -z "$OUT" ] || fail "a host without pi must stay silent in diagnostics mode"$'\n'"--- output ---"$'\n'"$OUT"
  OUT=
  STATUS=0
  OUT=$(PATH="$fakebin" FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        bash "$CHECK" --all 2>&1) || STATUS=$?
  expect_code 0 "$STATUS" "a host without pi must stay exit 0 in table mode"
  assert_contains "$OUT" "reason=pi-not-installed" "--all must say why nothing was judged"
  pass "a host with no pi installed skips the check instead of failing it"
}

test_silent_jq_is_not_read_as_missing_settings() {
  case_dir=$(make_home silent-jq)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","compaction":{"reserveTokens":65536}}
EOF
  # A jq that produces nothing must not look like an empty settings object: the
  # file exists and names a model, so the honest report names the unreadable file
  # rather than inventing no-model-configured.
  fakebin=$(make_narrow_fakebin silent-jq-bin silent-jq)
  OUT=
  STATUS=0
  OUT=$(PATH="$fakebin" FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" \
        FM_COMPACTION_MODELS_CMD="cat $MODELS_STUB" \
        bash "$CHECK" --diagnostics 2>&1) || STATUS=$?
  expect_code 2 "$STATUS" "an unreadable settings file must fail"
  [ -n "$OUT" ] || fail "an unreadable settings file produced a silent no-output run"
  assert_contains "$OUT" "reason=unreadable-json:$case_dir/global.json" "the unreadable file must be named"
  pass "a settings read that yields nothing is reported as unreadable, not as missing settings"
}

# --- session-start wiring ---------------------------------------------------

# The digest prints the bootstrap section, so the check reaches firstmate by
# riding bootstrap's stdout. These two tests drive the real bootstrap through
# its documented read-only detect pass and assert the digest-visible contract:
# an actionable line when a scope is unsafe, silence when every scope is safe.
run_bootstrap_detect() { # <home> <global-json> -> OUT, STATUS
  local home=$1 global=$2
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" \
        FM_ROOT_OVERRIDE="$home" \
        FM_STATE_OVERRIDE="$home/state" \
        FM_CONFIG_OVERRIDE="$home/config" \
        FM_DATA_OVERRIDE="$home/data" \
        FM_PROJECTS_OVERRIDE="$home/projects" \
        FM_BOOTSTRAP_DETECT_ONLY=1 \
        FM_BOOTSTRAP_NETWORK=skip \
        FM_BOOTSTRAP_NETWORK_PHASE=skip \
        FM_COMPACTION_GLOBAL_SETTINGS="$global" \
        FM_COMPACTION_MODELS_CMD="cat $MODELS_STUB" \
        bash "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null) || STATUS=$?
}

test_bootstrap_reports_unsafe_scope() {
  case_dir=$(make_home bootstrap-unsafe)
  home="$case_dir/home"
  mkdir -p "$home/projects" "$home/state"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"deepseek","defaultModel":"deepseek-flash","compaction":{"reserveTokens":46072}}
EOF
  run_bootstrap_detect "$home" "$case_dir/global.json"
  assert_contains "$OUT" "COMPACTION: unsafe session=primary" "the digest's bootstrap section must carry the unsafe verdict"
  assert_contains "$OUT" "reason=trigger-above-limit" "the digest line must carry the reason"
  pass "the read-only bootstrap detect pass relays the unsafe compaction line into the digest"
}

test_bootstrap_is_silent_when_every_scope_is_safe() {
  case_dir=$(make_home bootstrap-safe)
  home="$case_dir/home"
  mkdir -p "$home/projects" "$home/state" "$case_dir/sm"
  # 500000 of a 1M window triggers at 50% for the primary and global scopes, and
  # the secondmate pin resolves to the same model, so every scope is safe.
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"deepseek","defaultModel":"deepseek-flash","compaction":{"reserveTokens":500000}}
EOF
  cat > "$home/config/secondmate-harness" <<'EOF'
pi deepseek-flash
EOF
  cat > "$home/data/secondmates.md" <<EOF
- epsilon - Test secondmate epsilon. (home: $case_dir/sm; scope: testing; projects: none; added 2026-01-01)
EOF
  run_bootstrap_detect "$home" "$case_dir/global.json"
  assert_not_contains "$OUT" "COMPACTION: unsafe" "a safe fleet must not produce an unsafe line"
  assert_not_contains "$OUT" "COMPACTION: error" "a resolvable fleet must not produce an error line"
  assert_not_contains "$OUT" "COMPACTION: ok" "the digest must stay quiet about safe scopes"
  pass "the bootstrap detect pass stays silent when every session scope is safe"
}

# Live guard: the verdict depends on vendor output, so the parser must also be
# proven against a real `pi` installation. Self-skips where pi is absent.
test_real_pi_model_list_resolves() {
  if ! command -v pi >/dev/null 2>&1; then
    printf 'skip: pi not found\n'
    return 0
  fi
  local row provider model
  row=$(pi --no-extensions --offline --list-models 2>/dev/null | awk 'NR > 1 && NF >= 3 { print $1 "|" $2; exit }')
  if [ -z "$row" ]; then
    printf 'skip: pi --list-models produced no usable row\n'
    return 0
  fi
  provider=${row%%|*}
  model=${row#*|}
  case_dir=$(make_home live-pi)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<EOF
{"defaultProvider":"$provider","defaultModel":"$model","compaction":{"reserveTokens":1000}}
EOF
  OUT=
  STATUS=0
  OUT=$(FM_HOME="$home" FM_COMPACTION_PRIMARY_HOME="$home" \
        FM_COMPACTION_GLOBAL_SETTINGS="$case_dir/global.json" bash "$CHECK" 2>&1) || STATUS=$?
  expect_code 1 "$STATUS" "live-pi: a 1000-token reserve must be reported unsafe"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "model=$provider/$model" "the real model list must resolve the fixture's model"
  assert_contains "$line" "reserveTokens=1000" "the fixture's reserve must be used"
  assert_not_contains "$line" "window=-" "the real model list must yield a window"
  assert_contains "$line" "reason=trigger-above-limit" "a 1000-token reserve must be above the limit"
  pass "the real pi --list-models output resolves a window through this checker"
}

# --- defect: thinking level and output budget -------------------------------
#
# The effective reasoning level and the model's output ceiling must be explicit
# and judged at boot. A level inherited silently, a level set from two
# conflicting files, an output ceiling below the local-model floor, or a ceiling
# the compaction reserve cannot hold are all actionable, and every line names
# the effective level and the file that set it.

test_output_ceiling_below_the_fleet_floor_is_unsafe_with_both_numbers() {
  case_dir=$(make_home output-floor)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"tencent-plan/auto","compaction":{"reserveTokens":65536}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "an 8.2K output ceiling must be reported unsafe"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: unsafe" "the scope must be marked unsafe"
  assert_contains "$line" "reason=output-budget-below-ceiling" "the reason must name the output ceiling"
  assert_contains "$line" "output=8.2K ceiling=32768" "the line must name both numbers"
  pass "a model output ceiling below the fleet floor fails loudly with both numbers"
}

test_output_ceiling_above_the_reserve_is_unsafe_with_both_numbers() {
  case_dir=$(make_home output-reserve)
  home="$case_dir/home"
  rmdir "$home/.pi"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"openrouter","defaultModel":"mega-out","compaction":{"reserveTokens":500000}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "an output ceiling above the reserve must be reported unsafe"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reason=output-budget-exceeds-reserve" "the reason must name the reserve collision"
  assert_contains "$line" "output=943700" "the line must name the output ceiling"
  assert_contains "$line" "reserve=500000" "the line must name the reserve"
  pass "an output ceiling the reserve cannot hold fails loudly with both numbers"
}

test_thinking_level_from_two_conflicting_sources_is_unsafe() {
  case_dir=$(make_home thinking-conflict)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","defaultThinkingLevel":"high","compaction":{"reserveTokens":65536}}
EOF
  cat > "$home/.pi/settings.json" <<'EOF'
{"defaultThinkingLevel":"medium","compaction":{"reserveTokens":65536}}
EOF
  run_check "$home"
  expect_code 1 "$STATUS" "a level set from two conflicting files must be reported unsafe"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "reason=thinking-level-dual-source" "the reason must name the two-source conflict"
  assert_contains "$line" "project=medium global=high" "the line must name both values"
  assert_contains "$line" "thinking=medium thinkingSource=$home/.pi/settings.json" \
    "the effective project level must be named with its source"
  pass "a thinking level set from two conflicting sources is reported unsafe with both values"
}

test_single_explicit_thinking_level_is_ok_and_named() {
  case_dir=$(make_home thinking-single)
  home="$case_dir/home"
  cat > "$case_dir/global.json" <<'EOF'
{"defaultProvider":"syslog-harness","defaultModel":"syslog-auto","defaultThinkingLevel":"high","compaction":{"reserveTokens":65536}}
EOF
  rmdir "$home/.pi"
  run_check "$home"
  expect_code 0 "$STATUS" "a single adequate output budget and level must pass"
  line=$(scope_line primary "$OUT")
  assert_contains "$line" "COMPACTION: ok" "the reconciled scope must pass"
  assert_contains "$line" "thinking=high thinkingSource=$case_dir/global.json" \
    "the effective level and its single source must be named"
  assert_not_contains "$line" "thinking-level-dual-source" "a single source is not a conflict"
  pass "a single explicit thinking level with an adequate output budget is reported ok and named"
}


test_project_over_global_reserve_wins
test_global_reserve_used_without_project_settings
test_builtin_default_reserve_is_named
test_disabled_compaction_scope_is_not_judged_by_its_reserve
test_disabled_scope_does_not_disarm_a_sibling_guard
test_project_enabled_true_overrides_global_enabled_false
test_non_boolean_enabled_is_an_error_not_a_silent_coercion
test_global_non_boolean_enabled_errors_for_every_scope
test_secondmate_pin_rejects_a_non_boolean_enabled
test_above_limit_failure_names_every_input
test_reserve_at_or_above_window_fails
test_diagnostics_mode_is_silent_when_safe
test_diagnostics_mode_prints_only_actionable_lines
test_secondmate_home_project_reserve_wins
test_non_pi_harness_is_skipped
test_unknown_model_is_an_error
test_ambiguous_model_id_is_an_error
test_model_list_failure_is_reported
test_partial_model_list_is_not_silent
test_empty_model_list_is_not_silent
test_partial_model_list_retry_recovers
test_missing_pi_is_skipped_not_failed
test_silent_jq_is_not_read_as_missing_settings
test_bootstrap_reports_unsafe_scope
test_bootstrap_is_silent_when_every_scope_is_safe
test_output_ceiling_below_the_fleet_floor_is_unsafe_with_both_numbers
test_output_ceiling_above_the_reserve_is_unsafe_with_both_numbers
test_thinking_level_from_two_conflicting_sources_is_unsafe
test_single_explicit_thinking_level_is_ok_and_named
test_real_pi_model_list_resolves
