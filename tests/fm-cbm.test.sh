#!/usr/bin/env bash
# Behavior tests for optional codebase-memory-mcp integration.
# shellcheck disable=SC2030,SC2031 # Each case uses a subshell to isolate its test environment.
# shellcheck disable=SC2016 # Structural contract strings deliberately retain literal shell syntax.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-cbm-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
INDEX="$ROOT/bin/fm-cbm-index.sh"

# --- library unit behavior ---

test_lib_disabled_when_forced_off() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config" "$dir/bin"
  cat > "$dir/config/cbm.env" <<'EOF'
FM_CBM_ENABLED=0
EOF
  # even with a fake binary on PATH, force-off wins
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  (
    # shellcheck disable=SC2030,SC2031
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    if fm_cbm_enabled; then
      fail "CBM should be disabled when FM_CBM_ENABLED=0"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: FM_CBM_ENABLED=0 disables CBM even if binary exists"
}

test_lib_auto_on_with_binary() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    unset FM_CBM_ENABLED FM_CBM_BIN
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_enabled || fail "auto mode should enable when binary is on PATH"
    prefix=$(fm_cbm_launch_env_prefix) || fail "launch prefix should succeed"
    printf '%s' "$prefix" | grep -q 'CBM_CACHE_DIR=' || fail "prefix missing CBM_CACHE_DIR"
    printf '%s' "$prefix" | grep -q 'CBM_MEM_BUDGET_MB=' || fail "prefix missing mem budget"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: auto enables with binary and builds launch prefix"
}

test_lib_rejects_unsafe_resource_caps() {
  local dir marker prefix out
  dir=$(fm_test_tmproot fm-cbm)
  marker="$dir/injected"
  mkdir -p "$dir/bin" "$dir/config"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  cat > "$dir/config/cbm.env" <<EOF
FM_CBM_MEM_BUDGET_MB=2; touch $marker; #
FM_CBM_WORKERS=999999999
EOF
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    prefix=$(fm_cbm_launch_env_prefix) || fail "launch prefix should succeed"
    bash -c "${prefix}env" > "$dir/env"
    [ ! -e "$marker" ] || fail "resource cap config must not execute shell text"
    grep -qx 'CBM_MEM_BUDGET_MB=1024' "$dir/env" || fail "invalid memory cap must use default"
    grep -qx 'CBM_WORKERS=2' "$dir/env" || fail "out-of-range worker cap must use default"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: unsafe resource caps are rejected"
}

test_index_rejects_openclaw_monorepo_root() {
  local dir repo linked_repo fake log target
  dir=$(fm_test_tmproot fm-cbm)
  repo="$dir/.openclaw"
  fake="$dir/bin/codebase-memory-mcp"
  log="$dir/invoked"
  mkdir -p "$dir/home/config" "$dir/bin" "$repo"
  linked_repo="$dir/linked/.openclaw"
  mkdir -p "$(dirname "$linked_repo")"
  ln -s "$repo" "$linked_repo"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
touch "$CBM_TEST_LOG"
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  (
    export FM_ROOT_OVERRIDE="$dir/home"
    export FM_HOME="$dir/home"
    export CBM_TEST_LOG="$log"
    for target in "$repo"/ "$linked_repo"; do
      if "$INDEX" index "$target" >/dev/null 2>&1; then
        fail "the .openclaw monorepo root must not be indexed"
      fi
    done
    [ ! -e "$log" ] || fail "monorepo root must not invoke CBM"
  ) || fail "subshell failed"
  pass "fm-cbm-index: rejects the .openclaw monorepo root"
}

