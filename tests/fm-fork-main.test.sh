#!/usr/bin/env bash
# Behavior tests for permanent fork-main integration.
#
# These fixtures use real local Git repositories to prove the load-bearing
# properties without touching the live fork, its remotes, secondmate homes, or
# no-mistakes service:
#   - explicit and reversible origin=fork/upstream=official topology;
#   - startup probes upstream only from a validated topology, and reports a
#     half-migrated one loudly on every startup instead of skipping it;
#   - rerere enabled with autoupdate off and inherited by standalone homes;
#   - self-update stays fast-forward-only while reporting a separate upstream
#     integration need;
#   - git-cherry-backed divergence health survives changed commit identity and
#     fails on manifest drift;
#   - an upstream-accepted divergence retires with re-provable Git evidence that
#     outlives the merge which made git cherry blind to it;
#   - upstream merges are prepared only in isolated candidates, preserve live
#     origin/main on conflicts, require per-unit re-justification, and reuse a
#     recorded resolution without staging it;
#   - fork-target no-mistakes setup proves the ordinary registration unchanged;
#   - fork divergence briefs can branch explicitly from upstream/main.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fork-main)
REMOTES="$ROOT/bin/fm-fork-remotes.sh"
STATUS="$ROOT/bin/fm-fork-status.sh"
MERGE="$ROOT/bin/fm-fork-merge.sh"
TOPIC="$ROOT/bin/fm-fork-topic.sh"
INTEGRATION="$ROOT/bin/fm-fork-integration.sh"
UPDATE="$ROOT/bin/fm-update.sh"
REMOTE_PROVISION="$ROOT/bin/fm-remote-home-provision.sh"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

new_world() { # <name>
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"
  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/upstream.git" "$w/seed" 2>/dev/null
  git -C "$w/seed" config commit.gpgsign false
  printf 'base\n' > "$w/seed/base.txt"
  cp "$ROOT/fork-divergences.json" "$w/seed/fork-divergences.json"
  git -C "$w/seed" add .
  git -C "$w/seed" commit -qm base
  git -C "$w/seed" push -q origin main
  git clone -q --bare "$w/upstream.git" "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  printf '%s\n' "$w"
}

configure_fork_clone() { # <repo> <world>
  local repo=$1 w=$2
  git -C "$repo" remote add upstream "$w/upstream.git"
  git -C "$repo" config branch.main.remote origin
  git -C "$repo" config branch.main.merge refs/heads/main
  git -C "$repo" config rerere.enabled true
  git -C "$repo" config rerere.autoupdate false
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" fetch -q upstream
  git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$repo" remote set-head upstream main >/dev/null 2>&1 || true
}

add_topic_and_merge() { # <world> <id> <path> <content> [class]
  local w=$1 id=$2 path=$3 content=$4 class=${5:-pending} repo pr
  repo="$w/admin"
  if [ ! -d "$repo/.git" ]; then
    git clone -q "$w/fork.git" "$repo"
    configure_fork_clone "$repo" "$w"
  fi
  git -C "$repo" fetch -q origin
  git -C "$repo" fetch -q upstream
  git -C "$repo" switch -qC "fm/divergence/$id" upstream/main
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -qm "topic $id"
  git -C "$repo" push -q origin "fm/divergence/$id"
  git -C "$repo" switch -qC main origin/main
  git -C "$repo" merge --no-ff --no-commit "fm/divergence/$id" >/dev/null
  pr="https://github.com/example/firstmate/pull/1"
  tmp="$w/manifest.$id"
  jq --arg id "$id" --arg class "$class" --arg path "$path" --arg pr "$pr" '
    .divergences += [{id:$id,summary:("Carries " + $id + " behavior."),class:$class,topic:("fm/divergence/" + $id),introduced:"2026-08-08",upstream_pr:(if $class == "private" then null else {url:$pr,disposition:"open"} end),retire_when:("Upstream ships equivalent " + $id + " behavior."),paths:[$path]}]
  ' "$repo/fork-divergences.json" > "$tmp" || fail "could not build manifest fixture"
  mv "$tmp" "$repo/fork-divergences.json"
  git -C "$repo" add fork-divergences.json
  git -C "$repo" commit -qm "merge divergence $id"
  git -C "$repo" push -q origin main
}

advance_upstream() { # <world> <path> <content> <message>
  local w=$1 path=$2 content=$3 message=$4
  git -C "$w/seed" pull -q --ff-only origin main
  mkdir -p "$(dirname "$w/seed/$path")"
  printf '%s\n' "$content" > "$w/seed/$path"
  git -C "$w/seed" add -- "$path"
  git -C "$w/seed" commit -qm "$message"
  git -C "$w/seed" push -q origin main
}

new_candidate() { # <world> <name>; prints path
  local w name repo candidate
  w=$1
  name=$2
  repo="$w/integration"
  candidate="$w/$name"
  if [ ! -d "$repo/.git" ]; then
    git clone -q "$w/fork.git" "$repo"
    configure_fork_clone "$repo" "$w"
  fi
  git -C "$repo" fetch -q origin
  git -C "$repo" fetch -q upstream
  git -C "$repo" worktree add -q --detach "$candidate" origin/main
  git -C "$candidate" switch -qc "fm/$name"
  printf '%s\n' "$candidate"
}

