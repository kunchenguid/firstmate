#!/usr/bin/env bash
# Behavior tests for sub-firstmate home routing and lifecycle reuse.
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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-sub-firstmate-tests.XXXXXX")

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
if [ "${1:-}" = get ] && [ -n "${FM_FAKE_TREEHOUSE_HOME:-}" ]; then
  mkdir -p "$FM_FAKE_TREEHOUSE_HOME"
  ( cd "$FM_FAKE_TREEHOUSE_HOME" && "$SHELL" )
  exit $?
fi
if [ "${1:-}" = return ] && [ "${2:-}" = --force ] && [ -n "${3:-}" ]; then
  rm -rf -- "$3"
fi
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
  local home_one home_two out
  home_one="$TMP_ROOT/home-one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under FM_HOME"
  [ -f "$home_one/data/task-a/brief.md" ] || fail "brief was not written under FM_HOME/data"
  grep -F "$home_one/state/task-a.status" "$home_one/data/task-a/brief.md" >/dev/null || fail "brief did not embed FM_HOME state path"

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
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FIRSTMATE_SCOPE='feature design and implementation for alpha beta gamma' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta gamma)
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report subhome"
  [ -f "$subhome/.fm-sub-firstmate-home" ] || fail "seed did not mark subhome as seeded"
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
  grep -F -- '- design - feature design and implementation for alpha beta gamma' "$home/data/firstmates.md" >/dev/null || fail "registry line was not written"
  grep -F 'scope: feature design and implementation for alpha beta gamma' "$home/data/firstmates.md" >/dev/null || fail "registry line did not record scope"
  grep -F 'projects: alpha, beta, gamma' "$home/data/firstmates.md" >/dev/null || fail "registry line did not record project clone list"
  grep -F 'owns:' "$home/data/firstmates.md" >/dev/null && fail "registry line still used owns field"

  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed"

  FM_HOME="$home" FM_FIRSTMATE_SCOPE='issue triage and support for beta' "$ROOT/bin/fm-home-seed.sh" other "$otherhome" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  grep -F -- '- other - issue triage and support for beta' "$home/data/firstmates.md" >/dev/null || fail "overlapping registry line was not written"
  grep -F 'projects: beta' "$home/data/firstmates.md" >/dev/null || fail "overlapping project clone list was not recorded"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping projects"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "firstmates registry records scopes and allows overlapping project clone lists"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/firstmates.md" <<EOF
