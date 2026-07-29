#!/usr/bin/env bash
# Test fixtures deliberately scope PATH changes to subshells; no parent-shell
# mutation is expected or subsequently consumed.
# shellcheck disable=SC2031
# tests/fm-backend-herdr.test.sh - fake-herdr-CLI unit tests for the herdr
# session-provider adapter (bin/backends/herdr.sh), P2 of
# data/fm-backend-design-d7 (herdr-addendum.md). Mirrors tests/fm-backend.test.sh's
# fakebin/command-log convention, but herdr has no pre-refactor baseline to
# diff against (it is new in this task), so these are direct behavior
# assertions against a small, LOG-based, canned-response fake `herdr` + real
# `jq` (jq itself is a real required tool for this backend, not faked).
# The real-binary smoke test lives in tests/fm-backend-herdr-smoke.test.sh,
# gated on the herdr binary actually being installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-tests)
export FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
export FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1

assert_no_server_transients() {  # <lock-root> <label>
  local root=$1 label=$2 artifact leaf mode
  for artifact in "$root"/*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    leaf=${artifact##*/}
    case "$leaf" in
      *.closed-shell-v2|*.closed-shell-config-v2.toml|*.closed-shell-config-v2-*.toml)
        if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$artifact"); else mode=$(stat -c %a "$artifact"); fi
        [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ "$mode" = 600 ] \
          || fail "$label left an unsafe persistent managed artifact: $artifact"
        ;;
      managed-worker-shell-v1-*)
        if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$artifact"); else mode=$(stat -c %a "$artifact"); fi
        [ -f "$artifact" ] && [ ! -L "$artifact" ] && [ "$mode" = 500 ] \
          || fail "$label left an unsafe persistent managed helper: $artifact"
        ;;
      *) fail "$label left a lock, candidate, quarantine, or unknown artifact: $artifact" ;;
    esac
  done
}

