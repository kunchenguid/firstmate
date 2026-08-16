#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home, including guarded GitHub
# fork synchronization and inherited-config convergence ordering.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - github.com forks synchronize through gh before the local fetch; current
#     forks are harmless, while API/authentication failure and fork divergence
#     stop before any local or config convergence.
#   - Non-GitHub and local origins never invoke gh and retain direct origin
#     fast-forward behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"
CONFIG_PUSH_REAL="$ROOT/bin/fm-config-push.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  {
    printf 'config/crew-dispatch.json\nconfig/crew-harness\nconfig/backlog-backend\n'
    printf 'config/backend\nconfig/herdr-presentation-spaces\nconfig/startup-memory-budget\n'
  } > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

cat > "$w/config-push" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$*" = "--include-registered" ] \
  || { echo "config convergence omitted registered homes" >&2; exit 1; }
if [ -n "${FM_TEST_EXPECTED_HEAD:-}" ]; then
  [ "$(git -C "$FM_ROOT_OVERRIDE" rev-parse HEAD)" = "$FM_TEST_EXPECTED_HEAD" ] \
    || { echo "config convergence ran before firstmate update" >&2; exit 1; }
fi
if [ -n "${FM_TEST_SECOND_HOME:-}" ]; then
  [ "$(git -C "$FM_TEST_SECOND_HOME" rev-parse HEAD)" = "$FM_TEST_EXPECTED_HEAD" ] \
    || { echo "config convergence ran before secondmate update" >&2; exit 1; }
fi
if [ -n "${FM_TEST_ORDER_LOG:-}" ]; then
  printf 'config\n' >> "$FM_TEST_ORDER_LOG"
fi
if [ "${FM_TEST_CONFIG_FAIL:-0}" = 1 ]; then
  echo "configured convergence failure" >&2
  exit 1
fi
SH
  chmod +x "$w/config-push"

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_CONFIG_PUSH_OVERRIDE="$w/config-push" "$UPDATE"
}

