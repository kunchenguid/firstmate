#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, bounded concurrency, budgets, timing
# markers, JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_ensure_pyyaml || fail "python3 PyYAML is required to parse workflow policy"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_pyyaml_vendor_is_offline_without_package_commands() {
  local vendor="$ROOT/tests/fixtures/vendor/pyyaml-6.0.2" tmp fakebin
  [ -f "$vendor/LICENSE" ] || fail "vendored PyYAML is missing upstream LICENSE"
  [ -f "$vendor/UPSTREAM" ] || fail "vendored PyYAML is missing digest provenance"
  assert_grep 'sdist_sha256=' "$vendor/UPSTREAM" \
    "vendored PyYAML must record the upstream sdist digest"
  if grep -Eq 'pip install|pip3 install' "$ROOT/tests/lib.sh"; then
    fail "fm_ensure_pyyaml must not invoke a package installer during tests"
  fi
  PYTHONNOUSERSITE=1 PYTHONPATH="$vendor" python3 - <<'PY' \
    || fail "hermetic PyYAML vendor could not parse workflow YAML offline"
import sys

import yaml

assert any("fixtures/vendor/pyyaml-6.0.2" in p for p in sys.path)
assert yaml.safe_load("jobs:\n  lint:\n    runs-on: ubuntu-latest\n") == {
    "jobs": {"lint": {"runs-on": "ubuntu-latest"}}
}
PY
  tmp=$(fm_test_tmproot fm-pyyaml-offline)
  fakebin=$(fm_fakebin "$tmp")
  for tool in pip pip3; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf 'package installer must not run during fm_ensure_pyyaml\n' >&2
exit 99
SH
    chmod +x "$fakebin/$tool"
  done
  PATH="$fakebin:$PATH" PYTHONNOUSERSITE=1 PYTHONPATH='' \
    bash -c '
      ROOT="'"$ROOT"'"
      # shellcheck source=tests/lib.sh
      . "$ROOT/tests/lib.sh"
      fm_ensure_pyyaml
    ' || fail "fm_ensure_pyyaml must succeed from the pinned vendor without package commands"
  pass "workflow-policy tests use pinned offline PyYAML with upstream provenance"
}

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-unconfigured.XXXXXX")
  listed=$(FM_CONFIG_OVERRIDE="$tmp/config" "$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  rm -rf "$tmp"
  pass "exact suite coverage: --all lists every tests/*.test.sh once without a disabled policy"
}

test_family_selection() {
  local listed line pr_forge
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pr_forge=$("$RUNNER" --list --family pr-forge)
  assert_contains "$pr_forge" "tests/fm-check-register.test.sh" \
    "pr-forge family must include custom-check lifecycle coverage"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script opencode_plugin
  mkdir -p "$repo/bin" "$repo/tests" "$repo/.opencode/plugins"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-skill-war-room.test.sh \
    fm-ask-user-authority.test.sh \
    fm-documentation-audiences.test.sh \
    fm-test-isolation-proof.test.sh \
    fm-test-run.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-harness-adapter-instructions-live-e2e.test.sh \
    fm-harness-adapter-references.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-procevent-quota.test.sh \
    fm-quota-choose.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-pi-windows-shell-invocation.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-bearings-board-render.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-control-herdr-smoke.test.sh \
    fm-backend-orca.test.sh \
    fm-model-usage.test.sh \
    fm-memory-doctor.test.sh \
    fm-pending-reply.test.sh \
    fm-procevent.test.sh \
    fm-public-followup.test.sh \
    fm-slack-captain-channel.test.sh \
    fm-slack-socket.test.sh \
    fm-x-mode.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  # A behavior-area fixture extracted out of a suite: only the helper names the
  # shared source, and only the suite names the helper.
  printf '#!/usr/bin/env bash\n# drives bin/fm-fixture-shared.sh\n' \
    >"$repo/tests/fixture-helpers.sh"
  printf '# tests/fixture-helpers.sh\n' >>"$repo/tests/fm-pr-merge.test.sh"
  : >"$repo/bin/fm-fixture-shared.sh"
  # Single-file fixtures kept directly under tests/fixtures/: one named by a
  # suite, one named by nothing.
  mkdir -p "$repo/tests/fixtures"
  : >"$repo/tests/fixtures/flat-named.golden"
  : >"$repo/tests/fixtures/flat-orphan.golden"
  printf '# tests/fixtures/flat-named.golden\n' >>"$repo/tests/fm-brief.test.sh"
  mkdir -p "$repo/tests/assets"
  : >"$repo/tests/assets/board-render-harness.mjs"
  printf '# tests/assets/board-render-harness.mjs\n' >>"$repo/tests/fm-bearings-board-render.test.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-launch-axis-lib.sh"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-model-usage.mjs"
  : >"$repo/bin/fm-x-lib.sh"
  : >"$repo/bin/fm-public-followup-lib.sh"
  : >"$repo/bin/fm-procevent-lib.sh"
  : >"$repo/bin/fm-slack-lib.sh"
  : >"$repo/bin/fm-pending-reply-lib.sh"
  : >"$repo/bin/fm-control-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  : >"$repo/bin/fm-procevent-quota.sh"
  : >"$repo/bin/fm-quota-axi-lib.sh"
  : >"$repo/bin/fm-quota-choose.sh"
  : >"$repo/bin/unmapped-source.sh"
  # A shared helper with no curated family of its own, named by exactly ONE
  # script of the expensive real-Herdr family and consumed by one curated
  # watcher script. This is the shape that made a one-line helper change select
  # every real-Herdr E2E.
  : >"$repo/bin/shared-probe-lib.sh"
  printf '# shared-probe-lib.sh\n' >>"$repo/tests/fm-backend-herdr-smoke.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: the reference must reach
  # the file verbatim so the changed-file scan can find it, not expand here.
  printf '. "$ROOT/bin/shared-probe-lib.sh"\n' >"$repo/bin/fm-watch-probe.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p \
    "$repo/.agents/skills/example" \
    "$repo/.agents/skills/war-room/templates" \
    "$repo/.agents/skills/harness-adapters/references/common" \
    "$repo/.claude" "$repo/.pi/extensions" "$repo/docs" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.agents/skills/war-room/templates/lead.md"
  : >"$repo/.agents/skills/harness-adapters/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  printf '{}\n' >"$repo/.backpassrc.json"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  # Keep the path split so this regression proves the explicit path map instead
  # of satisfying the runner's source-reference scan with its own test text.
  opencode_plugin="$repo/.opencode/plugins/fm-primary-"
  : >"${opencode_plugin}cd-check.js"
  : >"$repo/docs/fm-test-isolation-proof.md"
  : >"$repo/CONTRIBUTING.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

# Build a repository with a primary checkout and one linked worktree, each
# holding a runnable copy of the runner and a probe suite that records the fact
# that it ran. Untracked copies are enough: the runner resolves its root from
# its own path, and the probe is named explicitly.
init_primary_and_linked_worktree() {
  local repo=$1 linked=$2 tree
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b linked-probe "$linked"
  for tree in "$repo" "$linked"; do
    mkdir -p "$tree/bin" "$tree/tests"
    cp "$RUNNER" "$tree/bin/fm-test-run.sh"
    cp "$ROOT/bin/fm-timeout-lib.sh" "$tree/bin/fm-timeout-lib.sh"
    chmod +x "$tree/bin/fm-test-run.sh"
    cat >"$tree/tests/probe.test.sh" <<PROBE
#!/usr/bin/env bash
echo "ok - probe suite"
: >"$tree/ran"
PROBE
    chmod +x "$tree/tests/probe.test.sh"
  done
}

# A task worker's isolated placement is checked once, when the task starts.
# Nothing re-checks it, so a worker that later changes directory into the
# repository's primary checkout would run this branch-switching suite in the one
# checkout every linked worktree resolves against. The runner refuses that.
test_task_marker_refuses_the_primary_checkout() {
  local tmp repo linked out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-primary.XXXXXX")
  repo="$tmp/repo"
  linked="$tmp/linked"
  init_primary_and_linked_worktree "$repo" "$linked"

  # Marker set, primary checkout: refuse, name the primary, and run nothing.
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" tests/probe.test.sh 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "the runner must refuse the primary checkout under a task marker"; }
  assert_contains "$out" "primary checkout" "refusal did not name the primary checkout"
  assert_contains "$out" "FM_TASK_ID=probe-task" "refusal did not name the task marker"
  assert_contains "$out" "task worktree" "refusal did not point at the task worktree"
  assert_not_contains "$out" "FM_TEST_BEGIN" "the refusal must happen before any suite runs"
  assert_absent "$repo/ran" "the refused run still executed a suite"

  # Marker set, linked worktree: the assigned placement, so the suite runs.
  FM_TASK_ID=probe-task "$linked/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "the runner must still run in a linked task worktree"; }
  assert_present "$linked/ran" "the linked-worktree run did not execute its suite"

  # No marker: a person in their own checkout is unaffected.
  "$repo/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "an unmarked run in the primary checkout must be unchanged"; }
  assert_present "$repo/ran" "the unmarked run did not execute its suite"

  # Inspection executes nothing, so it stays available even in the primary.
  rm -f "$repo/ran"
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" --list tests/probe.test.sh 2>&1) \
    || { rm -rf "$tmp"; fail "--list must remain available under a task marker"; }
  [ "$out" = "tests/probe.test.sh" ] \
    || { rm -rf "$tmp"; fail "--list under a task marker printed: $out"; }
  assert_absent "$repo/ran" "--list must not execute a suite"

  rm -rf "$tmp"
  pass "a task marker refuses execution in the primary checkout and leaves worktrees and inspection alone"
}

test_changed_runner_surfaces_select_their_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-owner-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A change to the runner selects the WHOLE pure-contract-unit family, not
  # just its own contract test. The runner executes every script in that
  # family, so its own test passing proves its logic is right, not that the
  # suite it drives still runs. Narrowing this to the contract owners would
  # also make any wall-clock claim about the changed suite trivially true by
  # not running the work.
  printf '\n' >>"$repo/bin/fm-test-run.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-test-run.test.sh*) ;;
    *) fail "runner change did not select its own contract test: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-ask-user-authority.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  git -C "$repo" add bin/fm-test-run.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm runner-change

  # The same holds for the surfaces that document that contract.
  printf '\n' >>"$repo/docs/fm-test-isolation-proof.md"
  printf '\n' >>"$repo/CONTRIBUTING.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-documentation-audiences.test.sh*) ;;
    *) fail "documentation surface change did not select audience coverage: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "documentation surface change did not select its curated family: $listed" ;;
  esac

  rm -rf "$tmp"
  pass "runner and its documentation surfaces select their curated family, not just their contract owners"
}

