#!/usr/bin/env bash
# Behavior tests for secondmate home routing and lifecycle reuse.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-tests.XXXXXX")

make_git_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

make_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  make_git_project "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

add_file_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

make_fake_tmux() {
  local dir=$1 fakebin log capture
  fakebin="$dir/fakebin"
  log="$dir/tmux.log"
  capture="$dir/pane.txt"
  mkdir -p "$fakebin"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_WINDOW"
    fi
    exit 0
    ;;
  display-message)
    printf 'firstmate\n'
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  get)
    # Durable lease: print only the worktree path to stdout (banners to stderr),
    # and record the lease holder so tests can assert it is set and later cleared.
    shift
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
      [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && printf '%s\n' "$holder" > "$FM_FAKE_TREEHOUSE_LEASE_FILE"
      printf 'leased worktree for %s\n' "${holder:-unknown}" >&2
      printf '%s\n' "$FM_FAKE_TREEHOUSE_HOME"
    fi
    exit 0
    ;;
  return)
    shift
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        *) target=$1 ;;
      esac
      shift
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    [ -n "${FM_FAKE_TREEHOUSE_LEASE_FILE:-}" ] && rm -f "$FM_FAKE_TREEHOUSE_LEASE_FILE"
    [ -n "$target" ] && rm -rf -- "$target"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  chmod +x "$fakebin/treehouse"
  : > "$log"
  printf '%s\n' "$fakebin"
}

make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

test_fm_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" FM_SECONDMATE_CHARTER='ops domain' "$ROOT/bin/fm-brief.sh" task-c --secondmate app >/dev/null \
    || fail "secondmate brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-c/brief.md"
  grep -F ">> '$home_one/state/task-c.status'" "$brief" >/dev/null || fail "secondmate brief did not shell-quote FM_HOME state path"

  printf 'project=x\n' > "$home_one/state/task-a.meta"
  FM_HOME="$home_one" FM_GUARD_GRACE=999999 "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "fm-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "fm-lock status is scoped per home"
}

test_home_seed_registry_scope_and_overlapping_projects() {
  local home subhome subhome_abs otherhome fakebin out
  home="$TMP_ROOT/main-home"
  subhome="$TMP_ROOT/design-home"
  otherhome="$TMP_ROOT/other-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  make_git_project "$home/projects/beta"
  make_git_project "$home/projects/gamma"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/alpha.git"
  add_file_origin "$home/projects/beta" "$TMP_ROOT/remotes/beta.git"
  add_file_origin "$home/projects/gamma" "$TMP_ROOT/remotes/gamma.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR +yolo] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
- gamma - gamma project (added 2026-06-22)
EOF

  fakebin=$(make_fake_no_mistakes "$TMP_ROOT/no-mistakes-fake")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SECONDMATE_CHARTER='feature design and implementation for alpha beta gamma' \
    FM_SECONDMATE_SCOPE='feature design and implementation for alpha beta gamma' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta gamma)
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report subhome"
  [ -f "$subhome/.fm-secondmate-home" ] || fail "seed did not mark subhome as seeded"
  [ -f "$subhome/data/charter.md" ] || fail "seed did not write charter into subhome"
  grep -F 'feature design and implementation for alpha beta gamma' "$subhome/data/charter.md" >/dev/null \
    || fail "seeded charter did not record natural-language scope"
  [ -d "$subhome/projects/alpha/.git" ] || fail "alpha was not cloned into subhome"
  [ -d "$subhome/projects/beta/.git" ] || fail "beta was not cloned into subhome"
  [ -d "$subhome/projects/gamma/.git" ] || fail "gamma was not cloned into subhome"
  git -C "$subhome/projects/beta" remote get-url origin >/dev/null 2>&1 || fail "direct-PR beta did not keep an origin remote"
  [ -f "$subhome/projects/gamma/.no-mistakes-init" ] || fail "no-mistakes project was not initialized"
  [ -f "$subhome/projects/gamma/.no-mistakes-doctor" ] || fail "no-mistakes project was not checked"
  out=$(FM_HOME="$subhome" "$ROOT/bin/fm-project-mode.sh" alpha)
  [ "$out" = "direct-PR on" ] || fail "seed did not preserve alpha delivery mode in subhome registry"
  out=$(FM_HOME="$subhome" "$ROOT/bin/fm-project-mode.sh" beta)
  [ "$out" = "direct-PR off" ] || fail "seed did not preserve beta delivery mode in subhome registry"
  grep -F -- '- design - feature design and implementation for alpha beta gamma' "$home/data/secondmates.md" >/dev/null || fail "registry line was not written"
  grep -F 'scope: feature design and implementation for alpha beta gamma' "$home/data/secondmates.md" >/dev/null || fail "registry line did not record scope"
  grep -F 'projects: alpha, beta, gamma' "$home/data/secondmates.md" >/dev/null || fail "registry line did not record project clone list"
  grep -F 'owns:' "$home/data/secondmates.md" >/dev/null && fail "registry line still used owns field"

  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='issue triage and support for beta' \
    FM_SECONDMATE_SCOPE='issue triage and support for beta' \
    "$ROOT/bin/fm-home-seed.sh" other "$otherhome" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  grep -F -- '- other - issue triage and support for beta' "$home/data/secondmates.md" >/dev/null || fail "overlapping registry line was not written"
  grep -F 'projects: beta' "$home/data/secondmates.md" >/dev/null || fail "overlapping project clone list was not recorded"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping projects"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "secondmates registry records scopes and allows overlapping project clone lists"
}

