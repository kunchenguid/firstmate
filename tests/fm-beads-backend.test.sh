#!/usr/bin/env bash
# tests/fm-beads-backend.test.sh - beads as third backlog backend option.
# Tests backend selection and availability checks.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-tasks-axi-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-beads-backend)

# Test: fm_backlog_backend_value() returns beads when configured
test_beads_backend_value() {
  local config="$TMP_ROOT/config"
  mkdir -p "$config"

  # Test default (tasks-axi)
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "tasks-axi" ] || fail "default backend should be tasks-axi, got: $value"

  # Test explicit beads
  printf '%s' 'beads' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "beads backend when configured should return beads, got: $value"

  # Test manual
  printf '%s' 'manual' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "manual" ] || fail "manual backend when configured should return manual, got: $value"
}

# Test: fm_beads_backend_available() checks config and task CLI
test_beads_backend_available() {
  local config="$TMP_ROOT/config-beads"
  mkdir -p "$config"

  # Test: beads not configured - should return false
  printf '%s' 'tasks-axi' > "$config/backlog-backend"
  if fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return false when beads not configured"
  fi

  # Test: beads configured but task CLI not found - should return false
  printf '%s' 'beads' > "$config/backlog-backend"
  if ! command -v task >/dev/null 2>&1; then
    if fm_beads_backend_available "$config"; then
      fail "fm_beads_backend_available should return false when task CLI not found"
    fi
    return 0
  fi

  # Test: beads configured and task CLI found - should return true if store is reachable
  if ! task list --limit 1 >/dev/null 2>&1; then
    # Store not reachable in test environment - that's OK
    return 0
  fi
  if ! fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return true when beads configured and task CLI works"
  fi
}

# Test: fm_tasks_axi_backend_available() returns false when beads is configured
test_tasks_axi_backend_false_for_beads() {
  local config="$TMP_ROOT/config-axi"
  mkdir -p "$config"

  printf '%s' 'beads' > "$config/backlog-backend"

  if fm_tasks_axi_backend_available "$config"; then
    fail "fm_tasks_axi_backend_available should return false when beads is configured"
  fi
}

# Test: backend value handles whitespace
test_backend_value_whitespace() {
  local config="$TMP_ROOT/config-ws"
  mkdir -p "$config"

  printf '%s' '  beads  ' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "backend value should strip whitespace, got: $value"
}

# Test: fm_beads_fleet_label() defaults to fleet:firstmate and honors the
# test-only FM_BEADS_FLEET_LABEL override (beads-authority migration Stage 0).
test_beads_fleet_label() {
  local value
  value=$(unset FM_BEADS_FLEET_LABEL; fm_beads_fleet_label)
  [ "$value" = "fleet:firstmate" ] || fail "default fleet label should be fleet:firstmate, got: $value"

  value=$(FM_BEADS_FLEET_LABEL="fleet:example" fm_beads_fleet_label)
  [ "$value" = "fleet:example" ] || fail "fleet label override should win, got: $value"
}

# add_beads_task_mock_store <fakebin_dir> <calls_log> <store_json> <minted_id>
# [emit_labels]: a fake `task` CLI backed by a small on-disk store. `list`
# applies the same --label (AND), --status, --all, and --limit semantics the real
# CLI documents - including truncating to --limit AFTER filtering - so a lookup
# that forgets a filter sees exactly the rows it meant to exclude instead of a
# fixture that answers correctly no matter what was asked. Rows are
# {id,status,labels}; `create` reports <minted_id>.
#
# The store is a FILE, and `tag` writes to it, so a migration and the resolve
# that follows it see one store evolving rather than two disconnected fixtures -
# which is what lets a test assert that a re-tagged bead is afterwards found by
# its scoped label.
#
# The real CLI does NOT return a labels field from `list --json` (it is served
# separately by `label list <id> --json`, a flat array of label strings), so the
# mock strips labels from its list rows by default and serves `label list` and
# `label list-all` too, and a reader of a bead's labels exercises the same
# two-call shape it does in production. Pass <emit_labels> as "true" for the
# forward-compatible case where the payload already carries labels.
add_beads_task_mock_store() {
  local fakebin_dir=$1 calls_log=$2 store_json=$3 minted_id=$4 emit_labels=${5:-false}
  local store_file="$fakebin_dir/store.json"
  printf '%s' "$store_json" > "$store_file"
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
store=\$(cat "$store_file")
case "\$1" in
  list)
    labels=; statuses=; limit=50
    shift
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --label|-l) labels=\${2:-}; shift 2 ;;
        --status|-s) statuses=\${2:-}; shift 2 ;;
        --limit|-n) limit=\${2:-0}; shift 2 ;;
        --all) statuses=all; shift ;;
        *) shift ;;
      esac
    done
    printf '%s' "\$store" | jq -c \
      --arg labels "\$labels" --arg statuses "\$statuses" --argjson limit "\$limit" \
      --argjson emit_labels $emit_labels '
      [ .[]
        | select(\$labels == "" or ((\$labels | split(",")) - (.labels // [])) == [])
        | select(
            if \$statuses == "all" then true
            elif \$statuses == "" then .status != "closed"
            else (.status as \$s | \$statuses | split(",") | index(\$s)) != null
            end)
      ]
      | if \$limit > 0 then .[0:\$limit] else . end
      | map(if \$emit_labels then . else del(.labels) end)'
    ;;
  label)
    case "\${2:-}" in
      list)
        printf '%s' "\$store" | jq -c --arg id "\${3:-}" \
          '[ .[] | select(.id == \$id) | (.labels // [])[] ]'
        ;;
      list-all)
        # The real list-all spans the whole store, closed rows included.
        printf '%s' "\$store" | jq -c \
          '[ .[] | (.labels // [])[] ] | unique | map({label: ., count: 1})'
        ;;
      *) exit 1 ;;
    esac
    ;;
  tag)
    printf '%s' "\$store" | jq -c --arg id "\${2:-}" --arg l "\${3:-}" \
      'map(if .id == \$id then (.labels = (((.labels // []) + [\$l]) | unique)) else . end)' \
      > "$store_file.next" && mv "$store_file.next" "$store_file"
    ;;
  create)
    printf '%s\n' "$minted_id"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# Test: fm_beads_resolve_or_create() mints a new bead labeled
# task:<scope>:<id> when no bead already carries that scoped label
# (beads-authority migration Stage 3).
test_beads_resolve_or_create_mints_when_absent() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve mint skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-mint"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" '[]' "bead-99"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "task-abc")
  [ "$id" = "bead-99" ] || fail "expected minted bead id bead-99, got: $id"
  assert_grep "list --label task:home-a:task-abc --limit 1 --json" "$calls_log" \
    "resolve did not look up an existing bead by its scoped task:<scope>:<id> label"
  assert_no_grep "list --label task:home-a:task-abc --all" "$calls_log" \
    "resolve asked for closed beads instead of letting the store exclude them"
  assert_no_grep "list --label task:task-abc" "$calls_log" \
    "resolve paid a legacy-label store call for a task whose own record names no bead to adopt"
  assert_grep "create --title" "$calls_log" \
    "resolve did not mint a new bead when none existed"
  assert_grep "task:home-a:task-abc" "$calls_log" \
    "minted bead did not carry the home-scoped idempotency label"
  pass "fm_beads_resolve_or_create mints a new bead labeled task:<scope>:<id> when none exists"
}

# Test: fm_beads_resolve_or_create() reuses an existing scoped-labeled bead
# instead of minting a duplicate, so a resolution against an id that was already
# linked (e.g. an explicit --beads spawn, or a prior successful spawn attempt)
# never mints a second bead for the same task.
test_beads_resolve_or_create_reuses_existing() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve reuse skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-reuse"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:home-a:task-xyz"]}]' \
    "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-7" ] || fail "expected existing bead id bead-7, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate bead despite an existing scoped label match"
  assert_no_grep "tag bead-7" "$calls_log" \
    "resolve rewrote a bead that already carried the scoped label"
  pass "fm_beads_resolve_or_create reuses an existing task:<scope>:<id>-labeled bead instead of minting a duplicate"
}

# Test: a CLOSED bead carrying the scoped label is never adopted. Task ids are
# reusable slugs and fm-teardown.sh closes a bead without stripping that label, so
# the record of a long-finished task survives in the store. Adopting it would link
# a brand-new task to an already-closed bead - and under the beads backend a closed
# bead is the authoritative task-complete signal bin/fm-crew-state.sh reads, so the
# fresh crew would reconcile as done before its worker committed anything.
test_beads_resolve_or_create_skips_closed_bead() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve closed-bead skip skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-closed"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-old","status":"closed","labels":["task:home-a:fix-ci"]}]' \
    "bead-fresh"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "fix-ci")
  [ "$id" != "bead-old" ] \
    || fail "resolve adopted the closed bead of a previous task that reused this id"
  [ "$id" = "bead-fresh" ] || fail "expected a freshly minted bead, got: $id"
  assert_grep "create --title" "$calls_log" \
    "resolve did not mint a fresh bead when the only labeled bead was closed"
  pass "fm_beads_resolve_or_create mints a fresh bead instead of adopting a closed one"
}

# Test: the closed-bead exclusion must not cost idempotency. When a task id has a
# closed predecessor AND the live bead for the current task, resolve still returns
# the live one rather than minting a duplicate - the label matches both records and
# their order in the store is not specified.
test_beads_resolve_or_create_prefers_live_bead_over_closed() {
  local dir fakebin calls_log id
  command -v jq >/dev/null 2>&1 || { pass "resolve live-over-closed skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-mixed"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-old","status":"closed","labels":["task:home-a:fix-ci"]},{"id":"bead-live","status":"in_progress","labels":["task:home-a:fix-ci"]}]' \
    "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "fix-ci")
  [ "$id" = "bead-live" ] || fail "expected the still-live bead bead-live, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate despite a live task:<scope>:<id>-labeled bead existing"
  pass "fm_beads_resolve_or_create returns the live bead when a closed predecessor shares the label"
}

# Test: the store, not the caller, decides which rows come back. A reusable task id
# accumulates one closed predecessor per completed task, and the store applies
# --limit AFTER filtering, so a lookup that fetches a page and drops the closed rows
# itself sees only predecessors once they outnumber the page - and mints a duplicate
# bead for a task that is already linked, every time it is asked. Asking the store
# for the non-closed rows makes the page size irrelevant.
test_beads_resolve_or_create_ignores_predecessor_backlog_depth() {
  local dir fakebin calls_log id store i
  command -v jq >/dev/null 2>&1 || { pass "resolve predecessor-depth skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-deep"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  store='['
  for i in $(seq 1 40); do
    store="$store{\"id\":\"bead-old-$i\",\"status\":\"closed\",\"labels\":[\"task:home-a:fix-ci\"]},"
  done
  store="$store{\"id\":\"bead-live\",\"status\":\"open\",\"labels\":[\"task:home-a:fix-ci\"]}]"
  add_beads_task_mock_store "$fakebin" "$calls_log" "$store" "bead-should-not-be-created"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "fix-ci")
  [ "$id" = "bead-live" ] \
    || fail "expected the live bead behind 40 closed predecessors, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "resolve minted a duplicate because the closed predecessors filled its page"
  pass "fm_beads_resolve_or_create finds the live bead however many closed predecessors share the label"
}