test_changed_large_mapped_set_is_bounded() {
  local tmp repo i
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-large-mapped.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  mkdir -p "$repo/docs"
  for i in $(seq 1 80); do
    printf '#!/usr/bin/env bash\n' > "$repo/tests/scale-$i.test.sh"
    chmod +x "$repo/tests/scale-$i.test.sh"
    printf '# fixture\n' > "$repo/docs/scale-$i.md"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm scale-fixture
  for i in $(seq 1 80); do
    printf '\n' >> "$repo/docs/scale-$i.md"
  done

  python3 - "$repo" <<'PY' \
    || fail "mapped changed-file selection did not finish within its bounded inspection window"
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
result = subprocess.run(
    ["bin/fm-test-run.sh", "--list", "--changed", "--base", "HEAD"],
    cwd=repo,
    text=True,
    capture_output=True,
    timeout=10,
    check=True,
)
assert "tests/fm-test-run.test.sh" in result.stdout
PY
  rm -rf "$tmp"
  pass "large mapped change sets select their curated coverage within a bounded inspection window"
}

test_changed_dependency_graph_is_precise_and_explains_selection() {
  local tmp repo runner listed paths reason count
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-dependency-graph.XXXXXX")
  repo="$tmp/repo"
  runner=${FM_DEPENDENCY_RUNNER:-$RUNNER}
  mkdir -p "$repo/bin" "$repo/tests/fixtures"
  cp "$runner" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
cat >"$repo/bin/a.sh" <<'EOF'
#!/usr/bin/env bash
. "$FIXTURE_BIN/l.sh"
EOF
  printf '#!/usr/bin/env bash\n' >"$repo/bin/b.sh"
  printf '#!/usr/bin/env bash\n' >"$repo/bin/l.sh"
  # shellcheck disable=SC2016 # literal fixture source reference
  printf '. "$ROOT/bin/a.sh"\n' >"$repo/tests/a-source.test.sh"
  printf '# tests/fixtures/a.fixture\n' >"$repo/tests/a-fixture.test.sh"
  printf 'bin/b.sh\n' >"$repo/tests/b-invokes.test.sh"
  # shellcheck disable=SC2016 # literal fixture source reference
  printf '. "$ROOT/bin/l.sh"\n' >"$repo/tests/l-direct.test.sh"
  printf '# unrelated\n' >"$repo/tests/unrelated.test.sh"
  printf '# family fallback owner\n' >"$repo/tests/fm-test-run.test.sh"
  printf 'bin/a.sh\n' >"$repo/tests/fixtures/a.fixture"
  printf '# fallback target\n' >"$repo/README.md"
  chmod +x "$repo/tests"/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  printf '# change A\n' >>"$repo/bin/a.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  paths=$(printf '%s\n' "$listed" | cut -f1 | LC_ALL=C sort)
  count=$(printf '%s\n' "$paths" | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "A must select exactly its two dependents, got: $listed"
  assert_contains "$paths" "tests/a-source.test.sh" "A source dependent is selected"
  assert_contains "$paths" "tests/a-fixture.test.sh" "A fixture dependent is selected"
  assert_not_contains "$paths" "tests/l-direct.test.sh" "A change does not select L-only tests"
  reason=$(printf '%s\n' "$listed" | grep -F 'tests/a-source.test.sh' || true)
  assert_contains "$reason" "changed=bin/a.sh" "--list identifies the changed source"
  assert_contains "$reason" "source" "--list identifies the dependency edge"
  git -C "$repo" add bin/a.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm change-a

  printf '# change L\n' >>"$repo/bin/l.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  paths=$(printf '%s\n' "$listed" | cut -f1 | LC_ALL=C sort)
  count=$(printf '%s\n' "$paths" | wc -l | tr -d ' ')
  [ "$count" = 3 ] || fail "L must select its transitive closure, got: $listed"
  assert_contains "$paths" "tests/a-source.test.sh" "L reaches the test through A"
  assert_contains "$paths" "tests/a-fixture.test.sh" "L reaches the fixture test through A"
  assert_contains "$paths" "tests/l-direct.test.sh" "L direct dependent is selected"
  reason=$(printf '%s\n' "$listed" | grep -F 'tests/a-source.test.sh' || true)
  assert_contains "$reason" "bin/l.sh --source--> bin/a.sh" "--list preserves the transitive edge"
  git -C "$repo" add bin/l.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm change-l

  printf '# docs change\n' >>"$repo/README.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-test-run.test.sh" "unmapped documentation falls back to its curated family"
  rm -rf "$tmp"
  pass "changed selection follows direct and transitive dependency edges with reasons"
}

test_changed_dependency_graph_covers_backend_closure_and_test_self() {
  local tmp repo runner listed paths expected
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-dependency-backend.XXXXXX")
  repo="$tmp/repo"
  runner=${FM_DEPENDENCY_RUNNER:-$RUNNER}
  mkdir -p "$repo/bin/backends" "$repo/tests"
  cp "$runner" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/bin/backend.sh" <<'EOF'
#!/usr/bin/env bash
. "$BACKEND_DIR/backends/herdr.sh"
EOF
  printf '#!/usr/bin/env bash\n' >"$repo/bin/backends/herdr.sh"
  printf 'bin/backend.sh\n' >"$repo/tests/backend-a.test.sh"
  printf 'bin/backend.sh\n' >"$repo/tests/backend-b.test.sh"
  printf '# changed test\n' >"$repo/tests/edited.test.sh"
  printf '# tests/edited.test.sh\n' >"$repo/tests/mentions-edited.test.sh"
  chmod +x "$repo/tests"/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

  printf '# changed backend\n' >>"$repo/bin/backends/herdr.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  paths=$(printf '%s\n' "$listed" | cut -f1 | LC_ALL=C sort)
  expected=$(rg -l 'bin/backend\.sh' "$repo/tests" | sed "s|$repo/||" | LC_ALL=C sort)
  [ "$paths" = "$expected" ] || fail "variable-sourced backend closure must equal rg dependents: $paths"

  git -C "$repo" add bin/backends/herdr.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm backend-change
  printf '# edited\n' >>"$repo/tests/edited.test.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  paths=$(printf '%s\n' "$listed" | cut -f1 | LC_ALL=C sort)
  assert_contains "$paths" "tests/edited.test.sh" "a changed test always selects itself"
  rm -rf "$tmp"
  pass "variable source closures and changed test files never under-select"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc opencode_plugin
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/bin/fm-launch-axis-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" "launch-axis changes select backend coverage"
  assert_contains "$listed" "tests/fm-brief.test.sh" "launch-axis changes select pure contract coverage"
  git -C "$repo" add bin/fm-launch-axis-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm launch-axis-change

  printf '\n' >>"$repo/bin/fm-model-usage.mjs"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-model-usage.test.sh" "usage reader changes select their own contract coverage"
  git -C "$repo" add bin/fm-model-usage.mjs
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm usage-reader-change

  printf '\n' >>"$repo/bin/fm-x-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-x-mode.test.sh" "X owner changes preserve X-mode coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" "X owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" "X owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-x-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm x-owner-change

  printf '\n' >>"$repo/bin/fm-public-followup-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-public-followup.test.sh" \
    "public-followup owner changes preserve public-followup coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "public-followup owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "public-followup owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-public-followup-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm public-followup-owner-change

  printf '\n' >>"$repo/bin/fm-procevent-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent.test.sh" \
    "process-event owner changes preserve process-event coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "process-event owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "process-event owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-procevent-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm procevent-owner-change

  printf '\n' >>"$repo/bin/fm-slack-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-slack-captain-channel.test.sh" \
    "Slack owner changes preserve Slack coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "Slack owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "Slack owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-slack-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm slack-owner-change

  printf '\n' >>"$repo/bin/fm-pending-reply-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pending-reply.test.sh" \
    "pending-reply owner changes preserve pending-reply coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "pending-reply owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "pending-reply owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-pending-reply-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm pending-reply-owner-change

  printf '\n' >>"$repo/bin/fm-fixture-shared.sh"
  set +e
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/helper-err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "source named only by a shared fixture must stay mapped: $(cat "$tmp/helper-err")"
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "source named only by a shared fixture selects the suites sourcing that fixture"
  git -C "$repo" add bin/fm-fixture-shared.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture-shared-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "turn-end extension selects native-Windows shell coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf ' { }\n' >"$repo/.backpassrc.json"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" \
    "Backpass configuration changes select pure contract coverage"
  git -C "$repo" add .backpassrc.json
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm backpass-config-change

  opencode_plugin="$repo/.opencode/plugins/fm-primary-"
  printf '\n' >>"${opencode_plugin}cd-check.js"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" \
    "OpenCode cd adapter changes select cd-guard coverage"
  git -C "$repo" add .opencode
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm opencode-cd-adapter-change

  printf '\n' >>"$repo/tests/fixtures/flat-named.golden"
  set +e
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/flat-err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "a single-file fixture named by a suite must stay mapped: $(cat "$tmp/flat-err")"
  assert_contains "$listed" "tests/fm-brief.test.sh" \
    "a single-file fixture selects the suite that names it"
  git -C "$repo" add tests/fixtures/flat-named.golden
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm flat-fixture-change

  printf '\n' >>"$repo/tests/fixtures/flat-orphan.golden"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a single-file fixture no suite names must fail closed, got $rc"
  grep -Fq 'no changed-test mapping for source path: tests/fixtures/flat-orphan.golden' "$tmp/err" \
    || fail "unnamed single-file fixture failure is not actionable: $(cat "$tmp/err")"
  git -C "$repo" add tests/fixtures/flat-orphan.golden
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm flat-orphan-change

  printf '\n' >>"$repo/tests/assets/board-render-harness.mjs"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-bearings-board-render.test.sh" \
    "the board-render harness selects its consuming render suite"
  git -C "$repo" add tests/assets/board-render-harness.mjs
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm board-render-harness-change

  mkdir -p "$repo/rejected"
  printf 'night report\n' >"$repo/gnhf-night-report.md"
  printf 'rejected candidate\n' >"$repo/rejected/1-candidate.md"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "tracked autonomous-run artifacts must select no family instead of failing closed: $(cat "$tmp/err")"
  git -C "$repo" add gnhf-night-report.md rejected
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm run-artifact-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter reference selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter reference selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-reference-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/SKILL.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter router selects portable structural coverage"
  assert_contains "$listed" "tests/fm-harness-adapter-instructions-live-e2e.test.sh" "harness adapter router selects opt-in instruction coverage"
  git -C "$repo" add .agents/skills/harness-adapters/SKILL.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-router-change

  printf '\n' >>"$repo/bin/fm-procevent-quota.sh"
  printf '\n' >>"$repo/bin/fm-quota-choose.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "quota process-event source selects its focused test"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "quota chooser source selects its focused test"
  git -C "$repo" add bin/fm-procevent-quota.sh bin/fm-quota-choose.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-source-change

  printf '\n' >>"$repo/bin/fm-quota-axi-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "shared quota validator selects process-event coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "shared quota validator selects chooser coverage"
  git -C "$repo" add bin/fm-quota-axi-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-validator-change

  printf '\n' >>"$repo/bin/fm-control-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "control library keeps backend coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "control library keeps session coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "control library selects chooser coverage"
  git -C "$repo" add bin/fm-control-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm control-lib-change

  printf '\n' >>"$repo/bin/fm-timeout-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "timeout library selects quota polling coverage"
  git -C "$repo" add bin/fm-timeout-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm timeout-lib-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"

  rm -f "$repo/src/unmapped.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  [ -z "$listed" ] || fail "a retired unmapped source without consumers selected tests: $listed"
  rm -rf "$tmp"
  pass "changed selection covers dependents, fails closed for live unmapped source, and accepts retired unconsumed source"
}

test_changed_war_room_template_selects_contract_family() {
  local tmp repo listed expected
  tmp=$(fm_test_tmproot fm-test-run-war-room-template)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/.agents/skills/war-room/templates/lead.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || fail "changed room template must select tests instead of refusing its path"
  expected=$(cd "$repo" && bin/fm-test-run.sh --list --family pure-contract-unit)
  [ "$(printf '%s\n' "$listed" | cut -f1)" = "$expected" ] || fail "room template must select the existing contract family"
  assert_contains "$listed" "tests/fm-skill-war-room.test.sh" \
    "room template must select its skill contract suite"
  pass "changed room template selects the contract family including its skill suite"
}

# A direct test reference is per-script evidence. Widening it to the referencing
# test's whole family is what turned a one-line change to a shared helper into
# every real-Herdr E2E, including scripts with no dependency on it at all.
# Consumer bin/ scripts must still resolve through the curated map, so recorded
# family-level coupling is not lost along the way.
test_changed_bin_reference_selects_per_script_not_per_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/shared-probe-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)

  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" \
    "the one gated script that names the helper must still be selected"
  case "$listed" in
    *tests/fm-control-herdr-smoke.test.sh*)
      fail "a single gated script's reference dragged in its whole family: $listed"
      ;;
  esac
  # The curated consumer keeps its family-level coupling.
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a curated consumer of the helper must still select its whole family"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a curated consumer of the helper must still select its whole family"

  rm -rf "$tmp"
  pass "a bin reference selects the referencing scripts, and consumers still select their curated families"
}

