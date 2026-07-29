#!/usr/bin/env bash
# Behavior tests for direct per-account usage selection and Herdr hook setup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECTOR="$ROOT/bin/fm-account-directory.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-directory-tests)
ACCOUNT_ROOT="$TMP_ROOT/accounts"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
QUOTA_LOG="$TMP_ROOT/quota.log"
HERDR_LOG="$TMP_ROOT/herdr.log"
TREEHOUSE_LOG="$TMP_ROOT/treehouse.log"
ROTATION_STATE="$TMP_ROOT/rotation-state"

mkdir -p "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --provider ] && [ "${2:-}" = codex ] && [ "${3:-}" = --json ] || exit 64
account=${CODEX_HOME##*/}
cache_file=$XDG_CACHE_HOME/quota-axi/quotas.json
[ "$XDG_CACHE_HOME" = "$CODEX_HOME/.agent-fleet-quota-cache" ] || exit 65
[ ! -e "$cache_file" ] || exit 66
case "${QUOTA_AXI_HOSTILE+x}${AGENT_FLEET_HOSTILE+x}${XDG_CONFIG_HOME+x}" in
  '') ;;
  *) exit 67 ;;
esac
printf '%s\t%s\n' "$CODEX_HOME" "$XDG_CACHE_HOME" >> "$FM_FAKE_QUOTA_LOG"
remaining=$(cat "$CODEX_HOME/test-remaining")
mkdir -p "$(dirname "$cache_file")"
printf '{"cached":true}\n' > "$cache_file"
if [ "$remaining" = hang ]; then
  sleep 30
  exit 0
fi
if [ "$remaining" = none ]; then
  printf '%s\n' '{"providers":[{"provider":"codex","state":{"status":"auth_required"},"windows":[]}]}'
  exit 1
fi
five=${remaining%%,*}
week=${remaining#*,}
cat <<JSON
{"providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[
{"id":"five_hour","kind":"session","percentRemaining":$five},
{"id":"weekly","kind":"weekly","percentRemaining":$week},
{"id":"model:test:5h","kind":"model","percentRemaining":100}
]}]}
JSON
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = integration ] && [ "${2:-}" = install ] || exit 64
case "${3:-}" in
  codex)
    [ -n "${CODEX_HOME:-}" ] || exit 65
    printf 'codex\t%s\n' "$CODEX_HOME" >> "$FM_FAKE_HERDR_LOG"
    printf '#!/usr/bin/env bash\n' > "$CODEX_HOME/herdr-agent-state.sh"
    ;;
  claude)
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] || exit 66
    printf 'claude\t%s\n' "$CLAUDE_CONFIG_DIR" >> "$FM_FAKE_HERDR_LOG"
    mkdir -p "$CLAUDE_CONFIG_DIR/hooks"
    printf '#!/usr/bin/env bash\n' > "$CLAUDE_CONFIG_DIR/hooks/herdr-agent-state.sh"
    ;;
  *) exit 67 ;;
esac
if [ -n "${FM_FAKE_HERDR_DRIFT_WORKTREE:-}" ]; then
  # Drift the worktree's identity out from under account preparation. It must be a
  # real change: a leased worktree is handed over DETACHED, so detaching again
  # would be a no-op and the recheck would have nothing to catch. -C is used so
  # repeated preparation calls stay idempotent.
  git -C "$FM_FAKE_HERDR_DRIFT_WORKTREE" switch --quiet -C drifted-during-prepare || exit 68
fi
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/profile-agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 4 ] && [ "$1" = --format ] && [ "$2" = json ] \
  && [ "$3" = profile ] && [ "$4" = list ] || exit 64
root=${FM_ACCOUNT_DIRECTORY_ROOT:-${FM_ACCOUNT_DIRECTORY_PASSWD_HOME:?}/.local/share/agent-fleet/accounts}
separator=
printf '{"profiles":['
for provider in claude codex; do
  vendor_dir=$root/$provider
  [ -d "$vendor_dir" ] || continue
  for home in "$vendor_dir"/*; do
    [ -d "$home" ] && [ ! -L "$home" ] || continue
    account=${home##*/}
    case "$account" in
      ''|.*|*[!A-Za-z0-9._-]*) continue ;;
    esac
    if [ -f "$home/test-last-resort" ]; then
      pools="[\"$provider-crew-last-resort\",\"$provider-manual\"]"
    elif [ -f "$home/test-manual-only" ]; then
      pools="[\"$provider-manual\"]"
    else
      pools="[\"$provider-crew\",\"$provider-manual\"]"
    fi
    enabled=true
    safety_policy=worker
    [ ! -f "$home/test-disabled" ] || enabled=false
    [ ! -f "$home/test-non-worker" ] || safety_policy=manual_only
    printf '%s{"id":"%s-%s","provider":"%s","home":"%s","pools":%s,"enabled":%s,"safety_policy":"%s"}' \
      "$separator" "$provider" "$account" "$provider" "$home" "$pools" \
      "$enabled" "$safety_policy"
    separator=,
  done
done
printf ']}\n'
SH
chmod +x "$FAKEBIN/profile-agent-fleet"

run_selector() {
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_ROOT="$ACCOUNT_ROOT" \
    FM_ACCOUNT_DIRECTORY_STATE_ROOT="$ROTATION_STATE" \
    FM_ACCOUNT_DIRECTORY_AGENT_FLEET="$FAKEBIN/profile-agent-fleet" \
    FM_ACCOUNT_DIRECTORY_QUOTA_AXI="$FAKEBIN/quota-axi" \
    FM_ACCOUNT_DIRECTORY_HERDR="$FAKEBIN/herdr" \
    FM_FAKE_QUOTA_LOG="$QUOTA_LOG" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    "$SELECTOR" "$@"
}

set_remaining() {
  local account=$1 remaining=$2
  mkdir -p "$ACCOUNT_ROOT/codex/$account/.agent-fleet-quota-cache/quota-axi"
  printf '%s\n' "$remaining" > "$ACCOUNT_ROOT/codex/$account/test-remaining"
  printf '{"stale":true}\n' > "$ACCOUNT_ROOT/codex/$account/.agent-fleet-quota-cache/quota-axi/quotas.json"
}

reset_accounts() {
  rm -rf "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"
  rm -rf "$ROTATION_STATE"
  mkdir -p "$ACCOUNT_ROOT/codex" "$ACCOUNT_ROOT/claude"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"
}

mark_manual_only() {
  local provider=$1 account=$2
  touch "$ACCOUNT_ROOT/$provider/$account/test-manual-only"
}

mark_last_resort() {
  local provider=$1 account=$2
  touch "$ACCOUNT_ROOT/$provider/$account/test-last-resort"
}

mark_claude_keychain_ready() {
  local account=$1
  mkdir -p "$ACCOUNT_ROOT/claude/$account/.agent-fleet-quota-cache/quota-axi"
  printf 'granted\n' > "$ACCOUNT_ROOT/claude/$account/.agent-fleet-quota-cache/quota-axi/claude-keychain-access-granted"
  chmod 600 "$ACCOUNT_ROOT/claude/$account/.agent-fleet-quota-cache/quota-axi/claude-keychain-access-granted"
}

