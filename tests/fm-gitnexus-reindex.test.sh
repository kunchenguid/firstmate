#!/usr/bin/env bash
# Behavior tests for bin/fm-gitnexus-reindex.sh and its two callers,
# bin/fm-fleet-sync.sh and bin/fm-merge-local.sh.
#
# The hard constraint is that GitNexus analysis never mutates a project clone:
# it once wrote boilerplate into a worker's AGENTS.md, and firstmate never
# writes to a project. This suite pins:
#   - the reindex script builds/refreshes a dedicated mirror clone under
#     $FM_HOME/state/gitnexus-mirrors/<label> and indexes only that mirror,
#     never the project clone itself (a fake `gitnexus` records what it was
#     pointed at, so this half of the suite needs no real install);
#   - it is fail-soft: gitnexus missing, or `analyze` failing, prints one WARN
#     line and still exits 0, without ever touching the project clone;
#   - fm-fleet-sync.sh calls it after an actual fast-forward/recovery but not
#     when the clone was already current (nothing changed to index);
#   - fm-merge-local.sh calls it after a successful local-only landing.
# A second, real-tool group (skipped when `gitnexus` is not installed) proves
# the actual empirical claim the header makes: a real `gitnexus analyze
# --index-only` run against a throwaway repo leaves that repo's working tree
# byte-identical (clean git status, no new files) and the index it registers
# is keyed to that repo's exact HEAD.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-gitnexus-reindex-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_repo <path> <name>: a standalone repo with one commit, no remote.
build_repo() {
  local dir=$1 name=$2
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  commit_file "$dir" "$name.txt" v0 C0
}

# build_pair <home> <name>: projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo to advance it.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

# fake_gitnexus <fakebin> <logfile> [fail_analyze]: a `gitnexus` shim that
# appends "argv: <args>" and "cwd-arg-head: <sha of last arg if a git repo>"
# to <logfile> for every call, and exits 1 on `analyze` when fail_analyze=1.
fake_gitnexus() {
  local fakebin=$1 log=$2 fail_analyze=${3:-0}
  cat > "$fakebin/gitnexus" <<SH
#!/usr/bin/env bash
{
  printf 'argv:'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >> "$log"
if [ "\${1:-}" = analyze ] && [ "$fail_analyze" = 1 ]; then
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gitnexus"
}

run_reindex() {
  local home=$1 proj=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-gitnexus-reindex.sh" "$proj" "$@"
}

snapshot() {
  local dir=$1
  {
    git -C "$dir" status --porcelain=v1 --untracked-files=all
    echo "---files---"
    find "$dir" -mindepth 1 -not -path "$dir/.git*" | sort
    echo "---exclude---"
    cat "$dir/.git/info/exclude" 2>/dev/null
  }
}

# =============================================================================
# Group A: fake-gitnexus behavior (no real install required)
# =============================================================================

# --- mirrors, never the project clone -------------------------------------
home=$(new_home)
proj="$home/standalone-proj"
build_repo "$proj" standalone
fakebin=$(fm_fakebin "$home")
log="$home/gitnexus.log"
: > "$log"
fake_gitnexus "$fakebin" "$log"
before_snapshot=$(snapshot "$proj")
head_sha=$(git -C "$proj" rev-parse HEAD)

out=$(PATH="$fakebin:$PATH" run_reindex "$home" "$proj" 2>&1)
code=$?
expect_code 0 "$code" "reindex exits 0 on success"
assert_contains "$out" "gitnexus index refreshed at $head_sha" "reindex reports the indexed sha"

after_snapshot=$(snapshot "$proj")
[ "$before_snapshot" = "$after_snapshot" ] || fail "project clone changed after reindex"$'\n'"$before_snapshot"$'\n---vs---\n'"$after_snapshot"

mirror="$home/state/gitnexus-mirrors/standalone-proj"
assert_present "$mirror/.git" "mirror clone was created under state/gitnexus-mirrors"
mirror_sha=$(git -C "$mirror" rev-parse HEAD)
[ "$mirror_sha" = "$head_sha" ] || fail "mirror HEAD ($mirror_sha) does not match project HEAD ($head_sha)"

assert_grep "argv: analyze --index-only --name fm-standalone-proj $mirror" "$log" \
  "gitnexus was invoked with --index-only against the mirror, not the project clone"
assert_no_grep "$proj" "$log" "gitnexus was never invoked with the project clone path"
pass "fm-gitnexus-reindex.sh indexes a dedicated mirror and never touches the project clone"

# --- mirror refresh follows a project advance -------------------------------
commit_file "$proj" standalone.txt v1 C1
new_sha=$(git -C "$proj" rev-parse HEAD)
: > "$log"
out=$(PATH="$fakebin:$PATH" run_reindex "$home" "$proj" 2>&1)
assert_contains "$out" "gitnexus index refreshed at $new_sha" "reindex reports the advanced sha"
mirror_sha=$(git -C "$mirror" rev-parse HEAD)
[ "$mirror_sha" = "$new_sha" ] || fail "mirror did not advance to the project's new HEAD"
pass "fm-gitnexus-reindex.sh refreshes an existing mirror to the project's new HEAD"

# --- fail-soft: gitnexus not installed --------------------------------------
# Strip every PATH directory that actually provides a real `gitnexus` (there
# can be several - nvm, linuxbrew, ~/.local/bin) rather than replacing PATH
# outright, so git and coreutils stay reachable.
home=$(new_home)
proj="$home/no-tool-proj"
build_repo "$proj" no-tool
no_gitnexus_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ -x "$dir/gitnexus" ] && continue
  no_gitnexus_path="${no_gitnexus_path:+$no_gitnexus_path:}$dir"