# Exercise begin/end markers from real fixture processes to prove the automatic
# changed-suite default and its explicit serial override.
test_changed_uses_bounded_automatic_concurrency() {
  local tmp repo script serial_shape parallel_shape timeout_repo timeout_script expected_jobs rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-consent.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - concurrency consent fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/parallel.json") \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default changed fixture run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "plain --changed did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --jobs 1 --json "$tmp/serial.json") \
    >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial changed fixture run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force serial execution: $serial_shape"
  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PY' \
    || fail "changed timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PY

  timeout_repo="$tmp/timeout-repo"
  timeout_script=tests/fm-calm-pi-extension.test.sh
  mkdir -p "$timeout_repo/bin" "$timeout_repo/tests"
  cp "$RUNNER" "$timeout_repo/bin/fm-test-run.sh"
  cat >"$timeout_repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  [ "$1" -eq 900 ] || return 99
  return 124
}
SH
  cat >"$timeout_repo/$timeout_script" <<'SH'
#!/usr/bin/env bash
touch should-not-run
echo "not ok - automatic timeout helper was bypassed"
SH
  chmod +x "$timeout_repo/bin/fm-test-run.sh" "$timeout_repo/$timeout_script"
  git -C "$timeout_repo" init -q
  git -C "$timeout_repo" add .
  git -C "$timeout_repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$timeout_repo/$timeout_script"
  set +e
  (cd "$timeout_repo" && bin/fm-test-run.sh --changed --base HEAD) \
    >"$tmp/timeout.out" 2>"$tmp/timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "single-script automatic timeout must fail the run, got $rc"
  grep -Eq '^FM_TEST_END .+ tests/fm-calm-pi-extension\.test\.sh exit=124 ' "$tmp/timeout.out" \
    || fail "single unproven changed script did not receive the automatic timeout: $(cat "$tmp/timeout.out")"
  [ ! -e "$timeout_repo/should-not-run" ] || fail "automatic timeout helper did not own the single changed script"

  rm -rf "$tmp"
  pass "changed defaults to bounded automatic scheduling with serial override"
}

