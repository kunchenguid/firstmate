#!/usr/bin/env bash
# Behavior tests for the project-local home model: the bin/firstmate launcher,
# config/projects-root resolution, discovery-is-not-authority, and org-shaped
# secondmate seeding (docs/configuration.md "Project-local homes").
#
# Pinned contracts:
#   - launcher home resolution: explicit FM_HOME wins over a nearer
#     .firstmate/ ancestor; a nested .firstmate/ shadows an outer org home;
#     --global and a cwd outside any git repo fall back to $HOME/.firstmate
#     (or the install root when that is absent); a cwd inside a git repo with
#     no .firstmate/ ancestor refuses to guess. The harness execs from the
#     install root with FM_LAUNCH_DIR recording the caller's directory.
#   - `firstmate init`: --org scaffolds .firstmate/ at the cwd with
#     config/projects-root=.. and no projects/ dir; without --org it scaffolds
#     at the enclosing repo's root and registers the repo itself.
#   - projects root precedence: FM_PROJECTS_OVERRIDE > config/projects-root >
#     $FM_HOME/projects; a malformed config/projects-root fails loudly.
#   - discovery is not authority: fm-projects.sh discover lists every sibling
#     repo, but a whole-fleet refresh touches only registered aliases.
#   - central resolver precedence: data/project-paths.json, then
#     <projects-root>/<alias>, then $FM_HOME/projects/<alias>; projects/<name>
#     prefers the legacy clone.
#   - org-shaped secondmate seed registers siblings instead of cloning them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-project-local-tests)

new_dir() {
  mktemp -d "$TMP_ROOT/case.XXXXXX"
}

# make_fake_harness <dir>: drop a `claude` stub that records FM_HOME,
# FM_LAUNCH_DIR, and its cwd, then exits. Echoes the fakebin dir.
make_fake_harness() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/claude" <<'SH'
#!/usr/bin/env bash
printf 'FM_HOME=%s\nFM_LAUNCH_DIR=%s\nPWD=%s\n' "$FM_HOME" "$FM_LAUNCH_DIR" "$(pwd -P)" > "$FM_FAKE_HARNESS_OUT"
SH
  chmod +x "$dir/claude"
  printf '%s\n' "$dir"
}

run_launcher() { # <cwd> [env-assignments...] -- [args...]
  local cwd=$1
  shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  (cd "$cwd" && env -u FM_HOME "${envs[@]}" "$ROOT/bin/firstmate" "$@")
}

# --- launcher home resolution ------------------------------------------------