test_home_seed_registry_reads_scope_from_filled_brief() {
  local home subhome
  home="$TMP_ROOT/brief-scope-home"
  subhome="$TMP_ROOT/brief-scope-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/brief-scope-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_SECONDMATE_SCOPE='customer onboarding from brief' \
    scaffold_secondmate_charter "$home" design 'customer onboarding charter' alpha \
    || fail "filled secondmate charter scaffold failed"

  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "seed failed with a filled charter brief"
  grep -F -- '- design - customer onboarding charter' "$home/data/secondmates.md" >/dev/null \
    || fail "registry summary did not come from the filled charter"
  grep -F 'scope: customer onboarding from brief' "$home/data/secondmates.md" >/dev/null \
    || fail "registry scope did not come from the filled charter brief"
  grep -F 'secondmate for alpha' "$home/data/secondmates.md" >/dev/null \
    && fail "registry fell back to a generic project-list scope"
  pass "home seeding records routing scope from filled charter briefs"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two secondmates with the same home"
  fi
  grep -F 'duplicate secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same secondmate id"
  fi
  grep -F 'duplicate secondmate id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/secondmates.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested secondmate homes"
  fi
  grep -F 'overlapping secondmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_treehouse_acquired_home() {
  local home acquired acquired_abs fakebin log lease out
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/tmux.log"
  lease="$TMP_ROOT/dash-fake/lease"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'treehouse get --lease --lease-holder dash' "$log" >/dev/null || fail "seed did not durably lease a home under the secondmate id"
  [ -f "$lease" ] || fail "seed did not record a treehouse lease"
  [ "$(cat "$lease")" = dash ] || fail "seed did not set the lease holder to the secondmate id"
  [ -f "$acquired/.fm-secondmate-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.fm-secondmate-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/secondmates.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding durably leases treehouse-acquired dash homes under the secondmate id"
}

test_home_seed_returns_treehouse_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- dash ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err lease
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/tmux.log"
  lease="$TMP_ROOT/dash-return-fail-fake/lease"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to return treehouse-acquired home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when treehouse return failed"
  [ -f "$lease" ] || fail "failed rollback return did not preserve lease evidence"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt to return the acquired home"
  pass "home seed rollback warns when treehouse-acquired return fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home matching the active firstmate home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$descendant" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active descendant through treehouse"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_rolls_back_failed_clone() {
  local home subhome err missing_remote
  home="$TMP_ROOT/rollback-home"
  subhome="$TMP_ROOT/rollback-subhome"
  err="$TMP_ROOT/rollback-home.err"
  missing_remote="$TMP_ROOT/remotes/missing-beta.git"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  make_git_project "$home/projects/beta"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/rollback-alpha.git"
  git -C "$home/projects/beta" remote add origin "file://$missing_remote"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='rollback scope' FM_SECONDMATE_SCOPE='rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" rollback "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$subhome" ] || fail "failed seed left the newly created secondmate home behind"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "failed seed left a subhome marker"
  [ ! -e "$subhome/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- rollback ' "$home/data/secondmates.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
}

test_home_seed_refuses_missing_filled_charter() {
  local home subhome err
  home="$TMP_ROOT/missing-charter-home"
  subhome="$TMP_ROOT/missing-charter-subhome"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled secondmate charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$subhome" ] || fail "missing charter seed left a generated subhome"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_placeholder_charter() {
  local home subhome err
  home="$TMP_ROOT/placeholder-charter-home"
  subhome="$TMP_ROOT/placeholder-charter-subhome"
  err="$TMP_ROOT/placeholder-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/placeholder-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --secondmate alpha >/dev/null \
    || fail "placeholder charter scaffold failed"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an unfilled placeholder charter"
  fi
  grep -F 'still contains {TASK}' "$err" >/dev/null \
    || fail "seed did not explain placeholder charter refusal"
  [ ! -e "$subhome" ] || fail "placeholder charter seed left a generated subhome"
  [ ! -e "$subhome/projects/alpha" ] || fail "placeholder charter seed cloned before refusing"
  pass "home seeding refuses unfilled placeholder charters"
}

test_home_seed_refuses_empty_charter_fields() {
  local home subhome err
  home="$TMP_ROOT/empty-charter-home"
  subhome="$TMP_ROOT/empty-charter-subhome"
  err="$TMP_ROOT/empty-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/empty-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='   ' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a whitespace-only charter"
  fi
  grep -F 'empty Charter section' "$err" >/dev/null \
    || fail "seed did not explain empty charter refusal"
  [ ! -e "$subhome" ] || fail "empty charter seed left a generated subhome"

  rm -rf "$home/data/design" "$subhome" "$err"
  FM_SECONDMATE_SCOPE='   ' scaffold_secondmate_charter "$home" design 'filled charter' alpha \
    || fail "empty scope fixture scaffold failed"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an empty routing scope"
  fi
  grep -F 'empty Routing scope section' "$err" >/dev/null \
    || fail "seed did not explain empty routing scope refusal"
  [ ! -e "$subhome" ] || fail "empty routing scope seed left a generated subhome"
  pass "home seeding refuses empty normalized charter fields"
}

test_home_seed_refuses_local_only_project() {
  local home subhome err
  home="$TMP_ROOT/local-only-seed-home"
  subhome="$TMP_ROOT/local-only-seed-subhome"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a secondmate home"
  fi
  grep -F 'project alpha is local-only; secondmate routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home subhome err
  home="$TMP_ROOT/delimiter-home"
  subhome="$TMP_ROOT/delimiter)subhome"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='delimiter charter' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'secondmate home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/secondmates.md" ] && grep -F -- '- design ' "$home/data/secondmates.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_ancestor active_descendant root_clone root_descendant root_ancestor root_inside
  active_ancestor="$TMP_ROOT/active-seed-ancestor"
  home="$active_ancestor/main-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  root_ancestor="$TMP_ROOT/active-seed-root-ancestor"
  root_inside="$root_ancestor/nested-root"
  git clone --quiet "$ROOT" "$active_ancestor"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse active FM_HOME"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside active FM_HOME"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active FM_HOME before descendant rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain active FM_HOME"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME ancestor rejection"
  [ ! -f "$active_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of active FM_HOME"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to reuse FM_ROOT"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/fm-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home inside FM_ROOT"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside FM_ROOT before descendant rejection"

  git clone --quiet "$ROOT" "$root_ancestor"
  git clone --quiet "$ROOT" "$root_inside"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_inside" "$ROOT/bin/fm-home-seed.sh" design "$root_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed secondmate home to contain FM_ROOT"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT ancestor rejection"
  [ ! -f "$root_ancestor/.fm-secondmate-home" ] || fail "seed marked an ancestor of FM_ROOT"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home subhome err
  home="$TMP_ROOT/marked-seed-home"
  subhome="$TMP_ROOT/marked-seed-subhome"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/marked-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  printf 'other\n' > "$subhome/.fm-secondmate-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for marked-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another secondmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$subhome/.fm-secondmate-home")" = "other" ] || fail "seed overwrote another secondmate marker"
  pass "home seeding refuses homes marked for another id"
}

test_home_seed_refuses_home_registered_to_another_id() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/registered-seed-home"
  subhome="$TMP_ROOT/registered-seed-subhome"
  err="$TMP_ROOT/registered-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/registered-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/secondmates.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another secondmate"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.fm-secondmate-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
}

