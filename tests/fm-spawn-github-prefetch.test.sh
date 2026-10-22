#!/usr/bin/env bash
# Drive fm-spawn's executable interface across a server-created shell boundary.
# Only tools/terminals are fixtures: the destination runs real Bash/Fish and Git
# credential plumbing against an explicitly fake gh, with no network or model.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-github-prefetch)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup' EXIT
REAL_GIT=$(type -P git)
FISH_BIN=$(type -P fish) || fail 'fish is required for destination compatibility checks'

make_case() {
  local name="$DEST_SHELL-$1"
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/worktree"
  ID="prefetch-$name"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR")
  fm_test_fake_no_mistakes "$FAKEBIN"
  fm_test_fake_gh_axi "$FAKEBIN"
  fm_test_fake_sleep_noop "$FAKEBIN"
  fm_fake_exit0 "$FAKEBIN" codex
  GH_DIR="$CASE_DIR/gh helper's bin"
  DEST_BIN="$CASE_DIR/destination-bin"
  mkdir -p "$GH_DIR" "$DEST_BIN" "$CASE_DIR/shell-home"

  # Keep the actual origin local. Only the metadata query advertises GitHub;
  # any coordinator-side fetch continues to use the local fixture bare repo.
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *' remote get-url origin') printf 'https://github.com/fixture/prefetch.git\n'; exit 0 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  cat > "$GH_DIR/gh" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'auth git-credential get' ] || exit 91
printf 'native-helper\n' >> "$FM_PREFETCH_CASE/helper-calls"
[ "${FM_PREFETCH_EMPTY:-0}" = 0 ] || exit 0
printf 'username=fixture-user\npassword=fixture-only-not-a-secret\n'
SH
  # If the bridge merely preserves `!gh ...` instead of pinning/quoting the
  # already resolved executable, the destination must NOT use another gh.
  cat > "$DEST_BIN/gh" <<'SH'
#!/usr/bin/env bash
printf 'wrong-helper\n' >> "$FM_PREFETCH_CASE/helper-calls"
exit 92
SH
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$*" = get ] || exit 93
printf 'treehouse-get\n' >> "$FM_PREFETCH_CASE/treehouse-calls"
[ "${GIT_CONFIG_COUNT:-}" = 2 ] || exit 94
[ "${GIT_CONFIG_VALUE_7+x}" != x ] || exit 95
[ "${GIT_TERMINAL_PROMPT:-}" = 0 ] || exit 96
[ "${GIT_ASKPASS:-}" = /bin/false ] || exit 97
reply=$(printf 'protocol=https\nhost=github.com\n\n' | "$FM_REAL_GIT" credential fill)
case "$reply" in
  *username=fixture-user*password=fixture-only-not-a-secret*) ;;
  *) exit 98 ;;
esac
printf 'real-git-credential-flow\n' > "$FM_PREFETCH_CASE/credential-ok"
SH
  cat > "$CASE_DIR/pane.bash" <<'SH'
treehouse() {
  command treehouse "$@" && cd -- "$FM_PREFETCH_WT"
}
eval "$1"
result=$?
pwd > "$FM_PREFETCH_CASE/destination-cwd"
exit "$result"
SH
  cat > "$CASE_DIR/pane.fish" <<'FISH'
function treehouse
  command treehouse $argv
  and cd -- "$FM_PREFETCH_WT"
end
eval "$argv[1]"
set -l result $status
pwd > "$FM_PREFETCH_CASE/destination-cwd"
exit $result
FISH
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_PREFETCH_CASE
case "$*" in
  *'#{pane_current_path}'*)
    if [ -f "$D/destination-cwd" ]; then
      IFS= read -r cwd < "$D/destination-cwd"
      printf '%s\n' "$cwd"
    else printf '%s\n' "$FM_PREFETCH_PROJECT"; fi
    exit 0 ;;