test_launcher_resolution() {
  local base org nested fakebin
  base=$(new_dir)
  org="$base/org"
  nested="$org/team/repo"
  mkdir -p "$org/.firstmate" "$nested/.firstmate" "$nested/sub/dir"
  fakebin=$(make_fake_harness "$base/fakebin")

  # Nearest .firstmate/ ancestor wins from a deep cwd.
  (cd "$nested/sub/dir" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out1" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$nested/.firstmate" "$base/out1" "nested .firstmate did not shadow the org home"
  assert_grep "FM_LAUNCH_DIR=$nested/sub/dir" "$base/out1" "FM_LAUNCH_DIR did not record the caller cwd"
  assert_grep "PWD=$ROOT" "$base/out1" "harness did not exec from the install root"

  # Explicit FM_HOME beats the nearest ancestor.
  local explicit="$base/explicit-home"
  mkdir -p "$explicit"
  (cd "$nested" && env \
    FM_HOME="$explicit" FM_FAKE_HARNESS_OUT="$base/out2" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$explicit" "$base/out2" "explicit FM_HOME did not win over .firstmate ancestor"

  # --global falls back to $HOME/.firstmate even under an org home.
  local fakehome="$base/fakehome"
  mkdir -p "$fakehome/.firstmate"
  (cd "$nested" && env -u FM_HOME HOME="$fakehome" \
    FM_FAKE_HARNESS_OUT="$base/out3" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --global)
  assert_grep "FM_HOME=$fakehome/.firstmate" "$base/out3" "--global did not resolve the global home"

  # Outside any git repo with no $HOME/.firstmate, the install root is the home.
  local bare="$base/bare" barehome="$base/barehome"
  mkdir -p "$bare" "$barehome"
  (cd "$bare" && env -u FM_HOME HOME="$barehome" \
    FM_FAKE_HARNESS_OUT="$base/out4" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$ROOT" "$base/out4" "outside-git fallback did not resolve the install root"

  # Inside a git repo with no .firstmate/ ancestor: refuse to guess.
  local repo="$base/lonely-repo"
  fm_git_init_commit "$repo"
  if (cd "$repo/sub" 2>/dev/null || mkdir -p "$repo/sub" && cd "$repo/sub" && env -u FM_HOME HOME="$barehome" \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err"); then
    fail "in-repo launch without .firstmate did not refuse"
  fi
  assert_grep "firstmate init" "$base/err" "refusal did not name firstmate init"

  pass "launcher: FM_HOME win, nested shadowing, global+install fallback, in-repo refusal"
}

# --- firstmate init ----------------------------------------------------------

test_init() {
  local base org repo
  base=$(new_dir)

  # --org at an org root.
  org="$base/org"
  mkdir -p "$org"
  (cd "$org" && "$ROOT/bin/firstmate" init --org >/dev/null) || fail "init --org failed"
  assert_present "$org/.firstmate/config/projects-root" "init --org wrote no projects-root"
  assert_equals ".." "$(cat "$org/.firstmate/config/projects-root")" "org projects-root is not .."
  assert_present "$org/.firstmate/.tasks.toml" "init --org wrote no .tasks.toml"
  assert_present "$org/.firstmate/.gitignore" "init --org wrote no .gitignore"
  assert_absent "$org/.firstmate/projects" "org home must not create projects/"
  assert_absent "$org/.firstmate/data/projects.md" "org home must not pre-register siblings"

  # Per-project init inside a repo registers the repo itself.
  repo="$base/standalone"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/deep/dir"
  (cd "$repo/deep/dir" && "$ROOT/bin/firstmate" init >/dev/null) || fail "per-project init failed"
  assert_present "$repo/.firstmate/config/projects-root" "per-project init wrote no projects-root"
  assert_absent "$repo/deep/dir/.firstmate" "per-project init did not land at the repo root"
  assert_grep "- standalone " "$repo/.firstmate/data/projects.md" "per-project init did not register the repo"
  if grep -qF "/.firstmate/" "$repo/.git/info/exclude" 2>/dev/null; then
    fail "init excluded .firstmate/ wholesale, hiding whitelisted config"
  fi
  [ -z "$(git -C "$repo" status --porcelain)" ] \
    || fail "init left the repository dirty"
  printf '!config/crew-harness\n' >> "$repo/.firstmate/.gitignore"
  printf 'claude\n' > "$repo/.firstmate/config/crew-harness"
  printf 'x\n' > "$repo/.firstmate/config/private-item"
  git -C "$repo" check-ignore -q .firstmate/config/crew-harness \
    && fail "whitelisted config item is still ignored"
  git -C "$repo" check-ignore -q .firstmate/config/private-item \
    || fail "non-whitelisted config item is not ignored"
  # The self-registered alias resolves to the repo itself.
  assert_equals "$(cd "$repo" && pwd -P)" "$(FM_HOME="$repo/.firstmate" "$ROOT/bin/fm-projects.sh" resolve standalone)" \
    "per-project init alias did not resolve to the repo"

  # init outside a repo and without --org refuses.
  local nowhere="$base/nowhere"
  mkdir -p "$nowhere"
  if (cd "$nowhere" && "$ROOT/bin/firstmate" init >/dev/null 2>&1); then
    fail "init outside a repo did not refuse"
  fi

  pass "init: org scaffold, per-project registration, repo-root landing, outside-repo refusal"
}

# --- projects-root resolution and validation ---------------------------------

test_projects_root() {
  local base home
  base=$(new_dir)
  home="$base/home"
  mkdir -p "$home/config" "$home/data" "$home/projects"

  # shellcheck source=bin/fm-projects-lib.sh
  . "$ROOT/bin/fm-projects-lib.sh"

  # Legacy default.
  assert_equals "$home/projects" "$(fm_projects_root "$home" "$home/config")" "default root is not home/projects"

  # config/projects-root, relative resolves against the home.
  printf '..\n' > "$home/config/projects-root"
  assert_equals "$(cd "$home/.." && pwd -P)" "$(fm_projects_root "$home" "$home/config")" "relative projects-root did not resolve against home"
  printf '%s\n' "$base/abs-root" > "$home/config/projects-root"
  assert_equals "$base/abs-root" "$(fm_projects_root "$home" "$home/config")" "absolute projects-root not honored"

  # FM_PROJECTS_OVERRIDE wins over config.
  assert_equals "$base/override" "$(FM_PROJECTS_OVERRIDE="$base/override" fm_projects_root "$home" "$home/config")" "FM_PROJECTS_OVERRIDE did not win"

  # Malformed files fail loudly, never fall back.
  local bad
  for bad in empty multi symlink; do
    case "$bad" in
      empty) : > "$home/config/projects-root" ;;
      multi) printf '%s\n%s\n' "$base/a" "$base/b" > "$home/config/projects-root" ;;
      symlink) rm -f "$home/config/projects-root"; ln -s "$base/abs-root" "$home/config/projects-root" ;;
    esac
    if fm_projects_root "$home" "$home/config" >/dev/null 2>&1; then
      fail "malformed projects-root ($bad) did not fail loudly"
    fi
  done
  rm -f "$home/config/projects-root"

  pass "projects-root: override > config > legacy default; malformed fails loudly"
}

# --- discovery is not authority ----------------------------------------------

test_discovery_authority() {
  local base org home reg unreg
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"

  # Two sibling repos; only `reg` is registered.
  reg="$org/reg"
  unreg="$org/unreg"
  fm_git_init_commit "$reg"
  fm_git_init_commit "$unreg"
  fm_git_add_origin "$reg" "$base/remotes/reg.git"
  fm_git_add_origin "$unreg" "$base/remotes/unreg.git"
  printf -- '- reg [direct-PR] - registered sibling (added 2026-09-17)\n' > "$home/data/projects.md"
  # A non-repo sibling must not be discoverable.
  mkdir -p "$org/plain-dir"

  # discover lists both repos and skips the plain dir.
  local found
  found=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" discover | sort | tr '\n' ' ')
  assert_contains "$found" "reg" "discover missed the registered sibling"
  assert_contains "$found" "unreg" "discover missed the unregistered sibling"
  case "$found" in *plain-dir*) fail "discover listed a non-repo sibling" ;; esac

  # Resolver precedence: manifest > sibling > legacy clone.
  local outside="$base/outside-proj"
  fm_git_init_commit "$outside"
  printf '{ "ext": "%s" }\n' "$outside" > "$home/data/project-paths.json"
  assert_equals "$outside" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext)" "manifest alias did not resolve"
  assert_equals "$org/reg" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve reg)" "sibling alias did not resolve"
  mkdir -p "$home/projects/legacy"
  assert_equals "$home/projects/legacy" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve legacy)" "legacy clone did not resolve"
  # projects/<name> prefers the legacy clone over a same-named sibling.
  mkdir -p "$home/projects/reg"
  assert_equals "$home/projects/reg" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve projects/reg)" "projects/<name> did not prefer the legacy clone"
  rmdir "$home/projects/reg"
  # An unresolvable bare name passes through unchanged.
  assert_equals "ghost" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ghost)" "unresolvable alias did not pass through"

  # Whole-fleet refresh touches only the registered sibling: advance both
  # origins, then sync. reg fast-forwards; unreg is never fetched.
  local reg_head unreg_head
  commit_file() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$4"; }
  # Advance via a work repo wired to each origin.
  local w="$base/work"
  git clone --quiet "file://$(cd "$base/remotes/reg.git" && pwd)" "$w-reg" 2>/dev/null || {
    git clone --quiet "$base/remotes/reg.git" "$w-reg"; }
  commit_file "$w-reg" f.txt v1 C1
  git -C "$w-reg" push -q origin HEAD:main 2>/dev/null || git -C "$w-reg" push -q origin HEAD:master
  git clone --quiet "$base/remotes/unreg.git" "$w-unreg"
  commit_file "$w-unreg" f.txt v1 C1
  git -C "$w-unreg" push -q origin HEAD:main 2>/dev/null || git -C "$w-unreg" push -q origin HEAD:master

  # A local branch whose upstream is gone must survive an org-home refresh.
  git -C "$reg" fetch -q origin
  git -C "$reg" branch -q keepme
  git -C "$reg" config branch.keepme.remote origin
  git -C "$reg" config branch.keepme.merge refs/heads/vanished
  reg_head=$(git -C "$reg" rev-parse HEAD)
  unreg_head=$(git -C "$unreg" rev-parse HEAD)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" >/dev/null 2>&1 \
    || fail "fleet sync failed in org home"
  [ "$(git -C "$reg" rev-parse HEAD)" != "$reg_head" ] || fail "registered sibling was not fast-forwarded"
  [ "$(git -C "$unreg" rev-parse HEAD)" = "$unreg_head" ] || fail "unregistered sibling was fetched - discovery leaked into authority"
  git -C "$reg" show-ref --verify --quiet refs/heads/keepme \
    || fail "org-home refresh pruned a user branch"

  # A user feature branch is skipped, never re-attached or reported STUCK.
  git -C "$reg" checkout -q -b feature
  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_contains "$out" "reg: skipped: on branch feature" "org-home refresh did not skip a feature branch"
  case "$out" in *STUCK*) fail "org-home refresh reported a user branch as STUCK" ;; esac
  [ "$(git -C "$reg" symbolic-ref --short HEAD)" = feature ] || fail "org-home refresh moved the user's branch"

  # A registered alias that resolves nowhere is skipped, not treated as a cwd path.
  printf -- '- docs [direct-PR] - missing (added 2026-09-17)\n' >> "$home/data/projects.md"
  local cands
  cands=$(cd "$ROOT" && FM_HOME="$home" bash -c '. bin/fm-projects-lib.sh; fm_project_sync_candidates "$FM_HOME" "$FM_HOME/config" "$FM_HOME/data"' 2>/dev/null)
  case "$cands" in *docs*) fail "unresolved registered alias leaked into sync candidates" ;; esac

  pass "discovery=authority: discover lists siblings, refresh touches registered only, resolver precedence"
}

