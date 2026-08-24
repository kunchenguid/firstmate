#!/usr/bin/env bash
# tests/fm-browser-guard.test.sh - portable regressions for the default-on fleet
# browser analytics-beacon block (bin/fm-browser-guard.sh) and its injection at
# the crewmate spawn site (bin/fm-spawn.sh).
#
# Why this file exists: a fleet browser session once polluted a production
# PostHog project with beacons from automated sweeps. The block must be
# structural, not brief discipline, so fm-spawn injects the guard flag into every
# crewmate pane by default. These cases pin the guard's host-level decisions and
# flag format, and prove fm-spawn injects the real guard bytes by default and
# omits them only under the explicit FM_BROWSER_ALLOW_ANALYTICS opt-out.
#
# The block DECISION logic is pinned here with no browser (portable in CI). That
# Chrome actually honors the emitted flag and blocks the requests headless is a
# harness-dependent fact proven by tests/fm-browser-guard-block-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-browser-guard.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-guard)

# --- guard contract ---------------------------------------------------------

test_classify_decisions() {
  # host, expected verdict. Production apex and the whole posthog.com family are
  # blocked; staging/preview subdomains, localhost, and unrelated sites are not.
  local table=(
    "https://birdied.app/|BLOCK"
    "https://birdied.app/ingest/e/|BLOCK"
    "https://www.birdied.app/anything|BLOCK"
    "https://staging.birdied.app/|ALLOW"
    "https://pr-42.birdied.app/courses|ALLOW"
    "https://eu.i.posthog.com/e/|BLOCK"
    "https://us.i.posthog.com/batch/|BLOCK"
    "https://app.posthog.com/decide/|BLOCK"
    "https://posthog.com/docs|BLOCK"
    "https://example.com/ingest/e|ALLOW"
    "http://localhost:3000/|ALLOW"
    "http://127.0.0.1:8081/ingest|ALLOW"
  )
  local row url want got
  for row in "${table[@]}"; do
    url=${row%%|*}
    want=${row##*|}
    got=$("$GUARD" classify "$url") || fail "classify failed for $url"
    [ "$got" = "$want" ] || fail "classify $url: expected $want, got $got"
  done
  pass "guard: host-level block decisions (production apex + posthog cloud blocked, staging/localhost allowed)"
}

test_chrome_args_is_single_token() {
  local flag
  flag=$("$GUARD" chrome-args) || fail "chrome-args failed"
  case "$flag" in
    "--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,"*) : ;;
    *) fail "chrome-args did not emit a data: PAC URL flag: $flag" ;;
  esac
  # CHROME_DEVTOOLS_AXI_CHROME_ARGS is whitespace-split with no quoting, so the
  # flag MUST be a single whitespace-free token or Chrome would receive garbage.
  case "$flag" in
    *[[:space:]]*) fail "chrome-args token contains whitespace and would be shredded by CHROME_DEVTOOLS_AXI_CHROME_ARGS: $flag" ;;
  esac
  pass "guard: chrome-args is a single whitespace-free data: PAC token"
}

test_chrome_args_carries_the_real_pac() {
  local flag b64 decoded pac
  flag=$("$GUARD" chrome-args) || fail "chrome-args failed"
  b64=${flag#*base64,}
  decoded=$(printf '%s' "$b64" | base64 -d) || fail "chrome-args base64 did not decode"
  pac=$("$GUARD" pac) || fail "pac failed"
  [ "$decoded" = "$pac" ] || fail "chrome-args data: URL does not carry the exact PAC bytes"
  pass "guard: the emitted flag carries the exact PAC the guard prints"
}

test_env_composes_with_existing_value() {
  local line composed
  line=$("$GUARD" env) || fail "env failed"
  # The literal ${...} is what we are asserting is present, not a value to expand.
  # shellcheck disable=SC2016
  case "$line" in
    *'${CHROME_DEVTOOLS_AXI_CHROME_ARGS:-}'*) : ;;
    *) fail "env line does not defer to an existing CHROME_DEVTOOLS_AXI_CHROME_ARGS value: $line" ;;
  esac
  # Eval it with a pre-existing value and confirm the guard flag is prepended and
  # the inherited value is preserved (never clobbered).
  composed=$(
    CHROME_DEVTOOLS_AXI_CHROME_ARGS="--enable-gpu"
    eval "$line"
    printf '%s' "$CHROME_DEVTOOLS_AXI_CHROME_ARGS"
  )
  case "$composed" in
    "--proxy-pac-url=data:"*" --enable-gpu") : ;;
    *) fail "env composition clobbered or dropped the inherited value: $composed" ;;
  esac
  pass "guard: env composes the block flag with an inherited CHROME_DEVTOOLS_AXI_CHROME_ARGS"
}

