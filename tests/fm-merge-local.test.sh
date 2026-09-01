#!/usr/bin/env bash
# Behavior tests for fm-merge-local.sh's local-mirror-origin sync.
#
# fm-merge-local.sh fast-forwards a local-only project's local default branch to
# the crewmate's fm/<id> branch. Some local-only projects point origin at a local
# bare mirror that exists only so bin/fm-spawn.sh's pooled-worktree refresh has
# something to fetch from. This suite pins the fix that keeps that mirror caught
# up: after the local fast-forward, a local-path (or file://) origin gets its
# default branch fast-forwarded to match, while a real hosted (https/ssh/scp-like)
# origin is left completely untouched - no push is even attempted, so local-only's
# no-push, no-PR contract for a real forge holds unchanged.
#
# The decision is made on push URLs, never the fetch URL alone, because a
# separately configured remote.origin.pushurl overrides the fetch URL for
# `git push`: the local-fetch/hosted-pushurl, hosted-fetch/local-pushurl,
# no-pushurl-configured, and multiple-pushurls cases below pin that boundary
# from every direction a mismatched fetch/push URL pair could take it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/state"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_local_mirror_project <home> <name>: a bare local mirror plus a project
# clone of it (origin set to the mirror's plain filesystem path, no file://
# prefix - the real-world shape "data/local-remotes/<repo>.git" is cloned as).
# Both start with one commit on main. Echoes "<mirror-path> <project-path>".
build_local_mirror_project() {
  local home=$1 name=$2 work mirror proj
  work="$home/work-$name"
  mirror="$home/mirrors/$name.git"
  proj="$home/proj-$name"
  mkdir -p "$home/mirrors"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$mirror"

  git clone --quiet "$mirror" "$proj"
  printf '%s %s\n' "$mirror" "$proj"
}

# task_branch <proj> <id>: create fm/<id> off the current default branch with one
# extra commit, then return to that default branch (clean, checked out) so the
# project checkout is in the state fm-merge-local.sh requires.
task_branch() {
  local proj=$1 id=$2 default
  default=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" checkout -qb "fm/$id"
  commit_file "$proj" file.txt "v-$id" "C-$id"
  git -C "$proj" checkout -q "$default"
}

run_merge_local() {
  local home=$1 id=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-merge-local.sh" "$id"
}

# --- tests ------------------------------------------------------------------

