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
#     no .firstmate/ ancestor refuses to guess. An install-mode harness execs
#     from the install root with FM_LAUNCH_DIR recording the caller's
#     directory (launch-mode selection lives in tests/fm-view.test.sh).
#     Session-start digest priming of that launch directory (LAUNCH CONTEXT)
#     lives in tests/fm-session-start.test.sh.
#     Ancestor-discovered homes must carry the init-written .fm-home trust
#     marker, read from the repository's own index whatever git redirection
#     the caller exports; config/primary-harness accepts only verified primary adapters;
#     a relative FM_HOME is canonicalized before export.
#   - a directory, fifo, dangling link, or unreadable file at
#     config/primary-harness or config/launch-mode stops the launch by name.
#   - `firstmate init`: --org scaffolds .firstmate/ at the cwd with
#     config/projects-root=.. and no projects/ dir; without --org it scaffolds
#     at the enclosing repo's root and registers the repo itself.
#   - projects root precedence: FM_PROJECTS_OVERRIDE > config/projects-root >
#     $FM_HOME/projects; a malformed config/projects-root fails loudly.
#   - discovery is not authority: fm-projects.sh discover lists every sibling
#     repo, but a whole-fleet refresh touches only registered aliases, and
#     never prunes their branches or remote-tracking refs.
#   - central resolver precedence: data/project-paths.json, then
#     <projects-root>/<alias>, then $FM_HOME/projects/<alias>; projects/<name>
#     prefers the legacy clone, except that FM_PROJECTS_OVERRIDE's root wins.
#   - a data/projects.md or data/project-paths.json that exists but cannot be
#     read as a regular file is a named failure, never an empty registry, and a
#     malformed config/projects-root stops a path spawn.
#   - an unresolved projects/<name> passes through unchanged; a quoted alias jq
#     can hold resolves; a typed name with those bytes that is no key is
#     refused, while a registered row with them never stops a walk over the
#     registry; init refuses a name the registry cannot hold; an init
#     that fails partway is completed by the next one.
#   - a caller's GIT_* variables and CDPATH cannot redirect the launcher or the
#     project library, and the trust check runs no command from the repository
#     it is judging.
#   - a line break in a directory name forges no project record, and
#     config/projects-root refuses control bytes, not locale-dependent ones.
#   - data/project-paths.json refuses a control byte, an empty alias, or a
#     second JSON document whole, with and without jq, so no decoded value can
#     forge a record.
#   - a spawn argument that is really a path - `.`, `..`, a bare relative
#     directory no alias resolves, or a projects/ form with a trailing slash or
#     dot segment - records its registered alias or basename, never its text.
#   - a bare-name refresh argument keeps its registry alias as the label, so a
#     manifest-registered project outside the projects root still resolves its
#     registered posture (local-only is skipped, not fetched).
#   - registry parsing reads whole names: a spaced name is one alias and a
#     name that prefixes a longer one reads its own row's delivery mode.
#   - spawn refuses an unborn HEAD in the directory the resolver chose: a
#     registered sibling or a path-registered project, by name and by path.
#   - org-shaped secondmate seed registers siblings instead of cloning them,
#     only when the sibling is the parent's registered copy or a clone of its
#     origin, and a path-registered alias carries its path mapping, delivery
#     mode, and alias into the child; a reseed removes the child's mapping
#     for a seeded alias the parent no longer maps (keeping unrelated ones),
#     refuses a symlinked child config/projects-root before writing it, and
#     reads the child's stored root without the parent's FM_PROJECTS_OVERRIDE;
#     copied and preserved mappings keep their exact bytes, and a seed refuses
#     a manifest its reader cannot hold, with or without jq.
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
    FM_FAKE_HARNESS_OUT="$base/out1" PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" --mode install)
  assert_grep "FM_HOME=$nested/.firstmate" "$base/out1" "nested .firstmate did not shadow the org home"
  assert_grep "FM_LAUNCH_DIR=$nested/sub/dir" "$base/out1" "FM_LAUNCH_DIR did not record the caller cwd"
  assert_grep "PWD=$ROOT" "$base/out1" "harness did not exec from the install root"

  # The documented install is a symlink on PATH: the launcher must still find
  # its own install root, not the symlink's directory.
  local linkbin="$base/linkbin"
  mkdir -p "$linkbin"
  ln -s "$ROOT/bin/firstmate" "$linkbin/firstmate"
  (cd "$nested/sub/dir" && env -u FM_HOME \
    FM_FAKE_HARNESS_OUT="$base/out-link" PATH="$linkbin:$fakebin:$PATH" firstmate --mode install) \
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

  # Caller-exported git redirection cannot hide the tracked marker: an
  # alternate index, another repository, or a ceiling above the home would
  # each make the check read some state other than this repository's own.
  local alt="$base/alt" redirect
  fm_git_init_commit "$alt"
  for redirect in "GIT_INDEX_FILE=$base/alt-index" "GIT_DIR=$alt/.git" \
      "GIT_COMMON_DIR=$alt/.git" "GIT_CEILING_DIRECTORIES=$repo"; do
    if (cd "$repo/sub" && env -u FM_HOME "$redirect" FM_FAKE_HARNESS_OUT="$base/out-redirect" \
        PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err-redirect"); then
      fail "a tracked .fm-home marker blessed the home under $redirect"
    fi
    assert_grep "untrusted" "$base/err-redirect" "redirected refusal ($redirect) did not name the home untrusted"
  done
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

# --- a broken launcher setting is an error, never a default --------------------
# Anything at config/primary-harness or config/launch-mode that cannot be read
# as a regular file stops the launch naming the setting, rather than reading as
# unset and starting a session the captain did not choose.
test_launcher_broken_settings() {
  local base home repo fakebin setting
  base=$(new_dir)
  home="$base/home"
  repo="$base/repo"
  mkdir -p "$home/config"
  fm_git_init_commit "$repo"
  fakebin=$(make_fake_harness "$base/fakebin")

  refuses() {  # <label> <setting>
    rm -f "$base/out"
    if (cd "$repo" && FM_HOME="$home" FM_FAKE_HARNESS_OUT="$base/out" PATH="$fakebin:$PATH" \
        "$ROOT/bin/firstmate") >/dev/null 2>"$base/err"; then
      fail "$1 at config/$2: the launch was not refused"
    fi
    assert_grep "config/$2" "$base/err" "$1 at config/$2: the refusal did not name the setting"
    assert_absent "$base/out" "$1 at config/$2: the harness ran"
  }

  for setting in primary-harness launch-mode; do
    mkdir "$home/config/$setting"
    refuses "a directory" "$setting"
    rmdir "$home/config/$setting"
    mkfifo "$home/config/$setting"
    refuses "a fifo" "$setting"
    rm -f "$home/config/$setting"
    ln -s "$base/gone" "$home/config/$setting"
    refuses "a dangling link" "$setting"
    rm -f "$home/config/$setting"
    if [ "$(id -u)" -ne 0 ]; then
      printf 'claude\n' > "$home/config/$setting"
      chmod 000 "$home/config/$setting"
      refuses "an unreadable file" "$setting"
      chmod 644 "$home/config/$setting"
      rm -f "$home/config/$setting"
    fi
  done

  pass "launcher: a non-regular or unreadable harness or mode setting stops the launch"
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

# --- firstmate init blessing an existing home ---------------------------------

# snapshot_tree <dir>: one line per file, path plus content hash, so a before
# and after comparison shows any modified, added, or deleted file.
snapshot_tree() {
  (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done)
}

test_init_bless() {
  local base fakebin src clone out
  base=$(new_dir)
  fakebin=$(make_fake_harness "$base/fakebin")
  cp "$fakebin/claude" "$fakebin/codex"

  # A shared home committed upstream and cloned: the clone has the committed
  # config but no marker, so the committed harness is refused before init.
  src="$base/src"
  fm_git_init_commit "$src"
  mkdir -p "$src/.firstmate/config"
  printf 'codex\n' > "$src/.firstmate/config/primary-harness"
  printf '*\n!config/\nconfig/*\n!config/primary-harness\n' > "$src/.firstmate/.gitignore"
  git -C "$src" add -f .firstmate/.gitignore .firstmate/config/primary-harness
  git -C "$src" commit -q -m "share home"
  clone="$base/clone"
  git clone -q "$src" "$clone"
  if (cd "$clone" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out-pre" \
      PATH="$fakebin:$PATH" "$ROOT/bin/firstmate" >/dev/null 2>"$base/err-pre"); then
    fail "cloned home was honoured before init"
  fi
  assert_grep "untrusted" "$base/err-pre" "pre-init refusal did not name the home untrusted"
  assert_grep "firstmate init" "$base/err-pre" "refusal did not name firstmate init"
  assert_absent "$base/out-pre" "the harness launched before the home was blessed"

  local before
  before=$(snapshot_tree "$clone/.firstmate")
  out=$(cd "$clone" && "$ROOT/bin/firstmate" init) || fail "init failed on a cloned home"
  assert_contains "$out" "now trusted" "init did not report the blessing"
  assert_contains "$out" "config/primary-harness" "init did not name the committed config it will honour"
  assert_not_contains "$out" ".tasks.toml" "init named a .tasks.toml it created itself as pre-existing config"
  assert_present "$clone/.firstmate/.fm-home" "init wrote no marker into the cloned home"
  assert_equals "codex" "$(cat "$clone/.firstmate/config/primary-harness")" "init changed committed config"
  assert_equals "*
!config/
config/*
!config/primary-harness" "$(cat "$clone/.firstmate/.gitignore")" "init overwrote the committed .gitignore"
  # Only files that were absent may differ: everything in the snapshot is intact.
  local line
  while IFS= read -r line; do
    printf '%s\n' "$(snapshot_tree "$clone/.firstmate")" | grep -qxF -- "$line" \
      || fail "init modified or deleted an existing file: $line"
  done <<< "$before"
  assert_present "$clone/.firstmate/data" "init did not create the missing data dir"
  assert_present "$clone/.firstmate/.tasks.toml" "init did not create the missing .tasks.toml"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "blessing left the clone dirty"
  (cd "$clone" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out-post" \
    PATH="$fakebin:$PATH" "$ROOT/bin/firstmate") || fail "blessed clone did not launch"
  assert_grep "FM_HOME=$clone/.firstmate" "$base/out-post" "blessed clone did not resolve its home"

  # A second run reports the home already trusted, exit 0, and changes nothing.
  before=$(snapshot_tree "$clone/.firstmate")
  out=$(cd "$clone" && "$ROOT/bin/firstmate" init) || fail "re-running init on a trusted home failed"
  assert_contains "$out" "already trusted" "re-run did not report already trusted"
  assert_equals "$before" "$(snapshot_tree "$clone/.firstmate")" "already-trusted re-run changed files"

  # A pre-marker home (older scaffold, hand-written notes) is blessed without
  # touching what it holds, and the repo registers nothing over existing data.
  local pre="$base/pre"
  fm_git_init_commit "$pre"
  mkdir -p "$pre/.firstmate/data" "$pre/.firstmate/config"
  printf 'keep me\n' > "$pre/.firstmate/data/projects.md"
  printf '..\n' > "$pre/.firstmate/config/projects-root"
  printf 'my own ignore\n' > "$pre/.firstmate/.gitignore"
  before=$(snapshot_tree "$pre/.firstmate")
  out=$(cd "$pre" && "$ROOT/bin/firstmate" init) || fail "init failed on a pre-marker home"
  assert_contains "$out" "now trusted" "pre-marker home was not blessed"
  assert_present "$pre/.firstmate/.fm-home" "pre-marker home got no marker"
  assert_equals "keep me" "$(cat "$pre/.firstmate/data/projects.md")" "init overwrote existing projects.md"
  assert_equals "my own ignore" "$(cat "$pre/.firstmate/.gitignore")" "init overwrote existing .gitignore"
  while IFS= read -r line; do
    printf '%s\n' "$(snapshot_tree "$pre/.firstmate")" | grep -qxF -- "$line" \
      || fail "init modified or deleted an existing pre-marker file: $line"
  done <<< "$before"
  assert_present "$pre/.firstmate/.tasks.toml" "pre-marker home got no .tasks.toml"

  # --org blesses an existing org home the same way.
  local org="$base/org"
  mkdir -p "$org/.firstmate"
  out=$(cd "$org" && "$ROOT/bin/firstmate" init --org) || fail "init --org failed on an existing home"
  assert_contains "$out" "now trusted" "org home was not blessed"
  assert_present "$org/.firstmate/.fm-home" "org home got no marker"
  assert_absent "$org/.firstmate/data/projects.md" "blessing an org home registered a project"

  # A home carrying only a .tasks.toml names it: it can pick the task backend.
  local tasks="$base/tasks"
  fm_git_init_commit "$tasks"
  mkdir -p "$tasks/.firstmate"
  printf 'backend = "beads"\n' > "$tasks/.firstmate/.tasks.toml"
  out=$(cd "$tasks" && "$ROOT/bin/firstmate" init) || fail "init failed on a home with only .tasks.toml"
  assert_contains "$out" "it will honour its config: .tasks.toml" "init did not name the pre-existing .tasks.toml"
  assert_equals 'backend = "beads"' "$(cat "$tasks/.firstmate/.tasks.toml")" "init changed the pre-existing .tasks.toml"

  # A symlinked .firstmate/ is refused and nothing behind it is written.
  local link="$base/linked" target="$base/elsewhere"
  fm_git_init_commit "$link"
  mkdir -p "$target"
  ln -s "$target" "$link/.firstmate"
  if (cd "$link" && "$ROOT/bin/firstmate" init >/dev/null 2>"$base/err-link"); then
    fail "init blessed a symlinked .firstmate"
  fi
  assert_grep "symlink" "$base/err-link" "symlink refusal did not say why"
  assert_absent "$target/.fm-home" "init wrote through a symlinked .firstmate"
  # A non-directory .firstmate is refused too.
  local file="$base/filed"
  fm_git_init_commit "$file"
  printf 'x\n' > "$file/.firstmate"
  if (cd "$file" && "$ROOT/bin/firstmate" init >/dev/null 2>&1); then
    fail "init blessed a non-directory .firstmate"
  fi
  # A symlinked scaffold piece inside a real home is refused as well.
  local piece="$base/piece"
  fm_git_init_commit "$piece"
  mkdir -p "$piece/.firstmate" "$base/outside"
  ln -s "$base/outside" "$piece/.firstmate/data"
  if (cd "$piece" && "$ROOT/bin/firstmate" init >/dev/null 2>&1); then
    fail "init blessed a home with a symlinked data dir"
  fi
  assert_absent "$piece/.firstmate/.fm-home" "refused bless still wrote a marker"

  pass "init: blesses cloned and pre-marker homes without modifying files, already-trusted re-run, unsafe homes refused"
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
  # In a legacy home, FM_PROJECTS_OVERRIDE still selects the root
  # projects/<name> resolves in, ahead of a same-named <home>/projects clone.
  mkdir -p "$base/legacy/config" "$base/legacy/data" "$base/legacy/projects/dup" "$base/override/dup"
  assert_equals "$base/override/dup" "$(FM_HOME="$base/legacy" FM_PROJECTS_OVERRIDE="$base/override" "$ROOT/bin/fm-projects.sh" resolve projects/dup)" "projects/<name> ignored FM_PROJECTS_OVERRIDE for a same-named legacy clone"
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

  # A user feature branch is skipped, never re-attached or reported STUCK,
  # and the fetch never prunes the user's remote-tracking refs.
  git -C "$w-reg" push -q origin HEAD:refs/heads/stale
  git -C "$reg" fetch -q origin
  git -C "$w-reg" push -q origin --delete stale
  git -C "$reg" checkout -q -b feature
  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  git -C "$reg" show-ref --verify --quiet refs/remotes/origin/stale \
    || fail "org-home refresh pruned a remote-tracking ref of a user's feature-branch checkout"
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
  git -C "$reg" show-ref --verify --quiet refs/remotes/origin/stale \
    || fail "org-home refresh of a clean default branch pruned a remote-tracking ref"

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

# --- aliases versus paths -----------------------------------------------------

# A projects/<name> nothing resolves stays exactly that, so a caller's own
# not-a-directory handling runs; stripped, it would name a directory relative
# to whatever the caller's cwd happens to hold.
test_unresolved_projects_form_stays_unchanged() {
  local base home cwd out
  base=$(new_dir)
  home="$base/home"
  cwd="$base/cwd"
  mkdir -p "$home/config" "$home/data"
  fm_git_init_commit "$cwd/ghost"
  out=$(cd "$cwd" && FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve projects/ghost)
  assert_equals projects/ghost "$out" "an unresolved projects/<name> did not pass through unchanged"
  out=$(cd "$cwd" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" projects/ghost 2>/dev/null)
  assert_contains "$out" "skipped: not a directory" "an unresolved projects/<name> refreshed a directory under the cwd"
  pass "resolver: an unresolved projects/<name> passes through unchanged"
}

# `.` names a directory, not a registry key, so an org refresh takes the same
# path-to-alias route it takes for the absolute path.
test_org_refresh_of_current_directory() {
  local base org home out
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"
  fm_git_init_commit "$org/app"
  mkdir -p "$org/app/sub"
  printf -- '- app [local-only] - app (added 2026-10-30)\n' > "$home/data/projects.md"
  out=$(cd "$org/app" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" . 2>&1) \
    || fail "org refresh of . was refused: $out"
  assert_contains "$out" "app:" "org refresh of . was not reported by its registered name"
  out=$(cd "$org/app/sub" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" .. 2>&1) \
    || fail "org refresh of .. was refused: $out"
  assert_contains "$out" "app:" "org refresh of .. was not reported by its registered name"
  pass "org refresh: . and .. resolve to their registered alias"
}

# jq holds a key with a quote or backslash, and seeding keeps its exact bytes,
# so the lookup must find it, and enumerating aliases must survive it.
test_manifest_quoted_alias_resolves() {
  local base home repo out key
  command -v jq >/dev/null 2>&1 || { printf 'ok - SKIP quoted manifest alias: no jq\n'; return 0; }
  base=$(new_dir)
  home="$base/home"
  repo="$base/repo"
  mkdir -p "$home/config" "$home/data" "$repo"
  key='odd"key\name'
  jq -n --arg key "$key" --arg repo "$repo" '{($key): $repo, plain: "/nowhere"}' > "$home/data/project-paths.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve "$key") || fail "a jq-held alias was refused"
  assert_equals "$repo" "$out" "a jq-held alias did not resolve"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" name "$repo/" "$repo") || fail "a jq-held alias poisoned the registry"
  assert_equals "$key" "$out" "a jq-held alias was not found by path"
  pass "manifest lookup: an alias jq can hold resolves, with its exact bytes"
}

# init must not report a registration the resolver can never read back.
test_init_refuses_unregistrable_name() {
  local base name repo
  base=$(new_dir)
  # shellcheck disable=SC2016 # Each $ and backtick is a literal directory name.
  for name in 'my - app' 'my [app]' 'my$app' 'my`app' 'my"app' 'my\app'; do
    repo="$base/$name"
    fm_git_init_commit "$repo"
    if (cd "$repo" && "$ROOT/bin/firstmate" init) >/dev/null 2>"$base/err"; then
      fail "init registered a name the registry cannot hold: $name"
    fi
    assert_grep "cannot register" "$base/err" "the refusal for '$name' did not say why"
    assert_absent "$repo/.firstmate" "a refused init left a home behind for '$name'"
  done
  repo="$base/plain name"
  fm_git_init_commit "$repo"
  (cd "$repo" && "$ROOT/bin/firstmate" init) >/dev/null || fail "init refused a plain spaced name"
  assert_equals "plain name" "$(FM_HOME="$repo/.firstmate" "$ROOT/bin/fm-projects.sh" aliases)" \
    "a plain spaced name was not registered whole"
  pass "init: a repository name the registry cannot hold is refused before anything is written"
}

# --- anything but a readable regular file ---------------------------------------

test_manifest_non_regular() {
  local base home
  base=$(new_dir)
  home="$base/home"
  mkdir -p "$home/config" "$home/data"
  printf -- '- app [local-only] - app (added 2026-10-30)\n' > "$home/data/projects.md"

  refuses() {  # <label>
    if FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve app >/dev/null 2>"$base/err"; then
      fail "$1: resolve read it as an absent manifest"
    fi
    assert_grep "project-paths.json" "$base/err" "$1: the refusal did not name the manifest"
    if FM_HOME="$home" "$ROOT/bin/fm-projects.sh" aliases >/dev/null 2>&1; then
      fail "$1: aliases read it as an absent manifest"
    fi
  }

  mkdir "$home/data/project-paths.json"
  refuses "a directory"
  rmdir "$home/data/project-paths.json"
  ln -s "$base/gone" "$home/data/project-paths.json"
  refuses "a dangling link"
  rm -f "$home/data/project-paths.json"
  if [ "$(id -u)" -ne 0 ]; then
    printf '{}\n' > "$home/data/project-paths.json"
    chmod 000 "$home/data/project-paths.json"
    refuses "an unreadable file"
    chmod 644 "$home/data/project-paths.json"
  fi
  pass "manifest: anything but a readable regular file is refused rather than read as absent"
}

# A malformed config/projects-root must not read as a legacy home, whose rules
# accept an unregistered path.
test_spawn_malformed_projects_root() {
  local base home repo
  base=$(new_dir)
  home="$base/home"
  repo="$base/repo"
  mkdir -p "$home/config" "$home/data" "$home/state"
  fm_git_init_commit "$repo"
  mkdir "$base/root"
  ln -s "$base/root" "$home/config/projects-root"
  if FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" t1 "$repo" --harness claude --mode direct-PR --yolo off \
      >/dev/null 2>"$base/err"; then
    fail "spawn accepted a path under a malformed config/projects-root"
  fi
  assert_grep "projects-root must be a regular file" "$base/err" "spawn did not name the malformed config/projects-root"
  pass "spawn: a malformed config/projects-root stops a path spawn"
}

# The child's manifest is a seed leaf like its siblings, so a symlink there is
# refused rather than followed by the reader and replaced by the write.
test_org_seed_manifest_symlink() {
  local base parent org child target
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$base/child"
  target="$base/elsewhere.json"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$org"
  printf '%s\n' "$org" > "$parent/config/projects-root"
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  printf -- '- alpha [direct-PR] - alpha (added 2026-10-30)\n' > "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha --projects-root "$org" >/dev/null 2>"$base/err" \
    || fail "the first seed failed: $(cat "$base/err")"
  printf '{}\n' > "$target"
  ln -s "$target" "$child/data/project-paths.json"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha --projects-root "$org" \
      >/dev/null 2>"$base/err"; then
    fail "a seed accepted a symlinked child data/project-paths.json"
  fi
  assert_grep "project-paths.json" "$base/err" "the refusal did not name the child manifest"
  [ -L "$child/data/project-paths.json" ] || fail "a refused seed replaced the child's manifest link"
  pass "org seed: a symlinked child manifest is refused like its sibling leaf files"
}

test_bless_marker_not_regular() {
  local base repo
  base=$(new_dir)
  repo="$base/repo"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/.firstmate/.fm-home"
  if (cd "$repo" && "$ROOT/bin/firstmate" init) >/dev/null 2>"$base/err"; then
    fail "init blessed a home whose marker is a directory"
  fi
  assert_grep "not a regular file" "$base/err" "a directory at the marker was not named as such"
  if grep -q "tracked by git" "$base/err"; then
    fail "a directory at the marker was reported as tracked"
  fi
  pass "init: a non-regular marker is reported as that, not as tracked by git"
}

test_summary_unreadable_instructions() {
  local base org home out
  if [ "$(id -u)" -eq 0 ]; then
    printf 'ok - SKIP unreadable instructions: running as root\n'
    return 0
  fi
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data"
  printf '..\n' > "$home/config/projects-root"
  fm_git_init_commit "$org/app"
  printf '# App\n' > "$org/app/AGENTS.md"
  chmod 000 "$org/app/AGENTS.md"
  printf -- '- app [local-only] - app (added 2026-10-30)\n' > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" summary 2>/dev/null)
  chmod 644 "$org/app/AGENTS.md"
  assert_contains "$out" "AGENTS.md: unreadable" "an unreadable AGENTS.md was reported as absent"
  pass "summary: an unreadable instruction file is named rather than reported absent"
}

# --- caller environment --------------------------------------------------------

# Git exports GIT_DIR into every hook, so a launcher run from one must still
# act on the repository it stands in.
test_init_ignores_caller_git_env() {
  local base here other
  base=$(new_dir)
  here="$base/here"
  other="$base/other"
  fm_git_init_commit "$here"
  fm_git_init_commit "$other"
  (cd "$here" && GIT_DIR="$other/.git" GIT_WORK_TREE="$other" "$ROOT/bin/firstmate" init) >/dev/null \
    || fail "init failed under a caller-exported repository"
  assert_present "$here/.firstmate/.fm-home" "init did not scaffold the repository it ran in"
  assert_absent "$other/.firstmate" "a caller-exported GIT_WORK_TREE redirected init into another repository"
  pass "init: a caller-exported git repository cannot redirect the scaffold"
}

test_project_lib_ignores_caller_git_env() {
  local base org other out
  base=$(new_dir)
  org="$base/org"
  other="$base/other"
  mkdir -p "$org/.firstmate/config" "$org/.firstmate/data" "$org/plain"
  printf '..\n' > "$org/.firstmate/config/projects-root"
  fm_git_init_commit "$other"
  fm_git_init_commit "$org/repo"
  out=$(GIT_DIR="$other/.git" FM_HOME="$org/.firstmate" "$ROOT/bin/fm-projects.sh" discover)
  assert_equals repo "$out" "a caller-exported GIT_DIR made a plain directory discoverable"
  out=$(GIT_DIR="$other/.git" FM_HOME="$org/.firstmate" "$ROOT/bin/fm-projects.sh" resolve plain)
  assert_equals plain "$out" "a caller-exported GIT_DIR made a plain directory a project"
  pass "project library: a caller-exported GIT_DIR cannot make a directory a repository"
}

# Reading an untrusted home's marker bypasses git's ownership check, so it must
# not run a command that repository's own config names.
test_trust_check_runs_no_repository_command() {
  local base repo fakebin ran
  base=$(new_dir)
  repo="$base/repo"
  ran="$base/fsmonitor-ran"
  fm_git_init_commit "$repo"
  mkdir -p "$repo/.firstmate"
  : > "$repo/.firstmate/.fm-home"
  printf '#!/bin/sh\n: > "%s"\nexit 1\n' "$ran" > "$base/fsmonitor"
  chmod +x "$base/fsmonitor"
  git -C "$repo" config core.fsmonitor "$base/fsmonitor"
  git -C "$repo" status >/dev/null 2>&1
  rm -f "$ran"
  git -C "$repo/.firstmate" ls-files --error-unmatch -- .fm-home >/dev/null 2>&1 || true
  [ -e "$ran" ] || { printf 'ok - SKIP trust check command: this git ran no fsmonitor for ls-files\n'; return 0; }
  rm -f "$ran"
  fakebin=$(make_fake_harness "$base/fakebin")
  (cd "$repo" && env -u FM_HOME FM_FAKE_HARNESS_OUT="$base/out" PATH="$fakebin:$PATH" \
    "$ROOT/bin/firstmate" --mode install) >/dev/null 2>&1 || true
  assert_absent "$ran" "the trust check ran a command from the repository's own config"
  pass "trust check: reading the marker runs no command from the repository's config"
}

test_relative_path_ignores_cdpath() {
  local base org home other out
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  other="$base/other"
  mkdir -p "$home/config" "$home/data" "$home/state" "$other/app"
  printf '..\n' > "$home/config/projects-root"
  fm_git_init_commit "$org/app"
  printf -- '- app [local-only] - app (added 2026-10-30)\n' > "$home/data/projects.md"
  out=$(cd "$org" && CDPATH="$other" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" app/ 2>&1) \
    || fail "a caller's CDPATH redirected a relative project path: $out"
  assert_contains "$out" "app:" "a relative project path lost its registered name under CDPATH"
  pass "project library: a caller's CDPATH cannot redirect a relative path"
}

test_org_seed_relative_root_with_leading_dash() {
  local base parent org child out
  base=$(new_dir)
  parent="$base/parent"
  org="$base/-org"
  child="$base/child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$org"
  printf '%s\n' "$org" > "$parent/config/projects-root"
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  printf -- '- alpha [direct-PR] - alpha (added 2026-10-30)\n' > "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha || fail "charter scaffold failed"
  out=$(cd "$base" && FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha --projects-root -org 2>&1) \
    || fail "a relative --projects-root with a leading dash was refused: $out"
  assert_grep "/-org" "$child/config/projects-root" "the child did not record the resolved root"
  pass "org seed: a relative --projects-root may start with a dash"
}

# --- record boundaries and registry names --------------------------------------

test_discover_skips_line_break_names() {
  local base org out
  base=$(new_dir)
  org="$base/org"
  mkdir -p "$org/.firstmate/config" "$org/.firstmate/data"
  printf '..\n' > "$org/.firstmate/config/projects-root"
  fm_git_init_commit "$org/real"
  fm_git_init_commit "$org/two
lines"
  out=$(FM_HOME="$org/.firstmate" "$ROOT/bin/fm-projects.sh" discover)
  assert_equals real "$out" "a line break in a sibling's name forged a discovered project"
  pass "discovery: a name with a line break cannot forge a second project"
}

# The tail of a broken record would read as a path relative to the cwd, so a
# legacy whole-fleet refresh could fetch into an unrelated repository.
test_legacy_refresh_skips_line_break_names() {
  local base home cwd out
  base=$(new_dir)
  home="$base/home"
  cwd="$base/cwd"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/projects/a
tail" "$cwd/tail"
  fm_git_init_commit "$cwd/tail"
  out=$(cd "$cwd" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  assert_not_contains "$out" "tail:" "a line break in a clone's name refreshed a directory under the cwd"
  pass "legacy refresh: a clone with a line break in its name forges no relative path"
}

test_summary_reads_backslash_name_row() {
  local home out
  command -v jq >/dev/null 2>&1 || { printf 'ok - SKIP backslash registry name: no jq\n'; return 0; }
  home=$(new_dir)
  mkdir -p "$home/config" "$home/data" "$home/repo"
  printf -- '- a\\tb [local-only] - name with a backslash (added 2026-10-30)\n' > "$home/data/projects.md"
  jq -n --arg repo "$home/repo" '{"a\\tb": $repo}' > "$home/data/project-paths.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" summary)
  assert_contains "$out" '[local-only]' "a backslash in a registered name lost its row's delivery mode"
  pass "summary: a registered name reads its own row byte for byte"
}

# The quote and backslash refusal is for a name a caller typed. A registered row
# holding those bytes is an alias like any other to every registry walk.
test_quoted_registry_row_never_stops_a_walk() {
  local base org home legacy out name
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data"
  printf '..\n' > "$home/config/projects-root"
  fm_git_init_commit "$org/good"
  printf -- '- b"c [local-only] - quoted\n- d\\e [local-only] - backslashed\n- good [local-only] - plain\n' \
    > "$home/data/projects.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>&1) \
    || fail "a quoted row stopped the whole-fleet refresh: $out"
  assert_contains "$out" 'b"c: skipped: registered project resolves to no directory' "the quoted row was not reported"
  assert_contains "$out" 'd\e: skipped: registered project resolves to no directory' "the backslashed row was not reported"
  assert_contains "$out" "good: skipped: local-only project" "a quoted row cost the plain project its refresh"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" summary 2>&1) \
    || fail "a quoted row stopped the summary: $out"
  assert_contains "$out" '- b"c [local-only] - missing: resolves to no directory' "summary lost the quoted row"
  assert_contains "$out" "- good [local-only]" "a quoted row cost the plain project its summary"
  assert_equals "good" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" name "$org/good" "$org/good")" \
    "a quoted row stopped alias-for-path"
  fm_git_init_commit "$org/b\"c"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>&1) \
    || fail "a resolvable quoted row stopped the whole-fleet refresh: $out"
  assert_contains "$out" 'b"c: skipped: local-only project' "a quoted row with a directory did not resolve"

  legacy="$base/legacy"
  mkdir -p "$legacy/config" "$legacy/data" "$legacy/projects"
  printf -- '- see "notes" for bar\n' > "$legacy/data/projects.md"
  mkdir "$base/plain"
  assert_equals "plain" "$(cd "$base/plain" && FM_HOME="$legacy" "$ROOT/bin/fm-projects.sh" name . "$base/plain")" \
    "a free-form quoted bullet stopped a path-form name"

  for name in 'b"c' 'd\e'; do
    mkdir "$base/plain/$name"
    if (cd "$base/plain" && FM_HOME="$legacy" "$ROOT/bin/fm-projects.sh" resolve "$name") \
        >"$base/out" 2>"$base/err"; then
      fail "a typed name the manifest cannot hold resolved: $name"
    fi
    assert_grep "manifest cannot hold" "$base/err" "the typed refusal did not name the bad alias"
    [ ! -s "$base/out" ] || fail "a refused name printed a resolution: $(cat "$base/out")"
  done
  pass "a quoted registry row never stops a walk, and a typed one is still refused"
}

# A backslash in a registered name reaches the row match byte for byte, so a
# local-only project reads its own row and a refresh leaves it alone.
test_backslash_local_only_row_stays_skipped() {
  local base org home repo name before out
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data"
  printf '..\n' > "$home/config/projects-root"
  printf -- '- d\\e [local-only] - backslashed\n- a\\tb [local-only] - escape-shaped\n' > "$home/data/projects.md"
  for name in 'd\e' 'a\tb'; do
    repo="$org/$name"
    fm_git_init_commit "$repo"
    fm_git_add_origin "$repo" "$base/$name.git"
    git clone -q "$base/$name.git" "$base/$name.work"
    git -C "$base/$name.work" -c user.name=t -c user.email=t@example.invalid \
      commit -q --allow-empty -m ahead
    git -C "$base/$name.work" push -q origin HEAD
    assert_equals "local-only off" \
      "$(FM_HOME="$home" "$ROOT/bin/fm-project-mode.sh" "$name" 2>/dev/null)" \
      "$name did not read its own registry row"
    before=$(git -C "$repo" rev-parse HEAD)
    out=$(cd "$repo" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" . 2>&1) \
      || fail "the path-form refresh of $name failed: $out"
    assert_contains "$out" "$name: skipped: local-only project" "the path-form refresh did not skip $name"
    assert_equals "$before" "$(git -C "$repo" rev-parse HEAD)" "the path-form refresh moved $name"
  done
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>&1) \
    || fail "the whole-fleet refresh failed: $out"
  assert_contains "$out" 'd\e: skipped: local-only project' "the whole-fleet refresh did not skip d\\e"
  assert_contains "$out" 'a\tb: skipped: local-only project' "the whole-fleet refresh did not skip a\\tb"
  pass "a backslash in a local-only name reads its own row and stays skipped"
}

# The same byte-for-byte match carries a backslashed row into a seeded child and
# replaces that row on a reseed rather than leaving a second one beside it.
test_org_seed_backslash_row() {
  local base parent org child repo
  command -v jq >/dev/null 2>&1 || { printf 'ok - SKIP backslash seed row: no jq\n'; return 0; }
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$base/child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$org"
  repo="$base/outside/repo"
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$base/repo.git"
  repo=$(cd "$repo" && pwd -P)
  printf -- '- a\\tb [direct-PR +yolo] - parent row\n' > "$parent/data/projects.md"
  jq -n --arg repo "$repo" '{"a\\tb": $repo}' > "$parent/data/project-paths.json"
  scaffold_secondmate_charter "$parent" mate 'mate charter' 'a\tb' \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" 'a\tb' \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "the seed failed: $(cat "$base/err-seed")"
  assert_equals '- a\tb [direct-PR +yolo] - parent row' "$(cat "$child/data/projects.md")" \
    "the child did not carry the parent's own row"
  printf -- '- a\\tb [no-mistakes] - stale row\n' > "$child/data/projects.md"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" 'a\tb' \
    --projects-root "$org" >/dev/null 2>"$base/err-reseed" \
    || fail "the reseed failed: $(cat "$base/err-reseed")"
  assert_equals '- a\tb [direct-PR +yolo] - parent row' "$(cat "$child/data/projects.md")" \
    "the reseed left the child's stale row beside the parent's"
  pass "org seed: a backslashed row keeps its bytes and replaces the child's"
}

# A multibyte path is ordinary text whatever the locale, and the writer and the
# reader must agree on that.
test_projects_root_non_ascii_c_locale() {
  local base home root parent child out
  base=$(new_dir)
  home="$base/home"
  root="$base/café"
  mkdir -p "$home/config" "$root"
  printf '%s\n' "$root" > "$home/config/projects-root"
  out=$(LC_ALL=C FM_HOME="$home" "$ROOT/bin/fm-projects.sh" root 2>&1) \
    || fail "the C locale refused a non-ASCII projects root: $out"
  assert_equals "$(cd "$root" && pwd -P)" "$out" "a non-ASCII projects root resolved wrongly in the C locale"
  printf '%s\001\n' "$root" > "$home/config/projects-root"
  if LC_ALL=C FM_HOME="$home" "$ROOT/bin/fm-projects.sh" root >/dev/null 2>"$base/err"; then
    fail "a control byte in config/projects-root was accepted"
  fi
  assert_grep "control byte" "$base/err" "the refusal did not name the control byte"
  parent="$base/parent"
  child="$base/child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config"
  printf '%s\n' "$root" > "$parent/config/projects-root"
  fm_git_init_commit "$root/alpha"
  fm_git_add_origin "$root/alpha" "$base/remotes/alpha.git"
  printf -- '- alpha [direct-PR] - alpha (added 2026-10-30)\n' > "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha || fail "charter scaffold failed"
  out=$(LC_ALL=C FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha --projects-root "$root" 2>&1) \
    || fail "the C locale refused a non-ASCII --projects-root: $out"
  pass "projects root: only a control byte is refused, whatever the locale"
}

# --- partial writes --------------------------------------------------------------

# The marker is what makes a home read as finished, so an init that fails
# partway must leave a home the next init completes.
test_init_interrupted_completes_on_rerun() {
  local base repo stub
  base=$(new_dir)
  repo="$base/repo"
  stub="$base/stub"
  fm_git_init_commit "$repo"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/cat"
  chmod +x "$stub/cat"
  if (cd "$repo" && PATH="$stub:$PATH" "$ROOT/bin/firstmate" init) >/dev/null 2>&1; then
    fail "the stubbed init did not fail"
  fi
  assert_absent "$repo/.firstmate/.fm-home" "an interrupted init left a home that reads as finished"
  (cd "$repo" && "$ROOT/bin/firstmate" init) >/dev/null || fail "the rerun init failed"
  assert_present "$repo/.firstmate/.fm-home" "the rerun init left no marker"
  assert_present "$repo/.firstmate/.gitignore" "the rerun init left the home without its .gitignore"
  assert_present "$repo/.firstmate/data/projects.md" "the rerun init did not register the repository"
  pass "init: an interrupted scaffold is completed by the next init"
}

# --- an unreadable registry is a failure, never an empty one -------------------
# An empty success reads as "this home registers nothing", so an org refresh
# would skip every project without saying why.
test_registry_read_failure() {
  local base org home
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"
  fm_git_init_commit "$org/app"
  printf -- '- app [local-only] - app (added 2026-10-30)\n' > "$home/data/projects.md"

  refuses() {  # <label>
    if FM_HOME="$home" "$ROOT/bin/fm-projects.sh" aliases >/dev/null 2>"$base/err"; then
      fail "$1: aliases reported success"
    fi
    assert_grep "projects.md" "$base/err" "$1: aliases did not name the registry"
    if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" >/dev/null 2>"$base/err"; then
      fail "$1: a whole-fleet refresh reported success"
    fi
    assert_grep "projects.md" "$base/err" "$1: the refresh did not name the registry"
  }

  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$home/data/projects.md"
    refuses "unreadable registry"
    chmod 644 "$home/data/projects.md"
  fi
  rm -f "$home/data/projects.md"
  mkdir "$home/data/projects.md"
  refuses "directory at the registry path"
  rmdir "$home/data/projects.md"
  ln -s "$base/gone" "$home/data/projects.md"
  refuses "dangling registry symlink"

  pass "registry: an unreadable or non-regular data/projects.md fails rather than reading as empty"
}

# --- manifest record boundaries ----------------------------------------------
# Entries travel as alias<TAB>path lines, so a decoded tab, newline, or other
# control byte would forge a second record. Both readers refuse the whole
# manifest before returning any record, naming the file, and never hand back
# the existing directory a truncated value happens to name.
test_manifest_record_boundaries() {
  local base home repo nojq doc out
  base=$(new_dir)
  home="$base/home"
  repo="$base/line"
  mkdir -p "$home/config" "$home/data" "$home/state"
  fm_git_init_commit "$repo"
  nojq=$(make_jqless_path "$base/nojq")

  refuses() {  # <label> <path-prefix>
    if out=$(PATH="$2" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext 2>"$base/err"); then
      fail "$1: the reader returned '$out' for a manifest it cannot hold"
    fi
    assert_grep "project-paths.json" "$base/err" "$1: the refusal did not name the manifest"
    if FM_HOME="$home" PATH="$2" "$ROOT/bin/fm-projects.sh" aliases >/dev/null 2>&1; then
      fail "$1: aliases succeeded on a manifest the reader cannot hold"
    fi
  }

  if command -v jq >/dev/null 2>&1; then
    for doc in \
      '{"ext":"'"$repo"'\nbreak"}' \
      '{"ext":"'"$repo"'\tbreak"}' \
      '{"e\nxt":"'"$repo"'"}' \
      '{"e\txt":"'"$repo"'"}' \
      '{"ext":"'"$repo"'\u0000break"}' \
      '{"ext":"'"$repo"'\u001bbreak"}' \
      '{"ext":"'"$repo"'\u007fbreak"}' \
      '{"":"'"$repo"'"}' \
      '{"ext":"'"$repo"'"} {"other":"'"$repo"'"}'; do
      printf '%s\n' "$doc" > "$home/data/project-paths.json"
      refuses "jq reader on $doc" "$PATH"
    done
  fi
  printf '{"ext":"%s\nbreak"}\n' "$repo" > "$home/data/project-paths.json"
  refuses "fallback reader on a raw newline" "$nojq"
  printf '{"ext":"%s\tbreak"}\n' "$repo" > "$home/data/project-paths.json"
  refuses "fallback reader on a raw tab" "$nojq"
  printf '{"e\txt":"%s"}\n' "$repo" > "$home/data/project-paths.json"
  refuses "fallback reader on a raw tab in an alias" "$nojq"
  printf '{"ext":"%s","later":"%s\033"}\n' "$repo" "$repo" > "$home/data/project-paths.json"
  refuses "fallback reader on a control byte in a later entry" "$nojq"

  # Spaces and non-ASCII names are ordinary path bytes in both readers.
  local spaced="$base/spaced café"
  mkdir -p "$spaced"
  printf '{"ext":"%s"}\n' "$spaced" > "$home/data/project-paths.json"
  assert_equals "$spaced" "$(PATH="$nojq" FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext)" \
    "the fallback reader refused an ordinary spaced path"
  if command -v jq >/dev/null 2>&1; then
    assert_equals "$spaced" "$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" resolve ext)" \
      "the jq reader refused an ordinary spaced path"
  fi

  pass "manifest reader: a control byte or empty alias is refused whole, before any record is returned"
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

# The unborn-HEAD refusal checks the directory the resolver chose, so a
# registered sibling under the projects root and a path-registered project
# outside it are refused for their own missing commit, by name and by path.
test_spawn_unborn_head_resolved_project() {
  local base org home sib ext legacy legacy_ext label target arg n=0
  base=$(new_dir)
  org="$base/org"
  home="$org/.firstmate"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '..\n' > "$home/config/projects-root"
  sib="$org/sib"
  ext="$base/outside/ext"
  git init -q "$sib"
  git init -q "$ext"
  sib=$(cd "$sib" && pwd)
  ext=$(cd "$ext" && pwd)
  printf -- '- sib [direct-PR] - registered sibling (added 2026-10-18)\n' > "$home/data/projects.md"
  printf '{ "ext": "%s" }\n' "$ext" > "$home/data/project-paths.json"

  # An ordinary home whose path-registered alias names a project outside
  # projects/, while a same-named clone with a commit sits under projects/.
  legacy="$base/legacy"
  legacy_ext="$base/elsewhere/ext"
  mkdir -p "$legacy/config" "$legacy/data" "$legacy/state"
  fm_git_init_commit "$legacy/projects/ext"
  git init -q "$legacy_ext"
  legacy_ext=$(cd "$legacy_ext" && pwd)
  printf '{ "ext": "%s" }\n' "$legacy_ext" > "$legacy/data/project-paths.json"

  for label in "org:sib:$sib" "org:$sib:$sib" "org:ext:$ext" "org:$ext:$ext" "legacy:ext:$legacy_ext"; do
    n=$((n + 1))
    case "$label" in
      org:*) target=$home; label=${label#org:} ;;
      legacy:*) target=$legacy; label=${label#legacy:} ;;
    esac
    arg=${label%%:*}
    if FM_HOME="$target" "$ROOT/bin/fm-spawn.sh" "unborn$n" "$arg" --harness claude --mode direct-PR --yolo off \
      >/dev/null 2>"$base/err$n"; then
      fail "spawn accepted unborn project $arg"
    fi
    assert_grep "project ${label#*:} has no commit yet (unborn HEAD)" "$base/err$n" \
      "spawn of $arg did not refuse the resolved project's unborn HEAD"
    [ ! -e "$target/state/unborn$n.meta" ] || fail "refused spawn of $arg published task metadata"
  done
  [ -z "$(git -C "$sib" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the sibling"
  [ -z "$(git -C "$ext" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the path-registered project"
  [ -z "$(git -C "$legacy_ext" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the legacy path-registered project"

  pass "spawn: unborn HEAD refused on the resolved sibling and path-registered project, by name and path"
}

# --- org-shaped secondmate seed ----------------------------------------------

test_org_seed() {
  local base parent org child
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$org/.firstmate-mate"
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$org"

  # Parent registers alpha at its own clone; the child's sibling under the org
  # root is another clone of the same origin.
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  git clone --quiet "$(git -C "$org/alpha" remote get-url origin)" "$parent/projects/alpha"
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

  # A legacy parent authorizes by repository too: a same-named sibling under
  # the child's root that is neither the parent's registered copy nor a clone
  # of its origin is refused, so the child cannot inherit the parent's posture
  # for a different repository.
  fm_git_init_commit "$parent/projects/webapp"
  fm_git_add_origin "$parent/projects/webapp" "$base/remotes/webapp.git"
  fm_git_init_commit "$org/webapp"
  fm_git_add_origin "$org/webapp" "$base/remotes/other-webapp.git"
  printf -- '- webapp [direct-PR] - webapp project (added 2026-10-02)\n' >> "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate8 'mate8 charter' webapp \
    || fail "charter scaffold failed"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate8 "$base/child8" webapp \
      --projects-root "$org" >/dev/null 2>"$base/err-webapp"; then
    fail "org seed registered a different repository than the legacy parent's copy"
  fi
  assert_grep "registered in this home at" "$base/err-webapp" "repository refusal did not name the registered copy"
  assert_absent "$base/child8" "refused seed left a home behind"
  # A parent alias with no registered copy at all has nothing to bind to.
  printf -- '- gamma [direct-PR] - gamma project (added 2026-10-02)\n' >> "$parent/data/projects.md"
  fm_git_init_commit "$org/gamma"
  fm_git_add_origin "$org/gamma" "$base/remotes/gamma.git"
  scaffold_secondmate_charter "$parent" mate9 'mate9 charter' gamma \
    || fail "charter scaffold failed"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate9 "$base/child9" gamma \
      --projects-root "$org" >/dev/null 2>"$base/err-gamma"; then
    fail "org seed registered a sibling the parent has no registered copy of"
  fi
  assert_grep "no directory" "$base/err-gamma" "missing-copy refusal did not say the parent has no copy"

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

# --- org seed of path-registered aliases (review finding W4) ------------------

# A project registered through data/project-paths.json - with or without a
# data/projects.md line - seeds into an org-shaped child at its registered
# path, and the child inherits the path mapping, the delivery mode, and the
# alias, so the child resolves and treats it exactly as the parent does.
test_org_seed_path_registered() {
  local base parent org child ext ship out
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$org/.firstmate-mate"
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$org"

  # ext: registered ONLY by path, outside the org root.
  ext="$base/outside/ext"
  fm_git_init_commit "$ext"
  fm_git_add_origin "$ext" "$base/remotes/ext.git"
  ext=$(cd "$ext" && pwd -P)
  # ship: a registry line with a posture plus a path outside the org root.
  ship="$base/outside/ship"
  fm_git_init_commit "$ship"
  fm_git_add_origin "$ship" "$base/remotes/ship.git"
  ship=$(cd "$ship" && pwd -P)
  printf -- '- ship [direct-PR +yolo] - ship project (added 2026-09-24)\n' > "$parent/data/projects.md"
  printf '{\n  "ext": "%s",\n  "ship": "%s"\n}\n' "$ext" "$ship" > "$parent/data/project-paths.json"

  scaffold_secondmate_charter "$parent" mate 'mate charter' ext ship \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext ship \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "org seed of path-registered aliases failed: $(cat "$base/err-seed")"

  # The alias and the delivery mode.
  assert_grep "- ext [no-mistakes] - registered by path in the parent home" "$child/data/projects.md" \
    "a path-only alias did not carry the parent's resolved delivery mode"
  assert_grep "- ship [direct-PR +yolo] - ship project" "$child/data/projects.md" \
    "a path-registered alias lost its registry line"
  assert_no_grep "cloned project" "$child/data/projects.md" "a registered-in-place alias was described as cloned"
  assert_equals "no-mistakes off" "$(FM_HOME="$child" "$ROOT/bin/fm-project-mode.sh" ext 2>/dev/null)" \
    "the child resolves a different posture for ext than the parent"
  assert_equals "$(FM_HOME="$parent" "$ROOT/bin/fm-project-mode.sh" ship 2>/dev/null)" \
    "$(FM_HOME="$child" "$ROOT/bin/fm-project-mode.sh" ship 2>/dev/null)" \
    "the child resolves a different posture for ship than the parent"
  # The path mapping.
  assert_equals "$ext" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ext)" \
    "the child did not inherit ext's path mapping"
  assert_equals "$ship" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ship)" \
    "the child did not inherit ship's path mapping"
  out=$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" aliases)
  assert_contains "$out" "ext" "the child does not register ext"
  # Registered in place: nothing cloned, the real repositories untouched.
  assert_absent "$child/projects" "an org seed created a projects/ dir"
  assert_absent "$org/ext" "an org seed cloned a path-registered alias into the org root"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "registry validation failed after the path-registered org seed"

  # Reseeding keeps the child's other mappings and replaces a stale one.
  printf '{"keep": "/somewhere/keep", "ext": "/stale/ext"}\n' > "$child/data/project-paths.json"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext ship \
    --projects-root "$org" >/dev/null 2>"$base/err-reseed" \
    || fail "reseed failed: $(cat "$base/err-reseed")"
  assert_equals "/somewhere/keep" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve keep)" \
    "reseeding dropped the child's own mapping"
  assert_equals "$ext" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ext)" \
    "reseeding did not replace the child's stale mapping"

  # A path-registered alias whose repository is gone is refused, and the
  # refused seed leaves no child manifest behind.
  printf '{"ghost": "%s"}\n' "$base/outside/ghost" > "$parent/data/project-paths.json"
  scaffold_secondmate_charter "$parent" mate2 'mate2 charter' ghost \
    || fail "charter scaffold failed"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate2 "$base/child2" ghost \
      --projects-root "$org" >/dev/null 2>"$base/err-ghost"; then
    fail "an org seed accepted a path-registered alias whose repository is missing"
  fi
  assert_grep "not found at $base/outside/ghost" "$base/err-ghost" "the missing-repository refusal did not name the registered path"
  assert_absent "$base/child2" "a refused seed left a home behind"

  pass "org seed: a path-registered alias carries its path mapping, delivery mode, and alias into the child"
}

# --- an existing child's config/projects-root leaf ---------------------------

# A reseed with --projects-root never writes through a symlink at the child's
# config/projects-root: a dangling link would otherwise create a file outside
# the child home that a failed seed's rollback cannot remove.
test_org_seed_root_leaf_symlink() {
  local base parent org child
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$base/child"
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$org"
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  git clone --quiet "$(git -C "$org/alpha" remote get-url origin)" "$parent/projects/alpha"
  printf -- '- alpha [direct-PR] - alpha project (added 2026-10-30)\n' > "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "org seed failed: $(cat "$base/err-seed")"

  rm -f "$child/config/projects-root"
  ln -s "$base/outside-root" "$child/config/projects-root"
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
      --projects-root "$org" >/dev/null 2>"$base/err-link"; then
    fail "a reseed wrote through a symlinked config/projects-root"
  fi
  assert_absent "$base/outside-root" "a reseed created a file outside the child home through config/projects-root"
  assert_grep "must not be a symlink: $child/config/projects-root" "$base/err-link" \
    "the symlinked projects-root refusal did not name the leaf"

  pass "org seed: a symlinked child config/projects-root is refused before it is written"
}

# --- a seeded alias the parent stops mapping ---------------------------------

# When the parent moves a path-registered project into its org folder and
# drops its data/project-paths.json entry, a reseed removes the child's
# mapping for that alias, so the child resolves the sibling the seed checked
# rather than the old repository; mappings for unrelated aliases survive.
test_org_seed_moved_alias() {
  local base parent org child ship
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$base/child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$org"
  printf '%s\n' "$org" > "$parent/config/projects-root"
  ship="$base/outside/ship"
  fm_git_init_commit "$ship"
  fm_git_add_origin "$ship" "$base/remotes/ship.git"
  ship=$(cd "$ship" && pwd -P)
  printf -- '- ship [direct-PR] - ship project (added 2026-10-30)\n' > "$parent/data/projects.md"
  printf '{"ship": "%s"}\n' "$ship" > "$parent/data/project-paths.json"
  scaffold_secondmate_charter "$parent" mate 'mate charter' ship \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ship \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "org seed failed: $(cat "$base/err-seed")"
  assert_equals "$ship" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ship)" \
    "the child did not inherit ship's path mapping"

  # The parent moves ship into the org folder and stops mapping it.
  git clone --quiet "$(git -C "$ship" remote get-url origin)" "$org/ship"
  printf '{}\n' > "$parent/data/project-paths.json"
  printf '{"ship": "%s", "keep": "/somewhere/keep"}\n' "$ship" > "$child/data/project-paths.json"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ship \
    --projects-root "$org" >/dev/null 2>"$base/err-reseed" \
    || fail "reseed after the move failed: $(cat "$base/err-reseed")"
  assert_equals "$(cd "$org/ship" && pwd -P)" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ship)" \
    "the child kept resolving the old repository after the parent moved it"
  assert_equals "/somewhere/keep" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve keep)" \
    "the reseed dropped an unrelated child mapping"

  pass "org seed: a seeded alias the parent no longer maps loses its stale child mapping"
}

# --- a seeded mapping keeps its exact bytes ------------------------------------

# With jq the reader accepts an absolute path holding a quote or backslash, so
# seeding writes each copied and preserved key and path as JSON, and an
# unrelated child mapping comes through byte for byte. Without jq the reader
# refuses those bytes, so such a seed stops before the child's manifest changes.
test_org_seed_path_bytes() {
  local base parent org child ext nojq before
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  child="$base/child"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$org"
  printf '%s\n' "$org" > "$parent/config/projects-root"
  ext="$base/outside/it's \"ext\" back\\slash"
  fm_git_init_commit "$ext"
  fm_git_add_origin "$ext" "$base/remotes/ext.git"
  ext=$(cd "$ext" && pwd -P)
  printf -- '- ext [direct-PR] - ext project (added 2026-10-30)\n' > "$parent/data/projects.md"
  jq -n --arg ext "$ext" '{ext: $ext}' > "$parent/data/project-paths.json"
  scaffold_secondmate_charter "$parent" mate 'mate charter' ext \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "org seed failed: $(cat "$base/err-seed")"
  jq -e . "$child/data/project-paths.json" >/dev/null || fail "seeding wrote broken JSON"
  assert_equals "$ext" "$(jq -r .ext "$child/data/project-paths.json")" "seeding changed the copied path"
  assert_equals "$ext" "$(FM_HOME="$child" "$ROOT/bin/fm-projects.sh" resolve ext)" \
    "the child did not resolve the seeded path"

  # An unrelated child mapping survives a reseed with its exact bytes.
  jq -n --arg ext "$ext" '{
    "odd\"key\\name": "/some/\"where\"\\keep",
    ext: "/stale/ext"
  }' > "$child/data/project-paths.json"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext \
    --projects-root "$org" >/dev/null 2>"$base/err-reseed" \
    || fail "reseed failed: $(cat "$base/err-reseed")"
  jq -e . "$child/data/project-paths.json" >/dev/null || fail "reseeding wrote broken JSON"
  assert_equals "$ext" "$(jq -r .ext "$child/data/project-paths.json")" "reseeding did not replace the stale path"
  assert_equals '/some/"where"\keep' "$(jq -r '."odd\"key\\name"' "$child/data/project-paths.json")" \
    "reseeding changed a preserved mapping holding a quote and a backslash"

  # A child manifest no reader can hold stops the reseed and is left untouched.
  jq -n '{"tabbed\tkey": "/line\nbreak\tkeep"}' > "$child/data/project-paths.json"
  before=$(cat "$child/data/project-paths.json")
  if FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext \
      --projects-root "$org" >/dev/null 2>"$base/err-held"; then
    fail "a reseed accepted a child manifest its reader cannot hold"
  fi
  assert_grep "must be a flat JSON object" "$base/err-held" "the reseed stopped for another reason"
  assert_equals "$before" "$(cat "$child/data/project-paths.json")" "a refused reseed changed the child's manifest"
  jq -n '{"odd\"key\\name": "/some/\"where\"\\keep", ext: "/stale/ext"}' > "$child/data/project-paths.json"

  # Without jq the same parent manifest is refused and the child keeps its file.
  nojq=$(make_jqless_path "$base/nojq")
  for tool in chmod cp date dirname id ln mv pwd readlink rmdir sleep touch; do
    ln -sf "$(command -v "$tool")" "$nojq/$tool"
  done
  before=$(cat "$child/data/project-paths.json")
  if PATH="$nojq" FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext \
      --projects-root "$org" >/dev/null 2>"$base/err-nojq"; then
    fail "a jq-less seed accepted a manifest its reader cannot hold"
  fi
  assert_grep "must be a flat JSON object" "$base/err-nojq" "the jq-less seed stopped for another reason"
  assert_equals "$before" "$(cat "$child/data/project-paths.json")" "a refused jq-less seed changed the child's manifest"

  # A plain manifest seeds the same way without jq.
  ext="$base/outside/plain"
  fm_git_init_commit "$ext"
  fm_git_add_origin "$ext" "$base/remotes/plain.git"
  ext=$(cd "$ext" && pwd -P)
  printf '{"ext": "%s"}\n' "$ext" > "$parent/data/project-paths.json"
  printf '{"keep": "/somewhere/keep", "ext": "/stale/ext"}\n' > "$child/data/project-paths.json"
  PATH="$nojq" FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" ext \
    --projects-root "$org" >/dev/null 2>"$base/err-plain" \
    || fail "a jq-less reseed of a plain manifest failed: $(cat "$base/err-plain")"
  assert_equals "$ext" "$(jq -r .ext "$child/data/project-paths.json")" "a jq-less reseed did not replace the stale path"
  assert_equals "/somewhere/keep" "$(jq -r .keep "$child/data/project-paths.json")" "a jq-less reseed dropped an unrelated mapping"

  pass "org seed: copied and preserved mappings keep their exact bytes, and a jq-less seed refuses what its reader cannot hold"
}

# --- the child's stored root, not the parent's override ----------------------

# The parent's FM_PROJECTS_OVERRIDE is parent-only: a secondmate launch clears
# it, so seeding reads and compares the child's own config/projects-root.
test_org_seed_override_root() {
  local base parent org other child
  base=$(new_dir)
  parent="$base/parent"
  org="$base/org"
  other="$base/other"
  child="$base/child"
  mkdir -p "$parent/projects" "$parent/data" "$parent/state" "$org" "$other"
  fm_git_init_commit "$org/alpha"
  fm_git_add_origin "$org/alpha" "$base/remotes/alpha.git"
  git clone --quiet "$(git -C "$org/alpha" remote get-url origin)" "$parent/projects/alpha"
  printf -- '- alpha [direct-PR] - alpha project (added 2026-10-30)\n' > "$parent/data/projects.md"
  scaffold_secondmate_charter "$parent" mate 'mate charter' alpha \
    || fail "charter scaffold failed"
  FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
    --projects-root "$org" >/dev/null 2>"$base/err-seed" \
    || fail "org seed failed: $(cat "$base/err-seed")"
  other=$(cd "$other" && pwd -P)
  printf '%s\n' "$other" > "$child/config/projects-root"

  # A flag matching the parent's override does not match the child's root.
  if FM_PROJECTS_OVERRIDE="$org" FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
      --projects-root "$org" >/dev/null 2>"$base/err-flag"; then
    fail "a reseed compared --projects-root with the parent's override, not the child's root"
  fi
  assert_grep "already names $other" "$base/err-flag" "the root-mismatch refusal did not name the child's root"
  # Without the flag, the child's own root decides where siblings are checked.
  if FM_PROJECTS_OVERRIDE="$org" FM_HOME="$parent" "$ROOT/bin/fm-home-seed.sh" mate "$child" alpha \
      >/dev/null 2>"$base/err-noflag"; then
    fail "a reseed checked siblings under the parent's override instead of the child's root"
  fi
  assert_grep "$other/alpha" "$base/err-noflag" "the reseed did not check the sibling under the child's root"
  assert_equals "$other" "$(cat "$child/config/projects-root")" "a refused reseed changed the child's projects root"

  pass "org seed: the child's stored projects root is read without the parent's override"
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

# --- project names for path-shaped arguments ---------------------------------
# A spawn records project_name and reads capacity and forge by it, so anything
# that is really a path takes its registered alias or basename, never its text.
test_project_name_path_forms() {
  local base home repo plain out arg
  base=$(new_dir)
  home="$base/home"
  repo="$base/work/checkout"
  plain="$base/work/plain"
  mkdir -p "$home/config" "$home/data" "$home/projects/clone" "$repo/sub" "$plain"
  printf '{"ext": "%s"}\n' "$repo" > "$home/data/project-paths.json"
  name_of() { FM_HOME="$home" "$ROOT/bin/fm-projects.sh" name "$1" "$2"; }

  assert_equals ext "$(cd "$repo" && name_of . "$repo")" ". lost the registered alias"
  assert_equals ext "$(cd "$repo/sub" && name_of .. "$repo")" ".. lost the registered alias"
  assert_equals plain "$(cd "$plain" && name_of . "$plain")" ". of an unregistered directory did not take its basename"
  assert_equals ext "$(cd "$base/work" && name_of checkout "$repo")" \
    "a bare relative directory no alias resolves lost its registered alias"
  assert_equals ext "$(name_of ext "$repo")" "a bare alias did not keep its name"
  assert_equals clone "$(name_of projects/clone "$home/projects/clone")" "projects/<name> did not keep its name"
  for arg in projects/clone/ projects/./clone; do
    assert_equals clone "$(name_of "$arg" "$home/projects/clone")" "$arg was recorded as typed"
  done
  assert_equals projects "$(name_of projects/ "$home/projects")" "projects/ recorded no name"
  assert_equals home "$(name_of projects/.. "$home")" "projects/.. was recorded as typed"

  pass "project name: . .. and other path-shaped arguments take the registered alias or basename"
}

# --- whole-name registry parsing --------------------------------------------
# A spaced name is one alias, and a name that prefixes a longer registered name
# reads its own row, matching bin/fm-project-mode.sh's whole-name rule.
test_registry_whole_names() {
  local home out
  home=$(new_dir)
  mkdir -p "$home/config" "$home/data"
  {
    printf -- '- my app [direct-PR +yolo] - spaced name (added 2026-10-11)\n'
    printf -- '- my [local-only] - prefix of the spaced name (added 2026-10-11)\n'
    printf -- '- legacy - unannotated (added 2026-10-11)\n'
  } > "$home/data/projects.md"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" aliases) \
    || fail "aliases failed on a spaced registry name"
  assert_equals "$(printf 'legacy\nmy\nmy app')" "$out" \
    "a spaced registry name was split into its first word"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-projects.sh" summary) \
    || fail "summary failed on a spaced registry name"
  assert_contains "$out" "- my app [direct-PR +yolo] - missing" \
    "a spaced name did not read its own row's delivery mode"
  assert_contains "$out" "- my [local-only] - missing" \
    "a prefix name did not read its own row's delivery mode"
  assert_contains "$out" "- legacy [no-mistakes] - missing" \
    "an unannotated row did not default to no-mistakes"

  pass "registry parsing: spaced and prefix names resolve to their own whole rows"
}

test_launcher_resolution
test_launcher_trust
test_launcher_broken_settings
test_init
test_init_bless
test_projects_root
test_discovery_authority
test_resolver_fails_closed
test_manifest_reader_without_jq
test_registry_read_failure
test_manifest_record_boundaries
test_manifest_alias_label
test_project_name_path_forms
test_unresolved_projects_form_stays_unchanged
test_org_refresh_of_current_directory
test_manifest_quoted_alias_resolves
test_init_refuses_unregistrable_name
test_manifest_non_regular
test_spawn_malformed_projects_root
test_org_seed_manifest_symlink
test_bless_marker_not_regular
test_summary_unreadable_instructions
test_init_ignores_caller_git_env
test_project_lib_ignores_caller_git_env
test_trust_check_runs_no_repository_command
test_relative_path_ignores_cdpath
test_org_seed_relative_root_with_leading_dash
test_discover_skips_line_break_names
test_legacy_refresh_skips_line_break_names
test_summary_reads_backslash_name_row
test_quoted_registry_row_never_stops_a_walk
test_backslash_local_only_row_stays_skipped
test_projects_root_non_ascii_c_locale
test_init_interrupted_completes_on_rerun
test_spawn_refusal
test_spawn_unborn_head_resolved_project
test_org_seed
test_org_seed_path_registered
test_org_seed_root_leaf_symlink
test_org_seed_moved_alias
test_org_seed_path_bytes
test_org_seed_backslash_row
test_org_seed_override_root
test_registry_whole_names

printf 'all project-local tests passed\n'