test_home_seed_refuses_reassigning_existing_id_to_different_home() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/reassign-id-home"
  first="$TMP_ROOT/reassign-id-first"
  second="$TMP_ROOT/reassign-id-second"
  err="$TMP_ROOT/reassign-id.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/reassign-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$first" alpha >/dev/null \
    || fail "initial seed failed for reassigning-id test"
  first_abs=$(cd "$first" && pwd -P)

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$second" alpha >/dev/null 2>"$err"; then
    fail "seed reassigned an existing secondmate id to a different home"
  fi
  grep -F "secondmate id design is already registered to home $first_abs" "$err" >/dev/null \
    || fail "seed did not explain same-id different-home rejection"
  [ ! -e "$second" ] || fail "failed id reassignment created the new subhome"
  [ "$(cat "$first/.fm-secondmate-home")" = design ] || fail "failed id reassignment changed the original marker"
  grep -F "home: $first_abs" "$home/data/secondmates.md" >/dev/null \
    || fail "failed id reassignment did not preserve the original registry route"
  second_abs=$(cd "$(dirname "$second")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$second")")
  grep -F "home: $second_abs" "$home/data/secondmates.md" >/dev/null \
    && fail "failed id reassignment recorded the rejected home"
  pass "home seeding refuses same-id reassignment to a different home"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/secondmates.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered secondmate home"
  fi
  grep -F 'overlaps registered secondmate home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.fm-secondmate-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_home_seed_refuses_remote_backed_project_without_origin() {
  local home subhome err
  home="$TMP_ROOT/no-origin-home"
  subhome="$TMP_ROOT/no-origin-subhome"
  err="$TMP_ROOT/no-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for no-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed remote-backed project without origin"
  fi
  grep -F 'project alpha is direct-PR but has no origin remote' "$err" >/dev/null || fail "seed did not explain missing origin for remote-backed project"
  pass "remote-backed subhome seeding requires a source origin"
}

test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin() {
  local home subhome subhome_abs err expected
  home="$TMP_ROOT/wrong-origin-home"
  subhome="$TMP_ROOT/wrong-origin-subhome"
  err="$TMP_ROOT/wrong-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/wrong-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  mkdir -p "$subhome/projects"
  git clone --quiet "$home/projects/alpha" "$subhome/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for wrong-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted existing remote-backed project with wrong origin"
  fi
  expected=$(git -C "$home/projects/alpha" remote get-url origin)
  grep -F "seeded project alpha at $subhome_abs/projects/alpha has origin" "$err" >/dev/null \
    || fail "seed did not identify wrong origin for existing remote-backed project"
  grep -F "expected $expected" "$err" >/dev/null \
    || fail "seed did not report expected origin for existing remote-backed project"
  pass "remote-backed subhome seeding validates existing destination origins"
}

test_home_seed_resolves_relative_source_origins() {
  local home subhome subhome_abs expected out actual
  home="$TMP_ROOT/relative-origin-home"
  subhome="$TMP_ROOT/relative-origin-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/remotes"
  make_git_project "$home/projects/alpha"
  git clone --quiet --bare "$home/projects/alpha" "$home/remotes/relative-alpha.git"
  git -C "$home/projects/alpha" remote add origin ../../remotes/relative-alpha.git
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for relative origin seed test"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha)
  subhome_abs=$(cd "$subhome" && pwd -P)
  expected=$(cd "$home/remotes/relative-alpha.git" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report relative-origin subhome"
  [ -d "$subhome/projects/alpha/.git" ] || fail "relative source origin was not cloned"
  actual=$(git -C "$subhome/projects/alpha" remote get-url origin)
  [ "$actual" = "$expected" ] || fail "relative source origin was not cloned through the resolved path"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "relative source origin did not compare equal on reseed"
  pass "home seeding resolves relative source origins against the source project"
}

test_home_seed_skips_initialized_existing_no_mistakes_projects() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-initialized-home"
  subhome="$TMP_ROOT/existing-initialized-subhome"
  err="$TMP_ROOT/existing-initialized.err"
  log="$TMP_ROOT/existing-initialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  make_git_project "$home/projects/beta"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/existing-alpha.git"
  add_file_origin "$home/projects/beta" "$TMP_ROOT/remotes/existing-beta.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  git -C "$subhome/projects/alpha" remote add no-mistakes "$TMP_ROOT/no-mistakes-alpha.git"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' '- beta - beta project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-initialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" FM_FAKE_NO_MISTAKES_FAIL_PROJECT=beta \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing init rollback scope' FM_SECONDMATE_SCOPE='existing init rollback scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though later no-mistakes initialization failed"
  fi
  grep -F 'failed to initialize no-mistakes for beta' "$err" >/dev/null \
    || fail "seed did not explain later no-mistakes initialization failure"
  grep -F "$subhome/projects/alpha" "$log" >/dev/null \
    && fail "seed ran no-mistakes against an initialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated initialized existing clone with no-mistakes init"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-doctor" ] || fail "seed mutated initialized existing clone with no-mistakes doctor"
  [ ! -e "$subhome/projects/beta" ] || fail "failed seed left a newly cloned project after no-mistakes failure"
  pass "home seeding skips initialized existing no-mistakes clones"
}

test_home_seed_refuses_uninitialized_existing_no_mistakes_project() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-uninitialized-home"
  subhome="$TMP_ROOT/existing-uninitialized-subhome"
  err="$TMP_ROOT/existing-uninitialized.err"
  log="$TMP_ROOT/existing-uninitialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/uninitialized-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-uninitialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing uninitialized scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed initialized a preexisting no-mistakes clone"
  fi
  grep -F 'refusing to mutate preexisting clone' "$err" >/dev/null \
    || fail "seed did not explain uninitialized existing no-mistakes clone refusal"
  [ ! -s "$log" ] || fail "seed ran no-mistakes before refusing an uninitialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated uninitialized existing clone"
  pass "home seeding refuses uninitialized existing no-mistakes clones"
}