# Test: fm_beads_home_scope is a 16-hex string, stable across calls, distinct
# across homes, and honors the FM_BEADS_HOME_SCOPE test override. Fails (returns
# 1) when neither a home path nor the override is supplied.
test_beads_home_scope_stable_and_distinct() {
  local a1 a2 b
  a1=$(FM_HOME=/tmp/home-a fm_beads_home_scope) || a1=
  [ -n "$a1" ] || fail "fm_beads_home_scope produced nothing for a real home path"
  [ "${#a1}" -eq 16 ] || fail "scope should be 16 chars, got '$a1'"
  a2=$(FM_HOME=/tmp/home-a fm_beads_home_scope)
  [ "$a1" = "$a2" ] || fail "scope must be stable across calls for one home"
  b=$(FM_HOME=/tmp/home-b fm_beads_home_scope)
  [ "$a1" != "$b" ] || fail "two distinct homes must yield distinct scopes"
  [ "$(FM_BEADS_HOME_SCOPE=home-a fm_beads_home_scope)" = "home-a" ] \
    || fail "the FM_BEADS_HOME_SCOPE override must win"
  if FM_HOME='' fm_beads_home_scope >/dev/null 2>&1; then
    fail "fm_beads_home_scope must fail when no home and no override are supplied"
  fi
  pass "fm_beads_home_scope is 16-hex, stable, and distinct per home; the override wins"
}

# Regression: two different home scopes with the same task slug resolve to
# different beads. Home A reuses its own scoped bead while home B, which shares
# the store but a different scope, mints its own bead - the exact cross-home
# adoption the home-scoped label exists to prevent.
test_beads_resolve_or_create_two_homes_same_slug() {
  local dir fakebin calls_log id_a id_b
  command -v jq >/dev/null 2>&1 || { pass "two-homes same-slug skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-two-homes"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-A","status":"open","labels":["task:home-a:task-xyz"]}]' \
    "bead-B"

  id_a=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "task-xyz")
  [ "$id_a" = "bead-A" ] || fail "home A should resolve to its own bead-A, got: $id_a"
  id_b=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b fm_beads_resolve_or_create "task-xyz")
  [ "$id_b" = "bead-B" ] || fail "home B must mint its own bead-B, got: $id_b"
  [ "$id_a" != "$id_b" ] \
    || fail "two home scopes must resolve the same slug to different beads"
  assert_grep "list --label task:home-b:task-xyz" "$calls_log" \
    "home B's resolve did not look up its own scoped label"
  pass "two home scopes with the same slug resolve to different beads"
}

# Regression (the reason the migration is a sweep and not a lookup): a
# pre-migration bead carrying the unscoped task:<id> label is rescued for the
# home that owns the slug, even though NO state/<id>.meta exists for it. That is
# the case a meta-gated compatibility read could never reach: fm-brief.sh mints
# the intake bead at scaffold time and fm-spawn.sh resolves before it writes the
# meta, so at every point the bead could be adopted the only home-local record is
# the scaffolded brief. Without the sweep this home mints a second bead and the
# intake bead stays open forever, because teardown closes only the meta's id.
test_beads_migration_retags_a_scaffolded_tasks_legacy_bead() {
  local dir fakebin calls_log home id marker
  command -v jq >/dev/null 2>&1 || { pass "legacy label migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-own"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data/task-xyz"
  : > "$home/data/task-xyz/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:task-xyz"]}]' \
    "bead-should-not-be-created"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the migration sweep reported failure against a healthy store"
  assert_grep "tag bead-7 task:home-a:task-xyz" "$calls_log" \
    "the sweep did not re-tag this home's own pre-migration bead onto the scoped label"

  marker="$home/state/.beads-label-migration-v1"
  assert_present "$marker" "a completed sweep left no durable marker, so it re-sweeps every session"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-7" ] \
    || fail "after the migration the ordinary resolve should be a scoped hit on bead-7, got: $id"
  assert_no_grep "create --title" "$calls_log" \
    "the task minted a duplicate bead despite its pre-migration bead having been migrated"
  pass "the sweep re-tags a scaffolded task's pre-migration bead and the next resolve is a scoped hit"
}

# Regression (the cross-home bug itself): the unscoped label records no home, so
# two homes that both used one slug can both see one pre-migration bead. The
# first home to sweep keeps it and stamps its scope on it; the second must leave
# it alone and mint its own on its next resolve, otherwise the two keep sharing
# one bead and one home closing it still marks the other's live work done.
test_beads_migration_leaves_a_bead_another_home_claimed_alone() {
  local dir fakebin calls_log home id
  command -v jq >/dev/null 2>&1 || { pass "claimed-bead migration skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-claimed"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data/task-xyz"
  : > "$home/data/task-xyz/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # bead-shared already carries home A's scoped label, i.e. home A swept first.
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-shared","status":"open","labels":["task:task-xyz","task:home-a:task-xyz"]}]' \
    "bead-b-own"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure when its only candidate was another home's bead"
  assert_no_grep "tag bead-shared task:home-b:task-xyz" "$calls_log" \
    "the sweep claimed a bead another home had already scoped, so the two keep sharing it"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-b-own" ] \
    || fail "home B must mint its own bead once another home has scoped bead-shared, got: $id"
  pass "the sweep leaves a bead another home already scoped alone and that home mints its own"
}

# Regression: leaving the winner's bead alone is only enough for a task this
# home never dispatched. A DISPATCHED task is pinned to that shared bead by its
# own state/<id>.meta beads_id=, which bin/fm-crew-state.sh and bin/fm-teardown.sh
# read directly and never re-resolve, so a bare skip left both homes acting on
# one bead forever. The sweep must mint this home a bead of its own and repoint
# this home's OWN record at it, leaving the other home's bead untouched.
test_beads_migration_repoints_a_dispatched_task_off_another_homes_bead() {
  local dir fakebin calls_log home out got want
  command -v jq >/dev/null 2>&1 || { pass "repoint migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-repoint"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nworktree=/tmp/wt\nbeads_id=bead-shared\nproject=demo\n' \
    > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  # bead-shared already carries home A's scoped label, i.e. home A swept first.
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-shared","status":"open","labels":["task:task-xyz","task:home-a:task-xyz"]}]' \
    "bead-b-own"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels 2>&1) \
    || fail "repointing this home's own record is a success path, not a failure: $out"
  printf '%s\n' "$out" | grep -q "repointed task-xyz onto its own bead bead-b-own" \
    || fail "the sweep did not report the repointing, so an operator cannot see it: $out"

  got=$(cat "$home/state/task-xyz.meta")
  want=$(printf 'window=w1\nworktree=/tmp/wt\nbeads_id=bead-b-own\nproject=demo\n')
  [ "$got" = "$want" ] \
    || fail "the record must name this home's own bead with every other line and its order intact, got: $got"
  assert_no_grep "tag bead-shared" "$calls_log" \
    "the sweep wrote to the bead another home had already claimed"
  assert_absent "$home/state/task-xyz.meta.beads-repoint.$$" \
    "the repoint left its temporary record behind"
  pass "the sweep repoints a dispatched task off another home's bead onto one of its own"
}

# Regression: repoint must skip a task whose tmux endpoint is still alive.
# A live worker holds the old bead ID in its brief; rewriting meta under it
# would give the worker a stale reference it would then act on erroneously.
test_beads_migration_skips_repoint_for_live_endpoint() {
  local dir fakebin calls_log home out before
  command -v jq >/dev/null 2>&1 || { pass "live-endpoint repoint skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-repoint-live"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=live-w1\nbeads_id=bead-shared\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-shared","status":"open","labels":["task:task-xyz","task:home-a:task-xyz"]}]' \
    "bead-b-own"
  # A fake tmux that confirms live-w1 is alive (returns a pane id for display-message).
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "display-message" ] && [ "${4:-}" = "live-w1" ]; then
  printf '%%100\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  before=$(cat "$home/state/task-xyz.meta")

  # The sweep returns non-zero when a repoint is skipped so the durable marker
  # is not written and the sweep retries next session; capture the output
  # without treating non-zero as a test failure.
  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels 2>&1) || true
  printf '%s\n' "$out" | grep -q "skipping repoint of task-xyz" \
    || fail "the sweep did not log the live-endpoint skip diagnostic: $out"

  after=$(cat "$home/state/task-xyz.meta")
  [ "$before" = "$after" ] \
    || fail "the sweep rewrote meta for a task with a live endpoint, got: $after"
  assert_absent "$home/state/.beads-label-migration-v1" \
    "the marker must not be written when a repoint was skipped (so the sweep retries next session)"
  pass "the sweep skips repoint and logs a diagnostic when the task's tmux endpoint is alive"
}

# Test: the repointing path is safe to re-run. Once this home's own record names
# its replacement bead, the shared bead is no longer a candidate this home
# claims, so a second sweep mints nothing and rewrites nothing.
test_beads_migration_repoint_second_run_is_a_no_op() {
  local dir fakebin calls_log home mints before after
  command -v jq >/dev/null 2>&1 || { pass "repoint idempotence skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-repoint-twice"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nbeads_id=bead-shared\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-shared","status":"open","labels":["task:task-xyz","task:home-a:task-xyz"]}]' \
    "bead-b-own"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the first sweep reported failure against a healthy store"
  before=$(cat "$home/state/task-xyz.meta")

  # Drop the marker so the second pass runs for real and the store's own
  # evidence, not the one-shot record, has to carry the idempotence.
  rm -f "$home/state/.beads-label-migration-v1"
  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the second sweep reported failure with nothing left to do"

  after=$(cat "$home/state/task-xyz.meta")
  [ "$after" = "$before" ] \
    || fail "the second sweep rewrote an already-repointed record: $after"
  mints=$(grep -c '^create ' "$calls_log" || true)
  [ "$mints" = 1 ] || fail "the replacement bead should be minted exactly once, saw $mints"
  pass "re-running the sweep after a repoint mints nothing and rewrites nothing"
}

# Regression (silent pin): if the replacement bead cannot be minted, the task is
# still pointed at the other home's bead. Treating that as a clean pass would
# write the permanent one-shot marker and leave it pinned forever, so it must
# count as a failure and hold the marker back.
test_beads_migration_counts_a_failed_replacement_mint_as_a_failure() {
  local dir fakebin calls_log home out
  command -v jq >/dev/null 2>&1 || { pass "failed-mint migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-mint-fails"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nbeads_id=bead-shared\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # A store that answers every read but refuses the mint: the shape a write
  # outage actually takes once the sweep has already decided to repoint.
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
case "\$1 \${2:-}" in
  "label list-all") printf '%s\n' '[{"label":"task:task-xyz","count":1}]'; exit 0 ;;
  "label list") printf '%s\n' '["task:task-xyz","task:home-a:task-xyz"]'; exit 0 ;;
esac
case "\$1" in
  create) exit 1 ;;
  list)
    for a in "\$@"; do
      if [ "\$a" = "task:task-xyz" ]; then
        printf '%s\n' '[{"id":"bead-shared","status":"open"}]'
        exit 0
      fi
    done
    printf '%s\n' '[]'
    ;;
  *) printf '%s\n' '[]' ;;
