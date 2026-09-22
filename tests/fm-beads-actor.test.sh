#!/usr/bin/env bash
# Behavior tests for Beads audit-trail actor identity (BEADS_ACTOR).
#
# bd attributes every backlog state change to $BEADS_ACTOR (bd --help: default
# is $BEADS_ACTOR, git user.name, then $USER), and tasks-axi's beads backend
# shells out to bd. Without an explicit actor a whole fleet collapses into one
# identity in the shared Beads graph, so firstmate exports the variable at two
# boundaries (docs/configuration.md "Backlog backend"):
#   dispatch  bin/fm-spawn.sh exports the task id, so the claim that moves a
#             row In flight and the worker's pane (every claim, hold, or close
#             the worker drives) record the worker that did it. For a
#             --secondmate spawn the same $ID is the registered name.
#   firstmate bin/fm-teardown.sh and every other firstmate-owned mutation run
#             as firstmate@<basename of FM_HOME> through the shared resolver
#             fm_tasks_axi_export_actor (bin/fm-tasks-axi-lib.sh), which never
#             overrides an explicitly exported actor.
#
# These tests drive the real bin/fm-spawn.sh and bin/fm-teardown.sh against a
# real tasks-axi on the beads backend with a real bd database, then assert the
# recorded actors in .beads/interactions.jsonl - never the scripts' source.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture
# in fm_tasks_axi_backend, and a stray BEADS_ACTOR would masquerade as an
# explicit firstmate-side actor, so both start from a clean slate.
unset TASKS_AXI_BACKEND || :
unset BEADS_ACTOR || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-beads-actor)

if ! { command -v tasks-axi >/dev/null 2>&1 \
    && command -v bd >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1; }; then
  printf 'ok - skipped (tasks-axi, bd, and jq are required to exercise the beads backend)\n'
  exit 0
fi

# --- fixture ----------------------------------------------------------------

# A home with a real bd database on the beads backend, a real project clone
# with an origin, a pooled worktree, and stubs for every tool the spawn and
# teardown paths shell out to. The tmux stub records every send-keys line so
# the pane-environment boundary is asserted from delivered text, not source.
make_home() {  # <name>
  local name=$1 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  # The markdown scaffold stays the record-present gate even on beads; the
  # backend selection itself comes from the home's .tasks.toml.
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  # tasks-axi resolves its bd binary as ~/.local/bin/bd unless [beads]
  # binary pins one, and the spawn below runs under a throwaway HOME, so the
  # fixture pins the real bd explicitly.
  {
    printf '%s\n' 'backend = "beads"' '[beads]' 'path = ".beads"' 'prefix = "actor"' \
      "binary = \"$(command -v bd)\""
  } > "$home/.tasks.toml"
  (cd "$home" && bd init --prefix actor) >/dev/null 2>&1 \
    || fail "could not initialize the beads fixture database"
  # bd 1.2+ keeps issue history in the DB always, but the interactions.jsonl
  # sidecar this suite asserts is off by default; enable it for the fixture.
  (cd "$home" && bd config set audit.enabled true) >/dev/null 2>&1 \
    || fail "could not enable beads audit sidecar for the fixture"

  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) printf '%s\n' "\$*" >> "$case_dir/tmux-sends" ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes

  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }
interactions_of() { printf '%s/home/.beads/interactions.jsonl\n' "$1"; }

write_brief() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  mkdir -p "$case_dir/home/data/$id"
  cat > "$case_dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise Beads actor attribution for $id.

## Firstmate spec
Verify the audit-trail actor boundaries.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

add_item() {  # <case-dir> <id>
  (cd "$(home_of "$1")" && tasks-axi add "$2" "item for $2" --kind ship) >/dev/null
}

row_state() {  # <case-dir> <id>
  (cd "$(home_of "$1")" && tasks-axi show "$2" 2>/dev/null) |
    sed -n 's/^  state: *//p' | head -1
}

status_actor() {  # <case-dir> <new-value>
  jq -r "select(.extra.field == \"status\" and .extra.new_value == \"$2\") | .actor" \
    "$(interactions_of "$1")" | head -1
}