test_home_seed_refuses_project_destinations_outside_subhome() {
  local home subhome sink err
  home="$TMP_ROOT/symlink-project-home"
  subhome="$TMP_ROOT/symlink-project-subhome"
  sink="$home/data/symlink-projects"
  err="$TMP_ROOT/symlink-project.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$sink"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  rm -rf "$subhome/projects"
  ln -s "$sink" "$subhome/projects"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink destination seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed followed a subhome projects symlink outside the subhome"
  fi
  grep -F 'secondmate projects directory must resolve inside the secondmate home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the subhome"
}

test_home_seed_refuses_operational_dirs_outside_subhome() {
  local home subhome sink err opdir
  home="$TMP_ROOT/symlink-opdir-home"
  err="$TMP_ROOT/symlink-opdir.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-opdir-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink operational dir seed test"

  for opdir in data state config; do
    subhome="$TMP_ROOT/symlink-opdir-subhome-$opdir"
    sink="$home/data/symlink-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$sink"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "seed did not explain unsafe $opdir directory rejection"
    [ ! -f "$subhome/.fm-secondmate-home" ] || fail "seed marked subhome after unsafe $opdir directory rejection"
  done
  pass "home seeding refuses operational directories outside the subhome"
}

test_home_seed_refuses_symlinked_leaf_files() {
  local home subhome sink err leaf target expected
  home="$TMP_ROOT/symlink-leaf-home"
  err="$TMP_ROOT/symlink-leaf.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-leaf-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_secondmate_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink leaf seed test"

  for leaf in data/projects.md data/charter.md .fm-secondmate-home; do
    subhome="$TMP_ROOT/symlink-leaf-subhome-${leaf//\//-}"
    sink="$home/data/symlink-leaf-${leaf//\//-}"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$(dirname "$subhome/$leaf")" "$(dirname "$sink")"
    expected=outside
    if [ "$leaf" = ".fm-secondmate-home" ]; then
      expected=design
    fi
    printf '%s\n' "$expected" > "$sink"
    ln -s "$sink" "$subhome/$leaf"
    if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted symlinked leaf file $leaf"
    fi
    grep -F 'secondmate leaf file must not be a symlink:' "$err" >/dev/null \
      || fail "seed did not explain symlinked leaf refusal for $leaf"
    target=$(cat "$sink")
    [ "$target" = "$expected" ] || fail "seed overwrote outside symlink target for $leaf"
    [ ! -f "$subhome/.fm-secondmate-home" ] || [ "$leaf" = ".fm-secondmate-home" ] || fail "seed marked subhome after symlinked leaf refusal"
  done
  pass "home seeding refuses symlinked leaf files"
}

test_secondmate_spawn_records_home_meta() {
  local home subhome subhome_abs fakebin log meta
  home="$TMP_ROOT/spawn home"
  subhome="$TMP_ROOT/spawn subhome"
  mkdir -p "$home/data/spawn-sub" "$home/state" "$subhome/data"
  mark_firstmate_home "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf 'spawn-sub\n' > "$subhome/.fm-secondmate-home"
  printf '%s\n' '- spawn-sub - spawn domain (home: '"$subhome"'; scope: spawn domain; projects: alpha, beta; added 2026-06-22)' > "$home/data/secondmates.md"
  printf 'stale parent charter\n' > "$home/data/spawn-sub/brief.md"
  printf 'current persistent charter\n' > "$subhome/data/charter.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-fake")
  log="$TMP_ROOT/spawn-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/parent-config" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" spawn-sub "$subhome" codex --secondmate >/dev/null \
    || fail "secondmate spawn failed"

  meta="$home/state/spawn-sub.meta"
  grep -Fx 'kind=secondmate' "$meta" >/dev/null || fail "meta did not record kind=secondmate"
  grep -Fx "home=$subhome_abs" "$meta" >/dev/null || fail "meta did not record subhome"
  grep -Fx 'projects=alpha, beta' "$meta" >/dev/null || fail "meta did not record project clone list"
  grep -F 'treehouse get' "$log" >/dev/null && fail "secondmate spawn should not run project treehouse get"
  grep -F "FM_HOME='$subhome_abs'" "$log" >/dev/null || fail "secondmate launch did not set FM_HOME to subhome"
  grep -F 'FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE=' "$log" >/dev/null || fail "secondmate launch did not clear operational overrides"
  grep -F 'FM_CONFIG_OVERRIDE=' "$log" >/dev/null || fail "secondmate launch did not clear config override"
  grep -F "$subhome_abs/data/charter.md" "$log" >/dev/null || fail "secondmate launch did not use persistent charter"
  grep -F "$home/data/spawn-sub/brief.md" "$log" >/dev/null && fail "secondmate launch used stale parent brief"
  grep -F 'notify=' "$log" >/dev/null && fail "secondmate codex launch should not install parent turn-end notify"
  grep -F 'turn-ended' "$log" >/dev/null && fail "secondmate launch should not reference parent turn-end marker"
  pass "kind=secondmate spawn launches in the home and records routing meta"
}

test_secondmate_spawn_requires_seeded_matching_home() {
  local home subhome wronghome marker_only active_descendant active_ancestor ancestor_active_home fakeroot root_descendant root_ancestor root_inside fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  marker_only="$TMP_ROOT/spawn-validate-marker-only"
  active_descendant="$home/data/spawn-descendant-home"
  active_ancestor="$TMP_ROOT/spawn-active-ancestor"
  ancestor_active_home="$active_ancestor/main-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  root_ancestor="$TMP_ROOT/spawn-root-ancestor"
  root_inside="$root_ancestor/repo"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data" "$marker_only/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  mkdir -p "$ancestor_active_home/data" "$ancestor_active_home/state" "$active_ancestor/data" "$root_ancestor/data" "$root_inside/bin"
  cat > "$root_inside/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root_inside/bin/fm-guard.sh"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/tmux.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  # Canonical ordering proof: validation runs before any tmux side-effect. Every rejection
  # reason below shares this one linear pre-launch path, so they each assert only their own
  # refusal message rather than re-proving "no window created before validation" each time.
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before validation"

  printf 'other\n' > "$wronghome/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$wronghome" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home marked for another secondmate"
  fi
  grep -F 'marked for secondmate other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"

  printf 'domain\n' > "$marker_only/.fm-secondmate-home"
  printf 'charter\n' > "$marker_only/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing AGENTS.md"
  fi
  grep -F 'not a firstmate home (missing AGENTS.md)' "$err" >/dev/null || fail "spawn did not explain missing AGENTS.md"

  printf '# Firstmate\n' > "$marker_only/AGENTS.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$marker_only" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a marked home missing bin"
  fi
  grep -F 'not a firstmate home (missing bin/)' "$err" >/dev/null || fail "spawn did not explain missing bin"

  printf 'domain\n' > "$home/.fm-secondmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$home" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the active home"
  fi
  grep -F 'secondmate home cannot be the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$ROOT" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted the firstmate repo root"
  fi
  grep -F 'secondmate home cannot be the firstmate repo' "$err" >/dev/null || fail "spawn did not reject firstmate repo root"

  printf 'domain\n' > "$active_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the active firstmate home"
  fi
  grep -F 'secondmate home cannot be inside the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home descendant"

  printf 'domain\n' > "$active_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$active_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$ancestor_active_home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the active firstmate home"
  fi
  grep -F 'secondmate home cannot be an ancestor of the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home ancestor"

  printf 'domain\n' > "$root_descendant/.fm-secondmate-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_descendant" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home inside the firstmate repo"
  fi
  grep -F 'secondmate home cannot be inside the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"

  printf 'domain\n' > "$root_ancestor/.fm-secondmate-home"
  printf 'charter\n' > "$root_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root_inside" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_ancestor" codex --secondmate >/dev/null 2>"$err"; then
    fail "secondmate spawn accepted a home containing the firstmate repo"
  fi
  grep -F 'secondmate home cannot be an ancestor of the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo ancestor"

  pass "secondmate spawn validates homes before launch"
}