test_windows_posix_mode_emulation_does_not_fail_parallel_runs() {
  local tmp repo fakebin real_stat out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-windows-modes.XXXXXX")
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  real_stat=$(command -v stat)
  init_changed_fixture_repo "$repo"
  mkdir -p "$fakebin"
  cat >"$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-MINGW64_NT-10.0}"
SH
  cat >"$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  printf '%s\n' 755
  exit 0
fi
exec "$REAL_STAT" "$@"
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "native-Windows POSIX-mode emulation"
  assert_contains "$out" "FM_TEST_SUMMARY total=2 failed=0" \
    "Windows mode emulation did not complete both parallel scripts"

  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" FAKE_UNAME=CYGWIN_NT-10.0 \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-ask-user-authority.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Cygwin POSIX-mode enforcement"
  assert_contains "$out" "isolation failure: worker root mode is 755, expected 0700" \
    "Cygwin mode enforcement did not reject a non-0700 worker root"
  rm -rf "$tmp"
  pass "Windows emulation exempts only synthetic POSIX modes"
}

# A local verification round names the subjects it cares about. Exercise begin/end
# markers from real fixture processes to prove that a plain list of script paths
# gets bounded automatic scheduling without changing its per-script timeout
# contract, so verifying several subjects is one bounded concurrent run rather
# than a serial chain of separate `bash tests/X.test.sh` invocations.
test_script_list_uses_bounded_automatic_concurrency() {
  local tmp repo script parallel_shape serial_shape mixed_shape expected_jobs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-script-list.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  # fm-cd-pretool-check and fm-pr-merge are individually proven isolated;
  # fm-backend-orca is not, so it must still land in the serial tail.
  for script in fm-cd-pretool-check.test.sh fm-pr-merge.test.sh fm-backend-orca.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - script-list concurrency fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --json "$tmp/parallel.json") >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default script-list run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "a plain script list did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --jobs 1 --json "$tmp/serial.json") >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial script-list run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force a serial script list: $serial_shape"

  # An unproven script in the list is scheduled around, never refused and never
  # run beside another script.
  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      tests/fm-backend-orca.test.sh) >"$tmp/mixed.out" 2>"$tmp/mixed.err" \
    || fail "mixed proven/unproven script list failed: $(cat "$tmp/mixed.err")"
  mixed_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/mixed.out" | awk '{print $1}' | paste -sd, -)
  [ "$mixed_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN,FM_TEST_END,FM_TEST_END,FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "an unproven script was not kept in the serial tail: $mixed_shape"

  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PYJSON' \
    || fail "script-list timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PYJSON

  # An explicit zero keeps the historical unbounded mode available even when
  # the timeout helper is absent.
  rm -f "$repo/bin/fm-timeout-lib.sh"
  (cd "$repo" && bin/fm-test-run.sh --per-script-timeout-secs 0 tests/fm-backend-orca.test.sh) \
    >"$tmp/named.out" 2>"$tmp/named.err" \
    || fail "an explicit unbounded script unexpectedly required a timeout helper: $(cat "$tmp/named.err")"
  grep -Eq '^FM_TEST_END .+ tests/fm-backend-orca\.test\.sh exit=0 ' "$tmp/named.out" \
    || fail "an explicitly unbounded named script did not run: $(cat "$tmp/named.out")"

  rm -rf "$tmp"
  pass "a plain script list defaults to bounded automatic concurrency and explicit zero remains unbounded"
}