bootstrap_network_only() { # <repo> <home>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$2" FM_BOOTSTRAP_NETWORK=only \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

# Startup probes official upstream only from a fully validated fork-main
# primary, but a home part-way through the explicit migration must not go quiet:
# it names the first missing requirement on every startup, runs no probe, and
# writes no daily marker, so it stays loud until it is finished or reversed. A
# home with no upstream remote at all is classic single-origin and stays silent.
test_startup_upstream_probe_requires_validated_topology() {
  local w repo home marker out second classic classic_home
  w=$(new_world startup-probe)
  repo="$w/primary"
  home="$w/home"
  marker="$home/state/.fork-upstream-check"
  mkdir -p "$home/state" "$home/data"
  git clone -q "$w/fork.git" "$repo"
  git -C "$repo" config commit.gpgsign false
  # A tracked bin/ is what makes this checkout a firstmate home to bootstrap.
  ln -s "$ROOT/bin" "$repo/bin"

  # Half-migrated: `gh repo fork --remote` left origin=fork and upstream=parent,
  # but the confirmed apply that configures reviewable rerere never ran.
  git -C "$repo" remote add upstream "$w/upstream.git"
  git -C "$repo" fetch -q upstream
  out=$(bootstrap_network_only "$repo" "$home")
  assert_contains "$out" "UPSTREAM_SYNC: fork topology is not validated: rerere.enabled is not true" \
    "a half-migrated home did not name its first missing requirement"
  assert_not_contains "$out" "upstream-integration" "the upstream movement probe ran on an unvalidated topology"
  [ ! -e "$marker" ] || fail "an unvalidated topology published a successful daily-check marker"
  second=$(bootstrap_network_only "$repo" "$home")
  assert_contains "$second" "UPSTREAM_SYNC: fork topology is not validated:" \
    "the half-migrated home went quiet on the next startup"

  # Completing the topology restores the ordinary probe and its daily marker.
  git -C "$repo" config rerere.enabled true
  git -C "$repo" config rerere.autoupdate false
  advance_upstream "$w" startup-probe.txt moved startup-probe-moved
  out=$(bootstrap_network_only "$repo" "$home")
  assert_not_contains "$out" "fork topology is not validated" "a validated topology was still reported as unvalidated"
  assert_contains "$out" "UPSTREAM_SYNC: required" "a validated primary did not report the needed upstream integration"
  [ -f "$marker" ] || fail "a successful check did not publish its daily-check marker"

  # Classic single-origin homes never learn about any of this.
  classic="$w/classic"
  classic_home="$w/classic-home"
  mkdir -p "$classic_home/state" "$classic_home/data"
  git clone -q "$w/upstream.git" "$classic"
  ln -s "$ROOT/bin" "$classic/bin"
  out=$(bootstrap_network_only "$classic" "$classic_home")
  assert_not_contains "$out" "UPSTREAM_SYNC" "a classic single-origin home was given fork-main output"
  pass "bootstrap: the upstream probe is gated on validated topology and never silently skipped"
}

# Topology migration is explicit, prints its reverse before mutation, enables
# reviewable rerere, and restores upstream origin without moving commits.
test_remote_topology_is_explicit_and_reversible() {
  local w repo repo_fail out before fakebin log rc
  w=$(new_world remotes)
  repo="$w/repo"
  git clone -q "$w/upstream.git" "$repo"
  before=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" config remote.origin.pushurl "$w/fork.git"
  fakebin="$w/fakebin"
  log="$w/no-mistakes-status.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 2
printf 'status\n' >> "${FAKE_NM_LOG:?}"
count=$(wc -l < "$FAKE_NM_LOG" | tr -d ' ')
if [ "${FAKE_NM_BAD_AFTER_FIRST:-0}" = 1 ] && [ "$count" -gt 1 ]; then
  printf 'remote: changed-registration\n'
else
  printf 'remote: %s\n' "${FAKE_UPSTREAM:?}"
fi
printf 'fork: %s\n' "${FAKE_FORK:?}"
SH
  chmod +x "$fakebin/no-mistakes"

  out=$(FM_ROOT_OVERRIDE="$ROOT" "$REMOTES" plan "$w/fork.git" "$w/upstream.git" "$repo")
  assert_contains "$out" "reverse-command:" "plan did not print the reverse command"
  [ "$(git -C "$repo" remote get-url origin)" = "$w/upstream.git" ] || fail "read-only plan changed origin"
  if FM_ROOT_OVERRIDE="$ROOT" "$REMOTES" apply "$w/fork.git" "$w/upstream.git" nope "$repo" >/dev/null 2>&1; then
    fail "apply accepted migration without --confirm"
  fi
  [ "$(git -C "$repo" remote get-url origin)" = "$w/upstream.git" ] || fail "refused apply changed origin"

  out=$(PATH="$fakebin:$PATH" FAKE_NM_LOG="$log" FAKE_UPSTREAM="$w/upstream.git" FAKE_FORK="$w/fork.git" \
    FM_ROOT_OVERRIDE="$ROOT" "$REMOTES" apply "$w/fork.git" "$w/upstream.git" --confirm "$repo") \
    || fail "confirmed topology migration failed"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 2 ] || fail "migration did not prove ordinary registration before and after"
  assert_contains "$out" "reverse-command:" "apply did not print reverse command before completion"
  [ "$(git -C "$repo" remote get-url origin)" = "$w/fork.git" ] || fail "fork is not origin"
  [ "$(git -C "$repo" remote get-url --push origin)" = "$w/fork.git" ] || fail "fork push URL differs from fork fetch URL"
  [ "$(git -C "$repo" remote get-url upstream)" = "$w/upstream.git" ] || fail "official repository is not upstream"
  [ "$(git -C "$repo" remote get-url --push upstream)" = "$w/upstream.git" ] || fail "upstream inherited the old origin push target"
  [ "$(git -C "$repo" config --type=bool --get rerere.enabled)" = true ] || fail "rerere was not enabled"
  [ "$(git -C "$repo" config --type=bool --get rerere.autoupdate)" = false ] || fail "rerere autoupdate was not disabled"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail "remote migration moved HEAD"

  "$REMOTES" reverse "$w/fork.git" "$w/upstream.git" --confirm "$repo" >/dev/null \
    || fail "reverse migration failed"
  [ "$(git -C "$repo" remote get-url origin)" = "$w/upstream.git" ] || fail "reverse did not restore official origin"
  [ "$(git -C "$repo" remote get-url --push origin)" = "$w/upstream.git" ] || fail "reverse did not restore the official push URL"
  [ "$(git -C "$repo" remote get-url fork)" = "$w/fork.git" ] || fail "reverse did not retain fork remote"
  [ "$(git -C "$repo" remote get-url --push fork)" = "$w/fork.git" ] || fail "reverse did not retain the fork push URL"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail "reverse moved HEAD"

  repo_fail="$w/repo-fail"
  git clone -q "$w/upstream.git" "$repo_fail"
  : > "$log"
  set +e
  out=$(PATH="$fakebin:$PATH" FAKE_NM_LOG="$log" FAKE_NM_BAD_AFTER_FIRST=1 \
    FAKE_UPSTREAM="$w/upstream.git" FAKE_FORK="$w/fork.git" FM_ROOT_OVERRIDE="$ROOT" \
    "$REMOTES" apply "$w/fork.git" "$w/upstream.git" --confirm "$repo_fail" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "migration accepted a changed ordinary registration"
  assert_contains "$out" "registration remote is 'changed-registration'" "post-migration registration refusal was unclear"
  [ "$(git -C "$repo_fail" remote get-url origin)" = "$w/upstream.git" ] || fail "failed registration proof did not restore official origin"
  [ -z "$(git -C "$repo_fail" remote get-url upstream 2>/dev/null || true)" ] || fail "failed registration proof left a partial upstream remote"
  pass "fork remotes: migration is explicit, reviewable, and history-preserving reversible"
}

# Standalone homes inherit exact remote policy while linked worktrees share it;
# an unrelated target is never overwritten.
test_remote_topology_inheritance_refuses_unrelated_clones() {
  local w source standalone linked unrelated before out
  w=$(new_world inherit)
  source="$w/source"
  standalone="$w/standalone"
  git clone -q "$w/fork.git" "$source"
  configure_fork_clone "$source" "$w"
  git clone -q "$source" "$standalone"
  git -C "$standalone" config remote.origin.pushurl "$w/upstream.git"
  "$REMOTES" inherit "$source" "$standalone" >/dev/null || fail "standalone inheritance failed"
  [ "$(git -C "$standalone" remote get-url origin)" = "$w/fork.git" ] || fail "standalone origin did not inherit fork"
  [ "$(git -C "$standalone" remote get-url upstream)" = "$w/upstream.git" ] || fail "standalone upstream did not inherit official"
  [ "$(git -C "$standalone" remote get-url --push origin)" = "$w/fork.git" ] || fail "standalone retained a mismatched push URL"
  [ "$(git -C "$standalone" config --get-all remote.upstream.fetch)" = "$(git -C "$source" config --get-all remote.upstream.fetch)" ] \
    || fail "standalone did not inherit the upstream fetch refspec"
  [ "$(git -C "$standalone" symbolic-ref refs/remotes/upstream/HEAD)" = "$(git -C "$source" symbolic-ref refs/remotes/upstream/HEAD)" ] \
    || fail "standalone did not inherit the upstream remote HEAD"
  [ "$(git -C "$standalone" config --type=bool --get rerere.autoupdate)" = false ] || fail "standalone enabled rerere autoupdate"

  linked="$w/linked"
  git -C "$source" worktree add -q --detach "$linked" main
  out=$("$REMOTES" inherit "$source" "$linked") || fail "linked inheritance failed"
  assert_contains "$out" "already shares" "linked worktree did not use shared-config no-op"

  git clone -q "$w/upstream.git" "$w/other-source"
  git init -q --bare "$w/unrelated.git"
  unrelated="$w/unrelated"
  git clone -q "$w/unrelated.git" "$unrelated" 2>/dev/null
  before=$(git -C "$unrelated" remote get-url origin)
  if "$REMOTES" inherit "$source" "$unrelated" >/dev/null 2>&1; then
    fail "inherit overwrote an unrelated target"
  fi
  [ "$(git -C "$unrelated" remote get-url origin)" = "$before" ] || fail "refused inheritance changed unrelated origin"

  git clone -q "$source" "$w/rollback-target"
  before=$(git -C "$w/rollback-target" config --local --list | sort)
  git -C "$source" config --unset-all remote.upstream.fetch
  if "$REMOTES" inherit "$source" "$w/rollback-target" >/dev/null 2>&1; then
    fail "inherit accepted a source without an upstream fetch refspec"
  fi
  [ "$(git -C "$w/rollback-target" config --local --list | sort)" = "$before" ] \
    || fail "failed inheritance left partial target Git configuration"
  pass "fork remotes: standalone and linked homes converge without overwriting unrelated clones"
}

# Remote provisioning carries the primary-approved URLs to an official-origin
# code root, prints its reversal, and makes both the root and persistent home
# consume fork main without touching a real host.
test_remote_provisioning_inherits_fork_topology() {
  local w root home manifest out
  w=$(new_world remote-provision)
  w=$(cd "$w" && pwd -P)
  root="$w/remote-root"
  home="$w/remote-home"
  manifest="$w/manifest"
  git clone -q "$w/upstream.git" "$root"
  cat > "$manifest" <<EOF
schema=fm-remote-home-provision.v1
id_b64=$(b64 remote)
charter_b64=$(b64 'Remote charter')
parent_host_b64=$(b64 remote-host)
firstmate_fork_b64=$(b64 "$w/fork.git")
firstmate_upstream_b64=$(b64 "$w/upstream.git")
project_count=0
EOF
  out=$(FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$REMOTE_PROVISION" < "$manifest" 2>&1) \
    || fail "remote fork topology provisioning failed: $out"
  assert_contains "$out" "reverse-command:" "remote code-root migration did not print its reverse command"
  [ "$(git -C "$root" remote get-url origin)" = "$w/fork.git" ] || fail "remote code root did not adopt fork origin"
  [ "$(git -C "$root" remote get-url upstream)" = "$w/upstream.git" ] || fail "remote code root did not retain official upstream"
  [ "$(git -C "$home" remote get-url origin)" = "$w/fork.git" ] || fail "remote persistent home did not inherit fork origin"
  [ "$(git -C "$home" remote get-url upstream)" = "$w/upstream.git" ] || fail "remote persistent home did not inherit official upstream"
  [ "$(git -C "$home" config --type=bool --get rerere.autoupdate)" = false ] || fail "remote persistent home enabled rerere autoupdate"
  pass "fork remotes: remote roots and homes inherit primary-approved topology"
}

# Firstmate divergence topics branch from upstream explicitly, while malformed
# refs and use on scouts are refused.
test_brief_supports_explicit_upstream_start_ref() {
  local home brief out rc
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" fork-topic firstmate --mode no-mistakes --start-ref upstream/main >/dev/null \
    || fail "ship brief refused upstream start ref"
  brief="$home/data/fork-topic/brief.md"
  assert_grep 'git checkout -b fm/fork-topic upstream/main' "$brief" "brief did not branch from upstream/main"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bad-ref firstmate --mode no-mistakes --start-ref 'upstream/main;rm' 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "brief accepted unsafe start ref"
  assert_contains "$out" "not a safe Git ref" "unsafe start ref refusal was unclear"
  set +e
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" scout-ref firstmate --scout --start-ref upstream/main 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "scout accepted ship-only start ref"
  assert_contains "$out" "applies only to ship briefs" "scout start-ref refusal was unclear"
  pass "fm-brief: fork topics use one explicit upstream start ref"
}

# Live homes only consume validated fork origin. Upstream movement is reported as
# separate merge work and never changes local main or creates a merge commit.
test_self_update_stays_fast_forward_only() {
  local w repo home out fork_tip before
  w=$(new_world update)
  repo="$w/repo"
  home="$w/home"
  mkdir -p "$home/state" "$home/data"
  touch "$home/state/.last-watcher-beat"
  git clone -q "$w/fork.git" "$repo"
  configure_fork_clone "$repo" "$w"

  git clone -q "$w/fork.git" "$w/fork-work"
  git -C "$w/fork-work" config commit.gpgsign false
  printf 'fork-only\n' > "$w/fork-work/fork.txt"
  git -C "$w/fork-work" add fork.txt
  git -C "$w/fork-work" commit -qm fork-only
  git -C "$w/fork-work" push -q origin main
  fork_tip=$(git -C "$w/fork.git" rev-parse main)

  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" "$UPDATE" 2>/dev/null)
  assert_contains "$out" "firstmate: updated" "self-update did not fast-forward from fork origin"
  assert_contains "$out" "upstream-integration: current" "fork-ahead state was not treated as normal"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$fork_tip" ] || fail "self-update did not land on fork tip"
  [ "$(git -C "$repo" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] || fail "self-update created a merge commit"

  advance_upstream "$w" upstream.txt upstream upstream-moved
  before=$(git -C "$repo" rev-parse HEAD)
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" "$UPDATE" 2>/dev/null)
  assert_contains "$out" "upstream-integration: required" "upstream movement did not request isolated validation"
  [ "$(git -C "$repo" rev-parse HEAD)" = "$before" ] || fail "self-update merged upstream into the live checkout"
  pass "fm-update: homes remain fast-forward-only and upstream integration is separate"
}

# A topic based on newer official upstream must not smuggle those unvalidated
# upstream commits into fork main through its second parent.
test_topic_waits_for_validated_upstream() {
  local w repo candidate before out rc
  w=$(new_world topic-upstream-order)
  advance_upstream "$w" upstream-api.txt api upstream-api
  repo="$w/topic-work"
  git clone -q "$w/fork.git" "$repo"
  configure_fork_clone "$repo" "$w"
  git -C "$repo" switch -qc fm/divergence/new-api upstream/main
  printf 'topic\n' > "$repo/topic.txt"
  git -C "$repo" add topic.txt
  git -C "$repo" commit -qm topic
  git -C "$repo" push -q origin fm/divergence/new-api
  candidate=$(new_candidate "$w" topic-before-upstream)
  before=$(git -C "$candidate" rev-parse HEAD)
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" integrate --repo "$candidate" --id new-api \
    --summary 'Adds new API behavior.' --class pending --topic fm/divergence/new-api \
    --retire-when 'Upstream ships equivalent new API behavior.' --path topic.txt \
    --pr-url https://github.com/example/firstmate/pull/12 --pr-disposition open 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "topic integrated unvalidated upstream commits"
  assert_contains "$out" "upstream must be integrated and validated" "topic/upstream ordering refusal was unclear"
  [ "$(git -C "$candidate" rev-parse HEAD)" = "$before" ] || fail "refused topic integration moved candidate HEAD"
  [ -z "$(git -C "$candidate" rev-parse --verify --quiet MERGE_HEAD 2>/dev/null || true)" ] || fail "refused topic integration left a merge active"
  pass "fork topics: validated upstream must land before a newer divergence topic"
}

# The status surface groups git-cherry facts into manifest units, recognizes a
# changed-ID equivalent patch, and refuses an unmanifested carried patch.
test_health_uses_git_cherry_equivalence_and_exposes_drift() {
  local w repo out rc
  w=$(new_world health)
  add_topic_and_merge "$w" probe feature.txt enabled
  repo="$w/admin"
  out=$("$STATUS" --repo "$repo") || fail "healthy divergence report failed: $out"
  assert_contains "$out" "retained=1 patches=1" "health did not count the named divergence"
  assert_contains "$out" "retire when:" "health omitted falsifiable retirement condition"

  # Same patch, different commit identity and parent history. git cherry marks
  # the fork topic equivalent even though no SHA is shared.
  advance_upstream "$w" feature.txt enabled upstream-squash-equivalent
  git -C "$repo" fetch -q upstream
  set +e
  out=$("$STATUS" --repo "$repo" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "accepted equivalent patch left a stale active manifest healthy"
  assert_contains "$out" "retained=0 patches=0" "git cherry did not recognize equivalent upstream patch"
  assert_contains "$out" "owns no non-equivalent patch" "stale manifest entry was not surfaced"

  # Add another fork-only patch without a manifest unit. The factual patch must
  # remain visible even though prose does not explain it.
  git -C "$repo" switch -qc stray upstream/main
  printf 'stray\n' > "$repo/stray.txt"
  git -C "$repo" add stray.txt
  git -C "$repo" commit -qm stray
  git -C "$repo" switch -q main
  git -C "$repo" merge --no-ff -m stray stray >/dev/null
  git -C "$repo" push -q origin main
  set +e
  out=$("$STATUS" --repo "$repo" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unowned patch reported healthy"
  assert_contains "$out" "unowned non-equivalent patch" "manifest drift did not name the factual patch"
  pass "fork health: diff equivalence survives changed IDs and Git facts outrank stale manifest"
}

# Two canonical topics integrate as separate merge units, and discarding one
# reverts only its merge while preserving its neighbor.
test_topics_are_independently_revertible_units() {
  local w candidate out beta_merge rc
  w=$(new_world topic-units)
  admin="$w/admin"
  git clone -q "$w/fork.git" "$admin"
  configure_fork_clone "$admin" "$w"
  for spec in alpha:alpha.txt:alpha beta:beta.txt:beta; do
    id=${spec%%:*}; rest=${spec#*:}; path=${rest%%:*}; content=${rest##*:}
    git -C "$admin" switch -qC "fm/divergence/$id" upstream/main
    printf '%s\n' "$content" > "$admin/$path"
    git -C "$admin" add "$path"
    git -C "$admin" commit -qm "$id"
    git -C "$admin" push -q origin "fm/divergence/$id"
  done

  candidate=$(new_candidate "$w" integrate-alpha)
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" integrate --repo "$candidate" --id alpha \
    --summary 'Adds alpha behavior.' --class pending --topic fm/divergence/alpha \
    --retire-when 'Upstream ships equivalent alpha behavior.' --path alpha.txt \
    --pr-url https://github.com/example/firstmate/pull/10 --pr-disposition open 2>&1) \
    || fail "alpha integration failed: $out"
  assert_contains "$out" "branch-level merge" "alpha was not integrated as a merge unit"
  git -C "$candidate" push -q origin HEAD:main

  candidate=$(new_candidate "$w" integrate-beta)
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" integrate --repo "$candidate" --id beta \
    --summary 'Adds beta behavior.' --class rejected-but-retained --topic fm/divergence/beta \
    --retire-when 'Upstream ships equivalent beta behavior.' --path beta.txt \
    --pr-url https://github.com/example/firstmate/pull/11 --pr-disposition rejected 2>&1) \
    || fail "beta integration failed: $out"
  git -C "$candidate" push -q origin HEAD:main

  candidate=$(new_candidate "$w" discard-alpha)
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" discard --repo "$candidate" --id alpha 2>&1) \
    || fail "alpha discard failed: $out"
  assert_contains "$out" "discarded independently" "discard did not report independent removal"
  assert_absent "$candidate/alpha.txt" "discard left alpha behavior"
  assert_present "$candidate/beta.txt" "discard removed neighboring beta behavior"
  jq -e '[.divergences[].id] == ["beta"]' "$candidate/fork-divergences.json" >/dev/null \
    || fail "discard did not remove only alpha manifest unit"

  beta_merge=$(git -C "$candidate" log --first-parent --merges --format=%H --grep='Merge divergence beta' -1)
  printf 'not a revert\n' > "$candidate/fake.txt"
  git -C "$candidate" add fake.txt
  git -C "$candidate" commit -qm 'Fake revert marker' -m "This reverts commit $beta_merge, reversing"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$STATUS" --repo "$candidate" --fork-ref HEAD 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "message-only fake revert was accepted as retired Git history"
  assert_contains "$out" "unowned non-equivalent patch" "fake revert marker hid an unrelated patch"
  pass "fork topics: each divergence is a branch-level unit that can be discarded alone"
}

# A clean upstream merge is committed only in an isolated candidate, records its
# health baseline, runs range-diff, and leaves fork origin/main untouched.
test_clean_upstream_merge_is_isolated_and_validated_as_candidate() {
  local w candidate origin_before out head
  w=$(new_world clean-merge)
  advance_upstream "$w" upstream.txt one upstream-one
  candidate=$(new_candidate "$w" upstream-clean)
  origin_before=$(git -C "$w/integration" rev-parse origin/main)

  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" prepare --repo "$candidate" 2>&1) \
    || fail "clean upstream merge preparation failed: $out"
  assert_contains "$out" "range-diff:" "clean merge did not run relevance review"
  assert_contains "$out" "prepared: upstream merge candidate" "clean merge did not reach validated candidate"
  [ "$(git -C "$w/integration" rev-parse origin/main)" = "$origin_before" ] || fail "candidate moved fork origin/main"
  head=$(git -C "$candidate" rev-parse HEAD)
  [ "$(git -C "$candidate" rev-list --parents -n1 "$head" | wc -w | tr -d ' ')" -eq 3 ] \
    || fail "upstream candidate is not a two-parent merge"
  jq -e '.upstream_syncs | length == 1 and .[0].touched == []' "$candidate/fork-divergences.json" >/dev/null \
    || fail "clean merge did not record bounded sync health input"
  pass "fork merge: clean upstream integration is isolated, merge-shaped, and health-validated"
}

# A conflict stops before commit, requires every affected unit to be justified,
# then records and reuses the resolution while leaving it unstaged next time.
test_conflict_requires_rejustification_and_rerere_stays_reviewable() {
  local w candidate candidate2 origin_before out rc decisions bad_decisions receipt head
  w=$(new_world conflict)
  add_topic_and_merge "$w" conflict config.txt fork
  advance_upstream "$w" config.txt upstream upstream-conflict
  advance_upstream "$w" clean.txt upstream-clean upstream-clean
  candidate=$(new_candidate "$w" upstream-conflict-one)
  origin_before=$(git -C "$w/integration" rev-parse origin/main)

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" prepare --repo "$candidate" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "conflicted merge returned $rc, expected relevance stop 3: $out"
  assert_contains "$out" "rejustify-required" "conflict did not demand re-justification"
  assert_contains "$out" "affected: conflict" "conflict did not identify its manifest unit"
  [ "$(git -C "$w/integration" rev-parse origin/main)" = "$origin_before" ] || fail "conflict moved fork origin/main"
  receipt=$(git -C "$candidate" rev-parse --git-path fm-fork-rejustify.json)
  assert_present "$receipt" "conflict did not publish re-justification receipt"
  [ -n "$(git -C "$candidate" diff --name-only --diff-filter=U)" ] || fail "conflict was silently staged"

  bad_decisions="$w/bad-decisions.json"
  cat > "$bad_decisions" <<'JSON'
{"schema":"firstmate.fork-rejustify.v1","decisions":[{"id":"conflict","action":"retain","reason":"The fork behavior remains required after the upstream change."},{"id":"unrelated","action":"remove","reason":"This unrelated unit must not enter a conflict decision."}]}
JSON
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" continue --repo "$candidate" --decisions "$bad_decisions" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "conflict continuation accepted a decision for an unaffected unit"
  assert_contains "$out" "exactly the affected units" "extra conflict decision refusal was unclear"

  printf 'fork-on-upstream\n' > "$candidate/config.txt"
  git -C "$candidate" add config.txt
  decisions="$w/decisions.json"
  cat > "$decisions" <<'JSON'
{"schema":"firstmate.fork-rejustify.v1","decisions":[{"id":"conflict","action":"retain","reason":"The fork behavior remains required after the upstream change."}]}
JSON
  printf 'tampered\n' > "$candidate/clean.txt"
  git -C "$candidate" add clean.txt
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" continue --repo "$candidate" --decisions "$decisions" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "conflict continuation accepted a changed non-conflict index entry"
  assert_contains "$out" "non-conflict index entries changed" "non-conflict index refusal was unclear"
  git -C "$candidate" show MERGE_HEAD:clean.txt > "$candidate/clean.txt"
  git -C "$candidate" add clean.txt
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" continue --repo "$candidate" --decisions "$decisions" 2>&1) \
    || fail "justified conflict did not continue: $out"
  assert_contains "$out" "prepared: upstream merge candidate" "continued conflict did not reach candidate"
  assert_absent "$receipt" "successful continue left conflict receipt"
  head=$(git -C "$candidate" rev-parse HEAD)
  [ "$(git -C "$candidate" rev-list --parents -n1 "$head" | wc -w | tr -d ' ')" -eq 3 ] \
    || fail "continued conflict did not make a merge commit"

  # Repeat the exact merge from untouched fork origin. Shared worktrees use the
  # same rr-cache; Git should write the known result but keep unmerged index
  # stages because rerere.autoupdate is false.
  candidate2=$(new_candidate "$w" upstream-conflict-two)
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" prepare --repo "$candidate2" 2>&1); rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated conflict did not stop for review"
  grep -qx 'fork-on-upstream' "$candidate2/config.txt" || fail "rerere did not reuse the recorded resolution"
  [ -n "$(git -C "$candidate2" ls-files -u)" ] || fail "rerere.autoupdate staged a reused resolution"
  git -C "$candidate2" merge --abort >/dev/null 2>&1 || true
  pass "fork merge: conflicts require re-justification and rerere reuse stays unstaged"
}

# Upstream acceptance is the divergence set's main retirement path, and it must
# survive the integration merge that makes it true. After that merge upstream is
# an ancestor of fork main, so `git cherry` can no longer see the equivalence and
# the fork's own copy of the accepted patch is a raw `+` fact forever. The merge
# therefore records the proof it could still take, the health owner re-derives
# that proof from Git rather than trusting it, the divergence count falls with
# visible evidence, and later divergence work keeps working.
test_upstream_acceptance_retires_a_divergence_with_evidence() {
  local w candidate admin manifest out rc fork_patch upstream_patch tampered
  w=$(new_world upstream-accepted)
  admin="$w/admin"
  git clone -q "$w/fork.git" "$admin"
  configure_fork_clone "$admin" "$w"
  git -C "$admin" switch -qC fm/divergence/banner upstream/main
  printf 'FLEET\n' > "$admin/banner.txt"
  git -C "$admin" add banner.txt
  git -C "$admin" commit -qm 'Show the fleet banner'
  git -C "$admin" push -q origin fm/divergence/banner
  git -C "$admin" switch -q main
  candidate=$(new_candidate "$w" accept-integrate)
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" integrate --repo "$candidate" --id banner \
    --summary 'Shows the fleet banner on startup.' --class pending --topic fm/divergence/banner \
    --retire-when 'Upstream prints the fleet banner itself.' --path banner.txt \
    --pr-url https://github.com/example/firstmate/pull/43 --pr-disposition open 2>&1) \
    || fail "banner integration failed: $out"
  assert_contains "$out" "retained=1 patches=1" "the carried divergence was not counted"
  git -C "$candidate" push -q origin HEAD:main
  fork_patch=$(git -C "$admin" rev-parse fm/divergence/banner)

  # Upstream accepts the same patch under a different commit identity.
  advance_upstream "$w" banner.txt FLEET 'official: show the fleet banner'
  candidate=$(new_candidate "$w" accept-merge)
  upstream_patch=$(git -C "$w/integration" rev-parse upstream/main)
  [ "$upstream_patch" != "$fork_patch" ] || fail "the upstream fixture reused the fork commit identity"
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$MERGE" prepare --repo "$candidate" 2>&1) \
    || fail "the upstream merge that accepts a carried divergence failed: $out"
  assert_contains "$out" "retained=0 patches=0" "the accepted divergence was still counted as carried"
  assert_contains "$out" "accepted-upstream-patches=1" "the retired patch was not reported as accepted upstream"
  assert_contains "$out" "trend=down" "retiring a divergence did not reward a falling count"
  assert_contains "$out" "proof: fork patch $fork_patch equals upstream commit $upstream_patch" \
    "the health report did not explain the retirement with its Git evidence"
  manifest="$candidate/fork-divergences.json"
  jq -e --arg fork "$fork_patch" --arg upstream "$upstream_patch" '
    (.divergences | length) == 0 and (.retired_upstream | length) == 1
    and .retired_upstream[0].id == "banner"
    and .retired_upstream[0].summary == "Shows the fleet banner on startup."
    and .retired_upstream[0].fork_patch == $fork and .retired_upstream[0].upstream_patch == $upstream
  ' "$manifest" >/dev/null || fail "the merge did not persist the retirement evidence beside the removed unit"
  [ "$(git -C "$candidate" show HEAD:fork-divergences.json | jq '.retired_upstream | length')" -eq 1 ] \
    || fail "the retirement record did not land in the upstream merge commit itself"
  git -C "$candidate" push -q origin HEAD:main

  # The machine-readable report carries the same evidence and a healthy verdict.
  git -C "$admin" fetch -q origin
  git -C "$admin" fetch -q upstream
  git -C "$admin" merge -q --ff-only origin/main
  out=$("$STATUS" --repo "$admin" --json) || fail "the caught-up fork reported unhealthy: $out"
  printf '%s' "$out" | jq -e --arg fork "$fork_patch" '
    .healthy == true and .retained.patches == 0 and .retained.accepted_upstream_patches == 1
    and (.accepted_upstream | length) == 1 and .accepted_upstream[0].proved == true
    and .accepted_upstream[0].fork_patch == $fork and (.errors | length) == 0
  ' >/dev/null || fail "fork-health JSON did not publish a proved retirement: $out"

  # A later divergence still integrates on top of the retirement.
  git -C "$admin" switch -qC fm/divergence/next upstream/main
  printf 'next\n' > "$admin/next.txt"
  git -C "$admin" add next.txt
  git -C "$admin" commit -qm 'Add the next divergence'
  git -C "$admin" push -q origin fm/divergence/next
  git -C "$admin" switch -q main
  git -C "$admin" fetch -q origin
  candidate=$(new_candidate "$w" accept-next)
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$TOPIC" integrate --repo "$candidate" --id next \
    --summary 'Adds the next divergence.' --class pending --topic fm/divergence/next \
    --retire-when 'Upstream ships an equivalent next behavior.' --path next.txt \
    --pr-url https://github.com/example/firstmate/pull/44 --pr-disposition open 2>&1) \
    || fail "a later divergence could not be integrated after a retirement: $out"
  assert_contains "$out" "retained=1 patches=1" "the later divergence was not counted"

  # Evidence is re-derived from Git, never trusted. A record pointing at a real
  # upstream commit that carries a different patch is unproved, so its patch
  # stays counted and named instead of quietly shrinking the divergence set.
  tampered="$w/tampered"
  git -C "$admin" worktree add -q --detach "$tampered" origin/main
  jq --arg upstream "$(git -C "$admin" rev-parse upstream/main~1)" \
    '.retired_upstream[0].upstream_patch = $upstream' "$tampered/fork-divergences.json" > "$w/tampered.json"
  mv "$w/tampered.json" "$tampered/fork-divergences.json"
  set +e
  out=$("$STATUS" --repo "$tampered" --fork-ref HEAD 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unproved retirement record was accepted as healthy"
  assert_contains "$out" "is unproved" "the unproved retirement was not named"
  assert_contains "$out" "unowned non-equivalent patch $fork_patch" "the unproved retirement still hid its patch"

  # Deleting the evidence does not delete the patch either.
  jq '.retired_upstream = []' "$tampered/fork-divergences.json" > "$w/dropped.json"
  mv "$w/dropped.json" "$tampered/fork-divergences.json"
  set +e
  out=$("$STATUS" --repo "$tampered" --fork-ref HEAD 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dropping the retirement evidence reported healthy"
  assert_contains "$out" "unowned non-equivalent patch $fork_patch" "a missing retirement record hid its patch"
  pass "fork health: upstream acceptance retires a divergence only on re-provable Git evidence"
}

# The private fork registration is added without changing the ordinary
# upstream/fork registration. A mismatch stops before clone creation.
test_no_mistakes_registration_isolation_is_proven() {
  local w primary primary_real home fakebin log before after out bad_home fail_home rc
  w=$(new_world registration)
  primary="$w/primary"
  home="$w/home"
  fakebin="$w/fakebin"
  log="$w/no-mistakes.log"
  mkdir -p "$home/data" "$fakebin"
  git clone -q "$w/fork.git" "$primary"
  configure_fork_clone "$primary" "$w"
  primary_real=$(cd "$primary" && pwd -P)
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    here=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
    here=$(cd "$here" && pwd -P)
    if [ "$here" = "${FAKE_PRIMARY:?}" ]; then
      if [ -f "$FAKE_PRIMARY/.fake-registration-mutated" ]; then
        printf 'remote: %s\n' "$FAKE_PRIMARY/not-official"
      else
        printf 'remote: %s\n' "${FAKE_UPSTREAM:?}"
      fi
      printf 'fork: %s\n' "${FAKE_FORK:?}"
    elif [ -f .fake-nm-init ]; then
      printf 'remote: %s\n' "$(git remote get-url origin)"
      printf 'fork: \n'
    else
      exit 1
    fi
    ;;
  init)
    printf 'init %s\n' "$PWD" >> "${FAKE_LOG:?}"
    if [ "${FAKE_MUTATE_REGISTRATION:-0}" = 1 ]; then
      : > "$FAKE_PRIMARY/.fake-registration-mutated"
      exit 9
    fi
    : > .fake-nm-init
    git remote add no-mistakes "$PWD/.fake-gate.git"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  before=$(git -C "$primary" config --list | sort)
  out=$(PATH="$fakebin:$PATH" FAKE_PRIMARY="$primary_real" FAKE_UPSTREAM="$w/upstream.git" \
    FAKE_FORK="$w/fork.git" FAKE_LOG="$log" FM_ROOT_OVERRIDE="$primary" FM_HOME="$home" \
    FM_FORK_INTEGRATION_DIR="$home/data/fork-integration" \
    "$INTEGRATION" ensure "$w/fork.git" "$w/upstream.git" --confirm 2>&1) \
    || fail "integration registration provisioning failed: $out"
  assert_contains "$out" "integration-registration: ready" "integration registration did not report ready"
  after=$(git -C "$primary" config --list | sort)
  [ "$before" = "$after" ] || fail "integration provisioning changed ordinary Git registration config"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] || fail "integration registration initialized more than once"
  PATH="$fakebin:$PATH" FAKE_PRIMARY="$primary_real" FAKE_UPSTREAM="$w/upstream.git" \
    FAKE_FORK="$w/fork.git" FAKE_LOG="$log" FM_ROOT_OVERRIDE="$primary" FM_HOME="$home" \
    FM_FORK_INTEGRATION_DIR="$home/data/fork-integration" \
    "$INTEGRATION" check "$w/fork.git" "$w/upstream.git" >/dev/null \
    || fail "isolated registration check failed"

  mkdir -p "$primary/data"
  out=$(PATH="$fakebin:$PATH" FAKE_PRIMARY="$primary_real" FAKE_UPSTREAM="$w/upstream.git" \
    FAKE_FORK="$w/fork.git" FAKE_LOG="$log" FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" \
    "$INTEGRATION" ensure "$w/fork.git" "$w/upstream.git" --confirm 2>&1) \
    || fail "default private integration path inside the operating home was refused: $out"
  assert_present "$primary/data/fork-integration/.fake-nm-init" "default private integration clone was not initialized"

  bad_home="$w/bad-home"
  mkdir -p "$bad_home/data"
  if PATH="$fakebin:$PATH" FAKE_PRIMARY="$primary_real" FAKE_UPSTREAM="$w/not-the-upstream.git" \
    FAKE_FORK="$w/fork.git" FAKE_LOG="$log" FM_ROOT_OVERRIDE="$primary" FM_HOME="$bad_home" \
    FM_FORK_INTEGRATION_DIR="$bad_home/data/fork-integration" \
    "$INTEGRATION" ensure "$w/fork.git" "$w/upstream.git" --confirm >/dev/null 2>&1; then
    fail "registration mismatch was reconfigured instead of refused"
  fi
  assert_absent "$bad_home/data/fork-integration" "refused registration mismatch still created integration clone"

  fail_home="$w/fail-home"
  mkdir -p "$fail_home/data"
  set +e
  out=$(PATH="$fakebin:$PATH" FAKE_PRIMARY="$primary_real" FAKE_UPSTREAM="$w/upstream.git" \
    FAKE_FORK="$w/fork.git" FAKE_LOG="$log" FAKE_MUTATE_REGISTRATION=1 \
    FM_ROOT_OVERRIDE="$primary" FM_HOME="$fail_home" FM_FORK_INTEGRATION_DIR="$fail_home/data/fork-integration" \
    "$INTEGRATION" ensure "$w/fork.git" "$w/upstream.git" --confirm 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed integration init continued after changing the ordinary registration"
  assert_contains "$out" "ordinary no-mistakes registration changed" "post-init registration stop was not explicit"
  [ "$(grep -c '/fail-home/data/fork-integration$' "$log")" -eq 1 ] \
    || fail "failed integration init was retried"
  rm -f "$primary/.fake-registration-mutated"
  pass "fork integration: isolated no-mistakes registration is proven without reconfiguring the live one"
}

test_startup_upstream_probe_requires_validated_topology
test_remote_topology_is_explicit_and_reversible
test_remote_topology_inheritance_refuses_unrelated_clones
test_remote_provisioning_inherits_fork_topology
test_brief_supports_explicit_upstream_start_ref
test_self_update_stays_fast_forward_only
test_topic_waits_for_validated_upstream
test_health_uses_git_cherry_equivalence_and_exposes_drift
test_topics_are_independently_revertible_units
test_clean_upstream_merge_is_isolated_and_validated_as_candidate
test_conflict_requires_rejustification_and_rerere_stays_reviewable
test_upstream_acceptance_retires_a_divergence_with_evidence
test_no_mistakes_registration_isolation_is_proven

echo "# all fork-main integration tests passed"