test_secondmate_spawn_refuses_operational_dirs_outside_subhome() {
  local home subhome sink fakebin log err opdir
  home="$TMP_ROOT/spawn-opdir-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-opdir-fake")
  log="$TMP_ROOT/spawn-opdir-fake/tmux.log"
  err="$TMP_ROOT/spawn-opdir.err"
  mkdir -p "$home/data" "$home/state"

  for opdir in data state config projects; do
    subhome="$TMP_ROOT/spawn-opdir-subhome-$opdir"
    sink="$home/data/spawn-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    mkdir -p "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects" "$sink"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    printf 'charter\n' > "$subhome/data/charter.md"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if [ "$opdir" = data ]; then
      printf 'charter\n' > "$sink/charter.md"
    fi
    : > "$log"
    if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-opdir-fake/pane.txt" \
      "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --secondmate >/dev/null 2>"$err"; then
      fail "secondmate spawn accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "secondmate $opdir directory must resolve inside the secondmate home" "$err" >/dev/null \
      || fail "spawn did not explain unsafe $opdir directory rejection"
    grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before unsafe $opdir directory validation"
  done
  pass "secondmate spawn refuses operational directories outside the subhome"
}

test_fm_send_resolves_bare_firstmate_window_from_home_meta() {
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  cat > "$home/state/domain.meta" <<EOF
window=current-session:fm-domain
kind=secondmate
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-domain" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-domain 'route this work' >/dev/null 2>"$err" \
    || fail "fm-send failed for a bare firstmate window with home metadata"

  grep -F 'send-keys -t current-session:fm-domain -l route this work' "$log" >/dev/null \
    || fail "fm-send did not use the window recorded in this home's meta"
  grep -F 'send-keys -t other-session:fm-domain' "$log" >/dev/null \
    && fail "fm-send targeted a foreign window with the same bare name"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "fm-send sent to a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-send fell back to a foreign same-name window"

  pass "fm-send resolves bare firstmate windows through this home"
}

test_recovery_respawn_uses_persistent_home() {
  local home subhome subhome_abs fakebin meta
  home="$TMP_ROOT/recovery-home"
  subhome="$TMP_ROOT/recovery-subhome"
  mkdir -p "$home/data" "$home/state" "$subhome/data"
  mark_firstmate_home "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf 'recover-sub\n' > "$subhome/.fm-secondmate-home"
  printf 'charter\n' > "$subhome/data/charter.md"
  printf '%s\n' '- recover-sub - recovery domain mentions home: '"$TMP_ROOT/ignored-summary-home"' (home: '"$subhome"'; scope: recovery domain mentions home: '"$TMP_ROOT/ignored-scope-home"'; projects: gamma; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/recovery-fake")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/recovery-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/recovery-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" recover-sub "echo relaunch" --secondmate >/dev/null 2>/dev/null \
    || fail "recovery secondmate respawn failed"

  meta="$home/state/recover-sub.meta"
  grep -Fx "home=$subhome_abs" "$meta" >/dev/null || fail "respawn did not preserve persistent home from meta/registry"
  grep -Fx 'projects=gamma' "$meta" >/dev/null || fail "respawn did not preserve project clone list from registry"
  grep -Fx 'window=firstmate:fm-recover-sub' "$meta" >/dev/null || fail "respawn did not reconstruct the direct report window"
  pass "restart recovery can respawn a secondmate from durable registry and charter"
}

test_secondmate_teardown_retires_empty_home() {
  local home subhome subhome_abs fakebin log lease fmroot
  home="$TMP_ROOT/teardown-home"
  subhome="$TMP_ROOT/teardown-subhome"
  fmroot="$TMP_ROOT/teardown-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-fake")
  log="$TMP_ROOT/teardown-fake/tmux.log"
  lease="$TMP_ROOT/teardown-fake/lease"
  printf 'domain\n' > "$lease"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for empty secondmate home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not release the secondmate home lease via treehouse return"
  [ ! -e "$lease" ] || fail "teardown left the secondmate home lease held after retirement"
  [ ! -d "$subhome" ] || fail "teardown did not remove the retired secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove secondmate registry route"
  pass "secondmate teardown retires empty homes and releases routing"
}

test_secondmate_teardown_refuses_failed_leased_home_return() {
  local home subhome subhome_abs fakebin log fmroot err rc
  home="$TMP_ROOT/teardown-return-fail-home"
  subhome="$TMP_ROOT/teardown-return-fail-subhome"
  fmroot="$TMP_ROOT/teardown-return-fail-fmroot"
  err="$TMP_ROOT/teardown-return-fail.err"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-return-fail-fake")
  log="$TMP_ROOT/teardown-return-fail-fake/tmux.log"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-return-fail-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown succeeded despite failed treehouse return"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not try to return the leased home"
  grep -F 'treehouse return failed for secondmate home' "$err" >/dev/null || fail "teardown did not report failed leased home return"
  [ -d "$subhome" ] || fail "teardown removed a leased home after return failed"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared meta after leased home return failed"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null || fail "teardown removed registry route after leased home return failed"
  pass "secondmate teardown refuses to hide failed leased-home return"
}

