#!/usr/bin/env bash
# shellcheck disable=SC2031,SC2100 # Sourced output globals and hyphenated fixture IDs are intentional.
# Exercise shared repository-subtree admission, recovery, relaunch, and release.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-repo-concurrency-lib.sh disable=SC1091
. "$ROOT/bin/fm-repo-concurrency-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh disable=SC1091
. "$ROOT/bin/fm-secondmate-parent-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-repo-concurrency)
PFM="$TMP_ROOT/project-firstmate"
REMOTE="$TMP_ROOT/alpha.origin.git"
REMOTE_ABS=
ORIGIN_URL=

fail() {
  echo "not ok - $*" >&2
  exit 1
}

mkdir -p "$PFM/data" "$PFM/state" "$PFM/config" "$PFM/projects"
fm_git_init_commit "$TMP_ROOT/alpha-source"
fm_git_add_origin "$TMP_ROOT/alpha-source" "$REMOTE"
REMOTE_ABS=$(cd "$REMOTE" && pwd -P)
ORIGIN_URL="file://$REMOTE_ABS"
git clone --quiet "$ORIGIN_URL" "$PFM/projects/alpha"
repo_hash=$(fm_repo_scope_clone_identity "$PFM/projects/alpha") \
  || fail "project Firstmate repository identity could not be normalized"
repo_identity="sha256:$repo_hash"
authority_hash=$(printf '%s' "$PFM"$'\n''alpha'$'\n'"$repo_identity" | shasum -a 256 | awk '{print $1}')
authority_id="sha256:$authority_hash"
printf 'schema=fm-project-firstmate.v1\nproject=alpha\nrepo_identity=%s\nauthority_id=%s\nrepo_path=%s/projects/alpha\n' \
  "$repo_identity" "$authority_id" "$PFM" > "$PFM/.fm-project-firstmate"
printf '2\n' > "$PFM/config/repo-concurrency"

if FM_HOME="$PFM" FM_SECONDMATE_CHARTER='remote child should fail closed' \
  "$ROOT/bin/fm-remote-home-seed.sh" remote-child example-host /remote/firstmate /remote/child alpha \
  > "$TMP_ROOT/remote-seed.out" 2> "$TMP_ROOT/remote-seed.err"; then
  fail "project Firstmate was allowed to create a remote descendant route"
fi
grep -F 'remote descendant routes beneath a project Firstmate are unsupported' "$TMP_ROOT/remote-seed.err" >/dev/null \
  || fail "remote descendant refusal did not explain the unavailable distributed lock"

for suffix in a b c; do
  child="$TMP_ROOT/child-$suffix"
  mkdir -p "$child/data" "$child/state" "$child/config" "$child/projects"
  printf 'child-%s\n' "$suffix" > "$child/.fm-secondmate-home"
  git clone --quiet "$ORIGIN_URL" "$child/projects/alpha"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\nparent_role=project-firstmate\nrepo_authority_home=%s\nrepo_authority_id=%s\nrepo_identity=%s\n' \
    "$PFM" "$PFM" "$authority_id" "$repo_identity" > "$child/.fm-secondmate-parent"
  printf -- '- child-%s - alpha child (home: %s; scope: alpha tasks; projects: alpha; added 2026-09-17)\n' \
    "$suffix" "$child" >> "$PFM/data/secondmates.md"
done

# An admitted lease is authoritative before spawn can publish task metadata.
# Sibling reconciliation must preserve that in-flight claim, or a third spawn
# can pass the shared limit during endpoint creation.
FM_HOME="$TMP_ROOT/child-a"
export FM_HOME
fm_repo_scope_acquire_task "$FM_HOME" provisional-a "$FM_HOME/projects/alpha" 0 \
  || fail "could not admit the delayed-metadata provisional task"
provisional_a_lease=$(fm_repo_scope_lease_path "$PFM" "$FM_HOME" provisional-a)
[ -f "$provisional_a_lease" ] || fail "delayed-metadata admission did not publish its lease"
capacity=$(fm_repo_scope_reconcile_task_home "$TMP_ROOT/child-b") \
  || fail "sibling reconciliation failed while a provisional claim had no metadata"
[ -f "$provisional_a_lease" ] \
  || fail "sibling reconciliation pruned an admitted lease before task metadata publication"