test_local_mirror_origin_advances_to_match() {
  local home id mirror proj built out mirror_main proj_main

  home=$(new_home)
  id=local-mirror-1
  built=$(build_local_mirror_project "$home" alpha)
  mirror=${built% *}
  proj=${built#* }

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  out=$(run_merge_local "$home" "$id" 2>&1) \
    || fail "fm-merge-local.sh failed against a local-mirror origin: $out"

  assert_contains "$out" "merged fm/$id into local main" \
    "local-mirror: the local fast-forward itself was not reported"
  assert_contains "$out" "origin mirror updated: main" \
    "local-mirror: the mirror-sync outcome was not reported"

  mirror_main=$(git -C "$mirror" rev-parse main)
  proj_main=$(git -C "$proj" rev-parse main)
  [ "$mirror_main" = "$proj_main" ] \
    || fail "local-mirror: mirror main ($mirror_main) does not match project main ($proj_main) after merge"

  pass "a local-path origin's default branch is fast-forwarded to match after the merge"
}

test_local_mirror_origin_already_current_is_quiet() {
  local home id mirror proj built out

  home=$(new_home)
  id=local-mirror-2
  built=$(build_local_mirror_project "$home" bravo)
  mirror=${built% *}
  proj=${built#* }

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  out=$(run_merge_local "$home" "$id" 2>&1) \
    || fail "fm-merge-local.sh failed on first run: $out"
  assert_contains "$out" "origin mirror updated: main" \
    "local-mirror: the first run's mirror-sync outcome was not reported"

  # Re-running against the same already-merged branch is a no-op fast-forward
  # (branch is an ancestor of an unchanged default) and the mirror is already
  # exactly caught up from the first run, so the "Everything up-to-date" push
  # outcome must not be misreported as a fresh update.
  out=$(run_merge_local "$home" "$id" 2>&1) \
    || fail "fm-merge-local.sh failed on the idempotent second run: $out"
  assert_not_contains "$out" "origin mirror updated" \
    "local-mirror: an already-current mirror was wrongly reported as updated again"

  [ "$(git -C "$mirror" rev-parse main)" = "$(git -C "$proj" rev-parse main)" ] \
    || fail "local-mirror: mirror main does not match project main after the idempotent re-run"

  pass "an already-caught-up local mirror is not spuriously re-reported as updated"
}

test_hosted_origin_is_never_pushed_to() {
  local home id proj fakebin out err push_log

  home=$(new_home)
  id=hosted-origin-1
  proj="$home/proj-hosted"

  git init -q "$proj"
  git -C "$proj" symbolic-ref HEAD refs/heads/main
  commit_file "$proj" file.txt v0 C0
  git -C "$proj" remote add origin "https://example.invalid/fake/repo.git"

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  push_log="$home/push.log"
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf '%s\n' "push \$*" >> "$push_log"
    exit 1
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"

  out="$home/out"; err="$home/err"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$out" 2>"$err"
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "hosted-origin: fm-merge-local.sh failed for a real https origin: $(cat "$err")"
  assert_contains "$(cat "$out")" "merged fm/$id into local main" \
    "hosted-origin: the local fast-forward itself was not reported"
  assert_no_grep "origin mirror updated" "$out" \
    "hosted-origin: a hosted origin was wrongly reported as mirror-updated"
  assert_no_grep "could not fast-forward local-mirror origin" "$err" \
    "hosted-origin: a hosted origin was wrongly treated as a local mirror"
  [ ! -s "$push_log" ] || fail "hosted-origin: git push was attempted against a real hosted origin: $(cat "$push_log")"

  pass "a real hosted (https) origin is never pushed to, preserving local-only's no-push contract"
}

test_local_fetch_hosted_pushurl_is_never_pushed_to() {
  local home id built mirror proj fakebin out err push_log

  home=$(new_home)
  id=hosted-pushurl-1
  built=$(build_local_mirror_project "$home" charlie)
  mirror=${built% *}
  proj=${built#* }
  git -C "$proj" remote set-url --push origin "https://example.invalid/fake/repo.git"

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  push_log="$home/push.log"
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf '%s\n' "push \$*" >> "$push_log"
    exit 1
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"

  out="$home/out"; err="$home/err"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$out" 2>"$err"
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "hosted-pushurl: fm-merge-local.sh failed for a local-fetch/hosted-push origin: $(cat "$err")"
  assert_contains "$(cat "$out")" "merged fm/$id into local main" \
    "hosted-pushurl: the local fast-forward itself was not reported"
  assert_no_grep "origin mirror updated" "$out" \
    "hosted-pushurl: a hosted pushurl was wrongly reported as mirror-updated"
  [ ! -s "$push_log" ] || fail "hosted-pushurl: git push was attempted against a remote with a hosted pushurl: $(cat "$push_log")"

  mirror_main=$(git -C "$mirror" rev-parse main)
  proj_prev=$(git -C "$proj" rev-parse "main^")
  [ "$mirror_main" = "$proj_prev" ] \
    || fail "hosted-pushurl: the local mirror should have been left untouched at its prior commit"

  pass "a local fetch URL paired with a hosted pushurl is never pushed to (the reported bypass)"
}

test_hosted_fetch_local_pushurl_still_syncs() {
  local home id built mirror proj out mirror_main proj_main

  home=$(new_home)
  id=local-pushurl-1
  built=$(build_local_mirror_project "$home" delta)
  mirror=${built% *}
  proj=${built#* }
  git -C "$proj" remote set-url origin "https://example.invalid/fake/repo.git"
  git -C "$proj" remote set-url --push origin "$mirror"

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  out=$(run_merge_local "$home" "$id" 2>&1) \
    || fail "local-pushurl: fm-merge-local.sh failed against a hosted-fetch/local-push origin: $out"

  assert_contains "$out" "origin mirror updated: main" \
    "local-pushurl: the mirror-sync outcome was not reported when the actual push destination is local"

  mirror_main=$(git -C "$mirror" rev-parse main)
  proj_main=$(git -C "$proj" rev-parse main)
  [ "$mirror_main" = "$proj_main" ] \
    || fail "local-pushurl: mirror main ($mirror_main) does not match project main ($proj_main) after merge"

  pass "a hosted fetch URL paired with a local pushurl still syncs, since that is the actual push destination"
}

test_no_pushurl_falls_back_to_fetch_url() {
  # Regression pin: git itself returns the fetch URL from `get-url --push` when
  # no pushurl is configured, so the ordinary (no pushurl) local-mirror case must
  # keep working unchanged - covered already by test_local_mirror_origin_advances_to_match,
  # this test only pins the no-pushurl-configured hosted-origin side of that
  # same fallback so the boundary is exercised from both directions.
  local home id proj out err push_log fakebin

  home=$(new_home)
  id=no-pushurl-1
  proj="$home/proj-no-pushurl"

  git init -q "$proj"
  git -C "$proj" symbolic-ref HEAD refs/heads/main
  commit_file "$proj" file.txt v0 C0
  git -C "$proj" remote add origin "https://example.invalid/fake/repo.git"

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  push_log="$home/push.log"
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf '%s\n' "push \$*" >> "$push_log"
    exit 1
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"

  out="$home/out"; err="$home/err"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$out" 2>"$err"
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "no-pushurl: fm-merge-local.sh failed for an unconfigured-pushurl hosted origin: $(cat "$err")"
  [ ! -s "$push_log" ] || fail "no-pushurl: git push was attempted against a hosted origin with no pushurl configured: $(cat "$push_log")"

  pass "an unconfigured pushurl correctly falls back to the (hosted) fetch URL and is never pushed to"
}

test_multiple_pushurls_one_hosted_is_never_pushed_to() {
  local home id built mirror proj out err push_log fakebin

  home=$(new_home)
  id=multi-pushurl-1
  built=$(build_local_mirror_project "$home" echo)
  mirror=${built% *}
  proj=${built#* }
  git -C "$proj" remote set-url --push origin "$mirror"
  git -C "$proj" remote set-url --add --push origin "https://example.invalid/fake/repo.git"

  task_branch "$proj" "$id"
  fm_write_meta "$home/state/$id.meta" "project=$proj" "mode=local-only"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  push_log="$home/push.log"
  realgit=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
real="$realgit"
for a in "\$@"; do
  if [ "\$a" = push ]; then
    printf '%s\n' "push \$*" >> "$push_log"
    exit 1
  fi
done
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/git"

  out="$home/out"; err="$home/err"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-merge-local.sh" "$id" >"$out" 2>"$err"
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "multi-pushurl: fm-merge-local.sh failed for a mixed local/hosted multi-pushurl origin: $(cat "$err")"
  [ ! -s "$push_log" ] || fail "multi-pushurl: git push was attempted against a remote with one hosted pushurl among several: $(cat "$push_log")"

  pass "one hosted URL among several configured pushurls disqualifies the whole remote from the sync"
}

test_local_mirror_origin_advances_to_match
test_local_mirror_origin_already_current_is_quiet
test_hosted_origin_is_never_pushed_to
test_local_fetch_hosted_pushurl_is_never_pushed_to
test_hosted_fetch_local_pushurl_still_syncs
test_no_pushurl_falls_back_to_fetch_url
test_multiple_pushurls_one_hosted_is_never_pushed_to
