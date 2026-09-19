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
#     Session-start digest priming of that launch directory (LAUNCH CONTEXT)
#     lives in tests/fm-session-start.test.sh.
#     Ancestor-discovered homes must carry the init-written .fm-home trust
#     marker; config/primary-harness accepts only verified primary adapters;
#     a relative FM_HOME is canonicalized before export.
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
#   - a bare-name refresh argument keeps its registry alias as the label, so a
#     manifest-registered project outside the projects root still resolves its
#     registered posture (local-only is skipped, not fetched).
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

# make_jqless_path <dir>: a PATH directory holding the tools the project
# scripts use, minus jq, so the manifest reader's jq-less fallback runs.
make_jqless_path() {
  local dir=$1 tool path
  mkdir -p "$dir"
  for tool in env bash awk sed grep cat cut sort tr wc head tail basename dirname \
      mktemp rm mkdir ls find git uname expr; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$path" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# --- launcher home resolution ------------------------------------------------

test_launcher_resolution() {
  local base org nested fakebin
  base=$(new_dir)
  org="$base/org"
  nested="$org/team/repo"
  mkdir -p "$org/.firstmate" "$nested/.firstmate" "$nested/sub/dir"
  # Ancestor-discovered homes must carry the init-written trust marker.
  : > "$org/.firstmate/.fm-home"
  : > "$nested/.firstmate/.fm-home"
  fakebin=$(make_fake_harness "$base/fakebin")

  # Nearest .firstmate/ ancestor wins from a deep cwd.
  (cd "$nested/sub/dir" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out1" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$nested/.firstmate" "$base/out1" "nested .firstmate did not shadow the org home"
  assert_grep "FM_LAUNCH_DIR=$nested/sub/dir" "$base/out1" "FM_LAUNCH_DIR did not record the caller cwd"
  assert_grep "PWD=$ROOT" "$base/out1" "harness did not exec from the install root"

  # The documented install is a symlink on PATH: the launcher must still find
  # its own install root, not the symlink's directory.
  local linkbin="$base/linkbin"
  mkdir -p "$linkbin"
  ln -s "$ROOT/bin/firstmate" "$linkbin/firstmate"
  (cd "$nested/sub/dir" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out-link" PATH="$linkbin:$fakebin:$PATH" firstmate) \
    || fail "launcher invoked through a PATH symlink failed"
  assert_grep "PWD=$ROOT" "$base/out-link" "symlinked launcher did not exec from the install root"
  assert_grep "FM_HOME=$nested/.firstmate" "$base/out-link" "symlinked launcher resolved the wrong home"

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
  mkdir -p "$repo/sub"
  if (cd "$repo/sub" && env -u FM_HOME HOME="$barehome" \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err"); then
    fail "in-repo launch without .firstmate did not refuse"
  fi
  assert_grep "firstmate init" "$base/err" "refusal did not name firstmate init"

  # A cwd under $HOME never finds $HOME/.firstmate as an ancestor: an unmarked
  # global home still serves a non-repo cwd, and a repo under $HOME without
  # its own .firstmate/ still refuses to guess.
  local underhome="$base/underhome"
  mkdir -p "$underhome/.firstmate" "$underhome/plain/dir"
  fm_git_init_commit "$underhome/work/repo"
  (cd "$underhome/plain/dir" && env -u FM_HOME HOME="$underhome"     FM_FAKE_HARNESS_OUT="$base/out5" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")     || fail "cwd under HOME did not resolve the unmarked global home"
  assert_grep "FM_HOME=$underhome/.firstmate" "$base/out5" "cwd under HOME did not resolve the global home"
  if (cd "$underhome/work/repo" && env -u FM_HOME HOME="$underhome"       PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err5"); then
    fail "repo under HOME resolved the global home as an ancestor"
  fi
  assert_grep "firstmate init" "$base/err5" "repo under HOME did not refuse to guess"
  (cd "$underhome/work/repo" && HOME="$underhome" "$ROOT/bin/firstmate" init >"$base/init5") \
    || fail "init under HOME failed"
  if grep -q "shadowing" "$base/init5"; then
    fail "init under HOME reported shadowing the global home"
  fi

  pass "launcher: FM_HOME win, nested shadowing, global+install fallback, in-repo refusal"
}

# --- home trust, adapter whitelist, FM_HOME canonicalization -----------------

test_launcher_trust() {
  local base repo fakebin
  base=$(new_dir)
  repo="$base/repo"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/.firstmate" "$repo/sub"
  fakebin=$(make_fake_harness "$base/fakebin")

  # A .firstmate/ without the init-written marker is untrusted: the launcher
  # refuses it and names how to bless it, so a committed home stays inert.
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err1"); then
    fail "unmarked .firstmate home was honored"
  fi
  assert_grep "untrusted" "$base/err1" "refusal did not name the home untrusted"
  assert_grep ".fm-home" "$base/err1" "refusal did not name the blessing"

  # Blessing the marker makes the same home resolve.
  : > "$repo/.firstmate/.fm-home"
  (cd "$repo/sub" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out1" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$repo/.firstmate" "$base/out1" "marked home did not resolve"

  # A marker tracked by git arrived with a clone and does not bless the home.
  git -C "$repo" add -f .firstmate/.fm-home
  if (cd "$repo/sub" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out-tracked" \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err-tracked"); then
    fail "a git-tracked .fm-home marker blessed the home"
  fi
  assert_grep "untrusted" "$base/err-tracked" "tracked-marker refusal did not name the home untrusted"
  git -C "$repo" rm -q --cached .firstmate/.fm-home

  # A git failure while checking the marker fails closed, not open. Ownership
  # refusals are not reachable (the check passes safe.directory='*'), so the
  # stub raises the generic failure the fail-closed leg exists for.
  local failgit="$base/failgit"
  mkdir -p "$failgit"
  cat > "$failgit/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = ls-files ] && { echo "fatal: index file corrupt" >&2; exit 128; }
done
exec $(command -v git) "\$@"
SH
  chmod +x "$failgit/git"
  if (cd "$repo/sub" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out-failgit" \
      PATH="$failgit:$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err-failgit"); then
    fail "a git error while checking the marker blessed the home"
  fi
  assert_grep "untrusted" "$base/err-failgit" "git-error refusal did not name the home untrusted"

  # config/primary-harness accepts only primary-capable adapters.
  mkdir -p "$repo/.firstmate/config"
  printf 'muse\n' > "$repo/.firstmate/config/primary-harness"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err2"); then
    fail "crew-only primary-harness was accepted"
  fi
  assert_grep "not primary-capable" "$base/err2" "adapter refusal did not fail loudly"
  printf 'kimi\n' > "$repo/.firstmate/config/primary-harness"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err2k"); then
    fail "crew-scope kimi primary-harness was accepted"
  fi
  assert_grep "not primary-capable" "$base/err2k" "kimi refusal did not fail loudly"
  printf 'definitely-not-a-harness\n' > "$repo/.firstmate/config/primary-harness"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err3"); then
    fail "unknown primary-harness was accepted"
  fi
  assert_grep "not primary-capable" "$base/err3" "unknown adapter did not fail loudly"
  printf 'cla ude\n' > "$repo/.firstmate/config/primary-harness"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err3b"); then
    fail "interior-whitespace primary-harness was accepted"
  fi
  assert_grep "not primary-capable" "$base/err3b" "interior-whitespace adapter did not fail loudly"
  printf '  claude  \n' > "$repo/.firstmate/config/primary-harness"
  (cd "$repo/sub" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out3c" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate") \
    || fail "edge-whitespace primary-harness was refused"
  printf 'codex\n' > "$base/harness-target"
  rm -f "$repo/.firstmate/config/primary-harness"
  ln -s "$base/harness-target" "$repo/.firstmate/config/primary-harness"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err3d"); then
    fail "symlinked primary-harness was silently ignored"
  fi
  assert_grep "symlink" "$base/err3d" "symlinked primary-harness did not fail loudly"
  rm -f "$repo/.firstmate/config/primary-harness"
  # --harness is held to the same primary-capable set as config/primary-harness.
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --harness kimi >/dev/null 2>"$base/err3e"); then
    fail "--harness kimi was accepted"
  fi
  assert_grep "not primary-capable" "$base/err3e" "--harness kimi refusal did not fail loudly"
  if (cd "$repo/sub" && env -u FM_HOME \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --harness=muse >/dev/null 2>"$base/err3f"); then
    fail "--harness=muse was accepted"
  fi
  assert_grep "not primary-capable" "$base/err3f" "--harness=muse refusal did not fail loudly"
  # Pi-family primaries carry their own launch-boundary identity marker, so an
  # inherited FM_PI_HARNESS cannot relabel the session.
  local h
  for h in pi pi-signed omp; do
    cat > "$fakebin/$h" <<'SH'
#!/usr/bin/env bash
printf 'FM_PI_HARNESS=%s\nFM_OMP_HARNESS=%s\n' "${FM_PI_HARNESS:-}" "${FM_OMP_HARNESS:-}" > "$FM_FAKE_HARNESS_OUT"
SH
    chmod +x "$fakebin/$h"
  done
  (cd "$repo/sub" && env -u FM_HOME -u FM_PI_HARNESS FM_FAKE_HARNESS_OUT="$base/out-pisigned" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --harness pi-signed) \
    || fail "--harness pi-signed was refused"
  grep -qxF "FM_PI_HARNESS=pi-signed" "$base/out-pisigned" || fail "pi-signed primary launched without its identity marker"
  (cd "$repo/sub" && env -u FM_HOME FM_PI_HARNESS=pi-signed FM_FAKE_HARNESS_OUT="$base/out-pi" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --harness pi) \
    || fail "--harness pi was refused"
  grep -qxF "FM_PI_HARNESS=pi" "$base/out-pi" || fail "inherited FM_PI_HARNESS relabeled a pi primary"
  (cd "$repo/sub" && env -u FM_HOME -u FM_OMP_HARNESS FM_FAKE_HARNESS_OUT="$base/out-omp" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --harness omp) \
    || fail "--harness omp was refused"
  grep -qxF "FM_OMP_HARNESS=omp" "$base/out-omp" || fail "omp primary launched without its identity marker"

  # A relative FM_HOME is canonicalized before export, not resolved against
  # the install root after the launcher's cd.
  local relhome="$base/relhome"
  mkdir -p "$relhome"
  (cd "$base" && env \
    FM_HOME=relhome FM_FAKE_HARNESS_OUT="$base/out4" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate")
  assert_grep "FM_HOME=$relhome" "$base/out4" "relative FM_HOME was not canonicalized"

  pass "trust: unmarked home refused, marker blesses, adapter whitelist, relative FM_HOME canonicalized"
}

# --- firstmate init ----------------------------------------------------------

test_init() {
  local base org repo
  base=$(new_dir)

  # --org at an org root reports the siblings it can discover, and only those
  # that are their own work-tree roots.
  local org_out
  org="$base/org"
  mkdir -p "$org/plain-dir"
  fm_git_init_commit "$org/alpha"
  fm_git_init_commit "$org/beta"
  mkdir -p "$org/alpha/nested"
  org_out=$(cd "$org" && "$ROOT/bin/firstmate" init --org) || fail "init --org failed"
  assert_contains "$org_out" "discoverable sibling repos: alpha beta" \
    "init --org did not report the discoverable siblings"
  case "$org_out" in
    *plain-dir*) fail "init --org reported a non-repo sibling as discoverable" ;;
    *nested*) fail "init --org reported a nested directory as a sibling repo" ;;
  esac
  assert_contains "$org_out" "discovery is not authority" \
    "init --org dropped the discovery-is-not-authority note"
  assert_present "$org/.firstmate/config/projects-root" "init --org wrote no projects-root"
  assert_equals ".." "$(cat "$org/.firstmate/config/projects-root")" "org projects-root is not .."
  assert_present "$org/.firstmate/.tasks.toml" "init --org wrote no .tasks.toml"
  assert_present "$org/.firstmate/.fm-home" "init --org wrote no trust marker"
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

  # A same-named package directory inside the repo never shadows the repo.
  local pkgrepo="$base/pkg"
  fm_git_init_commit "$pkgrepo"
  mkdir -p "$pkgrepo/pkg"
  (cd "$pkgrepo" && "$ROOT/bin/firstmate" init >/dev/null) || fail "per-project init in pkg failed"
  assert_equals "$(cd "$pkgrepo" && pwd -P)" "$(FM_HOME="$pkgrepo/.firstmate" "$ROOT/bin/fm-projects.sh" resolve pkg)" \
    "same-named subdirectory shadowed the per-project repo"

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
  # Interior whitespace is rejected loudly, never mangled; leading/trailing
  # whitespace is trimmed.
  printf '%s\n' "$base/abs root" > "$home/config/projects-root"
  if fm_projects_root "$home" "$home/config" >/dev/null 2>&1; then
    fail "interior-whitespace projects-root did not fail loudly"
  fi
  printf '  %s  \n' "$base/abs-root" > "$home/config/projects-root"
  assert_equals "$base/abs-root" "$(fm_projects_root "$home" "$home/config")" "edge whitespace was not trimmed"
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

  # A single-argument refresh in an org home refuses unregistered siblings,
  # by bare name and by path alike; the registered sibling still syncs.
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" unreg >/dev/null 2>"$base/err-unreg"; then
    fail "single-arg refresh accepted an unregistered sibling name"
  fi
  assert_grep "not a registered project" "$base/err-unreg" "name refusal did not name registration"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$unreg" >/dev/null 2>"$base/err-unreg-path"; then
    fail "single-arg refresh accepted an unregistered sibling path"
  fi
  assert_grep "not a registered project" "$base/err-unreg-path" "path refusal did not name registration"
  git -C "$reg" checkout -q main 2>/dev/null || git -C "$reg" checkout -q master
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" reg >/dev/null 2>&1 \
    || fail "single-arg refresh refused the registered sibling"

  # A registered alias that resolves nowhere is skipped, not treated as a cwd path.
  printf -- '- docs [direct-PR] - missing (added 2026-09-17)\n' >> "$home/data/projects.md"
  local cands
  cands=$(cd "$ROOT" && FM_HOME="$home" bash -c '. bin/fm-projects-lib.sh; fm_project_sync_candidates "$FM_HOME" "$FM_HOME/config" "$FM_HOME/data"' 2>/dev/null)
  case "$cands" in *docs*) fail "unresolved registered alias leaked into sync candidates" ;; esac

  pass "discovery=authority: discover lists siblings, refresh touches registered only, resolver precedence"
}

# --- an unresolvable project argument fails closed ---------------------------

test_resolver_fails_closed() {
  local base org home reg out
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"
  reg="$org/reg"
  fm_git_init_commit "$reg"
  fm_git_add_origin "$reg" "$base/remotes/reg.git"
  printf -- '- reg [direct-PR] - registered sibling (added 2026-09-17)\n' > "$home/data/projects.md"
  # Not a flat alias -> path map: every resolution through it must fail loudly.
  printf '{"reg": ["not-a-path"]}\n' > "$home/data/project-paths.json"

  # A whole-fleet refresh must report the broken manifest, not a clean no-op.
  if out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>"$base/err-fleet"); then
    fail "whole-fleet refresh succeeded with an unreadable project manifest"
  fi
  assert_grep "flat JSON object" "$base/err-fleet" "fleet refresh did not name the broken manifest"
  case "$out" in *synced*) fail "fleet refresh reported syncs it never performed" ;; esac

  # A path argument in a manifest-only home must report the broken registry,
  # not call a registered project unregistered.
  local home2="$base/org2/.firstmate"
  mkdir -p "$home2/config" "$home2/data" "$home2/state"
  printf '..\n' > "$home2/config/projects-root"
  fm_git_init_commit "$base/org2/reg"
  printf '{"reg": ["not-a-path"]}\n' > "$home2/data/project-paths.json"
  if FM_HOME="$home2" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$base/org2/reg" \
      >/dev/null 2>"$base/err-path"; then
    fail "single-arg refresh succeeded with an unreadable project manifest"
  fi
  assert_grep "registry" "$base/err-path" "broken registry was not named"
  case "$(cat "$base/err-path")" in
    *"not a registered project"*) fail "broken manifest was reported as an unregistered project" ;;
  esac

  # An alias the manifest cannot hold must stop the spawn at resolution, not
  # fall through to the launcher's own working directory.
  local plain="$base/plain"
  mkdir -p "$plain/config" "$plain/data" "$plain/state"
  if FM_HOME="$plain" "$ROOT/bin/fm-spawn.sh" t1 'proj\name' --harness claude --mode direct-PR --yolo off \
      >/dev/null 2>"$base/err-spawn"; then
    fail "spawn accepted an alias the manifest cannot hold"
  fi
  assert_grep "manifest cannot hold" "$base/err-spawn" "spawn refusal did not name the bad alias"
  case "$(cat "$base/err-spawn")" in
    *"has no brief"*) fail "spawn resolved a bad alias to a directory and continued" ;;
  esac

  # A relative manifest value would resolve against whatever directory the
  # caller happens to be in, so it is refused rather than resolved.
  local home3="$base/org3/.firstmate" cwd="$base/cwd"
  mkdir -p "$home3/config" "$home3/data" "$home3/state"
  printf '..\n' > "$home3/config/projects-root"
  printf -- '- docs [direct-PR] - relative registration (added 2026-09-17)\n' > "$home3/data/projects.md"
  printf '{"docs": "./docs"}\n' > "$home3/data/project-paths.json"
  fm_git_init_commit "$cwd/docs"
  if (cd "$cwd" && FM_HOME="$home3" "$ROOT/bin/fm-projects.sh" resolve docs) \
      >"$base/out-rel" 2>"$base/err-rel"; then
    fail "a relative manifest path resolved instead of failing"
  fi
  assert_grep "absolute path" "$base/err-rel" "relative manifest refusal did not name the format"
  case "$(cat "$base/out-rel")" in *docs*) fail "relative manifest path was printed as a resolution" ;; esac
  if (cd "$cwd" && FM_HOME="$home3" "$ROOT/bin/fm-spawn.sh" t1 docs --harness claude --mode direct-PR --yolo off) \
      >/dev/null 2>"$base/err-rel-spawn"; then
    fail "spawn accepted a relative manifest path"
  fi
  case "$(cat "$base/err-rel-spawn")" in
    *"has no brief"*) fail "spawn resolved a relative manifest path against its own cwd" ;;
  esac

  # A malformed projects root must fail discover, not read as "no siblings".
  local home4="$base/org4/.firstmate"
  mkdir -p "$home4/config" "$home4/data" "$home4/state"
  printf '..\nextra\n' > "$home4/config/projects-root"
  if FM_HOME="$home4" "$ROOT/bin/fm-projects.sh" discover >"$base/out-disc" 2>"$base/err-disc"; then
    fail "discover succeeded with a malformed projects root"
  fi
  assert_grep "exactly one path line" "$base/err-disc" "discover did not name the malformed root"
  [ ! -s "$base/out-disc" ] || fail "discover listed siblings from a malformed projects root"

  # A well-formed root naming a directory that no longer exists is an error
  # too: an empty success reads as "this org has no siblings".
  local home5="$base/org5/.firstmate"
  mkdir -p "$home5/config" "$home5/data" "$home5/state"
  printf 'missing-root\n' > "$home5/config/projects-root"
  if FM_HOME="$home5" "$ROOT/bin/fm-projects.sh" discover >"$base/out-miss" 2>"$base/err-miss"; then
    fail "discover succeeded with a projects root that does not exist"
  fi
  assert_grep "not a directory" "$base/err-miss" "discover did not name the missing projects root"

  # A registered alias that resolves nowhere must not be matched against a
  # same-named directory in whatever cwd the caller happens to have.
  local home6="$base/org6/.firstmate" cwd6="$base/cwd6"
  mkdir -p "$home6/config" "$home6/data" "$home6/state" "$base/org6/sibling"
  printf '..\n' > "$home6/config/projects-root"
  printf -- '- ghostproj [direct-PR] - stale registration (added 2026-09-17)\n' > "$home6/data/projects.md"
  fm_git_init_commit "$cwd6/ghostproj"
  local out6
  out6=$( (cd "$cwd6" && FM_HOME="$home6" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" ghostproj) \
      2>"$base/err-ghost") \
    || fail "single-arg refresh of a registered alias failed: $(cat "$base/err-ghost")"
  assert_contains "$out6" "ghostproj: skipped: registered project resolves to no directory" \
    "a stale registration was not reported by its own name"
  case "$out6" in
    *"$cwd6"*|*synced*|*"already current"*)
      fail "single-arg refresh acted on a cwd directory as a registered project" ;;
  esac
  if (cd "$cwd6" && FM_HOME="$home6" "$ROOT/bin/fm-spawn.sh" t1 ghostproj --harness claude --mode direct-PR --yolo off) \
      >/dev/null 2>"$base/err-ghost-spawn"; then
    fail "spawn accepted a cwd directory as a registered project"
  fi
  case "$(cat "$base/err-ghost-spawn")" in
    *"has no brief"*) fail "spawn matched a stale registration against its own cwd" ;;
  esac

  # A registered alias that resolves to no directory is reported on stdout,
  # where the session digest relays it, not hidden on stderr.
  local home7="$base/org7/.firstmate" out7
  mkdir -p "$home7/config" "$home7/data" "$home7/state" "$base/org7"
  printf '..\n' > "$home7/config/projects-root"
  printf -- '- gone [direct-PR] - moved away (added 2026-09-17)\n' > "$home7/data/projects.md"
  out7=$(FM_HOME="$home7" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null) \
    || fail "whole-fleet refresh failed on a stale registration"
  assert_contains "$out7" "gone: skipped: registered project resolves to no directory" \
    "a stale registration was not reported in the refresh output"

  # A registered sibling that exists but is not a clone gets the accurate
  # story, not the "resolves to no directory" one.
  mkdir -p "$base/org7/notes"
  printf -- '- notes [direct-PR] - registered too early (added 2026-09-17)\n' >> "$home7/data/projects.md"
  out7=$(FM_HOME="$home7" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null) \
    || fail "whole-fleet refresh failed on a non-repo sibling"
  assert_contains "$out7" "notes: skipped: not a git repo" \
    "a registered plain directory was not reported as a non-repo"
  out7=$(FM_HOME="$home7" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" notes 2>"$base/err-notes") \
    || fail "single-arg refresh called a registered non-repo sibling unregistered: $(cat "$base/err-notes")"
  assert_contains "$out7" "notes: skipped: not a git repo" \
    "the single-project form hid the real cause behind a registration refusal"
  case "$out7" in
    *"notes: skipped: registered project resolves to no directory"*)
      fail "an existing sibling was reported as resolving to no directory" ;;
  esac

  # Remote seeding names the unreadable registry too, instead of blaming a
  # missing origin the operator would then be told to supply.
  local home8="$base/org8/.firstmate"
  mkdir -p "$home8/config" "$home8/data" "$home8/state"
  printf -- '- reg [direct-PR] - registered project (added 2026-09-17)\n' > "$home8/data/projects.md"
  printf '{"reg": ["/not-a-path"]}\n' > "$home8/data/project-paths.json"
  if FM_HOME="$home8" FM_SECONDMATE_CHARTER='Own the reg project.' \
      FM_SECONDMATE_SCOPE='reg delivery' \
      "$ROOT/bin/fm-remote-home-seed.sh" mate9 remote-host /remote/root /remote/home reg \
      >/dev/null 2>"$base/err-remote"; then
    fail "remote seed proceeded with an unreadable project registry"
  fi
  assert_grep "project registry" "$base/err-remote" "remote seed did not name the broken registry"
  case "$(cat "$base/err-remote")" in
    *"has no origin"*) fail "remote seed blamed a missing origin for an unreadable registry" ;;
  esac

  pass "resolver failures fail closed: fleet refresh, registry lookup, spawn, manifest paths, discover, stale aliases, remote seed"
}