printf '%s\n' "$capacity" | grep -F 'active=1 limit=2 available=1' >/dev/null \
  || fail "sibling reconciliation did not count the delayed-metadata claim"
FM_HOME="$TMP_ROOT/child-b"
fm_repo_scope_acquire_task "$FM_HOME" provisional-b "$FM_HOME/projects/alpha" 0 \
  || fail "the second provisional task did not consume the last slot"
FM_HOME="$TMP_ROOT/child-c"
if fm_repo_scope_acquire_task "$FM_HOME" provisional-c "$FM_HOME/projects/alpha" 0; then
  fail "a third task was admitted while two provisional claims occupied the limit"
else
  [ "$?" -eq 2 ] || fail "third provisional task returned an unexpected admission error"
fi
FM_HOME="$TMP_ROOT/child-a"
fm_repo_scope_release_task "$FM_HOME" provisional-a || fail "could not release provisional task a"
FM_HOME="$TMP_ROOT/child-b"
fm_repo_scope_release_task "$FM_HOME" provisional-b || fail "could not release provisional task b"
abandoned_lease=$(fm_repo_scope_lease_path "$PFM" "$TMP_ROOT/child-a" abandoned-provisional)
mkdir -p "$(dirname "$abandoned_lease")"
printf 'schema=fm-repo-concurrency-lease.v1\nauthority_id=%s\nrepo_identity=%s\ntask_home=%s\ntask_id=abandoned-provisional\nclaim_pid=99999999\nclaim_identity=sha256:%064d\n' \
  "$authority_id" "$repo_identity" "$TMP_ROOT/child-a" 0 > "$abandoned_lease"
FM_HOME="$TMP_ROOT/child-b"
fm_repo_scope_reconcile_task_home "$FM_HOME" > "$TMP_ROOT/abandoned-reconcile.out" \
  2> "$TMP_ROOT/abandoned-reconcile.err" \
  || fail "reconciliation failed while recovering an abandoned provisional claim"
[ ! -e "$abandoned_lease" ] \
  || fail "reconciliation retained a provisional claim whose creator was proven gone"
grep -F 'REPO_CONCURRENCY: removed abandoned provisional lease' "$TMP_ROOT/abandoned-reconcile.err" >/dev/null \
  || fail "abandoned provisional claim recovery did not report its action"

# Task metadata honors the active home's state override, but the authority
# lock, limit, and leases stay under the authority home's ordinary paths so
# every child computes one shared namespace from durable parent bindings.
override_state="$TMP_ROOT/pfm-state-override"
mkdir -p "$override_state"
FM_HOME="$PFM" FM_STATE_OVERRIDE="$override_state"
export FM_HOME FM_STATE_OVERRIDE
fm_repo_scope_acquire_task "$PFM" override-task "$PFM/projects/alpha" 0 \
  || fail "authority-home state override blocked repository admission"
override_lease=$(fm_repo_scope_lease_path "$PFM" "$PFM" override-task)
[ -f "$override_lease" ] || fail "shared authority namespace did not receive the task lease"
case "$override_lease" in "$PFM/state/"*) ;; *) fail "lease followed a process-local override instead of the shared authority namespace" ;; esac
[ ! -e "$override_state/.repo-concurrency" ] \
  || fail "state override split the shared repository concurrency namespace"
printf 'kind=ship\nproject=%s/projects/alpha\n' "$PFM" > "$override_state/override-task.meta"
rm -f -- "$override_lease"
capacity=$(fm_repo_scope_reconcile_task_home "$PFM") \
  || fail "authority-home override reconciliation failed"
[ -f "$override_lease" ] \
  || fail "active-home metadata override was not scanned to repair the shared lease"
printf '%s\n' "$capacity" | grep -F 'active=1 limit=2 available=1' >/dev/null \
  || fail "authority-home override reconciliation lost its live lease"
rm -f -- "$override_state/override-task.meta"
fm_repo_scope_release_task "$PFM" override-task || fail "could not release the override-scoped lease"
unset FM_STATE_OVERRIDE
FM_HOME="$PFM"
export FM_HOME