done < <(printf '%s' "$PATH" | tr ':' '\n')
before_snapshot=$(snapshot "$proj")
out=$(PATH="$no_gitnexus_path" run_reindex "$home" "$proj" 2>&1)
code=$?
expect_code 0 "$code" "reindex exits 0 even when gitnexus is missing"
assert_contains "$out" "WARN:" "missing gitnexus produces a WARN line"
assert_contains "$out" "gitnexus not installed" "WARN names the missing tool"
after_snapshot=$(snapshot "$proj")
[ "$before_snapshot" = "$after_snapshot" ] || fail "project clone changed when gitnexus is missing"
assert_absent "$home/state/gitnexus-mirrors/no-tool-proj" "no mirror is created when gitnexus is missing"
pass "fm-gitnexus-reindex.sh is fail-soft when gitnexus is not installed"

# --- fail-soft: gitnexus analyze fails --------------------------------------
home=$(new_home)
proj="$home/fail-analyze-proj"
build_repo "$proj" fail-analyze
fakebin=$(fm_fakebin "$home")
log="$home/gitnexus.log"
: > "$log"
fake_gitnexus "$fakebin" "$log" 1
before_snapshot=$(snapshot "$proj")
out=$(PATH="$fakebin:$PATH" run_reindex "$home" "$proj" 2>&1)
code=$?
expect_code 0 "$code" "reindex exits 0 even when analyze fails"
assert_contains "$out" "WARN:" "failed analyze produces a WARN line"
assert_contains "$out" "gitnexus analyze failed" "WARN names the failed step"
after_snapshot=$(snapshot "$proj")
[ "$before_snapshot" = "$after_snapshot" ] || fail "project clone changed when analyze fails"
pass "fm-gitnexus-reindex.sh is fail-soft when gitnexus analyze fails"

# =============================================================================
# Group B: wiring into the two clone-refresh owners
# =============================================================================

# --- fm-fleet-sync.sh reindexes after an actual fast-forward, not a no-op --
home=$(new_home)
clone=$(build_pair "$home" wired)
fakebin=$(fm_fakebin "$home")
log="$home/gitnexus.log"
: > "$log"
fake_gitnexus "$fakebin" "$log"

PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$clone" >/dev/null 2>&1
assert_no_grep "analyze" "$log" "fleet-sync does not reindex a clone that was already current"

advance_origin "$home" wired C1
: > "$log"
out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>&1)
assert_contains "$out" "synced" "fleet-sync fast-forwarded the clone"
assert_grep "$home/state/gitnexus-mirrors/wired" "$log" "fleet-sync reindexed the clone after fast-forwarding it"
pass "fm-fleet-sync.sh reindexes only after an actual fast-forward or recovery"

# --- fm-merge-local.sh reindexes after a successful local-only landing -----
home=$(new_home)
proj="$home/local-only-proj"
build_repo "$proj" local-only
git -C "$proj" checkout -q -b fm/wired-local
commit_file "$proj" local-only.txt v1 C1
git -C "$proj" checkout -q main
fakebin=$(fm_fakebin "$home")
log="$home/gitnexus.log"
: > "$log"
fake_gitnexus "$fakebin" "$log"

mkdir -p "$home/state"
fm_write_meta "$home/state/wired-local.meta" worktree="$home/wt" project="$proj" mode=local-only kind=ship
PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-merge-local.sh" wired-local >/dev/null 2>&1
assert_grep "$home/state/gitnexus-mirrors/local-only-proj" "$log" "merge-local reindexed the project after landing"
pass "fm-merge-local.sh reindexes the project after a successful local-only landing"

# =============================================================================
# Group C: real gitnexus, skipped when not installed
# =============================================================================
command -v gitnexus >/dev/null 2>&1 || { pass "skip: gitnexus not installed, real-tool proof skipped"; exit 0; }

home=$(new_home)
proj="$home/real-proj"
build_repo "$proj" real
head_sha=$(git -C "$proj" rev-parse HEAD)
before_snapshot=$(snapshot "$proj")

FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-gitnexus-reindex.sh" "$proj" >/dev/null 2>&1
code=$?

expect_code 0 "$code" "real gitnexus reindex exits 0"
after_snapshot=$(snapshot "$proj")
[ "$before_snapshot" = "$after_snapshot" ] || fail "real gitnexus run left the project working tree changed"$'\n'"$before_snapshot"$'\n---vs---\n'"$after_snapshot"

mirror="$home/state/gitnexus-mirrors/real-proj"
mirror_status=$(cd "$mirror" && gitnexus status 2>&1)
assert_contains "$mirror_status" "Indexed commit: ${head_sha:0:7}" "the real index's recorded commit matches the project's HEAD"
assert_contains "$mirror_status" "Current commit: ${head_sha:0:7}" "the mirror's checked-out commit matches the project's HEAD"
gitnexus remove "fm-real-proj" --force >/dev/null 2>&1 || true
pass "a real gitnexus analyze --index-only run leaves the project byte-identical and indexes its exact HEAD"