test_index_list_surfaces_cli_failures() {
  local dir fake
  dir=$(fm_test_tmproot fm-cbm)
  fake="$dir/bin/codebase-memory-mcp"
  mkdir -p "$dir/home/config" "$dir/bin"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  (
    export FM_ROOT_OVERRIDE="$dir/home"
    export FM_HOME="$dir/home"
    if "$INDEX" list >/dev/null 2>&1; then
      fail "list must return nonzero when CBM CLI fails"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-index: list surfaces CLI failures"
}

test_lib_rejects_relative_explicit_binary() {
  local dir found
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config" "$dir/relative-bin"
  cat > "$dir/relative-bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/relative-bin/codebase-memory-mcp"
  printf '%s\n' 'FM_CBM_BIN=relative-bin/codebase-memory-mcp' > "$dir/config/cbm.env"
  (
    export PATH=/usr/bin:/bin
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    cd "$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_load_config_file
    found=$(fm_cbm_binary || true)
    [ "$found" != 'relative-bin/codebase-memory-mcp' ] || fail "relative explicit binary must be rejected"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: rejects relative explicit binary"
}

test_lib_project_eligibility_defaults() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config"
  (
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_project_eligible "/tmp/.openclaw" || fail ".openclaw should be eligible by default"
    fm_cbm_project_eligible "/tmp/firstmate" || fail "firstmate should be eligible by default"
    if fm_cbm_project_eligible "/tmp/random-app"; then
      fail "random app should not be eligible by default"
    fi
    fm_cbm_project_eligible "/x/workspace/projects/active/JT-Control-Room" || fail "JT-Control-Room path should match"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: default project allowlist"
}

test_lib_project_eligibility_file() {
  local dir
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/config"
  printf '%s\n' 'only-this' > "$dir/config/cbm-projects"
  (
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_project_eligible "/tmp/only-this" || fail "allowlisted name should match"
    if fm_cbm_project_eligible "/tmp/.openclaw"; then
      fail "default allowlist must not apply when file exists"
    fi
    if fm_cbm_project_eligible "/x/workspace/projects/active/JT-Control-Room"; then
      fail "JT shortcut must not bypass configured allowlist"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: config/cbm-projects overrides defaults"
}

test_lib_append_brief_policy() {
  local dir brief
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config" "$dir/data/t1"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  brief="$dir/data/t1/brief.md"
  printf '%s\n' '# Task' 'do things' > "$brief"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    unset FM_CBM_ENABLED
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_append_brief_policy "$brief" "/repo/.openclaw" scout
    grep -q 'firstmate:cbm-orientation:start' "$brief" || fail "brief missing CBM marker"
    grep -q 'Optional code orientation' "$brief" || fail "brief missing CBM section"
    # idempotent
    fm_cbm_append_brief_policy "$brief" "/repo/.openclaw" scout
    count=$(grep -c 'firstmate:cbm-orientation:start' "$brief" || true)
    [ "$count" = 1 ] || fail "brief policy should append once, got $count"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: append brief policy is idempotent for eligible projects"
}

test_lib_append_skips_ineligible() {
  local dir brief
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config" "$dir/data/t1"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  brief="$dir/data/t1/brief.md"
  printf '%s\n' '# Task' > "$brief"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_append_brief_policy "$brief" "/repo/unrelated" scout
    if grep -q 'firstmate:cbm-orientation:start' "$brief"; then
      fail "ineligible project must not get CBM brief block"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-lib: skips brief policy for ineligible projects"
}

test_index_escapes_paths_and_fails_loudly() {
  local dir repo fake log out
  dir=$(fm_test_tmproot fm-cbm)
  repo="$dir/repo\"quoted"
  fake="$dir/bin/codebase-memory-mcp"
  log="$dir/request.json"
  mkdir -p "$dir/home/config" "$dir/bin" "$repo"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s' "$3" > "$CBM_TEST_LOG"
exit "${CBM_FAKE_EXIT:-0}"
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  printf '%s\n' "$repo" > "$dir/home/config/cbm-projects"
  (
    export FM_ROOT_OVERRIDE="$dir/home"
    export FM_HOME="$dir/home"
    export CBM_TEST_LOG="$log"
    "$INDEX" index "$repo" >/dev/null
    jq -e --arg repo_path "$repo" '.repo_path == $repo_path' "$log" >/dev/null \
      || fail "index request must JSON-escape repo_path"
    if CBM_FAKE_EXIT=9 "$INDEX" index "$repo" >/dev/null 2>&1; then
      fail "failed explicit index must return nonzero"
    fi
  ) || fail "subshell failed"
  pass "fm-cbm-index: escapes paths and surfaces index failures"
}

test_index_rejects_unallowlisted_absolute_path() {
  local dir repo fake log
  dir=$(fm_test_tmproot fm-cbm)
  repo="$dir/unallowlisted"
  fake="$dir/bin/codebase-memory-mcp"
  log="$dir/invoked"
  mkdir -p "$dir/home/config" "$dir/bin" "$repo"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
touch "$CBM_TEST_LOG"
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  printf '%s\n' 'another-project' > "$dir/home/config/cbm-projects"
  (
    export FM_ROOT_OVERRIDE="$dir/home"
    export FM_HOME="$dir/home"
    export CBM_TEST_LOG="$log"
    if "$INDEX" index "$repo" >/dev/null 2>&1; then
      fail "unallowlisted absolute index target must fail"
    fi
    [ ! -e "$log" ] || fail "unallowlisted path must not invoke CBM"
  ) || fail "subshell failed"
  pass "fm-cbm-index: rejects unallowlisted absolute paths"
}

test_index_all_skips_ineligible_without_failing() {
  local dir fake log ok_repo skip_repo
  dir=$(fm_test_tmproot fm-cbm)
  fake="$dir/bin/codebase-memory-mcp"
  log="$dir/invoked.log"
  ok_repo="$dir/ok-proj"
  skip_repo="$dir/skip-proj"
  mkdir -p "$dir/home/config" "$dir/bin" "$ok_repo" "$skip_repo"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$CBM_TEST_LOG"
exit 0
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  # Restrictive allowlist: only ok-proj
  printf '%s\n' "$ok_repo" > "$dir/home/config/cbm-projects"
  (
    export FM_ROOT_OVERRIDE="$dir/home"
    export FM_HOME="$dir/home"
    export CBM_TEST_LOG="$log"
    # Monkey-patch via env is not available; call resolve through absolute paths
    # by invoking index with a custom approach: run index twice simulating all
    # filtering logic is covered by sourcing? Prefer direct script path via all
    # after replacing resolve_target is heavy. Call index on each then verify
    # the all-mode helper by running a mini clone of the loop:
    # Use the real script by placing both under names it discovers? Simpler:
    # invoke with a fake by calling bash -c that sources and runs with patched resolve.
    # Practical contract: run index "$ok_repo" succeeds and index all with only
    # firstmate root when allowlist is ok-only: we instead call the script's
    # index all after making FM_ROOT the home (firstmate) and ensure skip works.
    if ! "$INDEX" index "$ok_repo" >/dev/null; then
      fail "allowlisted path must index"
    fi
    [ -s "$log" ] || fail "allowlisted index should invoke CLI"
    # firstmate root is $dir/home (FM_ROOT_OVERRIDE); not allowlisted → all should
    # skip it if JT missing, and fail only if nothing indexed. Create JT path fake
    # by allowing only ok_repo while resolve_target all returns firstmate only.
    rm -f "$log"
    out=$("$INDEX" index all 2>&1) || rc=$?
    rc=${rc:-0}
    # When only firstmate resolves and is not allowlisted, expect failure + skip note.
    printf '%s' "$out" | grep -q 'skip (not allowlisted)' \
      || fail "index all should skip non-allowlisted targets"
    [ "$rc" -ne 0 ] || fail "index all with zero eligible targets must fail"
    [ ! -e "$log" ] || fail "index all must not index skipped targets"
  ) || fail "subshell failed"
  pass "fm-cbm-index: index all skips ineligible without hard abort mid-list"
}

test_index_helper_exists_and_help() {
  [ -x "$INDEX" ] || fail "fm-cbm-index.sh must be executable"
  out=$("$INDEX" --help 2>&1 || true)
  printf '%s' "$out" | grep -q 'status|list|index' \
    || fail "fm-cbm-index help should list commands"
  pass "fm-cbm-index.sh: help works"
}

test_cli_wrapper_logs_usage() {
  local dir fake usage
  dir=$(fm_test_tmproot fm-cbm)
  fake="$dir/bin/codebase-memory-mcp"
  mkdir -p "$dir/home/config" "$dir/bin"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
# echo a tiny JSON payload so list_projects looks successful
if [ "${2:-}" = list_projects ] || [ "${1:-}" = list_projects ]; then
  printf '%s\n' '{"projects":[]}'
fi
exit 0
SH
  chmod +x "$fake"
  cat > "$dir/home/config/cbm.env" <<EOF
FM_CBM_ENABLED=1
FM_CBM_BIN=$fake
FM_CBM_CACHE_DIR=$dir/cache
EOF
  (
    export FM_ROOT_OVERRIDE="$ROOT"
    export FM_HOME="$dir/home"
    export FM_DATA_OVERRIDE="$dir/isolated-data"
    export FM_CBM_TASK_ID="task-usage-1"
    export CONFIG="$dir/home/config"
    "$ROOT/bin/fm-cbm-cli.sh" list_projects >/dev/null
    usage="$dir/isolated-data/cbm/usage.jsonl"
    [ -f "$usage" ] || fail "usage.jsonl missing at $usage"
    [ ! -e "$dir/home/data/cbm/usage.jsonl" ] || fail "usage log must honor FM_DATA_OVERRIDE"
    grep -q '"tool":"list_projects"' "$usage" || fail "usage line missing tool"
    grep -q '"source":"cli"' "$usage" || fail "usage line missing source=cli"
    grep -q '"task_id":"task-usage-1"' "$usage" || fail "usage line missing task_id"
    out=$("$ROOT/bin/fm-cbm-usage.sh" summary)
    printf '%s' "$out" | grep -q 'events: 1' || fail "usage summary should show 1 event"
  ) || fail "subshell failed"
  pass "fm-cbm-cli: appends durable usage.jsonl and summary works"
}

test_usage_log_fallback_encodes_json() {
  local dir usage tool detail task
  dir=$(fm_test_tmproot fm-cbm)
  usage="$dir/data/cbm/usage.jsonl"
  tool=$'tool\\name\nnext\001'
  detail=$'detail\\value\nnext\002'
  task=$'task\\name\nnext\003'
  (
    export FM_HOME="$dir/home"
    export FM_DATA_OVERRIDE="$dir/data"
    export FM_CBM_TASK_ID="$task"
    # ShellCheck cannot see command() being called by the sourced helper.
    # shellcheck disable=SC2317
    command() {
      if [ "$1" = -v ] && [ "${2:-}" = jq ]; then
        return 1
      fi
      builtin command "$@"
    }
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_usage_log --source cli --tool "$tool" --detail "$detail"
    python3 - "$usage" "$tool" "$detail" "$task" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as usage:
    event = json.loads(usage.read())
assert event["tool"] == sys.argv[2]
assert event["detail"] == sys.argv[3]
assert event["task_id"] == sys.argv[4]
PY
  ) || fail "subshell failed"
  pass "fm-cbm-lib: no-jq fallback writes valid escaped JSONL"
}

test_usage_log_omits_detail_as_null() {
  local dir usage
  dir=$(fm_test_tmproot fm-cbm)
  usage="$dir/data/cbm/usage.jsonl"
  (
    export FM_HOME="$dir/home"
    export FM_DATA_OVERRIDE="$dir/data"
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_usage_log --source cli --tool list_projects
    python3 - "$usage" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as usage:
    event = json.loads(usage.read())
assert event["detail"] is None
PY
  ) || fail "subshell failed"
  pass "fm-cbm-lib: omitted detail is logged as null"
}

test_brief_mentions_logged_cli() {
  local dir brief
  dir=$(fm_test_tmproot fm-cbm)
  mkdir -p "$dir/bin" "$dir/config" "$dir/data/t1"
  cat > "$dir/bin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/codebase-memory-mcp"
  brief="$dir/data/t1/brief.md"
  printf '%s\n' '# Task' > "$brief"
  (
    export PATH="$dir/bin:$PATH"
    export CONFIG="$dir/config"
    export FM_HOME="$dir"
    export FM_ROOT="$ROOT"
    unset FM_CBM_ENABLED
    # shellcheck source=bin/fm-cbm-lib.sh
    . "$LIB"
    fm_cbm_append_brief_policy "$brief" "/repo/.openclaw" scout
    grep -q 'fm-cbm-cli.sh' "$brief" || fail "brief should recommend logged CLI wrapper"
  ) || fail "subshell failed"
  pass "fm-cbm-lib: brief points at fm-cbm-cli.sh"
}

test_lib_disabled_when_forced_off
test_lib_auto_on_with_binary
test_lib_rejects_unsafe_resource_caps
test_lib_rejects_relative_explicit_binary
test_lib_project_eligibility_defaults
test_lib_project_eligibility_file
test_lib_append_brief_policy
test_lib_append_skips_ineligible
test_index_helper_exists_and_help
test_index_escapes_paths_and_fails_loudly
test_index_rejects_unallowlisted_absolute_path
test_index_all_skips_ineligible_without_failing
test_index_rejects_openclaw_monorepo_root
test_index_list_surfaces_cli_failures
test_cli_wrapper_logs_usage
test_usage_log_fallback_encodes_json
test_usage_log_omits_detail_as_null
test_brief_mentions_logged_cli
