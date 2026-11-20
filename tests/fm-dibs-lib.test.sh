#!/usr/bin/env bash
# tests/fm-dibs-lib.test.sh - the optional dibs task scope (bin/fm-dibs-lib.sh):
# a home without the config/dibs-scopes flag never calls dibs during a real
# spawn, an opted-in home without dibs or with scopes off is untouched, a
# retained member refuses teardown, the exec owner keeps any state path
# literal, and - where dibs and treehouse are installed - the real
# spawn-to-teardown lifecycle against a scratch dibs state and treehouse pool,
# plus a real bin/fm-spawn.sh run whose emitted launch is executed.
# Each case scopes its environment to a subshell on purpose.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-dibs-lib.sh"

TMP=$(fm_test_tmproot fm-dibs-lib)

# A fake dibs ahead of every other tool on PATH: it logs each call and answers
# from FAKE_DIBS_<verb> exit codes and canned JSON.
fake_dibs_path() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat >"$fakebin/dibs" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIBS_LOG"
case "$1 ${2:-}" in
  'scope show') [ -z "${FAKE_DIBS_SHOW_JSON:-}" ] || printf '%s\n' "$FAKE_DIBS_SHOW_JSON"; exit "${FAKE_DIBS_SHOW:-0}" ;;
  release*) echo '{"reason":"resource_busy"}'; exit "${FAKE_DIBS_RELEASE:-0}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/dibs"
  printf '%s:%s\n' "$fakebin" "$PATH"
}

# A dibs that must never run: any call leaves a marker and fails.
tripwire_dibs() {  # <fakebin> <marker>
  cat >"$1/dibs" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>'$2'
exit 99
SH
  chmod +x "$1/dibs"
}

test_flag_absent_spawn_never_calls_dibs() {
  local dir="$TMP/noflag" home proj fakebin out
  home="$dir/home" proj="$dir/project"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  tripwire_dibs "$fakebin" "$dir/dibs-called"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$dir/wt" wt-noflag
  fm_test_spawn_brief "$home" noflag1
  [ ! -e "$home/config/dibs-scopes" ] || fail "the fixture home must start without the opt-in flag"
  (
    unset DIBS_SCOPES
    out=$(fm_test_run_spawn "$home" "$dir/wt" "$fakebin" noflag1 "$proj" --mode no-mistakes --yolo off)
    expect_code 0 "$?" "a spawn without config/dibs-scopes must succeed even though dibs fails: $out"
    [ ! -e "$dir/dibs-called" ] || fail "a home without config/dibs-scopes called dibs: $(cat "$dir/dibs-called")"
  ) || exit 1
  pass "a home without config/dibs-scopes spawns without ever calling dibs"
}

# The exec owner is run by /bin/sh, so every character a home path can contain
# must stay literal: spaces, both quotes, $, backticks, command substitution,
# and newlines, including one that ends the state directory's own name.
test_owner_quotes_any_state_path() {
  local dir="$TMP/quote" base state owner key
  base="$dir/home it's \"q\" \$HOME \`touch $dir/pwned-bt\` \$(touch $dir/pwned-cs)
nl"
  for state in "$base/state" "$base/st
"; do
    mkdir -p "$state"
    : >"$state/t1.meta"
    owner=$(fm_dibs_scope_owner "$state" t1) || fail "no owner for a path with special characters"
    case "$owner" in exec:*) ;; *) fail "owner lost its exec: prefix: $owner" ;; esac
    /bin/sh -c "${owner#exec:}" || fail "the owner reads dead while the task record exists: $owner"
    mv "$state/t1.meta" "$state/t1.meta.gone"
    if /bin/sh -c "${owner#exec:}"; then
      fail "the owner reads alive after the task record is gone: $owner"
    fi
    key=$(fm_dibs_scope_key "$state" t1) || fail "no key for a path with special characters"
    case "$key" in fm-[0-9a-f]*-t1) ;; *) fail "malformed key: $key" ;; esac
  done
  [ "$(fm_dibs_scope_key "$base/state" t1)" != "$(fm_dibs_scope_key "$base/st
" t1)" ] || fail "distinct state paths must give distinct keys"
  [ ! -e "$dir/pwned-bt" ] && [ ! -e "$dir/pwned-cs" ] || fail "the state path was executed by the owner probe"
  if command -v dibs >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    mkdir -p "$dir/xdg/dibs" "$dir/dibs"
    printf '{"scopes":true,"exec_owner":true,"lease_policies":true}\n' >"$dir/xdg/dibs/config.json"
    (
      export XDG_CONFIG_HOME="$dir/xdg" DIBS_STATE="$dir/dibs"
      unset DIBS_SCOPES DIBS_EXEC_OWNER DIBS_LEASE_POLICIES DIBS_CONSUMER_CONTRACT
      state="$base/state"
      mv "$state/t1.meta.gone" "$state/t1.meta"
      fm_dibs_scope_start "$state" t1 || fail "real dibs refused a scope for a path with special characters"
      [ "$(dibs scope show "$FM_DIBS_SCOPE" --json | jq -r .scope.liveness)" = alive ] ||
        fail "real dibs reads the owner dead while the task record exists"
      mv "$state/t1.meta" "$state/t1.meta.gone"
      [ "$(dibs scope show "$FM_DIBS_SCOPE" --json | jq -r .scope.liveness)" = dead ] ||
        fail "real dibs reads the owner alive after the task record is gone"
    ) || exit 1
    [ ! -e "$dir/pwned-bt" ] && [ ! -e "$dir/pwned-cs" ] || fail "real dibs executed the state path"
  fi
  pass "the exec owner keeps spaces, quotes, \$, backticks, and newlines in the state path literal"
}