- design - design domain (home: $subhome_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two sub-firstmates with the same home"
  fi
  grep -F 'duplicate sub-firstmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
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
  cat > "$home/data/firstmates.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested sub-firstmate homes"
  fi
  grep -F 'overlapping sub-firstmate home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_treehouse_acquired_home() {
  local home acquired acquired_abs fakebin log out
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/tmux.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FIRSTMATE_SCOPE='dash acquired scope' "$ROOT/bin/fm-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'treehouse get' "$log" >/dev/null || fail "seed did not ask treehouse for a home"
  [ -f "$acquired/.fm-sub-firstmate-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.fm-sub-firstmate-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/firstmates.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding accepts treehouse-acquired dash homes"
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
  printf 'other\n' > "$acquired/.fm-sub-firstmate-home"
  fakebin=$(make_fake_tmux "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FIRSTMATE_SCOPE='dash acquired scope' "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another sub-firstmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "treehouse return --force $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not return the home through treehouse"
  if [ -f "$home/data/firstmates.md" ] && grep -F -- '- dash ' "$home/data/firstmates.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding returns rejected acquired homes through treehouse"
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
  grep -F 'sub-firstmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "treehouse return --force" "$log" >/dev/null \
    && fail "seed returned an unsafe acquired active home through treehouse"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$descendant" FM_FAKE_TMUX_LOG="$log" \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active firstmate home"
  fi
  grep -F 'sub-firstmate home cannot be inside the active firstmate home' "$err" >/dev/null \
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

  if FM_HOME="$home" FM_FIRSTMATE_SCOPE='rollback scope' "$ROOT/bin/fm-home-seed.sh" rollback "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$subhome" ] || fail "failed seed left the newly created sub-firstmate home behind"
  [ ! -e "$subhome/.fm-sub-firstmate-home" ] || fail "failed seed left a subhome marker"
  [ ! -e "$subhome/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/firstmates.md" ] && grep -F -- '- rollback ' "$home/data/firstmates.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
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
    fail "seed allowed a local-only project into a sub-firstmate home"
  fi
  grep -F 'project alpha is local-only; sub-firstmate routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_descendant root_clone root_descendant
  home="$TMP_ROOT/active-seed-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  add_file_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home to reuse active FM_HOME"
  fi
  grep -F 'sub-firstmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home inside active FM_HOME"
  fi
  grep -F 'sub-firstmate home cannot be inside the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active FM_HOME before descendant rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home to reuse FM_ROOT"
  fi
  grep -F 'sub-firstmate home cannot be the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/fm-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home inside FM_ROOT"
  fi
  grep -F 'sub-firstmate home cannot be inside the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside FM_ROOT before descendant rejection"
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
  printf 'other\n' > "$subhome/.fm-sub-firstmate-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for marked-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another sub-firstmate"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$subhome/.fm-sub-firstmate-home")" = "other" ] || fail "seed overwrote another sub-firstmate marker"
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
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/firstmates.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another sub-firstmate"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.fm-sub-firstmate-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
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
  cat > "$home/data/firstmates.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered sub-firstmate home"
  fi
  grep -F 'overlaps registered sub-firstmate home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered sub-firstmate home"
  fi
  grep -F 'overlaps registered sub-firstmate home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.fm-sub-firstmate-home" ] || fail "seed marked a home containing a registered home"
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
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for no-origin seed test"

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
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for wrong-origin seed test"

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
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for relative origin seed test"

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
    FM_HOME="$home" FM_FIRSTMATE_SCOPE='existing init rollback scope' "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha beta >/dev/null 2>"$err"; then
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
    FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
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
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for symlink destination seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed followed a subhome projects symlink outside the subhome"
  fi
  grep -F 'sub-firstmate projects directory must resolve inside the sub-firstmate home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$subhome/.fm-sub-firstmate-home" ] || fail "seed marked subhome after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the subhome"
}

test_firstmate_spawn_records_home_meta() {
  local home subhome subhome_abs fakebin log meta
  home="$TMP_ROOT/spawn-home"
  subhome="$TMP_ROOT/spawn-subhome"
  mkdir -p "$home/data/spawn-sub" "$home/state" "$subhome/data"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf 'spawn-sub\n' > "$subhome/.fm-sub-firstmate-home"
  printf '%s\n' '- spawn-sub - spawn domain (home: '"$subhome"'; scope: spawn domain; projects: alpha, beta; added 2026-06-22)' > "$home/data/firstmates.md"
  printf 'stale parent charter\n' > "$home/data/spawn-sub/brief.md"
  printf 'current persistent charter\n' > "$subhome/data/charter.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-fake")
  log="$TMP_ROOT/spawn-fake/tmux.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/parent-config" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" spawn-sub "$subhome" codex --firstmate >/dev/null \
    || fail "firstmate spawn failed"

  meta="$home/state/spawn-sub.meta"
  grep -Fx 'kind=firstmate' "$meta" >/dev/null || fail "meta did not record kind=firstmate"
  grep -Fx "home=$subhome_abs" "$meta" >/dev/null || fail "meta did not record subhome"
  grep -Fx 'projects=alpha, beta' "$meta" >/dev/null || fail "meta did not record project clone list"
  grep -F 'treehouse get' "$log" >/dev/null && fail "firstmate spawn should not run project treehouse get"
  grep -F "FM_HOME='$subhome_abs'" "$log" >/dev/null || fail "firstmate launch did not set FM_HOME to subhome"
  grep -F 'FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE=' "$log" >/dev/null || fail "firstmate launch did not clear operational overrides"
  grep -F 'FM_CONFIG_OVERRIDE=' "$log" >/dev/null || fail "firstmate launch did not clear config override"
  grep -F "$subhome_abs/data/charter.md" "$log" >/dev/null || fail "firstmate launch did not use persistent charter"
  grep -F "$home/data/spawn-sub/brief.md" "$log" >/dev/null && fail "firstmate launch used stale parent brief"
  grep -F 'notify=' "$log" >/dev/null && fail "firstmate codex launch should not install parent turn-end notify"
  grep -F 'turn-ended' "$log" >/dev/null && fail "firstmate launch should not reference parent turn-end marker"
  pass "kind=firstmate spawn launches in the home and records routing meta"
}