esac
exit 0
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels 2>&1) \
    && fail "a task left pinned to another home's bead was reported as a clean sweep"
  printf '%s\n' "$out" | grep -q "could not mint task-xyz a bead of its own" \
    || fail "the sweep did not report the failed mint, so the pin is invisible: $out"
  assert_absent "$home/state/.beads-label-migration-v1" \
    "a failed mint still wrote the one-shot marker, so that task stays pinned forever"
  assert_grep "beads_id=bead-shared" "$home/state/task-xyz.meta" \
    "the record was rewritten even though no replacement bead exists"
  pass "a failed replacement mint counts as a failure and the sweep retries next session"
}

# Regression (silent pin, write half): the mint can succeed and the record
# rewrite still fail - another process is mid-write on that record. The task is
# then pinned to the other home's bead exactly as if nothing happened, so this
# too must count as a failure and hold the one-shot marker back.
test_beads_migration_counts_a_failed_repoint_write_as_a_failure() {
  local dir fakebin calls_log home out lock
  command -v jq >/dev/null 2>&1 || { pass "failed-repoint migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-repoint-write-fails"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nbeads_id=bead-shared\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-shared","status":"open","labels":["task:task-xyz","task:home-a:task-xyz"]}]' \
    "bead-b-own"

  # Hold the record's own write lock from a live process, which is what a
  # concurrent full-record rewrite looks like to the sweep.
  fm_beads_require_lock_lib || { pass "failed-repoint migration skipped without the lock library"; return; }
  lock=$(fm_meta_lock_path "$home/state/task-xyz.meta") \
    || fail "could not derive the record's write lock path"
  fm_lock_try_acquire "$lock" || fail "could not take the record's write lock in the test"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels 2>&1) \
    && { fm_lock_release "$lock"; fail "a record the sweep could not rewrite was reported as a clean sweep"; }
  fm_lock_release "$lock"

  printf '%s\n' "$out" | grep -q "could not repoint task-xyz's own record onto bead-b-own" \
    || fail "the sweep did not report the failed record rewrite, so the pin is invisible: $out"
  assert_absent "$home/state/.beads-label-migration-v1" \
    "a failed record rewrite still wrote the one-shot marker, so that task stays pinned forever"
  assert_grep "beads_id=bead-shared" "$home/state/task-xyz.meta" \
    "the record changed even though the sweep reported it could not be rewritten"
  pass "a failed record rewrite counts as a failure and the sweep retries next session"
}

# Regression: a slug this home holds no record for is not one of its tasks, so
# its pre-migration bead belongs to some other home and must be left untouched -
# the enumeration-side half of the same cross-home guarantee.
test_beads_migration_ignores_a_slug_this_home_has_no_record_for() {
  local dir fakebin calls_log home id
  command -v jq >/dev/null 2>&1 || { pass "unknown-slug migration skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-unknown"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-other","status":"open","labels":["task:task-xyz"]}]' \
    "bead-fresh"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure when it simply had no candidates of its own"
  assert_no_grep "tag bead-other" "$calls_log" \
    "the sweep claimed another home's pre-migration bead for a slug it has no record of"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-fresh" ] \
    || fail "a home that never owned the pre-migration bead must mint its own, got: $id"
  pass "the sweep ignores a pre-migration bead whose slug this home has no record for"
}

# Regression: task ids are reusable slugs and fm-teardown.sh closes a bead
# without stripping its label, so a finished task's unscoped label survives in
# the store forever. Re-tagging it would hand a brand-new task a bead that is
# already closed - the authoritative task-complete signal bin/fm-crew-state.sh
# reads under this backend - so the sweep must never touch a closed bead.
test_beads_migration_never_touches_closed_beads() {
  local dir fakebin calls_log home
  command -v jq >/dev/null 2>&1 || { pass "closed-bead migration skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-closed"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data/task-old"
  : > "$home/data/task-old/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-closed","status":"closed","labels":["task:task-old"]}]' \
    "bead-should-not-be-created"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure when its only legacy label was on a closed bead"
  assert_no_grep "tag bead-closed" "$calls_log" \
    "the sweep re-tagged a CLOSED bead, which would reconcile the next task on that slug as done"
  pass "the sweep never re-tags a closed bead"
}

# Test: the sweep is safe to re-run. The second pass must not repeat the re-tag,
# both because the durable marker records the completed pass and because a bead
# already carrying this home's scoped label is skipped on its own evidence.
test_beads_migration_second_run_is_a_no_op() {
  local dir fakebin calls_log home tags
  command -v jq >/dev/null 2>&1 || { pass "migration idempotence skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-twice"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data/task-xyz"
  : > "$home/data/task-xyz/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:task-xyz"]}]' \
    "bead-should-not-be-created"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the first sweep reported failure against a healthy store"
  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the second sweep reported failure with nothing left to do"
  tags=$(grep -c -F -- "tag bead-7 task:home-a:task-xyz" "$calls_log" || true)
  [ "$tags" = 1 ] || fail "the re-tag should happen exactly once across two sweeps, saw $tags"

  # Same again with the marker removed, so the store's own evidence carries it.
  rm -f "$home/state/.beads-label-migration-v1"
  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure re-running against an already-migrated bead"
  tags=$(grep -c -F -- "tag bead-7 task:home-a:task-xyz" "$calls_log" || true)
  [ "$tags" = 1 ] \
    || fail "an already-scoped bead was re-tagged when the marker was gone, saw $tags"
  pass "re-running the migration sweep is a no-op"
}

# Test: when the store's list payload already carries the bead's labels, the
# sweep's exclusivity check reads them from that payload and pays no second store
# call. The real CLI omits labels from list rows today (hence the `label list`
# fallback the tests above exercise), so this pins the behavior for a payload
# that does carry them and keeps the sweep from paying for both.
test_beads_migration_reads_labels_from_the_list_payload_when_present() {
  local dir fakebin calls_log home
  command -v jq >/dev/null 2>&1 || { pass "payload label read skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-labels-in-payload"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data/task-xyz"
  : > "$home/data/task-xyz/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:task-xyz"]}]' \
    "bead-should-not-be-created" true

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure against a store whose list rows carry labels"
  assert_grep "tag bead-7 task:home-a:task-xyz" "$calls_log" \
    "the sweep did not re-tag the bead when its labels came from the list payload"
  assert_no_grep "label list bead-7" "$calls_log" \
    "the sweep paid a second store call for labels the list payload already carried"
  pass "the sweep reads a bead's labels from the list payload when the store sends them"
}

# Regression (the weak-evidence claim): a data/backlog.md item id is NOT evidence
# that this home owns the slug. Every home that ever queued a task carries that
# line, including one that never dispatched it, so accepting it let a home claim
# the pre-migration bead a DIFFERENT home had already minted and recorded in its
# own state/<id>.meta. Nothing re-resolves that meta by label afterwards, so both
# homes then keep using one bead - exactly the sharing the scoped label exists to
# end. A backlog line alone must not even make the slug a candidate.
test_beads_migration_ignores_a_backlog_only_slug() {
  local dir fakebin calls_log home id
  command -v jq >/dev/null 2>&1 || { pass "backlog-only migration skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-backlog-only"
  home="$dir/home-a"
  mkdir -p "$home/state" "$home/data"
  # The whole of this home's record for task-xyz: a queued backlog line. No meta,
  # no brief - it was never dispatched or even scaffolded here.
  printf -- '- [x] task-xyz  ship something\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # bead-b is home B's: B minted it and recorded it in B's own meta.
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-b","status":"open","labels":["task:task-xyz"]}]' \
    "bead-a-own"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure when its only backlog line was not a candidate"
  assert_no_grep "tag bead-b" "$calls_log" \
    "a backlog line alone let this home claim another home's pre-migration bead"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-a-own" ] \
    || fail "a backlog-only home must mint its own bead rather than share, got: $id"
  pass "a backlog item id alone is not ownership evidence for the migration sweep"
}

# The other half of the tightened rule: a home whose own dispatch record names
# the pre-migration bead exactly still claims it. That is the strongest evidence
# there is, and dropping the backlog class must not cost it.
test_beads_migration_claims_a_bead_this_homes_meta_records() {
  local dir fakebin calls_log home
  command -v jq >/dev/null 2>&1 || { pass "meta-recorded migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-meta-records"
  home="$dir/home-a"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nbeads_id=bead-7\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-7","status":"open","labels":["task:task-xyz"]}]' \
    "bead-should-not-be-created"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "the sweep reported failure against its own dispatched task's bead"
  assert_grep "tag bead-7 task:home-a:task-xyz" "$calls_log" \
    "the sweep left the bead its own dispatch record names unmigrated"
  pass "the sweep claims the pre-migration bead this home's own meta records"
}

# A meta is a candidate record, not a claim. One that names no bead at all, and
# has no brief beside it, does not say this bead is ours, so the sweep must leave
# it alone rather than treat the mere existence of a meta as ownership.
test_beads_migration_leaves_a_bead_its_records_do_not_name() {
  local dir fakebin calls_log home id
  command -v jq >/dev/null 2>&1 || { pass "unclaimed-bead migration skip skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-unclaimed"
  home="$dir/home-a"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" \
    '[{"id":"bead-other","status":"open","labels":["task:task-xyz"]}]' \
    "bead-a-own"

  PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels >/dev/null \
    || fail "leaving an unclaimed bead alone is a skip, not a failure"
  assert_no_grep "tag bead-other" "$calls_log" \
    "a meta naming no bead let this home claim a pre-migration bead anyway"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a STATE="$home/state" DATA="$home/data" \
    fm_beads_resolve_or_create "task-xyz")
  [ "$id" = "bead-a-own" ] \
    || fail "a home holding no claiming record must mint its own bead, got: $id"
  pass "the sweep leaves a pre-migration bead none of this home's records name"
}

# Regression (silent skip then permanent marker): a per-candidate lookup that
# FAILS is not a lookup that found nothing. Collapsing the two took the benign
# "the surviving label belongs to a closed record" path, wrote the permanent
# one-shot marker, and left that bead unmigrated forever. A failed lookup must
# count as a failure and hold the marker back so the next session retries.
test_beads_migration_counts_a_failed_candidate_lookup_as_a_failure() {
  local dir fakebin calls_log home out marker
  command -v jq >/dev/null 2>&1 || { pass "failed-lookup migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-lookup-fails"
  home="$dir/home-a"
  mkdir -p "$home/state" "$home/data/task-xyz"
  : > "$home/data/task-xyz/brief.md"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # A store that answers the liveness probe and the whole-store label list, then
  # fails the per-candidate lookup: the shape a store hiccup actually takes.
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
case "\$1 \${2:-}" in
  "label list-all") printf '%s\n' '[{"label":"task:task-xyz","count":1}]' ;;
  *)
    for a in "\$@"; do
      [ "\$a" = "--label" ] && exit 1
    done
    printf '%s\n' '[]'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a \
    STATE="$home/state" DATA="$home/data" fm_beads_migrate_legacy_task_labels 2>&1) \
    && fail "a failed per-candidate lookup was reported as a clean sweep"
  printf '%s\n' "$out" | grep -q "could not look up task-xyz" \
    || fail "the sweep did not report the failed lookup, so the store hiccup is invisible: $out"

  marker="$home/state/.beads-label-migration-v1"
  assert_absent "$marker" \
    "a failed lookup still wrote the one-shot marker, so that bead never migrates"
  pass "a failed per-candidate lookup counts as a failure and the sweep retries next session"
}