# --- the manifest means the same thing with and without jq -------------------

test_manifest_reader_without_jq() {
  local base home outside nojq out
  base=$(new_dir)
  home="$base/home"
  mkdir -p "$home/config" "$home/data" "$home/state"
  outside="$base/outside-proj"
  fm_git_init_commit "$outside"
  nojq=$(make_jqless_path "$base/nojq")

  # The one-line object is the documented form; it must resolve identically
  # whether or not jq is installed.
  printf '{"ext": "%s"}\n' "$outside" > "$home/data/project-paths.json"
  out=$(PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext) \
    || fail "one-line manifest was rejected without jq"
  assert_equals "$outside" "$out" "one-line manifest resolved wrongly without jq"
  if command -v jq >/dev/null 2>&1; then
    out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext) \
      || fail "one-line manifest was rejected with jq"
    assert_equals "$outside" "$out" "one-line manifest resolved wrongly with jq"
  fi

  # So must the pretty-printed form, including several entries.
  printf '{\n  "ext": "%s",\n  "ext2": "%s"\n}\n' "$outside" "$outside" \
    > "$home/data/project-paths.json"
  out=$(PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext2) \
    || fail "multi-line manifest was rejected without jq"
  assert_equals "$outside" "$out" "multi-line manifest resolved wrongly without jq"

  # The absolute-path rule still holds in the fallback reader.
  printf '{"ext": "./rel"}\n' > "$home/data/project-paths.json"
  if PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext \
      >/dev/null 2>"$base/err-rel"; then
    fail "the fallback reader accepted a relative manifest path"
  fi
  assert_grep "absolute path" "$base/err-rel" "fallback refusal did not name the format"

  # And a document that is not a flat object still fails loudly.
  printf '{"ext": ["%s"]}\n' "$outside" > "$home/data/project-paths.json"
  if PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext \
      >/dev/null 2>"$base/err-bad"; then
    fail "the fallback reader accepted a non-flat manifest"
  fi
  assert_grep "flat JSON object" "$base/err-bad" "fallback refusal did not name the format"

  # A duplicated alias names one directory, not two: jq keeps the last value,
  # so the fallback reader must resolve to the same repository.
  local second="$base/second-proj"
  fm_git_init_commit "$second"
  printf '{"dup": "%s", "dup": "%s"}\n' "$outside" "$second" \
    > "$home/data/project-paths.json"
  out=$(PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve dup) \
    || fail "duplicate-alias manifest was rejected without jq"
  assert_equals "$second" "$out" "the fallback reader did not take the last duplicate alias"
  if command -v jq >/dev/null 2>&1; then
    out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve dup) \
      || fail "duplicate-alias manifest was rejected with jq"
    assert_equals "$second" "$out" "jq and the fallback disagree on a duplicate alias"
  fi

  pass "manifest reader: one-line, multi-line, and duplicate aliases agree with and without jq"
}