esac
case "${1:-}" in
  new-window|new-session)
    printf 'created\n' >> "$D/endpoints"
    printf '@1\n'
    exit 0 ;;
  list-windows)
    [ -f "$D/endpoints" ] || exit 0
    case "$*" in
      *'#{window_name}'*) printf 'fm-%s\n' "$FM_PREFETCH_TASK" ;;
      *'#{window_id}'*) printf '@1\n' ;;
    esac
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        *'treehouse get')
          printf '%s\n' "$a" > "$D/prefetch-command"
          destination_auth=()
          [ -z "${FM_PREFETCH_DEST_AUTH_ENV:-}" ] || destination_auth=("$FM_PREFETCH_DEST_AUTH_ENV")
          case "$FM_PREFETCH_SHELL" in
            bash) destination=(/bin/bash --noprofile --norc "$D/pane.bash") ;;
            fish) destination=("$FM_PREFETCH_FISH_BIN" --no-config "$D/pane.fish") ;;
            *) exit 99 ;;
          esac
          # A Herdr/tmux server's new shell does not inherit caller Git env.
          # Deliberately drop ALL of it, including the unlisted marker.
          (cd "$FM_PREFETCH_PROJECT" && /usr/bin/env -i \
            HOME="$FM_PREFETCH_DEST_HOME" XDG_CONFIG_HOME="$FM_PREFETCH_DEST_XDG" PATH="$FM_PREFETCH_DEST_PATH" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            FM_REAL_GIT="$FM_REAL_GIT" FM_PREFETCH_CASE="$D" FM_PREFETCH_WT="$FM_PREFETCH_WT" \
            FM_PREFETCH_EMPTY="${FM_PREFETCH_EMPTY:-0}" \
            "${destination_auth[@]}" \
            "${destination[@]}" "$a") > "$D/probe-output" 2>&1
          printf '%s\n' "$?" > "$D/probe-status"
          ;;
      esac
    done
    exit 0 ;;
  has-session|kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/git" "$FAKEBIN/treehouse" "$FAKEBIN/tmux" "$GH_DIR/gh" "$DEST_BIN/gh"
  HELPER='!gh auth git-credential'
  CALLER_TOKEN=
  DEST_AUTH_ENV=
  CALLER_XDG="$CASE_DIR/config root's base"
  DEST_XDG=$CALLER_XDG
  DEST_HOME="$CASE_DIR/shell-home"
  mkdir -p "$CALLER_XDG/gh" "$DEST_HOME/.config/gh" "$HOME_DIR/user-home/.config/gh"
  EMPTY_HELPER=0
  CONFIG_COUNT=2
}

run_case() {
  GH_TOKEN="$CALLER_TOKEN" GITHUB_TOKEN='' GH_CONFIG_DIR='' GH_HOST='' XDG_CONFIG_HOME="$CALLER_XDG" \
    GIT_CONFIG_COUNT="$CONFIG_COUNT" GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
    GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1="$HELPER" \
    GIT_CONFIG_VALUE_7=fixture-unlisted-marker FM_REAL_GIT="$REAL_GIT" \
    FM_PREFETCH_CASE="$CASE_DIR" FM_PREFETCH_TASK="$ID" FM_PREFETCH_PROJECT="$PROJ_DIR" FM_PREFETCH_WT="$WT_DIR" \
    FM_PREFETCH_EMPTY="$EMPTY_HELPER" FM_PREFETCH_DEST_AUTH_ENV="$DEST_AUTH_ENV" \
    FM_PREFETCH_SHELL="$DEST_SHELL" FM_PREFETCH_FISH_BIN="$FISH_BIN" \
    FM_PREFETCH_DEST_HOME="$DEST_HOME" FM_PREFETCH_DEST_XDG="$DEST_XDG" \
    FM_PREFETCH_DEST_PATH="$DEST_BIN:$FAKEBIN:/usr/bin:/bin" \
    PATH="$GH_DIR:$PATH" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
      "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off
}

test_native_helper_reaches_fetch_shell() {
  local out status auth i=0
  for auth in '' GH_TOKEN= GITHUB_TOKEN= GH_CONFIG_DIR= GH_HOST= GH_HOST=github.com; do
    make_case "native-$i"
    DEST_AUTH_ENV=$auth
    out=$(run_case); status=$?
    expect_code 0 "$status" "native helper bridge should permit isolated spawn: $out; destination output: $(< "$CASE_DIR/probe-output")"
    expect_code 0 "$(< "$CASE_DIR/probe-status")" "$DEST_SHELL destination prefetch failed"
    [ "$(< "$CASE_DIR/destination-cwd")" = "$WT_DIR" ] || fail "$DEST_SHELL lost Treehouse's parent-shell directory transition"
    [ -f "$CASE_DIR/credential-ok" ] || fail "real Git never reached the selected fake native helper: $out"
    assert_grep 'real-git-credential-flow' "$CASE_DIR/credential-ok" "credential flow did not complete"
    assert_grep 'native-helper' "$CASE_DIR/helper-calls" "selected helper was not called"
    assert_no_grep 'wrong-helper' "$CASE_DIR/helper-calls" "destination selected a different helper"
    assert_no_grep 'fixture-unlisted-marker' "$CASE_DIR/prefetch-command" "arbitrary caller environment was copied"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$ID.meta" "spawn did not preserve isolated worktree verification"
    pass "$DEST_SHELL preserves the parent-shell directory transition and native helper with authentication '${auth:-unset}'"
    i=$((i + 1))
  done
}

