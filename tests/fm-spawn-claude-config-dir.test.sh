#!/usr/bin/env bash
# Behavior tests for the claude crewmate CLAUDE_CONFIG_DIR launch knob (#599).
#
# On a multi-account machine the default ~/.claude can be empty/unauthenticated,
# so a bare-`claude` crewmate lands on the login wall and never starts. The local,
# gitignored config/crew-config-dir file names the config dir a claude crewmate
# should authenticate with; when set, fm-spawn prefixes the claude launch command
# with `CLAUDE_CONFIG_DIR=<dir> `. These tests drive a real claude ship spawn
# through fm-spawn.sh with a fake tmux that records the literal launch string, and
# pin behavior on real values:
#   1. config/crew-config-dir set  -> the launch gains the CLAUDE_CONFIG_DIR prefix.
#   2. config/crew-config-dir absent -> NO prefix, i.e. byte-identical prior
#      behavior (bare `claude`, default config dir).
#   3. a leading `~`/`~/` resolves to $HOME in the launch (captain's real value).
#   4. `$HOME`/`${HOME}` resolves to the home directory in the launch.
#   5. a plain absolute path (no ~/$HOME) passes through unchanged.
#   6. shell metacharacters in the value stay single-quoted, never re-parsed
#      or executed at launch (injection guard).
#   7. blank and `#` comment lines above the value are skipped, matching the
#      single-value reader config/backend and config/secondmate-harness use.
set -u

# shellcheck source=tests/fm-spawn-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-ccd)

# Build one isolated case (home + project + worktree + fakebin), returning its
# fields. Each case gets a fresh id so state/data never collide across cases.
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_spawn_fakebin "$case_dir/fake" gh-axi gh)
  id="ccd-$name-x1"
  fm_spawn_home_skeleton "$home"
  fm_spawn_seed_task "$home" "$id"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

# Drive a real claude ship spawn and echo the recorded launch string.
run_claude_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 send_log=$6 out
  out=$(fm_spawn_run "$home" "$wt" "$fakebin" "$send_log" "$id" "$proj" claude) \
    || { echo "SPAWN-FAILED: $out" >&2; return 1; }
  cat "$send_log"
}

test_config_dir_adds_prefix() {
  local rec case_dir home proj wt fakebin id send_log ccd launch
  rec=$(make_spawn_case with-knob)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  ccd="$case_dir/alt-claude-home"
  printf '%s\n' "$ccd" > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with config/crew-config-dir failed"

  # The prefix must sit between the ghost-text env var and the claude verb, with
  # the config dir shell-quoted (single quotes, no special chars in the path).
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$ccd' claude --dangerously-skip-permissions "*) : ;;
    *) fail "launch missing CLAUDE_CONFIG_DIR prefix"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "config/crew-config-dir prefixes the claude launch with CLAUDE_CONFIG_DIR"
}

test_absent_knob_is_backward_compatible() {
  local rec case_dir home proj wt fakebin id send_log launch
  rec=$(make_spawn_case no-knob)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # No config/crew-config-dir file: the launch must be identical to prior behavior.
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn without config/crew-config-dir failed"

  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR" "absent knob must not add a CLAUDE_CONFIG_DIR prefix"
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "*) : ;;
    *) fail "absent knob changed the bare-claude launch prefix"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "absent config/crew-config-dir keeps the bare-claude launch byte-identical"
}

test_config_dir_expands_tilde() {
  local rec case_dir home proj wt fakebin id send_log launch exp
  rec=$(make_spawn_case tilde)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # The captain's real-world value: a home-relative ~ path.
  # shellcheck disable=SC2088  # A literal ~ must be written to the file, not expanded here.
  printf '%s\n' '~/.claude-account2' > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"
  exp="$HOME/.claude-account2"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with a ~ config dir failed"

  # A leading ~ must resolve to the real $HOME in the launch, shell-quoted, and
  # the literal tilde must never survive into the launch string.
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$exp' claude --dangerously-skip-permissions "*) : ;;
    *) fail "launch did not expand a leading ~ to \$HOME"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  assert_not_contains "$launch" "'~/.claude-account2'" "a leading ~ must not reach the launch literally"
  pass "config/crew-config-dir expands a leading ~ to the home directory"
}