test_profile_eligibility_requires_enabled_worker() {
  local out err expected
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/codex/1" "$ACCOUNT_ROOT/codex/2" "$ACCOUNT_ROOT/codex/3"
  touch "$ACCOUNT_ROOT/codex/1/test-disabled"
  touch "$ACCOUNT_ROOT/codex/2/test-non-worker"
  set_remaining 1 100,100
  set_remaining 2 100,100
  set_remaining 3 80,80
  out=$(run_selector select codex 2>"$TMP_ROOT/profile-eligibility.err")
  err=$(cat "$TMP_ROOT/profile-eligibility.err")
  expected="$ACCOUNT_ROOT/codex/3"
  [ "$out" = "$expected" ] || fail "disabled or non-worker profile entered crew selection: $out"
  assert_contains "$err" "$ACCOUNT_ROOT/codex/1 excluded from codex-crew: profile is disabled" \
    "disabled profile exclusion was not explicit"
  assert_contains "$err" "$ACCOUNT_ROOT/codex/2 excluded from codex-crew: safety policy is not worker" \
    "non-worker profile exclusion was not explicit"
  pass "crew selection hard-excludes disabled and non-worker profiles with explicit diagnostics"
}

test_claude_approval_marker_contract() {
  local account cache_dir marker marker_dir out status
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/1/.agent-fleet-quota-cache/quota-axi"
  account="$ACCOUNT_ROOT/claude/1"
  cache_dir="$account/.agent-fleet-quota-cache"
  marker_dir="$cache_dir/quota-axi"
  marker="$marker_dir/claude-keychain-access-granted"
  printf 'granted' > "$marker"
  chmod 600 "$marker"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted a marker without the exact granted newline payload"
  assert_contains "$out" "invalid quota-axi Keychain approval marker" \
    "malformed approval payload did not fail with a clear diagnostic"

  printf 'granted\n' > "$marker"
  chmod 644 "$marker"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted an insecure approval marker mode"

  chmod 600 "$marker"
  ln "$marker" "$marker.link"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted a multiply linked approval marker"
  rm "$marker.link"

  chmod 770 "$account"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted a group-writable account directory"
  chmod 700 "$account"

  chmod 707 "$cache_dir"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted a world-writable marker ancestor"
  chmod 700 "$cache_dir"

  chmod 770 "$marker_dir"
  if out=$(run_selector select claude 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "Claude selection accepted a group-writable marker parent"
  pass "Claude approval marker requires secure stable parents and leaf metadata"
}

test_codex_picks_highest_fresh_minimum_and_skips_no_window() {
  local out err
  reset_accounts
  set_remaining 1 80,40
  set_remaining 2 none
  set_remaining 3 90,75
  out=$(QUOTA_AXI_HOSTILE=1 AGENT_FLEET_HOSTILE=1 XDG_CONFIG_HOME=/hostile \
    run_selector select codex 2>"$TMP_ROOT/codex-select.err")
  err=$(cat "$TMP_ROOT/codex-select.err")
  [ "$out" = "$ACCOUNT_ROOT/codex/3" ] || fail "Codex did not choose the account with the highest minimum remaining usage: $out"
  assert_contains "$err" "codex account $ACCOUNT_ROOT/codex/2 skipped: no freshly readable usage window" \
    "Codex no-window account was not visibly skipped"
  assert_contains "$err" "selected codex account $ACCOUNT_ROOT/codex/3 with fresh remaining score=75" \
    "Codex selection did not report its fresh score"
  [ "$(wc -l < "$QUOTA_LOG" | tr -d ' ')" = 3 ] || fail "Codex selection did not read every discovered account"
  pass "Codex selects the highest fresh general-window minimum and skips only unreadable accounts"
}

test_codex_rechecks_health_on_every_selection() {
  local first second calls
  reset_accounts
  set_remaining 1 30,20
  set_remaining 2 none
  first=$(run_selector select codex 2>"$TMP_ROOT/recheck-first.err")
  [ "$first" = "$ACCOUNT_ROOT/codex/1" ] || fail "initial Codex selection ignored the only healthy account"

  set_remaining 2 100,100
  second=$(run_selector select codex 2>"$TMP_ROOT/recheck-second.err")
  [ "$second" = "$ACCOUNT_ROOT/codex/2" ] || fail "freshly re-authenticated Codex account stayed cached as unhealthy"
  calls=$(grep -c "^$ACCOUNT_ROOT/codex/2"$'\t' "$QUOTA_LOG" || true)
  [ "$calls" = 2 ] || fail "Codex account health was not re-read on both selections"
  pass "Codex health is read fresh at selection time so a newly authenticated account is immediately eligible"
}

test_codex_rotates_when_no_account_has_a_fresh_window() {
  local out expected
  reset_accounts
  set_remaining 1 none
  set_remaining 2 none
  out=$({
    run_selector select codex
    run_selector select codex
    run_selector select codex
    run_selector select codex
  } 2>"$TMP_ROOT/codex-unavailable.err")
  expected=$(printf '%s\n' \
    "$ACCOUNT_ROOT/codex/1" "$ACCOUNT_ROOT/codex/2" \
    "$ACCOUNT_ROOT/codex/1" "$ACCOUNT_ROOT/codex/2")
  [ "$out" = "$expected" ] || fail "Codex unavailable-usage fallback did not rotate: $out"
  assert_contains "$(cat "$TMP_ROOT/codex-unavailable.err")" "CODEX USAGE UNAVAILABLE" \
    "Codex unavailable-usage fallback did not identify the degraded signal"
  assert_contains "$(cat "$TMP_ROOT/codex-unavailable.err")" \
    "round-robin selection across 2 eligible codex-crew accounts" \
    "Codex unavailable-usage fallback did not report its rotation"
  pass "Codex rotates eligible accounts when every quota signal is unavailable"
}

test_codex_timeout_skips_wedged_account() {
  local out err
  reset_accounts
  set_remaining 1 hang
  set_remaining 2 90,85
  out=$(FM_ACCOUNT_DIRECTORY_QUOTA_TIMEOUT_SECONDS=1 \
    run_selector select codex 2>"$TMP_ROOT/codex-timeout.err")
  err=$(cat "$TMP_ROOT/codex-timeout.err")
  [ "$out" = "$ACCOUNT_ROOT/codex/2" ] || fail "wedged Codex account prevented selection of a later healthy account: $out"
  assert_contains "$err" "codex account $ACCOUNT_ROOT/codex/1 skipped: quota read timed out after 1s" \
    "Codex timeout was not classified as an unreadable account"
  pass "Codex bounds each usage read and continues to later healthy accounts"
}

test_claude_rotates_eligible_accounts_without_treating_usage_as_health() {
  local out err expected
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/3" "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  mark_manual_only claude 1
  mark_claude_keychain_ready 2
  mark_claude_keychain_ready 3
  out=$({
    run_selector select claude
    run_selector select claude
    run_selector select claude
    run_selector select claude
  } 2>"$TMP_ROOT/claude-select.err")
  err=$(cat "$TMP_ROOT/claude-select.err")
  expected=$(printf '%s\n' \
    "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/3" \
    "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/3")
  [ "$out" = "$expected" ] || fail "Claude unreadable-usage fallback did not round-robin across eligible accounts: $out"
  assert_contains "$err" "CLAUDE USAGE UNREADABLE" "Claude fallback did not carry the required obvious warning"
  assert_contains "$err" "config-dir-specific macOS Keychain credential" \
    "Claude fallback did not explain the keychain/quota-read gap"
  assert_contains "$err" "excluded from claude-crew" \
    "Claude fallback did not report the reserved account's pool exclusion"
  assert_not_contains "$out" "$ACCOUNT_ROOT/claude/1" \
    "Claude fallback selected an account reserved to the manual-only pool"
  [ ! -s "$QUOTA_LOG" ] || fail "Claude fallback called quota-axi even though per-directory usage is known unreadable"
  pass "Claude deterministically rotates across crew-pool accounts and excludes manual-only accounts when usage is unreadable"
}

test_concurrent_claude_selections_spread_without_usage() {
  local output_dir i status counts expected pid
  local -a pids=()
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/3" "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  mark_manual_only claude 1
  mark_claude_keychain_ready 2
  mark_claude_keychain_ready 3
  output_dir="$TMP_ROOT/concurrent-claude"
  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  status=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    run_selector select claude > "$output_dir/$i.out" 2> "$output_dir/$i.err" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || status=1
  done
  [ "$status" = 0 ] || fail "one or more concurrent Claude selections failed"
  if grep -Fqx "$ACCOUNT_ROOT/claude/1" "$output_dir"/*.out; then
    fail "concurrent Claude selection used the reserved manual-only account"
  fi
  counts=$(sort "$output_dir"/*.out | uniq -c | sed 's/^[[:space:]]*//')
  expected=$(printf '%s\n' \
    "6 $ACCOUNT_ROOT/claude/2" \
    "6 $ACCOUNT_ROOT/claude/3")
  [ "$counts" = "$expected" ] || fail "concurrent Claude selections did not spread evenly: $counts"
  [ ! -s "$QUOTA_LOG" ] || fail "concurrent Claude fallback unexpectedly called quota-axi"
  pass "concurrent unreadable-usage Claude selections serialize into an even deterministic rotation"
}

test_claude_fails_closed_when_no_usable_crew_account_exists() {
  local out status
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  mark_manual_only claude 1
  if out=$(run_selector select claude 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "Claude selection silently used a reserved or unapproved account"
  assert_contains "$out" "$ACCOUNT_ROOT/claude/1 excluded from claude-crew" \
    "zero-eligible Claude refusal did not identify the reserved account"
  assert_contains "$out" "$ACCOUNT_ROOT/claude/2 excluded from claude-crew: missing quota-axi's non-secret Keychain access marker" \
    "zero-eligible Claude refusal did not identify the account awaiting approval"
  assert_contains "$out" "no usable Claude account directories remain in claude-crew or claude-crew-last-resort" \
    "zero-eligible Claude refusal was not actionable"
  pass "Claude fails closed and names the reserved and unapproved reasons when no usable crew account exists"
}

test_claude_uses_only_explicit_last_resort_after_primary_exhaustion() {
  local out err
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  mark_last_resort claude 1
  mark_claude_keychain_ready 1
  out=$(run_selector select claude 2>"$TMP_ROOT/claude-last-resort.err")
  err=$(cat "$TMP_ROOT/claude-last-resort.err")
  [ "$out" = "$ACCOUNT_ROOT/claude/1" ] || fail "Claude did not select the declared last-resort account: $out"
  assert_contains "$err" "CLAUDE LAST RESORT" \
    "Claude last-resort selection was not explicit"
  assert_contains "$err" "using the explicitly declared claude-crew-last-resort tier" \
    "Claude last-resort selection did not name its declared policy"
  pass "Claude consults an explicitly declared last-resort tier only after no primary crew account remains"
}

test_codex_rotates_accounts_tied_for_best_fresh_score() {
  local out expected
  reset_accounts
  set_remaining 1 98,98
  set_remaining 2 98,98
  set_remaining 3 100,100
  set_remaining 4 100,100
  set_remaining 5 100,100
  mark_manual_only codex 5
  out=$({
    run_selector select codex
    run_selector select codex
    run_selector select codex
    run_selector select codex
  } 2>"$TMP_ROOT/codex-tie.err")
  expected=$(printf '%s\n' \
    "$ACCOUNT_ROOT/codex/3" "$ACCOUNT_ROOT/codex/4" \
    "$ACCOUNT_ROOT/codex/3" "$ACCOUNT_ROOT/codex/4")
  [ "$out" = "$expected" ] || fail "Codex best-score ties concentrated instead of rotating: $out"
  assert_not_contains "$out" "$ACCOUNT_ROOT/codex/5" \
    "Codex tie rotation selected an account reserved to the manual-only pool"
  assert_contains "$(cat "$TMP_ROOT/codex-tie.err")" "round-robin among 2 tied accounts" \
    "Codex tie rotation did not report its deterministic tie-break"
  pass "Codex preserves fresh usage scoring and round-robins accounts tied for the best score"
}

test_default_root_uses_passwd_home_not_ambient_home() {
  local passwd_home hostile_home expected out
  passwd_home="$TMP_ROOT/passwd-home"
  hostile_home="$TMP_ROOT/hostile-home"
  expected="$passwd_home/.local/share/agent-fleet/accounts/claude/1"
  mkdir -p "$expected" "$hostile_home/.local/share/agent-fleet/accounts/claude/0"
  mkdir -p "$expected/.agent-fleet-quota-cache/quota-axi"
  printf 'granted\n' > "$expected/.agent-fleet-quota-cache/quota-axi/claude-keychain-access-granted"
  chmod 600 "$expected/.agent-fleet-quota-cache/quota-axi/claude-keychain-access-granted"
  out=$(HOME="$hostile_home" \
    FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_PASSWD_HOME="$passwd_home" \
    FM_ACCOUNT_DIRECTORY_STATE_ROOT="$ROTATION_STATE" \
    FM_ACCOUNT_DIRECTORY_AGENT_FLEET="$FAKEBIN/profile-agent-fleet" \
    "$SELECTOR" select claude 2>"$TMP_ROOT/passwd-home.err")
  [ "$out" = "$expected" ] || fail "ambient HOME redirected account discovery away from the passwd home: $out"
  pass "default account discovery ignores ambient HOME and stays under the passwd home"
}

test_prepare_installs_and_verifies_per_account_herdr_hooks() {
  local codex_home claude_home
  reset_accounts
  set_remaining 1 90,80
  mkdir -p "$ACCOUNT_ROOT/claude/1"
  mark_claude_keychain_ready 1

  codex_home=$(run_selector prepare codex 2>"$TMP_ROOT/prepare-codex.err")
  claude_home=$(run_selector prepare claude 2>"$TMP_ROOT/prepare-claude.err")
  [ -f "$codex_home/herdr-agent-state.sh" ] || fail "Codex Herdr hook was not installed in the selected profile home"
  [ -f "$claude_home/hooks/herdr-agent-state.sh" ] || fail "Claude Herdr hook was not installed in the selected profile home"
  assert_grep $'codex\t'"$ACCOUNT_ROOT/codex/1" "$HERDR_LOG" "Herdr installer did not receive CODEX_HOME"
  assert_grep $'claude\t'"$ACCOUNT_ROOT/claude/1" "$HERDR_LOG" "Herdr installer did not receive CLAUDE_CONFIG_DIR"
  pass "prepare uses Herdr's own installer and verifies each selected profile hook"
}

make_spawn_fakebin() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{session_name}"*"#{window_name}"*)
    [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] || exit 1
    printf 'firstmate\t%s\n' "${FM_FAKE_ENDPOINT_LABEL:?}"
    exit 0
    ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    case " $* " in
      *" -t "*) [ -f "${FM_FAKE_ENDPOINT_FILE:?}" ] || exit 1 ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows) exit 0 ;;
  has-session|new-session) exit 0 ;;
  new-window)
    touch "${FM_FAKE_ENDPOINT_FILE:?}"
    printf '@1\n'
    exit 0
    ;;
  kill-window)
    [ "${FM_FAKE_KILL_RETAIN:-0}" = 1 ] || rm -f "${FM_FAKE_ENDPOINT_FILE:?}"
    exit 0
    ;;
  send-keys)
    prev=
    for argument in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$argument" >> "$FM_FAKE_LAUNCH_LOG"
      fi
      prev=$argument
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
# `treehouse get --lease` reports the leased worktree on stdout, and fm-spawn
# refuses to launch without it. The stub has to answer that the same way.
[ "${1:-}" != get ] || {
  printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
  exit 0
}
[ "${1:-}" = return ] || exit 0
target=${@: -1}
[ "$target" != . ] || target=$(pwd -P)
printf 'return --force %s\n' "$target" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
[ "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" != 1 ] || exit 71
project=${FM_TREEHOUSE_RETURN_PROJECT:-$(pwd -P)}
cd "$project" || exit 72
git worktree remove --force "$target"
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/forbidden-agent-fleet" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FM_FAKE_AGENT_FLEET_LOG"
exit 99
SH
  chmod +x "$fakebin/forbidden-agent-fleet"
}