attempt_task() {
  local suffix=$1 task_home="$TMP_ROOT/child-$1" task_id="task-$1" rc
  FM_HOME="$task_home" export FM_HOME
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$ROOT/bin/fm-wake-lib.sh"
  # shellcheck source=bin/fm-repo-concurrency-lib.sh disable=SC1091
  . "$ROOT/bin/fm-repo-concurrency-lib.sh"
  if fm_repo_scope_acquire_task "$task_home" "$task_id" "$task_home/projects/alpha" 0; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    [ "$FM_REPO_SCOPE_LOCK_HELD" = 0 ] || {
      printf 'error:admission retained the authority lock\n'
      return 1
    }
    printf 'kind=ship\nproject=%s/projects/alpha\n' "$task_home" > "$task_home/state/$task_id.meta"
    fm_repo_scope_lock_release || return 1
    printf 'admitted\n'
  elif [ "$rc" -eq 2 ]; then
    fm_repo_scope_lock_release || return 1
    printf 'queued\n'
  else
    fm_repo_scope_lock_release || true
    printf 'error:%s\n' "$FM_REPO_SCOPE_LAST_ERROR"
    return 1
  fi
}

attempt_task a > "$TMP_ROOT/a.result" 2> "$TMP_ROOT/a.err" & pid_a=$!
attempt_task b > "$TMP_ROOT/b.result" 2> "$TMP_ROOT/b.err" & pid_b=$!
attempt_task c > "$TMP_ROOT/c.result" 2> "$TMP_ROOT/c.err" & pid_c=$!
wait "$pid_a" || { cat "$TMP_ROOT/a.err" >&2; fail "sibling a admission process failed"; }
wait "$pid_b" || { cat "$TMP_ROOT/b.err" >&2; fail "sibling b admission process failed"; }
wait "$pid_c" || { cat "$TMP_ROOT/c.err" >&2; fail "sibling c admission process failed"; }
admitted=$(grep -l '^admitted$' "$TMP_ROOT"/*.result | wc -l | tr -d ' ')
queued=$(grep -l '^queued$' "$TMP_ROOT"/*.result | wc -l | tr -d ' ')
[ "$admitted" = 2 ] || fail "parallel sibling-home claims admitted $admitted tasks instead of 2"
[ "$queued" = 1 ] || fail "parallel sibling-home claims queued $queued tasks instead of 1"
queued_suffix=
for suffix in a b c; do
  [ "$(cat "$TMP_ROOT/$suffix.result")" = queued ] && queued_suffix=$suffix
done
[ -n "$queued_suffix" ] || fail "parallel admission did not identify a queued task"

FM_HOME="$PFM"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-repo-concurrency-lib.sh disable=SC1091
. "$ROOT/bin/fm-repo-concurrency-lib.sh"
identity_repo="$TMP_ROOT/identity-repo"
identity_remote="$TMP_ROOT/identity-origin.git"
mkdir -p "$TMP_ROOT/identity-origins"
fm_git_init_commit "$identity_repo"
identity_remote="$TMP_ROOT/identity-origins/alpha.git"
git -C "$identity_repo" remote add origin "$identity_remote"
path_identity=$(fm_repo_scope_canonical_origin_identity "$identity_repo") \
  || fail "plain file-path origin could not be normalized"
git -C "$identity_repo" remote set-url origin "file://$identity_remote"
file_identity=$(fm_repo_scope_canonical_origin_identity "$identity_repo") \
  || fail "file URL origin could not be normalized"
[ "$path_identity" = "$file_identity" ] \
  || fail "equivalent local path and file URL origins had different identities"
git -C "$identity_repo" remote set-url origin 'https://Example.COM/Owner/Repo.git'
https_identity=$(fm_repo_scope_canonical_origin_identity "$identity_repo") \
  || fail "HTTPS origin could not be normalized"
git -C "$identity_repo" remote set-url origin 'git@example.com:Owner/Repo.git'
ssh_identity=$(fm_repo_scope_canonical_origin_identity "$identity_repo") \
  || fail "SSH origin could not be normalized"
[ "$https_identity" = "$ssh_identity" ] \
  || fail "equivalent HTTPS and SSH origins had different identities"

local_root="$TMP_ROOT/local-root"
local_project="$local_root/projects/local-only"
mkdir -p "$local_root/data" "$local_root/state" "$local_root/projects"
fm_git_init_commit "$local_project"
printf -- '- alpha-pfm - project alpha (home: %s; scope: alpha; projects: alpha; added 2026-09-17)\n' "$PFM" \
  > "$local_root/data/secondmates.md"
FM_HOME="$local_root" FM_DATA_OVERRIDE="$local_root/data" FM_STATE_OVERRIDE="$local_root/state"
export FM_HOME FM_DATA_OVERRIDE FM_STATE_OVERRIDE
fm_repo_scope_root_route_guard "$local_root" "$local_project" \
  || fail "local-only project without an origin was refused by the root route guard: $FM_REPO_SCOPE_LAST_ERROR"
[ "$FM_REPO_SCOPE_ROOT_LOCK_HELD" = 0 ] \
  || fail "root route guard retained the secondmate registry lock after admitting local-only work"
[ ! -e "$local_root/state/.secondmates.lock" ] \
  || fail "root route guard left its registry lock on disk after admitting local-only work"
unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE
FM_HOME="$PFM"
export FM_HOME

alpha_identity=$(fm_repo_scope_canonical_origin_identity "$PFM/projects/alpha") \
  || fail "project Firstmate repository identity could not be normalized"

remote_home="$TMP_ROOT/attested-remote-home"
mkdir -p "$remote_home/data" "$remote_home/state" "$remote_home/projects"
printf 'remote-mate\n' > "$remote_home/.fm-secondmate-home"
git clone --quiet "$ORIGIN_URL" "$remote_home/projects/alpha"
printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-09-17)' > "$remote_home/data/projects.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nrepo_scope_snapshot=fm-remote-repo-scope.v1\nrepo_scope_count=1\nrepo_authority_count=1\nrepo_scope_identity=%s\nrepo_authority_identity=%s\n' \
  "sha256:$alpha_identity" "sha256:$alpha_identity" > "$remote_home/.fm-secondmate-parent"
if fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/alpha"; then
  fail "remote ordinary route bypassed a matching root project-authority identity"
fi
printf '%s\n' "$FM_REPO_SCOPE_LAST_ERROR" | grep -F 'owned by a root project Firstmate' >/dev/null \
  || fail "remote overlap refusal did not explain the project Firstmate route"

printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\n' > "$remote_home/.fm-secondmate-parent"
if fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/alpha"; then
  fail "remote ordinary route without an authority snapshot was allowed to spawn project work"
fi
printf '%s\n' "$FM_REPO_SCOPE_LAST_ERROR" | grep -F 'no verified repository-scope snapshot' >/dev/null \
  || fail "remote uncertainty refusal did not name the missing scope snapshot"

printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nrepo_scope_snapshot=fm-remote-repo-scope.v1\nrepo_scope_count=\nrepo_authority_count=0\n' \
  > "$remote_home/.fm-secondmate-parent"
if fm_secondmate_parent_record_parse "$remote_home/.fm-secondmate-parent" 2> "$TMP_ROOT/empty-count.err"; then
  fail "remote parent binding accepted an empty repository-scope count"
fi
[ ! -s "$TMP_ROOT/empty-count.err" ] \
  || fail "empty repository-scope count leaked a shell arithmetic diagnostic"

other_origin="$TMP_ROOT/other-origin.git"
fm_git_init_commit "$TMP_ROOT/other-source"
fm_git_add_origin "$TMP_ROOT/other-source" "$other_origin"
git clone --quiet "file://$(cd "$other_origin" && pwd -P)" "$remote_home/projects/other"
other_identity=$(fm_repo_scope_canonical_origin_identity "$remote_home/projects/other") \
  || fail "non-overlapping remote project identity could not be normalized"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nrepo_scope_snapshot=fm-remote-repo-scope.v1\nrepo_scope_count=1\nrepo_authority_count=1\nrepo_scope_identity=%s\nrepo_authority_identity=%s\n' \
  "sha256:$other_identity" "sha256:$alpha_identity" > "$remote_home/.fm-secondmate-parent"
if fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/alpha"; then
  fail "remote ordinary route allowed a target outside its attested clone scope"
fi
printf '%s\n' "$FM_REPO_SCOPE_LAST_ERROR" | grep -F 'outside the verified remote-home scope' >/dev/null \
  || fail "remote out-of-scope refusal did not report the stale or uncertain binding"
fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/other" \
  || fail "attested non-overlapping remote ordinary route was not preserved: $FM_REPO_SCOPE_LAST_ERROR"
sed 's/^repo_scope_count=1$/repo_scope_count=2/' "$remote_home/.fm-secondmate-parent" \
  > "$remote_home/.fm-secondmate-parent.tmp"
mv "$remote_home/.fm-secondmate-parent.tmp" "$remote_home/.fm-secondmate-parent"
if fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/other"; then
  fail "remote ordinary route accepted a malformed manually edited scope snapshot"
fi
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_role=root\nrepo_scope_snapshot=fm-remote-repo-scope.v1\nrepo_scope_count=2\nrepo_authority_count=0\nrepo_scope_identity=sha256:%s\nrepo_scope_identity=sha256:%s\n' \
  "$other_identity" "$other_identity" > "$remote_home/.fm-secondmate-parent"
if fm_repo_scope_root_route_guard "$remote_home" "$remote_home/projects/other"; then
  fail "remote ordinary route accepted duplicate repository identities in its attested snapshot"
fi

audit_root="$TMP_ROOT/remote-overlap-audit-root"
mkdir -p "$audit_root/data" "$audit_root/projects"
git clone --quiet "$ORIGIN_URL" "$audit_root/projects/alpha"
printf -- '- alpha-pfm - project alpha (home: %s; scope: alpha; projects: alpha; added 2026-09-17)\n' "$PFM" \
  > "$audit_root/data/secondmates.md"
printf -- '- legacy-remote - legacy remote (host: build; root: /srv/fm; home: /srv/legacy; scope: legacy; projects: legacy; added 2026-09-17)\n' \
  >> "$audit_root/data/secondmates.md"
printf -- '- remote-alpha - remote alpha (host: build; root: /srv/fm; home: /srv/alpha; scope: alpha; projects: alpha; repo-identities: alpha=sha256:%s; added 2026-09-17)\n' \
  "$alpha_identity" \
  >> "$audit_root/data/secondmates.md"
if fm_repo_scope_audit_remote_overlaps "$audit_root/data/secondmates.md"; then
  fail "bootstrap overlap audit accepted a manually registered remote/PFM ownership collision"
fi
printf '%s\n' "$FM_REPO_SCOPE_LAST_ERROR" | grep -F 'overlaps project Firstmate repository alpha' >/dev/null \
  || fail "bootstrap overlap audit did not identify the conflicting route"
printf '%s\n' "$FM_REPO_SCOPE_LAST_ERROR" | grep -F "remote ordinary route legacy-remote's repository identities" >/dev/null \
  || fail "bootstrap overlap audit hid an earlier legacy remote route"
mkdir -p "$audit_root/config" "$TMP_ROOT/bootstrap-home"
if audit_bootstrap=$(HOME="$TMP_ROOT/bootstrap-home" FM_HOME="$audit_root" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_LOCKED=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1); then
  :
else
  fail "bootstrap did not complete its manual-overlap audit: $audit_bootstrap"
fi
printf '%s\n' "$audit_bootstrap" | grep -F 'REPO_CONCURRENCY: remote repository ownership needs review:' >/dev/null \
  || fail "bootstrap did not surface manually registered remote/PFM overlap"
printf '%s\n' "$audit_bootstrap" | grep -F 'legacy-remote' >/dev/null \
  || fail "bootstrap did not name the legacy remote route requiring migration"
printf '%s\n' "$audit_bootstrap" | grep -F 'overlaps project Firstmate repository alpha' >/dev/null \
  || fail "bootstrap hid the later remote/PFM ownership collision"
limit=$(fm_repo_scope_limit "$PFM") || fail "configured repository limit was rejected"
[ "$limit" = 2 ] || fail "repository limit parser returned $limit instead of 2"
printf '2\n\n' > "$PFM/config/repo-concurrency"
if fm_repo_scope_limit "$PFM" >/dev/null; then
  fail "repository limit parser accepted more than one value"
fi
printf '2\n' > "$PFM/config/repo-concurrency"
capacity=$(fm_repo_scope_reconcile_task_home "$PFM") || fail "bootstrap-style lease reconciliation failed"
printf '%s\n' "$capacity" | grep -F 'active=2 limit=2 available=0' >/dev/null \
  || fail "capacity report did not show two active tasks at the shared limit"
mkdir -p "$TMP_ROOT/bootstrap-user"
if bootstrap_out=$(HOME="$TMP_ROOT/bootstrap-user" FM_HOME="$PFM" FM_ROOT_OVERRIDE="$ROOT" \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_LOCKED=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1); then
  :
else
  fail "project-home bootstrap failed before reporting repository capacity: $bootstrap_out"
fi
printf '%s\n' "$bootstrap_out" | grep -F 'REPO_CONCURRENCY: alpha active=2 limit=2 available=0' >/dev/null \
  || fail "project-home bootstrap did not print current repository capacity"

git -C "$PFM/projects/alpha" remote set-url origin "$REMOTE_ABS"
fm_repo_scope_validate_project "$PFM" "$PFM/projects/alpha" \
  || fail "equivalent origin spelling invalidated the stable repository authority: $FM_REPO_SCOPE_LAST_ERROR"
git -C "$PFM/projects/alpha" remote set-url origin "$ORIGIN_URL"

for suffix in a b c; do
  task_home="$TMP_ROOT/child-$suffix"
  task_id="task-$suffix"
  if [ -f "$task_home/state/$task_id.meta" ]; then
    if fm_repo_scope_acquire_task "$task_home" "$task_id" "$task_home/projects/alpha" 1; then
      fm_repo_scope_lock_release || fail "relaunch failed to release its authority lock"
    else
      fail "relaunch did not reuse its existing repository slot"
    fi
  fi
done
[ "$(find "$PFM/state/.repo-concurrency/leases" -type f -name '*.lease' | wc -l | tr -d ' ')" = 2 ] \
  || fail "relaunch consumed an additional repository slot"

released_suffix=
for suffix in a b c; do
  task_home="$TMP_ROOT/child-$suffix"
  task_id="task-$suffix"
  if [ -f "$task_home/state/$task_id.meta" ]; then
    rm -f -- "$task_home/state/$task_id.meta"
    fm_repo_scope_release_task "$task_home" "$task_id" || fail "teardown did not release an admitted slot"
    released_suffix=$suffix
    break
  fi
done
[ -n "$released_suffix" ] || fail "test fixture lost both admitted task records"
mv "$PFM/config/repo-concurrency" "$TMP_ROOT/repo-concurrency.limit"
limit=$(fm_repo_scope_limit "$PFM") || fail "absent project-local limit was rejected"
[ "$limit" = unlimited ] || fail "absent project-local limit did not select unlimited capacity"
mv "$TMP_ROOT/repo-concurrency.limit" "$PFM/config/repo-concurrency"
if attempt_task "$queued_suffix" > "$TMP_ROOT/retry.result" 2> "$TMP_ROOT/retry.err"; then :; else fail "queued task retry failed"; fi
[ "$(cat "$TMP_ROOT/retry.result")" = admitted ] || fail "queued task did not acquire the released slot"

stale_suffix=$released_suffix
stale_home="$TMP_ROOT/child-$stale_suffix"
stale_id="task-$stale_suffix"
stale_lease=$(fm_repo_scope_lease_path "$PFM" "$stale_home" "$stale_id")
[ ! -e "$stale_lease" ] || fail "teardown left its released task lease behind"

missing_suffix=
for suffix in a b c; do
  task_home="$TMP_ROOT/child-$suffix"
  task_id="task-$suffix"
  if [ -f "$task_home/state/$task_id.meta" ] && [ "$suffix" != "$queued_suffix" ]; then
    missing_suffix=$suffix
    missing_home=$task_home
    missing_id=$task_id
    break
  fi
done
[ -n "$missing_suffix" ] || fail "test fixture has no active task left for repair coverage"
missing_lease=$(fm_repo_scope_lease_path "$PFM" "$missing_home" "$missing_id")
rm -f -- "$missing_lease"
capacity=$(fm_repo_scope_reconcile_task_home "$PFM") || fail "missing-lease repair failed"
[ -f "$missing_lease" ] || fail "bootstrap-style repair did not restore a missing active-task lease"
printf '%s\n' "$capacity" | grep -F 'active=2 limit=2 available=0' >/dev/null \
  || fail "repaired capacity report did not restore the correct active count"

printf -- '- retired-child - retired alpha child (home: %s; scope: alpha tasks; projects: alpha; added 2026-09-17)\n' \
  "$TMP_ROOT/retired-child" >> "$PFM/data/secondmates.md"
capacity=$(fm_repo_scope_reconcile_task_home "$PFM") \
  || fail "a registry entry whose retired child home is already absent wedged reconciliation"
printf '%s\n' "$capacity" | grep -F 'active=2 limit=2 available=0' >/dev/null \
  || fail "absent retired child changed repository capacity"

orphan_home="$TMP_ROOT/unregistered-live-home"
mkdir -p "$orphan_home/state"
orphan_lease=$(fm_repo_scope_lease_path "$PFM" "$orphan_home" orphan-task)
mkdir -p "$(dirname "$orphan_lease")"
printf 'schema=fm-repo-concurrency-lease.v1\nauthority_id=%s\nrepo_identity=%s\ntask_home=%s\ntask_id=orphan-task\n' \
  "$authority_id" "$repo_identity" "$orphan_home" > "$orphan_lease"
capacity=$(fm_repo_scope_reconcile_task_home "$PFM" 2> "$TMP_ROOT/orphan-reconcile.err") \
  || fail "an orphan lease for an unregistered existing home wedged reconciliation"
[ ! -e "$orphan_lease" ] || fail "reconciliation retained an orphan lease for an unregistered home"
grep -F 'REPO_CONCURRENCY: removed stale lease for unregistered task home' "$TMP_ROOT/orphan-reconcile.err" >/dev/null \
  || fail "orphan lease repair did not emit its actionable diagnostic"

spawn_home="$TMP_ROOT/child-$queued_suffix"
spawn_id=spawn-denied
fm_test_spawn_home "$spawn_home" codex
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' \
  > "$spawn_home/.tasks.toml"
fm_test_spawn_brief "$spawn_home" "$spawn_id" "work that should remain queued"
TASKS_AXI_BACKEND=markdown tasks-axi add "$spawn_id" "capacity refusal stays queued" \
  --kind scout --file "$spawn_home/data/backlog.md" >/dev/null \
  || fail "could not seed a queued backlog row for the spawn admission test"
before_backlog=$(cksum "$spawn_home/data/backlog.md")
before_brief=$(cksum "$spawn_home/data/$spawn_id/brief.md")
before_data_files=$(find "$spawn_home/data/$spawn_id" -type f -print | sort)
before_project_entries=$(find "$spawn_home/projects" -mindepth 1 -maxdepth 1 -print | sort)
before_worktrees=$(git -C "$spawn_home/projects/alpha" worktree list --porcelain)
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-admission-fake" codex)
launch_log="$TMP_ROOT/spawn-admission.launch"
: > "$launch_log"
if output=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$spawn_home" "$spawn_home/projects/alpha" "$fakebin" \
      "$spawn_id" "$spawn_home/projects/alpha" --scout); then
  fail "real fm-spawn admitted a task over the subtree limit"
else
  status=$?
fi
[ "$status" = 2 ] || fail "capacity refusal returned status $status instead of the queue status 2"
printf '%s\n' "$output" | grep -F 'queued: repository subtree has 2 active ship/scout tasks' >/dev/null \
  || fail "real spawn did not explain its queue-capacity refusal"
[ ! -e "$spawn_home/state/$spawn_id.meta" ] || fail "capacity refusal published task metadata"
[ ! -e "$spawn_home/data/$spawn_id/launch-brief.md" ] \
  || fail "capacity refusal published the launch-brief overlay"
[ "$(find "$spawn_home/data/$spawn_id" -type f -print | sort)" = "$before_data_files" ] \
  || fail "capacity refusal changed files in the task data directory"
[ "$(cksum "$spawn_home/data/$spawn_id/brief.md")" = "$before_brief" ] \
  || fail "capacity refusal changed the source task brief"
[ "$(find "$spawn_home/projects" -mindepth 1 -maxdepth 1 -print | sort)" = "$before_project_entries" ] \
  || fail "capacity refusal changed the home project/worktree entries"
[ "$(git -C "$spawn_home/projects/alpha" worktree list --porcelain)" = "$before_worktrees" ] \
  || fail "capacity refusal created or removed a repository worktree"
[ ! -s "$launch_log" ] || fail "capacity refusal created an endpoint or delivered a worker launch"
[ "$(cksum "$spawn_home/data/backlog.md")" = "$before_backlog" ] \
  || fail "capacity refusal changed the queued backlog row"

for suffix in a b c; do
  admitted_home="$TMP_ROOT/child-$suffix"
  admitted_id="task-$suffix"
  if [ -f "$admitted_home/state/$admitted_id.meta" ]; then
    rm -f -- "$admitted_home/state/$admitted_id.meta"
    fm_repo_scope_release_task "$admitted_home" "$admitted_id" \
      || fail "could not free capacity for the provisional-claim cleanup test"
    break
  fi
done
failed_id=endpoint-failure
fm_test_spawn_brief "$spawn_home" "$failed_id" "endpoint launch should release its provisional claim"
TASKS_AXI_BACKEND=markdown tasks-axi add "$failed_id" "endpoint failure releases repository claim" \
  --kind scout --file "$spawn_home/data/backlog.md" >/dev/null \
  || fail "could not seed the endpoint-failure backlog row"
failed_lease=$(fm_repo_scope_lease_path "$PFM" "$spawn_home" "$failed_id")
if FM_FAKE_TMUX_NEW_WINDOW_FAIL=1 \
    fm_test_run_spawn "$spawn_home" "$spawn_home/projects/alpha" "$fakebin" \
      "$failed_id" "$spawn_home/projects/alpha" --scout \
      > "$TMP_ROOT/endpoint-failure.out" 2> "$TMP_ROOT/endpoint-failure.err"; then
  fail "spawn unexpectedly survived a forced endpoint-creation failure"
fi
[ ! -e "$spawn_home/state/$failed_id.meta" ] \
  || fail "failed endpoint creation published task metadata"
[ ! -e "$failed_lease" ] \
  || fail "failed endpoint creation leaked its provisional repository claim"

external_home="$TMP_ROOT/external/alpha"
mkdir -p "$(dirname "$external_home")"
git clone --quiet "$ORIGIN_URL" "$external_home"
external_id=external-clone-refusal
fm_test_spawn_brief "$spawn_home" "$external_id" "reject an external clone alias"
TASKS_AXI_BACKEND=markdown tasks-axi add "$external_id" "external clone path refusal" \
  --kind scout --file "$spawn_home/data/backlog.md" >/dev/null \
  || fail "could not seed the external clone-path refusal backlog row"
before_backlog=$(cksum "$spawn_home/data/backlog.md")
before_brief=$(cksum "$spawn_home/data/$external_id/brief.md")
before_worktrees=$(git -C "$spawn_home/projects/alpha" worktree list --porcelain)
launch_log="$TMP_ROOT/external-clone-refusal.launch"
: > "$launch_log"
if output=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    fm_test_run_spawn "$spawn_home" "$external_home" "$fakebin" \
      "$external_id" "$external_home" --scout); then
  fail "real fm-spawn accepted an external same-origin clone alias"
else
  status=$?
fi
[ "$status" = 1 ] || fail "external clone-path refusal returned status $status instead of 1"
printf '%s\n' "$output" | grep -F "task project path must be the task home's canonical owned clone" >/dev/null \
  || fail "external clone-path refusal did not explain the home-owned clone requirement"
[ ! -e "$spawn_home/state/$external_id.meta" ] || fail "external clone-path refusal published task metadata"
[ ! -e "$spawn_home/data/$external_id/launch-brief.md" ] || fail "external clone-path refusal published a launch overlay"
[ ! -s "$launch_log" ] || fail "external clone-path refusal created an endpoint"
[ "$(git -C "$spawn_home/projects/alpha" worktree list --porcelain)" = "$before_worktrees" ] \
  || fail "external clone-path refusal created or removed a repository worktree"
[ "$(cksum "$spawn_home/data/$external_id/brief.md")" = "$before_brief" ] \
  || fail "external clone-path refusal changed the source brief"
[ "$(cksum "$spawn_home/data/backlog.md")" = "$before_backlog" ] \
  || fail "external clone-path refusal changed the backlog"
echo "ok - repository subtree capacity serializes sibling homes, repairs leases, reuses relaunch claims, and releases on teardown"