# Regression (unreadable store read as a clean one): the whole-store label list
# is the sweep's only evidence that there is nothing left to migrate, and an
# exit-0 answer that is not a JSON array parses to the same empty result a clean
# store gives. Taking that as "clean" wrote the permanent one-shot marker, so
# every pre-migration bead stayed orphaned forever with no second chance.
test_beads_migration_reports_an_unreadable_label_list_as_unmigrated() {
  local dir fakebin calls_log home out
  command -v jq >/dev/null 2>&1 || { pass "unreadable-label-list migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-label-list-unreadable"
  home="$dir/home-a"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # A store that is up and answers the liveness probe, then hands back an error
  # object instead of a label array: the shape a store that is reachable but
  # cannot serve this one query actually takes.
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
case "\$1 \${2:-}" in
  "label list-all") printf '%s\n' '{"error":"label index unavailable"}' ;;
  *) printf '%s\n' '[]' ;;
esac
exit 0
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a \
    STATE="$home/state" DATA="$home/data" fm_beads_migrate_legacy_task_labels 2>&1) \
    && fail "an unreadable label list was reported as a clean sweep"
  printf '%s\n' "$out" | grep -q "label list could not be read" \
    || fail "the sweep did not report the unreadable label list: $out"
  assert_absent "$home/state/.beads-label-migration-v1" \
    "an unreadable label list still wrote the one-shot marker, so nothing ever migrates"
  pass "an unreadable label list is reported as unmigrated rather than as a clean store"
}

# Regression (duplicate replacement bead): on the repoint path the sweep asks
# whether this home already minted itself a replacement before minting one. A
# failed read there answers "no" exactly like a genuine miss, so a first pass
# that minted a replacement and then failed its record rewrite would mint a
# SECOND replacement on the retry and leave the first open forever. A read that
# fails must count as a failure and mint nothing.
test_beads_migration_counts_a_failed_replacement_lookup_as_a_failure() {
  local dir fakebin calls_log home out mints
  command -v jq >/dev/null 2>&1 || { pass "failed-replacement-lookup migration skipped without jq"; return; }
  dir="$TMP_ROOT/migrate-replacement-lookup-fails"
  home="$dir/home-b"
  mkdir -p "$home/state" "$home/data"
  printf 'window=w1\nbeads_id=bead-shared\n' > "$home/state/task-xyz.meta"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  # A store that serves every read the sweep needs to decide on the repoint, then
  # fails only the scoped replacement lookup that gates the mint.
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$calls_log"
case "\$1 \${2:-}" in
  "label list-all") printf '%s\n' '[{"label":"task:task-xyz","count":1}]'; exit 0 ;;
  "label list") printf '%s\n' '["task:task-xyz","task:home-a:task-xyz"]'; exit 0 ;;
esac
case "\$1" in
  list)
    for a in "\$@"; do
      [ "\$a" = "task:home-b:task-xyz" ] && exit 1
      if [ "\$a" = "task:task-xyz" ]; then
        printf '%s\n' '[{"id":"bead-shared","status":"open"}]'
        exit 0
      fi
    done
    printf '%s\n' '[]'
    ;;
  *) printf '%s\n' '[]' ;;
esac
exit 0
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-b STATE="$home/state" DATA="$home/data" \
    fm_beads_migrate_legacy_task_labels 2>&1) \
    && fail "a failed replacement lookup was reported as a clean sweep"
  printf '%s\n' "$out" | grep -q "could not look up task-xyz's replacement bead" \
    || fail "the sweep did not report the failed replacement lookup: $out"
  mints=$(grep -c '^create ' "$calls_log" || true)
  [ "$mints" = 0 ] \
    || fail "the sweep minted a replacement bead it could not first rule out, saw $mints"
  assert_absent "$home/state/.beads-label-migration-v1" \
    "a failed replacement lookup still wrote the one-shot marker, so that task stays pinned forever"
  assert_grep "beads_id=bead-shared" "$home/state/task-xyz.meta" \
    "the record was rewritten even though no replacement bead was resolved"
  pass "a failed replacement lookup counts as a failure and mints no duplicate bead"
}

# Test: the ordinary dispatch path - taken at every brief scaffold and every
# spawn, permanently - costs exactly one store lookup and writes nothing. A
# second compatibility read or a migration write here would be paid forever, and
# it is what the one-shot sweep exists to keep off this path.
test_beads_resolve_issues_one_lookup_and_no_write_beyond_the_mint() {
  local dir fakebin calls_log id lookups
  command -v jq >/dev/null 2>&1 || { pass "resolve call-count skipped without jq"; return; }
  dir="$TMP_ROOT/resolve-call-count"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  calls_log="$dir/calls.log"
  add_beads_task_mock_store "$fakebin" "$calls_log" '[]' "bead-99"

  id=$(PATH="$fakebin:$PATH" FM_BEADS_HOME_SCOPE=home-a fm_beads_resolve_or_create "task-abc")
  [ "$id" = "bead-99" ] || fail "expected minted bead id bead-99, got: $id"
  lookups=$(grep -c '^list ' "$calls_log" || true)
  [ "$lookups" = 1 ] \
    || fail "the resolve path should issue exactly one store lookup, saw $lookups"
  assert_no_grep "tag " "$calls_log" \
    "the resolve path wrote a migration tag, which every scaffold and spawn would then pay"
  assert_no_grep "label list" "$calls_log" \
    "the resolve path paid a label read it has no decision to make with"
  pass "the ordinary resolve path issues one lookup and no migration write"
}

# Regression: FM_HOME reaches fm_beads_home_scope through callers that do not
# canonicalize it, so one home spelled with a trailing slash, relatively, or
# through a symlink must still hash to ONE scope. Two spellings hashing apart
# would strand the intake bead fm-brief.sh minted where fm-spawn.sh cannot find
# it, mint a duplicate, and leave the first bead open forever.
test_beads_home_scope_normalizes_home_path_spellings() {
  local dir home link plain slashed via_link relative absent absent_slashed
  dir="$TMP_ROOT/home-scope-normalize"
  home="$dir/real-home"
  link="$dir/linked-home"
  mkdir -p "$home"
  ln -sfn "$home" "$link"

  plain=$(FM_HOME="$home" fm_beads_home_scope) || plain=
  [ -n "$plain" ] || fail "fm_beads_home_scope produced nothing for an existing home"
  slashed=$(FM_HOME="$home/" fm_beads_home_scope)
  [ "$plain" = "$slashed" ] \
    || fail "a trailing slash must not change the scope ('$plain' vs '$slashed')"
  via_link=$(FM_HOME="$link" fm_beads_home_scope)
  [ "$plain" = "$via_link" ] \
    || fail "a symlinked spelling must not change the scope ('$plain' vs '$via_link')"
  relative=$(cd "$dir" && FM_HOME="real-home" fm_beads_home_scope)
  [ "$plain" = "$relative" ] \
    || fail "a relative spelling must not change the scope ('$plain' vs '$relative')"

  # An unresolvable home still yields a deterministic scope rather than failing,
  # and the trailing slash is still stripped before hashing.
  absent=$(FM_HOME="$dir/not-created-yet" fm_beads_home_scope) || absent=
  [ -n "$absent" ] || fail "an unresolvable home must still yield a scope"
  absent_slashed=$(FM_HOME="$dir/not-created-yet/" fm_beads_home_scope)
  [ "$absent" = "$absent_slashed" ] \
    || fail "a trailing slash must not change an unresolvable home's scope"
  pass "fm_beads_home_scope normalizes trailing-slash, relative, and symlinked spellings of one home"
}

# Test: the library stays sourceable on its own. It is copied WITHOUT its
# siblings into partially-synced remote code roots (tests/fm-on.test.sh,
# tests/fm-remote-backlog-handoff.test.sh build exactly that fixture), where the
# scripts that source it run under `set -eu` and must still reach the report that
# names what the host is missing. An unguarded source of fm-timeout-lib.sh aborts
# them at load time instead.
test_lib_sources_without_its_siblings() {
  local dir="$TMP_ROOT/lonely-lib" out rc
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-tasks-axi-lib.sh" "$dir/bin/"
  cat > "$dir/consumer.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/bin/fm-tasks-axi-lib.sh"
printf 'reached-the-end\n'
SH
  chmod +x "$dir/consumer.sh"
  out=$("$dir/consumer.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "sourcing fm-tasks-axi-lib.sh alone under set -eu exited $rc: $out"
  [ "$out" = "reached-the-end" ] \
    || fail "sourcing fm-tasks-axi-lib.sh alone did not reach the next statement: $out"
  pass "fm-tasks-axi-lib.sh stays sourceable under set -eu when no sibling libs are co-located"
}

# Test: fm_beads_status distinguishes a completed read, an absent bead, and a read
# that never answered. Conflating the last two loses a queued write: an unanswered
# read is not evidence the bead is gone.
test_beads_status_read_outcomes() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status outcomes skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-open --json') printf '%s\n' '[{"id":"bd-open","status":"open"}]'; exit 0 ;;
  'show bd-closed --json') printf '%s\n' '[{"id":"bd-closed","status":"closed"}]'; exit 0 ;;
  'show bd-slow --json') sleep 5; printf '%s\n' '[{"id":"bd-slow","status":"open"}]'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-open) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a completed read of an existing bead must return 0, got $rc"
  [ "$out" = open ] || fail "expected status 'open' for bd-open, got: $out"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-gone) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_ABSENT" ] \
    || fail "an absent bead must return FM_BEADS_STATUS_RC_ABSENT, got $rc"
  [ -z "$out" ] || fail "an absent bead must print nothing, got: $out"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT=1 fm_beads_status bd-slow) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
    || fail "a read that hit its bound must return FM_BEADS_STATUS_RC_UNREADABLE, got $rc"
  [ -z "$out" ] || fail "a read that hit its bound must print nothing, got: $out"

  PATH="$fakebin:$PATH" fm_beads_is_closed bd-closed \
    || fail "fm_beads_is_closed must be true for a bead the store reports closed"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-open \
    && fail "fm_beads_is_closed must be false for an open bead"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-gone \
    && fail "fm_beads_is_closed must be false for an absent bead"
  PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT=1 fm_beads_is_closed bd-slow \
    && fail "fm_beads_is_closed must fail open (not closed) when the read never answered"
  pass "fm_beads_status separates a completed read, an absent bead, and an unanswered read"
}

