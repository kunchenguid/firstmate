#!/usr/bin/env bash
# End-to-end integrity and preservation-first recovery coverage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
INTEGRITY="$ROOT/bin/fm-fleet-integrity.sh"
RECONCILE="$ROOT/bin/fm-fleet-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-integrity)

make_tmux_missing() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_tmux_live() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'claude\n' ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_remote_probe() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
: "${FM_REMOTE_PROBE_LOG:?}"
printf 'contacted\n' >> "$FM_REMOTE_PROBE_LOG"
exit 1
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$fakebin"
}

write_backlog() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] missing-endpoint - Endpoint disappeared (repo: alpha) (kind: ship)
- [ ] missing-worktree - Worktree disappeared (repo: alpha) (kind: ship)
- [ ] completed-survivor - Completion survived cleanup (repo: alpha) (kind: ship)

## Queued

## Done
EOF
}

write_task() {
  local home=$1 id=$2 worktree=$3 status=$4
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$worktree" \
    "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

test_snapshot_and_read_surfaces_reconcile_stale_shape() {
  local home fakebin snapshot compact view startup harness_pid
  home="$TMP_ROOT/primary"
  mkdir -p "$home"/{state,data,config,projects,existing-worktree}
  write_backlog "$home"
  write_task "$home" missing-endpoint "$home/existing-worktree" 'working: processing'
  write_task "$home" missing-worktree "$home/gone-worktree" 'working: processing'
  write_task "$home" completed-survivor "$home/existing-worktree" 'done: PR https://example.test/repo/pull/1 checks green'
  fakebin=$(make_tmux_missing "$home-fake")

  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$snapshot" | jq -e '
    .integrity.valid == false
      and ([.tasks[] | select(.id == "missing-endpoint") | .integrity.classification] == ["stale"])
      and ([.tasks[] | select(.id == "missing-worktree") | .integrity.classification] == ["stale"])
      and ([.tasks[] | select(.id == "completed-survivor") | .integrity.classification] == ["completed-awaiting-cleanup"])
      and ([.integrity.failures[] | .id] | sort) == ["completed-survivor", "missing-endpoint", "missing-worktree"]
  ' >/dev/null || fail "snapshot did not classify all stale lifecycle shapes: $snapshot"

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$INTEGRITY" --compact)
  assert_contains "$compact" 'completed-awaiting-cleanup' 'integrity report must expose completed metadata awaiting guarded cleanup'
  assert_contains "$compact" 'missing-endpoint: in-flight task has no live recorded endpoint' 'integrity report must expose missing endpoint action'
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" '## Integrity' 'fleet view must include an integrity section'
  assert_contains "$view" '| missing-worktree | unknown / none | ship | alpha | tmux | absent |' 'fleet view must retain evidence for a missing worktree'
  assert_contains "$view" '| stale |' 'fleet view must label stale task integrity'
  ln -s /bin/sleep "$fakebin/codex"
  "$fakebin/codex" 30 &
  harness_pid=$!
  printf '%s\n' "$harness_pid" > "$home/state/.lock"
  startup=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SESSION_START_TIMEOUT=45 "$ROOT/bin/fm-session-start.sh") \
    || fail 'primary-home startup fixture failed'
  kill "$harness_pid" 2>/dev/null || true
  wait "$harness_pid" 2>/dev/null || true
  assert_contains "$startup" 'Fleet integrity: attention required' 'startup must expose the same guarded classifications'
  pass 'snapshot, read-only integrity, and fleet view expose stale lifecycle evidence without mutation'
}