# --- spawn refuses unregistered siblings -------------------------------------

test_spawn_refusal() {
  local base org home reg unreg
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"
  reg="$org/reg"
  unreg="$org/unreg"
  fm_git_init_commit "$reg"
  fm_git_init_commit "$unreg"
  printf -- '- reg [direct-PR] - registered sibling (added 2026-09-17)\n' > "$home/data/projects.md"

  # An unregistered sibling is refused by name and by path.
  if FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" t1 unreg --harness claude --mode direct-PR --yolo off >/dev/null 2>"$base/err1"; then
    fail "spawn accepted an unregistered sibling name"
  fi
  assert_grep "not a registered project" "$base/err1" "spawn refusal did not name registration"
  if FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" t1 "$unreg" --harness claude --mode direct-PR --yolo off >/dev/null 2>"$base/err2"; then
    fail "spawn accepted an unregistered sibling path"
  fi
  assert_grep "not a registered project" "$base/err2" "path spawn refusal did not name registration"

  # The registered sibling passes the gate and fails later on its missing
  # brief - proof the refusal above is the registration gate, not a dead end.
  if FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" t1 reg --harness claude --mode direct-PR --yolo off >/dev/null 2>"$base/err3"; then
    fail "spawn of a registered sibling unexpectedly succeeded"
  fi
  assert_grep "no brief" "$base/err3" "registered sibling did not reach the brief check"

  pass "spawn: unregistered sibling refused by name and path, registered reaches the brief check"
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

  # --projects-root is canonicalized even when given as an absolute symlink,
  # and a path with whitespace is refused before anything is written.
  ln -s "$org" "$base/org-link"
  scaffold_secondmate_charter "$parent" mate3 'mate3 charter' alpha \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate3 "$base/child3" alpha \
    --projects-root "$base/org-link" >/dev/null || fail "org seed through a symlinked root failed"
  assert_equals "$(cd "$org" && pwd -P)" "$(cat "$base/child3/config/projects-root")" "symlinked projects-root was not canonicalized"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate3 "$base/child3" alpha \
    --projects-root "$org" >/dev/null || fail "reseed with the canonical root disagreed with the symlinked one"
  mkdir -p "$base/org space"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate4 "$base/child4" alpha \
      --projects-root "$base/org space" >/dev/null 2>"$base/err-space"; then
    fail "org seed accepted a projects root with whitespace"
  fi
  assert_grep "whitespace" "$base/err-space" "whitespace projects-root refusal did not name the cause"

  # An org-shaped parent authorizes by location: its alias must name the
  # same repository the child's projects root holds.
  local oparent="$base/oparent" other="$base/other-org"
  mkdir -p "$oparent/data" "$oparent/state" "$oparent/config"
  printf '%s\n' "$org" > "$oparent/config/projects-root"
  printf -- '- alpha [direct-PR] - alpha project (added 2026-09-17)\n' > "$oparent/data/projects.md"
  fm_git_init_commit "$other/alpha"
  fm_git_add_origin "$other/alpha" "$base/remotes/other-alpha.git"
  scaffold_secondmate_charter "$oparent" mate5 'mate5 charter' alpha \
    || fail "charter scaffold failed"
  if FM_HOME="$oparent" "$ROOT/bin/fm-home-seed.sh" mate5 "$base/child5" alpha \
      --projects-root "$other" >/dev/null 2>"$base/err-loc"; then
    fail "org seed registered a same-named repo the parent does not pin"
  fi
  assert_grep "registered in this home at" "$base/err-loc" "location refusal did not name the registered path"

  # An ordinary seed from an org home refuses an unregistered sibling too:
  # every sibling of an org root is a user working copy until it is registered.
  fm_git_init_commit "$org/unreg"
  fm_git_add_origin "$org/unreg" "$base/remotes/unreg.git"
  scaffold_secondmate_charter "$oparent" mate6 'mate6 charter' unreg \
    || fail "charter scaffold failed"
  if FM_HOME="$oparent" "$ROOT/bin/fm-home-seed.sh" mate6 "$base/child6" unreg \
      >/dev/null 2>"$base/err-unreg-seed"; then
    fail "ordinary seed cloned an unregistered sibling of an org home"
  fi
  assert_grep "not registered" "$base/err-unreg-seed" "seed refusal did not name registration"
  assert_absent "$base/child6" "refused seed left a home behind"

  # A registered project is seeded from the path the registry names, not from
  # a same-named directory that happens to sit under the projects root.
  fm_git_init_commit "$base/elsewhere/beta"
  fm_git_add_origin "$base/elsewhere/beta" "$base/remotes/elsewhere-beta.git"
  fm_git_init_commit "$org/beta"
  fm_git_add_origin "$org/beta" "$base/remotes/org-beta.git"
  printf -- '- beta [direct-PR] - beta project (added 2026-09-17)\n' >> "$oparent/data/projects.md"
  printf '{"beta": "%s"}\n' "$base/elsewhere/beta" > "$oparent/data/project-paths.json"
  scaffold_secondmate_charter "$oparent" mate7 'mate7 charter' beta \
    || fail "charter scaffold failed"
  FM_HOME="$oparent" "$ROOT/bin/fm-home-seed.sh" mate7 "$base/child7" beta >/dev/null \
    || fail "seed of a manifest-registered project failed"
  assert_equals "file://$(cd "$base/remotes/elsewhere-beta.git" && pwd)" \
    "$(git -C "$base/child7/projects/beta" remote get-url origin)" \
    "seed cloned the same-named sibling instead of the registered repository"

  # Validation never needed a projects root, so a malformed config/projects-root
  # must not abort it.
  local badroot="$base/badroot"
  mkdir -p "$badroot/data" "$badroot/state" "$badroot/config"
  printf 'one\ntwo\n' > "$badroot/config/projects-root"
  FM_HOME="$badroot" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$base/err-validate" \
    || fail "registry validation refused a home with a malformed projects-root: $(cat "$base/err-validate")"

  pass "org seed: siblings registered not cloned, unregistered refused, registered path owns the source"
}