# Test: a failed read against a store that is DOWN is not evidence the bead is
# gone. `task show` exits non-zero for a missing bead and for an unreachable,
# locked, or unauthenticated store alike, so the classification must rest on
# whether the store itself answered - a down store is unreadable, not absent.
test_beads_status_down_store_is_not_absent() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status down-store skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status-down"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
exit 1
SH
  chmod +x "$fakebin/task"

  out=$(PATH="$fakebin:$PATH" fm_beads_status bd-any) && rc=0 || rc=$?
  [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
    || fail "a failed read against an unreachable store must be UNREADABLE, not absent (got $rc)"
  [ -z "$out" ] || fail "a failed read against an unreachable store must print nothing, got: $out"
  PATH="$fakebin:$PATH" fm_beads_is_closed bd-any \
    && fail "fm_beads_is_closed must fail open (not closed) when the store is unreachable"
  pass "fm_beads_status reports an unreachable store as unreadable rather than an absent bead"
}

# Test: a non-positive bound is not a bound. bin/fm-timeout-lib.sh documents that
# `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline, so an
# operator-supplied zero must be rejected before it reaches fm_run_timed - it is
# all-digits and would otherwise pass a digits-only validator and let a wedged
# store stall the read forever. Runs in a child process because the bound is
# sanitized from the environment when the library is sourced.
test_beads_status_rejects_non_positive_bound() {
  local dir fakebin consumer rc value
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_status bound skipped without jq"; return; }
  dir="$TMP_ROOT/beads-status-bound"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'show bd-hang --json') sleep 30 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"

  consumer="$dir/consumer.sh"
  cat > "$consumer" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-tasks-axi-lib.sh"
fm_beads_status bd-hang
exit \$?
SH
  chmod +x "$consumer"

  for value in 0 00; do
    PATH="$fakebin:$PATH" FM_BEADS_STATUS_TIMEOUT="$value" \
      fm_run_timed 15 "$consumer" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -ne 124 ] \
      || fail "FM_BEADS_STATUS_TIMEOUT=$value left the store read unbounded"
    [ "$rc" -eq "$FM_BEADS_STATUS_RC_UNREADABLE" ] \
      || fail "FM_BEADS_STATUS_TIMEOUT=$value must fall back to a real bound and report unreadable, got $rc"
  done
  pass "fm_beads_status rejects a non-positive bound instead of running the read unbounded"
}

# add_beads_task_mock_sync <fakebin_dir> <control_dir>: a fake `task` CLI for the
# store-provisioning and Dolt-sync helpers, driven entirely by files the test
# writes under <control_dir>, so one fake covers every success and failure shape:
#   calls.log     every argv the fake saw, one line per call (written by the fake)
#   list.rc       exit status for `task list`      (default 0, store answers)
#   remotes.json  what `task dolt remote list --json` prints  (default "[]")
#   remote.rc     exit status for `task dolt remote list`  (default 0; non-zero
#                 makes the listing itself fail, as an older bd without the
#                 subcommand or an unreachable store would)
#   commit.out    what `task dolt commit` prints  (default nothing)
#   commit.rc / push.rc / pull.rc   exit status per dolt subcommand (default 0)
#   commit.sleep / push.sleep / remote.sleep / list.sleep   seconds that
#                 subcommand hangs before answering (default 0)
#   bootstrap.rc  exit status for `task bootstrap` (default 0)
#   bootstrap.leaves_broken   when present, bootstrap "succeeds" without making
#                             the store answer a read
add_beads_task_mock_sync() {
  local fakebin_dir=$1 control=$2
  mkdir -p "$control"
  cat > "$fakebin_dir/task" <<SH
#!/usr/bin/env bash
control="$control"
printf '%s\n' "\$*" >> "\$control/calls.log"
read_control() { # <file> <default>
  if [ -f "\$control/\$1" ]; then cat "\$control/\$1"; else printf '%s' "\$2"; fi
}
case "\${1:-} \${2:-}" in
  'dolt remote')
    hang=\$(read_control remote.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    remote_rc=\$(read_control remote.rc 0)
    if [ "\$remote_rc" != 0 ]; then
      printf 'unknown command "remote" for "bd dolt"\n' >&2
      exit "\$remote_rc"
    fi
    read_control remotes.json '[]'
    printf '\n'
    exit 0
    ;;
  'dolt commit')
    hang=\$(read_control commit.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    read_control commit.out ''
    exit "\$(read_control commit.rc 0)"
    ;;
  'dolt push')
    hang=\$(read_control push.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    exit "\$(read_control push.rc 0)"
    ;;
  'dolt pull') exit "\$(read_control pull.rc 0)" ;;
esac
case "\${1:-}" in
  list)
    hang=\$(read_control list.sleep 0)
    [ "\$hang" = 0 ] || sleep "\$hang"
    exit "\$(read_control list.rc 0)"
    ;;
  bootstrap)
    [ -f "\$control/bootstrap.leaves_broken" ] || printf '0' > "\$control/list.rc"
    exit "\$(read_control bootstrap.rc 0)"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin_dir/task"
}

# beads_sync_fixture <name>: make a fixture dir, drop the fake `task` in it, and
# print "<fakebin> <control>" for the caller to read.
beads_sync_fixture() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  add_beads_task_mock_sync "$fakebin" "$dir/control"
  printf '%s %s\n' "$fakebin" "$dir/control"
}

# beads_sync_publisher_fixture <name>: a sync fixture whose PUBLISHER is a stub
# under the test's own control, so the sweep's delegation, relay, and bounding
# can be driven precisely without the real publisher's own steps. Prints
# "<fakebin> <control> <stub>". Control files:
#   backup.argv    every argv the stub publisher saw (written by the stub)
#   backup.lines   the BEADS_BACKUP: lines it prints (default: one verified line)
#   backup.rc      exit status it returns (default 0)
#   backup.sleep   seconds it hangs before answering (default 0)
beads_sync_publisher_fixture() {
  local dir="$TMP_ROOT/$1" fakebin stub
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  add_beads_task_mock_sync "$fakebin" "$dir/control"
  printf '%s' '[{"name":"mini1"}]' > "$dir/control/remotes.json"
  stub="$dir/fm-beads-remote-backup.sh"
  cat > "$stub" <<SH
#!/usr/bin/env bash
set -u
control="$dir/control"
printf '%s\n' "\$*" >> "\$control/backup.argv"
hang=\$(cat "\$control/backup.sleep" 2>/dev/null || printf '%s' 0)
[ "\$hang" = 0 ] || sleep "\$hang"
cat "\$control/backup.lines" 2>/dev/null || true
exit "\$(cat "\$control/backup.rc" 2>/dev/null || printf '%s' 0)"
SH
  chmod +x "$stub"
  printf 'BEADS_BACKUP: pushed-verified: %s\n' \
    "'mini1' now shares local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" > "$dir/control/backup.lines"
  printf '%s %s %s\n' "$fakebin" "$dir/control" "$stub"
}

# beads_sync_publisher_end_to_end_fixture <name>: the same shape, but the sweep
# keeps its REAL publisher (bin/fm-beads-remote-backup.sh) and only the store
# CLI and the reachability probe are faked. This is what proves the actual
# wiring rather than a stub's imitation of it. Prints "<fakebin> <control>".
# Extra control files beyond add_beads_task_mock_sync's:
#   argv.log      every argv the fake task CLI saw (written by the fake)
#   remotes.txt   `task dolt remote list` output (default: the approved entry)
#   push.rc / fetch.rc / commit.rc   exit statuses (default 0)
#   local.hash / remote.hash   what the two head reads answer
#   curl.code     HTTP code the reachability probe sees (default 401)
beads_sync_publisher_end_to_end_fixture() {
  local dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/control"
  printf '%s' '[{"name":"mini1"}]' > "$dir/control/remotes.json"
  cat > "$fakebin/task" <<SH
#!/usr/bin/env bash
set -u
control="$dir/control"
printf '%s\n' "\$*" >> "\$control/argv.log"
read_control() { # <file> <default>
  if [ -f "\$control/\$1" ]; then cat "\$control/\$1"; else printf '%s' "\$2"; fi
}
case "\${1:-} \${2:-}" in
  'dolt remote')
    if [ "\${4:-}" = --json ]; then printf '%s\n' '[{"name":"mini1"}]'; exit 0; fi
    read_control remotes.txt 'mini1                http://100.102.238.78:3310/tasks'; exit 0 ;;
  'dolt remote add') printf 'added'; exit 0 ;;
  'dolt commit') read_control commit.out ''; exit "\$(read_control commit.rc 0)" ;;
esac
if [ "\${1:-}" = sql ]; then
  case "\${2:-}" in
    'select 1') exit 0 ;;
    'call dolt_push'*) exit "\$(read_control push.rc 0)" ;;
    'call dolt_fetch'*) exit "\$(read_control fetch.rc 0)" ;;
    # The real store keeps the remote-tracking branch in dolt_remote_branches
    # and answers zero rows for it out of dolt_branches; reproducing that here
    # is what makes the separation real rather than incidental.
    *dolt_remote_branches*) read_control remote.hash 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; exit 0 ;;
    *"remotes/"*) printf '(0 rows)\n'; exit 0 ;;
    *"where name='main'"*) read_control local.hash 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; exit 0 ;;
  esac
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/task"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
control="$dir/control"
if [ -f "\$control/curl.code" ]; then cat "\$control/curl.code"; else printf '%s' 401; fi
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s %s\n' "$fakebin" "$dir/control"
}