test_historical_terminal_event_and_missing_secondmate_home_stay_truthful() {
  local home fakebin snapshot gen
  home="$TMP_ROOT/arena"
  mkdir -p "$home"/{state,data,config,projects,working-tree}
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] relaunched - Relaunched task (repo: alpha) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/relaunched.meta" \
    'window=firstmate:fm-relaunched' 'endpoint_task_id=relaunched' \
    "worktree=$home/working-tree" 'project=alpha' 'harness=claude' \
    'kind=ship' 'mode=no-mistakes'
  printf 'done: historical completion from an earlier run\n' > "$home/state/relaunched.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" relaunched)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" relaunched busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/arena-mate.meta" \
    'window=firstmate:fm-arena-mate' 'endpoint_task_id=arena-mate' \
    "worktree=$home/missing-mate" "home=$home/missing-mate" \
    "project=$home/missing-mate" 'harness=codex' 'kind=secondmate' \
    'mode=secondmate' 'projects=alpha'
  printf 'working: serving Arena\n' > "$home/state/arena-mate.status"
  printf -- '- arena-mate - Arena domain (home: %s; scope: Arena operations; projects: alpha; added 2026-08-15)\n' \
    "$home/missing-mate" > "$home/data/secondmates.md"
  fakebin=$(make_tmux_live "$TMP_ROOT/arena-fake")
  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$snapshot" | jq -e '
    ([.tasks[] | select(.id == "relaunched") | .integrity.classification] == ["working"])
      and ([.tasks[] | select(.id == "arena-mate") | .integrity.classification] == ["unreconciled"])
      and any(.integrity.failures[];
        .id == "arena-mate" and .reason == "persistent secondmate home or worktree is absent")
  ' >/dev/null || fail "current runtime truth did not override historical or missing-home evidence: $snapshot"
  pass 'Arena fixture keeps current working truth and missing persistent homes visible'
}

test_local_only_integrity_skips_remote_metadata_probes() {
  local home fakebin probe integrity
  home="$TMP_ROOT/remote-local-only"
  mkdir -p "$home"/{state,data,config,projects}
  fm_write_meta "$home/state/remote-mate.meta" \
    'window=remote-session:remote-pane' 'endpoint_task_id=remote-mate' \
    'worktree=/srv/firstmate-home' 'home=/srv/firstmate-home' \
    'project=/srv/firstmate-home' 'harness=codex' 'kind=secondmate' \
    'mode=secondmate' 'projects=alpha' 'remote_host=remote-fixture' \
    'remote_root=/srv/firstmate' 'remote_backend=herdr' \
    'remote_target=remote-session:remote-pane'
  printf -- '- remote-mate - remote domain (host: remote-fixture; root: /srv/firstmate; home: /srv/firstmate-home; scope: remote operations; projects: alpha; added 2026-08-15)\n' \
    > "$home/data/secondmates.md"
  fakebin=$(make_remote_probe "$TMP_ROOT/remote-local-only-fake")
  probe="$TMP_ROOT/remote-local-only-contact.log"
  integrity=$(PATH="$fakebin:$PATH" FM_SSH_BIN="$fakebin/ssh" \
    FM_REMOTE_PROBE_LOG="$probe" FM_HOME="$home" "$INTEGRITY" --json) \
    || fail 'local-only integrity inspection failed for remote metadata'
  assert_absent "$probe" 'local-only integrity inspection contacted a remote secondmate'
  printf '%s' "$integrity" | jq -e '
    .valid == false
      and any(.failures[];
        .id == "remote-mate" and .classification == "unreconciled")
  ' >/dev/null || fail "remote metadata was not preserved as unknown local-only evidence: $integrity"
  pass 'local-only integrity preserves remote metadata without contacting its host'
}

write_seed_receipt() {
  local home=$1 id=$2 returned=$3 projects=$4 scope=$5 digest
  digest=$(printf 'id=%s\nhome=%s\nprojects=%s\nscope=%s\n' \
    "$id" "$returned" "$projects" "$scope" | shasum -a 256 | awk '{print $1}')
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/seed-receipt" <<EOF
schema=fm-secondmate-seed.v1
id=$id
home=$returned
projects=$projects
scope=$scope
identity_digest=$digest
EOF
}

make_returned_secondmate() {
  local home=$1 id=$2 returned=$3 projects=$4 scope=$5
  mkdir -p "$home"/{state,data,config,projects} "$returned/state"
  returned=$(cd "$returned" && pwd -P)
  write_seed_receipt "$home" "$id" "$returned" "$projects" "$scope"
  printf -- '- %s - returned domain (home: %s; scope: %s; projects: %s; added 2026-08-15)\n' \
    "$id" "$returned" "$scope" "$projects" > "$home/data/secondmates.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$returned" \
    "project=$returned" "harness=codex" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "home=$returned" "projects=$projects"
}