test_firstmate_spawn_requires_seeded_matching_home() {
  local home subhome wronghome active_descendant fakeroot root_descendant fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  active_descendant="$home/data/spawn-descendant-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/fm-guard.sh"
  fakebin=$(make_fake_tmux "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/tmux.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$subhome" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded sub-firstmate home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before seed marker validation"

  : > "$log"
  printf 'other\n' > "$wronghome/.fm-sub-firstmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$wronghome" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted a home marked for another sub-firstmate"
  fi
  grep -F 'marked for sub-firstmate other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before marker mismatch validation"

  : > "$log"
  printf 'domain\n' > "$home/.fm-sub-firstmate-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$home" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted the active home"
  fi
  grep -F 'sub-firstmate home cannot be the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before active-home validation"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$ROOT" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted the firstmate repo root"
  fi
  grep -F 'sub-firstmate home cannot be the firstmate repo' "$err" >/dev/null || fail "spawn did not reject firstmate repo root"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before root validation"

  : > "$log"
  printf 'domain\n' > "$active_descendant/.fm-sub-firstmate-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$active_descendant" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted a home inside the active firstmate home"
  fi
  grep -F 'sub-firstmate home cannot be inside the active firstmate home' "$err" >/dev/null || fail "spawn did not reject active home descendant"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before active descendant validation"

  : > "$log"
  printf 'domain\n' > "$root_descendant/.fm-sub-firstmate-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" domain "$root_descendant" codex --firstmate >/dev/null 2>"$err"; then
    fail "firstmate spawn accepted a home inside the firstmate repo"
  fi
  grep -F 'sub-firstmate home cannot be inside the firstmate repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"
  grep -F 'new-window' "$log" >/dev/null && fail "spawn created a window before repo descendant validation"

  pass "firstmate spawn validates homes before launch"
}

test_fm_send_resolves_bare_firstmate_window_from_home_meta() {
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  cat > "$home/state/domain.meta" <<EOF
window=current-session:fm-domain
kind=firstmate
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
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf 'recover-sub\n' > "$subhome/.fm-sub-firstmate-home"
  printf 'charter\n' > "$subhome/data/charter.md"
  printf '%s\n' '- recover-sub - recovery domain (home: '"$subhome"'; scope: recovery domain; projects: gamma; added 2026-06-22)' > "$home/data/firstmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/recovery-fake")

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/recovery-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/recovery-fake/pane.txt" \
    "$ROOT/bin/fm-spawn.sh" recover-sub "echo relaunch" --firstmate >/dev/null 2>/dev/null \
    || fail "recovery firstmate respawn failed"

  meta="$home/state/recover-sub.meta"
  grep -Fx "home=$subhome_abs" "$meta" >/dev/null || fail "respawn did not preserve persistent home from meta/registry"
  grep -Fx 'window=firstmate:fm-recover-sub' "$meta" >/dev/null || fail "respawn did not reconstruct the direct report window"
  pass "restart recovery can respawn a sub-firstmate from durable registry and charter"
}

test_firstmate_teardown_retires_empty_home() {
  local home subhome fakebin
  home="$TMP_ROOT/teardown-home"
  subhome="$TMP_ROOT/teardown-subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/teardown-fake")
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/teardown-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for empty sub-firstmate home"
  [ ! -d "$subhome" ] || fail "teardown did not remove the retired sub-firstmate home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/firstmates.md" >/dev/null && fail "teardown did not remove firstmate registry route"
  pass "firstmate teardown retires empty homes and releases routing"
}

test_firstmate_force_teardown_discards_child_work() {
  local home subhome childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  subhome="$TMP_ROOT/force-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  make_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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
    fail "teardown allowed a sub-firstmate with in-flight child work"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$subhome" ] || fail "force teardown did not remove the retired sub-firstmate home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/firstmates.md" >/dev/null && fail "force teardown did not remove firstmate registry route"
  grep -F 'kill-window -t firstmate:fm-child' "$log" >/dev/null || fail "force teardown did not kill child window"
  grep -F 'kill-window -t firstmate:fm-domain' "$log" >/dev/null || fail "force teardown did not kill parent window"
  pass "firstmate force teardown discards child work"
}