run_direct_spawn() {
  local home=$1 worktree=$2 launch_log=$3
  shift 3
  : > "$launch_log"
  FM_ROOT_OVERRIDE="${FM_TEST_ROOT_OVERRIDE:-}" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launch_log" FM_FAKE_ENDPOINT_FILE="$home/state/.fake-endpoint" \
    FM_FAKE_ENDPOINT_LABEL="fm-${1:-unknown}" FM_FAKE_KILL_RETAIN="${FM_FAKE_KILL_RETAIN:-0}" \
    FM_FAKE_HERDR_DRIFT_WORKTREE="${FM_FAKE_HERDR_DRIFT_WORKTREE:-}" \
    T="${T:-}" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_TREEHOUSE_WORKTREE="$worktree" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL="${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" \
    PATH="$FAKEBIN:$PATH" \
    FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_ACCOUNT_DIRECTORY_ROOT="$ACCOUNT_ROOT" \
    FM_ACCOUNT_DIRECTORY_STATE_ROOT="$ROTATION_STATE" \
    FM_ACCOUNT_DIRECTORY_AGENT_FLEET="$FAKEBIN/profile-agent-fleet" \
    FM_ACCOUNT_DIRECTORY_QUOTA_AXI="$FAKEBIN/quota-axi" \
    FM_ACCOUNT_DIRECTORY_HERDR="$FAKEBIN/herdr" \
    FM_FAKE_QUOTA_LOG="$QUOTA_LOG" FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_AGENT_FLEET_BIN="$FAKEBIN/forbidden-agent-fleet" \
    FM_FAKE_AGENT_FLEET_LOG="$TMP_ROOT/agent-fleet.log" \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home project worktree launch_log
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  launch_log="$case_dir/launch.log"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/treehouse-pools"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  # A leased Treehouse worktree is handed over at detached HEAD on a clean
  # default branch, and fm-spawn refuses one that is still attached to a branch
  # (the crew creates its own). Reproduce that shape, not a generic worktree.
  fm_git_worktree "$project" "$worktree" "wt-$name"
  git -C "$worktree" checkout --quiet --detach HEAD
  git -C "$project" branch --quiet -D "wt-$name"
  printf '%s\n' "$home|$project|$worktree|$launch_log"
}

read_spawn_case() {
  IFS='|' read -r SPAWN_HOME SPAWN_PROJECT SPAWN_WORKTREE SPAWN_LAUNCH_LOG <<EOF
$1
EOF
}

test_spawn_uses_direct_codex_home_without_agent_fleet() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 30,20
  set_remaining 2 100,95
  id=direct-codex-z1
  record=$(make_spawn_case direct-codex codex "$id")
  read_spawn_case "$record"
  printf '%s\n' enforce > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "selected direct codex account home $ACCOUNT_ROOT/codex/2" \
    "spawn did not report its direct Codex account"
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/2' codex" \
    "spawn did not scope Codex to the selected account home"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/2" "$meta" "spawn metadata omitted the selected account home"
  if grep -q '^account_profile=' "$meta"; then fail "new direct spawn wrote legacy managed profile metadata"; fi
  if grep -q '^account_pool=' "$meta"; then fail "new direct spawn wrote legacy managed pool metadata"; fi
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "new direct spawn invoked Agent Fleet"
  pass "new enforced Codex spawn uses CODEX_HOME and never enters Agent Fleet lease selection"
}