make_recovery_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  cat "${FM_FAKE_TREEHOUSE_STATUS:?}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_returned_secondmate_recovery_is_identity_bound() {
  local home returned fakebin status_file output err
  home="$TMP_ROOT/recovery-parent"
  returned="$TMP_ROOT/recovery-returned"
  make_returned_secondmate "$home" returned "$returned" alpha 'feature development'
  status_file="$TMP_ROOT/treehouse-empty.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/recovery-fake")
  err="$TMP_ROOT/recovery-normal.err"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_TEARDOWN_GUARD_DONE=1 "$ROOT/bin/fm-teardown.sh" returned \
      >/dev/null 2>"$err"; then
    fail 'normal secondmate teardown accepted the partial-return shape'
  fi
  assert_grep 'unsafe secondmate home removal target' "$err" 'normal teardown must preserve a returned home without its seed marker'
  assert_present "$home/state/returned.meta" 'normal refusal must preserve parent metadata'

  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
    "$RECONCILE" recover-returned-secondmate returned) \
    || fail 'identity-bound returned-secondmate recovery rejected a proved return'
  assert_contains "$output" 'identity and completed lease return proved' 'recovery must report its proof boundary'
  assert_absent "$home/state/returned.meta" 'recovery must retire parent metadata through guarded teardown'
  assert_not_contains "$(cat "$home/data/secondmates.md")" '- returned ' 'recovery must retire the parent route'
  assert_present "$home/data/returned/seed-receipt" 'recovery must preserve the seed receipt as audit evidence'
  pass 'returned-secondmate recovery completes only after exact identity and lease-return proofs'
}

test_legacy_returned_secondmate_recovery_uses_charter_identity() {
  local home returned fakebin status_file output
  home="$TMP_ROOT/recovery-legacy-parent"
  returned="$TMP_ROOT/recovery-legacy-returned"
  make_returned_secondmate "$home" legacy-returned "$returned" alpha 'feature development'
  rm -f "$home/data/legacy-returned/seed-receipt"
  cat > "$home/data/legacy-returned/brief.md" <<'EOF'
# Charter
returned domain

# Routing scope
Feature development

# Project clones
- alpha
EOF
  status_file="$TMP_ROOT/treehouse-legacy-empty.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/recovery-legacy-fake")
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
    "$RECONCILE" recover-returned-secondmate legacy-returned) \
    || fail 'legacy charter identity did not recover a proved returned home'
  assert_contains "$output" 'legacy-charter identity' 'legacy recovery must disclose its bounded identity proof'
  assert_absent "$home/state/legacy-returned.meta" 'legacy recovery must retire parent metadata'
  assert_not_contains "$(cat "$home/data/secondmates.md")" '- legacy-returned ' 'legacy recovery must retire the parent route'
  pass 'legacy returned-home recovery uses only the durable charter identity'
}

test_legacy_returned_secondmate_recovery_rejects_identity_drift() {
  local home returned fakebin status_file err
  home="$TMP_ROOT/legacy-arena-parent"
  returned="$TMP_ROOT/legacy-arena-returned"
  make_returned_secondmate "$home" legacy-drift "$returned" alpha 'feature development'
  rm -f "$home/data/legacy-drift/seed-receipt"
  cat > "$home/data/legacy-drift/brief.md" <<'EOF'
# Charter
Legacy Arena replacement charter.

# Routing scope
Issue triage

# Project clones
- beta
EOF
  status_file="$TMP_ROOT/treehouse-legacy-drift.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/legacy-drift-fake")
  err="$TMP_ROOT/legacy-drift.err"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
      "$RECONCILE" recover-returned-secondmate legacy-drift >/dev/null 2>"$err"; then
    fail 'legacy recovery accepted charter, metadata, and route identity drift'
  fi
  assert_grep 'legacy charter projects do not match parent metadata' "$err" 'legacy identity drift refusal must name the mismatched durable evidence'
  assert_present "$home/state/legacy-drift.meta" 'legacy identity drift must preserve metadata'
  assert_grep 'legacy-drift' "$home/data/secondmates.md" 'legacy identity drift must preserve its route'
  pass 'legacy Arena recovery rejects replaced charter identity'
}