test_destination_auth_overrides_refuse_before_treehouse() {
  local out status variable marker=fixture-destination-override-not-real
  for variable in GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR GH_HOST; do
    make_case "destination-$variable"
    DEST_AUTH_ENV="$variable=$marker"
    out=$(run_case); status=$?
    [ "$status" -ne 0 ] || fail "$variable destination override launched a worker"
    [ -f "$CASE_DIR/probe-status" ] || fail "$variable never reached the destination shell"
    [ "$(< "$CASE_DIR/probe-status")" -ne 0 ] || fail "$variable destination override was accepted"
    [ "$(< "$CASE_DIR/destination-cwd")" = "$PROJ_DIR" ] || fail "$DEST_SHELL changed directory on credential refusal"
    [ ! -e "$CASE_DIR/treehouse-calls" ] || fail "$variable destination override reached Treehouse"
    [ ! -e "$CASE_DIR/helper-calls" ] || fail "$variable destination override reached a credential helper"
    [ ! -e "$CASE_DIR/credential-ok" ] || fail "$variable destination override completed credential lookup"
    [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "$variable destination override published a worker record"
    assert_grep 'refuses unsupported destination gh authentication environment' "$CASE_DIR/probe-output" "missing destination authentication refusal"
    case "$out" in *"$marker"*) fail "$variable value leaked into spawn diagnostics" ;; esac
    assert_no_grep "$marker" "$CASE_DIR/probe-output" "$variable value leaked into destination diagnostics"
    assert_no_grep "$marker" "$CASE_DIR/prefetch-command" "$variable value was copied into the command"
    pass "$DEST_SHELL rejects $variable before Treehouse without exposing its value or changing directory"
  done
}

test_matching_effective_config_roots() {
  local context out status
  for context in home-fallback xdg-to-home home-to-xdg equivalent-xdg; do
    make_case "matching-$context"
    case "$context" in
      home-fallback) CALLER_XDG=; DEST_XDG=; DEST_HOME="$HOME_DIR/user-home" ;;
      xdg-to-home) CALLER_XDG="$HOME_DIR/user-home/.config"; DEST_XDG=; DEST_HOME="$HOME_DIR/user-home" ;;
      home-to-xdg) CALLER_XDG=; DEST_XDG="$HOME_DIR/user-home/.config" ;;
      equivalent-xdg) DEST_XDG="$CALLER_XDG/./" ;;
    esac
    out=$(run_case); status=$?
    expect_code 0 "$status" "$DEST_SHELL rejected matching effective roots ($context): $out"
    expect_code 0 "$(< "$CASE_DIR/probe-status")" "$DEST_SHELL matching-root prefetch failed"
    [ "$(< "$CASE_DIR/destination-cwd")" = "$WT_DIR" ] || fail "$DEST_SHELL matching roots lost the shell directory transition"
    assert_grep native-helper "$CASE_DIR/helper-calls" 'matching roots never reached the selected helper'
    [ -f "$CASE_DIR/credential-ok" ] || fail 'matching roots did not complete credential lookup'
    pass "$DEST_SHELL accepts matching effective roots through $context"
  done
}

test_destination_config_root_mismatch_refuses() {
  local context out status other marker=fixture-private-root
  for context in xdg-to-xdg xdg-to-home home-to-xdg home-to-home relative-xdg missing-xdg; do
    make_case "root-$context"
    other="$CASE_DIR/$marker"
    mkdir -p "$other/gh" "$other/.config/gh"
    case "$context" in
      xdg-to-xdg) DEST_XDG=$other ;;
      xdg-to-home) DEST_XDG=; DEST_HOME=$other ;;
      home-to-xdg) CALLER_XDG=; DEST_XDG=$other ;;
      home-to-home) CALLER_XDG=; DEST_XDG=; DEST_HOME=$other ;;
      relative-xdg) DEST_XDG=$marker ;;
      missing-xdg) DEST_XDG="$other/missing" ;;
    esac
    out=$(run_case); status=$?
    [ "$status" -ne 0 ] || fail "$DEST_SHELL accepted a different or indeterminate configuration root ($context)"
    [ -f "$CASE_DIR/probe-status" ] || fail "$DEST_SHELL never checked the destination root ($context)"
    [ "$(< "$CASE_DIR/probe-status")" -ne 0 ] || fail 'destination root rejection reported success'
    [ "$(< "$CASE_DIR/destination-cwd")" = "$PROJ_DIR" ] || fail 'root rejection changed the destination directory'
    [ ! -e "$CASE_DIR/treehouse-calls" ] || fail 'root rejection reached Treehouse'
    [ ! -e "$CASE_DIR/helper-calls" ] || fail 'root rejection reached a credential helper'
    [ ! -e "$CASE_DIR/credential-ok" ] || fail 'root rejection completed credential lookup'
    [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail 'root rejection published a worker record'
    assert_grep 'gh configuration root' "$CASE_DIR/probe-output" 'missing root refusal diagnostic'
    case "$out" in *"$marker"*) fail 'destination root leaked into spawn diagnostics' ;; esac
    assert_no_grep "$marker" "$CASE_DIR/probe-output" 'destination root leaked into the guard diagnostic'
    assert_no_grep "$marker" "$CASE_DIR/prefetch-command" 'destination root was copied into the command'
    pass "$DEST_SHELL rejects $context configuration roots before Treehouse without disclosure"
  done
}