test_spawn_uses_direct_claude_fallback_and_hook() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  mkdir -p "$ACCOUNT_ROOT/claude/2" "$ACCOUNT_ROOT/claude/1"
  mark_manual_only claude 1
  mark_claude_keychain_ready 2
  id=direct-claude-z2
  record=$(make_spawn_case direct-claude claude "$id")
  read_spawn_case "$record"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool claude-crew 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "CLAUDE USAGE UNREADABLE" "spawn hid the required Claude quota-read warning"
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$ACCOUNT_ROOT/claude/2' claude" \
    "spawn did not scope Claude to the eligible rotated account home"
  assert_contains "$launch" "--model 'claude-opus-5'" \
    "Claude spawn did not carry the anchored Opus 5 model"
  assert_grep "account_home=$ACCOUNT_ROOT/claude/2" "$meta" "Claude spawn metadata omitted account_home"
  assert_grep "model=claude-opus-5" "$meta" "Claude spawn metadata omitted the resolved Opus 5 model"
  [ -f "$ACCOUNT_ROOT/claude/2/hooks/herdr-agent-state.sh" ] || fail "Claude spawn did not install its per-account Herdr hook"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "new direct Claude spawn invoked Agent Fleet"
  pass "new account-flagged Claude spawn excludes reserved profiles and launches on the anchored Opus 5 model"
}

