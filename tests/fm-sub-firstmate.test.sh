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
  add_file_origin "$home/projects/gamma" "$TMP_ROOT/remotes/gamma.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR +yolo] - alpha project (added 2026-06-22)
- beta [local-only] - beta project (added 2026-06-22)
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
  git -C "$subhome/projects/beta" remote get-url origin >/dev/null 2>&1 && fail "local-only beta kept an origin remote"
  [ -f "$subhome/projects/gamma/.no-mistakes-init" ] || fail "no-mistakes project was not initialized"
  [ -f "$subhome/projects/gamma/.no-mistakes-doctor" ] || fail "no-mistakes project was not checked"
  out=$(FM_HOME="$subhome" "$ROOT/bin/fm-project-mode.sh" alpha)
  [ "$out" = "direct-PR on" ] || fail "seed did not preserve alpha delivery mode in subhome registry"
  out=$(FM_HOME="$subhome" "$ROOT/bin/fm-project-mode.sh" beta)
  [ "$out" = "local-only off" ] || fail "seed did not preserve beta delivery mode in subhome registry"
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

test_home_seed_refuses_active_home_and_root() {
  local home err
  home="$TMP_ROOT/active-seed-home"
  err="$TMP_ROOT/active-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home to reuse active FM_HOME"
  fi
  grep -F 'sub-firstmate home cannot be the active firstmate home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sub-firstmate home to reuse FM_ROOT"
  fi
  grep -F 'sub-firstmate home cannot be the firstmate repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home subhome err
  home="$TMP_ROOT/marked-seed-home"
  subhome="$TMP_ROOT/marked-seed-subhome"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  make_git_project "$home/projects/alpha"
  git clone --quiet "$ROOT" "$subhome"
  printf 'other\n' > "$subhome/.fm-sub-firstmate-home"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
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
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/firstmates.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" design --firstmate alpha >/dev/null || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another sub-firstmate"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.fm-sub-firstmate-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
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
  local home subhome wronghome fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data"
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

test_fm_peek_resolves_bare_firstmate_window_from_home_meta() {
  local home fakebin log err out
  home="$TMP_ROOT/peek-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  cat > "$home/state/domain.meta" <<EOF
window=current-session:fm-domain
kind=firstmate
EOF
  fakebin=$(make_fake_tmux "$TMP_ROOT/peek-fake")
  log="$TMP_ROOT/peek-fake/tmux.log"
  err="$TMP_ROOT/peek-fake/peek.err"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-domain" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/peek-fake/pane.txt" \
    "$ROOT/bin/fm-peek.sh" fm-domain 10 2>"$err") \
    || fail "fm-peek failed for a bare firstmate window with home metadata"
  [ "$out" = "idle prompt" ] || fail "fm-peek did not print the captured pane"
  grep -F 'capture-pane -p -t current-session:fm-domain -S -10' "$log" >/dev/null \
    || fail "fm-peek did not use the window recorded in this home's meta"
  grep -F 'capture-pane -p -t other-session:fm-domain' "$log" >/dev/null \
    && fail "fm-peek targeted a foreign window with the same bare name"

  : > "$log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/peek-fake/pane.txt" \
    "$ROOT/bin/fm-peek.sh" fm-missing >/dev/null 2>"$err"; then
    fail "fm-peek inspected a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-peek did not explain missing home metadata"
  grep -F 'capture-pane -p -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-peek fell back to a foreign same-name window"

  pass "fm-peek resolves bare firstmate windows through this home"
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

test_watcher_ignores_foreign_tmux_windows() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-foreign-home"
  mkdir -p "$home/state"
  window="firstmate:fm-sub-child"
  fakebin=$(make_fake_tmux "$TMP_ROOT/watch-foreign-fake")
  out="$TMP_ROOT/watch-foreign-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_LOG="$TMP_ROOT/watch-foreign-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/watch-foreign-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "foreign tmux window triggered stale wake"
    fail "watcher exited unexpectedly while foreign window was present"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "foreign tmux window triggered stale wake"
  pass "watcher ignores fm windows not recorded in this home"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_home_seed_registry_scope_and_overlapping_projects
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_firstmate_spawn_records_home_meta
test_firstmate_spawn_requires_seeded_matching_home
test_fm_send_resolves_bare_firstmate_window_from_home_meta
test_fm_peek_resolves_bare_firstmate_window_from_home_meta
test_recovery_respawn_uses_persistent_home
test_firstmate_teardown_retires_empty_home
test_firstmate_force_teardown_discards_child_work
test_firstmate_teardown_requires_seed_marker
test_firstmate_force_teardown_prevalidates_before_child_cleanup
test_firstmate_teardown_refuses_home_ancestor
test_firstmate_idle_pane_is_not_stale
test_watcher_ignores_foreign_tmux_windows