test_family_proofs_run_in_separate_concurrent_phases() {
  local tmp repo script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-family-phases.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-calm-pi-extension.test.sh fm-vendor-auth-probe.test.sh \
    fm-pr-check-security.test.sh fm-teardown.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - family phase fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh \
      tests/fm-pr-check-security.test.sh tests/fm-calm-pi-extension.test.sh \
      tests/fm-teardown.test.sh tests/fm-vendor-auth-probe.test.sh --jobs 4) \
    >"$tmp/out" 2>"$tmp/err" \
    || fail "cross-family phase fixture failed: $(cat "$tmp/err")"

  python3 - "$tmp/out" <<'PY' \
    || fail "family-proof scripts from different families overlapped: $(cat "$tmp/out")"
import re, sys
active = {}
overlap = {"pure-contract-unit": False, "pr-forge": False}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("FM_TEST_BEGIN "):
        match = re.search(r" (tests/\S+) family=(\S+) ", line)
        assert match, line
        path, family = match.groups()
        assert not active or set(active.values()) == {family}, (active, line)
        active[path] = family
        if sum(value == family for value in active.values()) > 1:
            overlap[family] = True
    elif line.startswith("FM_TEST_END "):
        match = re.search(r" (tests/\S+) exit=", line)
        assert match and match.group(1) in active, (active, line)
        del active[match.group(1)]
assert not active, active
assert all(overlap.values()), overlap
PY

  rm -rf "$tmp"
  pass "family proofs run concurrently only within separate family phases"
}

test_empty_selection_emits_summary() {
  local tmp repo out json rc fake_bin real_git
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'run artifact only\n' >"$repo/gnhf-night-report.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  printf '%s\n' "$out" | grep -Eq \
    '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' \
    || fail "empty selection summary is missing or malformed: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["summary"]["skipped_gate"] == 0
assert doc["summary"]["duration_ms"] >= 0
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  fake_bin="$tmp/fake-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SLOW_GIT_MARKER" ]; then
  : >"$SLOW_GIT_MARKER"
  sleep 1
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  set +e
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --max-wall-ms 100) \
    >"$tmp/slow-selection.out" 2>"$tmp/slow-selection.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an empty run past its budget must fail normally, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its summary"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=100 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its budget result"
  [ -e "$tmp/slow-git" ] || fail "the slow selection fixture did not run"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --max-wall-ms nope) \
    >"$tmp/bad-budget.out" 2>"$tmp/bad-budget.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed budget on an empty selection must be refused, got $rc"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --per-script-timeout-secs nope) \
    >"$tmp/bad-timeout.out" 2>"$tmp/bad-timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed timeout on an empty selection must be refused, got $rc"
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_unwritable_timing_artifact_keeps_the_suite_verdict() {
  local tmp fixture red out err json rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-artifact.XXXXXX")
  fixture="$tmp/ok.test.sh"
  red="$tmp/red.test.sh"
  out="$tmp/out.txt"
  err="$tmp/err.txt"
  # A path whose parent is a regular file can never be created or written.
  : >"$tmp/blocked"
  json="$tmp/blocked/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  cat >"$red" <<'SH'
#!/usr/bin/env bash
echo "not ok - fixture"
exit 1
SH
  chmod +x "$fixture" "$red"

  rc=0
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] \
    || { rm -rf "$tmp"; fail "an unwritable timing artifact reclassified a green run: rc=$rc"; }
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 ' "$out" \
    || { rm -rf "$tmp"; fail "the green run lost its verdict trailer: $(cat "$out")"; }
  assert_contains "$(cat "$err")" "could not write timing artifact: $json" \
    "the contained artifact failure was not reported"
  [ ! -e "$json" ] || { rm -rf "$tmp"; fail "an artifact appeared at an unwritable path"; }

  rc=0
  "$RUNNER" --json "$json" "$red" >"$out" 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || { rm -rf "$tmp"; fail "a contained artifact failure also swallowed a failing script"; }
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=1 ' "$out" \
    || { rm -rf "$tmp"; fail "the red run lost its verdict trailer: $(cat "$out")"; }
  rm -rf "$tmp"
  pass "an unwritable timing artifact is reported without changing the suite verdict"
}

test_lane_selection_grammar_is_the_published_lane_label() {
  local tmp repo runner proven
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-selection.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  # fm-daemon is neither proven-isolated nor Herdr-gated, so it is the whole
  # portable serial remainder here; the smoke suite is the whole Herdr family.
  printf '#!/usr/bin/env bash\necho "ok - serial fixture"\n' >"$repo/tests/fm-daemon.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - herdr fixture"\n' \
    >"$repo/tests/fm-backend-herdr-smoke.test.sh"
  chmod +x "$runner" "$repo/tests/fm-daemon.test.sh" "$repo/tests/fm-backend-herdr-smoke.test.sh"
  # The proven-isolated members of portable-parallel-1, so the one production
  # lane that runs with bounded in-lane parallelism can be selected for real.
  while IFS= read -r proven; do
    printf '#!/usr/bin/env bash\necho "ok - proven fixture"\n' >"$repo/$proven"
    chmod +x "$repo/$proven"
  done < <(FM_CONFIG_OVERRIDE="$tmp/config" "$RUNNER" --list --lane portable-parallel-1)

  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial --json "$tmp/lane.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a lane-selected run over a green fixture must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial \
    --fail-on-gate-skip 'herdr not found' --json "$tmp/lane-suffix.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a lane-selected run with a gate-skip token must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --family real-herdr-gated \
    --fail-on-gate-skip 'herdr not found' --json "$tmp/family.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a family-selected run with a gate-skip token must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 --lane portable-parallel-1 \
    --json "$tmp/jobs.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a bounded-parallel lane run over green fixtures must pass"; }

  # bin/fm-ci.sh labels each row of the published Water 7 timing table by reading
  # this emitted selection as <kind>=<name>[;<suffix>...]. The exact strings are
  # pinned at the emitter, so changing the grammar fails this suite instead of
  # silently mislabelling a job summary.
  python3 -c '
import json, sys
lane, lane_suffix, family, jobs = (
    json.load(open(path, encoding="utf-8"))["selection"] for path in sys.argv[1:]
)
assert lane == "lane=portable-serial", lane
assert lane_suffix == "lane=portable-serial;fail-on-gate-skip=herdr not found", lane_suffix
assert family == "family=real-herdr-gated;fail-on-gate-skip=herdr not found", family
assert jobs == "lane=portable-parallel-1;jobs=2", jobs
' "$tmp/lane.json" "$tmp/lane-suffix.json" "$tmp/family.json" "$tmp/jobs.json" \
    || { rm -rf "$tmp"; fail "the emitted selection no longer carries the lane label fm-ci.sh publishes"; }
  rm -rf "$tmp"
  pass "the emitted selection pins the lane label the job summary publishes"
}