test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return() {
  local home subhome subhome_abs fakebin log
  home="$TMP_ROOT/plain-clone-teardown-home"
  subhome="$TMP_ROOT/plain-clone-teardown-subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  mark_firstmate_home "$subhome"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/plain-clone-teardown-fake")
  log="$TMP_ROOT/plain-clone-teardown-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/plain-clone-teardown-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for plain-clone secondmate home"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null && fail "teardown tried to return a plain-clone home through treehouse"
  [ ! -d "$subhome" ] || fail "teardown did not remove the plain-clone secondmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta for plain-clone home"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "teardown did not remove plain-clone registry route"
  pass "secondmate teardown raw-removes plain-clone homes"
}

test_secondmate_force_teardown_discards_child_work() {
  local home subhome childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  subhome="$TMP_ROOT/force-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  make_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/force-teardown-fake")
  log="$TMP_ROOT/force-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>&1; then
    fail "teardown allowed a secondmate with in-flight child work"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$subhome" ] || fail "force teardown did not remove the retired secondmate home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/secondmates.md" >/dev/null && fail "force teardown did not remove secondmate registry route"
  grep -F 'kill-window -t firstmate:fm-child' "$log" >/dev/null || fail "force teardown did not kill child window"
  grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window"
  pass "secondmate force teardown discards child work"
}

test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home() {
  local opdir home subhome target fakebin err log
  for opdir in data state config projects; do
    home="$TMP_ROOT/symlink-inside-teardown-home-$opdir"
    subhome="$TMP_ROOT/symlink-inside-teardown-subhome-$opdir"
    target="$subhome/internal-$opdir"
    err="$TMP_ROOT/symlink-inside-teardown-$opdir.err"
    rm -rf "$home" "$subhome"
    mkdir -p "$home/state" "$home/data" "$subhome" "$target"
    printf 'domain\n' > "$subhome/.fm-secondmate-home"
    ln -s "$target" "$subhome/$opdir"
    cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
    printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
    fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-inside-teardown-fake-$opdir")
    log="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/tmux.log"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/pane.txt" \
      "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err" \
      || fail "force teardown refused $opdir symlinked inside the secondmate home"
    [ ! -e "$subhome" ] || fail "force teardown did not remove subhome with inside $opdir symlink"
    [ ! -e "$home/state/domain.meta" ] || fail "force teardown did not clear parent meta for inside $opdir symlink"
    grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window for inside $opdir symlink"
  done
  pass "force teardown allows operational directory symlinks inside the subhome"
}

test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home() {
  local home subhome external_state fakebin err log
  home="$TMP_ROOT/symlink-state-teardown-home"
  subhome="$TMP_ROOT/symlink-state-teardown-subhome"
  external_state="$home/data/external-state"
  err="$TMP_ROOT/symlink-state-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome" "$external_state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  ln -s "$external_state" "$subhome/state"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/symlink-state-teardown-fake")
  log="$TMP_ROOT/symlink-state-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/symlink-state-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a symlinked secondmate state directory"
  fi
  [ -d "$subhome" ] || fail "force teardown removed subhome after symlinked state refusal"
  [ -d "$external_state" ] || fail "force teardown removed external symlink target"
  grep -F 'state directory' "$err" >/dev/null || fail "teardown did not explain symlinked state refusal"
  grep -F 'resolves outside the secondmate home' "$err" >/dev/null || fail "teardown did not identify unsafe state symlink"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before symlinked state refusal"
  pass "force teardown refuses operational directory symlinks outside the subhome"
}

test_secondmate_teardown_requires_seed_marker() {
  local home subhome fakebin err log
  home="$TMP_ROOT/unmarked-teardown-home"
  subhome="$TMP_ROOT/unmarked-teardown-subhome"
  err="$TMP_ROOT/unmarked-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/unmarked-teardown-fake")
  log="$TMP_ROOT/unmarked-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unmarked-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed an unmarked firstmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed unmarked subhome after refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before seed marker validation"
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "teardown did not explain missing seed marker"
  pass "secondmate teardown requires seeded home marker"
}

test_secondmate_teardown_refuses_registered_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  subhome="$TMP_ROOT/nested-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
window=firstmate:fm-nested
worktree=$nested
project=$nested
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/secondmates.md" <<EOF
- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain mentions home: $TMP_ROOT/ignored-summary-home (home: $nested; scope: nested domain mentions home: $TMP_ROOT/ignored-scope-home; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "secondmate teardown refuses homes containing registered nested homes"
}

test_secondmate_teardown_refuses_child_registry_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/child-registry-teardown-home"
  subhome="$TMP_ROOT/child-registry-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/child-registry-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'nested\n' > "$nested/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  printf '%s\n' '- nested - nested domain (home: '"$nested"'; scope: nested domain; projects: beta; added 2026-06-22)' > "$subhome/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-registry-teardown-fake")
  log="$TMP_ROOT/child-registry-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-registry-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing a child-registry secondmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed ancestor home after child-registry refusal"
  [ -d "$nested" ] || fail "teardown removed child-registry nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after child-registry refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before child-registry refusal"
  grep -F 'contains registered secondmate home' "$err" >/dev/null || fail "teardown did not explain child-registry nested-home refusal"
  pass "secondmate teardown refuses nested homes from the child registry"
}

test_secondmate_force_teardown_prevalidates_before_child_cleanup() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/prevalidate-teardown-home"
  subhome="$TMP_ROOT/prevalidate-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/prevalidate-child-worktree"
  err="$TMP_ROOT/prevalidate-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/prevalidate-teardown-fake")
  log="$TMP_ROOT/prevalidate-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/prevalidate-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown discarded child work before validating subhome"
  fi
  [ -d "$subhome" ] || fail "force teardown removed unmarked subhome after refusal"
  [ -d "$childwt" ] || fail "force teardown removed child worktree before validation"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before validation"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta before validation"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before subhome validation"
  grep -F 'not a seeded secondmate home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates subhome before child cleanup"
}