test_claude_spawn_rejects_mismatched_explicit_model() {
  local record id out status
  reset_accounts
  id=claude-model-mismatch-refused-z2
  record=$(make_spawn_case claude-model-mismatch-refused claude "$id")
  read_spawn_case "$record"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --model sonnet 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "Claude crew launch accepted a non-Opus-5 explicit model"
  assert_contains "$out" "model 'sonnet' does not match the installed Opus 5 anchor 'claude-opus-5'" \
    "Claude model mismatch refusal was not actionable"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "Claude model mismatch created an endpoint"
  pass "Claude crew/scout launch rejects an explicit model that differs from the Opus 5 anchor"
}

test_direct_claude_recovery_resolves_legacy_default_to_anchor() {
  local record id meta meta_tmp launch
  reset_accounts
  mkdir -p "$ACCOUNT_ROOT/claude/2"
  mark_claude_keychain_ready 2
  id=claude-recovery-model-anchor-z2
  record=$(make_spawn_case claude-recovery-model-anchor claude "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool claude-crew >/dev/null 2>&1
  meta=$SPAWN_HOME/state/$id.meta
  meta_tmp=$(mktemp "$SPAWN_HOME/state/.claude-recovery-model.XXXXXX")
  awk '/^model=/ { print "model=default"; next } { print }' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  rm -f "$SPAWN_HOME/state/.fake-endpoint"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account >/dev/null 2>&1
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  assert_contains "$launch" "--model 'claude-opus-5'" \
    "direct Claude recovery inherited the legacy default model"
  assert_grep "model=claude-opus-5" "$meta" \
    "direct Claude recovery metadata did not record the model actually launched"
  pass "direct Claude recovery preserves explicit models and upgrades a legacy default to the Opus 5 anchor"
}

test_observe_spawn_uses_direct_directory_without_agent_fleet() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 75,70
  id=direct-observe-z3
  record=$(make_spawn_case direct-observe codex "$id")
  read_spawn_case "$record"
  printf '%s\n' observe > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/1' codex" \
    "observe launch did not use direct Codex selection"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/1" "$meta" "observe metadata omitted the direct account home"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "observe launch invoked Agent Fleet"
  assert_not_contains "$out" "fm-account-routing: observe" "observe launch entered the legacy dry-run selector"
  pass "observe mode uses direct account-directory routing without Agent Fleet leases"
}

test_direct_spawn_and_recovery_support_detached_worktree() {
  local record id meta expected_head out launch
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-detached-z4
  record=$(make_spawn_case direct-detached codex "$id")
  read_spawn_case "$record"
  git -C "$SPAWN_WORKTREE" switch --quiet --detach
  expected_head=$(git -C "$SPAWN_WORKTREE" rev-parse --verify HEAD)

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1
  meta="$SPAWN_HOME/state/$id.meta"
  assert_grep "worktree_git_ref=refs/heads/fm/$id" "$meta" \
    "detached direct spawn did not record its authoritative task branch"
  assert_grep "worktree_git_setup_head=$expected_head" "$meta" \
    "detached direct spawn did not retain its exact pre-setup HEAD"
  git -C "$SPAWN_WORKTREE" switch --quiet -c "fm/$id"

  rm -f "$SPAWN_HOME/state/.fake-endpoint"
  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  assert_contains "$out" "spawned $id harness=codex" \
    "direct recovery rejected an intentionally detached worktree"
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/1' codex" \
    "detached direct recovery did not launch with direct account routing"
  assert_grep "worktree_git_ref=refs/heads/fm/$id" "$meta" \
    "direct recovery did not preserve the authoritative task branch"
  if grep -q '^worktree_git_setup_' "$meta"; then
    fail "direct recovery did not adopt the completed task-branch transition"
  fi
  pass "direct routing safely adopts the required detached-to-task-branch transition"
}