test_indeterminate_caller_root_refuses() {
  local context out status marker=fixture-indeterminate-root
  for context in relative missing; do
    make_case "caller-root-$context"
    case "$context" in
      relative) CALLER_XDG=$marker ;;
      missing) CALLER_XDG="$CASE_DIR/$marker" ;;
    esac
    out=$(run_case); status=$?
    [ "$status" -ne 0 ] || fail 'an indeterminate caller root was accepted'
    [ ! -e "$CASE_DIR/endpoints" ] || fail 'an indeterminate caller root created an endpoint'
    [ ! -e "$CASE_DIR/treehouse-calls" ] || fail 'an indeterminate caller root reached Treehouse'
    [ ! -e "$CASE_DIR/helper-calls" ] || fail 'an indeterminate caller root reached the helper'
    assert_contains "$out" 'cannot determine gh configuration root' 'missing caller root refusal'
    case "$out" in *"$marker"*) fail 'caller root leaked into diagnostics' ;; esac
    pass "$DEST_SHELL rejects $context caller roots before endpoint creation"
  done
}

test_missing_bridge_never_launches_worker() {
  local out status
  make_case absent
  CONFIG_COUNT=0
  out=$(run_case); status=$?
  [ "$status" -ne 0 ] || fail "missing helper bridge incorrectly launched a worker"
  [ ! -f "$HOME_DIR/state/$ID.meta" ] || fail "failed isolation published a worker record"
  grep -Fxq 'treehouse get' "$CASE_DIR/prefetch-command" || fail "non-opted-in command changed"
  pass "$DEST_SHELL without the bridge retains ordinary behavior and cannot bypass isolation"
}

test_missing_destination_auth_cannot_prompt() {
  local out status
  make_case signed-out
  EMPTY_HELPER=1
  out=$(run_case); status=$?
  [ "$status" -ne 0 ] || fail "missing destination authentication incorrectly launched a worker"
  [ ! -f "$HOME_DIR/state/$ID.meta" ] || fail "failed authentication published a worker record"
  assert_grep 'native-helper' "$CASE_DIR/helper-calls" "authentication fixture never exercised the helper"
  assert_grep 'terminal prompts disabled' "$CASE_DIR/probe-output" "missing authentication was not rejected noninteractively"
  pass "$DEST_SHELL missing destination authentication refuses without asking for credentials"
}

test_arbitrary_helper_is_not_transferred() {
  local out status
  make_case arbitrary
  HELPER='!fixture-unsupported-helper-with-private-marker'
  out=$(run_case); status=$?
  [ "$status" -ne 0 ] || fail "an arbitrary helper was accepted"
  [ ! -f "$CASE_DIR/endpoints" ] || fail "unsupported helper created an endpoint"
  assert_contains "$out" 'supports only the existing native gh' "missing explicit helper refusal"
  case "$out" in *fixture-unsupported-helper-with-private-marker*) fail "helper value leaked into diagnostics" ;; esac
  pass "$DEST_SHELL arbitrary helper is refused before endpoint creation without printing its value"
}

test_secret_auth_environment_is_not_transferred_or_replaced() {
  local out status
  make_case token
  CALLER_TOKEN=fixture-token-not-real
  out=$(run_case); status=$?
  [ "$status" -ne 0 ] || fail "token-only authentication was silently replaced"
  [ ! -f "$CASE_DIR/endpoints" ] || fail "unsupported authentication created an endpoint"
  assert_contains "$out" 'refusing to choose a different credential store' "missing authentication-scope refusal"
  case "$out" in *fixture-token-not-real*) fail "token value leaked into diagnostics" ;; esac
  pass "$DEST_SHELL token environment is neither copied nor silently replaced by another account store"
}

for DEST_SHELL in bash fish; do
  test_native_helper_reaches_fetch_shell
  test_destination_auth_overrides_refuse_before_treehouse
  test_matching_effective_config_roots
  test_destination_config_root_mismatch_refuses
  test_indeterminate_caller_root_refuses
  test_missing_bridge_never_launches_worker
  test_missing_destination_auth_cannot_prompt
  test_arbitrary_helper_is_not_transferred
  test_secret_auth_environment_is_not_transferred_or_replaced
done