configure_github_world() {
  local w=$1 origin_url=${2:-https://github.com/acme/firstmate-fork.git}
  git clone -q --bare "$w/origin.git" "$w/upstream.git"
  git clone -q "$w/upstream.git" "$w/upstream-seed"
  git -C "$w/main" remote set-url origin "$origin_url"
  git -C "$w/main" remote add upstream https://github.com/acme/firstmate.git
  git -C "$w/main" config \
    url."file://$w/origin.git".insteadOf "$origin_url"

  mkdir -p "$w/fake-bin"
  cat > "$w/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
sync_fork_from_upstream() {
  local upstream_ref=refs/fm-test/upstream
  git --git-dir="$FM_TEST_FORK_REPO" fetch -q "$FM_TEST_UPSTREAM_REPO" \
    "refs/heads/$FM_TEST_DEFAULT:$upstream_ref"
  if git --git-dir="$FM_TEST_FORK_REPO" merge-base --is-ancestor \
    "$upstream_ref" "refs/heads/$FM_TEST_DEFAULT"; then
    git --git-dir="$FM_TEST_FORK_REPO" update-ref -d "$upstream_ref"
    return 0
  fi
  git --git-dir="$FM_TEST_FORK_REPO" update-ref -d "$upstream_ref"
  git --git-dir="$FM_TEST_UPSTREAM_REPO" push -q "$FM_TEST_FORK_REPO" \
    "refs/heads/$FM_TEST_DEFAULT:refs/heads/$FM_TEST_DEFAULT"
}
case "${1:-} ${2:-}" in
  "repo view")
    case "${FM_TEST_GH_MODE:-fork}" in
      api-fail)
        echo "authentication required" >&2
        exit 1
        ;;
      direct) printf 'acme/firstmate-fork\tfalse\tmain\t\n' ;;
      fork-missing-parent*) printf 'acme/firstmate-fork\ttrue\tmain\t\n' ;;
      *) printf 'acme/firstmate-fork\ttrue\tmain\tacme/firstmate\n' ;;
    esac
    ;;
  "repo sync")
    if [ "${FM_TEST_GH_MODE:-fork}" = encoded-ref-404 ]; then
      echo "GET https://api.github.com/repos/acme/firstmate/git/refs/heads%2Fmain: HTTP 404: Not Found" >&2
      exit 1
    fi
    sync_fork_from_upstream
    ;;
  "api --method")
    [ "${3:-}" = POST ] && [ "${4:-}" = repos/acme/firstmate-fork/merge-upstream ] \
      || { echo "unexpected gh invocation: $*" >&2; exit 2; }
    case "${FM_TEST_GH_MODE:-fork}" in
      merge-upstream-api-fail)
        echo "upstream sync unavailable" >&2
        exit 1
        ;;
      merge-upstream-malformed)
        printf 'not-a-parent-branch\n'
        ;;
      merge-upstream-parent-mismatch)
        printf 'not-acme:main\n'
        ;;
      merge-upstream-branch-mismatch)
        printf 'acme:trunk\n'
        ;;
      merge-upstream-conflict)
        echo "merge conflict" >&2
        exit 1
        ;;
      *)
        sync_fork_from_upstream
        printf 'acme:main\n'
        ;;
    esac
    ;;
  "api repos/"*)
    case "${2:-}" in
      repos/acme/firstmate-fork)
        case "${FM_TEST_GH_MODE:-fork}" in
          fork-missing-parent) printf 'true\tacme/firstmate\tacme/firstmate\n' ;;
          fork-missing-parent-rest-missing-parent) printf 'true\t\t\n' ;;
          fork-missing-parent-rest-configured-mismatch) printf 'true\tacme/firstmate\tacme/firstmate\n' ;;
          fork-missing-parent-rest-not-fork) printf 'false\tacme/firstmate\tacme/firstmate\n' ;;
          fork-missing-parent-rest-distinct-source) printf 'true\tacme/firstmate\tacme/canonical-source\n' ;;
          fork-missing-parent-rest-self-parent) printf 'true\tACME/FIRSTMATE-FORK\tacme/canonical-source\n' ;;
          *)
            echo "unexpected repository metadata request: $*" >&2
            exit 2
            ;;
        esac
        ;;
      repos/acme/firstmate-fork/commits/main)
        git --git-dir="$FM_TEST_FORK_REPO" rev-parse "refs/heads/$FM_TEST_DEFAULT"
        ;;
      *)
        echo "unexpected gh invocation: $*" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$w/fake-bin/gh"
}

bump_upstream() {
  local w=$1 label=$2
  printf '%s\n' "$label" >> "$w/upstream-seed/AGENTS.md"
  git -C "$w/upstream-seed" add AGENTS.md
  git -C "$w/upstream-seed" commit -qm "$label"
  git -C "$w/upstream-seed" push -q origin main
}