test_secondmate_force_teardown_refuses_child_active_home_descendant() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  subhome="$TMP_ROOT/child-active-descendant-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-active-descendant-fake")
  log="$TMP_ROOT/child-active-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-active-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside active FM_HOME"
  fi
  [ -d "$home/data" ] || fail "force teardown removed active home data"
  [ -d "$subhome" ] || fail "force teardown removed subhome after child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before child validation refusal"
  grep -F 'inside the active firstmate home' "$err" >/dev/null || fail "force teardown did not explain active home descendant rejection"
  pass "force teardown refuses child worktrees inside the active home"
}

test_secondmate_force_teardown_refuses_child_repo_descendant() {
  local home subhome childproj childwt fakeroot fakebin err log
  home="$TMP_ROOT/child-repo-descendant-home"
  subhome="$TMP_ROOT/child-repo-descendant-subhome"
  childproj="$subhome/projects/alpha"
  fakeroot="$TMP_ROOT/child-repo-descendant-root"
  childwt="$fakeroot/data"
  err="$TMP_ROOT/child-repo-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/child-repo-descendant-fake")
  log="$TMP_ROOT/child-repo-descendant-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/child-repo-descendant-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside FM_ROOT"
  fi
  [ -d "$childwt" ] || fail "force teardown removed repo descendant worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after repo child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after repo child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after repo child validation refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before repo child validation refusal"
  grep -F 'inside the firstmate repo' "$err" >/dev/null || fail "force teardown did not explain repo descendant rejection"
  pass "force teardown refuses child worktrees inside the firstmate repo"
}

test_secondmate_force_teardown_refuses_unregistered_child_worktree() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  subhome="$TMP_ROOT/unregistered-child-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  cat > "$subhome/state/child.meta" <<EOF
window=firstmate:fm-child
worktree=$childwt
project=$childproj
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/unregistered-child-fake")
  log="$TMP_ROOT/unregistered-child-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unregistered-child-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed an unregistered child worktree"
  fi
  [ -d "$childwt" ] || fail "force teardown removed unregistered child worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after unregistered child refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after unregistered child refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after unregistered child refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "force teardown killed windows before unregistered child refusal"
  grep -F 'is not a git worktree for' "$err" >/dev/null || fail "force teardown did not explain unregistered child rejection"
  pass "force teardown refuses unregistered child worktree paths"
}

test_secondmate_teardown_refuses_home_ancestor() {
  local danger home fakebin err
  danger="$TMP_ROOT/ancestor-teardown"
  home="$danger/main-home"
  err="$TMP_ROOT/ancestor-teardown.err"
  mkdir -p "$home/state" "$home/data" "$danger/state"
  printf 'domain\n' > "$danger/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$danger
project=$danger
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$danger
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$danger"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/ancestor-teardown-fake")
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/ancestor-teardown-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/ancestor-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed an ancestor of active FM_HOME"
  fi
  [ -d "$danger" ] || fail "teardown removed ancestor path after refusal"
  grep -F 'ancestor of the active firstmate home' "$err" >/dev/null || fail "teardown did not explain ancestor rejection"
  pass "secondmate teardown refuses ancestor homes"
}

test_secondmate_teardown_refuses_home_descendants() {
  local home active_descendant fakeroot root_descendant fakebin log err
  home="$TMP_ROOT/descendant-teardown-home"
  active_descendant="$home/data/domain-home"
  fakeroot="$TMP_ROOT/descendant-teardown-root"
  root_descendant="$fakeroot/tmp/domain-home"
  err="$TMP_ROOT/descendant-teardown.err"
  mkdir -p "$home/state" "$home/data" "$active_descendant/state" "$root_descendant/state" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  printf 'domain\n' > "$active_descendant/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$active_descendant
project=$active_descendant
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$active_descendant
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$active_descendant"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/descendant-teardown-fake")
  log="$TMP_ROOT/descendant-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/descendant-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home inside active FM_HOME"
  fi
  [ -d "$active_descendant" ] || fail "teardown removed active-home descendant after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after active descendant refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before active descendant refusal"
  grep -F 'inside the active firstmate home' "$err" >/dev/null || fail "teardown did not explain active descendant rejection"

  : > "$log"
  printf 'repo-domain\n' > "$root_descendant/.fm-secondmate-home"
  cat > "$home/state/repo-domain.meta" <<EOF
window=firstmate:fm-repo-domain
worktree=$root_descendant
project=$root_descendant
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$root_descendant
projects=alpha
EOF
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/descendant-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" repo-domain >/dev/null 2>"$err"; then
    fail "teardown removed a home inside FM_ROOT"
  fi
  [ -d "$root_descendant" ] || fail "teardown removed repo descendant after refusal"
  [ -e "$home/state/repo-domain.meta" ] || fail "teardown cleared parent meta after repo descendant refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before repo descendant refusal"
  grep -F 'inside the firstmate repo' "$err" >/dev/null || fail "teardown did not explain repo descendant rejection"
  pass "secondmate teardown refuses descendant homes"
}

test_secondmate_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="firstmate:fm-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=secondmate
home=$TMP_ROOT/watch-subhome
projects=alpha
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_LOG="$TMP_ROOT/watch-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle secondmate"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle secondmate pane triggered stale wake"
  pass "idle kind=secondmate pane is healthy and not stale"
}