test_returned_secondmate_recovery_refuses_arbitrary_missing_home() {
  local home returned fakebin status_file err
  home="$TMP_ROOT/recovery-missing-parent"
  returned="$TMP_ROOT/recovery-missing"
  make_returned_secondmate "$home" missing-home "$returned" alpha 'feature development'
  rm -rf "$returned"
  status_file="$TMP_ROOT/treehouse-missing-empty.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/recovery-missing-fake")
  err="$TMP_ROOT/recovery-missing.err"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
      "$RECONCILE" recover-returned-secondmate missing-home >/dev/null 2>"$err"; then
    fail 'recovery accepted an arbitrary missing secondmate home'
  fi
  assert_grep 'missing or unsafe' "$err" 'missing-home refusal must name the identity-bound proof failure'
  assert_present "$home/state/missing-home.meta" 'missing-home refusal must preserve parent metadata'
  assert_grep 'missing-home' "$home/data/secondmates.md" 'missing-home refusal must preserve the route'
  pass 'returned-secondmate recovery preserves arbitrary missing homes'
}

test_route_scope_ambiguity_is_rejected_without_banning_shared_clones() {
  local home registry_err
  home="$TMP_ROOT/routes"
  mkdir -p "$home"/{state,data,config,projects}
  cat > "$home/data/secondmates.md" <<EOF
- one - first route (home: $TMP_ROOT/route-one; scope: feature development; projects: alpha; added 2026-08-15)
- two - equivalent route (home: $TMP_ROOT/route-two; scope: Feature-development; projects: alpha, beta; added 2026-08-15)
EOF
  registry_err="$TMP_ROOT/routes.err"
  if FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null 2>"$registry_err"; then
    fail 'registry validation accepted equivalent persistent scopes for one project'
  fi
  assert_grep 'ambiguous persistent route' "$registry_err" 'route validation must explain equivalent-scope ambiguity'

  cat > "$home/data/secondmates.md" <<EOF
- one - first route (home: $TMP_ROOT/route-one; scope: feature development; projects: alpha; added 2026-08-15)
- two - issue route (home: $TMP_ROOT/route-two; scope: issue triage; projects: alpha, beta; added 2026-08-15)
EOF
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail 'registry validation banned a shared clone with a materially different scope'
  pass 'route validation rejects equivalent scope ownership while preserving non-exclusive clones'
}

test_safe_returned_route_retirement_resolves_target_ambiguity() {
  local home returned other fakebin status_file output
  home="$TMP_ROOT/busy-blue-parent"
  returned="$TMP_ROOT/busy-blue-returned"
  other="$TMP_ROOT/busy-blue-authoritative"
  make_returned_secondmate "$home" busy-blue-old "$returned" alpha 'feature development'
  printf -- '- busy-blue-live - authoritative Busy Blue route (home: %s; scope: Feature-development; projects: alpha; added 2026-08-15)\n' \
    "$other" >> "$home/data/secondmates.md"
  status_file="$TMP_ROOT/treehouse-busy-blue.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/busy-blue-fake")
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
    "$RECONCILE" recover-returned-secondmate busy-blue-old) \
    || fail 'safe target-bound retirement could not resolve an equivalent route pair'
  assert_contains "$output" 'returned-home recovery busy-blue-old complete' 'safe retirement must complete through the guarded lifecycle'
  assert_not_contains "$(cat "$home/data/secondmates.md")" '- busy-blue-old ' 'safe retirement must remove only its exact old route'
  assert_contains "$(cat "$home/data/secondmates.md")" '- busy-blue-live ' 'safe retirement must preserve the authoritative route'
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail 'target-bound retirement left an ambiguous registry'
  pass 'Busy Blue safe retirement resolves only the proved route ambiguity'
}