# make_herdr_fakebin: a `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call read from $FM_HERDR_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...) so a test can script a short sequence
# of calls precisely. A missing response file means "succeed with empty
# stdout" (mirrors send-text/send-keys/pane close/tab close, which are silent
# on success in the real CLI - verified in herdr-verification-p2.md).
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ] && [ "${FM_HERDR_SCRIPT_STATUS:-0}" != 1 ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_herdr_statefake: a STATEFUL `herdr` stub that models the parts of herdr's
# real container behavior the workspace-leak fix (and the default-tab-prune
# safety fix) depend on, so a full spawn->teardown cycle can be replayed
# repeatedly and the "one persistent firstmate workspace, no orphans"
# invariant asserted end to end (the canned, call-numbered make_herdr_fakebin
# above cannot model state carried ACROSS calls). Backed by a JSON state file
# ($FM_FAKE_HERDR_STATE) mutated with real jq. Modeled behaviors, all
# verified real-herdr facts recorded in docs/herdr-backend.md: `workspace
# create` seeds the new workspace with one auto-created default tab (label
# "1") and returns that tab's tab_id/pane_id in the SAME response
# (`.result.tab.tab_id` / `.result.root_pane.pane_id`, verified empirically
# against the real binary); `pane close` removes the pane's single-pane tab
# (closing a tab's only pane closes the tab); `workspace list` / `tab list` /
# `pane list` reflect live state; `agent get <pane>` reports the pane's preset
# agent_status (set via fake_herdr_set_agent_status, never through a CLI
# call - mirrors an out-of-band agent registering itself) or an
# agent_not_found error when none was preset (verified real-herdr behavior for
# a pane with no registered agent). Every call is logged to $FM_HERDR_LOG in
# the same unit-separated form as make_herdr_fakebin.
make_herdr_statefake() {  # <dir> -> echoes fakebin dir; seeds an empty state file
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab=${3:-}
    jq_state --arg t "$tab" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent get")
    pane=${3:-}
    status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# fake_herdr_set_agent_status: preset <pane_id>'s agent_status in the
# stateful fake's state file, mirroring an agent registering itself
# out-of-band (never through a CLI call the adapter itself would make).
# Used to exercise fm_backend_herdr_workspace_prune_seeded_default_tab's
# defense-in-depth refuse-if-busy check.
fake_herdr_set_agent_status() {  # <state-file> <pane_id> <status>
  local state=$1 pane=$2 status=$3 tmp="$1.tmp.$$"
  jq --arg p "$pane" --arg s "$status" '.agent_status[$p] = $s' "$state" > "$tmp" && mv "$tmp" "$state"
}

# herdr_case <name> -> sets up FM_HERDR_LOG/FM_HERDR_RESPONSES/fb for one test,
# registers cleanup-free tmp dirs under TMP_ROOT.
herdr_env() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  printf '%s\n%s\n' "$dir/log" "$dir/responses"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_protocol() {
  local dir log resp fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","channel":"stable","protocol":14}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept protocol 14 (>= the verified minimum)"
  assert_contains "$(cat "$log")" $'\x1f''status'$'\x1f''--json' "version_check did not call herdr status --json"
  pass "fm_backend_herdr_version_check: accepts the current protocol (14)"
}

test_version_check_refuses_old_protocol() {
  local dir log resp fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.3.0","channel":"stable","protocol":5}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse protocol 5 (below min)"
  assert_contains "$out" "protocol 5" "version_check error did not name the rejected protocol"
  pass "fm_backend_herdr_version_check: refuses an old protocol loudly"
}

test_version_check_refuses_missing_herdr() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when herdr is not installed"
  assert_contains "$out" "unavailable or unsafe" "version_check did not report Herdr as missing or unsafe"
  pass "fm_backend_herdr_version_check: refuses loudly when herdr is not installed"
}

test_herdr_binary_revalidates_leaf_and_physical_ancestry() {
  local dir safe bin release unsafe hardlink out status
  dir="$TMP_ROOT/herdr-physical-pin"
  safe="$dir/safe"
  bin="$safe/bin"
  release="$safe/libexec/herdr/current/herdr"
  unsafe="$dir/unsafe"
  mkdir -p "$bin" "${release%/*}" "$unsafe/bin"
  chmod 700 "$safe" "$unsafe"
  cat > "$release" <<'SH'
#!/bin/sh
exit 0
SH
  chmod 755 "$release"
  ln -s ../libexec/herdr/current/herdr "$bin/herdr"

  out=$(PATH="$bin:/usr/bin:/bin" bash -c '
    . "$0/bin/backends/herdr.sh"
    first=$(fm_backend_herdr_bin) || exit 1
    chmod 777 "$first"
    fm_backend_herdr_bin >/dev/null 2>&1 && exit 2
    printf "%s\n" "$first"
  ' "$ROOT") || fail "safe Herdr symlink layout was not resolved and revalidated"
  [ "$out" = "$(cd "${release%/*}" && pwd -P)/${release##*/}" ] \
    || fail "Herdr pin returned the wrong physical release: $out"
  chmod 755 "$release"

  cp "$release" "$unsafe/bin/herdr"
  chmod 755 "$unsafe/bin/herdr"
  chmod 777 "$unsafe"
  if PATH="$unsafe/bin:/usr/bin:/bin" bash -c \
    '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_bin' "$ROOT" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "Herdr binary under writable physical ancestry was accepted"

  chmod 700 "$unsafe"
  hardlink="$unsafe/bin/herdr-link"
  ln "$unsafe/bin/herdr" "$hardlink"
  if PATH="$unsafe/bin:/usr/bin:/bin" bash -c \
    '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_bin' "$ROOT" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "hardlinked Herdr binary was accepted"
  pass "Herdr supports the installed symlink layout, revalidates its cached leaf, and rejects unsafe ancestry/hardlinks"
}

test_server_launch_scrubs_hostile_perl_and_control_environment() {
  local dir fb perl_lib marker launched tool
  dir="$TMP_ROOT/herdr-hostile-environment"
  fb="$dir/fakebin"
  perl_lib="$dir/perl-lib"
  marker="$dir/hostile-ran"
  launched="$dir/server-launched"
  mkdir -p "$fb" "$perl_lib"
  cat > "$fb/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "${FM_HERDR_DETACH_MARKER:?}"
SH
  chmod 755 "$fb/herdr"
  for tool in perl uname stat id date shasum sha256sum cksum awk sed jq; do
    cat > "$fb/$tool" <<SH
#!/bin/sh
printf '%s\n' '$tool' >> '$marker'
exit 97
SH
    chmod 755 "$fb/$tool"
  done
  cat > "$perl_lib/BridgeHerdrEvil.pm" <<PERL
package BridgeHerdrEvil;
BEGIN { open my \$fh, '>', '$marker' or die \$!; print {\$fh} "PERL5OPT\n"; close \$fh; }
1;
PERL
  PATH="$fb" PERL5OPT=-MBridgeHerdrEvil PERL5LIB="$perl_lib" PERLLIB="$perl_lib" \
    DYLD_INSERT_LIBRARIES="$dir/not-a-library" LD_PRELOAD="$dir/not-a-library" \
    FM_HERDR_DETACH_MARKER="$launched" /bin/bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_launch_detached fmtest || exit 1
      attempt=1
      while [ "$attempt" -le 100 ]; do
        [ -s "$FM_HERDR_DETACH_MARKER" ] && exit 0
        /bin/sleep 0.02
        attempt=$((attempt + 1))
      done
      exit 2
    ' "$ROOT" || fail "closed-environment detached launch did not execute the verified fake Herdr"
  [ "$(cat "$launched")" = "server --session fmtest" ] \
    || fail "closed detached launch changed the Herdr command"
  [ ! -e "$marker" ] || fail "hostile PATH/Perl/loader environment executed during Herdr launch: $(cat "$marker")"
  pass "Herdr detached launch uses fixed controls and a closed grandchild environment"
}

test_server_launch_preserves_only_safe_worker_tool_paths() {
  local dir fb safe unsafe safe_physical unsafe_physical marker path_line tool_line
  dir="$TMP_ROOT/herdr-worker-path"
  fb="$dir/herdr-bin"
  safe="$dir/safe-worker-bin"
  unsafe="$dir/writable-worker-bin"
  marker="$dir/worker-path.tsv"
  mkdir -p "$fb" "$safe" "$unsafe"
  chmod 700 "$fb" "$safe"
  chmod 777 "$unsafe"
  safe_physical=$(cd "$safe" && pwd -P)
  unsafe_physical=$(cd "$unsafe" && pwd -P)
  cat > "$safe/bridge-worker-tool" <<'SH'
#!/bin/sh
printf 'safe-worker-tool\n'
SH
  cat > "$unsafe/bridge-worker-tool" <<'SH'
#!/bin/sh
printf 'unsafe-worker-tool\n'
SH
  cat > "$fb/herdr" <<'SH'
#!/bin/sh
marker=${FM_HERDR_DETACH_MARKER:?}
tmp=$marker.tmp.$$
printf 'PATH\t%s\n' "$PATH" > "$tmp"
printf 'TOOL\t%s\n' "$(/bin/sh -c bridge-worker-tool)" >> "$tmp"
/bin/mv "$tmp" "$marker"
SH
  chmod 755 "$safe/bridge-worker-tool" "$unsafe/bridge-worker-tool" "$fb/herdr"

  PATH="$unsafe:$safe:$fb:/usr/bin:/bin" FM_HERDR_DETACH_MARKER="$marker" /bin/bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_server_launch_detached fmtest || exit 1
    attempt=1
    while [ "$attempt" -le 100 ]; do
      [ -s "$FM_HERDR_DETACH_MARKER" ] && exit 0
      /bin/sleep 0.02
      attempt=$((attempt + 1))
    done
    exit 2
  ' "$ROOT" || fail "detached Herdr descendant did not inherit its validated worker PATH"
  path_line=$(sed -n '1p' "$marker")
  tool_line=$(sed -n '2p' "$marker")
  assert_contains "$path_line" "$safe_physical" "safe user tool directory was stripped from the Herdr server PATH"
  assert_not_contains "$path_line" "$unsafe_physical" "writable PATH directory reached the Herdr server"
  [ "$tool_line" = $'TOOL\tsafe-worker-tool' ] \
    || fail "Herdr descendant did not resolve the safe worker tool: $tool_line"
  pass "detached Herdr descendants retain safe worker tools and exclude writable PATH entries"
}

test_managed_shell_and_server_certificate_close_startup_before_bash() {
  local dir fb lock_root lock_physical server_marker shell_marker bash_env shell_dump ps_fake ps_dead result certificate config wrapper helper_digest pid
  dir="$TMP_ROOT/herdr-managed-shell-certificate"
  fb="$dir/fakebin"
  lock_root="$dir/locks"
  server_marker="$dir/server-environment"
  shell_marker="$dir/shell-startup-injection-ran"
  bash_env="$dir/hostile-bash-env"
  shell_dump="$dir/worker-environment"
  ps_fake="$dir/fake-ps"
  ps_dead="$dir/ps-dead"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  lock_physical=$(cd "$lock_root" && pwd -P)
  cat > "$fb/herdr" <<'SH'
#!/bin/sh
printf '%s\n%s\n%s\n' "${HERDR_CONFIG_PATH-}" "${SHELL-}" "$*" \
  > "${FM_HERDR_DETACH_MARKER:?}"
exec /bin/sleep 20
SH
  chmod 755 "$fb/herdr"
  cat > "$bash_env" <<SH
/usr/bin/touch '$shell_marker'
SH
  cat > "$ps_fake" <<SH
#!/bin/sh
[ ! -e '$ps_dead' ] || exit 1
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"

  result=$(PATH="$fb:/usr/bin:/bin" FM_HERDR_DETACH_MARKER="$server_marker" \
    FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_launch_detached fmtest || exit 1
      for _attempt in $(seq 1 100); do
        [ -s "$FM_HERDR_DETACH_MARKER" ] && break
        /bin/sleep 0.02
      done
      [ -s "$FM_HERDR_DETACH_MARKER" ] || exit 2
      fm_backend_herdr_server_closed_shell_environment_ready fmtest || exit 3
      certificate=$(fm_backend_herdr_server_env_certificate_path fmtest) || exit 4
      config=$(fm_backend_herdr_managed_config_path fmtest) || exit 5
      wrapper=$(fm_backend_herdr_managed_shell_bin) || exit 6
      printf "%s\n%s\n%s\n" "$certificate" "$config" "$wrapper"
    ' "$ROOT") || fail "closed Herdr server certificate was not established"
  certificate=${result%%$'\n'*}
  result=${result#*$'\n'}
  config=${result%%$'\n'*}
  wrapper=${result#*$'\n'}
  [ "$(sed -n '1p' "$server_marker")" = "$config" ] \
    || fail "Herdr server did not receive the managed config path"
  [ "$(sed -n '2p' "$server_marker")" = "$wrapper" ] \
    || fail "Herdr server did not receive the pre-Bash managed shell"
  [ "$(sed -n '3p' "$server_marker")" = 'server --session fmtest' ] \
    || fail "certified server launch changed its scoped command"
  [ "$(sed -n '1p' "$certificate")" = firstmate-herdr-closed-env-v2 ] \
    || fail "Herdr server published the wrong closed-shell certificate schema"
  [ "$(sed -n '5p' "$certificate")" = "$wrapper" ] \
    || fail "Herdr certificate did not bind the exact managed helper path"
  [ "$(sed -n '8p' "$certificate")" = "$config" ] \
    || fail "Herdr certificate did not bind the exact managed config path"
  helper_digest=$(sed -n '6p' "$certificate")
  [ "${#helper_digest}" -eq 64 ] \
    && [ "$wrapper" = "$lock_physical/managed-worker-shell-v1-$helper_digest" ] \
    || fail "managed Herdr worker shell was not installed at its certified content address: $wrapper"
  assert_grep "default_shell = \"$wrapper\"" "$config" \
    "managed Herdr config did not force the pre-Bash worker shell"
  assert_grep 'shell_mode = "non_login"' "$config" \
    "managed Herdr config did not disable login startup"
  assert_grep 'resume_agents_on_restore = false' "$config" \
    "managed Herdr config did not disable autonomous restored-agent launch"

  /usr/bin/env SHELLOPTS=xtrace \
    "PS4=\$(/usr/bin/touch '$shell_marker')" \
    BASH_ENV="$bash_env" AGENT_FLEET_CONFIG=/tmp/hostile-fleet \
    QUOTA_AXI_CACHE_DIR=/tmp/hostile-quota XDG_CONFIG_HOME=/tmp/hostile-xdg \
    "BASH_FUNC_hostile_shell%%=() { /usr/bin/touch '$shell_marker'; }" \
    "$wrapper" -c "/usr/bin/env > '$shell_dump'" \
    || fail "managed worker shell did not start under hostile inherited Bash state"
  [ ! -e "$shell_marker" ] \
    || fail "managed worker shell interpreted hostile startup state before scrubbing"
  if grep -Eq '^(AGENT_FLEET_|QUOTA_AXI_|XDG_|BASH_FUNC_|BASH_ENV=|SHELLOPTS=|PS4=)' \
    "$shell_dump"; then
    fail "managed worker shell retained a startup/authority injection variable"
  fi

  pid=$(sed -n '3p' "$certificate")
  kill "$pid" 2>/dev/null || true
  : > "$ps_dead"
  for _attempt in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 0.05
  done
  if PATH="$fb:/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 FM_TEST_HERDR_PS_BIN="$ps_fake" \
    /bin/bash --noprofile --norc -c \
      '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_closed_shell_environment_ready fmtest' \
      "$ROOT" >/dev/null 2>&1; then
    fail "dead certified Herdr server retained closed-shell authority"
  fi
  pass "Herdr managed config, process certificate, and pre-Bash shell close hostile startup state"
}

test_managed_shell_certificate_rejects_release_and_artifact_drift() {
  local dir fb lock_root source ps_fake result certificate config wrapper pid replacement session marker
  dir="$TMP_ROOT/herdr-managed-shell-drift"
  fb="$dir/fakebin"
  lock_root="$dir/locks"
  source="$dir/fm-herdr-worker-shell"
  ps_fake="$dir/fake-ps"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  cp "$ROOT/bin/fm-herdr-worker-shell" "$source"
  chmod 755 "$source"
  cat > "$fb/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "${FM_HERDR_DETACH_MARKER:?}"
exec /bin/sleep 20
SH
  chmod 755 "$fb/herdr"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
pid=
for argument in "$@"; do pid=$argument; done
kill -0 "$pid" 2>/dev/null || exit 1
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"

  launch_fixture() {
    local fixture_session=$1 fixture_marker="$dir/$1.server"
    PATH="$fb:/usr/bin:/bin" FM_HERDR_DETACH_MARKER="$fixture_marker" \
      FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
      FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
      /bin/bash --noprofile --norc -c '
        . "$0/bin/backends/herdr.sh"
        fm_backend_herdr_server_launch_detached "$1" || exit 1
        for _attempt in $(seq 1 100); do
          [ -s "$FM_HERDR_DETACH_MARKER" ] && break
          /bin/sleep 0.02
        done
        [ -s "$FM_HERDR_DETACH_MARKER" ] || exit 2
        fm_backend_herdr_server_closed_shell_environment_ready "$1" || exit 3
        printf "%s\n%s\n%s\n" \
          "$(fm_backend_herdr_server_env_certificate_path "$1")" \
          "$(fm_backend_herdr_managed_config_path "$1")" \
          "$(fm_backend_herdr_managed_shell_bin)"
      ' "$ROOT" "$fixture_session"
  }

  certificate_ready() {
    local fixture_session=$1
    PATH="$fb:/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
      FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
      /bin/bash --noprofile --norc -c \
        '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_closed_shell_environment_ready "$1"' \
        "$ROOT" "$fixture_session"
  }

  session=fm-config-drift
  result=$(launch_fixture "$session") || fail "config-drift fixture did not establish a certificate"
  certificate=${result%%$'\n'*}
  result=${result#*$'\n'}
  config=${result%%$'\n'*}
  wrapper=${result#*$'\n'}
  replacement="$dir/config-replacement"
  cp "$config" "$replacement"
  chmod 600 "$replacement"
  mv "$replacement" "$config"
  certificate_ready "$session" >/dev/null 2>&1 \
    && fail "identical-byte managed-config replacement retained certificate authority"
  pid=$(sed -n '3p' "$certificate")
  kill "$pid" 2>/dev/null || true

  session=fm-helper-drift
  result=$(launch_fixture "$session") || fail "helper-drift fixture did not establish a certificate"
  certificate=${result%%$'\n'*}
  result=${result#*$'\n'}
  config=${result%%$'\n'*}
  wrapper=${result#*$'\n'}
  replacement="$dir/helper-replacement"
  cp "$wrapper" "$replacement"
  chmod 500 "$replacement"
  mv "$replacement" "$wrapper"
  certificate_ready "$session" >/dev/null 2>&1 \
    && fail "identical-byte managed helper replacement retained certificate authority"
  pid=$(sed -n '3p' "$certificate")
  kill "$pid" 2>/dev/null || true

  session=fm-source-drift
  result=$(launch_fixture "$session") || fail "source-drift fixture did not establish a certificate"
  certificate=${result%%$'\n'*}
  replacement="$dir/source-replacement"
  cp "$source" "$replacement"
  printf '\n# release drift fixture\n' >> "$replacement"
  chmod 755 "$replacement"
  mv "$replacement" "$source"
  certificate_ready "$session" >/dev/null 2>&1 \
    && fail "post-launch reviewed helper-source update retained old server authority"
  pid=$(sed -n '3p' "$certificate")
  kill "$pid" 2>/dev/null || true
  pass "Herdr certificate rejects config/helper inode replacement and release-source drift"
}

test_managed_artifact_candidate_recovery_is_guarded() {
  local dir lock_root source ps_fake result config certificate helper stale_config stale_certificate stale_helper
  local foreign_config foreign_certificate indeterminate_certificate raced_config raced_original ready proceed preserved recovery_pid candidate
  dir="$TMP_ROOT/herdr-managed-candidates"
  lock_root="$dir/locks"
  source="$dir/fm-herdr-worker-shell"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  cp "$ROOT/bin/fm-herdr-worker-shell" "$source"
  chmod 755 "$source"
  ps_fake="$dir/fake-ps"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
pid=
for argument in "$@"; do pid=$argument; done
if [ "$pid" = 999996 ]; then
  printf 'indeterminate process probe\n' >&2
  exit 1
fi
case "$pid" in 999995|999998|999999) exit 1 ;; esac
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"
  result=$(FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      printf "%s\n%s\n%s\n" \
        "$(fm_backend_herdr_managed_config_path fm-candidates)" \
        "$(fm_backend_herdr_server_env_certificate_path fm-candidates)" \
        "$(fm_backend_herdr_managed_shell_bin)"
    ' "$ROOT") || fail "candidate recovery paths were unavailable"
  config=${result%%$'\n'*}
  result=${result#*$'\n'}
  certificate=${result%%$'\n'*}
  helper=${result#*$'\n'}
  stale_config="$config.candidate.999999"
  stale_certificate="$certificate.candidate.999998"
  stale_helper="$helper.candidate.999995"
  foreign_config="$config.candidate.foreign"
  foreign_certificate="$certificate.candidate.999997"
  indeterminate_certificate="$certificate.candidate.999996"
  printf 'stale config candidate\n' > "$stale_config"
  printf 'stale certificate candidate\n' > "$stale_certificate"
  printf 'stale helper candidate\n' > "$stale_helper"
  printf 'foreign suffix\n' > "$foreign_config"
  printf 'foreign mode\n' > "$foreign_certificate"
  printf 'indeterminate owner\n' > "$indeterminate_certificate"
  chmod 600 "$stale_config" "$stale_certificate" "$foreign_config" "$indeterminate_certificate"
  chmod 500 "$stale_helper"
  chmod 640 "$foreign_certificate"
  touch -t 202001010000 "$stale_config" "$stale_certificate" "$stale_helper" "$foreign_config" "$foreign_certificate" "$indeterminate_certificate"

  FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_artifact_recover_candidates "$1" 0600
      fm_backend_herdr_artifact_recover_candidates "$2" 0600
      fm_backend_herdr_artifact_recover_candidates "$3" 0500
    ' "$ROOT" "$config" "$certificate" "$helper" \
    || fail "guarded artifact candidate recovery failed"
  [ ! -e "$stale_config" ] || fail "proven-stale config candidate was not recovered"
  [ ! -e "$stale_certificate" ] || fail "proven-stale certificate candidate was not recovered"
  [ ! -e "$stale_helper" ] || fail "proven-stale helper candidate was not recovered"
  [ -e "$foreign_config" ] || fail "non-numeric foreign candidate was deleted"
  [ -e "$foreign_certificate" ] || fail "wrong-mode indeterminate candidate was deleted"
  [ -e "$indeterminate_certificate" ] || fail "output-bearing indeterminate PID candidate was deleted"

  raced_config="$config.candidate.999999"
  raced_original="$raced_config.original"
  ready="$dir/remove-ready"
  proceed="$dir/remove-proceed"
  printf 'attributed generation\n' > "$raced_config"
  chmod 600 "$raced_config"
  touch -t 202001010000 "$raced_config"
  FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
    FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$raced_config" \
    FM_TEST_HERDR_ARTIFACT_REMOVE_READY="$ready" \
    FM_TEST_HERDR_ARTIFACT_REMOVE_PROCEED="$proceed" \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_artifact_recover_candidates "$1" 0600
    ' "$ROOT" "$config" >/dev/null 2>&1 &
  recovery_pid=$!
  for _attempt in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill "$recovery_pid" 2>/dev/null || true; fail "artifact substitution fixture never reached its final mutation barrier"; }
  mv "$raced_config" "$raced_original"
  printf 'foreign replacement\n' > "$raced_config"
  chmod 600 "$raced_config"
  : > "$proceed"
  wait "$recovery_pid" >/dev/null 2>&1 \
    && fail "candidate cleanup accepted a last-check-to-rename substitution"
  preserved=
  for candidate in "$raced_config".quarantine.*/artifact; do
    [ -f "$candidate" ] || continue
    preserved=$candidate
    break
  done
  [ -n "$preserved" ] && [ "$(cat "$preserved")" = 'foreign replacement' ] \
    || fail "candidate cleanup deleted or lost the substituted foreign generation"
  [ "$(cat "$raced_original")" = 'attributed generation' ] \
    || fail "candidate cleanup mutated the originally attributed generation after substitution"
  pass "managed artifact recovery deletes only proven generations and quarantines last-check substitutions without data loss"
}

# Literal programs are intentionally passed to isolated Bash subprocesses.
# shellcheck disable=SC2016
test_managed_artifact_recovers_every_published_pair_crash_boundary() {
  local dir lock_root source ps_fake helper helper_candidate helper_marker recovered
  local config config_candidate config_marker helper_quarantine_marker helper_quarantine
  local helper_mkdir_marker helper_mkdir_quarantine config_mkdir_marker config_mkdir_quarantine
  local empty_marker config_empty_quarantine foreign foreign_candidate helper_before
  local substitution_config substitution_candidate substitution_marker substitution_ready substitution_proceed
  local substitution_original substitution_expected recovery_pid recovery_status artifact
  dir="$TMP_ROOT/herdr-published-pair-crashes"
  lock_root="$dir/locks"
  source="$dir/fm-herdr-worker-shell"
  ps_fake="$dir/fake-ps"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  lock_root=$(cd "$lock_root" && pwd -P) || fail "could not resolve artifact test lock root"
  cp "$ROOT/bin/fm-herdr-worker-shell" "$source"
  chmod 755 "$source"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
exit 1
SH
  chmod 755 "$ps_fake"

  artifact_inode() {
    if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$1"; else stat -c '%d:%i' "$1"; fi
  }
  artifact_nlink() {
    if [ "$(uname)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi
  }
  first_candidate() {
    local found
    for found in "$1".candidate.*; do
      [ -f "$found" ] || continue
      printf '%s\n' "$found"
      return 0
    done
    return 1
  }
  first_candidate_quarantine() {
    local found
    for found in "$1".candidate.*.quarantine.*; do
      [ -d "$found" ] || continue
      printf '%s\n' "$found"
      return 0
    done
    return 1
  }
  artifact_bash() {
    local program=$1
    shift
    PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
      FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
      FM_TEST_HERDR_KILL_AFTER_HELPER_LINK="${FM_TEST_HERDR_KILL_AFTER_HELPER_LINK:-}" \
      FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK="${FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK:-}" \
      FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK:-}" \
      FM_TEST_HERDR_ARTIFACT_PAIR_TARGET="${FM_TEST_HERDR_ARTIFACT_PAIR_TARGET:-}" \
      FM_TEST_HERDR_ARTIFACT_PAIR_READY="${FM_TEST_HERDR_ARTIFACT_PAIR_READY:-}" \
      FM_TEST_HERDR_ARTIFACT_PAIR_PROCEED="${FM_TEST_HERDR_ARTIFACT_PAIR_PROCEED:-}" \
      /bin/bash --noprofile --norc -c "$program" "$ROOT" "$@"
  }

  # Helper: kill immediately after no-replace link publication, then converge
  # the exact target/candidate nlink=2 pair to one validated target.
  helper_marker="$dir/helper-linked"
  if FM_TEST_HERDR_KILL_AFTER_HELPER_LINK="$helper_marker" \
    artifact_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin' \
      >/dev/null 2>&1; then
    fail "managed helper publisher survived its post-link SIGKILL fixture"
  fi
  [ -e "$helper_marker" ] || fail "managed helper publisher never reached its post-link kill boundary"
  helper=
  for artifact in "$lock_root"/managed-worker-shell-v1-*; do
    case "$artifact" in *.candidate.*|*.quarantine.*) continue ;; esac
    [ -f "$artifact" ] || continue
    helper=$artifact
    break
  done
  [ -n "$helper" ] || fail "killed helper publisher left no installed target"
  helper_candidate=$(first_candidate "$helper") || fail "killed helper publisher left no candidate alias"
  if [ "$(artifact_inode "$helper")" != "$(artifact_inode "$helper_candidate")" ] \
    || [ "$(artifact_nlink "$helper")" -ne 2 ]; then
    fail "killed helper publisher did not leave one exact two-link inode"
  fi
  touch -t 202001010000 "$helper_candidate"
  helper_mkdir_marker="$dir/helper-quarantine-created"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$helper_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$helper_mkdir_marker" \
    artifact_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin' \
      >/dev/null 2>&1; then
    fail "managed helper recovery survived its post-quarantine-mkdir SIGKILL fixture"
  fi
  [ -e "$helper_mkdir_marker" ] || fail "managed helper never reached its post-quarantine-mkdir kill boundary"
  helper_mkdir_quarantine=$(first_candidate_quarantine "$helper") \
    || fail "managed helper mkdir crash left no attributed quarantine"
  if [ ! -e "$helper_candidate" ] || [ -e "$helper_mkdir_quarantine/artifact" ]; then
    fail "managed helper mkdir crash did not retain the public pair and exact empty quarantine"
  fi
  touch -t 202001010000 "$helper_mkdir_quarantine"
  recovered=$(artifact_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin') \
    || fail "managed helper did not recover its killed post-link publisher"
  if [ ! -e "$recovered" ] \
    || [ "$(artifact_inode "$recovered")" != "$(artifact_inode "$helper")" ] \
    || [ -e "$helper_candidate" ] \
    || [ "$(artifact_nlink "$helper")" -ne 1 ]; then
    fail "managed helper post-link recovery did not converge to one validated target"
  fi

  # Config: exercise the same direct post-link recovery independently.
  config=$(artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_path fm-config-link "$1"
  ' "$helper") || fail "could not derive post-link config path"
  config_marker="$dir/config-linked"
  if FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK="$config_marker" artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_ensure fm-config-link "$1"
  ' "$helper" >/dev/null 2>&1; then
    fail "managed config publisher survived its post-link SIGKILL fixture"
  fi
  [ -e "$config_marker" ] || fail "managed config publisher never reached its post-link kill boundary"
  config_candidate=$(first_candidate "$config") || fail "killed config publisher left no candidate alias"
  if [ "$(artifact_inode "$config")" != "$(artifact_inode "$config_candidate")" ] \
    || [ "$(artifact_nlink "$config")" -ne 2 ]; then
    fail "killed config publisher did not leave one exact two-link inode"
  fi
  touch -t 202001010000 "$config_candidate"
  config_mkdir_marker="$dir/config-quarantine-created"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$config_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$config_mkdir_marker" artifact_bash '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_managed_config_ensure fm-config-link "$1"
    ' "$helper" >/dev/null 2>&1; then
    fail "managed config recovery survived its post-quarantine-mkdir SIGKILL fixture"
  fi
  [ -e "$config_mkdir_marker" ] || fail "managed config never reached its post-quarantine-mkdir kill boundary"
  config_mkdir_quarantine=$(first_candidate_quarantine "$config") \
    || fail "managed config mkdir crash left no attributed quarantine"
  if [ ! -e "$config_candidate" ] || [ -e "$config_mkdir_quarantine/artifact" ]; then
    fail "managed config mkdir crash did not retain the public pair and exact empty quarantine"
  fi
  touch -t 202001010000 "$config_mkdir_quarantine"
  recovered=$(artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_ensure fm-config-link "$1"
  ' "$helper") || fail "managed config did not recover its killed post-link publisher"
  if [ ! -e "$recovered" ] \
    || [ "$(artifact_inode "$recovered")" != "$(artifact_inode "$config")" ] \
    || [ -e "$config_candidate" ] \
    || [ "$(artifact_nlink "$config")" -ne 1 ]; then
    fail "managed config post-link recovery did not converge to one validated target"
  fi

  # Kill after the helper candidate alias has moved to its attributed
  # quarantine but before unlink. The next call must recover that exact
  # target/quarantine-artifact pair and remove the quarantine.
  printf '\n# second helper generation\n' >> "$source"
  helper_quarantine_marker="$dir/helper-quarantined"
  if FM_TEST_HERDR_KILL_AFTER_HELPER_LINK="$dir/helper-linked-2" artifact_bash \
    '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin' >/dev/null 2>&1; then
    fail "second helper publisher survived its post-link SIGKILL fixture"
  fi
  helper=
  for artifact in "$lock_root"/managed-worker-shell-v1-*; do
    case "$artifact" in *.candidate.*|*.quarantine.*) continue ;; esac
    [ -f "$artifact" ] || continue
    [ "$(artifact_nlink "$artifact")" -eq 2 ] || continue
    helper=$artifact
    break
  done
  [ -n "$helper" ] || fail "second killed helper publisher left no two-link target"
  helper_candidate=$(first_candidate "$helper") || fail "second killed helper publisher left no candidate"
  touch -t 202001010000 "$helper_candidate"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$helper_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE="$helper_quarantine_marker" \
    artifact_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin' \
      >/dev/null 2>&1; then
    fail "helper recovery survived its post-quarantine SIGKILL fixture"
  fi
  [ -e "$helper_quarantine_marker" ] || fail "helper recovery never reached its post-quarantine kill boundary"
  [ ! -e "$helper_candidate" ] || fail "post-quarantine helper crash retained the public candidate alias"
  helper_quarantine=$(first_candidate_quarantine "$helper") \
    || fail "post-quarantine helper crash left no recoverable quarantine"
  if [ ! -f "$helper_quarantine/artifact" ] \
    || [ "$(artifact_inode "$helper_quarantine/artifact")" != "$(artifact_inode "$helper")" ]; then
    fail "post-quarantine helper crash lost its attributed target alias"
  fi
  touch -t 202001010000 "$helper_quarantine" "$helper_quarantine/artifact"
  recovered=$(artifact_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_managed_shell_bin') \
    || fail "managed helper did not recover its post-quarantine crash"
  if [ ! -e "$recovered" ] \
    || [ "$(artifact_inode "$recovered")" != "$(artifact_inode "$helper")" ] \
    || [ -e "$helper_quarantine" ] \
    || [ "$(artifact_nlink "$helper")" -ne 1 ]; then
    fail "post-quarantine helper recovery did not converge without transients"
  fi

  # Kill after the config candidate's quarantined alias is unlinked but before
  # rmdir. Recovery must prove the target inode and remove only the empty owned
  # quarantine.
  config=$(artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_path fm-config-empty-q "$1"
  ' "$helper") || fail "could not derive empty-quarantine config path"
  if FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK="$dir/config-linked-2" artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_ensure fm-config-empty-q "$1"
  ' "$helper" >/dev/null 2>&1; then
    fail "second config publisher survived its post-link SIGKILL fixture"
  fi
  config_candidate=$(first_candidate "$config") || fail "second killed config publisher left no candidate"
  touch -t 202001010000 "$config_candidate"
  empty_marker="$dir/config-artifact-unlinked"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$config_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK="$empty_marker" artifact_bash '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_managed_config_ensure fm-config-empty-q "$1"
    ' "$helper" >/dev/null 2>&1; then
    fail "config recovery survived its post-unlink SIGKILL fixture"
  fi
  [ -e "$empty_marker" ] || fail "config recovery never reached its post-unlink kill boundary"
  config_empty_quarantine=$(first_candidate_quarantine "$config") \
    || fail "post-unlink config crash left no empty quarantine"
  if [ -e "$config_empty_quarantine/artifact" ] \
    || [ "$(artifact_nlink "$config")" -ne 1 ]; then
    fail "post-unlink config crash did not preserve exactly one target alias"
  fi
  touch -t 202001010000 "$config_empty_quarantine"
  recovered=$(artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_ensure fm-config-empty-q "$1"
  ' "$helper") || fail "managed config did not recover its empty quarantine"
  if [ ! -e "$recovered" ] \
    || [ "$(artifact_inode "$recovered")" != "$(artifact_inode "$config")" ] \
    || [ -e "$config_empty_quarantine" ]; then
    fail "empty config quarantine recovery did not converge"
  fi

  # A stale two-link candidate that is not the target's inode is foreign and
  # must block recovery without losing either generation.
  helper_before=$(cat "$helper")
  foreign="$dir/foreign-helper"
  foreign_candidate="$helper.candidate.999999"
  printf 'foreign helper generation\n' > "$foreign"
  chmod 500 "$foreign"
  ln "$foreign" "$foreign_candidate"
  touch -t 202001010000 "$foreign_candidate"
  if artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_artifact_recover_candidates "$1" 0500
  ' "$helper" >/dev/null 2>&1; then
    fail "foreign two-link helper candidate was accepted as a published pair"
  fi
  if [ "$(cat "$helper")" != "$helper_before" ] \
    || [ ! -e "$foreign" ] \
    || [ ! -e "$foreign_candidate" ]; then
    fail "foreign two-link refusal deleted or changed a generation"
  fi

  # Substitute the config target after the last pair proof and before the
  # candidate's quarantine rename. Recovery may delete its attributed stale
  # alias, but must refuse and preserve both the substituted target and the
  # displaced original generation.
  substitution_config=$(artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_path fm-config-substitute "$1"
  ' "$helper") || fail "could not derive substitution config path"
  substitution_marker="$dir/config-linked-substitute"
  if FM_TEST_HERDR_KILL_AFTER_CONFIG_LINK="$substitution_marker" artifact_bash '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_managed_config_ensure fm-config-substitute "$1"
  ' "$helper" >/dev/null 2>&1; then
    fail "substitution config publisher survived its post-link SIGKILL fixture"
  fi
  substitution_candidate=$(first_candidate "$substitution_config") \
    || fail "substitution fixture left no published candidate pair"
  touch -t 202001010000 "$substitution_candidate"
  substitution_expected=$(cat "$substitution_config")
  substitution_original="$substitution_config.attributed"
  substitution_ready="$dir/pair-ready"
  substitution_proceed="$dir/pair-proceed"
  FM_TEST_HERDR_ARTIFACT_PAIR_TARGET="$substitution_config" \
    FM_TEST_HERDR_ARTIFACT_PAIR_READY="$substitution_ready" \
    FM_TEST_HERDR_ARTIFACT_PAIR_PROCEED="$substitution_proceed" artifact_bash '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_artifact_recover_candidates "$1" 0600
    ' "$substitution_config" >/dev/null 2>&1 &
  recovery_pid=$!
  for _attempt in $(seq 1 100); do [ -e "$substitution_ready" ] && break; sleep 0.02; done
  [ -e "$substitution_ready" ] \
    || { kill "$recovery_pid" 2>/dev/null || true; fail "published-pair recovery never reached its substitution barrier"; }
  mv "$substitution_config" "$substitution_original"
  printf 'foreign substituted config\n' > "$substitution_config"
  chmod 600 "$substitution_config"
  : > "$substitution_proceed"
  if wait "$recovery_pid" >/dev/null 2>&1; then recovery_status=0; else recovery_status=$?; fi
  [ "$recovery_status" -ne 0 ] || fail "published-pair recovery accepted a substituted target generation"
  if [ "$(cat "$substitution_config")" != 'foreign substituted config' ] \
    || [ "$(cat "$substitution_original")" != "$substitution_expected" ]; then
    fail "published-pair substitution refusal deleted or changed a target generation"
  fi
  pass "managed helper/config publication recovers every two-link cleanup crash boundary and refuses foreign/substituted pairs"
}

# Literal programs are intentionally passed to isolated Bash subprocesses.
# shellcheck disable=SC2016
test_attributed_cleanup_recovers_nlink1_and_exact_lock_release_phases() {
  local dir lock_root ps_fake lock candidate quarantine marker phase hook_mkdir hook_moved hook_unlinked
  local original occupied_candidate occupied_quarantine substituted_candidate substituted_quarantine
  local substitution_lock occupied_lock
  dir="$TMP_ROOT/herdr-attributed-cleanup-phases"
  lock_root="$dir/locks"
  ps_fake="$dir/fake-ps"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  lock_root=$(cd "$lock_root" && pwd -P) || fail "could not resolve attributed-cleanup lock root"
  lock="$lock_root/lifecycle.lock"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
pid=
for argument in "$@"; do pid=$argument; done
[ "$pid" != 999999 ] || exit 1
kill -0 "$pid" 2>/dev/null || exit 1
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"

  first_attributed_quarantine() {
    local found
    for found in "$1".quarantine.*; do
      [ -d "$found" ] || continue
      printf '%s\n' "$found"
      return 0
    done
    return 1
  }
  cleanup_bash() {
    local program=$1
    shift
    PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
      FM_TEST_HERDR_PS_BIN="$ps_fake" \
      FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="${FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE:-}" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK="${FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK:-}" \
      /bin/bash --noprofile --norc -c "$program" "$ROOT" "$@"
  }
  write_dead_candidate() {
    printf '999999\nMon Jan  1 00:00:00 2024\n%s\n' "${1##*.candidate.}" > "$1"
    chmod 600 "$1"
    touch -t 202001010000 "$1"
  }

  # Lifecycle lock candidates can be nlink=1 when publication never happened.
  # Crash each phase of their attributed deletion and require convergence.
  for phase in mkdir moved unlinked; do
    candidate="$lock.candidate.999999-nlink1-$phase"
    marker="$dir/nlink1-$phase"
    write_dead_candidate "$candidate"
    hook_mkdir=
    hook_moved=
    hook_unlinked=
    case "$phase" in
      mkdir) hook_mkdir=$marker ;;
      moved) hook_moved=$marker ;;
      unlinked) hook_unlinked=$marker ;;
    esac
    if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$candidate" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$hook_mkdir" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE="$hook_moved" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK="$hook_unlinked" cleanup_bash '
        . "$0/bin/backends/herdr.sh"
        fm_backend_herdr_server_lock_recover_candidates "$1"
      ' "$lock" >/dev/null 2>&1; then
      fail "nlink1 lifecycle candidate survived its $phase cleanup SIGKILL fixture"
    fi
    [ -e "$marker" ] || fail "nlink1 lifecycle candidate never reached its $phase crash boundary"
    quarantine=$(first_attributed_quarantine "$candidate") \
      || fail "nlink1 $phase crash left no attributed quarantine"
    touch -t 202001010000 "$quarantine"
    [ ! -e "$quarantine/artifact" ] || touch -t 202001010000 "$quarantine/artifact"
    [ ! -e "$candidate" ] || touch -t 202001010000 "$candidate"
    cleanup_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_recover_candidates "$1"' \
      "$lock" >/dev/null 2>&1 || fail "nlink1 lifecycle candidate did not recover its $phase crash"
    if [ -e "$candidate" ] || [ -e "$quarantine" ]; then
      fail "nlink1 lifecycle candidate left residue after $phase recovery"
    fi
  done

  # Exact release of the owned lifecycle lock uses the same primitive. Build
  # the record inside the killed process so release ownership is authentic.
  for phase in mkdir moved unlinked; do
    marker="$dir/release-$phase"
    hook_mkdir=
    hook_moved=
    hook_unlinked=
    case "$phase" in
      mkdir) hook_mkdir=$marker ;;
      moved) hook_moved=$marker ;;
      unlinked) hook_unlinked=$marker ;;
    esac
    if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$lock" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$hook_mkdir" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE="$hook_moved" \
      FM_TEST_HERDR_KILL_AFTER_ARTIFACT_UNLINK="$hook_unlinked" cleanup_bash '
        . "$0/bin/backends/herdr.sh"
        pid=${BASHPID:-$$}
        start=$(fm_backend_herdr_process_start "$pid") || exit 2
        token="release-$1"
        (umask 077; printf "%s\n%s\n%s\n" "$pid" "$start" "$token" > "$2") || exit 3
        chmod 600 "$2" || exit 4
        inode=$(fm_backend_herdr_path_inode "$2") || exit 5
        fm_backend_herdr_server_lock_release "$2" "$token" "$inode"
      ' "$phase" "$lock" >/dev/null 2>&1; then
      fail "exact lock release survived its $phase cleanup SIGKILL fixture"
    fi
    [ -e "$marker" ] || fail "exact lock release never reached its $phase crash boundary"
    quarantine=$(first_attributed_quarantine "$lock") \
      || fail "exact lock $phase crash left no attributed quarantine"
    touch -t 202001010000 "$quarantine"
    [ ! -e "$quarantine/artifact" ] || touch -t 202001010000 "$quarantine/artifact"
    [ ! -e "$lock" ] || touch -t 202001010000 "$lock"
    cleanup_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_recover_quarantines "$1"' \
      "$lock" >/dev/null 2>&1 || fail "exact lock release did not recover its $phase crash"
    if [ -e "$lock" ] || [ -e "$quarantine" ]; then
      fail "exact lock release left residue after $phase recovery"
    fi
  done

  # A foreign replacement at the empty-quarantine boundary is preserved, as
  # is an occupied private quarantine; neither can be guessed away.
  substitution_lock="$lock_root/substitution.lock"
  substituted_candidate="$substitution_lock.candidate.999999-substituted"
  write_dead_candidate "$substituted_candidate"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$substituted_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$dir/substituted-mkdir" cleanup_bash '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_recover_candidates "$1"
    ' "$substitution_lock" >/dev/null 2>&1; then
    fail "substitution fixture survived its quarantine-mkdir SIGKILL"
  fi
  substituted_quarantine=$(first_attributed_quarantine "$substituted_candidate") \
    || fail "substitution fixture left no empty quarantine"
  original="$substituted_candidate.original"
  mv "$substituted_candidate" "$original"
  write_dead_candidate "$substituted_candidate"
  touch -t 202001010000 "$substituted_quarantine"
  if cleanup_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_recover_candidates "$1"' \
    "$substitution_lock" >/dev/null 2>&1; then
    fail "attributed recovery accepted a foreign substituted lifecycle candidate"
  fi
  if [ ! -e "$original" ] || [ ! -e "$substituted_candidate" ] || [ ! -e "$substituted_quarantine" ]; then
    fail "substituted lifecycle candidate refusal lost a generation"
  fi

  occupied_lock="$lock_root/occupied.lock"
  occupied_candidate="$occupied_lock.candidate.999999-occupied"
  write_dead_candidate "$occupied_candidate"
  if FM_TEST_HERDR_ARTIFACT_REMOVE_TARGET="$occupied_candidate" \
    FM_TEST_HERDR_KILL_AFTER_ARTIFACT_QUARANTINE_MKDIR="$dir/occupied-mkdir" cleanup_bash '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_recover_candidates "$1"
    ' "$occupied_lock" >/dev/null 2>&1; then
    fail "occupied fixture survived its quarantine-mkdir SIGKILL"
  fi
  occupied_quarantine=$(first_attributed_quarantine "$occupied_candidate") \
    || fail "occupied fixture left no empty quarantine"
  printf 'foreign quarantine content\n' > "$occupied_quarantine/foreign"
  touch -t 202001010000 "$occupied_candidate" "$occupied_quarantine"
  if cleanup_bash '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_recover_candidates "$1"' \
    "$occupied_lock" >/dev/null 2>&1; then
    fail "attributed recovery accepted an occupied lifecycle quarantine"
  fi
  if [ ! -e "$occupied_candidate" ] || [ ! -e "$occupied_quarantine/foreign" ]; then
    fail "occupied lifecycle quarantine refusal lost foreign state"
  fi
  pass "attributed cleanup recovers every nlink1 candidate and exact-lock phase while preserving foreign/occupied states"
}

test_server_ensure_routes_occupied_adapter_owned_release_drift_without_restart() {
  local dir fb fake source ps_fake default_fleet default_before default_after case_dir lock_root running pids state log mutation old_pid new_pid out status
  # This fixture exercises the legacy certified-lifecycle lab path retained
  # behind FM_TEST_HERDR_REQUIRE_CERT_LIFECYCLE:
  # - release-drifted means the running process has a valid adapter-owned
  #   legacy certificate but not the current release's closed-shell certificate;
  # - occupied means the exact named session reports at least one workspace,
  #   tab, or pane;
  # - restarted means that exact session is stopped and a new server is launched;
  # - routed means container ensure continues in the same running session and
  #   reaches workspace creation for the native-agent spawn path.
  dir="$TMP_ROOT/herdr-certified-lifecycle"
  fb="$dir/fakebin"
  fake="$fb/herdr"
  source="$dir/fm-herdr-worker-shell"
  default_fleet="$dir/default-fleet"
  mkdir -p "$fb"
  printf '%s\n' '{"workspaces":[{"workspace_id":"captain","tabs":["captain:t1"],"panes":["captain:p1"]}]}' \
    > "$default_fleet"
  default_before=$(cat "$default_fleet")
  cp "$ROOT/bin/fm-herdr-worker-shell" "$source"
  chmod 755 "$source"
  ps_fake="$dir/fake-ps"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
pid=
for argument in "$@"; do pid=$argument; done
kill -0 "$pid" 2>/dev/null || exit 1
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
set -u
targets_default=false
[ "${HERDR_SESSION:-}" = default ] && targets_default=true
arguments=("$@")
for ((index=0; index<${#arguments[@]}; index++)); do
  case "${arguments[$index]}" in
    --session=default) targets_default=true ;;
    --session)
      [ "${arguments[$((index + 1))]:-}" = default ] && targets_default=true
      ;;
  esac
done
if [ "${arguments[0]:-}" = session ] && [ "${arguments[1]:-}" != list ]; then
  for ((index=2; index<${#arguments[@]}; index++)); do
    [ "${arguments[$index]}" = default ] && targets_default=true
  done
fi
if [ "$targets_default" = true ]; then
  printf -v offending_command '%q ' "$@"
  printf 'fake Herdr command targeting default is forbidden: %s\n' \
    "${offending_command% }" >&2
  exit 72
fi
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for argument in "$@"; do printf '\x1f%s' "$argument"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
mode=$(cat "${FM_FAKE_HERDR_STATE:?}")
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then running=true; else running=false; fi
    printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":%s}}\n' "$running"
    ;;
  "workspace list")
    case "$mode" in
      empty) printf '{"result":{"workspaces":[]}}\n' ;;
      occupied) printf '{"result":{"workspaces":[{"workspace_id":"foreign-w1","label":"captain"}]}}\n' ;;
      indeterminate) printf '{not-json\n' ;;
    esac
    ;;
  "tab list") printf '{"result":{"tabs":[]}}\n' ;;
  "pane list") printf '{"result":{"panes":[]}}\n' ;;
  "session stop")
    [ "${3:-}" = "${HERDR_SESSION:-}" ] || exit 71
    kill "$(tail -1 "${FM_FAKE_HERDR_SERVER_PIDS:?}")" 2>/dev/null || true
    rm -f "$FM_FAKE_HERDR_RUNNING"
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    : > "$FM_FAKE_HERDR_RUNNING"
    exec /bin/sleep 120
    ;;
  "workspace create")
    : > "${FM_FAKE_HERDR_MUTATION:?}"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
esac
SH
  chmod 755 "$fake"

  write_legacy_certificate() {
    PATH="$fb:/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
      FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" OLD_PID="$old_pid" \
      /bin/bash --noprofile --norc -c '
        . "$0/bin/backends/herdr.sh"
        key=$(fm_backend_herdr_server_lock_key "$1") || exit 1
        certificate=$(fm_backend_herdr_server_legacy_env_certificate_path "$1") || exit 1
        start=$(fm_backend_herdr_process_start "$OLD_PID") || exit 1
        printf "firstmate-herdr-closed-env-v1\n%s\n%s\n%s\n" \
          "$key" "$OLD_PID" "$start" > "$certificate" || exit 1
        chmod 600 "$certificate"
      ' "$ROOT" "$1"
  }

  case_dir="$dir/empty"
  lock_root="$case_dir/locks"
  running="$case_dir/running"
  pids="$case_dir/pids"
  state="$case_dir/state"
  log="$case_dir/log"
  mutation="$case_dir/workspace-created"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  printf 'empty\n' > "$state"
  : > "$log"
  /bin/sleep 120 & old_pid=$!
  printf '%s\n' "$old_pid" > "$pids"
  : > "$running"
  write_legacy_certificate fm-empty \
    || fail "could not establish legacy adapter ownership for empty restart"
  if out=$(PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_HERDR_MUTATION="$mutation" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_REQUIRE_CERT_LIFECYCLE=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 HERDR_SESSION=fm-empty \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_ensure fm-empty || exit 1
      fm_backend_herdr_server_closed_shell_environment_ready fm-empty
    ' "$ROOT" 2>&1); then status=0; else status=$?; fi
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    sed 's/^/herdr: /' "$log" >&2
    fail "adapter-owned exact-empty drift did not stop, relaunch, and recertify"
  fi
  wait "$old_pid" >/dev/null 2>&1 || true
  kill -0 "$old_pid" 2>/dev/null \
    && fail "exact-empty restart left the release-drifted adapter server alive"
  new_pid=$(tail -1 "$pids")
  if [ "$new_pid" = "$old_pid" ] || ! kill -0 "$new_pid" 2>/dev/null; then
    fail "exact-empty restart did not leave one newly certified server alive"
  fi
  assert_grep $'\x1fsession\x1fstop\x1ffm-empty\x1f--json\x1f--session\x1ffm-empty' "$log" \
    "empty drift restart did not use the positional exact lab session stop"
  assert_no_grep $'\x1fserver\x1fstop' "$log" \
    "empty drift restart used a generic server stop"
  assert_no_grep $'\x1fsession\x1fdelete' "$log" \
    "empty drift restart deleted session state"
  [ ! -e "$mutation" ] || fail "server lifecycle decision created a workspace before recertification"
  kill "$new_pid" 2>/dev/null || true

  case_dir="$dir/occupied"
  lock_root="$case_dir/locks"
  running="$case_dir/running"
  pids="$case_dir/pids"
  state="$case_dir/state"
  log="$case_dir/log"
  mutation="$case_dir/workspace-created"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  printf 'occupied\n' > "$state"
  : > "$log"
  /bin/sleep 120 & old_pid=$!
  printf '%s\n' "$old_pid" > "$pids"
  : > "$running"
  write_legacy_certificate fm-occupied \
    || fail "could not establish release-drifted adapter ownership for occupied routing"
  if out=$(PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_HERDR_MUTATION="$mutation" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_REQUIRE_CERT_LIFECYCLE=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
    HERDR_SESSION=fm-occupied \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_container_ensure "$PWD"
    ' "$ROOT" 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$out" >&2
    fail "occupied release-drifted server did not continue routing"
  }
  assert_contains "$out" $'fm-occupied:w1\tw1:t1' \
    "occupied release-drifted routing did not return its same-session container"
  kill -0 "$old_pid" 2>/dev/null \
    || fail "occupied release-drifted routing restarted the existing adapter server"
  assert_no_grep $'\x1fsession\x1fstop' "$log" \
    "occupied release-drifted routing stopped the existing server"
  assert_no_grep $'\x1fserver\x1f--session' "$log" \
    "occupied release-drifted routing launched a replacement server"
  assert_grep $'\x1fworkspace\x1fcreate' "$log" \
    "occupied release-drifted routing did not reach workspace creation"
  [ -e "$mutation" ] \
    || fail "occupied release-drifted routing did not reach workspace creation"
  kill "$old_pid" 2>/dev/null || true
  wait "$old_pid" >/dev/null 2>&1 || true

  case_dir="$dir/indeterminate"
  lock_root="$case_dir/locks"
  running="$case_dir/running"
  pids="$case_dir/pids"
  state="$case_dir/state"
  log="$case_dir/log"
  mutation="$case_dir/workspace-created"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  printf 'indeterminate\n' > "$state"
  : > "$log"
  /bin/sleep 120 & old_pid=$!
  printf '%s\n' "$old_pid" > "$pids"
  : > "$running"
  write_legacy_certificate fm-indeterminate \
    || fail "could not establish release-drifted adapter ownership for indeterminate refusal"
  if out=$(PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_HERDR_MUTATION="$mutation" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_REQUIRE_CERT_LIFECYCLE=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" FM_TEST_HERDR_MANAGED_SHELL_SOURCE="$source" \
    HERDR_SESSION=fm-indeterminate \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_container_ensure "$PWD"
    ' "$ROOT" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "indeterminate release-drifted server was routed"
  assert_contains "$out" "indeterminate" "indeterminate drift refusal was not explicit"
  kill -0 "$old_pid" 2>/dev/null \
    || fail "indeterminate drift refusal stopped the existing adapter server"
  assert_no_grep $'\x1fsession\x1fstop' "$log" \
    "indeterminate drift refusal stopped the server before its lifecycle decision"
  assert_no_grep $'\x1fserver\x1f--session' "$log" \
    "indeterminate drift refusal launched a server before its lifecycle decision"
  assert_no_grep $'\x1fworkspace\x1fcreate' "$log" \
    "indeterminate drift refusal created a workspace before its lifecycle decision"
  [ ! -e "$mutation" ] || fail "indeterminate drift refusal reached workspace creation"
  kill "$old_pid" 2>/dev/null || true
  wait "$old_pid" >/dev/null 2>&1 || true

  default_after=$(cat "$default_fleet")
  [ "$default_after" = "$default_before" ] \
    || fail "certified lifecycle validation changed the default fleet state"
  assert_no_grep 'HERDR_SESSION=default' "$dir/empty/log" \
    "empty lifecycle validation addressed the default Herdr session"
  assert_no_grep 'HERDR_SESSION=default' "$dir/occupied/log" \
    "occupied lifecycle validation addressed the default Herdr session"
  assert_no_grep 'HERDR_SESSION=default' "$dir/indeterminate/log" \
    "indeterminate lifecycle validation addressed the default Herdr session"

  pass "server ensure serializes certificate drift: exact-empty restarts, occupied routes without restart, and indeterminate refuses"
}

test_server_lock_root_rejects_unsafe_parent_and_ignores_tmpdir() {
  local dir unsafe lock_root out status
  dir="$TMP_ROOT/herdr-lock-ancestry"
  unsafe="$dir/public-parent"
  lock_root="$unsafe/locks"
  mkdir -p "$unsafe"
  chmod 777 "$unsafe"
  if FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_server_lock_root_prepare
  ' "$ROOT" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "Herdr accepted a lock root below a writable non-sticky parent"

  # $0 belongs to the nested Bash process.
  # shellcheck disable=SC2016
  out=$(env -u FM_BACKEND_HERDR_TEST_LAB -u FM_BACKEND_HERDR_SERVER_LOCK_ROOT \
    TMPDIR="$unsafe" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root
    ' "$ROOT") || fail "production lock root could not be resolved with hostile TMPDIR"
  case "$out" in "$unsafe"/*) fail "production Herdr lock root trusted hostile TMPDIR: $out" ;; esac
  pass "Herdr lock-root resolution rejects unsafe ancestry and ignores ambient TMPDIR"
}

# --- workspace_label: per-firstmate-HOME resolution (P3, herdr-sm-spaces-k4) -

test_workspace_label_primary_home_no_marker() {
  local home
  home="$TMP_ROOT/primary-home-no-marker"; mkdir -p "$home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "firstmate" ] || fail "a primary home (no .fm-secondmate-home marker) should resolve to label 'firstmate', got '$out'"
  pass "fm_backend_herdr_workspace_label: a primary home (no marker) resolves to 'firstmate'"
}

test_workspace_label_secondmate_home_uses_marker_id() {
  local home
  home="$TMP_ROOT/secondmate-home"; mkdir -p "$home"
  printf 'sshhip-h7\n' > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "2ndmate-sshhip-h7" ] || fail "a secondmate home should resolve to '2ndmate-<id>', got '$out'"
  pass "fm_backend_herdr_workspace_label: a secondmate home (.fm-secondmate-home) resolves to '2ndmate-<id>'"
}

test_workspace_label_secondmate_marker_trims_whitespace() {
  local home
  home="$TMP_ROOT/secondmate-home-ws"; mkdir -p "$home"
  printf '  sshhip-h7  \n\n' > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "2ndmate-sshhip-h7" ] || fail "the marker id should be trimmed of surrounding whitespace, got '$out'"
  pass "fm_backend_herdr_workspace_label: trims whitespace around the marker's secondmate id"
}

test_workspace_label_empty_marker_falls_back_to_primary() {
  local home
  home="$TMP_ROOT/secondmate-home-empty"; mkdir -p "$home"
  : > "$home/.fm-secondmate-home"
  out=$( FM_HOME="$home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out" = "firstmate" ] || fail "an empty/unreadable marker should fall back to 'firstmate', got '$out'"
  pass "fm_backend_herdr_workspace_label: an empty marker file falls back to the primary label 'firstmate'"
}

test_workspace_label_different_secondmates_get_different_labels() {
  local home1 home2 out1 out2
  home1="$TMP_ROOT/secondmate-a"; mkdir -p "$home1"; printf 'alpha-a1\n' > "$home1/.fm-secondmate-home"
  home2="$TMP_ROOT/secondmate-b"; mkdir -p "$home2"; printf 'bravo-b2\n' > "$home2/.fm-secondmate-home"
  out1=$( FM_HOME="$home1" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  out2=$( FM_HOME="$home2" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT" )
  [ "$out1" = "2ndmate-alpha-a1" ] || fail "secondmate home1 label mismatch: $out1"
  [ "$out2" = "2ndmate-bravo-b2" ] || fail "secondmate home2 label mismatch: $out2"
  [ "$out1" != "$out2" ] || fail "two different secondmate homes must not collide on the same label"
  pass "fm_backend_herdr_workspace_label: two different secondmate homes get two different, non-colliding labels"
}

# --- fm_backend_herdr_cli: session targeting (2026-07-02 incident fix) -------

test_cli_helper_sets_env_and_appends_trailing_session_flag() {
  local dir log resp fb
  dir="$TMP_ROOT/cli-helper"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_cli fmtest workspace list' "$ROOT"
  expect_code 0 $? "fm_backend_herdr_cli should succeed"
  assert_contains "$(cat "$log")" "HERDR_SESSION=fmtest"$'\x1f''workspace'$'\x1f''list' \
    "fm_backend_herdr_cli did not set the HERDR_SESSION env var"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''list'$'\x1f''--session'$'\x1f''fmtest' \
    "fm_backend_herdr_cli did not append a trailing --session <name> flag (the fix for the env-var-alone routing bug)"
  pass "fm_backend_herdr_cli: sets HERDR_SESSION AND appends a trailing --session flag on every call"
}

test_cli_helper_scrubs_loader_and_runtime_injection() {
  local dir fb log evil marker path_marker out
  dir="$TMP_ROOT/cli-loader-scrub"
  fb="$dir/fakebin"
  log="$dir/env.log"
  evil="$dir/evil-bash-env"
  marker="$dir/injected"
  path_marker="$dir/path-injected"
  mkdir -p "$fb"
  cat > "$evil" <<SH
printf 'injected\n' > '$marker'
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' \
  "${LD_PRELOAD-}" "${DYLD_INSERT_LIBRARIES-}" "${NODE_OPTIONS-}" \
  "${PERL5OPT-}" "${BASH_ENV-}" > "$FM_HERDR_LOADER_LOG"
printf '{"result":{"workspaces":[]}}\n'
SH
  cat > "$fb/id" <<SH
#!/usr/bin/env bash
printf 'injected\n' > '$path_marker'
printf '99999\n'
SH
  chmod 755 "$fb/herdr" "$fb/id"
  PATH="$fb:$PATH" FM_HERDR_LOADER_LOG="$log" FM_HERDR_EVIL_ENV="$evil" \
    bash -c '
      export LD_PRELOAD=/tmp/hostile.so
      export DYLD_INSERT_LIBRARIES=/tmp/hostile.dylib
      export NODE_OPTIONS="--require /tmp/hostile-node.js"
      export PERL5OPT=-MHostile
      export BASH_ENV="$FM_HERDR_EVIL_ENV"
      . "$0/bin/backends/herdr.sh"
      control_uid=$(fm_backend_herdr_control_exec id -u) || exit 1
      case "$control_uid" in ""|*[!0-9]*) exit 1 ;; esac
      fm_backend_herdr_cli fmtest workspace list
    ' "$ROOT" > "$dir/out" || fail "scrubbed non-launch Herdr CLI call failed"
  out=$(cat "$log")
  [ "$out" = '||||' ] || fail "Herdr CLI inherited loader/runtime injection: $out"
  [ ! -e "$marker" ] || fail "Herdr CLI child sourced hostile BASH_ENV"
  [ ! -e "$path_marker" ] || fail "Herdr control utility resolved from hostile caller PATH"
  pass "fm_backend_herdr_cli: scrubs loader and language-runtime injection on ordinary control calls"
}

test_server_launch_detaches_from_callers_session() {
  local dir fb marker result parent child parent_pid parent_pgid child_pid child_ppid child_pgid child_tty child_args
  dir="$TMP_ROOT/server-detach"; fb="$dir/fakebin"; marker="$dir/detached.tsv"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
tty_state=no
[ -t 0 ] && tty_state=yes
printf 'child\t%s\t%s\t%s\t%s\t%s\n' \
  "$$" \
  "$PPID" \
  "$(ps -o pgid= -p $$ | tr -d ' ')" \
  "$tty_state" \
  "$*" > "${FM_HERDR_DETACH_MARKER:?}"
exec sleep 20
SH
  chmod +x "$fb/herdr"

  result=$( PATH="$fb:/usr/bin:/bin" FM_HERDR_DETACH_MARKER="$marker" bash -c '
    . "$0/bin/backends/herdr.sh"
    printf "parent\t%s\t%s\n" \
      "$$" \
      "$(ps -o pgid= -p $$ | tr -d " ")"
    fm_backend_herdr_server_launch_detached fmtest || exit 1
    for _attempt in $(seq 1 40); do
      [ -s "$FM_HERDR_DETACH_MARKER" ] && break
      sleep 0.05
    done
    [ -s "$FM_HERDR_DETACH_MARKER" ] || exit 1
    cat "$FM_HERDR_DETACH_MARKER"
  ' "$ROOT" )
  expect_code 0 $? "the detached launcher should start the fake Herdr server"

  parent=$(printf '%s\n' "$result" | sed -n '1p')
  child=$(printf '%s\n' "$result" | sed -n '2p')
  IFS=$'\t' read -r _parent parent_pid parent_pgid <<< "$parent"
  IFS=$'\t' read -r _child child_pid child_ppid child_pgid child_tty child_args <<< "$child"

  if [ -z "$child_pid" ] || ! kill -0 "$child_pid" 2>/dev/null; then
    fail "the detached fake server did not survive its launching shell"
  fi
  [ "$child_pgid" != "$parent_pgid" ] \
    || fail "the detached fake server remained in the caller process group $parent_pgid"
  [ "$child_ppid" != "$parent_pid" ] \
    || fail "the detached fake server remained a direct child of its launching shell $parent_pid"
  [ "$child_tty" = no ] \
    || fail "the detached fake server retained a terminal on stdin"
  [ "$child_args" = "server --session fmtest" ] \
    || fail "the detached launcher changed the scoped server command: $child_args"
  kill "$child_pid" 2>/dev/null || true
  pass "fm_backend_herdr_server_launch_detached: server survives caller exit reparented in a distinct process group with closed stdin"
}

test_concurrent_server_ensure_launches_exactly_one_server() {
  local dir fb log lock_root running pids ps_fake first second launch_count server_pid
  dir="$TMP_ROOT/server-ensure-race"
  fb="$dir/fakebin"
  log="$dir/herdr.log"
  lock_root="$dir/locks"
  running="$dir/running"
  pids="$dir/server-pids"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  : > "$log"
  : > "$pids"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for argument in "$@"; do printf '\x1f%s' "$argument"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    sleep 0.25
    : > "$FM_FAKE_HERDR_RUNNING"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  ps_fake="$dir/fake-ps"
  cat > "$ps_fake" <<'SH'
#!/bin/sh
pid=
for argument in "$@"; do pid=$argument; done
kill -0 "$pid" 2>/dev/null || exit 1
printf 'Mon Jan  1 00:00:00 2024\n'
SH
  chmod 755 "$ps_fake"
  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  first=$!
  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$ps_fake" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  second=$!
  wait "$first" || fail "first concurrent server ensure failed"
  wait "$second" || fail "second concurrent server ensure failed"

  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] \
    || fail "concurrent server ensure launched $launch_count Herdr servers instead of one"
  [ "$(wc -l < "$pids" | tr -d ' ')" -eq 1 ] \
    || fail "concurrent server ensure recorded more than one detached server process"
  server_pid=$(cat "$pids")
  for _attempt in $(seq 1 50); do
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.02
  done
  kill -0 "$server_pid" 2>/dev/null \
    && fail "concurrent server ensure left the fake detached server orphaned"
  assert_no_server_transients "$lock_root" "concurrent server ensure"
  pass "fm_backend_herdr_server_ensure: concurrent callers launch one detached server and leave no lock or process orphan"
}

test_server_ensure_reclaims_killed_owner_and_rejects_public_root() {
  local dir fb log lock_root running pids ready holder status launch_count mode lock candidate_ready candidate_release first second
  dir="$TMP_ROOT/server-ensure-stale-owner"
  fb="$dir/fakebin"
  log="$dir/herdr.log"
  lock_root="$dir/locks"
  running="$dir/running"
  pids="$dir/server-pids"
  ready="$dir/owner-ready"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  : > "$log"
  : > "$pids"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for argument in "$@"; do printf '\x1f%s' "$argument"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    : > "$FM_FAKE_HERDR_RUNNING"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  lock=$(PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" bash -c '
    . "$0/bin/backends/herdr.sh"
    root=$(fm_backend_herdr_server_lock_root) || exit 1
    key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
    printf "%s/%s.lock\n" "$root" "$key"
  ' "$ROOT") || fail "could not derive the stale-owner lock path"

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_TEST_HERDR_LOCK_READY="$ready" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root_prepare || exit 1
      root=$(fm_backend_herdr_server_lock_root) || exit 1
      key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
      fm_backend_herdr_server_lock_try_acquire "$root/$key.lock" || exit 1
      : > "$FM_TEST_HERDR_LOCK_READY"
      while :; do sleep 1; done
    ' "$ROOT" &
  holder=$!
  for _attempt in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || { kill -KILL "$holder" 2>/dev/null || true; fail "stale-owner fixture never acquired the Herdr lock"; }
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  touch -t 202001010000 "$lock"

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" \
    || fail "server ensure could not reclaim a lock whose exact owner was killed"
  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] || fail "stale-lock recovery launched $launch_count servers instead of one"
  assert_no_server_transients "$lock_root" "stale-lock recovery"

  # A contender delayed before the atomic hard-link publication owns only its
  # private candidate. Even after the stale threshold, it cannot be mistaken
  # for the public lock owner or prevent another caller from launching.
  rm -f "$running"
  : > "$log"
  : > "$pids"
  candidate_ready="$dir/candidate-ready"
  candidate_release="$dir/candidate-release"
  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_CANDIDATE_READY_FILE="$candidate_ready" \
    FM_TEST_HERDR_CANDIDATE_RELEASE_FILE="$candidate_release" \
    FM_BACKEND_HERDR_SERVER_LOCK_STALE_SECONDS=11 FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  first=$!
  for _attempt in $(seq 1 100); do
    [ -e "$candidate_ready" ] && break
    sleep 0.02
  done
  [ -e "$candidate_ready" ] || { kill -KILL "$first" 2>/dev/null || true; fail "candidate-boundary fixture never reached the pre-publication barrier"; }
  sleep 12
  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  second=$!
  wait "$second" || fail "server ensure was blocked by a stale private lock candidate"
  : > "$candidate_release"
  wait "$first" || fail "delayed candidate owner did not converge on server readiness"
  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] || fail "candidate-publication race launched $launch_count servers instead of one"
  assert_no_server_transients "$lock_root" "candidate-publication race"

  rm -f "$running"
  chmod 755 "$lock_root"
  if PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" \
    >/dev/null 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "server ensure accepted a group/world-accessible lock root"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$lock_root"); else mode=$(stat -c %a "$lock_root"); fi
  [ "$mode" = 755 ] \
    || fail "server ensure silently changed an existing lock-root mode"
  pass "fm_backend_herdr_server_ensure: killed owners are reclaimed, private candidates publish atomically, and existing lock roots stay private"
}

test_server_ensure_never_steals_indeterminate_live_owner() {
  local dir fb log lock_root running pids ready holder waiter lock candidate inode_before inode_after owner_before owner_after
  dir="$TMP_ROOT/server-ensure-indeterminate-owner"
  fb="$dir/fakebin"
  log="$dir/herdr.log"
  lock_root="$dir/locks"
  running="$dir/running"
  pids="$dir/server-pids"
  ready="$dir/owner-ready"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  : > "$log"
  : > "$pids"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    ;;
esac
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
printf 'process probe denied\n' >&2
exit 42
SH
  chmod +x "$fb/herdr" "$fb/ps"

  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_TEST_HERDR_LOCK_READY="$ready" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root_prepare || exit 1
      root=$(fm_backend_herdr_server_lock_root) || exit 1
      key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
      fm_backend_herdr_server_lock_try_acquire "$root/$key.lock" || exit 1
      : > "$FM_TEST_HERDR_LOCK_READY"
      while :; do sleep 1; done
    ' "$ROOT" &
  holder=$!
  for _attempt in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || { kill -KILL "$holder" 2>/dev/null || true; fail "indeterminate-owner fixture never acquired the Herdr lock"; }
  lock=
  for candidate in "$lock_root"/*.lock; do
    [ -f "$candidate" ] || continue
    lock=$candidate
    break
  done
  [ -n "$lock" ] || fail "indeterminate-owner fixture has no lock file"
  if [ "$(uname)" = Darwin ]; then inode_before=$(stat -f '%d:%i' "$lock"); else inode_before=$(stat -c '%d:%i' "$lock"); fi
  owner_before=$(cat "$lock")

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_PS_BIN="$fb/ps" \
    FM_BACKEND_HERDR_SERVER_LOCK_WAIT_STEPS=100 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  waiter=$!
  sleep 0.25
  kill -0 "$waiter" 2>/dev/null || fail "waiter stole or rejected a live owner after an indeterminate process probe"
  if [ "$(uname)" = Darwin ]; then inode_after=$(stat -f '%d:%i' "$lock"); else inode_after=$(stat -c '%d:%i' "$lock"); fi
  owner_after=$(cat "$lock")
  [ "$inode_after" = "$inode_before" ] && [ "$owner_after" = "$owner_before" ] \
    || fail "indeterminate process probing replaced the live Herdr lock owner"
  : > "$running"
  wait "$waiter" || fail "waiter did not accept server readiness while preserving the live lock owner"
  [ ! -s "$pids" ] || fail "waiter launched a server while an indeterminate live lock owner existed"

  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  touch -t 202001010000 "$lock"
  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_try_reclaim "$1"' "$ROOT" "$lock" \
    || fail "could not clean the killed indeterminate-owner fixture"
  assert_no_server_transients "$lock_root" "indeterminate-owner boundary"
  pass "fm_backend_herdr_server_ensure: an indeterminate ps probe never steals a live owner and readiness still unblocks waiters"
}

test_server_ensure_recovers_crash_after_quarantine_rename() {
  local dir fb log lock_root running pids ready crash_ready link_crash holder crasher lock quarantine candidate launch_count lock_inode candidate_inode
  dir="$TMP_ROOT/server-ensure-quarantine-crash"
  fb="$dir/fakebin"
  log="$dir/herdr.log"
  lock_root="$dir/locks"
  running="$dir/running"
  pids="$dir/server-pids"
  ready="$dir/owner-ready"
  crash_ready="$dir/quarantine-renamed"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  : > "$log"
  : > "$pids"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for argument in "$@"; do printf '\x1f%s' "$argument"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    : > "$FM_FAKE_HERDR_RUNNING"
    ;;
esac
SH
  chmod +x "$fb/herdr"
  lock=$(PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" bash -c '
    . "$0/bin/backends/herdr.sh"
    root=$(fm_backend_herdr_server_lock_root) || exit 1
    key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
    printf "%s/%s.lock\n" "$root" "$key"
  ' "$ROOT") || fail "could not derive the quarantine-crash lock path"

  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_TEST_HERDR_LOCK_READY="$ready" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root_prepare || exit 1
      fm_backend_herdr_server_lock_try_acquire "$1" || exit 1
      : > "$FM_TEST_HERDR_LOCK_READY"
      while :; do sleep 1; done
    ' "$ROOT" "$lock" &
  holder=$!
  for _attempt in $(seq 1 100); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || { kill -KILL "$holder" 2>/dev/null || true; fail "quarantine-crash fixture never acquired its lock"; }
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  touch -t 202001010000 "$lock"

  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_KILL_AFTER_QUARANTINE_RENAME="$crash_ready" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_try_reclaim "$1"' \
    "$ROOT" "$lock" &
  crasher=$!
  wait "$crasher" 2>/dev/null || true
  [ -e "$crash_ready" ] || fail "quarantine crash injection did not reach the post-rename boundary"
  [ ! -e "$lock" ] || fail "post-rename crash unexpectedly restored the primary lock"
  quarantine=
  for candidate in "$lock".stale.*; do
    [ -f "$candidate" ] || continue
    quarantine=$candidate
    break
  done
  [ -n "$quarantine" ] || fail "post-rename crash left no recoverable quarantine"

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" \
    || fail "server ensure could not recover a stale post-rename quarantine"
  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] || fail "quarantine crash recovery launched $launch_count servers instead of one"
  assert_no_server_transients "$lock_root" "quarantine crash recovery"

  rm -f "$running"
  : > "$log"
  : > "$pids"
  link_crash="$dir/lock-linked"
  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_KILL_AFTER_LOCK_LINK="$link_crash" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root_prepare || exit 1
      fm_backend_herdr_server_lock_try_acquire "$1"
    ' "$ROOT" "$lock" &
  crasher=$!
  wait "$crasher" 2>/dev/null || true
  [ -e "$link_crash" ] || fail "post-link crash injection did not reach the hard-link boundary"
  [ -f "$lock" ] || fail "post-link crash left no public lock alias"
  candidate=
  for quarantine in "$lock".candidate.*; do
    [ -f "$quarantine" ] || continue
    candidate=$quarantine
    break
  done
  [ -n "$candidate" ] || fail "post-link crash left no recoverable candidate alias"
  if [ "$(uname)" = Darwin ]; then
    lock_inode=$(stat -f '%d:%i' "$lock")
    candidate_inode=$(stat -f '%d:%i' "$candidate")
  else
    lock_inode=$(stat -c '%d:%i' "$lock")
    candidate_inode=$(stat -c '%d:%i' "$candidate")
  fi
  [ "$lock_inode" = "$candidate_inode" ] \
    || fail "post-link crash aliases do not identify the same inode"
  touch -t 202001010000 "$lock" "$candidate"
  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" \
    || fail "server ensure could not recover a killed post-link owner"
  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] || fail "post-link crash recovery launched $launch_count servers instead of one"
  assert_no_server_transients "$lock_root" "post-link crash recovery"
  pass "fm_backend_herdr_server_ensure: crashes after quarantine rename or atomic link publication recover without leaks or duplicate launch"
}

test_server_test_hooks_are_inert_without_explicit_opt_in() {
  local dir lock_root ready release kill_marker hook_probe
  dir="$TMP_ROOT/server-hooks-inert"
  lock_root="$dir/locks"
  ready="$dir/candidate-ready"
  release="$dir/candidate-release"
  kill_marker="$dir/post-link-kill"
  mkdir -p "$lock_root"
  chmod 700 "$lock_root"
  : > "$release"
  FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=not-the-validated-opt-in \
    FM_TEST_HERDR_PS_BIN="$dir/nonexistent-ps" \
    FM_TEST_HERDR_CANDIDATE_READY_FILE="$ready" \
    FM_TEST_HERDR_CANDIDATE_RELEASE_FILE="$release" \
    FM_TEST_HERDR_KILL_AFTER_LOCK_LINK="$kill_marker" \
    bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_server_lock_root_prepare || exit 1
      root=$(fm_backend_herdr_server_lock_root) || exit 1
      key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
      lock="$root/$key.lock"
      fm_backend_herdr_server_lock_try_acquire "$lock" || exit 1
      fm_backend_herdr_server_lock_release \
        "$lock" "$FM_BACKEND_HERDR_SERVER_LOCK_TOKEN" "$FM_BACKEND_HERDR_SERVER_LOCK_INODE"
    ' "$ROOT" || fail "inherited test-hook variables affected production lock acquisition"
  [ ! -e "$ready" ] && [ ! -e "$kill_marker" ] \
    || fail "a Herdr test hook ran without the validated test-only opt-in"
  # $1 is intentionally expanded by bash -c.
  # shellcheck disable=SC2016
  hook_probe='. "$1"; fm_backend_herdr_test_hooks_enabled'
  if env -u FM_BACKEND_HERDR_TEST_LAB \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    bash -c "$hook_probe" \
      _ "$ROOT/bin/backends/herdr.sh"; then
    fail "the Herdr test-hook opt-in worked without the exact test-lab opt-in"
  fi
  assert_no_server_transients "$lock_root" "inert test-hook check"
  pass "Herdr launch-lock fault hooks are inert unless the validated test-only opt-in is present"
}

test_server_ensure_waits_for_inflight_launch_after_owner_kill() {
  local dir fb log lock_root running pids invoked first second lock candidate owner_pid launch_count
  dir="$TMP_ROOT/server-ensure-owner-killed-after-launch"
  fb="$dir/fakebin"
  log="$dir/herdr.log"
  lock_root="$dir/locks"
  running="$dir/running"
  pids="$dir/server-pids"
  invoked="$dir/launch-invoked"
  mkdir -p "$fb" "$lock_root"
  chmod 700 "$lock_root"
  : > "$log"
  : > "$pids"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for argument in "$@"; do printf '\x1f%s' "$argument"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    if [ -e "${FM_FAKE_HERDR_RUNNING:?}" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server --session")
    printf '%s\n' "$$" >> "${FM_FAKE_HERDR_SERVER_PIDS:?}"
    : > "${FM_FAKE_HERDR_LAUNCH_INVOKED:?}"
    sleep 0.5
    : > "$FM_FAKE_HERDR_RUNNING"
    ;;
esac
SH
  chmod +x "$fb/herdr"

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_FAKE_HERDR_LAUNCH_INVOKED="$invoked" \
    FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" FM_BACKEND_HERDR_LAUNCH_SETTLE=0.01 \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_BACKEND_HERDR_SERVER_LOCK_STALE_SECONDS=11 FM_TEST_HERDR_DELAY_BEFORE_LAUNCH=12 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  first=$!
  for _attempt in $(seq 1 1500); do
    [ -e "$invoked" ] && break
    sleep 0.01
  done
  [ -e "$invoked" ] || { kill -KILL "$first" 2>/dev/null || true; fail "delayed fake server was never launched"; }
  lock=
  for candidate in "$lock_root"/*.lock; do
    [ -f "$candidate" ] || continue
    lock=$candidate
    break
  done
  [ -n "$lock" ] || fail "inflight-launch fixture has no owner lock"
  owner_pid=$(sed -n '1p' "$lock")
  kill -KILL "$owner_pid" 2>/dev/null || fail "could not kill the inflight launch lock owner"
  wait "$first" 2>/dev/null || true

  PATH="$fb:/usr/bin:/bin" FM_HERDR_LOG="$log" FM_FAKE_HERDR_RUNNING="$running" \
    FM_FAKE_HERDR_SERVER_PIDS="$pids" FM_FAKE_HERDR_LAUNCH_INVOKED="$invoked" \
    FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT" &
  second=$!
  wait "$second" || fail "waiter failed while the first detached server became ready"
  launch_count=$(grep -c $'\x1fserver\x1f--session\x1ffmtest' "$log" || true)
  [ "$launch_count" -eq 1 ] \
    || fail "owner death during startup launched $launch_count servers instead of preserving the first"
  touch -t 202001010000 "$lock"
  PATH="/usr/bin:/bin" FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_lock_try_reclaim "$1"' "$ROOT" "$lock" \
    || fail "could not clean the completed inflight-launch fixture"
  assert_no_server_transients "$lock_root" "inflight-launch boundary"
  pass "fm_backend_herdr_server_ensure: the lock-file launch epoch prevents stale prelaunch time from duplicating a detached server after owner death"
}

# --- container_ensure / create_task ------------------------------------------

test_container_ensure_starts_server_and_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: version_check status --json (server not running yet, irrelevant to client check)
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  # 2: server_ensure's status --json check -> not running
  printf '{"server":{"running":false}}\n' > "$resp/2.out"
  # 3: server_ensure's under-lock recheck -> still not running
  printf '{"server":{"running":false}}\n' > "$resp/3.out"
  # 4: `herdr server` backgrounded launch - no meaningful output
  # 5: server_ensure poll -> now running
  printf '{"server":{"running":true}}\n' > "$resp/5.out"
  # 6: workspace list -> empty (no "firstmate" workspace yet)
  printf '{"result":{"workspaces":[]}}\n' > "$resp/6.out"
  # 7: workspace create -> w1, seeding default tab w1:t9 (real herdr returns
  # the seeded tab/pane ids in the SAME response - verified empirically).
  printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w1\tw1:t9' ] || fail "container_ensure should echo '<session>:<workspace_id>\\t<seeded_default_tab_id>', got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=fmtest"$'\x1f''server' "container_ensure did not start the herdr server"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''firstmate' \
    "container_ensure did not create the firstmate workspace with the given cwd"
  pass "fm_backend_herdr_container_ensure: version-gates, starts the server, ensures the firstmate workspace, echoes session:workspace_id + the seeded default tab id"
}

test_container_ensure_reuses_existing_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container-reuse"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w9","label":"firstmate"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w9\t' ] || fail "container_ensure should reuse the existing firstmate workspace id with an EMPTY seeded-tab field (an ADOPTED workspace is never a prune candidate), got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure should not create a workspace that already exists"
  pass "fm_backend_herdr_container_ensure: reuses an existing firstmate workspace without recreating it, and reports no seeded default tab (adopted, not created)"
}

test_create_task_refuses_duplicate_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-dup1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing tab label (herdr itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label"
  pass "fm_backend_herdr_create_task: refuses a duplicate tab label (herdr's own tab create has no uniqueness check)"
}

# --- restored-layout husk close-and-replace (herdr session.json restore) -----
#
# herdr persists and restores its whole session layout (workspaces/tabs/
# panes) across a server restart, including a reboot. A restored fm-<id> task
# tab comes back a HUSK - a dead pane, or a plain agent-less shell sitting in
# the saved cwd - never the crewmate that used to be there. Before this fix,
# create_task refused ANY same-labeled tab unconditionally, so every fleet
# respawn after such a restart needed the operator to manually close each
# husk pane first. These tests cover the four cases the fix must get right:
# a genuinely LIVE duplicate still refuses (unchanged), a DEAD pane husk and a
# NO-AGENT (restored plain shell) husk both close-and-replace, and an
# AMBIGUOUS/unparseable read refuses (fail-safe, never guesses toward
# closing).

test_create_task_refuses_duplicate_label_when_agent_live() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-live"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: tab list -> an existing same-labeled tab
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-dup1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  # 2: pane list (pane_for_tab) -> resolves the duplicate's pane id
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> the pane structurally exists
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> a genuinely registered, live agent (idle, not just working)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should still refuse when the duplicate's pane hosts a live (even idle) registered agent"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label for a live agent"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab when the duplicate is live"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close a live agent's pane"
  pass "fm_backend_herdr_create_task: a same-labeled tab with a live (even idle) registered agent still refuses exactly as before"
}

test_create_task_refuses_when_any_duplicate_label_is_live() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-mixed-live"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-mixed1","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-mixed1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w1:p3"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-mixed1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must refuse when any same-labeled tab hosts a live registered agent"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label when one duplicate was live"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab when any duplicate is live"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close any duplicate pane when one duplicate is live"
  pass "fm_backend_herdr_create_task: scans every same-labeled tab and refuses if any duplicate is live"
}

test_create_task_closes_and_replaces_dead_pane_husk() {
  local dir log resp fb out status tab pane
  dir="$TMP_ROOT/husk-dead"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> pane_not_found: the restored pane is dead
  printf '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"}}\n' > "$resp/3.out"
  # 4: tab create -> the replacement tab (created BEFORE the husk is closed)
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/4.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-husk1","workspace_id":"w1"}]}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk1 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace a dead-pane husk instead of refusing"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t3" ] || [ "$pane" != "w1:p3" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-husk1' \
    "create_task did not create the replacement tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the dead husk's tab"
  pass "fm_backend_herdr_create_task: closes and replaces a same-labeled tab whose pane is dead (pane_not_found)"
}

test_create_task_closes_and_replaces_no_agent_husk() {
  local dir log resp fb out status tab pane
  dir="$TMP_ROOT/husk-no-agent"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk2","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  # 3: pane get -> the pane is alive (a session-restore restarts the shell)
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> agent_not_found: nothing registered - a restored plain shell
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  # 5: tab create -> the replacement tab (created BEFORE the husk is closed)
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-husk2","workspace_id":"w1"}]}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk2 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace a no-agent husk (restored plain shell) instead of refusing"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t3" ] || [ "$pane" != "w1:p3" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-husk2' \
    "create_task did not create the replacement tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the no-agent husk's tab"
  pass "fm_backend_herdr_create_task: closes and replaces a same-labeled tab whose pane is alive but hosts no registered agent (a restored plain shell)"
}

test_create_task_closes_all_duplicate_husks_after_replacement() {
  local dir log resp fb out tab pane create_line close_p2_line close_p3_line
  dir="$TMP_ROOT/husk-multiple"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-husk-many","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-husk-many","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' > "$resp/5.out"
  printf '{"result":{"pane":{"pane_id":"w1:p3"}}}\n' > "$resp/6.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p3 not found"}}\n' > "$resp/7.out"
  printf '{"result":{"tab":{"tab_id":"w1:t4"},"root_pane":{"pane_id":"w1:p4"}}}\n' > "$resp/8.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t4","label":"fm-husk-many","workspace_id":"w1"}]}}\n' > "$resp/11.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-husk-many /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace all same-labeled husks after creating a replacement"
  read -r tab pane <<EOF
$out
EOF
  if [ "$tab" != "w1:t4" ] || [ "$pane" != "w1:p4" ]; then
    fail "create_task should echo the NEW tab/pane ids, got '$out'"
  fi
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the first duplicate husk"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' "create_task did not close the second duplicate husk"
  create_line=$(grep -n $'\x1f''tab'$'\x1f''create' "$log" | head -1 | cut -d: -f1)
  close_p2_line=$(grep -n $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "$log" | head -1 | cut -d: -f1)
  close_p3_line=$(grep -n $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' "$log" | head -1 | cut -d: -f1)
  [ -n "$create_line" ] || fail "expected a 'tab create' call in the log"
  if [ "$create_line" -ge "$close_p2_line" ] || [ "$create_line" -ge "$close_p3_line" ]; then
    fail "REGRESSION: duplicate husks were closed before the replacement tab was created"
  fi
  pass "fm_backend_herdr_create_task: closes every confirmed same-labeled husk only after creating the replacement"
}

test_create_task_refuses_when_preexisting_husk_tab_remains() {
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-close-fails"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-stale-husk","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '1\n' > "$resp/6.exit"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-stale-husk","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-stale-husk","workspace_id":"w1"}]}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-stale-husk /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when a preexisting same-labeled husk remains after close-and-replace"
  assert_contains "$out" "failed to remove preexisting herdr tab" "create_task did not report the stale preexisting husk tab"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t2' "create_task did not close the stale husk by tab id"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' "create_task did not close the exact replacement tab after husk removal verification failed"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "create_task should not rely on pane close for a preexisting husk"
  pass "fm_backend_herdr_create_task: closes the exact replacement when a preexisting husk remains"
}

test_create_task_closes_replacement_when_husk_verification_list_fails() {
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-verify-list-fails"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-verify-fails","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '1\n' > "$resp/7.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-verify-fails /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when the post-removal tab listing fails"
  assert_contains "$out" "could not verify herdr husk removal" "create_task did not report the failed verification listing"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' \
    "create_task did not close the exact replacement tab after verification listing failed"
  pass "fm_backend_herdr_create_task: closes the exact replacement when verification listing fails"
}

test_create_task_closes_replacement_when_husk_verification_list_is_malformed() {
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-verify-list-malformed"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-verify-malformed","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  printf '{"error":{"code":"agent_not_found","message":"agent target w1:p2 not found"}}\n' > "$resp/4.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/5.out"
  printf '{"result":{"tabs":["malformed",{"tab_id":"w1:t3","label":"fm-verify-malformed","workspace_id":"w1"}]}}\n' > "$resp/7.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-verify-malformed /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must fail when the post-removal tab listing contains a malformed record"
  assert_contains "$out" "could not parse herdr husk-removal verification listing" \
    "create_task did not report the malformed verification listing"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''close'$'\x1f''w1:t3' \
    "create_task did not close the exact replacement tab after parsing the malformed verification listing failed"
  pass "fm_backend_herdr_create_task: closes the exact replacement when the verification listing is malformed"
}

test_create_task_refuses_when_agent_state_ambiguous() {
  # An unexpected error code from agent get (neither agent_not_found nor a
  # successful read) must not be misread as a husk - fail-safe toward
  # refusal, exactly like today's unconditional-refusal behavior.
  local dir log resp fb out status
  dir="$TMP_ROOT/husk-ambiguous"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-ambig1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$resp/3.out"
  # 4: agent get -> an unrecognized error code, not agent_not_found
  printf '{"error":{"code":"internal_error","message":"transient failure"}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-ambig1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task must refuse (fail-safe) when the agent state cannot be classified confidently, not treat it as a husk"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label for an ambiguous state"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create' "create_task must not create a replacement tab on an ambiguous read"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task must not close a pane whose state is ambiguous"
  pass "fm_backend_herdr_create_task: refuses (fail-safe) rather than guessing when the duplicate's agent state cannot be classified confidently"
}

test_create_task_husk_replacement_creates_before_closing() {
  # Safety-critical ordering: the replacement tab must be created BEFORE the
  # husk tab is closed, never the reverse - closing a workspace's LAST
  # remaining tab deletes the whole workspace on real herdr (docs/herdr-
  # backend.md "Workspace lifecycle"), and a session-restore husk can
  # legitimately be that workspace's only tab. Verified here by log order
  # rather than by state, since herdr's destroy-on-last-tab-close side effect
  # is not modeled by the canned-response fake.
  local dir log resp fb out create_line close_line
  dir="$TMP_ROOT/husk-order"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-order1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n' > "$resp/2.out"
  printf '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"}}\n' > "$resp/3.out"
  printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n' > "$resp/4.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-order1","workspace_id":"w1"}]}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-order1 /tmp/proj' "$ROOT" ) \
    || fail "create_task should close-and-replace the dead-pane husk"
  create_line=$(grep -n $'\x1f''tab'$'\x1f''create' "$log" | head -1 | cut -d: -f1)
  close_line=$(grep -n $'\x1f''tab'$'\x1f''close' "$log" | head -1 | cut -d: -f1)
  [ -n "$create_line" ] || fail "expected a 'tab create' call in the log"
  [ -n "$close_line" ] || fail "expected a 'tab close' call in the log"
  [ "$create_line" -lt "$close_line" ] || fail "REGRESSION: the husk tab was closed (line $close_line) before (or at the same time as) the replacement tab was created (line $create_line) - risks deleting the whole workspace if the husk was its only tab"
  pass "fm_backend_herdr_create_task: creates the replacement tab BEFORE closing the husk tab, never the reverse"
}

test_create_task_creates_and_parses_ids() {
  local dir log resp fb out
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[]}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "w1:t2 w1:p2" ] || fail "create_task should echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-newtask' \
    "create_task did not call tab create with workspace/cwd/label"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' \
    "create_task must never prune when called with no seeded default tab id (the 4th arg defaults to empty)"
  pass "fm_backend_herdr_create_task: creates a tab and parses tab_id/pane_id from the JSON response, prunes nothing when no seeded tab id is given"
}

# --- container_ensure / create_task: --no-focus and per-home label ----------

test_container_ensure_creates_with_no_focus_flag() {
  local dir log resp fb out
  dir="$TMP_ROOT/container-no-focus"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[]}}\n' > "$resp/3.out"
  printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w1\tw1:t1' ] || fail "container_ensure should still echo '<session>:<workspace_id>\\t<seeded_default_tab_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''firstmate'$'\x1f''--no-focus' \
    "container_ensure's workspace create did not pass --no-focus (focus-safety: never steal the captain's attention on spawn)"
  pass "fm_backend_herdr_container_ensure: workspace create passes --no-focus"
}

test_container_ensure_uses_secondmate_home_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/container-secondmate-label"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/container-secondmate-home"; mkdir -p "$home"; printf 'sshhip-h7\n' > "$home/.fm-secondmate-home"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[]}}\n' > "$resp/3.out"
  printf '{"result":{"workspace":{"workspace_id":"w9","label":"2ndmate-sshhip-h7"},"tab":{"tab_id":"w9:t1"},"root_pane":{"pane_id":"w9:p1"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = $'fmtest:w9\tw9:t1' ] || fail "container_ensure did not echo the expected session:workspace_id + seeded default tab id, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''2ndmate-sshhip-h7' \
    "container_ensure did not create the workspace under this secondmate home's own label"
  pass "fm_backend_herdr_container_ensure: creates the workspace under the SECONDMATE home's own label, not 'firstmate'"
}

test_create_task_creates_with_no_focus_flag() {
  local dir log resp fb out
  dir="$TMP_ROOT/create-task-no-focus"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[]}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "w1:t2 w1:p2" ] || fail "create_task should still echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-newtask'$'\x1f''--no-focus' \
    "create_task's tab create did not pass --no-focus"
  pass "fm_backend_herdr_create_task: tab create passes --no-focus"
}

# --- workspace_find: scoped to THIS home's own label, not just any match ----

test_workspace_find_matches_only_this_homes_own_label() {
  local dir log resp fb out home
  dir="$TMP_ROOT/find-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/find-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # A workspace list carrying BOTH the primary's "firstmate" space and this
  # secondmate's own "2ndmate-bravo-b2" space (as would be true once several
  # homes share one herdr session) - find must pick the one matching THIS
  # home's own label, never the primary's or a sibling secondmate's.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"},{"workspace_id":"w3","label":"2ndmate-alpha-a1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_find fmtest' "$ROOT" )
  [ "$out" = "w2" ] || fail "workspace_find should have matched this home's own label (2ndmate-bravo-b2 -> w2), got '$out'"
  pass "fm_backend_herdr_workspace_find: matches only THIS home's own label among several coexisting workspaces"
}

# --- list_live: scoped to this home's own workspace only ---------------------

test_list_live_scoped_to_this_homes_workspace_only() {
  local dir log resp fb out home
  dir="$TMP_ROOT/list-live-scoped"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  home="$TMP_ROOT/list-live-scoped-home"; mkdir -p "$home"; printf 'bravo-b2\n' > "$home/.fm-secondmate-home"
  # 1: workspace_find's `workspace list` - two homes coexist, secondmate's is w2
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-bravo-b2"}]}}\n' > "$resp/1.out"
  # 2: tab list --workspace w2 (this secondmate's own tabs only)
  printf '{"result":{"tabs":[{"tab_id":"w2:t1","label":"fm-secondmatetask"}]}}\n' > "$resp/2.out"
  # 3: pane_for_tab's `pane list --workspace w2`
  printf '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:t1"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HOME="$home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live fmtest' "$ROOT" )
  [ "$out" = $'fmtest:w2:p1\tfm-secondmatetask' ] || fail "list_live should report only this home's own tab, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w2' \
    "list_live did not scope the tab list call to this home's own workspace (w2)"
  assert_not_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''list'$'\x1f''--workspace'$'\x1f''w1' \
    "list_live must never query the primary's (or a sibling secondmate's) workspace"
  pass "fm_backend_herdr_list_live: scoped to this home's own workspace, never a sibling home's"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_parse_target "default:w1:p2" || exit 1
    [ "$FM_BACKEND_HERDR_SESSION" = default ] || { echo "session mismatch: $FM_BACKEND_HERDR_SESSION" >&2; exit 1; }
    [ "$FM_BACKEND_HERDR_PANE" = "w1:p2" ] || { echo "pane mismatch: $FM_BACKEND_HERDR_PANE" >&2; exit 1; }
  ) || fail "fm_backend_herdr_parse_target did not split session:pane on the first colon only"
  pass "fm_backend_herdr_parse_target: splits '<session>:<pane_id>' on the FIRST colon (pane_id itself contains one)"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/herdr.sh"
    [ "$(fm_backend_herdr_normalize_key Enter)" = enter ] || exit 1
    [ "$(fm_backend_herdr_normalize_key Escape)" = escape ] || exit 1
    [ "$(fm_backend_herdr_normalize_key C-c)" = ctrl+c ] || exit 1
    [ "$(fm_backend_herdr_normalize_key ctrl+c)" = ctrl+c ] || exit 1
  ) || fail "fm_backend_herdr_normalize_key did not map firstmate's key vocabulary to herdr's verified names"
  pass "fm_backend_herdr_normalize_key: Enter/Escape/C-c map to herdr's verified enter/escape/ctrl+c"
}

# --- capture / send_key / kill / current_path --------------------------------

test_capture_calls_pane_read() {
  local dir log resp fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'line one\nline two\nline three\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  # Requesting 250 (already >= the 200 floor) passes straight through as the
  # fetch bound; the adapter then trims to the caller's requested 250 lines
  # locally, so all 3 fake lines survive.
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_capture default:w1:p2 250' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three' ] || fail "capture did not pass through pane read output, got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''recent'$'\x1f''--lines'$'\x1f''250' \
    "capture did not call pane read with the right pane id and line bound"
  pass "fm_backend_herdr_capture: calls 'pane read <pane> --source recent --lines N' with the session set"
}

test_capture_works_around_small_lines_bug() {
  local dir log resp fb out
  # Verified herdr v0.7.1 bug (herdr-verification-p2.md): `pane read --lines N`
  # for a small N (below the pane's viewport height) returns EMPTY, not the
  # last N lines. The adapter must never ask herdr for a small --lines bound -
  # it always fetches >= 200 and trims locally with tail.
  dir="$TMP_ROOT/capture-small"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'a\nb\nc\nd\ne\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" )
  [ "$out" = $'d\ne' ] || fail "a small --lines request should still return the last N lines (trimmed locally), got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''--lines'$'\x1f''200' \
    "capture should request a generous fetch (>=200), never the caller's small N, from herdr's own --lines flag"
  pass "fm_backend_herdr_capture: works around the verified small-N '--lines' bug by over-fetching and trimming locally"
}

test_capture_preserves_pane_read_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when pane read fails, got output '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "capture did not try to read the requested pane"
  pass "fm_backend_herdr_capture: preserves pane read failure"
}

test_send_key_normalizes_and_targets_pane() {
  local dir log resp fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_key default:w1:p2 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' "send_key did not normalize Escape to escape"
  pass "fm_backend_herdr_send_key: normalizes the key and targets the right pane"
}

test_kill_is_best_effort() {
  local dir log resp fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_kill default:w1:p2' "$ROOT"
  expect_code 0 $? "kill must be best-effort (never fail even when the pane close call itself fails)"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "kill did not call pane close on the right pane"
  pass "fm_backend_herdr_kill: calls pane close and stays best-effort on failure"
}

test_managed_identity_rejects_reused_pane() {
  local dir home state log fb out
  dir="$TMP_ROOT/managed-identity"; home="$dir/home"; state="$home/state"; log="$dir/log"
  mkdir -p "$dir/fakebin" "$state"; : > "$log"
  fm_write_meta "$state/intended-task.meta" \
    "window=default:w1:p2" "backend=herdr" "kind=ship" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "$*" in
  'session list --json') printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  status\ --json*) printf '{"client":{"protocol":14},"server":{"running":true}}\n' ;;
  pane\ list*) printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w2:t2","workspace_id":"w2"}]}}\n' ;;
  workspace\ list*) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"2ndmate-other"}]}}\n' ;;
  tab\ list*) printf '{"result":{"tabs":[{"tab_id":"w2:t2","label":"fm-intended-task","workspace_id":"w2"}]}}\n' ;;
  pane\ get*) printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  agent\ get*) printf '{"result":{"agent":{"agent_status":"working"}}}\n' ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fb="$dir/fakebin"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" bash -c '
    . "$0/bin/fm-backend.sh"
    [ "$(fm_backend_target_state herdr default:w1:p2 fm-intended-task)" = unknown ] || exit 11
    ! fm_backend_capture herdr default:w1:p2 10 fm-intended-task || exit 12
    ! fm_backend_send_key herdr default:w1:p2 Enter fm-intended-task || exit 13
    [ "$(fm_backend_send_text_submit herdr default:w1:p2 message 1 0 0 fm-intended-task)" = send-failed ] || exit 14
    ! fm_backend_kill herdr default:w1:p2 "" fm-intended-task || exit 15
    [ "$(fm_backend_agent_alive herdr default:w1:p2 fm-intended-task)" = unknown ] || exit 16
    [ "$(fm_backend_busy_state herdr default:w1:p2 fm-intended-task)" = unknown ] || exit 17
  ' "$ROOT" 2>&1) || fail "managed Herdr identity validation failed: $out"
  if grep -Eq 'pane (read|send-text|send-keys|close)|agent get' "$log"; then
    fail "a reused Herdr pane reached a read, mutation, or agent-state command"
  fi
  pass "managed Herdr operations reject same-labeled panes outside the recorded home workspace"
}

test_target_state_distinguishes_absent_from_malformed_panes() {
  local dir fb identity panes out
  dir="$TMP_ROOT/target-state-malformed"; mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'session list --json') printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  pane\ list*) printf '%s\n' "$FM_HERDR_PANES" ;;
  workspace\ list*) printf '%s\n' "${FM_HERDR_WORKSPACES:-}" ;;
  tab\ list*) printf '%s\n' "${FM_HERDR_TABS:-}" ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fb="$dir/fakebin"
  identity='fm-task|w1|firstmate|w1:t2'
  for panes in \
    '{"result":{"panes":[{"pane_id":"w1:p2"}]}}' \
    '{"result":{"panes":["not-a-pane-record"]}}'; do
    out=$(PATH="$fb:$PATH" FM_HERDR_PANES="$panes" bash -c '
      . "$0/bin/fm-backend.sh"
      fm_backend_target_exists() { return 1; }
      [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 11
      [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 12
    ' "$ROOT" "$identity" 2>&1) || fail "malformed Herdr pane record was not fail-closed: $out"
  done
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = absent ] || exit 11
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = dead ] || exit 12
  ' "$ROOT" "$identity" 2>&1) || fail "a removed final Herdr pane and workspace were not classified as absent: $out"
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' \
    FM_HERDR_TABS='{"result":{"tabs":[]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = absent ] || exit 11
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = dead ] || exit 12
  ' "$ROOT" "$identity" 2>&1) || fail "well-formed missing Herdr pane lost its absent/dead classification: $out"
  pass "Herdr target state distinguishes missing panes from malformed records"
}

test_target_state_refuses_absence_on_workspace_identity_collisions() {
  # B1 (review 2026-07-16): a missing exact workspace-id+label pair may be
  # classified absent ONLY with three proofs - the recorded pane is gone, the
  # recorded workspace id is gone under EVERY label, and no workspace still
  # carrying the expected home label holds the expected fm-<task> tab. Each
  # collision below must stay mismatch (unknown upstream) so teardown never
  # releases a live target's lease.
  local dir fb identity out
  dir="$TMP_ROOT/target-state-collisions"; mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'session list --json') printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  pane\ list*) printf '%s\n' "$FM_HERDR_PANES" ;;
  workspace\ list*) printf '%s\n' "${FM_HERDR_WORKSPACES:-}" ;;
  tab\ list*) printf '%s\n' "${FM_HERDR_TABS:-}" ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fb="$dir/fakebin"
  identity='fm-task|w1|firstmate|w1:t2'
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w1","label":"2ndmate-other"}]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr || exit 10
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_herdr_identity_state default:w1:p2 "$1")" = mismatch ] || exit 11
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 12
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 13
  ' "$ROOT" "$identity" 2>&1) || fail "a recorded workspace id recycled under a different label was not fail-closed: $out"
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w9","label":"firstmate"}]}}' \
    FM_HERDR_TABS='{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9","label":"fm-task"}]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr || exit 10
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_herdr_identity_state default:w1:p2 "$1")" = mismatch ] || exit 11
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 12
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 13
  ' "$ROOT" "$identity" 2>&1) || fail "an expected-label workspace still carrying the task tab was not fail-closed: $out"
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_source herdr || exit 10
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_herdr_identity_state default:w1:p2 "$1")" = mismatch ] || exit 11
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 12
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 13
  ' "$ROOT" "$identity" 2>&1) || fail "a live recorded pane with a missing exact workspace match was not fail-closed: $out"
  out=$(PATH="$fb:$PATH" FM_HERDR_PANES='{"result":{"panes":[]}}' \
    FM_HERDR_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w9","label":"firstmate"}]}}' \
    FM_HERDR_TABS='{"result":{"tabs":[{"tab_id":"w9:t1","workspace_id":"w9","label":"fm-other-task"}]}}' bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_target_exists() { return 1; }
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = absent ] || exit 11
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = dead ] || exit 12
  ' "$ROOT" "$identity" 2>&1) || fail "a replacement-generation workspace without the task tab blocked a true absence: $out"
  pass "Herdr identity absence requires pane gone, workspace id gone under every label, and no expected-label task tab"
}

test_target_state_refuses_missing_recorded_pane_with_replacement() {
  local dir fb identity out
  dir="$TMP_ROOT/target-state-replacement"; mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'session list --json') printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  pane\ list*) printf '{"result":{"panes":[{"pane_id":"w1:p9","tab_id":"w1:t2"}]}}\n' ;;
  workspace\ list*) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  tab\ list*) printf '{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"w1","label":"fm-task"}]}}\n' ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fb="$dir/fakebin"
  identity='fm-task|w1|firstmate|w1:t2'
  out=$(PATH="$fb:$PATH" bash -c '
    . "$0/bin/fm-backend.sh"
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 11
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 12
  ' "$ROOT" "$identity" 2>&1) || fail "Herdr replacement pane was classified as absent: $out"
  pass "Herdr target state refuses absence while the recorded task tab has a replacement pane"
}

test_target_state_refuses_missing_recorded_tab_with_same_label_replacement() {
  local dir fb identity out
  dir="$TMP_ROOT/target-state-tab-replacement"; mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'session list --json') printf '{"sessions":[{"name":"default","running":true}]}\n' ;;
  pane\ list*) printf '{"result":{"panes":[{"pane_id":"w1:p9","tab_id":"w1:t9"}]}}\n' ;;
  workspace\ list*) printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' ;;
  tab\ list*) printf '{"result":{"tabs":[{"tab_id":"w1:t9","workspace_id":"w1","label":"fm-task"}]}}\n' ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  fb="$dir/fakebin"
  identity='fm-task|w1|firstmate|w1:t2'
  out=$(PATH="$fb:$PATH" bash -c '
    . "$0/bin/fm-backend.sh"
    [ "$(fm_backend_target_state herdr default:w1:p2 "$1")" = unknown ] || exit 11
    [ "$(fm_backend_agent_alive herdr default:w1:p2 "$1")" = unknown ] || exit 12
  ' "$ROOT" "$identity" 2>&1) || fail "Herdr same-label replacement tab was classified as absent: $out"
  pass "Herdr recovery refuses absence while a same-label replacement tab remains"
}

test_current_path_reads_cwd() {
  local dir log resp fb out
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Verified pitfall (herdr-verification-p2.md): .result.pane.cwd is frozen at
  # pane-creation time and never updates; .foreground_cwd tracks the live
  # running process (e.g. a treehouse get subshell) and is what must be read.
  printf '{"result":{"pane":{"cwd":"/tmp/pane-creation-dir","foreground_cwd":"/tmp/fake-worktree"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_current_path default:w1:p2' "$ROOT" )
  [ "$out" = "/tmp/fake-worktree" ] || fail "current_path should read foreground_cwd (the live process), not the frozen creation-time cwd, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get'$'\x1f''w1:p2' "current_path did not call pane get"
  pass "fm_backend_herdr_current_path: reads pane foreground_cwd (the live running process), not the frozen creation-time cwd"
}

# --- busy_state (semantic agent state) ---------------------------------------

test_busy_state_working_maps_to_busy() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = busy ] || fail "agent_status=working should map to busy, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "busy_state did not call agent get"
  pass "fm_backend_herdr_busy_state: working -> busy"
}

test_busy_state_done_and_blocked_map_to_idle() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-done"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"done"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=done should map to idle, got '$out'"

  dir="$TMP_ROOT/busy-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=blocked should map to idle (stuck waiting on the human, not grinding), got '$out'"
  pass "fm_backend_herdr_busy_state: done -> idle, blocked -> idle (surfaced like a stale pane, not suppressed as busy)"
}

test_busy_state_unknown_on_no_agent() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "a failed agent get should report unknown (the fallback-to-regex cue), got '$out'"
  pass "fm_backend_herdr_busy_state: unparseable/absent agent state reports unknown, the regex-fallback cue"
}

# --- composer_state: structural border-row classification --------------------

test_composer_state_bare_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯                      │\n  ╰──────── Composer ─────╯\n\n  Shift+Tab:mode\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_ghost_placeholder_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ Type a message...    │\n  ╰──────── Composer ─────╯\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "the known ghost placeholder 'Type a message...' should read as empty, got '$out'"
  pass "fm_backend_herdr_composer_state: the ghost placeholder text reads empty, not pending"
}

test_composer_state_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭────────────────────────╮\n  │ ❯ hello captain         │\n  ╰──────── Composer ─────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real composer text reads pending"
}

# Live-verified incident (2026-07-03, real grok 0.2.82 on herdr, isolated
# session): typing "/compact" opens the completion popup; the FIRST Enter
# closes the popup and EXPANDS the composer into an argument-hint placeholder
# ("/compact compaction instructions") rather than submitting - the composer
# still reads real, unsubmitted text and the footer still shows "Enter:send".
# A prior raw-diff verification saw the popup vanish and the text change and
# declared this "submitted". The structural composer-row read must still call
# this pending.
test_composer_state_popup_placeholder_fill_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-popup-placeholder"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  ╭──────────────────────────────────────╮\n  │ ❯ /compact compaction instructions    │\n  ╰──────────────── Composer ─────────────╯\n\n  Enter:send\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_herdr_composer_state: a slash-command popup's argument-hint placeholder still reads pending (the incident fix)"
}

test_composer_state_unknown_on_capture_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/composer-capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable pane should read as unknown, got '$out'"
  pass "fm_backend_herdr_composer_state: reports unknown when the pane cannot be captured"
}

test_composer_state_unknown_when_no_composer_row_found() {
  local dir log resp fb out glyph idx=1
  dir="$TMP_ROOT/composer-no-row"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  for glyph in '>' '$' '%' '#'; do
    printf '%s \n' "$glyph" > "$resp/$idx.out"
    idx=$((idx + 1))
  done
  fb=$(make_herdr_fakebin "$dir")
  for glyph in '>' '$' '%' '#'; do
    out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
    [ "$out" = unknown ] || fail "a bare shell prompt '$glyph' should read as unknown, got '$out'"
  done
  pass "fm_backend_herdr_composer_state: reports unknown for bare shell prompts with no composer row"
}

# --- composer_state: unbordered (bare) composer rows -------------------------
# Regression coverage for the away-mode redelivery-loop incident
# (docs/herdr-backend.md "Incident (2026-07-07)"): real claude and codex
# composer rows carry NO border glyph at all - the fixtures below are captured
# verbatim (character-for-character) from a real herdr session running real
# `claude`/`codex` (see the dated evidence entry). Before the fix these all
# read "unknown" (claude/codex fixtures) or produced a false "empty" from a
# stale decorative box (the banner-priority fixture) - none of them correctly
# tracked the live composer, which is exactly what caused
# bin/fm-supervise-daemon.sh's fm_backend_herdr_send_text_submit to never
# confirm a landed injection, so escalate_flush never cleared
# state/.subsuper-escalations and the same digest was redelivered every cycle.

test_composer_state_claude_unbordered_prompt_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-empty"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Opus 4.8 (1M context)   \xe2\x96\x8d               3%%\n  \xe2\x86\x90 for agents\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a genuinely idle, unbordered real-claude '❯' prompt row (no border glyph anywhere in view) should read empty, got '$out' (regression: this used to read 'unknown' forever, which is exactly what broke escalate_flush's buffer-clear)"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯' prompt row (no border box in view) reads empty"
}

test_composer_state_claude_unbordered_prompt_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-bare-pending"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  20\n  21\n\n\xe2\x9c\xbb Worked for 2s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf hello there this is a test message\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real unsubmitted text in an unbordered real-claude prompt row should read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-claude unbordered '❯ <text>' prompt row reads pending"
}

# The exact incident shape: a bordered decorative box (claude's own startup
# welcome banner) is STILL in the capture window, sitting ABOVE the live,
# unbordered "❯" prompt. Before the fix, the bordered branch was the ONLY one
# ever consulted, so the LAST bordered row (the banner's own blank interior
# spacer row, immediately above its closing ╰──╯) won by construction and was
# misread as the live composer - which happened to strip to empty here, but
# for the same reason never tracks the REAL composer once real text is typed
# below the banner (see the daemon-level E2E evidence in
# docs/herdr-backend.md). The live, bottom-most row must win regardless of
# shape.
test_composer_state_bare_prompt_below_stale_bordered_banner_wins() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-banner-priority"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x95\xad\xe2\x94\x80 Claude Code \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\n\xe2\x94\x82           Welcome back Kun!           \xe2\x94\x82\n\xe2\x94\x82                                       \xe2\x94\x82\n\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf still typing captain\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the live unbordered prompt row below a stale bordered banner must win (pending, real text present), got '$out'"
  pass "fm_backend_herdr_composer_state: a live unbordered prompt row below a stale bordered decorative box still wins (not misread as the box's own row)"
}

# THE OVERNIGHT WEDGE regression (task afk-herdr-false-pending). Captured
# read-only from the live primary claude-on-herdr pane default:w1:p3 on
# 2026-07-10: an idle composer whose only content is claude's rotating
# prompt-suggestion GHOST, rendered SGR-2 dim after the bare "❯" prompt
# ("❯ \033[0m\033[2m<suggestion>\033[0m"). herdr's `pane read --format ansi`
# preserves the dim attribute. The pre-fix herdr classifier stripped ALL ANSI
# and read the suggestion as real pending text (its only faint check matched
# codex's bold-wrapped "\033[1m❯ \033[0m\033[2m", which this shape is NOT), so
# every away-mode injection deferred with "pending input (non-empty composer)"
# all night (6524 lifetime defers; wedge 30623s undelivered). The shared
# ANSI-aware owner now drops the dim ghost and the row reads empty (safe to
# inject).
test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x9c\xbb Brewed for 2m 40s\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf \x1b[0m\x1b[2mwhat did the wheelhouse healing verification find?\x1b[0m\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = empty ] || fail "the overnight shape - claude's SGR-2 dim prompt-suggestion ghost after a bare '❯' - must read empty, got '$out' (regression: this false-pending wedged away-mode injection all night)"
  pass "fm_backend_herdr_composer_state: claude's dim prompt-suggestion ghost (the overnight wedge shape) reads empty"
}

# Same prompt row, but the text after "❯" is REAL (normal intensity, no dim) -
# it must still read pending, so the ghost fix never weakens real-input
# protection.
test_composer_state_claude_dim_ghost_row_with_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-claude-dim-ghost-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf land pr 416 now\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  Fable 5                 80%%\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p3' "$ROOT" )
  [ "$out" = pending ] || fail "real normal-intensity text after '❯' must still read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: real typed text on the same claude prompt row still reads pending"
}

# grok's TRUECOLOR placeholder gap (harness-adapters "Known gap"), now covered by
# the same owner. grok renders its composer inside a bordered box whose border
# and placeholder/hint text use a dark, muted truecolor foreground (verified live
# against grok 0.2.93: border 38;2;86;82;110, muted 38;2;50;47;70, hint
# 38;2;110;106;134; real input is the BRIGHT 38;2;224;222;244), while the "❯"
# prompt glyph stays bright. The dark placeholder drops and the row reads empty.
test_composer_state_grok_dark_truecolor_placeholder_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-ghost"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x95\xad\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xae\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf \x1b[38;2;50;47;70mType a message...\x1b[38;2;86;82;110m \xe2\x94\x82\x1b[39m\n  \x1b[38;2;86;82;110m\xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x95\xaf\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a grok bordered composer whose only content is a dark-truecolor placeholder must read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's dark-truecolor placeholder (the TRUECOLOR gap) reads empty"
}

# grok's bordered composer with REAL bright typed input must still read pending.
test_composer_state_grok_bright_truecolor_real_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-grok-truecolor-real"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[38;2;224;222;244m \xe2\x9d\xaf fix the login bug \x1b[38;2;86;82;110m\xe2\x94\x82\x1b[39m\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "real bright typed text in a grok bordered composer must read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: grok's real bright typed input still reads pending"
}

test_composer_state_codex_bare_prompt_glyph_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-bare"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available.\n\n\xe2\x80\xba\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a bare '›' (codex) prompt glyph with no trailing text should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a real-codex unbordered '›' prompt row reads empty"
}

test_composer_state_codex_faint_suggestion_is_empty() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-faint-suggestion"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mFind and fix a bug in @filename\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex ghost suggestion should read empty, not pending, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex ghost suggestion reads empty"
}

test_composer_state_codex_non_faint_same_text_is_pending() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-non-faint-same-text"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 You have 2 usage limit resets available. Run /usage\nto use one.\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0mFind and fix a bug in @filename\n\n  gpt-5.5 xhigh \xc2\xb7 Context 100%% left\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the same words without faint styling should still protect real typed input, got '$out'"
  pass "fm_backend_herdr_composer_state: non-faint codex prompt text still reads pending"
}

# --- wait_for_working: the native agent-state poll-and-classify primitive ---
# Direct unit coverage for fm_backend_herdr_wait_for_working, the helper
# fm_backend_herdr_send_text_submit now uses instead of composer scraping
# (docs/herdr-backend.md "Native agent-state submit confirmation").

test_wait_for_working_returns_busy_on_first_poll() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-first"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 1 5' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should report busy once 'working' is observed, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 1 ] || fail "wait_for_working should short-circuit on the FIRST busy poll instead of consuming the whole budget, made $calls call(s)"
  pass "fm_backend_herdr_wait_for_working: reports 'busy' immediately on the first poll, without spending the rest of the budget"
}

test_wait_for_working_catches_a_slow_transition_mid_window() {
  local dir log resp fb out calls
  dir="$TMP_ROOT/wait-busy-slow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Two idle samples, then working on the third - a transition that would be
  # MISSED by a single check-at-the-end design (the old composer approach's
  # shape) but is caught here because the budget is sampled repeatedly.
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.03 3' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should catch a transition that lands on a later sample within the SAME window, got '$out'"
  calls=$(grep -c $'\x1f''agent'$'\x1f''get' "$log")
  [ "$calls" -eq 3 ] || fail "expected exactly 3 agent-get polls (idle, idle, working), got $calls"
  pass "fm_backend_herdr_wait_for_working: a slow transition landing on a later sample within one window is still caught (robust against the 'slow transition' failure direction)"
}

test_wait_for_working_samples_budget_endpoint_without_final_sleep() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/wait-budget-endpoint"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" \
    bash -c '. "$0/bin/backends/herdr.sh"; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_wait_for_working default w1:p2 0.5 6' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when every endpoint-spread poll is readable-idle, got '$out'"
  sleeps=$(grep -c '^sleep:0.1000$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "six polls across a 0.5s budget should sleep five times at 0.1000s, got $sleeps matching sleeps; log: $(cat "$sleep_log")"
  pass "fm_backend_herdr_wait_for_working: spreads six samples across the full budget endpoint without a final trailing sleep"
}

test_send_text_submit_applies_herdr_minimum_confirm_budget() {
  local dir log resp fb out sleep_log sleeps
  dir="$TMP_ROOT/submit-min-budget"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; sleep_log="$dir/sleeps"; : > "$log"; : > "$sleep_log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/7.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/8.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/9.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_SLEEP_LOG="$sleep_log" FM_BACKEND_HERDR_SUBMIT_POLLS=6 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; sleep() { printf "sleep:%s\n" "$1" >> "$FM_SLEEP_LOG"; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 1 0.4 0' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should catch a slow-but-valid transition inside the herdr minimum budget, got '$out'"
  sleeps=$(grep -c '^sleep:0.1200$' "$sleep_log")
  [ "$sleeps" -eq 5 ] || fail "a 0.4s caller budget should be expanded to five 0.1200s sleeps across the 0.6s herdr floor, got $sleeps; log: $(cat "$sleep_log")"
  [ "$(grep -c '^sleep:0.0800$' "$sleep_log")" -eq 0 ] || fail "send_text_submit used the caller's too-short 0.4s budget instead of the herdr floor: $(cat "$sleep_log")"
  pass "fm_backend_herdr_send_text_submit: applies the herdr minimum confirmation budget before polling agent-state"
}

test_wait_for_working_returns_idle_when_never_busy_but_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-idle"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/1.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = idle ] || fail "wait_for_working should report idle when the target was legibly read but never busy, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'idle' (readable, genuinely not yet working) when 'busy' never appears"
}

test_wait_for_working_returns_unknown_when_never_readable() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.02 2' "$ROOT" )
  [ "$out" = unknown ] || fail "wait_for_working should report unknown when every poll fails to read the target, got '$out'"
  pass "fm_backend_herdr_wait_for_working: reports 'unknown' (a hard read failure, not a timing race) only when EVERY poll in the window fails"
}

test_wait_for_working_treats_blocked_as_submit_active() {
  local dir log resp fb out
  dir="$TMP_ROOT/wait-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_for_working default w1:p2 0.01 1' "$ROOT" )
  [ "$out" = busy ] || fail "wait_for_working should treat a post-Enter blocked state as submit-active, got '$out'"
  pass "fm_backend_herdr_wait_for_working: treats blocked as submit-active for confirmation without changing watcher busy-state semantics"
}

# --- send_text_submit: native agent-state (agent get) verify-and-retry ------
# Rewritten for the 2026-07-07 incident (docs/herdr-backend.md): confirmation
# no longer reads composer content in the normal idle-baseline path, so a
# harness whose IDLE composer shows dynamic tip text (real codex) can no
# longer misread as "pending" and block/mis-confirm a send.
# FM_BACKEND_HERDR_SUBMIT_POLLS=1 pins most tests
# below to exactly one agent-get sample per Enter attempt for simple,
# deterministic call-count assertions; the multi-sample behavior itself is
# covered above by the wait_for_working tests and by
# test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter.

test_send_text_submit_detects_landed_send() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: native agent send (literal, no output)
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter
  # 4: agent get - agent_status working (a real turn started: submitted)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once agent_status reports working, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''send'$'\x1f''w1:p2'$'\x1f''hello captain' \
    "send_text_submit did not address the registered agent with the literal text first"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message with no popup, sent $enter_count Enter(s)"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never read the composer/pane content for confirmation anymore"
  pass "fm_backend_herdr_send_text_submit: reports 'empty' once agent_status reports working after one Enter, without ever reading the composer"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Every post-Enter agent-get read still reports idle: the Enter never
  # started a turn (swallowed), so wait_for_working never observes "busy".
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with agent_status never going busy, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'pending' when agent_status never reports working after retried Enters (swallowed)"
}

# Regression coverage for the 2026-07-03 incident using the NEW mechanism: a
# slash command's first Enter can close a completion popup and fill an
# argument-hint placeholder WITHOUT submitting. In the idle-baseline path,
# filling a placeholder never starts a turn, so agent_status simply stays idle
# for Enter #1, and the retry loop sends a genuine second Enter exactly as it
# would for any other swallowed Enter.
test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-popup-autocomplete"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text "/compact"
  # 2: agent get - pre-Enter baseline is idle
  # 3: send-keys enter (#1) - closes the popup, fills the placeholder; no turn starts
  # 4: agent get -> idle (not submitted yet)
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  # 5: send-keys enter (#2) - actually submits
  # 6: agent get -> working (submitted)
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually starts a turn, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill's agent_status still reads idle, got $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slash-command popup's placeholder fill on Enter #1 never flips agent_status to working, so it does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_text_submit_confirms_blocked_after_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/3.out"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "needs approval" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should treat a blocked state after Enter as a confirmed delivered prompt, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "blocked after Enter must not provoke a retry into the prompt, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a post-Enter blocked state confirms delivery without retrying into the prompt"
}

test_send_text_submit_preexisting_working_does_not_false_confirm_swallowed_enter() {
  local dir log resp fb out enter_count read_count
  dir="$TMP_ROOT/submit-preexisting-working-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/3.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/4.out"
  printf '  \xe2\x9d\xaf hello captain\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit must not accept preexisting working as proof that this Enter landed, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 2 ] || fail "preexisting-working swallowed Enter should retry Enter up to the configured count, sent $enter_count Enter(s)"
  read_count=$(grep -c $'\x1f''pane'$'\x1f''read' "$log")
  [ "$read_count" -eq 2 ] || fail "preexisting-working confirmation should fall back to composer reads, made $read_count read(s)"
  pass "fm_backend_herdr_send_text_submit: preexisting working is not accepted as submit proof when the composer still holds the message"
}

# Regression for the submit-confirmation side of the 2026-07-07 incident:
# even if a Codex idle composer displays suggestion text, an idle-baseline
# submit must confirm from native agent-state rather than composer scraping.
# The pre-injection composer guard has its own faint-suggestion coverage below.
test_send_text_submit_confirms_despite_codex_idle_tip_composer() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-codex-idle-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "reply with just OK" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm via agent_status alone even for a harness whose idle composer shows dynamic tip text, got '$out'"
  [ "$(grep -c $'\x1f''pane'$'\x1f''read' "$log")" -eq 0 ] || fail "send_text_submit must never call 'pane read' - a codex-style dynamic idle-tip composer can never mislead a confirmation path that does not read it"
  pass "fm_backend_herdr_send_text_submit: confirms submission via native agent-state alone, immune to a codex-style dynamic idle-tip composer that would have misread as 'pending' under the old composer-based confirmation"
}

# Companion regression for the pre-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending): a real Codex idle
# composer can show faint ghost suggestions after the bare `›` prompt.
# The guard must ignore that faint suggestion text, otherwise away-mode
# escalation delivery defers forever even though the human has typed nothing.
test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-codex-dynamic-tip"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '\xe2\x80\xa2 OK\n\n\n\x1b[0m\x1b[1m\xe2\x80\xba \x1b[0m\x1b[2mSummarize recent commits\x1b[0m\n\n  gpt-5.5 xhigh \xc2\xb7 Context 97%% left \xc2\xb7 /private/tmp \xc2\xb7 2\xe2\x80\xa6\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_composer_state default:w1:p2' "$ROOT" )
  [ "$out" = empty ] || fail "a faint real-codex dynamic idle-tip row should read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: a faint real-codex dynamic idle-tip composer row reads empty"
}

# Regression guard for the PRE-injection empty-box guard itself
# (bin/fm-supervise-daemon.sh's pane_input_pending, dispatched via
# fm_backend_composer_state -> fm_backend_herdr_composer_state): this task
# changes ONLY submit confirmation, so genuine unsubmitted text in the
# composer must still read 'pending' and the guard must still refuse to
# inject into it.
test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change() {
  local dir log resp fb out
  dir="$TMP_ROOT/composer-guard-still-refuses"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '  \xe2\x9d\xaf hello there this is a test message\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_composer_state herdr default:w1:p2' "$ROOT" )
  [ "$out" = pending ] || fail "the pre-injection empty-box guard must still refuse real unsubmitted composer text after this change, got '$out'"
  pass "fm_backend_composer_state (herdr): the pre-injection empty-box guard still refuses a genuinely non-empty composer, unaffected by the submit-confirmation change"
}

# A slow transition landing partway through a single Enter attempt's own
# budget must not provoke a needless extra Enter - end-to-end through
# send_text_submit itself (test_wait_for_working_catches_a_slow_transition_mid_window
# above covers the primitive directly; this proves the caller wires it
# correctly).
test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-slow-transition"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text  2: baseline idle  3: send-keys enter  4,5: agent get -> idle  6: agent get -> working
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/4.out"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/5.out"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=3 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.03 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should confirm once a later sample within the SAME Enter attempt observes working, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "a slow (but within-budget) transition must not provoke a needless extra Enter, sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: a slow transition landing on a later sample within one Enter's budget is confirmed WITHOUT sending a needless extra Enter"
}

test_send_text_submit_send_failed() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Native agent send fails, then the recovery/husk pane-send fallback fails.
  printf '1\n' > "$resp/1.exit"
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the literal send itself fails, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'send-failed' when native agent send and the pane-send fallback both error"
}

test_send_text_submit_unknown_on_capture_failure() {
  local dir log resp fb out enter_count
  dir="$TMP_ROOT/submit-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$resp/2.out"
  printf '1\n' > "$resp/4.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_reachable_for_readsteer() { return 0; }; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when the post-Enter agent-get read fails, got '$out'"
  enter_count=$(grep -c $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''enter' "$log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit must never retry past an unreadable target (that is a hard I/O failure, not a timing race), sent $enter_count Enter(s)"
  pass "fm_backend_herdr_send_text_submit: reports 'unknown' when the post-Enter agent-get read fails (never retries past an unreadable target)"
}

# --- fm-backend.sh dispatch wiring -------------------------------------------

test_dispatch_routes_herdr_backend() {
  fm_backend_validate herdr 2>/dev/null || fail "fm_backend_validate should accept herdr (P2 adds it to FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: herdr is a known backend (P2)"
}

test_dispatch_busy_state_unknown_for_tmux() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state tmux 'sess:win')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for tmux (no native agent-state primitive; watcher falls back to regex)"
  pass "fm_backend_busy_state: tmux (no native primitive) always reports unknown, preserving the P1 regex-only path"
}

test_dispatch_composer_state_routes_by_backend() {
  # fm_backend_composer_state (the generic per-backend composer/pending-input
  # classifier the away-mode daemon dispatches through - bin/fm-supervise-daemon.sh's
  # pane_input_pending) must route to each backend's OWN named classifier with
  # the target passed through unchanged, fall back to unknown for a backend with
  # no named classifier (zellij), and unknown for an unrecognized backend name.
  # Sourced-guards are pre-set so fm_backend_source no-ops and these stubs are
  # never clobbered by the real per-backend files trying (and failing) a live call.
  (
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    _FM_BACKEND_TMUX_SOURCED=1
    _FM_BACKEND_HERDR_SOURCED=1
    _FM_BACKEND_ORCA_SOURCED=1
    _FM_BACKEND_ZELLIJ_SOURCED=1
    fm_tmux_composer_state() { [ "$1" = "sess:win" ] || fail "tmux composer_state got wrong target: $1"; printf 'pending'; }
    fm_backend_herdr_composer_state() { [ "$1" = "default:w1:p2" ] || fail "herdr composer_state got wrong target: $1"; printf 'empty'; }
    fm_backend_orca_composer_state() { [ "$1" = "term-1" ] || fail "orca composer_state got wrong target: $1"; printf 'empty'; }
    [ "$(fm_backend_composer_state tmux sess:win)" = pending ] || fail "composer_state did not dispatch to the tmux classifier"
    [ "$(fm_backend_composer_state herdr default:w1:p2)" = empty ] || fail "composer_state did not dispatch to the herdr classifier"
    [ "$(fm_backend_composer_state orca term-1)" = empty ] || fail "composer_state did not dispatch to the orca classifier"
    [ "$(fm_backend_composer_state zellij sess:win)" = unknown ] || fail "composer_state should report unknown for zellij (no named classifier yet)"
    [ "$(fm_backend_composer_state bogus x)" = unknown ] || fail "composer_state should report unknown for an unrecognized backend"
  ) || fail "composer_state dispatch subshell failed"
  pass "fm_backend_composer_state dispatches tmux/herdr/orca to their named classifiers, unknown for zellij/unrecognized backends"
}

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state log resp fb neutral out lock_root owner_pid
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  lock_root="$dir/locks"
  /bin/sleep 30 &
  owner_pid=$!
  FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 OWNER_PID="$owner_pid" \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      key=$(fm_backend_herdr_server_lock_key default) || exit 1
      certificate=$(fm_backend_herdr_server_legacy_env_certificate_path default) || exit 1
      start=$(fm_backend_herdr_process_start "$OWNER_PID") || exit 1
      printf "firstmate-herdr-closed-env-v1\n%s\n%s\n%s\n" \
        "$key" "$OWNER_PID" "$start" > "$certificate" || exit 1
      chmod 600 "$certificate"
    ' "$ROOT" || { kill "$owner_pid" 2>/dev/null || true; fail "could not establish adapter ownership for routed script fixture"; }
  fm_write_meta "$state/herdr-stale.meta" \
    "window=default:w1:p2" "backend=herdr" \
    "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  touch "$state/.last-watcher-beat"
  printf 'captured herdr pane\n' > "$resp/1.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}]}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' > "$resp/3.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-herdr-stale","workspace_id":"w1"}]}}\n' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched herdr target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    "$ROOT/bin/fm-peek.sh" default:w1:p2 5 2>/dev/null )
  [ "$out" = "captured herdr pane" ] \
    || { kill "$owner_pid" 2>/dev/null || true; fail "fm-peek did not capture through herdr for an explicit metadata-matched target, got '$out'"; }
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "fm-peek did not route the explicit stale target through herdr capture"

  : > "$log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    "$ROOT/bin/fm-send.sh" default:w1:p2 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' \
    "fm-send did not route the explicit stale target through herdr send-key"

  kill "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" >/dev/null 2>&1 || true
  pass "fm-peek/fm-send: explicit stale targets matching metadata use the recorded backend"
}

# --- workspace lifecycle: reuse, no orphans, default-tab pruning -------------

test_workspace_ensure_prunes_default_tab() {
  local dir log state fb raw container seeded wsid ids pane tabcount
  dir="$TMP_ROOT/prune-default"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  wsid=${container#*:}
  [ -n "$seeded" ] || fail "container_ensure should report the seeded default tab id for a freshly created workspace, got raw='$raw'"
  # herdr seeds a fresh workspace with one auto-created default tab (label "1")
  # and closing a workspace's LAST tab deletes the whole workspace on real
  # herdr, so the adapter must not prune it until a real task tab exists
  # alongside it - verify it is still present right after container_ensure.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "expected the untouched default tab to remain after container_ensure alone, got $tabcount tab(s): $(jq -c '.tabs' "$state")"
  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-prunetest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"
  # Once the real task tab exists, create_task must prune the SEEDED default
  # tab id container_ensure captured, so only the real task tab remains.
  tabcount=$(jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)]|length' "$state")
  [ "$tabcount" = 1 ] || fail "the auto-created default tab should be pruned once a real task tab exists, $tabcount tab(s) remain: $(jq -c '.tabs' "$state")"
  jq -r --arg w "$wsid" '[.tabs[]|select(.workspace_id==$w)][0].label' "$state" | grep -qx 'fm-prunetest' \
    || fail "the surviving tab should be the real task tab, not the default: $(jq -c '.tabs' "$state")"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close' "create_task did not close the default tab's pane"
  pass "fm_backend_herdr_create_task: prunes exactly the seeded default tab container_ensure identified, once the first real task tab exists"
}

test_repeated_cycles_reuse_one_workspace_no_orphans() {
  local dir log state fb lock_root owner_pid i raw container seeded wsid ids pane first_ws="" wscount total tabcount created
  dir="$TMP_ROOT/cycles"
  lock_root="$dir/locks"
  mkdir -p "$dir" "$lock_root"
  chmod 700 "$lock_root"
  log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # fm_backend_herdr_kill now shares the read/steer safety gate: a running
  # server must be adapter-owned before an existing pane can be addressed.
  # Model that ownership with a valid legacy certificate bound to this test
  # process; leaving it absent would make best-effort kill correctly no-op.
  owner_pid=$$
  FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" OWNER_PID="$owner_pid" \
    /bin/bash --noprofile --norc -c '
      . "$0/bin/backends/herdr.sh"
      key=$(fm_backend_herdr_server_lock_key fmtest) || exit 1
      certificate=$(fm_backend_herdr_server_legacy_env_certificate_path fmtest) || exit 1
      start=$(fm_backend_herdr_process_start "$OWNER_PID") || exit 1
      printf "firstmate-herdr-closed-env-v1\n%s\n%s\n%s\n" \
        "$key" "$OWNER_PID" "$start" > "$certificate" || exit 1
      chmod 600 "$certificate"
    ' "$ROOT" || fail "could not establish adapter ownership for repeated-cycle teardown"
  for i in 1 2 3; do
    raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
      || fail "cycle $i: container_ensure failed"
    container=${raw%%$'\t'*}
    seeded=${raw#*$'\t'}
    case "$container" in fmtest:w*) : ;; *) fail "cycle $i: unexpected container '$container'" ;; esac
    wsid=${container#*:}
    if [ -z "$first_ws" ]; then
      first_ws=$wsid
      [ -n "$seeded" ] || fail "cycle $i: the first cycle must create a fresh workspace and report its seeded default tab id"
    else
      [ "$wsid" = "$first_ws" ] || fail "cycle $i: workspace not reused ('$wsid' != '$first_ws')"
      [ -z "$seeded" ] || fail "cycle $i: a REUSED (adopted) workspace must never report a seeded default tab id, got '$seeded'"
    fi
    ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-cycle$i" "$seeded" ) \
      || fail "cycle $i: create_task failed"
    read -r _ pane <<EOF
$ids
EOF
    [ -n "$pane" ] || fail "cycle $i: create_task returned no pane id"
    PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
      FM_BACKEND_HERDR_SERVER_LOCK_ROOT="$lock_root" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_kill "$1"' "$ROOT" "fmtest:$pane" \
      || fail "cycle $i: kill failed"
  done
  # exactly one firstmate workspace survives three spawn/teardown cycles
  wscount=$(jq -r '[.workspaces[]|select(.label=="firstmate")]|length' "$state")
  [ "$wscount" = 1 ] || fail "expected exactly 1 firstmate workspace after 3 cycles, got $wscount: $(jq -c '.workspaces' "$state")"
  # and no orphaned workspaces of any label
  total=$(jq -r '.workspaces|length' "$state")
  [ "$total" = 1 ] || fail "expected no orphaned workspaces after 3 cycles, got $total total: $(jq -c '.workspaces' "$state")"
  # zero tabs remain: every fm- task tab torn down AND the default tab pruned
  tabcount=$(jq -r '.tabs|length' "$state")
  [ "$tabcount" = 0 ] || fail "expected 0 tabs after teardown (default tab pruned, task tabs killed), got $tabcount: $(jq -c '.tabs' "$state")"
  # the workspace was minted once and reused thereafter, never re-created
  created=$(grep -c $'\x1f''workspace'$'\x1f''create' "$log")
  [ "$created" = 1 ] || fail "workspace create should run exactly once across 3 cycles (reuse, not re-mint), ran $created times"
  pass "herdr repeated spawn/teardown: one persistent firstmate workspace reused, zero orphans, default tab pruned, create ran once"
}

# --- created-vs-adopted default-tab-prune safety (2026-07-02 self-kill fix) -
#
# Root cause and fix are documented at
# fm_backend_herdr_workspace_prune_seeded_default_tab in bin/backends/herdr.sh
# and docs/herdr-backend.md's "Default-tab prune" section. These three tests
# cover the acceptance bar directly: an ADOPTED workspace's tab is never a
# prune candidate (regardless of label or count), a freshly CREATED
# workspace's seeded default tab IS pruned (already covered above by
# test_workspace_ensure_prunes_default_tab and
# test_repeated_cycles_reuse_one_workspace_no_orphans), and the exact
# label-collision startup-workspace shape that caused the real incident
# leaves the live tab alone.

test_adopted_workspace_never_prunes_default_tab() {
  # An ADOPTED workspace (fm_backend_herdr_workspace_find matched a
  # pre-existing workspace by label) must never have any tab pruned by
  # create_task, regardless of that tab's label or count - the created-vs-
  # adopted gate is structural (an empty seeded_tab_id), never re-derived
  # from label patterns at create_task time.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/adopt-no-prune"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Pre-seed a workspace that ALREADY exists before this spawn runs (as if a
  # previous session created it), with a single tab labeled "1" - the same
  # shape herdr's own auto-seeded default tab has, but this run's own
  # container_ensure never ran a `workspace create` call to produce it.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should have ADOPTED the pre-existing workspace w1, got '$container'"
  [ -z "$seeded" ] || fail "an ADOPTED workspace must report an EMPTY seeded default tab id, got '$seeded'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure must not create a new workspace when one already exists to adopt"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-adopttest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  # The pre-existing tab (and its pane) must be COMPLETELY untouched.
  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "the pre-existing (adopted) tab w1:t1 was removed - an adopted workspace's tab must never be pruned"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "create_task must never close a tab belonging to an ADOPTED workspace, no matter its label or count"
  pass "fm_backend_herdr_create_task: an ADOPTED workspace's pre-existing tab is never pruned (the created-vs-adopted gate)"
}

test_label_collision_startup_workspace_leaves_live_tab_alone() {
  # The exact live-fire incident shape (2026-07-02): a captain launches herdr
  # directly inside a directory named "firstmate", so herdr auto-derives that
  # workspace's DISPLAYED label from the cwd basename - "firstmate" - byte-
  # identical to the primary firstmate home's own derived label, with no
  # --label ever passed and no firstmate involvement at all. That workspace's
  # single auto-created tab (label "1") holds the captain's own live agent.
  # The very next crewmate spawn must adopt-and-leave-alone, never prune.
  local dir log state fb raw container seeded ids pane
  dir="$TMP_ROOT/label-collision"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  # Mimic a bare `herdr workspace create --cwd <dir-named-firstmate>` (no
  # --label): the resulting workspace's label is the cwd basename, and its
  # one auto-created tab is still labeled "1" - indistinguishable, by label
  # alone, from firstmate's own freshly-seeded default tab. Its pane hosts a
  # live agent (agent_status=working), exactly like the captain's own pane.
  jq -n '{next:2,workspaces:[{workspace_id:"w1",label:"firstmate"}],tabs:[{tab_id:"w1:t1",label:"1",workspace_id:"w1",pane_id:"w1:p1"}],agent_status:{"w1:p1":"working"}}' > "$state"
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ "$container" = "fmtest:w1" ] || fail "container_ensure should adopt the captain's coincidentally-labeled workspace, got '$container'"
  [ -z "$seeded" ] || fail "the coincidentally-labeled workspace was ADOPTED, not created, so seeded default tab id must be empty, got '$seeded'"

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-collisiontest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e '.tabs[] | select(.tab_id == "w1:t1")' "$state" >/dev/null \
    || fail "REGRESSION: the captain's live tab was closed - this is the exact 2026-07-02 self-kill incident"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p1' \
    "REGRESSION: create_task closed the captain's live pane in the label-collision scenario"
  pass "fm_backend_herdr_create_task: the label-collision startup-workspace scenario (2026-07-02 incident) leaves the captain's live tab untouched"
}

test_prune_refuses_a_working_agent_pane_defense_in_depth() {
  # Defense in depth (not the primary safety mechanism): even for a
  # freshly-created workspace with a genuine non-empty seeded default tab id,
  # if that specific pane's agent reports "working" by the time create_task
  # runs, the prune must refuse rather than close a live agent's pane.
  local dir log state fb raw container seeded seeded_pane ids pane
  dir="$TMP_ROOT/prune-busy-defense"; mkdir -p "$dir"; log="$dir/log"; state="$dir/state.json"; : > "$log"
  fb=$(make_herdr_statefake "$dir")
  raw=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /proj' "$ROOT" ) \
    || fail "container_ensure failed against the stateful fake"
  container=${raw%%$'\t'*}
  seeded=${raw#*$'\t'}
  [ -n "$seeded" ] || fail "expected a freshly created workspace to report a seeded default tab id"
  # Mark the seeded default tab's pane as hosting a working agent (simulates
  # some other path landing a live agent there between creation and prune).
  seeded_pane=$(jq -r --arg t "$seeded" '.tabs[] | select(.tab_id == $t) | .pane_id' "$state")
  [ -n "$seeded_pane" ] || fail "could not resolve the seeded default tab's pane id from state"
  fake_herdr_set_agent_status "$state" "$seeded_pane" working

  ids=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" "$2" /proj "$3"' "$ROOT" "$container" "fm-busytest" "$seeded" ) \
    || fail "create_task failed against the stateful fake"
  read -r _ pane <<EOF
$ids
EOF
  [ -n "$pane" ] || fail "create_task returned no pane id"

  jq -e --arg t "$seeded" '.tabs[] | select(.tab_id == $t)' "$state" >/dev/null \
    || fail "the seeded default tab was closed despite its pane reporting a working agent (defense-in-depth failed)"
  assert_not_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f'"$seeded_pane" \
    "create_task must refuse to close a seeded default tab whose pane hosts a working agent"
  pass "fm_backend_herdr_workspace_prune_seeded_default_tab: refuses to close the seeded default tab when its pane reports a working agent (defense in depth)"
}

# test_no_jq_reserved_keyword_arg_names: regression guard for the
# workspace-leak root cause (a jq `--arg`/`--argjson` named after a jq
# reserved keyword, e.g. `label`, is a compile error on jq <= 1.6; this
# adapter discards jq's stderr, so the error silently becomes an empty
# result instead of a visible failure). Greps every bin/ script for the
# pattern so a future filter reintroducing it fails loudly here instead of
# silently misbehaving on an older jq.
test_no_jq_reserved_keyword_arg_names() {
  local reserved='and|as|catch|def|elif|else|end|foreach|if|import|include|label|module|or|reduce|then|try'
  local hits
  hits=$(grep -rnE -- "--arg(json)?[[:space:]]+($reserved)\b" "$ROOT/bin" 2>/dev/null)
  if [ -n "$hits" ]; then
    fail "a jq --arg/--argjson variable is named after a jq reserved keyword (compile error on jq <= 1.6, silently swallowed by 2>/dev/null):"$'\n'"$hits"
  fi
  pass "no bin/ jq filter names a --arg/--argjson variable after a jq reserved keyword"
}

# --- native event push: normalize / policy-routing / dedupe / wait ----------
#
# These exercise the herdr subscriber (fm_backend_herdr_wait_transition and its
# helpers) with a FAKE socket reader and fake herdr CLI, so the policy routing,
# per-pane dedupe marker, reconnect level-reconcile, and fail-closed return
# codes are asserted without a real herdr server. The isolated real-herdr smoke
# that drives a live idle->blocked transition lives in
# tests/fm-backend-herdr-eventwait-smoke.test.sh.

# make_herdr_eventfake: a herdr stub answering exactly the calls the event path
# makes - `session list --json` (echoes one session, name FM_FAKE_SESSION_NAME,
# socket FM_FAKE_SOCKET), `status --json`, and `agent get <pane>` (per-pane
# status read from $FM_FAKE_AGENT_DIR/<key>.status, else agent_not_found).
make_herdr_eventfake() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:-/dev/null}"
{ printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.3","protocol":16},"server":{"running":true}}\n' ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"default":false,"socket_path":"%s"}]}\n' \
      "${FM_FAKE_SESSION_NAME:-default}" "${FM_FAKE_SOCKET:-/tmp/fm-fake.sock}" ;;
  "agent get")
    if [ -n "${FM_FAKE_READER_READY_FILE:-}" ] && [ ! -e "$FM_FAKE_READER_READY_FILE" ]; then
      exit 9
    fi
    pane=${3:-}
    key=$(printf '%s' "$pane" | tr ':/.' '___')
    f="${FM_FAKE_AGENT_DIR:-/tmp}/$key.status"
    if [ -f "$f" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$f")"
    else
      printf '{"error":{"code":"agent_not_found"}}\n' >&2
      exit 1
    fi ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# make_fake_reader: a stand-in for bin/backends/herdr-eventwait.py. It ignores
# the socket, streams the TAB-separated lines in $FM_FAKE_READER_LINES to stdout
# (one projected event per line: pane_id\tworkspace_id\tagent_status\tagent),
# then exits $FM_FAKE_READER_EXIT (default 0). A non-zero exit with no lines
# models a connect/subscribe failure.
make_fake_reader() {  # <dir> -> echoes reader path
  local dir=$1 path="$1/fake-reader.sh"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
# argv: <sock> <timeout> <pane...> - ignored; behavior is env-driven.
if [ -n "${FM_FAKE_READER_READY_FILE:-}" ]; then
  : > "$FM_FAKE_READER_READY_FILE"
fi
printf '%s\n' "${FM_FAKE_READER_ACK:-@subscribed}"
if [ -n "${FM_FAKE_READER_LINES:-}" ] && [ -f "$FM_FAKE_READER_LINES" ]; then
  cat "$FM_FAKE_READER_LINES"
fi
exit "${FM_FAKE_READER_EXIT:-0}"
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

set_fake_agent() {  # <agent-dir> <window-or-pane> <status>
  local dir=$1 target=$2 status=$3 key
  key=$(printf '%s' "$target" | tr ':/.' '___')
  mkdir -p "$dir"
  printf '%s' "$status" > "$dir/$key.status"
}

test_normalize_event_leaves_from_empty() {
  local rec
  rec=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_normalize_event wG:pQ wG blocked claude' "$ROOT")
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_pane_id "$1"' "$ROOT" "$rec")" = "wG:pQ" ] \
    || fail "normalize_event pane_id wrong: $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_from_status "$1"' "$ROOT" "$rec")" = "" ] \
    || fail "normalize_event should leave from_status empty (herdr carries no previous status): $rec"
  [ "$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_to_status "$1"' "$ROOT" "$rec")" = "blocked" ] \
    || fail "normalize_event to_status wrong: $rec"
  pass "fm_backend_herdr_normalize_event routes through the shared record with an empty from_status"
}

test_escalation_marker_keys_like_watcher() {
  local m
  m=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_escalation_marker /st default:wG:pQ' "$ROOT")
  [ "$m" = "/st/.herdr-escalated-default_wG_pQ" ] \
    || fail "escalation marker key must match the watcher's tr ':/.' '___' scheme, got '$m'"
  pass "fm_backend_herdr_escalation_marker keys the dedupe marker exactly like the watcher's .stale-<key>"
}

test_apply_transition_blocked_requires_commit_to_dedupe() {
  local dir state rec out rc marker
  dir="$TMP_ROOT/apply-blocked"; state="$dir/state"; mkdir -p "$state"
  rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  marker="$state/.herdr-escalated-default_wG_pQ"
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 0 ] || fail "a fresh blocked edge must return 0 (actionable), got $rc"
  case "$out" in *blocked*) : ;; *) fail "apply_transition should print the record on a fresh actionable edge, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "detecting a blocked edge must not commit its marker before durable handling"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"
  [ -e "$marker" ] || fail "commit_transition must set the marker after the caller handles the edge"
  # Second identical blocked edge (marker present) must NOT re-fire.
  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"); rc=$?
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must return 1 (deduped), got $rc"
  [ -z "$out" ] || fail "an already-marked blocked pane must print nothing, got '$out'"
  pass "fm_backend_herdr_apply_transition: blocked dedupe starts only after explicit commit"
}

test_apply_transition_working_clears_marker() {
  local dir state blocked working marker rc
  dir="$TMP_ROOT/apply-working"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  blocked=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" blocked claude' "$ROOT")
  working=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" working claude' "$ROOT")
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_commit_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked"
  [ -e "$marker" ] || fail "setup: committed blocked edge should have set the marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$working"; rc=$?
  [ "$rc" = 1 ] || fail "a working (absorb) edge must return 1 (no wake), got $rc"
  [ ! -e "$marker" ] || fail "a working edge must CLEAR the escalation marker so a later re-block re-fires"
  # A re-block after the clear must fire again.
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$blocked" >/dev/null; rc=$?
  [ "$rc" = 0 ] || fail "a re-block after a working clear must re-fire (return 0), got $rc"
  pass "fm_backend_herdr_apply_transition: a working edge clears the marker so the next ->blocked re-escalates"
}

test_clear_transition_removes_task_marker() {
  local dir state marker
  dir="$TMP_ROOT/clear-transition"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  : > "$marker"
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_clear_transition "$1" "$2"' "$ROOT" "$state" default:wG:pQ
  [ ! -e "$marker" ] || fail "clear_transition must remove the marker owned by a torn-down pane"
  pass "fm_backend_herdr_clear_transition removes task-owned dedupe state"
}

test_apply_transition_defer_and_fallback_are_noops() {
  local dir state marker rc s
  dir="$TMP_ROOT/apply-defer"; state="$dir/state"; mkdir -p "$state"
  marker="$state/.herdr-escalated-default_wG_pQ"
  for s in idle "done" unknown ""; do
    local rec
    rec=$(bash -c '. "$0/bin/fm-transition-lib.sh"; fm_transition_record wG:pQ wG "" "$1" claude' "$ROOT" "$s")
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_apply_transition "$1" "$2" "$3"' "$ROOT" "$state" default "$rec"; rc=$?
    [ "$rc" = 1 ] || fail "defer/fallback status '$s' must return 1 (no fast action), got $rc"
    [ ! -e "$marker" ] || fail "defer/fallback status '$s' must not touch the escalation marker"
  done
  pass "fm_backend_herdr_apply_transition: idle/done (defer) and unknown/empty (fallback) take no fast action"
}

test_wait_transition_no_panes_returns_2() {
  local rc
  bash -c '. "$0/bin/backends/herdr.sh"; FM_BACKEND_HERDR_EVENTS_FORCE=1 fm_backend_herdr_wait_transition default 1 /tmp/st' "$ROOT"; rc=$?
  [ "$rc" = 2 ] || fail "wait_transition with no pane windows must return 2 (fall back to sleep), got $rc"
  pass "fm_backend_herdr_wait_transition: a home with no herdr panes falls back to polling (rc 2)"
}

test_wait_transition_not_capable_returns_2() {
  local dir state fb rc
  dir="$TMP_ROOT/wt-incapable"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_herdr_eventfake "$dir")
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "wait_transition must return 2 when events are below capability (fail closed to poll), got $rc"
  pass "fm_backend_herdr_wait_transition: below-capability protocol/schema falls back to polling (rc 2)"
}

test_wait_transition_reconcile_blocked_returns_record() {
  local dir state agent temp fb reader lines out rc marker
  dir="$TMP_ROOT/wt-reconcile"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "reconcile of an already-blocked pane must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "reconcile must print the blocked record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "reconcile must not mark a blocked pane before the caller durably handles it"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "actionable reconciliation must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: reconnect level-reconcile returns an uncommitted blocked pane"
}

test_wait_transition_subscribes_before_reconcile() {
  local dir state agent fb reader lines ready rc
  dir="$TMP_ROOT/wt-subscribe-first"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; ready="$dir/subscribed"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_READY_FILE="$ready" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "subscription must be acknowledged before reconciliation begins, got $rc"
  pass "fm_backend_herdr_wait_transition: subscribes before reconnect level-reconcile"
}

test_wait_transition_reconcile_dedupes_when_marked() {
  local dir state agent fb rc
  dir="$TMP_ROOT/wt-reconcile-dedupe"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" blocked
  # Pre-mark: this blocked was already escalated.
  : > "$state/.herdr-escalated-sess_wG_pQ"
  # No stream events, reader exits 0 -> a clean timeout (rc 1), NOT a re-fire.
  local reader lines
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "an already-marked blocked pane must not re-fire on reconcile (expect clean timeout rc 1), got $rc"
  pass "fm_backend_herdr_wait_transition: a still-blocked, already-escalated pane is not re-delivered on reconnect"
}

test_wait_transition_stream_blocked_returns_record() {
  local dir state agent fb reader lines out rc marker
  dir="$TMP_ROOT/wt-stream-blocked"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle   # reconcile sees idle -> proceeds to stream
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  printf 'wG:pQ\t\tblocked\tclaude\n' > "$lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ' "$ROOT" "$state"); rc=$?
  [ "$rc" = 0 ] || fail "a streamed blocked edge must return 0, got $rc"
  case "$out" in *blocked*) : ;; *) fail "a streamed blocked edge must print the record, got '$out'" ;; esac
  [ ! -e "$marker" ] || fail "a streamed blocked edge must remain uncommitted until durable handling"
  pass "fm_backend_herdr_wait_transition: a streamed ->blocked edge returns the record sub-poll"
}

test_wait_transition_stream_absorb_clears_then_timeout() {
  local dir state agent fb reader lines rc marker
  dir="$TMP_ROOT/wt-stream-absorb"; state="$dir/state"; agent="$dir/agents"; mkdir -p "$state" "$agent"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  : > "$state/.herdr-escalated-sess_wG_pQ"   # previously escalated
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"
  marker="$state/.herdr-escalated-sess_wG_pQ"
  # Stream a working edge (absorb) then an idle edge (defer). Neither is a fresh
  # actionable edge, so the wait ends as a clean timeout (rc 1) and the marker
  # is cleared by the working edge.
  printf 'wG:pQ\t\tworking\tclaude\nwG:pQ\t\tidle\tclaude\n' > "$lines"
  rc=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 2 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 1 ] || fail "a stream of only working/idle edges must end as a clean timeout (rc 1), got $rc"
  [ ! -e "$marker" ] || fail "a streamed working edge must clear the escalation marker"
  pass "fm_backend_herdr_wait_transition: streamed working clears the marker, idle/done are deferred (clean timeout)"
}

test_wait_transition_reader_failure_returns_2() {
  local dir state agent temp fb reader lines rc
  dir="$TMP_ROOT/wt-reader-fail"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  rc=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_EXIT=2 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; echo $?' "$ROOT" "$state" | tail -1)
  [ "$rc" = 2 ] || fail "a reader connect/subscribe failure must return 2 (fall back to poll), got $rc"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "reader failure must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: a reader/subscribe failure falls back to polling (rc 2)"
}

test_wait_transition_bad_ack_returns_2_and_cleans_up() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-bad-ack"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" FM_FAKE_READER_ACK=invalid \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 2 ] || fail "an invalid subscription acknowledgement must return 2, got $rc"
  [ "$fd_open" = no ] || fail "an invalid subscription acknowledgement must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "an invalid subscription acknowledgement must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: Bash 3.2-safe bad-ack path closes fd 9 and removes its FIFO"
}

test_wait_transition_clean_timeout_returns_1() {
  local dir state agent temp fb reader lines result rc fd_open
  dir="$TMP_ROOT/wt-timeout"; state="$dir/state"; agent="$dir/agents"; temp="$dir/temp"; mkdir -p "$state" "$agent" "$temp"
  fb=$(make_herdr_eventfake "$dir")
  set_fake_agent "$agent" "wG:pQ" idle
  reader=$(make_fake_reader "$dir"); lines="$dir/lines"; : > "$lines"   # no events, reader exits 0
  result=$(PATH="$fb:$PATH" TMPDIR="$temp" FM_BACKEND_HERDR_EVENTS_FORCE=1 FM_FAKE_SESSION_NAME=sess FM_FAKE_SOCKET="$dir/x.sock" FM_FAKE_AGENT_DIR="$agent" \
    FM_BACKEND_HERDR_EVENT_READER="$reader" FM_FAKE_READER_LINES="$lines" \
    /bin/bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_wait_transition sess 1 "$1" sess:wG:pQ; rc=$?; [ -e /dev/fd/9 ] && fd_open=yes || fd_open=no; printf "%s %s\n" "$rc" "$fd_open"' "$ROOT" "$state")
  rc=${result%% *}; fd_open=${result#* }
  [ "$rc" = 1 ] || fail "a clean full-budget wait with no actionable edge must return 1, got $rc"
  [ "$fd_open" = no ] || fail "a clean timeout must close fixed fd 9"
  [ -z "$(find "$temp" -mindepth 1 -print -quit)" ] || fail "a clean timeout must remove its private FIFO directory"
  pass "fm_backend_herdr_wait_transition: stock macOS Bash clean timeout closes fd 9 and returns 1"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

if [ "${FM_TEST_FOCUSED:-}" = review-round-25 ]; then
  test_target_state_distinguishes_absent_from_malformed_panes
  test_target_state_refuses_missing_recorded_pane_with_replacement
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-26 ]; then
  test_target_state_refuses_missing_recorded_tab_with_same_label_replacement
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = herdr-identity-absence ]; then
  test_target_state_distinguishes_absent_from_malformed_panes
  test_target_state_refuses_absence_on_workspace_identity_collisions
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = server-ensure-race ]; then
  test_server_test_hooks_are_inert_without_explicit_opt_in
  test_concurrent_server_ensure_launches_exactly_one_server
  test_server_ensure_reclaims_killed_owner_and_rejects_public_root
  test_server_ensure_never_steals_indeterminate_live_owner
  test_server_ensure_recovers_crash_after_quarantine_rename
  test_server_ensure_waits_for_inflight_launch_after_owner_kill
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = server-startup ]; then
  test_server_test_hooks_are_inert_without_explicit_opt_in
  test_herdr_binary_revalidates_leaf_and_physical_ancestry
  test_server_launch_scrubs_hostile_perl_and_control_environment
  test_server_launch_preserves_only_safe_worker_tool_paths
  test_managed_shell_and_server_certificate_close_startup_before_bash
  test_server_lock_root_rejects_unsafe_parent_and_ignores_tmpdir
  test_server_launch_detaches_from_callers_session
  test_concurrent_server_ensure_launches_exactly_one_server
  test_server_ensure_reclaims_killed_owner_and_rejects_public_root
  test_server_ensure_never_steals_indeterminate_live_owner
  test_server_ensure_recovers_crash_after_quarantine_rename
  test_server_ensure_waits_for_inflight_launch_after_owner_kill
  test_container_ensure_starts_server_and_workspace
  test_container_ensure_reuses_existing_workspace
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-shell-cert ]; then
  test_managed_shell_and_server_certificate_close_startup_before_bash
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-shell-hardening ]; then
  test_managed_shell_and_server_certificate_close_startup_before_bash
  test_managed_shell_certificate_rejects_release_and_artifact_drift
  test_managed_artifact_candidate_recovery_is_guarded
  test_managed_artifact_recovers_every_published_pair_crash_boundary
  test_attributed_cleanup_recovers_nlink1_and_exact_lock_release_phases
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = published-pair ]; then
  test_managed_artifact_recovers_every_published_pair_crash_boundary
  test_attributed_cleanup_recovers_nlink1_and_exact_lock_release_phases
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = server-cert-lifecycle ]; then
  test_server_ensure_routes_occupied_adapter_owned_release_drift_without_restart
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = workspace-prune ]; then
  test_workspace_ensure_prunes_default_tab
  exit 0
fi

test_version_check_accepts_current_protocol
test_version_check_refuses_old_protocol
test_version_check_refuses_missing_herdr
test_server_test_hooks_are_inert_without_explicit_opt_in
test_herdr_binary_revalidates_leaf_and_physical_ancestry
test_server_launch_scrubs_hostile_perl_and_control_environment
test_server_launch_preserves_only_safe_worker_tool_paths
test_managed_shell_and_server_certificate_close_startup_before_bash
test_managed_shell_certificate_rejects_release_and_artifact_drift
test_managed_artifact_candidate_recovery_is_guarded
test_managed_artifact_recovers_every_published_pair_crash_boundary
test_attributed_cleanup_recovers_nlink1_and_exact_lock_release_phases
test_server_ensure_routes_occupied_adapter_owned_release_drift_without_restart
test_server_lock_root_rejects_unsafe_parent_and_ignores_tmpdir
test_workspace_label_primary_home_no_marker
test_workspace_label_secondmate_home_uses_marker_id
test_workspace_label_secondmate_marker_trims_whitespace
test_workspace_label_empty_marker_falls_back_to_primary
test_workspace_label_different_secondmates_get_different_labels
test_cli_helper_sets_env_and_appends_trailing_session_flag
test_cli_helper_scrubs_loader_and_runtime_injection
test_server_launch_detaches_from_callers_session
test_concurrent_server_ensure_launches_exactly_one_server
test_server_ensure_reclaims_killed_owner_and_rejects_public_root
test_server_ensure_never_steals_indeterminate_live_owner
test_server_ensure_recovers_crash_after_quarantine_rename
test_server_ensure_waits_for_inflight_launch_after_owner_kill
test_container_ensure_starts_server_and_workspace
test_container_ensure_reuses_existing_workspace
test_container_ensure_creates_with_no_focus_flag
test_container_ensure_uses_secondmate_home_label
test_workspace_ensure_prunes_default_tab
test_repeated_cycles_reuse_one_workspace_no_orphans
test_adopted_workspace_never_prunes_default_tab
test_label_collision_startup_workspace_leaves_live_tab_alone
test_prune_refuses_a_working_agent_pane_defense_in_depth
test_no_jq_reserved_keyword_arg_names
test_create_task_refuses_duplicate_label
test_create_task_refuses_duplicate_label_when_agent_live
test_create_task_refuses_when_any_duplicate_label_is_live
test_create_task_closes_and_replaces_dead_pane_husk
test_create_task_closes_and_replaces_no_agent_husk
test_create_task_closes_all_duplicate_husks_after_replacement
test_create_task_refuses_when_preexisting_husk_tab_remains
test_create_task_closes_replacement_when_husk_verification_list_fails
test_create_task_closes_replacement_when_husk_verification_list_is_malformed
test_create_task_refuses_when_agent_state_ambiguous
test_create_task_husk_replacement_creates_before_closing
test_create_task_creates_and_parses_ids
test_create_task_creates_with_no_focus_flag
test_workspace_find_matches_only_this_homes_own_label
test_list_live_scoped_to_this_homes_workspace_only
test_parse_target
test_normalize_key
test_capture_calls_pane_read
test_capture_works_around_small_lines_bug
test_capture_preserves_pane_read_failure
test_send_key_normalizes_and_targets_pane
test_kill_is_best_effort
test_managed_identity_rejects_reused_pane
test_target_state_distinguishes_absent_from_malformed_panes
test_target_state_refuses_absence_on_workspace_identity_collisions
test_target_state_refuses_missing_recorded_pane_with_replacement
test_target_state_refuses_missing_recorded_tab_with_same_label_replacement
test_current_path_reads_cwd
test_busy_state_working_maps_to_busy
test_busy_state_done_and_blocked_map_to_idle
test_busy_state_unknown_on_no_agent
test_composer_state_bare_prompt_is_empty
test_composer_state_ghost_placeholder_is_empty
test_composer_state_real_text_is_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_unknown_on_capture_failure
test_composer_state_unknown_when_no_composer_row_found
test_composer_state_claude_unbordered_prompt_is_empty
test_composer_state_claude_unbordered_prompt_is_pending
test_composer_state_bare_prompt_below_stale_bordered_banner_wins
test_composer_state_claude_dim_prompt_suggestion_ghost_is_empty
test_composer_state_claude_dim_ghost_row_with_real_text_is_pending
test_composer_state_grok_dark_truecolor_placeholder_is_empty
test_composer_state_grok_bright_truecolor_real_text_is_pending
test_composer_state_codex_bare_prompt_glyph_is_empty
test_composer_state_codex_faint_suggestion_is_empty
test_composer_state_codex_non_faint_same_text_is_pending
test_wait_for_working_returns_busy_on_first_poll
test_wait_for_working_catches_a_slow_transition_mid_window
test_wait_for_working_samples_budget_endpoint_without_final_sleep
test_send_text_submit_applies_herdr_minimum_confirm_budget
test_wait_for_working_returns_idle_when_never_busy_but_readable
test_wait_for_working_returns_unknown_when_never_readable
test_wait_for_working_treats_blocked_as_submit_active
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_text_submit_confirms_blocked_after_enter
test_send_text_submit_preexisting_working_does_not_false_confirm_swallowed_enter
test_send_text_submit_confirms_despite_codex_idle_tip_composer
test_composer_state_codex_dynamic_idle_tip_reads_empty_when_faint
test_composer_state_guard_still_refuses_real_pending_text_after_submit_confirmation_change
test_send_text_submit_slow_transition_within_one_enter_needs_no_extra_enter
test_send_text_submit_send_failed
test_send_text_submit_unknown_on_capture_failure
test_dispatch_routes_herdr_backend
test_dispatch_busy_state_unknown_for_tmux
test_dispatch_composer_state_routes_by_backend
test_scripts_route_explicit_target_through_meta_backend
test_normalize_event_leaves_from_empty
test_escalation_marker_keys_like_watcher
test_apply_transition_blocked_requires_commit_to_dedupe
test_apply_transition_working_clears_marker
test_clear_transition_removes_task_marker
test_apply_transition_defer_and_fallback_are_noops
test_wait_transition_no_panes_returns_2
test_wait_transition_not_capable_returns_2
test_wait_transition_reconcile_blocked_returns_record
test_wait_transition_subscribes_before_reconcile
test_wait_transition_reconcile_dedupes_when_marked
test_wait_transition_stream_blocked_returns_record
test_wait_transition_stream_absorb_clears_then_timeout
test_wait_transition_reader_failure_returns_2
test_wait_transition_bad_ack_returns_2_and_cleans_up
test_wait_transition_clean_timeout_returns_1