test_firstmate_teardown_requires_seed_marker() {
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
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/unmarked-teardown-fake")
  log="$TMP_ROOT/unmarked-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/unmarked-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed an unmarked firstmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed unmarked subhome after refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before seed marker validation"
  grep -F 'not a seeded sub-firstmate home' "$err" >/dev/null || fail "teardown did not explain missing seed marker"
  pass "firstmate teardown requires seeded home marker"
}

test_firstmate_teardown_refuses_registered_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  subhome="$TMP_ROOT/nested-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  printf 'nested\n' > "$nested/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
window=firstmate:fm-nested
worktree=$nested
project=$nested
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/firstmates.md" <<EOF
- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain (home: $nested; scope: nested domain; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/tmux.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered sub-firstmate home"
  fi
  [ -d "$subhome" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-window' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered sub-firstmate home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "firstmate teardown refuses homes containing registered nested homes"
}

test_firstmate_force_teardown_prevalidates_before_child_cleanup() {
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
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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
  grep -F 'not a seeded sub-firstmate home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates subhome before child cleanup"
}

test_firstmate_force_teardown_refuses_child_active_home_descendant() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  subhome="$TMP_ROOT/child-active-descendant-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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

test_firstmate_force_teardown_refuses_child_repo_descendant() {
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
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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

test_firstmate_force_teardown_refuses_unregistered_child_worktree() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  subhome="$TMP_ROOT/unregistered-child-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  printf 'domain\n' > "$subhome/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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

test_firstmate_teardown_refuses_home_ancestor() {
  local danger home fakebin err
  danger="$TMP_ROOT/ancestor-teardown"
  home="$danger/main-home"
  err="$TMP_ROOT/ancestor-teardown.err"
  mkdir -p "$home/state" "$home/data" "$danger/state"
  printf 'domain\n' > "$danger/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$danger
project=$danger
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$danger
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$danger"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/ancestor-teardown-fake")
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$TMP_ROOT/ancestor-teardown-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/ancestor-teardown-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed an ancestor of active FM_HOME"
  fi
  [ -d "$danger" ] || fail "teardown removed ancestor path after refusal"
  grep -F 'ancestor of the active firstmate home' "$err" >/dev/null || fail "teardown did not explain ancestor rejection"
  pass "firstmate teardown refuses ancestor homes"
}

test_firstmate_teardown_refuses_home_descendants() {
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
  printf 'domain\n' > "$active_descendant/.fm-sub-firstmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$active_descendant
project=$active_descendant
harness=echo
kind=firstmate
mode=firstmate
yolo=off
home=$active_descendant
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$active_descendant"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/firstmates.md"
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
  printf 'repo-domain\n' > "$root_descendant/.fm-sub-firstmate-home"
  cat > "$home/state/repo-domain.meta" <<EOF
window=firstmate:fm-repo-domain
worktree=$root_descendant
project=$root_descendant
harness=echo
kind=firstmate
mode=firstmate
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
  pass "firstmate teardown refuses descendant homes"
}

test_firstmate_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="firstmate:fm-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=firstmate
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
    grep -F "stale: $window" "$out" >/dev/null && fail "idle sub-firstmate pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle sub-firstmate"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle sub-firstmate pane triggered stale wake"
  pass "idle kind=firstmate pane is healthy and not stale"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_home_seed_registry_scope_and_overlapping_projects
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_treehouse_acquired_home
test_home_seed_returns_treehouse_acquired_home_on_assignment_failure
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_local_only_project
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_firstmate_spawn_records_home_meta
test_firstmate_spawn_requires_seeded_matching_home
test_fm_send_resolves_bare_firstmate_window_from_home_meta
test_recovery_respawn_uses_persistent_home
test_firstmate_teardown_retires_empty_home
test_firstmate_force_teardown_discards_child_work
test_firstmate_teardown_requires_seed_marker
test_firstmate_teardown_refuses_registered_nested_home
test_firstmate_force_teardown_prevalidates_before_child_cleanup
test_firstmate_force_teardown_refuses_child_active_home_descendant
test_firstmate_force_teardown_refuses_child_repo_descendant
test_firstmate_force_teardown_refuses_unregistered_child_worktree
test_firstmate_teardown_refuses_home_ancestor
test_firstmate_teardown_refuses_home_descendants
test_firstmate_idle_pane_is_not_stale