test_config_dir_expands_home_var() {
  local rec case_dir home proj wt fakebin id send_log launch exp
  rec=$(make_spawn_case home-var)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # The captain's real-world value uses $HOME literally in the file.
  # shellcheck disable=SC2016  # A literal $HOME must be written to the file, not expanded here.
  printf '%s\n' '$HOME/.claude-account2' > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"
  exp="$HOME/.claude-account2"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with a \$HOME config dir failed"

  # $HOME must resolve to the real home in the launch; the literal token must not survive.
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$exp' claude --dangerously-skip-permissions "*) : ;;
    *) fail "launch did not expand \$HOME to the home directory"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  # shellcheck disable=SC2016  # Asserting the literal token $HOME is absent from the launch.
  assert_not_contains "$launch" '$HOME' "a \$HOME reference must not reach the launch literally"
  pass "config/crew-config-dir expands \$HOME to the home directory"
}

test_config_dir_plain_path_unchanged() {
  local rec case_dir home proj wt fakebin id send_log launch plain
  rec=$(make_spawn_case plain-path)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # A plain absolute path with no ~ / $HOME must pass through untouched by expansion.
  plain="$case_dir/plain-claude-home"
  printf '%s\n' "$plain" > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with a plain absolute config dir failed"

  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$plain' claude --dangerously-skip-permissions "*) : ;;
    *) fail "a plain absolute path was altered by expansion"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "a plain absolute path with no ~/\$HOME passes through unchanged"
}

test_config_dir_metachars_stay_quoted() {
  local rec case_dir home proj wt fakebin id send_log launch evil
  rec=$(make_spawn_case metachars)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # A value carrying shell metacharacters (`;`, whitespace, a command
  # substitution) must be emitted as one single-quoted token so nothing is
  # re-parsed or executed at launch. No ~ / $HOME here, so only quoting is under
  # test. The \$ is escaped so the test itself never runs `id`; the file gets a
  # literal `$(id)`.
  evil="$case_dir/cfg; touch $case_dir/PWNED \$(id)"
  printf '%s\n' "$evil" > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with a metacharacter config dir failed"

  # The whole dangerous value must appear verbatim inside a single-quoted token,
  # proving the shell that runs the launch would treat `$(id)`/`;` as literal.
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$evil' claude --dangerously-skip-permissions "*) : ;;
    *) fail "metacharacter value was not fully single-quoted"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "shell metacharacters in the config dir stay single-quoted (injection guard)"
}

test_config_dir_skips_blank_and_comment_lines() {
  local rec case_dir home proj wt fakebin id send_log launch ccd
  rec=$(make_spawn_case blank-and-comment)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # A leading blank line (an editor-added newline) must not blank the knob, and a
  # leading `#` comment must never become the config dir itself - the same
  # first-non-empty-non-comment-line reader config/backend and
  # config/secondmate-harness use.
  ccd="$case_dir/commented-claude-home"
  printf '\n  \n# the authenticated account for crewmates\n%s\n' "$ccd" \
    > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with blank and comment lines failed"

  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CONFIG_DIR='$ccd' claude --dangerously-skip-permissions "*) : ;;
    *) fail "blank/comment lines were not skipped by the config reader"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  assert_not_contains "$launch" "the authenticated account for crewmates" \
    "a comment line must never reach the launch as the config dir"
  pass "blank and comment lines above the value are skipped, not taken as the config dir"
}

test_comment_only_file_is_backward_compatible() {
  local rec case_dir home proj wt fakebin id send_log launch
  rec=$(make_spawn_case comment-only)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  # A file with no real value must behave exactly like an absent file.
  printf '\n# no config dir chosen yet\n' > "$home/config/crew-config-dir"
  send_log="$case_dir/launch.log"

  launch=$(run_claude_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$send_log") \
    || fail "claude spawn with a comment-only config file failed"

  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR" "a comment-only knob must not add a CLAUDE_CONFIG_DIR prefix"
  case "$launch" in
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "*) : ;;
    *) fail "comment-only knob changed the bare-claude launch prefix"$'\n'"--- launch ---"$'\n'"$launch" ;;
  esac
  pass "a blank/comment-only config/crew-config-dir keeps the bare-claude launch byte-identical"
}

test_config_dir_adds_prefix
test_absent_knob_is_backward_compatible
test_config_dir_expands_tilde
test_config_dir_expands_home_var
test_config_dir_plain_path_unchanged
test_config_dir_metachars_stay_quoted
test_config_dir_skips_blank_and_comment_lines
test_comment_only_file_is_backward_compatible