run_github_update() {
  local w=$1
  PATH="$w/fake-bin:$PATH" \
    FM_TEST_GH_LOG="$w/gh.log" \
    FM_TEST_UPSTREAM_REPO="$w/upstream.git" \
    FM_TEST_FORK_REPO="$w/origin.git" \
    FM_TEST_DEFAULT=main \
    FM_ROOT_OVERRIDE="$w/main" \
    FM_HOME="$w/home" \
    FM_CONFIG_PUSH_OVERRIDE="$w/config-push" \
    "$UPDATE"
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

test_config_convergence_includes_registered_idle_home() {
  local w c1 out rc
  w=$(new_world config-idle)
  c1=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" worktree add -q --detach "$w/idle" "$c1"
  printf 'idle\n' > "$w/idle/.fm-secondmate-home"
  printf -- '- idle - registered idle home (home: %s/idle; scope: config; projects: p; added 2026-08-07)\n' \
    "$w" > "$w/home/data/secondmates.md"
  mkdir -p "$w/home/config"
  printf 'manual\n' > "$w/home/config/backlog-backend"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$CONFIG_PUSH_REAL" --include-registered 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "registered-idle config convergence failed: $out"
  assert_contains "$out" "config-push: $w/home -> registered secondmate homes" \
    "registered convergence mode was not reported"
  assert_contains "$out" "secondmate idle ($w/idle):" \
    "registered idle home was not discovered"
  [ "$(cat "$w/idle/config/backlog-backend")" = manual ] \
    || fail "registered idle home did not receive inherited config"
  assert_not_contains "$out" "config-reread: sent" \
    "registered idle home received a live reread nudge"
  pass "T8 inherited config converges for a registered idle home without a live nudge"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before rc
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "off-default firstmate update unexpectedly succeeded"
  assert_contains "$out" "update refused: firstmate checkout is on feature/wip, expected main" \
    "off-default firstmate refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before rc
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "detached firstmate update unexpectedly succeeded"
  assert_contains "$out" "update refused: firstmate checkout has detached HEAD, expected main" \
    "detached firstmate refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w" 2>&1)

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_not_contains "$out" "fm-bad" "unsafe home is not nudged"
  assert_contains "$out" "update refused: one or more registered secondmate homes could not fast-forward" \
    "unsafe home makes the overall update refuse"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_github_fork_ahead_sync_and_convergence_order() {
  local w out expected order rc
  w=$(new_world github-ahead)
  add_sm "$w" sm1
  configure_github_world "$w"
  bump_upstream "$w" upstream-ahead
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(FM_TEST_EXPECTED_HEAD="$expected" \
    FM_TEST_SECOND_HOME="$w/sm1" \
    FM_TEST_ORDER_LOG="$w/order.log" \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "GitHub fork-ahead update failed: $out"
  assert_contains "$out" "origin: github acme/firstmate-fork (fork)" "GitHub fork identified"
  assert_contains "$out" "upstream: github acme/firstmate" "GitHub parent identified"
  assert_contains "$out" "fork-sync: updated " \
    "GitHub fork synchronized"
  assert_contains "$out" "firstmate: updated " "local firstmate advanced after fork sync"
  assert_contains "$out" "secondmate sm1: updated " "secondmate advanced after firstmate"
  order=$(cat "$w/order.log")
  [ "$order" = config ] || fail "config convergence did not run exactly once after tracked updates"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "firstmate did not reach synchronized fork tip"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$expected" ] \
    || fail "secondmate did not reach synchronized fork tip"
  grep -q '^repo view ' "$w/gh.log" || fail "GitHub metadata inspection was not invoked"
  grep -q '^api --method POST repos/acme/firstmate-fork/merge-upstream -f branch=main --jq .base_branch$' "$w/gh.log" \
    || fail "guarded GitHub fork sync was not invoked"
  assert_not_contains "$(cat "$w/gh.log")" "api repos/acme/firstmate-fork --jq" \
    "GraphQL parent path unexpectedly requested REST metadata"
  pass "T12 GitHub fork sync precedes local, secondmate, and config convergence"
}

test_github_fork_sync_survives_cli_encoded_ref_fallback_refusal() {
  local w out expected gh_log rc
  w=$(new_world github-encoded-ref-fallback)
  configure_github_world "$w"
  bump_upstream "$w" encoded-ref-fallback
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=encoded-ref-404 run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "encoded-ref fallback made fork update refuse: $out"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "corrected fork sync did not advance the firstmate checkout"
  gh_log=$(cat "$w/gh.log")
  assert_contains "$gh_log" \
    "api --method POST repos/acme/firstmate-fork/merge-upstream -f branch=main --jq .base_branch" \
    "fork sync did not use the guarded merge-upstream endpoint"
  assert_not_contains "$gh_log" "repo sync" \
    "fork sync still invoked the CLI encoded-ref fallback"
  assert_not_contains "$gh_log" "git/refs" \
    "fork sync directly mutated a Git ref"
  assert_not_contains "$gh_log" "--force" \
    "fork sync used a forced update"
  pass "T35 fork sync avoids the CLI encoded-ref fallback while preserving fast-forward updates"
}

test_github_fork_merge_upstream_api_failure_refused() {
  local w out local_before fork_before rc
  w=$(new_world github-merge-upstream-api-failure)
  configure_github_world "$w"
  bump_upstream "$w" merge-upstream-api-failure
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=merge-upstream-api-fail run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "merge-upstream API failure unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync failed; unresolved downstream divergence requires a reviewed upstream-integration branch/PR before retry: upstream sync unavailable" \
    "merge-upstream API failure was not refused clearly"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after merge-upstream API failure"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "fork changed after merge-upstream API failure"
  [ ! -e "$w/order.log" ] || fail "config convergence ran after merge-upstream API failure"
  pass "T36 merge-upstream API failure refuses before local or fork mutation"
}

test_github_fork_merge_upstream_malformed_response_refused() {
  local w out local_before fork_before rc
  w=$(new_world github-merge-upstream-malformed)
  configure_github_world "$w"
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=merge-upstream-malformed run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "malformed merge-upstream response unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync returned malformed base branch: not-a-parent-branch" \
    "malformed merge-upstream response was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after malformed merge-upstream response"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "fork changed after malformed merge-upstream response"
  pass "T37 malformed merge-upstream response refuses before local or fork mutation"
}

test_github_fork_merge_upstream_response_disagreement_refused() {
  local w out local_before fork_before rc
  w=$(new_world github-merge-upstream-disagreement)
  configure_github_world "$w"
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=merge-upstream-parent-mismatch run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "merge-upstream parent disagreement unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync parent owner not-acme differs from GitHub parent owner acme" \
    "merge-upstream parent disagreement was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after merge-upstream parent disagreement"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "fork changed after merge-upstream parent disagreement"
  pass "T38 merge-upstream parent disagreement refuses before local or fork mutation"
}

test_github_fork_merge_upstream_branch_disagreement_refused() {
  local w out local_before fork_before rc
  w=$(new_world github-merge-upstream-branch-disagreement)
  configure_github_world "$w"
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=merge-upstream-branch-mismatch run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "merge-upstream branch disagreement unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync returned base branch trunk, expected main" \
    "merge-upstream branch disagreement was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after merge-upstream branch disagreement"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "fork changed after merge-upstream branch disagreement"
  pass "T40 merge-upstream branch disagreement refuses before local or fork mutation"
}

test_github_fork_merge_upstream_conflict_refused() {
  local w out local_before fork_before rc
  w=$(new_world github-merge-upstream-conflict)
  configure_github_world "$w"
  bump_upstream "$w" merge-upstream-conflict
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=merge-upstream-conflict run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "merge-upstream conflict unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync failed; unresolved downstream divergence requires a reviewed upstream-integration branch/PR before retry: merge conflict" \
    "merge-upstream conflict did not retain the guarded refusal"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after merge-upstream conflict"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "fork changed after merge-upstream conflict"
  pass "T39 merge-upstream conflict refuses before local or fork mutation"
}

test_github_fork_already_current() {
  local w out before rc
  w=$(new_world github-current)
  configure_github_world "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_ORDER_LOG="$w/order.log" run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "already-current GitHub fork update failed: $out"
  assert_contains "$out" "fork-sync: already current acme/firstmate-fork with acme/firstmate" \
    "already-current fork reported accurately"
  assert_contains "$out" "firstmate: already current" "already-current local checkout preserved"
  [ "$(cat "$w/order.log")" = config ] || fail "config convergence skipped for current fork"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "current checkout moved"
  pass "T13 already-current GitHub fork is an idempotent update"
}

test_github_fork_missing_graphql_parent_uses_rest_metadata() {
  local w out expected gh_log rc
  w=$(new_world github-missing-graphql-parent)
  configure_github_world "$w"
  bump_upstream "$w" graphql-parent-fallback
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=fork-missing-parent run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "GraphQL-missing-parent fork update failed: $out"
  assert_contains "$out" "upstream: github acme/firstmate" \
    "REST parent metadata was not accepted"
  assert_contains "$out" "fork-sync: updated " \
    "REST parent fallback did not synchronize the fork"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "REST parent fallback did not advance the local checkout"
  gh_log=$(cat "$w/gh.log")
  assert_contains "$gh_log" "api repos/acme/firstmate-fork" \
    "GraphQL-missing parent did not request authenticated REST metadata"
  pass "T28 GraphQL-missing fork parent falls back to authenticated REST metadata"
}

test_github_fork_missing_graphql_parent_rest_missing_parent_refused() {
  local w out before rc
  w=$(new_world github-rest-missing-parent)
  configure_github_world "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_GH_MODE=fork-missing-parent-rest-missing-parent \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "REST-missing-parent fork update unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub REST fork inspection did not identify a valid parent" \
    "missing REST parent was not refused clearly"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after missing REST parent"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" \
    "fork sync ran despite missing REST parent"
  pass "T29 GraphQL-missing fork parent refuses when REST has no valid parent"
}

test_github_rest_parent_keeps_configured_upstream_validation() {
  local w out before rc
  w=$(new_world github-rest-upstream-mismatch)
  configure_github_world "$w"
  git -C "$w/main" remote set-url upstream https://github.com/acme/not-the-parent.git
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_GH_MODE=fork-missing-parent-rest-configured-mismatch \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "REST parent bypassed configured upstream validation"
  assert_contains "$out" \
    "update refused: unsupported topology: configured upstream acme/not-the-parent differs from GitHub parent acme/firstmate" \
    "configured upstream mismatch was not refused after REST fallback"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after configured upstream mismatch via REST"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" \
    "fork sync ran despite configured upstream mismatch via REST"
  pass "T31 REST parent preserves configured-upstream identity validation"
}

test_github_fork_missing_graphql_parent_rest_not_fork_refused() {
  local w out before rc
  w=$(new_world github-rest-not-fork)
  configure_github_world "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_GH_MODE=fork-missing-parent-rest-not-fork \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "REST-not-fork update unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub REST fork inspection returned invalid fork state: false" \
    "GraphQL and REST fork-state disagreement was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after REST fork-state disagreement"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" \
    "fork sync ran despite REST fork-state disagreement"
  pass "T32 GraphQL fork and REST direct metadata disagreement refuses"
}

test_github_fork_missing_graphql_parent_rest_distinct_source_succeeds() {
  local w out expected rc
  w=$(new_world github-rest-distinct-source)
  configure_github_world "$w"
  bump_upstream "$w" nested-fork-parent
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(FM_TEST_GH_MODE=fork-missing-parent-rest-distinct-source \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "distinct REST source fork update failed: $out"
  assert_contains "$out" "upstream: github acme/firstmate" \
    "configured upstream was not matched to the REST immediate parent"
  assert_contains "$out" "fork-sync: updated " \
    "distinct REST source did not synchronize through the immediate parent"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "local checkout did not advance through the REST immediate parent"
  pass "T33 distinct valid REST source preserves nested-fork synchronization"
}

test_github_fork_missing_graphql_parent_rest_self_parent_refused() {
  local w out before rc
  w=$(new_world github-rest-self-parent)
  configure_github_world "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_GH_MODE=fork-missing-parent-rest-self-parent \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "REST self-parent update unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub REST fork inspection returned malformed self-parent identity" \
    "REST self-parent identity was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after REST self-parent identity"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" \
    "fork sync ran despite REST self-parent identity"
  pass "T34 REST self-parent identity is refused before fork sync"
}

test_downstream_fork_divergence_requires_reviewed_import() {
  local w out local_before fork_before rc
  w=$(new_world github-diverged)
  configure_github_world "$w"
  bump_upstream "$w" upstream-change
  printf 'fork divergence\n' >> "$w/seed/README.md"
  git -C "$w/seed" add README.md
  git -C "$w/seed" commit -qm fork-change
  git -C "$w/seed" push -q origin main
  local_before=$(git -C "$w/main" rev-parse HEAD)
  fork_before=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_ORDER_LOG="$w/order.log" run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "diverged GitHub fork update unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: GitHub fork sync failed; unresolved downstream divergence requires a reviewed upstream-integration branch/PR before retry" \
    "diverged downstream fork did not name its separate import path"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$local_before" ] \
    || fail "local checkout moved after fork divergence"
  [ "$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)" = "$fork_before" ] \
    || fail "diverged fork was changed"
  [ ! -e "$w/order.log" ] || fail "config convergence ran after fork divergence"
  pass "T14 downstream fork divergence refuses without mutation and names reviewed import"
}

test_help_owns_downstream_import_boundary() {
  local out rc
  out=$($UPDATE --help 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "fm-update --help failed: $out"
  assert_contains "$out" \
    "separate reviewed upstream-integration branch/PR" \
    "help omitted the downstream import boundary"
  assert_contains "$out" "This updater never creates," \
    "help omitted the updater's no-create boundary"
  pass "T26 help separates reviewed upstream integration from updatefirstmate"
}

test_reviewed_integration_restores_downstream_updates() {
  local w out expected rc
  w=$(new_world github-reviewed-integration)
  configure_github_world "$w"

  printf 'downstream updater policy\n' >> "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add .agents/skills/note.md
  git -C "$w/seed" commit -qm downstream-updater-feature
  git -C "$w/seed" push -q origin main
  bump_upstream "$w" canonical-updater-change

  git -C "$w/seed" remote add canonical "file://$w/upstream.git"
  git -C "$w/seed" fetch -q canonical main
  git -C "$w/seed" merge -q --no-edit canonical/main
  git -C "$w/seed" push -q origin main
  expected=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_EXPECTED_HEAD="$expected" \
    FM_TEST_ORDER_LOG="$w/order.log" run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "reviewed downstream integration update failed: $out"
  assert_contains "$out" \
    "fork-sync: already current acme/firstmate-fork with acme/firstmate" \
    "integrated downstream fork was not accepted as parent-compatible"
  assert_contains "$out" "firstmate: updated " \
    "local checkout did not fast-forward to reviewed integration"
  assert_contains "$out" "reread-firstmate: yes" \
    "downstream updater-skill feature did not trigger instruction reload"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "local checkout did not reach reviewed integration tip"
  grep -q '^downstream updater policy$' "$w/main/.agents/skills/note.md" \
    || fail "downstream updater-skill feature was lost during integration"
  [ "$(cat "$w/order.log")" = config ] \
    || fail "config convergence did not follow reviewed integration update"
  pass "T27 reviewed canonical integration preserves downstream updater features and restores updates"
}

test_github_api_failure_refused() {
  local w out before rc
  w=$(new_world github-api-fail)
  configure_github_world "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(FM_TEST_GH_MODE=api-fail FM_TEST_ORDER_LOG="$w/order.log" \
    run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "GitHub API failure unexpectedly succeeded"
  assert_contains "$out" "update refused: GitHub origin inspection failed: authentication required" \
    "GitHub authentication/API failure refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after GitHub API failure"
  [ ! -e "$w/order.log" ] || fail "config convergence ran after GitHub API failure"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" "fork sync not attempted after API failure"
  pass "T15 GitHub authentication/API failure stops before mutation"
}

test_non_github_origin_bypasses_gh() {
  local w out rc
  w=$(new_world non-github)
  bump_origin "$w" instr
  mkdir -p "$w/fake-bin"
  cat > "$w/fake-bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_GH_CALLED"
exit 97
SH
  chmod +x "$w/fake-bin/gh"

  out=$(PATH="$w/fake-bin:$PATH" FM_TEST_GH_CALLED="$w/gh.called" \
    run_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "non-GitHub direct update failed: $out"
  assert_contains "$out" "origin: non-GitHub local:" "non-GitHub origin identified"
  assert_contains "$out" "fork-sync: not applicable" "non-GitHub fork sync bypassed"
  assert_contains "$out" "firstmate: updated " "non-GitHub origin fast-forwarded directly"
  [ ! -e "$w/gh.called" ] || fail "non-GitHub origin invoked gh"
  pass "T16 non-GitHub origin retains direct fast-forward behavior"
}

test_stale_origin_tracking_is_refreshed_before_github_api() {
  local w out rc old
  w=$(new_world github-stale-origin)
  configure_github_world "$w"
  old=$(git -C "$w/main" rev-parse HEAD)
  printf 'landed local commit\n' >> "$w/main/README.md"
  git -C "$w/main" add README.md
  git -C "$w/main" commit -qm landed-local
  git -C "$w/main" push -q "file://$w/origin.git" main:main
  git -C "$w/main" update-ref refs/remotes/origin/main "$old"

  out=$(FM_TEST_GH_MODE=direct run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "fresh remote truth was not accepted: $out"
  assert_contains "$out" "origin: github acme/firstmate-fork (direct)" \
    "GitHub inspection did not run after origin refresh"
  [ "$(git -C "$w/main" rev-parse origin/main)" = "$(git -C "$w/main" rev-parse HEAD)" ] \
    || fail "preflight did not refresh stale origin/main"
  pass "T23 stale origin tracking is refreshed before GitHub mutation"
}

test_missing_origin_default_refused_before_github_api() {
  local w out rc
  w=$(new_world github-missing-origin)
  configure_github_world "$w"
  git --git-dir="$w/origin.git" update-ref -d refs/heads/main

  out=$(run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "missing origin/main unexpectedly succeeded"
  assert_contains "$out" "update refused: refreshed origin/main does not exist" \
    "missing refreshed origin/main was not refused"
  [ ! -e "$w/gh.log" ] || fail "GitHub API ran before missing origin/main refusal"
  pass "T24 missing origin/default is refused before GitHub mutation"
}

test_configured_upstream_must_match_github_parent() {
  local w out before rc
  w=$(new_world github-upstream-mismatch)
  configure_github_world "$w"
  git -C "$w/main" remote set-url upstream https://github.com/acme/not-the-parent.git
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "mismatched configured upstream unexpectedly succeeded"
  assert_contains "$out" \
    "update refused: unsupported topology: configured upstream acme/not-the-parent differs from GitHub parent acme/firstmate" \
    "configured upstream mismatch was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "local checkout moved after configured upstream mismatch"
  assert_not_contains "$(cat "$w/gh.log")" "merge-upstream" \
    "fork sync ran despite configured upstream mismatch"
  pass "T25 configured upstream must match the GitHub-reported parent"
}

test_direct_github_origin_bypasses_fork_sync() {
  local w out gh_log rc
  w=$(new_world github-direct)
  configure_github_world "$w"
  bump_origin "$w" instr

  out=$(FM_TEST_GH_MODE=direct run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "direct GitHub origin update failed: $out"
  assert_contains "$out" "origin: github acme/firstmate-fork (direct)" \
    "direct GitHub origin identified"
  assert_contains "$out" "fork-sync: not applicable" "direct GitHub origin skipped fork sync"
  assert_contains "$out" "firstmate: updated " "direct GitHub origin fast-forwarded normally"
  gh_log=$(cat "$w/gh.log")
  assert_contains "$gh_log" "repo view" "direct GitHub origin inspected"
  assert_not_contains "$gh_log" "merge-upstream" "direct GitHub origin did not invoke fork sync"
  pass "T17 direct GitHub origin retains ordinary fast-forward behavior"
}

test_mixed_case_github_host_uses_fork_sync() {
  local w out expected rc
  w=$(new_world github-mixed-case)
  configure_github_world "$w" https://GitHub.com/acme/firstmate-fork.git
  bump_upstream "$w" mixed-case-upstream
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "mixed-case GitHub host update failed: $out"
  assert_contains "$out" "origin: github acme/firstmate-fork (fork)" \
    "mixed-case github.com host classified as GitHub"
  assert_contains "$out" "fork-sync: updated " \
    "mixed-case github.com host used guarded fork sync"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "mixed-case GitHub checkout did not reach synchronized tip"
  pass "T21 GitHub hostname matching is case-insensitive"
}

test_credentialed_github_origin_uses_fork_sync() {
  local w out expected rc
  w=$(new_world github-credentialed)
  configure_github_world "$w" https://fixture:fixture@github.com/acme/firstmate-fork.git
  bump_upstream "$w" credentialed-upstream
  expected=$(git --git-dir="$w/upstream.git" rev-parse refs/heads/main)

  out=$(run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -eq 0 ] || fail "credentialed GitHub origin update failed: $out"
  assert_contains "$out" "origin: github acme/firstmate-fork (fork)" \
    "credentialed GitHub origin classified as GitHub"
  assert_contains "$out" "fork-sync: updated " \
    "credentialed GitHub origin used guarded fork sync"
  assert_not_contains "$out" "fixture:fixture" "origin credentials were not printed"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "credentialed GitHub checkout did not reach synchronized tip"
  pass "T22 credential-bearing GitHub HTTPS origins use guarded fork sync"
}

test_local_divergence_refused_before_remote_work() {
  local w out before rc
  w=$(new_world local-diverged)
  printf 'local work\n' >> "$w/main/README.md"
  git -C "$w/main" add README.md
  git -C "$w/main" commit -qm local-work
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "local-ahead update unexpectedly succeeded"
  assert_contains "$out" "update refused: local main has unlanded or divergent commits relative to origin/main" \
    "local unlanded commit refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "local commit was moved"
  pass "T18 local unlanded work is refused before remote mutation"
}

test_dirty_firstmate_refused_before_github_api() {
  local w out rc
  w=$(new_world github-dirty)
  configure_github_world "$w"
  printf 'dirty work\n' >> "$w/main/README.md"

  out=$(run_github_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "dirty firstmate update unexpectedly succeeded"
  assert_contains "$out" "update refused: firstmate checkout has a dirty working tree" \
    "dirty firstmate refused"
  [ ! -e "$w/gh.log" ] || fail "GitHub API was called before dirty-work refusal"
  pass "T19 dirty firstmate is refused before GitHub fork mutation"
}

test_config_convergence_failure_refused_after_fast_forward() {
  local w out expected rc
  w=$(new_world config-fail)
  bump_origin "$w" instr
  expected=$(git --git-dir="$w/origin.git" rev-parse refs/heads/main)

  out=$(FM_TEST_CONFIG_FAIL=1 run_update "$w" 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "config convergence failure unexpectedly succeeded"
  assert_contains "$out" "firstmate: updated " "tracked update completed before config convergence"
  assert_contains "$out" "update refused: inherited config convergence failed" \
    "config convergence failure refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] \
    || fail "safe tracked fast-forward was rolled back after config failure"
  pass "T20 config convergence failure is reported after safe tracked update"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_config_convergence_includes_registered_idle_home
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_github_fork_ahead_sync_and_convergence_order
test_github_fork_sync_survives_cli_encoded_ref_fallback_refusal
test_github_fork_merge_upstream_api_failure_refused
test_github_fork_merge_upstream_malformed_response_refused
test_github_fork_merge_upstream_response_disagreement_refused
test_github_fork_merge_upstream_branch_disagreement_refused
test_github_fork_merge_upstream_conflict_refused
test_github_fork_already_current
test_github_fork_missing_graphql_parent_uses_rest_metadata
test_github_fork_missing_graphql_parent_rest_missing_parent_refused
test_github_rest_parent_keeps_configured_upstream_validation
test_github_fork_missing_graphql_parent_rest_not_fork_refused
test_github_fork_missing_graphql_parent_rest_distinct_source_succeeds
test_github_fork_missing_graphql_parent_rest_self_parent_refused
test_downstream_fork_divergence_requires_reviewed_import
test_help_owns_downstream_import_boundary
test_reviewed_integration_restores_downstream_updates
test_github_api_failure_refused
test_non_github_origin_bypasses_gh
test_stale_origin_tracking_is_refreshed_before_github_api
test_missing_origin_default_refused_before_github_api
test_configured_upstream_must_match_github_parent
test_direct_github_origin_bypasses_fork_sync
test_mixed_case_github_host_uses_fork_sync
test_credentialed_github_origin_uses_fork_sync
test_local_divergence_refused_before_remote_work
test_dirty_firstmate_refused_before_github_api
test_config_convergence_failure_refused_after_fast_forward

echo "# all fm-update tests passed"