# Test: fm_beads_store_reachable() decides purely on whether the CLI answers a
# read. It must never infer a store from the filesystem: the `task` wrapper pins
# BEADS_DIR for the whole federation, so a home with no local .beads/ directory
# can be perfectly healthy and a host with one can still be broken.
test_beads_store_reachable_tracks_the_cli_answer() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture store-reachable)"

  PATH="$fakebin:$PATH" fm_beads_store_reachable ||
    fail "store should be reachable when the task CLI answers a read"

  printf '1' > "$control/list.rc"
  if PATH="$fakebin:$PATH" fm_beads_store_reachable; then
    fail "store should be unreachable when the task CLI fails a read"
  fi

  if PATH="$(fm_path_without task)" fm_beads_store_reachable; then
    fail "store should be unreachable when no task CLI exists at all"
  fi
  pass "fm_beads_store_reachable decides on the CLI's answer, not on a local .beads directory"
}

# Test: fm_beads_store_reachable honours the bound its CALLER passed, and stays
# unbounded when the caller passed none. Both halves are load-bearing and pull in
# opposite directions, which is why the bound is a per-call argument rather than
# one library-wide default:
#   - bin/fm-bootstrap.sh's sync sweep passes a bound carved out of the session
#     start budget. Substituting a shorter library default silently shrinks that
#     budget; substituting a longer one lets the probe overrun the whole stage.
#   - fm_beads_bootstrap_store's refuse-over-a-live-store guard passes NO bound
#     on purpose. A live-but-slow store answering late still means "live", and
#     reading it as unreachable is the one mistake provisioning must never make,
#     because the next step creates a second empty database beside the real one.
# A merge that leaves two definitions of this function in the file compiles and
# passes every other test in this suite while breaking exactly these guarantees,
# so they are asserted directly on observable return codes.
test_beads_store_reachable_honours_the_callers_bound() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture store-reachable-bound)"
  # The store answers, but only after 2s - longer than the status-read default.
  printf '2' > "$control/list.sleep"

  # A bound WIDER than the store is slow must let the read succeed, and the
  # library default is deliberately set narrower than the store's 2s so a
  # definition that substitutes it fails here instead of passing by luck.
  FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_store_reachable 10 \
    || fail "an explicit 10s bound must let a store that answers in 2s read as reachable"

  # ...and a bound NARROWER than the store is slow must cut the read off, with
  # the default set wide this time so the bound cannot be credited to it.
  if FM_BEADS_STATUS_TIMEOUT=30 PATH="$fakebin:$PATH" fm_beads_store_reachable 1; then
    fail "an explicit 1s bound must not be widened by a library default"
  fi

  FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_store_reachable \
    || fail "the unbounded form must not inherit a library default and read a live store as gone"

  pass "fm_beads_store_reachable applies the caller's bound, and none when the caller passed none"
}

# Test: the safety consequence of the above, asserted end to end. A store that is
# alive but slow to answer must still make provisioning REFUSE. This is the case
# that turns a silently-ignored bound into data loss rather than a slow session:
# bootstrap cannot see a Dolt sql-server store, so a false "unreachable" here is
# what puts a fresh empty database next to the live one.
test_beads_bootstrap_refuses_over_a_slow_live_store() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-refuse-slow)"
  printf '2' > "$control/list.sleep"

  if out=$(FM_BEADS_STATUS_TIMEOUT=1 PATH="$fakebin:$PATH" fm_beads_bootstrap_store 2>&1); then
    fail "bootstrap should refuse a live-but-slow store, got success: $out"
  fi
  assert_no_grep "bootstrap" "$control/calls.log" \
    "bootstrap ran over a live store that merely answered slowly"
  pass "fm_beads_bootstrap_store refuses a live store that answers slower than the status-read default"
}

# Test: fm_beads_bootstrap_store() refuses whenever the store already answers.
# This guard is the whole safety margin for provisioning: `bd bootstrap` inspects
# the .beads/ directory and cannot see a store served by a Dolt sql-server, so
# against a healthy server-mode store it would happily create a fresh empty
# database beside the live one.
test_beads_bootstrap_refuses_over_a_live_store() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-refuse)"

  if out=$(PATH="$fakebin:$PATH" fm_beads_bootstrap_store 2>&1); then
    fail "bootstrap should refuse a store that already answers, got success"
  fi
  case "$out" in
    *'bootstrap refused'*) ;;
    *) fail "bootstrap refusal did not explain itself, got: $out" ;;
  esac
  assert_no_grep "bootstrap" "$control/calls.log" \
    "bootstrap ran against a live store instead of refusing"
  pass "fm_beads_bootstrap_store refuses to bootstrap over a store that already answers"
}

# Test: fm_beads_bootstrap_store() provisions a home whose store genuinely does
# not answer, using the non-destructive `bootstrap` verb rather than an init.
test_beads_bootstrap_provisions_an_unreachable_store() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-provision)"
  printf '1' > "$control/list.rc"

  PATH="$fakebin:$PATH" fm_beads_bootstrap_store >/dev/null 2>&1 ||
    fail "bootstrap should provision a store that does not answer"
  assert_grep "bootstrap --yes" "$control/calls.log" \
    "provisioning did not run the non-destructive bootstrap verb"
  assert_no_grep "init" "$control/calls.log" \
    "provisioning reached for a destructive init instead of bootstrap"
  pass "fm_beads_bootstrap_store provisions an unreachable store with the non-destructive bootstrap verb"
}

# Test: a bootstrap that exits 0 without leaving a store that answers is still a
# failure. Provisioning is judged by the store's own read, never by the CLI's
# exit status, so a half-provisioned home is reported rather than assumed good.
test_beads_bootstrap_verifies_rather_than_trusting_exit_status() {
  local fakebin control
  read -r fakebin control <<< "$(beads_sync_fixture bootstrap-unverified)"
  printf '1' > "$control/list.rc"
  : > "$control/bootstrap.leaves_broken"

  if PATH="$fakebin:$PATH" fm_beads_bootstrap_store >/dev/null 2>&1; then
    fail "bootstrap reported success even though the store still does not answer"
  fi
  pass "fm_beads_bootstrap_store judges provisioning by the store's own read, not the CLI's exit status"
}

# Test: with no Dolt remote configured, sync is inert and succeeds. A
# single-machine store is a legitimate posture - firstmate never configures a
# remote on its own, because that would publish task data to a destination the
# captain has not approved - so sync must say so plainly and touch nothing.
test_beads_sync_is_inert_without_a_configured_remote() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-no-remote)"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) ||
    fail "sync with no remote configured must succeed, got failure: $out"
  case "$out" in
    *'no Dolt remote configured'*) ;;
    *) fail "sync did not report the missing remote, got: $out" ;;
  esac
  assert_no_grep "dolt push" "$control/calls.log" \
    "sync pushed despite no configured remote"
  assert_no_grep "dolt commit" "$control/calls.log" \
    "sync committed despite no configured remote"
  pass "fm_beads_sync_once stays inert and succeeds when no Dolt remote is configured"
}

# Test: an unreadable remote listing is never reported as "no remote
# configured". The empty-listing line is documented as the expected steady state
# and explicitly not a failure, so folding a failing listing into it would leave
# a home that IS configured silently not syncing, behind the one line that tells
# the reader not to investigate.
test_beads_sync_separates_an_unreadable_remote_list_from_an_empty_one() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-remote-unreadable)"
  printf '1' > "$control/remote.rc"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "an unreadable remote listing was reported as a clean no-op, got: $out"
  fi
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "sync did not report that it could not read the remote list, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "an unreadable remote listing was reported as the benign single-machine posture, got: $out"
      ;;
  esac
  assert_no_grep "dolt push" "$control/calls.log" \
    "sync pushed without knowing whether a remote is configured"
  pass "fm_beads_sync_once separates an unreadable remote listing from a genuinely empty one"
}

# Test: the same separation when jq itself is absent. jq is not an unconditional
# requirement of bootstrap, so this path is reachable on a real host, and it
# must not masquerade as a store that has no remote.
test_beads_sync_reports_a_missing_jq_rather_than_assuming_no_remote() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-no-jq)"
  # On Linux, jq and date share the same directory (/usr/bin).  fm_path_without
  # jq removes every directory that has jq, so date disappears too, and
  # fm_beads_sync_once then fails at the deadline computation (date +%s) before
  # it ever reaches the jq check.  Symlink the real date into fakebin so it
  # survives the PATH excision while jq itself remains absent.
  ln -sf "$(command -v date)" "$fakebin/date"

  if out=$(PATH="$fakebin:$(fm_path_without jq)" fm_beads_sync_once 2>&1); then
    fail "sync with no jq was reported as a clean no-op, got: $out"
  fi
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "sync did not report that it could not read the remote list, got: $out" ;;
  esac
  case "$out" in
    *'jq'*) ;;
    *) fail "sync did not name the missing tool, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "a missing jq was reported as the benign single-machine posture, got: $out"
      ;;
  esac
  pass "fm_beads_sync_once names a missing jq instead of assuming no remote is configured"
}

# Test: an unreadable clock must never be disguised as an exhausted budget.
#
# CI caught this the hard way. On Linux jq and date share /usr/bin, so the
# fm_path_without jq excision above took date with it, `$(date +%s)` expanded to
# nothing, and `$(( + FM_BEADS_SYNC_BUDGET ))` collapsed to the budget alone - a
# 1970 deadline that made every bounded step report the budget as already spent.
# On a host where date sits in its own directory the excision leaves it in
# place, which is exactly why this passed locally and failed only in CI.
#
# A stub is used rather than a PATH excision on purpose: removing the directory
# that holds date would take jq and the rest of coreutils with it on Linux and
# prove nothing about the clock.
#
# The invariant asserted here holds on every shell - a clock the sweep cannot
# read is either transparently survived (EPOCHSECONDS needs no PATH at all) or
# reported on its own line, but never rendered as a spent budget and never
# leaked as a raw shell error. Asserting the invariant instead of one branch
# keeps this honest on a shell too old to export EPOCHSECONDS.
test_beads_sync_never_reports_an_unreadable_clock_as_a_spent_budget() {
  local fakebin control out rc=0
  read -r fakebin control <<< "$(beads_sync_fixture sync-no-clock)"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/date"
  chmod +x "$fakebin/date"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) || rc=$?

  case "$out" in
    *'budget was spent'*)
      fail "an unreadable clock was misreported as an exhausted budget, got: $out"
      ;;
  esac
  case "$out" in
    *'command not found'*)
      fail "an unreadable clock leaked a raw shell error into the diagnostics, got: $out"
      ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      [ "$rc" -eq 0 ] ||
        fail "an ordinary sweep reported failure, rc=$rc, got: $out"
      ;;
    *'clock is unreadable'*)
      [ "$rc" -ne 0 ] ||
        fail "a named clock failure was reported as success, got: $out"
      ;;
    *)
      fail "expected either an ordinary sweep or an explicit clock line, got: $out"
      ;;
  esac
  pass "an unreadable clock is survived or named, never disguised as a spent budget"
}