test_returned_recovery_preserves_fallible_cleanup_and_unsafe_shapes() {
  local shape home returned fakebin status_file err gen
  for shape in dirty inaccessible unresolved unique-commit uncertain-ownership; do
    home="$TMP_ROOT/preserve-$shape-parent"
    returned="$TMP_ROOT/preserve-$shape-returned"
    make_returned_secondmate "$home" "$shape" "$returned" alpha 'feature development'
    status_file="$TMP_ROOT/treehouse-$shape.json"
    printf '[]\n' > "$status_file"
    fakebin=$(make_recovery_fakebin "$TMP_ROOT/preserve-$shape-fake")
    case "$shape" in
      dirty) printf 'unowned material\n' > "$returned/untracked" ;;
      inaccessible) chmod 000 "$returned/state" ;;
      unresolved) printf 'window=unknown\n' > "$returned/state/child.meta" ;;
      unique-commit)
        git -C "$returned" init -q
        printf 'unique work\n' > "$returned/unique.txt"
        git -C "$returned" add unique.txt
        git -C "$returned" -c user.name='Fleet Fixture' -c user.email='fixture@example.invalid' commit -qm unique
        ;;
      uncertain-ownership) fakebin=$(make_tmux_live "$TMP_ROOT/preserve-$shape-live-fake") ;;
    esac
    err="$TMP_ROOT/preserve-$shape.err"
    if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
        FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
        "$RECONCILE" recover-returned-secondmate "$shape" >/dev/null 2>"$err"; then
      [ "$shape" = inaccessible ] && chmod 700 "$returned/state"
      fail "returned-home recovery discarded $shape evidence"
    fi
    [ "$shape" = inaccessible ] && chmod 700 "$returned/state"
    assert_present "$home/state/$shape.meta" "$shape refusal must preserve parent metadata"
    assert_grep "$shape" "$home/data/secondmates.md" "$shape refusal must preserve its exact route"
    if [ "$shape" = unique-commit ]; then
      git -C "$returned" rev-parse --verify HEAD >/dev/null \
        || fail 'unique-commit refusal did not preserve the unique commit'
    fi
  done

  home="$TMP_ROOT/fallible-cleanup-parent"
  returned="$TMP_ROOT/fallible-cleanup-returned"
  make_returned_secondmate "$home" fallible "$returned" alpha 'feature development'
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" fallible)
  printf 'busy_gen=wrong-generation\n' >> "$home/state/fallible.meta"
  status_file="$TMP_ROOT/treehouse-fallible.json"
  printf '[]\n' > "$status_file"
  fakebin=$(make_recovery_fakebin "$TMP_ROOT/fallible-fake")
  err="$TMP_ROOT/fallible.err"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_FAKE_TREEHOUSE_STATUS="$status_file" FM_TEARDOWN_GUARD_DONE=1 \
      "$RECONCILE" recover-returned-secondmate fallible >/dev/null 2>"$err"; then
    fail 'returned-home recovery ignored a fallible cleanup refusal'
  fi
  assert_present "$home/state/fallible.meta" 'fallible cleanup refusal must preserve metadata'
  assert_grep 'fallible' "$home/data/secondmates.md" 'fallible cleanup refusal must preserve the route until finalization'
  [ -n "$gen" ] || fail 'fallible cleanup fixture did not arm an independent generation'
  pass 'guarded recovery preserves dirty, inaccessible, unresolved, unique, and uncertain evidence'
}

test_snapshot_and_read_surfaces_reconcile_stale_shape
test_historical_terminal_event_and_missing_secondmate_home_stay_truthful
test_local_only_integrity_skips_remote_metadata_probes
test_returned_secondmate_recovery_is_identity_bound
test_legacy_returned_secondmate_recovery_uses_charter_identity
test_legacy_returned_secondmate_recovery_rejects_identity_drift
test_returned_secondmate_recovery_refuses_arbitrary_missing_home
test_route_scope_ambiguity_is_rejected_without_banning_shared_clones
test_safe_returned_route_retirement_resolves_target_ambiguity
test_returned_recovery_preserves_fallible_cleanup_and_unsafe_shapes

echo 'all fleet integrity E2E tests passed'