test_without_dibs_nothing_runs() {
  local dir="$TMP/nodibs"
  mkdir -p "$dir/state"
  (
    PATH=/usr/bin:/bin
    ! command -v dibs >/dev/null 2>&1 || fail "the stripped PATH still finds a dibs"
    fm_dibs_scope_start "$dir/state" t1 || fail "scope start without dibs must succeed"
    [ -z "$FM_DIBS_SCOPE" ] || fail "scope start without dibs set a scope: $FM_DIBS_SCOPE"
    fm_dibs_release_members "$dir/state" t1 "$dir/wt" 0 || fail "member release without dibs must succeed"
    fm_dibs_scope_end "$dir/state" t1 2>"$dir/err" || fail "scope end without dibs must succeed"
    [ ! -s "$dir/err" ] || fail "scope end without dibs printed: $(cat "$dir/err")"
  ) || exit 1
  pass "a home without dibs neither starts, releases, nor ends a scope"
}

test_scopes_off_only_reads() {
  local dir="$TMP/off" path
  mkdir -p "$dir/state"
  path=$(fake_dibs_path "$dir")
  (
    PATH=$path FAKE_DIBS_LOG="$dir/log" FAKE_DIBS_SHOW=2
    export FAKE_DIBS_LOG FAKE_DIBS_SHOW
    fm_dibs_scope_start "$dir/state" t1 || fail "scope start with scopes off must succeed"
    [ -z "$FM_DIBS_SCOPE" ] || fail "scopes off still set a scope"
    fm_dibs_release_members "$dir/state" t1 "$dir/wt" 0 || fail "member release with scopes off must succeed"
    fm_dibs_scope_end "$dir/state" t1 || fail "scope end with scopes off must succeed"
    if grep -v '^scope show ' "$dir/log"; then
      fail "scopes off ran more than the read-only probe"
    fi
  ) || exit 1
  pass "with dibs scopes off, only the read-only scope probe runs"
}