test_unknown_command_fails() {
  local rc=0
  "$GUARD" bogus-subcommand >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "guard unknown command"
  pass "guard: an unknown subcommand fails closed with exit 2"
}

# --- spawn injection --------------------------------------------------------
#
# Fake tmux: answers the pane-path query and logs every send-keys text payload
# (the GOTMPDIR export, the browser-guard export, and the launch line) one per
# line, in send order, so both presence and ordering are observable.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 allow=$5
  shift 5
  : > "$launchlog"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_BROWSER_ALLOW_ANALYTICS="$allow" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

test_spawn_injects_block_by_default() {
  local rec home proj wt fakebin launchlog id out injected b64 decoded pac
  rec=$(make_spawn_case default-block)
  IFS='|' read -r home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" 0 "$id" "$proj") \
    || fail "default spawn failed: $out"
  assert_grep 'export CHROME_DEVTOOLS_AXI_CHROME_ARGS="--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,' \
    "$launchlog" "default spawn did not inject the browser analytics block flag"
  # The injected flag must carry the real guard PAC bytes.
  injected=$(grep '^export CHROME_DEVTOOLS_AXI_CHROME_ARGS=' "$launchlog" | head -1)
  b64=${injected#*base64,}
  b64=${b64%% *}
  decoded=$(printf '%s' "$b64" | base64 -d) || fail "injected flag base64 did not decode"
  pac=$("$GUARD" pac)
  [ "$decoded" = "$pac" ] || fail "spawn injected a flag that is not the guard's PAC"
  # Ordering: the block export rides the GOTMPDIR pre-launch site and is sent
  # before the launch line (which is the final logged payload).
  local gl cl total
  gl=$(grep -n '^export GOTMPDIR=' "$launchlog" | head -1 | cut -d: -f1)
  cl=$(grep -n '^export CHROME_DEVTOOLS_AXI_CHROME_ARGS=' "$launchlog" | head -1 | cut -d: -f1)
  total=$(grep -c '' "$launchlog")
  [ -n "$gl" ] && [ -n "$cl" ] || fail "spawn log missing GOTMPDIR/block export lines"
  [ "$cl" -gt "$gl" ] || fail "block export must ride the GOTMPDIR pre-launch site (gotmp=$gl block=$cl)"
  [ "$cl" -lt "$total" ] || fail "block export must be sent before the launch line (block=$cl total=$total)"
  pass "spawn: injects the real guard block flag before launch by default"
}

test_spawn_opt_out_omits_block() {
  local rec home proj wt fakebin launchlog id out
  rec=$(make_spawn_case opt-out)
  IFS='|' read -r home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" 1 "$id" "$proj") \
    || fail "opt-out spawn failed: $out"
  assert_no_grep 'export CHROME_DEVTOOLS_AXI_CHROME_ARGS=' \
    "$launchlog" "opt-out spawn must NOT inject the block flag"
  assert_grep '# firstmate: browser analytics beacon blocking DISABLED' \
    "$launchlog" "opt-out spawn must send the loud disabled marker into the pane"
  assert_contains "$out" "analytics beacon blocking DISABLED" \
    "opt-out spawn must print a loud notice to firstmate"
  pass "spawn: FM_BROWSER_ALLOW_ANALYTICS=1 omits the block and marks the pane loudly"
}

test_classify_decisions
test_chrome_args_is_single_token
test_chrome_args_carries_the_real_pac
test_env_composes_with_existing_value
test_unknown_command_fails
test_spawn_injects_block_by_default
test_spawn_opt_out_omits_block
