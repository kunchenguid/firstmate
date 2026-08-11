#!/usr/bin/env bash
# Pool HOME substitution must not hide the operator's git and gh configuration.
#
# fm-spawn.sh leases the task worktree by running `treehouse get` under a pool
# HOME, so the pool lands on the repo's own filesystem. That lease performs a
# `git fetch origin`, and over HTTPS the fetch authenticates through git's global
# config (the credential helper) and, when that helper is `gh auth git-credential`,
# through gh's own stored credentials. Both are discovered only through HOME, so
# the substitution made every spawn fail with "could not read Username for
# 'https://github.com'" while the identical fetch succeeded in an ordinary shell.
#
# fm_treehouse_preserve_user_config pins those two locations from the REAL HOME.
# These tests pin:
#   1. It exports both locations when neither is already set.
#   2. It prefers an existing ~/.gitconfig and falls back to the XDG location,
#      so an XDG-only operator is never pointed at a missing ~/.gitconfig.
#   3. It never overrides values the operator already set.
#   4. It pins nothing that does not exist, so a missing path is not invented.
#   5. fm-spawn.sh calls it on the lease path, before HOME is substituted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-treehouse-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# shellcheck source=/dev/null
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-user-config)

# Run fm_treehouse_preserve_user_config in a subshell with a synthetic HOME and
# report what it exported, so no case can leak environment into the next one.
# <home> <xdg-or-empty> <preset-git-config-global> <preset-gh-config-dir>
run_preserve() {
  local home=$1 xdg=$2 preset_git=$3 preset_gh=$4
  (
    HOME=$home
    export HOME
    if [ -n "$xdg" ]; then XDG_CONFIG_HOME=$xdg; export XDG_CONFIG_HOME; else unset XDG_CONFIG_HOME; fi
    if [ -n "$preset_git" ]; then GIT_CONFIG_GLOBAL=$preset_git; export GIT_CONFIG_GLOBAL; else unset GIT_CONFIG_GLOBAL; fi
    if [ -n "$preset_gh" ]; then GH_CONFIG_DIR=$preset_gh; export GH_CONFIG_DIR; else unset GH_CONFIG_DIR; fi
    fm_treehouse_preserve_user_config
    printf 'git=%s\ngh=%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GH_CONFIG_DIR:-}"
  )
}

# A home with a classic ~/.gitconfig and a ~/.config/gh directory.
make_classic_home() {  # <dir>
  local home=$1
  mkdir -p "$home/.config/gh"
  : > "$home/.gitconfig"
  printf '%s\n' "$home"
}

# A home whose git config lives only at the XDG location.
make_xdg_home() {  # <dir>
  local home=$1
  mkdir -p "$home/.config/git" "$home/.config/gh"
  : > "$home/.config/git/config"
  printf '%s\n' "$home"
}

test_pins_both_locations_from_the_real_home() {
  local home out
  home=$(make_classic_home "$TMP_ROOT/classic")
  out=$(run_preserve "$home" "" "" "")
  assert_contains "$out" "git=$home/.gitconfig" \
    "an unset GIT_CONFIG_GLOBAL should be pinned to the real home's .gitconfig"
  assert_contains "$out" "gh=$home/.config/gh" \
    "an unset GH_CONFIG_DIR should be pinned to the real home's gh config dir"
  pass "fm_treehouse_preserve_user_config: pins git and gh config from the real HOME"
}

test_falls_back_to_the_xdg_git_config() {
  local home out
  home=$(make_xdg_home "$TMP_ROOT/xdg")
  out=$(run_preserve "$home" "" "" "")
  assert_contains "$out" "git=$home/.config/git/config" \
    "an XDG-only operator should be pinned to the XDG git config, not a missing ~/.gitconfig"
  assert_not_contains "$out" "git=$home/.gitconfig" \
    "a nonexistent ~/.gitconfig must never be pinned"
  pass "fm_treehouse_preserve_user_config: falls back to the XDG git config"
}

test_honours_an_explicit_xdg_config_home() {
  local home xdg out
  home=$TMP_ROOT/xdgenv
  xdg=$TMP_ROOT/xdgenv-config
  mkdir -p "$home" "$xdg/git" "$xdg/gh"
  : > "$xdg/git/config"
  out=$(run_preserve "$home" "$xdg" "" "")
  assert_contains "$out" "git=$xdg/git/config" \
    "an explicit XDG_CONFIG_HOME should select the git config under it"
  assert_contains "$out" "gh=$xdg/gh" \
    "an explicit XDG_CONFIG_HOME should select the gh config dir under it"
  pass "fm_treehouse_preserve_user_config: honours an explicit XDG_CONFIG_HOME"
}

test_never_overrides_operator_values() {
  local home out
  home=$(make_classic_home "$TMP_ROOT/preset")
  out=$(run_preserve "$home" "" "/operator/gitconfig" "/operator/gh")
  assert_contains "$out" "git=/operator/gitconfig" \
    "an operator's own GIT_CONFIG_GLOBAL must win"
  assert_contains "$out" "gh=/operator/gh" \
    "an operator's own GH_CONFIG_DIR must win"
  pass "fm_treehouse_preserve_user_config: an operator's own values are never overridden"
}

test_pins_nothing_that_does_not_exist() {
  local home out
  home=$TMP_ROOT/bare
  mkdir -p "$home"
  out=$(run_preserve "$home" "" "" "")
  assert_contains "$out" "git=" "a home with no git config should leave GIT_CONFIG_GLOBAL unset"
  assert_not_contains "$out" "git=$home" "a nonexistent git config path must not be invented"
  assert_not_contains "$out" "gh=$home" "a nonexistent gh config dir must not be invented"
  pass "fm_treehouse_preserve_user_config: pins nothing that does not exist"
}

# The guarantee is worthless if the lease path stops calling it, and the call has
# to come BEFORE the HOME substitution or it reads the pool HOME instead.
test_spawn_calls_it_before_substituting_home() {
  local line
  # Match the executable lease line, not the prose in the script's own --help.
  line=$(grep -n 'treehouse get --lease' "$SPAWN" | grep -v ':[[:space:]]*#' | head -n 1)
  [ -n "$line" ] || fail "could not find the lease call in $SPAWN"
  assert_contains "$line" "fm_treehouse_preserve_user_config" \
    "the lease call must preserve the operator's git and gh config"
  case "$line" in
    *fm_treehouse_preserve_user_config*HOME=*) : ;;
    *) fail "fm_treehouse_preserve_user_config must run BEFORE HOME is substituted"$'\n'"--- line ---"$'\n'"$line" ;;
  esac
  pass "fm-spawn.sh: the lease preserves git and gh config before substituting HOME"
}

test_pins_both_locations_from_the_real_home
test_falls_back_to_the_xdg_git_config
test_honours_an_explicit_xdg_config_home
test_never_overrides_operator_values
test_pins_nothing_that_does_not_exist
test_spawn_calls_it_before_substituting_home