# --- org-shaped secondmate seed ----------------------------------------------

test_org_seed() {
  local base parent org child
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$org/.firstmate-mate"
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$org"

  # Parent registers alpha (sibling of the org root the child will share).
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  printf -- '- alpha [direct-PR] - alpha project (added 2026-09-17)\n' > "$parent/data/projects.md"

  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha \
    || fail "charter scaffold failed"

  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
    --projects-root "$org" >/dev/null || fail "org seed failed"

  assert_equals "$org" "$(cat "$child/config/projects-root")" "child projects-root not recorded"
  assert_absent "$child/projects" "org seed created a projects/ dir"
  assert_grep "- alpha " "$child/data/projects.md" "sibling was not registered in the child"
  assert_absent "$child/projects/alpha" "org seed cloned instead of registering"
  # The sibling itself was never mutated by the seed.
  assert_absent "$org/alpha/.no-mistakes-init" "org seed initialized a sibling in place"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "registry validation failed after org seed"

  # A named project that is not a sibling under the root fails loudly.
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate2 "$base/child2" ghost \
      --projects-root "$org" >/dev/null 2>&1; then
    fail "org seed accepted a non-sibling project"
  fi
  assert_absent "$base/child2" "failed org seed left a home behind"

  pass "org seed: siblings registered not cloned, projects-root recorded, non-sibling refused"
}

test_launcher_resolution
test_init
test_projects_root
test_discovery_authority
test_org_seed

printf 'all project-local tests passed\n'