test_retained_member_refuses_teardown() {
  local dir="$TMP/retained" path json
  mkdir -p "$dir/state"
  path=$(fake_dibs_path "$dir")
  json=$(cat <<'JSON'
{"id":"abc123","count":2,"records":[{"id":"lab1","resource":{"adapter":"compose"}},{"id":"wt1","resource":{"adapter":"treehouse-worktree","path":"/pool/1/app"}}]}
JSON
)
  (
    PATH=$path FAKE_DIBS_LOG="$dir/log" FAKE_DIBS_SHOW_JSON=$json FAKE_DIBS_RELEASE=3
    export FAKE_DIBS_LOG FAKE_DIBS_SHOW_JSON FAKE_DIBS_RELEASE
    if fm_dibs_release_members "$dir/state" t1 /pool/1/app 0 2>"$dir/err"; then
      fail "a member dibs retains must refuse teardown"
    fi
    grep -q 'REFUSED: .*lab1 (compose)' "$dir/err" || fail "refusal does not name the retained lease: $(cat "$dir/err")"
    grep -qx 'release lab1 --confirm --json' "$dir/log" || fail "the compose member was not released: $(cat "$dir/log")"
    if grep -q '^release wt1' "$dir/log"; then
      fail "the task worktree is released by teardown's own return, not by dibs"
    fi
    FAKE_DIBS_RELEASE=0
    fm_dibs_release_members "$dir/state" t1 /pool/1/app 1 || fail "a released member must let teardown continue"
    FAKE_DIBS_SHOW=1 FAKE_DIBS_SHOW_JSON='{"reason":"wrong_machine"}'
    export FAKE_DIBS_SHOW
    if fm_dibs_release_members "$dir/state" t1 /pool/1/app 0 2>/dev/null; then
      fail "an unreadable scope must refuse teardown"
    fi
  ) || exit 1
  pass "teardown refuses while dibs retains a scope member or cannot read the scope, and never releases the task worktree"
}

test_real_dibs_lifecycle() {
  local dir="$TMP/real" wt key lease_id
  if ! command -v dibs >/dev/null 2>&1 || ! command -v treehouse >/dev/null 2>&1; then
    pass "SKIP real dibs lifecycle: dibs or treehouse is not installed"
    return 0
  fi
  mkdir -p "$dir/xdg/dibs" "$dir/state" "$dir/dibs"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/repo" 2>/dev/null
  git -C "$dir/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$dir/repo" push -q origin HEAD:main
  printf '{"scopes":true,"exec_owner":true,"lease_policies":true,"consumer_contract":true,"treehouse_worktree_adapter":true}\n' \
    >"$dir/xdg/dibs/config.json"
  (
    export XDG_CONFIG_HOME="$dir/xdg" DIBS_STATE="$dir/dibs" TREEHOUSE_ROOT="$dir/pool"
    unset DIBS_SCOPES DIBS_EXEC_OWNER DIBS_LEASE_POLICIES DIBS_CONSUMER_CONTRACT DIBS_TREEHOUSE_WORKTREE
    : >"$dir/state/t1.meta"
    wt=$(cd "$dir/repo" && treehouse get --lease --lease-holder t1 2>/dev/null) || fail "scratch treehouse lease failed"
    fm_dibs_scope_start "$dir/state" t1 || fail "scope start refused in an opted-in home"
    scope=$FM_DIBS_SCOPE
    fm_dibs_adopt_worktree "$scope" "$dir/state" t1 "$wt" "$dir/repo" || fail "worktree adoption failed"
    fm_dibs_scope_start "$dir/state" t1 && [ "$FM_DIBS_SCOPE" = "$scope" ] || fail "relaunch did not rejoin the scope"
    fm_dibs_adopt_worktree "$scope" "$dir/state" t1 "$wt" "$dir/repo" || fail "relaunch adoption was not idempotent"
    key=$(fm_dibs_scope_key "$dir/state" t1)
    lease_id=$(dibs scope show --key "$key" --json | jq -r --arg wt "$wt" '.records[] | select(.resource.path == $wt) | .id')
    [ -n "$lease_id" ] || fail "the task worktree is not a scope member"
    dibs create --owner "scope:$scope" --resources lab --json >/dev/null || fail "member create failed"
    fm_dibs_release_members "$dir/state" t1 "$wt" 0 || fail "phase one refused with a releasable member"
    [ "$(dibs scope show --key "$key" --json | jq -r '[.records[].id] | join(" ")')" = "$lease_id" ] ||
      fail "phase one must leave exactly the task worktree"
    (cd "$dir/repo" && treehouse return --force "$wt" >/dev/null 2>&1 </dev/null) || fail "scratch return failed"
    fm_dibs_scope_end "$dir/state" t1 2>"$dir/err" || fail "scope end failed"
    [ ! -s "$dir/err" ] || fail "scope end warned after the return: $(cat "$dir/err")"
    [ "$(dibs scope show --key "$key" --json | jq -r .reason)" = not_found ] || fail "the scope outlived teardown"

    printf '{"scopes":true,"exec_owner":true}\n' >"$dir/xdg/dibs/config.json"
    : >"$dir/state/t2.meta"
    if fm_dibs_scope_start "$dir/state" t2 2>"$dir/err"; then
      fail "a time-bound scope must refuse the spawn"
    fi
    grep -q 'not owner-bound' "$dir/err" || fail "time-bound refusal unexplained: $(cat "$dir/err")"
    printf '{"scopes":true,"exec_owner":true,"lease_policies":true}\n' >"$dir/xdg/dibs/config.json"
    fm_dibs_scope_start "$dir/state" t2 || fail "the retry after enabling lease_policies still refused"
  ) || exit 1
  pass "real dibs: scope start, worktree adoption, relaunch rejoin, two-phase teardown, and time-bound refusal"
}