# --- a bare alias keeps its registry label in a legacy home ------------------

# Regression: a single-argument refresh of a manifest-registered alias in a
# home WITHOUT config/projects-root used to label the project by its absolute
# path, so the registry lookup that carries local-only found nothing and the
# clone was fetched instead of skipped.
test_manifest_alias_label() {
  local base home local_only shipped out
  base=$(new_dir)
  home="$base/home"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects"

  local_only="$base/outside/ext"
  fm_git_init_commit "$local_only"
  fm_git_add_origin "$local_only" "$base/remotes/ext.git"
  shipped="$base/outside/ship"
  fm_git_init_commit "$shipped"
  fm_git_add_origin "$shipped" "$base/remotes/ship.git"

  printf -- '- ext [local-only] - external project (added 2026-09-17)\n' > "$home/data/projects.md"
  printf -- '- ship [direct-PR] - external project (added 2026-09-17)\n' >> "$home/data/projects.md"
  printf '{"ext": "%s", "ship": "%s"}\n' "$local_only" "$shipped" > "$home/data/project-paths.json"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" ext 2>/dev/null) \
    || fail "single-arg refresh of a manifest alias failed"
  assert_contains "$out" "ext: skipped: local-only project" \
    "a manifest alias lost its registry label, and with it the local-only skip"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" ship 2>/dev/null) \
    || fail "single-arg refresh of a shipped manifest alias failed"
  assert_contains "$out" "ship:" "a manifest alias was not reported by its registered name"
  case "$out" in *"$shipped"*) fail "a manifest alias was reported by absolute path" ;; esac

  pass "legacy home: a bare alias keeps its registry label and its local-only skip"
}

test_launcher_resolution
test_launcher_trust
test_init
test_projects_root
test_discovery_authority
test_resolver_fails_closed
test_manifest_reader_without_jq
test_manifest_alias_label
test_spawn_refusal
test_org_seed

printf 'all project-local tests passed\n'