test_aggregate_json_contains_an_unusable_input() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggmissing.XXXXXX")
  printf '%s\n' '{"run_id": "a", "selection": "lane=portable-serial", "summary": {"total": 0, "failed": 0, "skipped_gate": 0, "duration_ms": 0}, "scripts": []}' \
    >"$tmp/a.json"
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/absent.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "aggregating a never-written lane artifact must fail"; }
  assert_contains "$out" "aggregate input not found: $tmp/absent.json" \
    "the missing aggregate input was not named"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "a missing aggregate input raised a Python traceback into the job log"
  [ ! -e "$tmp/out.json" ] \
    || { rm -rf "$tmp"; fail "a partial aggregate was written from an incomplete lane set"; }

  printf '%s' '{"run_id": "a", "selection": "lane=portab' >"$tmp/truncated.json"
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/truncated.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "aggregating a truncated lane artifact must fail"; }
  assert_contains "$out" "aggregate input is not valid timing JSON: $tmp/truncated.json" \
    "the unparsable aggregate input was not named"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "a truncated aggregate input raised a Python traceback into the job log"
  rm -rf "$tmp"
  pass "a missing or unparsable aggregate input is reported without a traceback"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_serial_runner_sanitizes_firstmate_overrides() {
  local tmp fixture out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-env.XXXXXX")
  fixture="$tmp/env.test.sh"
  out="$tmp/out.txt"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
if env | grep -Eq '^(FM_HOME|FM_STATE_OVERRIDE|FM_DATA_OVERRIDE|FM_ROOT_OVERRIDE|FM_PROJECTS_OVERRIDE|FM_CONFIG_OVERRIDE|FM_BACKEND)='; then
  echo "not ok - inherited Firstmate override reached serial test"
  exit 1
fi
echo "ok - serial test environment is isolated"
SH
  chmod +x "$fixture"
  FM_HOME=/tmp/inherited-home \
    FM_STATE_OVERRIDE=/tmp/inherited-state \
    FM_DATA_OVERRIDE=/tmp/inherited-data \
    FM_ROOT_OVERRIDE=/tmp/inherited-root \
    FM_PROJECTS_OVERRIDE=/tmp/inherited-projects \
    FM_CONFIG_OVERRIDE=/tmp/inherited-config \
    FM_BACKEND=inherited-backend \
    "$RUNNER" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "serial runner leaked a Firstmate override"; }
  grep -Fq 'ok - serial test environment is isolated' "$out" \
    || { rm -rf "$tmp"; fail "serial environment fixture did not run"; }
  rm -rf "$tmp"
  pass "serial runner sanitizes Firstmate overrides"
}

test_gate_skip_accounting_under_unsupported_inherited_locale() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  LC_ALL=fm_TEST_INVALID_LOCALE LANG=fm_TEST_INVALID_LOCALE \
    "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting survives an unsupported inherited locale"
}

# The runner replaces an unusable inherited locale so children never warn into
# the protocol stream, but the replacement must still decode UTF-8: the suite
# asserts on multibyte content (composer glyphs, the U+2063 injection sentinel,
# codepoint-bounded text), and a byte-oriented locale makes every ${#s}/${s:0:1}
# in those assertions count bytes instead.
test_inherited_locale_replacement_keeps_utf8_text_semantics() {
  local tmp probe out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-locale.XXXXXX")
  probe="$tmp/locale.test.sh"
  cat >"$probe" <<'SH'
#!/usr/bin/env bash
s='❯x'
printf 'chars=%s first=%s\n' "${#s}" "${s:0:1}"
SH
  chmod +x "$probe"
  out=$(LC_ALL=fm_TEST_INVALID_LOCALE LANG=fm_TEST_INVALID_LOCALE \
    "$RUNNER" "$probe" 2>/dev/null) \
    || { rm -rf "$tmp"; fail "the locale probe fixture must run"; }
  rm -rf "$tmp"
  if [ "$(env LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = UTF-8 ] \
    || [ "$(env LC_ALL=en_US.UTF-8 locale charmap 2>/dev/null)" = UTF-8 ]; then
    assert_contains "$out" 'chars=2 first=❯' \
      "the replacement locale must read ❯ as one character"
  else
    # No UTF-8 locale exists here, so the documented C fallback is correct.
    assert_contains "$out" 'chars=4' "the C fallback must still be a working locale"
  fi
  pass "an unusable inherited locale is replaced by the host's best UTF-8 locale"
}

test_gate_skip_reason_is_recorded() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skipreason.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: live: fmnosuchharness absent"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "a capability skip must still exit 0 from the runner"
  grep -q 'live: fmnosuchharness absent' "$tmp/err.txt" \
    || fail "the runner log must name what this host could not exercise: $(cat "$tmp/err.txt")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"] == "live: fmnosuchharness absent", record
' "$json" || { rm -rf "$tmp"; fail "the timing artifact must carry the skip reason"; }
  rm -rf "$tmp"
  pass "a gate skip records why it skipped"
}

test_a_run_that_ran_records_no_skip_reason() {
  local tmp ran_f json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ranreason.XXXXXX")
  ran_f="$tmp/ran.test.sh"
  json="$tmp/timing.json"
  cat >"$ran_f" <<'SH'
#!/usr/bin/env bash
echo "ok - ran"
exit 0
SH
  chmod +x "$ran_f"
  "$RUNNER" --json "$json" "$ran_f" >"$tmp/out.txt" 2>&1 \
    || fail "a passing fixture must exit 0 from the runner"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is False, record
assert record["gate_skip_reason"] == "", record
' "$json" || { rm -rf "$tmp"; fail "a script that ran must carry an empty skip reason"; }
  rm -rf "$tmp"
  pass "a script that actually ran records no skip reason"
}