run_ship_spawn() {  # <case-dir> <id>
  local case_dir=$1
  shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" HOME="$case_dir/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

run_teardown() {  # <case-dir> <id>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

# Replace the spawn's live record with the absent-worktree shape the completion
# cases in tests/fm-backlog-atomicity.test.sh use, so teardown's landed-work
# and worktree-return steps are no-ops and the close transition is the surface
# under test.
detach_worktree() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  rm -f "$case_dir/home/state/$id.busy-state" "$case_dir/home/state/$id.busy-gen" \
    "$case_dir/home/state/$id.meta"
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree" \
    "project=$case_dir/absent-project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=spawn-actor-close"
}

# --- attribution ------------------------------------------------------------

test_spawn_attributes_the_claim_and_the_pane_to_the_task_id() {
  local case_dir id out
  id=actor-claim-b1
  case_dir=$(make_home spawn-claim)
  write_brief "$case_dir" "$id"
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id" "$TMP_ROOT/spawn-claim/project") \
    || fail "beads spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "spawn reported success with its backlog item still $(row_state "$case_dir" "$id")"
  [ "$(status_actor "$case_dir" in_progress)" = "$id" ] \
    || fail "the dispatch claim records actor '$(status_actor "$case_dir" in_progress)' instead of the task id $id"
  assert_grep "export BEADS_ACTOR='$id'" "$TMP_ROOT/spawn-claim/tmux-sends" \
    "the worker pane did not receive its BEADS_ACTOR export"
  pass "a dispatch claim and the worker's pane both carry the task id as their actor"
}

test_teardown_closes_as_firstmate_and_reads_two_distinct_actors() {
  local case_dir home id out actors
  id=actor-close-b2
  case_dir=$(make_home spawn-close)
  home=$(home_of "$case_dir")
  write_brief "$case_dir" "$id"
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id" "$TMP_ROOT/spawn-close/project") \
    || fail "beads spawn failed: $out"
  detach_worktree "$case_dir" "$id"
  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the item still $(row_state "$case_dir" "$id")"
  [ "$(status_actor "$case_dir" closed)" = "firstmate@home" ] \
    || fail "the teardown close records actor '$(status_actor "$case_dir" closed)' instead of firstmate@home"

  # The documented attribution read (docs/configuration.md) must show both
  # boundaries after one spawn and one teardown.
  actors=$(cd "$home" && tail -100 .beads/interactions.jsonl | jq -r .actor | sort | uniq -c \
    | awk '{print $2}' | sort -u)
  [ "$(printf '%s\n' "$actors" | grep -c .)" -ge 2 ] \
    || fail "one spawn and one teardown left only these actors: $(printf '%s' "$actors")"
  printf '%s\n' "$actors" | grep -qx "$id" \
    || fail "the attribution read is missing the worker actor $id"
  printf '%s\n' "$actors" | grep -qx 'firstmate@home' \
    || fail "the attribution read is missing the firstmate@home actor"
  pass "one spawn and one teardown leave the worker and firstmate@home as distinct actors"
}

test_an_explicitly_exported_actor_is_never_overridden() {
  local case_dir id out
  id=actor-explicit-b3
  case_dir=$(make_home explicit-actor)
  add_item "$case_dir" "$id"
  (cd "$(home_of "$case_dir")" && tasks-axi start "$id") >/dev/null
  detach_worktree "$case_dir" "$id"

  out=$(BEADS_ACTOR=explicit-operator run_teardown "$case_dir" "$id") \
    || fail "teardown failed under an explicit actor: $out"
  [ "$(status_actor "$case_dir" closed)" = "explicit-operator" ] \
    || fail "the close overrode an explicit actor with '$(status_actor "$case_dir" closed)'"
  pass "an explicitly exported BEADS_ACTOR is never overridden"
}

test_spawn_attributes_the_claim_and_the_pane_to_the_task_id
test_teardown_closes_as_firstmate_and_reads_two_distinct_actors
test_an_explicitly_exported_actor_is_never_overridden
