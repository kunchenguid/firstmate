#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh tool detection.
#
# Bootstrap prints one block or line per problem or capability fact and is silent when all
# is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', and 'TASKS_AXI: available' lines, so those
# contracts are pinned verbatim. The cases are table-driven over the inputs that
# vary: whether `treehouse get --help` advertises --lease, which (if any)
# tasks-axi version is on PATH, whether the local backend config opts out, and
# which no-mistakes version is on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = checks ] && [ "${3:-}" = --help ]; then
  if [ "${FM_FAKE_GH_PR_CHECKS_JSON:-1}" = 1 ]; then
    printf '%s\n' '  --json fields   Output JSON with the specified fields'
  else
    printf '%s\n' '  --required      Only show checks that are required'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  add_tasks_axi "$fakebin" "0.1.1"
  printf '%s\n' "$fakebin"
}

# make_fake_live_tmux_window <fakebin> <window-name>: a tmux stub that reports
# exactly one live window running a harness, so the isolation gate - which only
# blocks records whose endpoint could still be running a worker - can be
# exercised deterministically.
make_fake_live_tmux_window() {
  local fakebin=$1 window=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *list-windows*window_name*) printf '%s\n' '$window' ;;
  *pane_current_command*) printf '%s\n' claude ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks backend mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label lease tasks backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    if [ "$tasks" = "-" ]; then
      rm -f "$fakebin/tasks-axi"
    else
      add_tasks_axi "$fakebin" "$tasks"
    fi
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^0.1.1^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is accepted silently by default^1^0.1.1^-^empty^^
missing tasks-axi is suggested by default^1^-^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is suggested by default^1^0.1.0^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend still requires tasks-axi^1^-^manual^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses tasks-axi availability^1^0.1.1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi default/backend contracts"
}

test_gh_pr_checks_json_compatibility() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/gh-pr-checks-json"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_tasks_axi "$fakebin" "0.1.1"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_GH_PR_CHECKS_JSON=0 "$ROOT/bin/fm-bootstrap.sh")

  [ -z "$out" ] || fail "gh compatibility probe should stay silent; got: $out"
  pass "bootstrap accepts the available GitHub toolchain"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" "0.1.1"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_crew_dispatch_active_rules_are_surfaced() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5.6-terra","effort":"medium"}}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'CREW_DISPATCH: active config/crew-dispatch.json\n  rule: fresh news -> grok\n  rule: big feature -> codex/gpt-5.6-sol/high\n  default: codex/gpt-5.6-terra/medium'
  [ "$out" = "$expect" ] || fail "active dispatch profile block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules and default"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported grok xhigh effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"xhigh"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:xhigh
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_secondmate_profile_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/secondmate-profile-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/secondmate-profile.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
    esac
  done <<'ROWS'
valid profile is silent^{"model":"gpt-5.6-sol","effort":"high"}^empty^
default values are silent^{"model":"default","effort":"default"}^empty^
malformed profile config is flagged^{"model":^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - malformed JSON
non-object profile is flagged^[]^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - top-level value must be an object
boolean profile is flagged^false^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - top-level value must be an object
non-string model is flagged^{"model":55,"effort":"high"}^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - model must be a non-empty string
non-string effort is flagged^{"model":"gpt-5.5","effort":55}^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - effort must be a string
invalid effort is flagged^{"model":"gpt-5.5","effort":"turbo"}^exact^SECONDMATE_PROFILE: invalid config/secondmate-profile.json - invalid effort: turbo
ROWS
  pass "bootstrap validates secondmate-profile.json and reports malformed or invalid configs"
}

test_bootstrap_discovers_home_nvm_tasks_axi() {
  local home nodebin fakebin out
  home="$TMP_ROOT/bootstrap-home-nvm"
  nodebin="$home/.nvm/versions/node/v22.22.2/bin"
  mkdir -p "$nodebin"
  add_tasks_axi "$nodebin" "0.1.2"
  fakebin=$(make_fake_toolchain "$home")

  out=$(HOME="$home" PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "bootstrap did not silently accept HOME NVM tasks-axi: $out"
  pass "bootstrap discovers HOME NVM tasks-axi in a clean non-interactive PATH"
}

test_bootstrap_blocks_mutation_on_unproven_isolation() {
  local case_dir fakebin out status
  case_dir="$TMP_ROOT/bootstrap-isolation-gate"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config"
  cat > "$case_dir/home/state/isolation-gate.meta" <<EOF
window=firstmate:fm-isolation-gate
worktree=$case_dir/worktree
project=$case_dir/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_toolchain "$case_dir")
  add_tasks_axi "$fakebin" "0.1.1"
  # The gate is scoped to records whose endpoint could still be running a
  # worker, so the fixture window has to report itself as live.
  make_fake_live_tmux_window "$fakebin" fm-isolation-gate
  out=$(PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh")
  status=$?
  expect_code 1 "$status" "bootstrap must refuse mutation on unproven worker isolation"
  assert_contains "$out" "ISOLATION: bootstrap mutations blocked until worker isolation is clean" \
    "bootstrap did not report the isolation mutation gate"
  pass "bootstrap blocks mutating sweeps when restore-time isolation is unproven"
}

test_bootstrap_does_not_block_on_a_record_whose_endpoint_is_gone() {
  local case_dir fakebin out status
  case_dir="$TMP_ROOT/bootstrap-isolation-stale"
  mkdir -p "$case_dir/home/state" "$case_dir/home/config"
  cat > "$case_dir/home/state/isolation-stale.meta" <<EOF
window=firstmate:fm-isolation-stale
worktree=$case_dir/worktree
project=$case_dir/project
harness=claude
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_toolchain "$case_dir")
  add_tasks_axi "$fakebin" "0.1.1"
  # No window of that name exists, so the endpoint is provably gone: one stale
  # record must not drop the whole home to read-only.
  make_fake_live_tmux_window "$fakebin" fm-some-other-window
  status=0
  out=$(PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh") || status=$?
  expect_code 0 "$status" "a stale record with a dead endpoint must not block bootstrap mutation"
  assert_not_contains "$out" "ISOLATION: bootstrap mutations blocked until worker isolation is clean" \
    "bootstrap blocked the whole home on a record whose endpoint is gone"
  assert_not_contains "$out" "BOOTSTRAP_INFO: isolation for isolation-stale" \
    "a non-actionable stale record was reported without FM_ISOLATION_VERBOSE"
  out=$(PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    FM_ISOLATION_VERBOSE=1 "$ROOT/bin/fm-bootstrap.sh") || status=$?
  assert_contains "$out" "BOOTSTRAP_INFO: isolation for isolation-stale is unproven but its endpoint" \
    "bootstrap did not report the stale unproven record as a verbose fact"
  pass "an unproven record whose endpoint is gone is a quiet fact, not a fleet-wide block"
}

test_bootstrap_reporting
test_gh_pr_checks_json_compatibility
test_no_mistakes_min_version
test_bootstrap_discovers_home_nvm_tasks_axi
test_bootstrap_blocks_mutation_on_unproven_isolation
test_bootstrap_does_not_block_on_a_record_whose_endpoint_is_gone