test_spawn_exports_scope_and_refuses_time_bound() {
  local dir="$TMP/spawn" home proj fakebin launchlog panelog out status seen scope
  if ! command -v dibs >/dev/null 2>&1; then
    pass "SKIP real dibs spawn: dibs is not installed"
    return 0
  fi
  home="$dir/home" proj="$dir/project" launchlog="$dir/launch.log" panelog="$dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" codex
  : >"$home/config/dibs-scopes"
  fm_git_worktree "$proj" "$dir/wt-a" wt-dibs-a
  git -C "$proj" worktree add --quiet -b wt-dibs-b "$dir/wt-b"
  fm_test_spawn_brief "$home" dibs-a1
  fm_test_spawn_brief "$home" dibs-b1
  mkdir -p "$dir/xdg/dibs" "$dir/dibs"
  printf '{"scopes":true,"exec_owner":true,"lease_policies":true,"consumer_contract":true}\n' >"$dir/xdg/dibs/config.json"
  (
    export XDG_CONFIG_HOME="$dir/xdg" DIBS_STATE="$dir/dibs" FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog"
    unset DIBS_SCOPES DIBS_EXEC_OWNER DIBS_LEASE_POLICIES DIBS_CONSUMER_CONTRACT
    : >"$launchlog"
    : >"$panelog"
    out=$(fm_test_run_spawn "$home" "$dir/wt-a" "$fakebin" dibs-a1 "$proj" --mode no-mistakes --yolo off)
    expect_code 0 "$?" "an opted-in ship spawn should succeed: $out"
    scope=$(dibs scope show --key "$(fm_dibs_scope_key "$home/state" dibs-a1)" --json | jq -r '.id // empty')
    [ -n "$scope" ] || fail "the spawn started no dibs scope"
    [ "$(dibs scope show "$scope" --json | jq -r .scope.liveness)" = alive ] || fail "the task record does not keep its scope alive"
    cat >"$fakebin/codex" <<'SH'
#!/bin/sh
printf '%s %s\n' "${DIBS_TASK-unset}" "${DIBS_SCOPE-unset}"
SH
    chmod +x "$fakebin/codex"
    # shellcheck disable=SC2016 # the pane shell expands the replayed exports.
    seen=$(env -i HOME="$dir/pane-home" PATH="$fakebin:$PATH" TERM=xterm TMUX=synthetic-pane \
      /bin/sh -c "$(grep '^export ' "$panelog")
$(cat "$launchlog")") || fail "the emitted launch failed to run"
    assert_equals "dibs-a1 $scope" "$seen" "the agent must start with DIBS_TASK and DIBS_SCOPE"

    printf '{"scopes":true,"exec_owner":true}\n' >"$dir/xdg/dibs/config.json"
    out=$(fm_test_run_spawn "$home" "$dir/wt-b" "$fakebin" dibs-b1 "$proj" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "a time-bound scope must refuse the spawn: $out"
    assert_contains "$out" "not owner-bound" "the refusal must name the missing dibs setting"
    [ ! -e "$home/state/dibs-b1.meta" ] || fail "a refused spawn left its task record"
  ) || exit 1
  pass "real dibs spawn: the agent starts with DIBS_TASK and DIBS_SCOPE, and a time-bound scope refuses the spawn"
}

fm_test_run \
  test_flag_absent_spawn_never_calls_dibs \
  test_owner_quotes_any_state_path \
  test_spawn_exports_scope_and_refuses_time_bound \
  test_without_dibs_nothing_runs \
  test_scopes_off_only_reads \
  test_retained_member_refuses_teardown \
  test_real_dibs_lifecycle