test_direct_recovery_preserves_recorded_task_context() {
  local record id out meta launch project_name generation recorded_project recorded_worktree meta_tmp
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 95,90
  set_remaining 2 30,20
  id=direct-recovery-z4
  record=$(make_spawn_case direct-recovery codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --harness codex --model gpt-recorded --effort high \
    --account-pool legacy-codex-pool --scout >/dev/null 2>&1
  meta=$SPAWN_HOME/state/$id.meta
  generation=$(sed -n 's/^generation_id=//p' "$meta")
  recorded_project=$(sed -n 's/^project=//p' "$meta")
  recorded_worktree=$(sed -n 's/^worktree=//p' "$meta")
  meta_tmp=$(mktemp "$SPAWN_HOME/state/.direct-recovery-meta.XXXXXX")
  awk '
    /^mode=/ { print "mode=direct-PR"; next }
    /^yolo=/ { print "yolo=on"; next }
    { print }
    END { print "dispatch_profile_required=1" }
  ' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  project_name=$(basename "$SPAWN_PROJECT")
  printf '%s\n' "- $project_name [local-only] - changed policy (added 2026-07-23)" > "$SPAWN_HOME/data/projects.md"
  printf '%s\n' '{"version":1,"rules":[],"default":{"harness":"claude"}}' > "$SPAWN_HOME/config/crew-dispatch.json"
  set_remaining 1 20,15
  set_remaining 2 90,85
  rm -f "$SPAWN_HOME/state/.fake-endpoint"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  assert_contains "$out" "selected direct codex account home $ACCOUNT_ROOT/codex/2" \
    "direct recovery did not select a fresh account directory"
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/2' codex" \
    "direct recovery did not launch with the freshly selected account"
  assert_contains "$launch" "--model 'gpt-recorded'" \
    "direct recovery did not preserve the recorded model"
  assert_contains "$launch" "model_reasoning_effort=\"high\"" \
    "direct recovery did not preserve the recorded effort"
  assert_not_contains "$launch" "treehouse get" \
    "direct recovery reconstructed or replaced the recorded worktree"
  assert_grep "kind=scout" "$meta" "direct recovery did not preserve scout kind"
  assert_grep "project=$recorded_project" "$meta" "direct recovery changed project identity"
  assert_grep "worktree=$recorded_worktree" "$meta" "direct recovery changed worktree identity"
  assert_grep "worktree_git_dir=" "$meta" "direct recovery dropped the exact worktree Git-dir"
  assert_grep "worktree_git_dir_identity=" "$meta" "direct recovery dropped the worktree Git-dir identity"
  assert_grep "worktree_git_ref=refs/heads/" "$meta" "direct recovery dropped the worktree branch identity"
  assert_grep "harness=codex" "$meta" "direct recovery changed the recorded harness"
  assert_grep "model=gpt-recorded" "$meta" "direct recovery changed the recorded model"
  assert_grep "effort=high" "$meta" "direct recovery changed the recorded effort"
  assert_grep "mode=direct-PR" "$meta" "direct recovery re-resolved the recorded delivery mode"
  assert_grep "yolo=on" "$meta" "direct recovery re-resolved the recorded yolo setting"
  assert_grep "report_required=1" "$meta" "direct recovery dropped the report requirement"
  assert_grep "generation_id=$generation" "$meta" "direct recovery replaced the task generation identity"
  assert_grep "dispatch_profile_required=1" "$meta" "direct recovery dropped dispatch-profile metadata"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/2" "$meta" "direct recovery did not update account_home"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "direct recovery invoked Agent Fleet"
  pass "direct recovery preserves recorded task context while refreshing account selection"
}

test_direct_recovery_rejects_secondmate_metadata() {
  local record id meta out status
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  id=direct-secondmate-refused-z4
  record=$(make_spawn_case direct-secondmate-refused codex "$id")
  read_spawn_case "$record"
  meta="$SPAWN_HOME/state/$id.meta"
  printf '%s\n' \
    'kind=secondmate' \
    'account_home=/accounts/codex/1' \
    > "$meta"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery accepted secondmate metadata"
  assert_contains "$out" "--recover-direct-account supports only recorded ship or scout tasks" \
    "direct recovery did not identify its crewmate-only scope"
  [ ! -s "$QUOTA_LOG" ] || fail "rejected secondmate recovery read direct account quota"
  [ ! -s "$HERDR_LOG" ] || fail "rejected secondmate recovery installed a direct account hook"
  pass "direct account recovery refuses secondmate metadata before selection"
}

test_direct_recovery_rejects_worktree_from_another_project() {
  local record id meta unrelated meta_tmp out status recorded_git_dir
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-project-identity-z5
  record=$(make_spawn_case direct-project-identity codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1
  meta="$SPAWN_HOME/state/$id.meta"
  unrelated="$TMP_ROOT/unrelated-direct-recovery"
  fm_git_init_commit "$unrelated"
  meta_tmp=$(mktemp "$SPAWN_HOME/state/.direct-project-meta.XXXXXX")
  awk -v worktree="$unrelated" '
    /^worktree=/ { print "worktree=" worktree; next }
    { print }
  ' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  rm -f "$SPAWN_HOME/state/.fake-endpoint"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"
  recorded_git_dir=$(sed -n 's/^worktree_git_dir=//p' "$meta")

  if out=$(GIT_DIR="$recorded_git_dir" GIT_COMMON_DIR="$SPAWN_PROJECT/.git" GIT_WORK_TREE="$unrelated" \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery launched in a worktree from another project"
  # Two correct guards can catch this worktree: the recorded Git metadata is now
  # proven before the project-membership comparison runs, so a redirected worktree
  # is refused as redirected rather than as foreign. Pin the REFUSAL and its
  # actionability - that it names the offending path - not which of the two fires
  # first, which is an implementation detail either ordering satisfies.
  case $out in
    *"does not belong to recorded project"*|*"redirected or unprovable Git metadata"*) ;;
    *) fail "direct recovery project-identity refusal was not actionable: $out" ;;
  esac
  assert_contains "$out" "$unrelated" \
    "direct recovery refusal did not name the offending worktree"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "project-identity mismatch created a replacement endpoint"
  [ ! -s "$QUOTA_LOG" ] || fail "project-identity mismatch read account quota before refusing recovery"
  [ ! -s "$HERDR_LOG" ] || fail "project-identity mismatch installed a profile hook before refusing recovery"
  pass "direct recovery proves the recorded worktree belongs to the recorded project"
}

test_direct_recovery_requires_recorded_brief() {
  local record id out status
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-brief-z6
  record=$(make_spawn_case direct-brief codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1
  rm -f "$SPAWN_HOME/state/.fake-endpoint" "$SPAWN_HOME/data/$id/brief.md"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery launched without its recorded brief"
  assert_contains "$out" "no brief at $SPAWN_HOME/data/$id/brief.md" \
    "direct recovery missing-brief refusal was not actionable"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "missing direct recovery brief created a replacement endpoint"
  [ ! -s "$QUOTA_LOG" ] || fail "missing direct recovery brief read account quota before refusing recovery"
  [ ! -s "$HERDR_LOG" ] || fail "missing direct recovery brief installed a profile hook before refusing recovery"
  pass "direct recovery refuses to launch without the recorded brief"
}

test_direct_recovery_rejects_changed_worktree_identity() {
  local record id meta original_worktree wrong_worktree redirected_worktree meta_tmp out status
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-worktree-identity-z7
  record=$(make_spawn_case direct-worktree-identity codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1
  meta="$SPAWN_HOME/state/$id.meta"
  original_worktree=$(sed -n 's/^worktree=//p' "$meta")
  wrong_worktree="$TMP_ROOT/wrong-linked-worktree"
  git -C "$SPAWN_PROJECT" worktree add --quiet -b wrong-linked-worktree "$wrong_worktree"
  wrong_worktree=$(cd "$wrong_worktree" && pwd -P)
  meta_tmp=$(mktemp "$SPAWN_HOME/state/.direct-worktree-meta.XXXXXX")
  awk -v worktree="$wrong_worktree" '
    /^worktree=/ { print "worktree=" worktree; next }
    { print }
  ' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  rm -f "$SPAWN_HOME/state/.fake-endpoint"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery launched in another linked worktree"
  assert_contains "$out" "no longer has its exact Git-dir identity" \
    "wrong linked-worktree refusal did not identify the exact Git-dir mismatch"
  [ ! -s "$QUOTA_LOG" ] || fail "wrong linked worktree read account quota before refusing recovery"
  [ ! -s "$HERDR_LOG" ] || fail "wrong linked worktree installed a profile hook before refusing recovery"

  redirected_worktree="$(cd "$TMP_ROOT" && pwd -P)/redirected-direct-worktree"
  ln -s "$original_worktree" "$redirected_worktree"
  meta_tmp=$(mktemp "$SPAWN_HOME/state/.direct-worktree-meta.XXXXXX")
  awk -v worktree="$redirected_worktree" '
    /^worktree=/ { print "worktree=" worktree; next }
    { print }
  ' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery followed a symlinked worktree path"
  assert_contains "$out" "is redirected or non-canonical" \
    "symlinked worktree refusal did not identify path redirection"
  [ ! -s "$QUOTA_LOG" ] || fail "symlinked worktree read account quota before refusing recovery"
  [ ! -s "$HERDR_LOG" ] || fail "symlinked worktree installed a profile hook before refusing recovery"

  meta_tmp=$(mktemp "$SPAWN_HOME/state/.direct-worktree-meta.XXXXXX")
  awk -v worktree="$original_worktree" '
    /^worktree=/ { print "worktree=" worktree; next }
    { print }
  ' "$meta" > "$meta_tmp"
  mv "$meta_tmp" "$meta"
  git -C "$original_worktree" switch --quiet -c diverted-direct-recovery
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery launched after the recorded worktree changed branches"
  assert_contains "$out" "changed branch identity" \
    "changed-branch refusal did not identify the recorded branch mismatch"
  [ ! -s "$QUOTA_LOG" ] || fail "changed worktree branch read account quota before refusing recovery"
  [ ! -s "$HERDR_LOG" ] || fail "changed worktree branch installed a profile hook before refusing recovery"
  pass "direct recovery rejects wrong, redirected, and branch-changed worktrees"
}

test_direct_recovery_rechecks_identity_after_account_prepare() {
  local record id out status
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-recheck-z7
  record=$(make_spawn_case direct-recheck codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1
  rm -f "$SPAWN_HOME/state/.fake-endpoint"
  : > "$QUOTA_LOG"
  : > "$HERDR_LOG"

  if out=$(FM_FAKE_HERDR_DRIFT_WORKTREE="$SPAWN_WORKTREE" \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery ignored worktree identity drift during account preparation"
  assert_contains "$out" "changed branch identity" \
    "post-prepare identity drift refusal was not actionable"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "post-prepare identity drift created a replacement endpoint"
  [ -s "$QUOTA_LOG" ] || fail "post-prepare identity test did not reach fresh quota selection"
  [ -s "$HERDR_LOG" ] || fail "post-prepare identity test did not reach Herdr installation"
  pass "direct recovery rechecks exact identity immediately before endpoint creation"
}

test_direct_recovery_tracks_retained_replacement_endpoint() {
  local record id meta out status backup_name artifacts_name retry launch
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  set_remaining 2 20,15
  id="direct-retained-endpoint-z7-$$"
  record=$(make_spawn_case direct-retained-endpoint codex "$id")
  read_spawn_case "$record"

  run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool >/dev/null 2>&1 \
    || fail "retained-endpoint fixture could not create its initial managed spawn"
  meta="$SPAWN_HOME/state/$id.meta"
  set_remaining 1 20,15
  set_remaining 2 95,90
  rm -f "$SPAWN_HOME/state/.fake-endpoint"
  rm -rf "/tmp/fm-$id"
  : > "/tmp/fm-$id"

  if out=$(FM_FAKE_KILL_RETAIN=1 \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" --recover-direct-account 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct recovery failure fixture unexpectedly succeeded"
  [ -f "$SPAWN_HOME/state/.fake-endpoint" ] || fail "retained-endpoint fixture did not keep the replacement endpoint alive"
  assert_grep "direct_recovery_cleanup=pending" "$meta" "failed recovery did not record pending direct cleanup"
  assert_grep "tmux_window_id=@1" "$meta" "failed recovery did not record the replacement endpoint identity"
  assert_grep "tmux_session_target=firstmate:fm-$id" "$meta" "failed recovery did not record the replacement endpoint scope"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/2" "$meta" "failed recovery metadata still presented the old account home as current"
  backup_name=$(sed -n 's/^direct_recovery_backup=//p' "$meta")
  artifacts_name=$(sed -n 's/^direct_recovery_artifacts=//p' "$meta")
  [ -f "$SPAWN_HOME/state/$backup_name" ] || fail "failed recovery did not retain its prior metadata backup"
  [ -d "$SPAWN_HOME/state/$artifacts_name" ] || fail "failed recovery did not retain its artifact backup"

  rm -f "/tmp/fm-$id" "$SPAWN_HOME/state/.fake-endpoint"
  retry=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  assert_contains "$retry" "cleaned retained direct recovery endpoint for $id" \
    "direct recovery did not reconcile the retained replacement endpoint"
  assert_contains "$launch" "CODEX_HOME='$ACCOUNT_ROOT/codex/2' codex" \
    "direct recovery did not launch after reconciling the retained endpoint"
  if grep -q '^direct_recovery_' "$meta"; then fail "successful retry left direct recovery markers in metadata"; fi
  [ ! -e "$SPAWN_HOME/state/$backup_name" ] || fail "successful retry left the retained metadata backup"
  [ ! -e "$SPAWN_HOME/state/$artifacts_name" ] || fail "successful retry left the retained artifact backup"
  rm -rf "/tmp/fm-$id"
  pass "failed direct recovery tracks and reconciles a retained replacement endpoint"
}

test_new_direct_spawn_tracks_retained_endpoint_and_worktree() {
  local record id meta out status recovery_out recovery_status recorded_worktree
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 90,85
  id=direct-new-retained-z8
  record=$(make_spawn_case direct-new-retained codex "$id")
  read_spawn_case "$record"
  : > "/tmp/fm-$id"

  if out=$(FM_FAKE_KILL_RETAIN=1 \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "new retained-endpoint failure fixture unexpectedly succeeded"
  meta="$SPAWN_HOME/state/$id.meta"
  recorded_worktree=$(cd "$SPAWN_WORKTREE" && pwd -P)
  [ -f "$SPAWN_HOME/state/.fake-endpoint" ] || fail "new direct spawn fixture did not retain its endpoint"
  assert_grep "direct_spawn_cleanup=pending" "$meta" \
    "new direct spawn did not record pending endpoint cleanup"
  assert_grep "rollback_pending=1" "$meta" \
    "new direct spawn did not fail closed against duplicate spawn"
  assert_grep "worktree=$recorded_worktree" "$meta" \
    "new direct spawn did not retain its worktree path"
  assert_grep "worktree_git_dir=" "$meta" \
    "new direct spawn did not retain its exact worktree Git-dir"
  assert_grep "worktree_git_dir_identity=" "$meta" \
    "new direct spawn did not retain its worktree Git-dir identity"
  assert_grep "worktree_git_ref=refs/heads/" "$meta" \
    "new direct spawn did not retain its authoritative branch"
  assert_grep "tmux_window_id=@1" "$meta" \
    "new direct spawn did not retain its endpoint identity"
  assert_grep "account_home=$ACCOUNT_ROOT/codex/1" "$meta" \
    "new direct spawn did not retain its selected account home"

  if recovery_out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" --recover-direct-account 2>&1); then
    recovery_status=0
  else
    recovery_status=$?
  fi
  [ "$recovery_status" -ne 0 ] || fail "direct recovery bypassed pending new-spawn cleanup"
  assert_contains "$recovery_out" "failed direct spawn cleanup is pending" \
    "pending new-spawn cleanup refusal was not actionable"
  rm -f "/tmp/fm-$id" "$SPAWN_HOME/state/.fake-endpoint"
  pass "new direct spawn tracks retained endpoint and worktree state"
}

test_failed_new_direct_spawn_returns_worktree_after_endpoint_cleanup() {
  local record id out status recorded_worktree
  reset_accounts
  set_remaining 1 90,85
  id=direct-new-rollback-z9
  record=$(make_spawn_case direct-new-rollback codex "$id")
  read_spawn_case "$record"
  recorded_worktree=$(cd "$SPAWN_WORKTREE" && pwd -P)
  : > "$TREEHOUSE_LOG"
  : > "/tmp/fm-$id"

  if out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "new direct rollback fixture unexpectedly succeeded"
  if ! grep -Fq "return --force $recorded_worktree" "$TREEHOUSE_LOG"; then
    fail "failed new direct spawn did not return its worktree: output=$out treehouse=$(cat "$TREEHOUSE_LOG")"
  fi
  [ ! -e "$SPAWN_WORKTREE" ] || fail "failed new direct spawn left its worktree registered"
  [ ! -e "$SPAWN_HOME/state/$id.meta" ] || fail "successful direct rollback left task metadata"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "successful direct rollback left its endpoint"
  rm -f "/tmp/fm-$id"
  pass "failed new direct spawn removes its endpoint and returns its worktree"
}

test_failed_new_direct_spawn_retains_cleanup_when_worktree_return_fails() {
  local record id out status meta
  reset_accounts
  set_remaining 1 90,85
  id=direct-new-return-fail-z9
  record=$(make_spawn_case direct-new-return-fail codex "$id")
  read_spawn_case "$record"
  : > "$TREEHOUSE_LOG"
  : > "/tmp/fm-$id"

  if out=$(FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" "$SPAWN_PROJECT" --account-pool legacy-codex-pool 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "direct return-failure fixture unexpectedly succeeded"
  meta="$SPAWN_HOME/state/$id.meta"
  [ -d "$SPAWN_WORKTREE" ] || fail "direct return failure lost the retained worktree"
  assert_grep "direct_spawn_cleanup=pending" "$meta" \
    "direct return failure did not record pending cleanup"
  assert_grep "rollback_pending=1" "$meta" \
    "direct return failure did not fail closed"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "direct return failure retained an already-removed endpoint"
  rm -f "/tmp/fm-$id"
  pass "direct spawn persists cleanup state when worktree return cannot be confirmed"
}

test_failed_new_direct_spawn_never_records_an_uncreated_endpoint() {
  local record id out status meta
  reset_accounts
  set_remaining 1 90,85
  id=direct-new-no-endpoint-z9
  record=$(make_spawn_case direct-new-no-endpoint codex "$id")
  read_spawn_case "$record"
  : > "$TREEHOUSE_LOG"
  : > "/tmp/fm-$id"

  if out=$(T=default:captain-pane FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
      "$id" "$SPAWN_PROJECT" --backend herdr --account-pool legacy-codex-pool 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "pre-endpoint direct spawn failure fixture unexpectedly succeeded"
  meta="$SPAWN_HOME/state/$id.meta"
  [ -d "$SPAWN_WORKTREE" ] || fail "pre-endpoint return failure lost the retained worktree"
  assert_grep "direct_spawn_cleanup=pending" "$meta" \
    "pre-endpoint failure did not record pending worktree cleanup"
  assert_grep "direct_spawn_endpoint=not-created" "$meta" \
    "pre-endpoint failure did not distinguish an uncreated endpoint"
  assert_grep "window=" "$meta" \
    "pre-endpoint failure did not retain the metadata schema's empty window field"
  assert_no_grep "window=default:captain-pane" "$meta" \
    "pre-endpoint failure fabricated the currently focused pane as its endpoint"
  assert_no_grep "herdr_pane_id=" "$meta" \
    "pre-endpoint failure copied an ambient Herdr pane identity"
  [ ! -e "$SPAWN_HOME/state/.fake-endpoint" ] || fail "pre-endpoint failure created an endpoint"
  rm -f "/tmp/fm-$id"
  pass "failed direct spawn never records an endpoint it did not create"
}

test_routing_off_keeps_default_provider_launch() {
  local record id out launch meta
  reset_accounts
  : > "$TMP_ROOT/agent-fleet.log"
  set_remaining 1 100,100
  id=direct-off-z3
  record=$(make_spawn_case direct-off codex "$id")
  read_spawn_case "$record"
  printf '%s\n' off > "$SPAWN_HOME/config/account-routing-mode"

  out=$(run_direct_spawn "$SPAWN_HOME" "$SPAWN_WORKTREE" "$SPAWN_LAUNCH_LOG" \
    "$id" "$SPAWN_PROJECT" 2>&1)
  launch=$(cat "$SPAWN_LAUNCH_LOG")
  meta=$SPAWN_HOME/state/$id.meta
  assert_contains "$out" "spawned $id harness=codex" "routing-off spawn failed"
  assert_not_contains "$launch" "CODEX_HOME=" "routing-off launch unexpectedly selected an account directory"
  if grep -q '^account_home=' "$meta"; then fail "routing-off metadata unexpectedly recorded an account home"; fi
  [ ! -s "$QUOTA_LOG" ] || fail "routing-off spawn read per-account quota"
  [ ! -s "$HERDR_LOG" ] || fail "routing-off spawn ran the Herdr profile installer"
  [ ! -s "$TMP_ROOT/agent-fleet.log" ] || fail "routing-off spawn invoked Agent Fleet"
  pass "routing off preserves the provider's default identity and performs no account selection"
}

make_spawn_fakebin "$FAKEBIN"

if [ "${FM_TEST_FOCUSED:-}" = account-directory-trust ]; then
  test_profile_eligibility_requires_enabled_worker
  test_claude_approval_marker_contract
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = direct-recovery-lifecycle ]; then
  test_direct_spawn_and_recovery_support_detached_worktree
  test_direct_recovery_preserves_recorded_task_context
  test_direct_recovery_rejects_secondmate_metadata
  test_failed_new_direct_spawn_returns_worktree_after_endpoint_cleanup
  test_failed_new_direct_spawn_retains_cleanup_when_worktree_return_fails
  test_failed_new_direct_spawn_never_records_an_uncreated_endpoint
  exit 0
fi

test_codex_picks_highest_fresh_minimum_and_skips_no_window
test_profile_eligibility_requires_enabled_worker
test_claude_approval_marker_contract
test_codex_rechecks_health_on_every_selection
test_codex_rotates_when_no_account_has_a_fresh_window
test_codex_timeout_skips_wedged_account
test_claude_rotates_eligible_accounts_without_treating_usage_as_health
test_concurrent_claude_selections_spread_without_usage
test_claude_fails_closed_when_no_usable_crew_account_exists
test_claude_uses_only_explicit_last_resort_after_primary_exhaustion
test_codex_rotates_accounts_tied_for_best_fresh_score
test_default_root_uses_passwd_home_not_ambient_home
test_prepare_installs_and_verifies_per_account_herdr_hooks
test_spawn_uses_direct_codex_home_without_agent_fleet
test_spawn_uses_direct_claude_fallback_and_hook
test_claude_spawn_rejects_mismatched_explicit_model
test_direct_claude_recovery_resolves_legacy_default_to_anchor
test_observe_spawn_uses_direct_directory_without_agent_fleet
test_direct_spawn_and_recovery_support_detached_worktree
test_direct_recovery_preserves_recorded_task_context
test_direct_recovery_rejects_secondmate_metadata
test_direct_recovery_rejects_worktree_from_another_project
test_direct_recovery_requires_recorded_brief
test_direct_recovery_rejects_changed_worktree_identity
test_direct_recovery_rechecks_identity_after_account_prepare
test_direct_recovery_tracks_retained_replacement_endpoint
test_new_direct_spawn_tracks_retained_endpoint_and_worktree
test_failed_new_direct_spawn_returns_worktree_after_endpoint_cleanup
test_failed_new_direct_spawn_retains_cleanup_when_worktree_return_fails
test_failed_new_direct_spawn_never_records_an_uncreated_endpoint
test_routing_off_keeps_default_provider_launch

echo "# all fm-account-directory tests passed"