test_live_guards_expect_a_capability_skip_class() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-liveclass.XXXXXX")
  out="$tmp/out.txt"
  # FM_LIVE=0 makes every live guard refuse without touching a harness, so this
  # exercises the real family through the real runner in bounded time.
  FM_LIVE=0 "$RUNNER" --json "$tmp/timing.json" \
    tests/fm-composer-matrix-live-e2e.test.sh >"$out" 2>"$tmp/err.txt" \
    || fail "a disabled live guard must not fail the runner: $(cat "$tmp/err.txt")"
  grep -q 'expected_gate_skip=live-capability' "$out" \
    || fail "the live-harness family must expect a capability skip: $(grep FM_TEST_BEGIN "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["expected_gate_skip"] == "live-capability", record
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"].startswith("live: "), record
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "the live guard record is wrong"; }
  rm -rf "$tmp"
  pass "live guards are recorded as a capability class, not a bare env opt-in"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    || fail "family real-herdr-gated must list focus-flash e2e"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    && fail "portable lanes must not include real-Herdr focus-flash e2e"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_hint_coverage_is_reported_and_bounded() {
  local out serial unhinted
  # Shards are packed from measured duration hints, so an unmeasured script is
  # placed on a guess. Enough of them and the partition still looks balanced by
  # script count while one shard carries far more real work than another and
  # reaches its CI job cap. The coverage guard therefore reports the unmeasured
  # share and refuses past its bound; assert that contract is live rather than
  # trusting the hint table to stay fresh on its own.
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "serial_unhinted=" "coverage guard must report the unmeasured serial share"
  serial=$(printf '%s\n' "$out" | sed -n 's/.*[^_]serial=\([0-9][0-9]*\).*/\1/p')
  unhinted=$(printf '%s\n' "$out" | sed -n 's/.*serial_unhinted=\([0-9][0-9]*\).*/\1/p')
  [ -n "$serial" ] && [ -n "$unhinted" ] \
    || fail "coverage summary must carry numeric serial counts: $out"
  [ "$serial" -gt 0 ] || fail "portable serial lane must be non-empty, got $serial"
  [ "$unhinted" -le "$serial" ] \
    || fail "unmeasured count $unhinted exceeds the serial lane size $serial"
  # 15% is the guard's own bound; staying well inside it is what keeps the
  # balance evidence-based. Refresh from a green run's timing artifacts when
  # this trips (docs/fm-test-portable-shards.md).
  [ "$((unhinted * 100))" -le "$((serial * 15))" ] \
    || fail "$unhinted of $serial portable serial scripts lack a measured hint; refresh them"
  pass "coverage guard reports and bounds the unmeasured portable serial share"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-afk-inject-e2e.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on a family with no recorded proof must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

# The complement of the refusal above: a family carrying a recorded concurrent
# proof is admitted and actually scheduled, so the admission rule is two-sided
# rather than a blanket refusal that happens to pass its negative cases.
test_jobs_admits_a_concurrent_safe_family() {
  local tmp rc external
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-admit.XXXXXX")
  # --list exits before the admission guard, so this has to be a real run for
  # the assertion to mean anything. Two cheap watcher-wake-lock scripts exercise
  # admission and the concurrent scheduler for real.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-supervision-events.test.sh tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--jobs on a proven family must be admitted, got $rc: $(cat "$tmp/err") $(cat "$tmp/out")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "the admitted concurrent run did not report both scripts green: $(cat "$tmp/out")"

  set +e
  "$RUNNER" --jobs 5 tests/fm-session-lock-ancestry.test.sh \
    >"$tmp/over-cap.out" 2>"$tmp/over-cap.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a family run above its proven four-worker cap must be refused, got $rc"

  external="$tmp/fm-session-lock-ancestry.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - colliding external fixture"\n' >"$external"
  chmod +x "$external"
  set +e
  "$RUNNER" --jobs 2 "$external" >"$tmp/external.out" 2>"$tmp/external.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an external script colliding with a proven family member must be refused, got $rc"
  rm -rf "$tmp"
  pass "--jobs admits and schedules a family with a recorded concurrent proof"
}

# The residual `standalone` family carries a concurrent proof, but the `*)`
# catch-all it was split out of must not: a test nobody has classified yet is
# exactly the one with no proof, so it has to stay serial rather than inherit
# concurrency from the family map's default arm.
test_unmapped_new_test_never_inherits_family_concurrency() {
  local tmp repo rc script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-unmapped.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  # Two members of the proven residual family, plus a test basename the family
  # map has never seen - the shape of any test added tomorrow.
  for script in fm-procevent.test.sh fm-quota-choose.test.sh fm-zz-unmapped-fixture.test.sh; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$script" >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-quota-choose.test.sh) \
    >"$tmp/family.out" 2>"$tmp/family.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "two members of the proven residual family must be admitted, got $rc: $(cat "$tmp/family.err")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/family.out" \
    || fail "the admitted residual-family run did not report both scripts green: $(cat "$tmp/family.out")"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/unmapped.out" 2>"$tmp/unmapped.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an unclassified new test must not be admitted under --jobs, got $rc: $(cat "$tmp/unmapped.out")"
  grep -Fq 'fm-zz-unmapped-fixture.test.sh' "$tmp/unmapped.err" \
    || fail "the refusal did not name the unclassified script: $(cat "$tmp/unmapped.err")"

  # It is only concurrency that is refused: the same script still runs serially.
  set +e
  (cd "$repo" && bin/fm-test-run.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/serial.out" 2>"$tmp/serial.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an unclassified test must still run serially, got $rc: $(cat "$tmp/serial.err")"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$tmp/serial.out" \
    || fail "the unmapped fixture did not land in the catch-all family: $(cat "$tmp/serial.out")"
  rm -rf "$tmp"
  pass "an unclassified new test stays serial while the proven residual family runs concurrently"
}

# Workers are handed scripts in order, so the slowest script must start first or
# it runs alone at the tail and throws away most of the concurrency.
test_concurrent_runs_are_ordered_longest_first() {
  local tmp listed first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-order.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --family watcher-wake-lock --list >"$tmp/serial" 2>&1
  set -e
  # The scheduler reorders the real run, so assert on the begin-marker order of
  # a real concurrent run over scripts whose hints differ by a wide margin.
  set +e
  "$RUNNER" --jobs 2 \
    tests/fm-session-lock-ancestry.test.sh tests/fm-task-inbox.test.sh \
    >"$tmp/out" 2>"$tmp/err"
  set -e
  first=$(grep -m1 '^FM_TEST_BEGIN' "$tmp/out" | awk '{print $3}')
  [ "$first" = tests/fm-task-inbox.test.sh ] \
    || fail "concurrent run did not start the longest script first, started: $first"
  rm -rf "$tmp"
  pass "a concurrent run starts the longest-hint script first"
}

# --max-wall-ms is checked after the run, so it cannot end a run that never
# finishes. A hung script has to become a bounded failure, because an unbounded
# suite is exactly what silently outruns its caller's invocation budget.
test_per_script_timeout_bounds_a_hang() {
  local tmp repo runner hang rc began ended grandchild_pid grandchild waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hang.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  grandchild_pid="$tmp/grandchild.pid"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture is about to hang"
sh -c 'trap "" TERM; echo $$ >"$1"; sleep 600' _ "$GRANDCHILD_PID" &
sleep 600
SH
  chmod +x "$runner" "$repo/$hang"

  began=$(date +%s)
  set +e
  GRANDCHILD_PID="$grandchild_pid" \
    "$runner" --per-script-timeout-secs 3 "$hang" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  ended=$(date +%s)

  [ "$rc" -ne 0 ] || fail "a terminated script must fail the run: $(cat "$tmp/out")"
  [ "$((ended - began))" -lt 120 ] \
    || fail "the per-script bound did not stop a 600s hang (took $((ended - began))s)"
  grep -Fq "FM_TEST_TIMEOUT script=$hang after=3s" "$tmp/out" \
    || fail "the timeout diagnostic was not emitted: $(cat "$tmp/out")"
  grep -Fq 'exceeded the per-script bound' "$tmp/out" \
    || fail "the terminated script was not named: $(cat "$tmp/out")"
  grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "a terminated script must be recorded as exit 124: $(cat "$tmp/out")"
  # The run still completes and accounts for the script, rather than dying.
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out" \
    || fail "the bounded run did not report a complete summary: $(cat "$tmp/out")"
  [ -s "$grandchild_pid" ] || fail "the hanging fixture did not record its grandchild"
  grandchild=$(cat "$grandchild_pid")
  waited=0
  while kill -0 "$grandchild" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$grandchild" 2>/dev/null; then
    kill -KILL "$grandchild" 2>/dev/null || true
    fail "the timed-out script left grandchild $grandchild running"
  fi

  # 0 keeps the historical unbounded behavior, so no existing caller changes.
  set +e
  "$runner" --per-script-timeout-secs nope "$hang" >"$tmp/o2" 2>"$tmp/e2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--per-script-timeout-secs with a non-number must be refused, got $rc"

  rm -rf "$tmp"
  pass "--per-script-timeout-secs turns a hung script into a bounded failure"
}

# The duration regression this guard exists for: a suite whose scripts are all
# green but whose wall clock outgrew its caller's invocation budget. The caller
# gets killed mid-run and retries invisibly, so an over-budget run has to be a
# failure, not a note in the log.
test_max_wall_ms_is_a_result_not_advice() {
  local tmp repo runner fast rc summary_duration budget_duration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fast=tests/fm-budget-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cat >"$repo/$fast" <<'SH'
#!/usr/bin/env bash
sleep 1
echo "ok - budget fixture"
SH
  chmod +x "$runner" "$repo/$fast"

  # Comfortably inside budget: the run passes and states the budget it met.
  set +e
  "$runner" --max-wall-ms 60000 "$fast" >"$tmp/under" 2>"$tmp/under.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a run inside its budget must pass, got $rc: $(cat "$tmp/under.err")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=60000 duration_ms=[0-9]+$' "$tmp/under" \
    || fail "an inside-budget run did not report the budget: $(cat "$tmp/under")"

  # Same green script, budget it cannot meet: the run must FAIL.
  set +e
  "$runner" --max-wall-ms 500 "$fast" >"$tmp/over" 2>"$tmp/over.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an over-budget run must fail through the result path, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SUMMARY_FAMILY .+$' "$tmp/over" \
    || fail "an over-budget run omitted its family summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SLOWEST rank=1 .+$' "$tmp/over" \
    || fail "an over-budget run omitted its slowest result: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=500 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its budget result: $(cat "$tmp/over")"
  summary_duration=$(awk '/^FM_TEST_SUMMARY / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  budget_duration=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  [ "$budget_duration" = "$summary_duration" ] \
    || fail "budget verdict used a different duration than the summary: $(cat "$tmp/over")"

  # A malformed budget is refused rather than silently ignored.
  set +e
  "$runner" --max-wall-ms 0 "$fast" >"$tmp/bad" 2>"$tmp/bad.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms 0 must be refused (exit 2), got $rc"
  set +e
  "$runner" --max-wall-ms nope "$fast" >"$tmp/bad2" 2>"$tmp/bad2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms with a non-number must be refused (exit 2), got $rc"

  rm -rf "$tmp"
  pass "--max-wall-ms fails an over-budget run and refuses a malformed budget"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  local json job_timeout step_timeout
  json=$(python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow:
    job = yaml.safe_load(workflow)["jobs"]["tests-herdr"]
step = next(
    step
    for step in job["steps"]
    if step.get("name") == "Run real-Herdr family (serial, required)"
)
print(json.dumps({
    "job_timeout": job["timeout-minutes"],
    "step_timeout": step["timeout-minutes"],
}))
PY
  ) \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
# Fields bin/fm-ci.sh renders into the Water 7 job summary. They are pinned here,
# at the owner that emits them, so renaming one fails this suite instead of
# silently emptying a published report.
assert [lane["selection"] for lane in doc["lanes"]]==[
    "lane=portable-parallel-1", "lane=portable-serial"], doc["lanes"]
assert [lane["summary"]["duration_ms"] for lane in doc["lanes"]]==[1000, 2000], doc["lanes"]
assert [(row["path"], row["duration_ms"]) for row in doc["slowest"]]==[
    ("tests/b.test.sh", 1500),
    ("tests/a.test.sh", 1000),
    ("tests/c.test.sh", 500),
], doc["slowest"]
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_task_marker_refuses_the_primary_checkout
test_changed_runner_surfaces_select_their_family
test_changed_large_mapped_set_is_bounded
test_changed_war_room_template_selects_contract_family
test_changed_dependency_graph_is_precise_and_explains_selection
test_changed_dependency_graph_covers_backend_closure_and_test_self
test_changed_dependency_selection_and_unmapped_failure
test_changed_bin_reference_selects_per_script_not_per_family
test_changed_uses_bounded_automatic_concurrency
test_windows_posix_mode_emulation_does_not_fail_parallel_runs
test_script_list_uses_bounded_automatic_concurrency
test_family_proofs_run_in_separate_concurrent_phases
test_empty_selection_emits_summary
test_timing_markers_and_json
test_unwritable_timing_artifact_keeps_the_suite_verdict
test_lane_selection_grammar_is_the_published_lane_label
test_pyyaml_vendor_is_offline_without_package_commands
test_aggregate_json_contains_an_unusable_input
test_aggregate_exit_behavior
test_serial_runner_sanitizes_firstmate_overrides
test_gate_skip_accounting_under_unsupported_inherited_locale
test_inherited_locale_replacement_keeps_utf8_text_semantics
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_hint_coverage_is_reported_and_bounded
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_admits_a_concurrent_safe_family
test_unmapped_new_test_never_inherits_family_concurrency
test_concurrent_runs_are_ordered_longest_first
test_per_script_timeout_bounds_a_hang
test_max_wall_ms_is_a_result_not_advice
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
test_gate_skip_reason_is_recorded
test_a_run_that_ran_records_no_skip_reason
test_live_guards_expect_a_capability_skip_class
