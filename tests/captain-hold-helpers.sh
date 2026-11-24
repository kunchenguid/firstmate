#!/usr/bin/env bash
# Shared fixtures for the captain-hold lifecycle suites.
#
# Source this from a captain-hold test file after TMP_ROOT and the jq/tasks-axi
# skip gates:
#   # shellcheck source=tests/captain-hold-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"
set -u

if [ -n "${FM_CAPTAIN_HOLD_HELPERS_SOURCED:-}" ]; then
  return 0
fi
FM_CAPTAIN_HOLD_HELPERS_SOURCED=1


make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

# The generic process-event runner, run against this suite's isolated home and
# its own claim root, so a review armed here can never contend with a real one.
run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json "$@"
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Completes <id>'s captain-call inventory through a separate held task, because
# the origin task is never accepted as its own inventory entry.
complete_through_sibling() {  # <home> <origin-id>
  local home=$1 id=$2
  run_captain "$home" hold "$id-call" --title "Sibling captain call for $id" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    && run_captain "$home" complete "$id" "$id-call"
}

request_reconciles() {  # <home> <source-id> <task-id>...
  local home=$1 source_id=$2 id
  shift 2
  run_captain "$home" bind "$source_id" >/dev/null || return 1
  for id in "$@"; do printf '%s\n' "$id"; done \
    | run_captain "$home" reconcile-requests --source-id "$source_id" \
        --source "captured board result" >/dev/null
}

configure_merged_github() {  # <home>
  local home=$1
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
        ;;
      *headRefOid*) printf '%s\n' 1111111111111111111111111111111111111111 ;;
    esac
    ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "api graphql")
    printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'
    ;;
  "api --paginate")
    case " $* " in
      *merge_queue*) ;;
      *) printf '%s\n' '[]' ;;
    esac
    ;;
  "api repos/"*) printf '%s\n' '{"name":"main","protected":false}' ;;
esac
SH
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/gh-axi"
  : > "$home/gh.log"
  : > "$home/gh-axi.log"
}

run_pr_merge() {  # <home> <id> <url>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_GH_AXI_LOG="$home/gh-axi.log" "$ROOT/bin/fm-pr-merge.sh" "$@"
}

wait_for_test_file() {  # <path> <pid>
  local path=$1 pid=$2 i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$path" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.01
    i=$((i + 1))
  done
  return 1
}

install_reused_task_barriers() {  # <home>
  local home=$1
  cat > "$home/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_TEARDOWN:-}" = 1 ] \
    && [ ! -e "${FM_TEST_REUSE_TEARDOWN_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_TEARDOWN_ONCE"
  : > "$FM_TEST_REUSE_TEARDOWN_READY"
  while [ ! -e "$FM_TEST_REUSE_TEARDOWN_RELEASE" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_PERL" "$@"
SH
  cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_MERGE:-}" = 1 ] && [ "${1:-}" = 0.1 ] \
    && [ ! -e "${FM_TEST_REUSE_MERGE_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_MERGE_ONCE"
  : > "$FM_TEST_REUSE_MERGE_READY"
  while [ ! -e "$FM_TEST_REUSE_MERGE_RELEASE" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$home/fakebin/perl" "$home/fakebin/sleep"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# --- markdown-to-beads migration resolution ----------------------------------
#
# A home on the Beads backend no longer carries the legacy markdown ids a scout
# report attested: fm-hold-migration rehomed each held row under a prefixed fm-
# id and recorded its markdown identity in the row's notes as the exact line
# "migrated from data/backlog.md id <legacy id>". The fixture graph is driven
# through bd directly where possible because the npm-published tasks-axi ships
# the markdown backend only; the hold itself needs a beads-capable tasks-axi,
# so that family probes once and skips itself with an explicit reason on
# markdown-only installs, mirroring tests/fm-control-relaunch.test.sh.

# Build a fixture home whose configured backend is a scratch Beads graph.
# Echoes "<home>|<graph-beads-dir>". The graph repo dir is named "fm" because
# bd derives the row-id prefix from the repo directory name.
make_beads_home() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph"
  (umask 077; mkdir -p "$home/state")
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  fb=$(fm_fakebin "$home")
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home|$graph/.beads"
}

bdrow() {  # <beads-dir> <args...>
  BEADS_DIR="$1" bd "${@:2}"
}

# One capability probe for the migration family: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot, and the
# hold fixture needs its beads backend; those installs skip with this reason.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  rm -rf "$probe_home" "$probe_graph"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 \
   && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

# Cleanup rewrites a captain-held row's body to append the finished work's
# deliverable, so every byte of that body has to survive the decode. The
# assertions below are on bytes, not characters: a decoder that prints a
# character string to a stream with no :raw layer emits a codepoint at or below
# U+00FF as one latin-1 byte, which is not valid UTF-8, and the comparison of
# decoded strings would not notice.
#
# The two characters go in separate rows on purpose. A string that holds any
# character above U+00FF is printed as UTF-8 whatever the layer, so mixing them
# in one body hides the latin-1 case entirely.

# Take one captain-held row carrying <body> all the way through cleanup, which
# is the path that reads the body back to append the deliverable.
retain_row_with_body() {  # <home> <id> <body>
  local home=$1 id=$2 body=$3
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample body bytes" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the fixture for $id"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample body bytes\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" update "$id" --body "$body" >/dev/null \
    || fail "could not give $id a body carrying non-ASCII characters"
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold $id for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "the completion gate failed for $id"
  run_teardown "$home" "$id" > "$home/$id.out" 2> "$home/$id.err" \
    || fail "cleanup of captain-held $id failed: $(cat "$home/$id.err")"
}

write_scout_with_attested_inventory() {  # <home> <scout-id> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}