# Test: with EPOCHSECONDS unavailable too, the clock failure gets its own
# diagnostic rather than a number. That is the branch a shell without
# EPOCHSECONDS takes, forced here so the guard is exercised on every host
# instead of only where the fallback happens to be reached.
test_beads_sync_names_a_clock_it_cannot_read() {
  local fakebin control out rc=0
  read -r fakebin control <<< "$(beads_sync_fixture sync-clock-named)"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/date"
  chmod +x "$fakebin/date"

  out=$(unset EPOCHSECONDS; PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) || rc=$?

  [ "$rc" -ne 0 ] ||
    fail "an unreadable clock must not be reported as a successful sweep, got: $out"
  case "$out" in
    *'clock is unreadable'*) ;;
    *) fail "sync did not name the unreadable clock, got: $out" ;;
  esac
  case "$out" in
    *'budget was spent'*)
      fail "the clock failure was reported as a spent budget, got: $out"
      ;;
  esac
  pass "fm_beads_sync_once names a clock it cannot read instead of bounding against it"
}

# Test: the remote leg is DELEGATED, not reimplemented. The store has no Dolt
# `origin` and the client holds no mesh credential, so the sweep must never
# issue its own `task dolt push`/`pull`; it hands the whole leg to the approved
# publisher and relays that publisher's outcomes instead. This asserts the
# delegation, the relay, and the absence of every client-side Dolt remote
# command in one pass, because a sweep that pushed by itself would still pass a
# relay-only assertion.
test_beads_sync_delegates_the_remote_leg_and_relays_every_outcome() {
  local fakebin control stub out
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-delegates)"
  printf '%s\n' \
    "BEADS_BACKUP: repaired: re-added the 'mini1' Dolt remote (http://100.102.238.78:3310/tasks)" \
    "BEADS_BACKUP: pushed-verified: 'mini1' now shares local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" \
    > "$control/backup.lines"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" fm_beads_sync_once 2>&1) ||
    fail "a healthy delegated sync must succeed, got: $out"
  case "$out" in
    *"BEADS_SYNC: pushed-verified: 'mini1' now shares local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"*) ;;
    *) fail "the publisher's terminal outcome was not relayed, got: $out" ;;
  esac
  case "$out" in
    *"BEADS_SYNC: repaired: re-added the 'mini1' Dolt remote"*) ;;
    *) fail "only some of the publisher's outcomes were relayed, got: $out" ;;
  esac
  case "$out" in
    *'BEADS_BACKUP:'*) fail "the publisher's own prefix leaked into the sweep's vocabulary, got: $out" ;;
  esac
  [ "$(cat "$control/backup.argv")" = "--repair" ] ||
    fail "the sweep did not delegate to the publisher's --repair mode, got: $(cat "$control/backup.argv")"
  grep -Fxq 'dolt push' "$control/calls.log" &&
    fail "the sweep issued a client-side bare 'task dolt push' on the default remote"
  grep -Fxq 'dolt pull' "$control/calls.log" &&
    fail "the sweep issued a client-side bare 'task dolt pull' from the default remote"
  grep -Fq 'dolt commit' "$control/calls.log" &&
    fail "the sweep committed outside the approved publisher"
  pass "fm_beads_sync_once delegates its whole remote leg to the approved publisher and relays its outcomes"
}

# Test: the dropped pull leg is reported out loud, not silently absent. A reader
# who remembers the old commit/push/pull shape - and the agent handling the
# bootstrap diagnostic - must be able to tell an intentional removal from a step
# that quietly stopped running.
test_beads_sync_reports_the_dropped_pull_leg() {
  local fakebin control stub out
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-pull-dropped)"

  out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" fm_beads_sync_once 2>&1) ||
    fail "a healthy delegated sync must succeed, got: $out"
  case "$out" in
    *'BEADS_SYNC: pull dropped:'*) ;;
    *) fail "the sweep dropped its pull leg without saying so, got: $out" ;;
  esac
  case "$out" in
    *'single write authority'*) ;;
    *) fail "the dropped-pull line did not name why the leg is gone, got: $out" ;;
  esac
  pass "fm_beads_sync_once reports its dropped pull leg instead of removing it silently"
}

# Test: a failing publisher is relayed AND propagated. Best-effort means the
# caller continues, never that a failure is swallowed, so the named outcome must
# reach the output and the exit status must reach the caller.
test_beads_sync_relays_a_failing_publisher_and_propagates_its_status() {
  local fakebin control stub out
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-push-fails)"
  printf '%s\n' \
    "BEADS_BACKUP: commit-failed: 'task dolt commit' exited non-zero; continuing to push previously committed work: schema skew detected" \
    "BEADS_BACKUP: push-failed: 'dolt_push' to 'mini1' failed: transport down" \
    > "$control/backup.lines"
  printf '1' > "$control/backup.rc"

  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" fm_beads_sync_once 2>&1); then
    fail "a failed publisher was reported as a successful sync, got: $out"
  fi
  case "$out" in
    *'BEADS_SYNC: push-failed:'*) ;;
    *) fail "sync did not relay the publisher's failure, got: $out" ;;
  esac
  case "$out" in
    *'transport down'*) ;;
    *) fail "the relayed failure did not carry the publisher's own reason, got: $out" ;;
  esac
  case "$out" in
    *'BEADS_SYNC: commit-failed:'*) ;;
    *) fail "sync dropped an earlier publisher outcome, got: $out" ;;
  esac
  pass "fm_beads_sync_once relays a failing publisher and never calls the sweep a success"
}

# Test: a publisher that fails WITHOUT printing an outcome still gets exactly one
# bounded line. Silence here would be the worst case - a remote leg that failed
# and said nothing - so the sweep synthesizes a diagnostic from the exit status
# rather than letting an empty output read like a clean run.
test_beads_sync_names_a_publisher_that_produced_no_outcome() {
  local fakebin control stub out
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-publisher-silent)"
  : > "$control/backup.lines"
  printf '127' > "$control/backup.rc"

  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" fm_beads_sync_once 2>&1); then
    fail "a publisher that failed silently was reported as a successful sync, got: $out"
  fi
  case "$out" in
    *"BEADS_SYNC: remote leg failed: 'fm-beads-remote-backup.sh' exited 127"*) ;;
    *) fail "sync did not name the mute publisher and its status, got: $out" ;;
  esac
  pass "fm_beads_sync_once names a publisher that failed without reporting an outcome"
}

# Test: an unresolvable publisher is its own named skip, not a bare 127 from the
# bounded runner. firstmate must never conclude the remote is fine because the
# helper that talks to it was missing from the code root.
test_beads_sync_reports_a_missing_publisher() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_fixture sync-publisher-missing)"
  printf '%s' '[{"name":"mini1"}]' > "$control/remotes.json"

  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$TMP_ROOT/definitely-absent-publisher.sh" \
    fm_beads_sync_once 2>&1); then
    fail "a missing publisher was reported as a successful sync, got: $out"
  fi
  case "$out" in
    *'the approved Dolt publisher is not executable at'*) ;;
    *) fail "sync did not name the missing publisher, got: $out" ;;
  esac
  assert_no_grep 'dolt push' "$control/calls.log" \
    "sync pushed without the approved publisher that owns the credential path"
  pass "fm_beads_sync_once names a missing approved publisher instead of guessing at a remote"
}

# Test: a hanging publisher is bounded, so the remote leg can never wedge the
# session-start sweep that calls it. The bound is the reason the delegation is
# safe to run routinely.
test_beads_sync_bounds_a_hanging_publisher() {
  local fakebin control stub out started elapsed
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-hangs)"
  printf '%s' '30' > "$control/backup.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" FM_BEADS_SYNC_TIMEOUT=1 \
    fm_beads_sync_once 2>&1); then
    fail "a timed-out remote leg must be reported as a failure, got success: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  case "$out" in
    *'remote leg failed: timed out after 1s'*) ;;
    *) fail "sync did not report the bound being hit, got: $out" ;;
  esac
  [ "$elapsed" -lt 15 ] ||
    fail "sync waited ${elapsed}s on a hanging publisher instead of honouring its bound"
  pass "fm_beads_sync_once bounds a hanging publisher so it cannot wedge the sweep that calls it"
}

# Test: the bound that matters is the one on the WHOLE sweep, not the generous
# per-step one. A blackholed remote must not be able to spend the per-step bound
# three times over and starve every other sweep sharing the caller's budget, so
# the remote leg is given whatever remains of the sweep budget and nothing more.
test_beads_sync_takes_the_leg_bound_from_the_sweep_budget_not_the_per_step_bound() {
  local fakebin control stub out started elapsed
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-budget)"
  printf '%s' '30' > "$control/backup.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" FM_BEADS_SYNC_TIMEOUT=45 \
    FM_BEADS_SYNC_BUDGET=2 fm_beads_sync_once 2>&1); then
    fail "a sweep that spent its whole budget must be reported as a failure, got: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] ||
    fail "the remote leg ran ${elapsed}s against a 2s sweep budget, so only the per-step bound applied"
  # The bound is whatever remained of the 2s sweep budget when the leg started,
  # so it is 2s or 1s depending on where the second boundary fell - never the 45s
  # per-step bound, which is what the elapsed assertion below proves.
  case "$out" in
    *'remote leg failed: timed out after 1s'* | *'remote leg failed: timed out after 2s'*) ;;
    *) fail "sync did not report the sweep budget as the leg's bound, got: $out" ;;
  esac
  pass "fm_beads_sync_once bounds the remote leg by the sweep budget, not by the per-step bound"
}

# Test: a budget already spent at entry is reported on its own line rather than
# silently skipping the leg. A caller that hands over a deadline it has already
# used up must get a diagnostic, not an empty success that reads like a sync.
test_beads_sync_reports_a_budget_already_spent_at_entry() {
  local fakebin control stub out
  read -r fakebin control stub <<< "$(beads_sync_publisher_fixture sync-budget-spent)"

  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_BACKUP_BIN="$stub" FM_BEADS_SYNC_BUDGET=40 \
    fm_beads_sync_once "$(( $(date +%s) - 5 ))" 2>&1); then
    fail "a sweep with no budget left was reported as success, got: $out"
  fi
  case "$out" in
    *'sync budget was spent before the Dolt remote list could be read'*) ;;
    *) fail "sync did not report the exhausted budget, got: $out" ;;
  esac
  assert_absent "$control/backup.argv" \
    "sync delegated to the publisher with no budget left to run it"
  pass "fm_beads_sync_once reports a budget already spent instead of skipping the leg silently"
}