seed_secondmate_home_marker() {
  # Make a directory look like a genuine seeded secondmate home for handoff tests.
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

test_secondmate_charter_brief_is_idle_by_default() {
  local home brief
  home="$TMP_ROOT/idle-charter-home"
  mkdir -p "$home/data" "$home/state"
  scaffold_secondmate_charter "$home" idle-sm 'feature work for alpha' alpha
  brief="$home/data/idle-sm/brief.md"
  [ -f "$brief" ] || fail "secondmate charter brief was not scaffolded"
  # Idle contract: waits for routed work, never self-initiates.
  grep -F 'go idle and wait silently for the main firstmate' "$brief" >/dev/null \
    || fail "charter brief does not tell the secondmate to go idle and wait for routed work"
  grep -F 'Act only on tasks the main firstmate routes to you' "$brief" >/dev/null \
    || fail "charter brief does not restrict work to routed tasks"
  grep -F 'never spawn a survey, audit, or any self-directed' "$brief" >/dev/null \
    || fail "charter brief does not forbid self-initiated survey/audit work"
  # Reconcile-on-startup must remain: bootstrap and recovery still run, scoped to own work.
  grep -F 'run normal firstmate bootstrap and recovery' "$brief" >/dev/null \
    || fail "charter brief dropped the bootstrap/recovery reconciliation step"
  grep -F 'only to RECONCILE work that is already yours' "$brief" >/dev/null \
    || fail "charter brief does not scope startup work to reconciling existing work"
  # Regression guard: the over-broad phrasing that got misread as "go find work" is gone.
  if grep -F 'then supervise work that matches your scope' "$brief" >/dev/null; then
    fail "charter brief still uses the over-broad 'supervise work that matches your scope' phrasing"
  fi
  pass "secondmate charter brief is idle by default and does not self-initiate work"
}

test_backlog_handoff_moves_in_scope_items() {
  local home subhome subhome_abs out before
  home="$TMP_ROOT/handoff-main"
  subhome="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" design
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] feat-x - add feature x (repo: alpha)
- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF

  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design feat-x feat-y) \
    || fail "handoff failed for in-scope items"
  printf '%s\n' "$out" | grep -F 'handed off 2 item(s) to design' >/dev/null \
    || fail "handoff did not report the moved items"

  # Moved items leave the main backlog; untouched items stay.
  grep -F 'feat-x' "$home/data/backlog.md" >/dev/null && fail "feat-x was not removed from the main backlog"
  grep -F 'feat-y' "$home/data/backlog.md" >/dev/null && fail "feat-y was not removed from the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "out-of-scope bug-z was wrongly removed from the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight item was wrongly removed from the main backlog"

  # Moved items arrive in the secondmate backlog, verbatim and under their section.
  grep -F -- '- [ ] feat-x - add feature x (repo: alpha)' "$subhome/data/backlog.md" >/dev/null \
    || fail "feat-x did not arrive verbatim in the secondmate backlog"
  grep -F -- '- [ ] feat-y - add feature y (repo: beta) blocked-by: feat-x - waits' "$subhome/data/backlog.md" >/dev/null \
    || fail "feat-y line was not preserved verbatim in the secondmate backlog"
  awk '/^## Queued/{q=1;next} /^## /{q=0} q && /feat-x/{found=1} END{exit found?0:1}' "$subhome/data/backlog.md" \
    || fail "feat-x did not land under the Queued section in the secondmate backlog"

  # Idempotent re-run: no error, no duplication, main untouched.
  before=$(cat "$home/data/backlog.md")
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design feat-x feat-y >/dev/null 2>&1 \
    || fail "idempotent re-run failed"
  [ "$(grep -cF -- '- [ ] feat-x - add feature x (repo: alpha)' "$subhome/data/backlog.md")" -eq 1 ] \
    || fail "idempotent re-run duplicated feat-x in the secondmate backlog"
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "idempotent re-run mutated the main backlog"

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item from the main backlog"

  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  grep -F 'live-task' "$subhome/data/backlog.md" >/dev/null && fail "in-flight refusal copied the live task"

  # An unregistered secondmate is refused.
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered secondmate id"
  fi
  pass "fm-backlog-handoff moves in-scope items, is idempotent, and aborts safely"
}

test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home() {
  local home subhome subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside
  home="$TMP_ROOT/handoff-safety-main"
  subhome="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  # A Done item handed into a secondmate backlog lacking a Done section gets one.
  seed_secondmate_home_marker "$subhome" archive
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$subhome/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] shipped-task - shipped thing - local main (merged 2026-06-19)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" archive shipped-task >/dev/null \
    || fail "handoff of a Done item failed"
  grep -F '## Done' "$subhome/data/backlog.md" >/dev/null \
    || fail "handoff did not create the missing Done section in the secondmate backlog"
  awk '/^## Done/{d=1;next} /^## /{d=0} d && /shipped-task/{found=1} END{exit found?0:1}' "$subhome/data/backlog.md" \
    || fail "Done item did not land under the created Done section"
  grep -F 'keep-me' "$subhome/data/backlog.md" >/dev/null || fail "handoff clobbered the existing secondmate backlog content"

  # A registered home that is not a seeded secondmate home (e.g. a project clone)
  # is refused, and nothing is written into it.
  make_git_project "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/secondmates.md"
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" proj-sm shipped-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded secondmate home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-secondmate home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-sm\n' > "$markerhome/.fm-secondmate-home"
  printf -- '- marker-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" marker-sm marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a secondmate home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_secondmate_home_marker "$symlinkhome" symlink-sm
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" symlink-sm symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a secondmate home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked secondmate data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "fm-backlog-handoff creates absent sections and refuses unsafe homes"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_home_seed_registry_scope_and_overlapping_projects
test_home_seed_registry_reads_scope_from_filled_brief
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_treehouse_acquired_home
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_placeholder_charter
test_home_seed_refuses_empty_charter_fields
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_reassigning_existing_id_to_different_home
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_home_seed_refuses_operational_dirs_outside_subhome
test_home_seed_refuses_symlinked_leaf_files
test_secondmate_spawn_records_home_meta
test_secondmate_spawn_requires_seeded_matching_home
test_secondmate_spawn_refuses_operational_dirs_outside_subhome
test_fm_send_resolves_bare_firstmate_window_from_home_meta
test_recovery_respawn_uses_persistent_home
test_secondmate_teardown_retires_empty_home
test_secondmate_teardown_refuses_failed_leased_home_return
test_secondmate_teardown_removes_plain_clone_home_without_treehouse_return
test_secondmate_force_teardown_discards_child_work
test_secondmate_force_teardown_allows_operational_dir_symlinks_inside_home
test_secondmate_force_teardown_refuses_operational_dir_symlink_outside_home
test_secondmate_teardown_requires_seed_marker
test_secondmate_teardown_refuses_registered_nested_home
test_secondmate_teardown_refuses_child_registry_nested_home
test_secondmate_force_teardown_prevalidates_before_child_cleanup
test_secondmate_force_teardown_refuses_child_active_home_descendant
test_secondmate_force_teardown_refuses_child_repo_descendant
test_secondmate_force_teardown_refuses_unregistered_child_worktree
test_secondmate_teardown_refuses_home_ancestor
test_secondmate_teardown_refuses_home_descendants
test_secondmate_idle_pane_is_not_stale
test_secondmate_charter_brief_is_idle_by_default
test_backlog_handoff_moves_in_scope_items
test_backlog_handoff_creates_absent_section_and_refuses_non_secondmate_home