# Test: the real end-to-end wiring. This one deliberately uses NO override, so
# the sweep resolves bin/fm-beads-remote-backup.sh as its publisher, and it
# drives that real script against a fake task CLI and a fake curl. It asserts the
# two facts the whole task exists for: the approved remote is the one named, and
# no client-side bare push or pull ever reaches the store's CLI.
test_beads_sync_drives_the_real_publisher_to_the_approved_remote() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_publisher_end_to_end_fixture sync-approved-remote)"

  out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1) ||
    fail "the real publisher against a healthy fixture must succeed, got: $out"
  case "$out" in
    *"BEADS_SYNC: pushed-verified: 'mini1' now shares local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"*) ;;
    *) fail "the real publisher's verified outcome was not relayed, got: $out" ;;
  esac
  grep -Fq "call dolt_push('mini1','main','--user','brainsync')" "$control/argv.log" ||
    fail "the approved remote was not named explicitly on the server-side push, got: $(cat "$control/argv.log")"
  grep -Fq "call dolt_fetch('mini1','main','--user','brainsync')" "$control/argv.log" ||
    fail "head equality was not verified by a post-push fetch, got: $(cat "$control/argv.log")"
  grep -Fxq 'dolt push' "$control/argv.log" &&
    fail "a client-side bare 'task dolt push' reached the store's CLI"
  grep -Fxq 'dolt pull' "$control/argv.log" &&
    fail "a client-side bare 'task dolt pull' reached the store's CLI"
  grep -Fq -- '--force' "$control/argv.log" &&
    fail "the sync reached for a force operation"
  pass "fm_beads_sync_once drives the approved publisher, which names mini1 explicitly and never uses the default remote"
}

# Test: head equality is verified and divergence is REPORTED, never reconciled
# by force. The local store is the single write authority, so a remote that
# disagrees is an operator decision; every automatic answer to it (force-push,
# overwrite, reset) would discard history.
test_beads_sync_surfaces_publisher_divergence_without_force_pushing() {
  local fakebin control out
  read -r fakebin control <<< "$(beads_sync_publisher_end_to_end_fixture sync-diverged)"
  printf '%s' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$control/remote.hash"

  if out=$(PATH="$fakebin:$PATH" fm_beads_sync_once 2>&1); then
    fail "diverged heads were reported as a successful sync, got: $out"
  fi
  case "$out" in
    *"BEADS_SYNC: diverged: 'mini1' main (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) differs from local main (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"*) ;;
    *) fail "sync did not report the divergence for an operator, got: $out" ;;
  esac
  case "$out" in
    *'never a force-push'*) ;;
    *) fail "the divergence line did not refuse the force-push, got: $out" ;;
  esac
  grep -Fq -- '--force' "$control/argv.log" &&
    fail "the sync tried to reconcile diverged heads with a force"
  pass "fm_beads_sync_once reports diverged heads for an operator and never force-pushes"
}

# Test: the budget covers the sweep's FIRST command, not merely the remote leg
# it names. A Dolt server that accepts the connection and then never answers
# hangs the remote listing, which runs before the leg does, so leaving that
# probe outside the budget lets the sweep spend unbounded wall clock without a
# single bounded step running and without any diagnostic at all - the budget
# would be a claim rather than a bound.
test_beads_sync_bounds_the_probe_that_precedes_its_steps() {
  local fakebin control out started elapsed
  read -r fakebin control <<< "$(beads_sync_fixture sync-probe-hangs)"
  printf '%s' '[{"name":"origin"}]' > "$control/remotes.json"
  printf '30' > "$control/remote.sleep"

  started=$(date +%s)
  if out=$(PATH="$fakebin:$PATH" FM_BEADS_SYNC_TIMEOUT=45 FM_BEADS_SYNC_BUDGET=2 \
    fm_beads_sync_once 2>&1); then
    fail "a sweep whose remote listing never answered must be reported as a failure, got: $out"
  fi
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] ||
    fail "the sweep hung ${elapsed}s on its remote listing against a 2s budget"
  case "$out" in
    *'could not read the Dolt remote list'*) ;;
    *) fail "a listing that never answered was not reported as unreadable, got: $out" ;;
  esac
  case "$out" in
    *'no Dolt remote configured'*)
      fail "a listing that never answered was reported as a home that has no remote: $out" ;;
  esac
  if grep -q 'dolt commit' "$control/calls.log"; then
    fail "sync committed after a remote listing it never got an answer from"
  fi
  if [ -e "$control/backup.argv" ]; then
    fail "sync delegated to the publisher after a remote listing it never got an answer from"
  fi
  pass "fm_beads_sync_once bounds the probe that precedes its steps, not only the steps"
}

# Test: fm_beads_sync_remote_state with a bound must print an 'unreadable:' line
# and exit 0 when the timeout library is absent, rather than producing empty
# output. An absent library must not collapse into the 'none' response.
test_beads_sync_remote_state_timeout_lib_absent_is_unreadable() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_sync_remote_state timeout-lib skipped without jq"; return; }
  dir="$TMP_ROOT/sync-remote-no-timeoutlib"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-tasks-axi-lib.sh" "$dir/bin/"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'dolt remote list --json') printf '%s\n' '[{"name":"origin"}]'; exit 0 ;;
  'list --limit 1') exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"
  cat > "$dir/consumer.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/bin/fm-tasks-axi-lib.sh"
fm_beads_sync_remote_state "$1"
SH
  chmod +x "$dir/consumer.sh"
  out=$(PATH="$fakebin:$PATH" "$dir/consumer.sh" 5 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm_beads_sync_remote_state with absent timeout lib must exit 0, got $rc"
  case "$out" in
    unreadable:*) ;;
    '') fail "absent timeout library produced empty output; must produce an 'unreadable:' line" ;;
    none) fail "absent timeout library collapsed into 'none' (no remote configured)" ;;
    *) fail "expected an 'unreadable:' line, got: $out" ;;
  esac
  pass "fm_beads_sync_remote_state with an absent timeout library reports unreadable, not empty"
}

# Test: fm_beads_sync_once must emit a BEADS_SYNC: skipped diagnostic and return
# non-zero when the timeout library is absent, even under set -e. An unguarded
# bare call at the top of the function silently aborts under set -e, producing
# no output while the caller's || true swallows the failure — indistinguishable
# from a clean run with no Dolt remote configured.
test_beads_sync_once_timeout_lib_absent_emits_diagnostic() {
  local dir fakebin out rc
  command -v jq >/dev/null 2>&1 || { pass "fm_beads_sync_once timeout-lib skipped without jq"; return; }
  dir="$TMP_ROOT/sync-once-no-timeoutlib"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-tasks-axi-lib.sh" "$dir/bin/"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/task" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'list --limit 1') exit 0 ;;
  'dolt remote list --json') printf '%s\n' '[{"name":"origin"}]'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/task"
  cat > "$dir/consumer.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/bin/fm-tasks-axi-lib.sh"
fm_beads_sync_once
SH
  chmod +x "$dir/consumer.sh"
  out=$(PATH="$fakebin:$PATH" "$dir/consumer.sh" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "fm_beads_sync_once with absent timeout lib must return non-zero, got 0"
  [ -n "$out" ] || fail "fm_beads_sync_once with absent timeout lib produced no output (silent abort)"
  case "$out" in
    *'BEADS_SYNC: skipped:'*) ;;
    *) fail "expected a 'BEADS_SYNC: skipped:' line, got: $out" ;;
  esac
  pass "fm_beads_sync_once with an absent timeout library emits a BEADS_SYNC: diagnostic and returns non-zero"
}

# Run all tests
test_beads_backend_value
test_beads_backend_available
test_tasks_axi_backend_false_for_beads
test_backend_value_whitespace
test_beads_fleet_label
test_beads_resolve_or_create_mints_when_absent
test_beads_resolve_or_create_reuses_existing
test_beads_resolve_or_create_skips_closed_bead
test_beads_resolve_or_create_prefers_live_bead_over_closed
test_beads_resolve_or_create_ignores_predecessor_backlog_depth
test_beads_home_scope_stable_and_distinct
test_beads_resolve_or_create_two_homes_same_slug
test_beads_migration_retags_a_scaffolded_tasks_legacy_bead
test_beads_migration_leaves_a_bead_another_home_claimed_alone
test_beads_migration_repoints_a_dispatched_task_off_another_homes_bead
test_beads_migration_skips_repoint_for_live_endpoint
test_beads_migration_repoint_second_run_is_a_no_op
test_beads_migration_counts_a_failed_replacement_mint_as_a_failure
test_beads_migration_counts_a_failed_repoint_write_as_a_failure
test_beads_migration_ignores_a_slug_this_home_has_no_record_for
test_beads_migration_never_touches_closed_beads
test_beads_migration_second_run_is_a_no_op
test_beads_migration_reads_labels_from_the_list_payload_when_present
test_beads_migration_ignores_a_backlog_only_slug
test_beads_migration_claims_a_bead_this_homes_meta_records
test_beads_migration_leaves_a_bead_its_records_do_not_name
test_beads_migration_counts_a_failed_candidate_lookup_as_a_failure
test_beads_migration_reports_an_unreadable_label_list_as_unmigrated
test_beads_migration_counts_a_failed_replacement_lookup_as_a_failure
test_beads_resolve_issues_one_lookup_and_no_write_beyond_the_mint
test_beads_home_scope_normalizes_home_path_spellings
test_lib_sources_without_its_siblings
test_beads_status_read_outcomes
test_beads_status_down_store_is_not_absent
test_beads_status_rejects_non_positive_bound

test_beads_store_reachable_tracks_the_cli_answer
test_beads_store_reachable_honours_the_callers_bound
test_beads_bootstrap_refuses_over_a_live_store
test_beads_bootstrap_refuses_over_a_slow_live_store
test_beads_bootstrap_provisions_an_unreachable_store
test_beads_bootstrap_verifies_rather_than_trusting_exit_status
test_beads_sync_is_inert_without_a_configured_remote
test_beads_sync_separates_an_unreadable_remote_list_from_an_empty_one
test_beads_sync_reports_a_missing_jq_rather_than_assuming_no_remote
test_beads_sync_delegates_the_remote_leg_and_relays_every_outcome
test_beads_sync_reports_the_dropped_pull_leg
test_beads_sync_relays_a_failing_publisher_and_propagates_its_status
test_beads_sync_names_a_publisher_that_produced_no_outcome
test_beads_sync_reports_a_missing_publisher
test_beads_sync_bounds_a_hanging_publisher
test_beads_sync_takes_the_leg_bound_from_the_sweep_budget_not_the_per_step_bound
test_beads_sync_reports_a_budget_already_spent_at_entry
test_beads_sync_drives_the_real_publisher_to_the_approved_remote
test_beads_sync_surfaces_publisher_divergence_without_force_pushing
test_beads_sync_bounds_the_probe_that_precedes_its_steps
test_beads_sync_remote_state_timeout_lib_absent_is_unreadable
test_beads_sync_once_timeout_lib_absent_emits_diagnostic
test_beads_sync_never_reports_an_unreadable_clock_as_a_spent_budget
test_beads_sync_names_a_clock_it_cannot_read

echo "ok - all beads backend tests passed"
