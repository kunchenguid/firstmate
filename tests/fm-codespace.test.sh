#!/usr/bin/env bash
# Behavior tests for the codespace delivery mode adapter.
#
# Covers:
#   (a) fm-project-mode.sh parses [codespace]                  -> "codespace off"
#   (b) fm-project-mode.sh parses [codespace +yolo]            -> "codespace on"
#   (c) fm-project-mode.sh --slug parses [codespace owner/repo]-> "owner/repo"
#   (d) fm-project-mode.sh --slug exits non-zero with no slug
#   (e) fm-spawn.sh generates check.sh for codespace tasks
#   (f) fm-spawn.sh records codespace name + leased remote_worktree in meta
#   (g) fm-spawn.sh records kind=scout for a codespace scout
#   (h) fm-spawn.sh errors when no Available codespace found
#   (i) fm-spawn.sh errors when >1 Available codespaces found
#   (j) fm-spawn.sh errors when the registry line carries no owner/repo slug
#   (k) fm-brief.sh writes a codespace scout brief (remote report + status, no push)
#   (l) fm-teardown.sh copies a scout report back over SSH, then succeeds
#   (m) fm-teardown.sh refuses a scout teardown when no report exists anywhere
#   (n) fm-teardown.sh refuses a ship teardown when the codespace worktree is dirty
#   (o) fm-teardown.sh stops with state intact when treehouse return fails
#   (p) fm-teardown.sh releases the lease and removes state on success
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE_SCRIPT="$ROOT/bin/fm-project-mode.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codespace-tests.XXXXXX")

# Build a minimal registry file with one project entry and a given mode string.
make_registry() {
  local dir=$1 proj=$2 mode_str=$3
  mkdir -p "$dir"
  printf -- '- %s [%s] - test project (added 2026-06-22)\n' "$proj" "$mode_str" > "$dir/projects.md"
}

# Run fm-project-mode.sh with a temporary registry.
run_mode() {
  local dir=$1; shift
  FM_DATA_OVERRIDE="$dir" "$MODE_SCRIPT" "$@" 2>/dev/null
}

# ── (a) [codespace] parses to "codespace off" ──────────────────────────────

test_codespace_mode_parses() {
  local reg_dir
  reg_dir="$TMP_ROOT/reg-codespace"
  make_registry "$reg_dir" myproj "codespace owner/myproj"

  local out
  out=$(run_mode "$reg_dir" myproj)
  [ "$out" = "codespace off" ] || fail "codespace mode: expected 'codespace off', got '$out'"
  pass "[codespace owner/repo] parses to 'codespace off'"
}

# ── (b) [codespace +yolo] parses to "codespace on" ─────────────────────────

test_codespace_yolo_parses() {
  local reg_dir
  reg_dir="$TMP_ROOT/reg-codespace-yolo"
  make_registry "$reg_dir" myproj "codespace owner/myproj +yolo"

  local out
  out=$(run_mode "$reg_dir" myproj)
  [ "$out" = "codespace on" ] || fail "codespace+yolo mode: expected 'codespace on', got '$out'"
  pass "[codespace owner/repo +yolo] parses to 'codespace on'"
}

# ── (c) --slug parses owner/repo ───────────────────────────────────────────

test_slug_parses() {
  local reg_dir out
  reg_dir="$TMP_ROOT/reg-slug"
  make_registry "$reg_dir" myproj "codespace acme/widget"
  out=$(run_mode "$reg_dir" --slug myproj)
  [ "$out" = "acme/widget" ] || fail "slug: expected 'acme/widget', got '$out'"
  pass "--slug parses owner/repo from [codespace owner/repo]"
}

# ── (d) --slug exits non-zero when no slug present ──────────────────────────

test_slug_absent_errors() {
  local reg_dir rc
  reg_dir="$TMP_ROOT/reg-slug-absent"
  make_registry "$reg_dir" myproj "codespace"
  set +e
  FM_DATA_OVERRIDE="$reg_dir" "$MODE_SCRIPT" --slug myproj >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "slug-absent: expected non-zero exit when no owner/repo present"
  pass "--slug exits non-zero when the line carries no owner/repo"
}

# ── Helpers for spawn tests ─────────────────────────────────────────────────

# Create a sandbox for a spawn test. Sets up:
#   $dir/state/            - firstmate state dir (with a fresh watcher beacon)
#   $dir/data/<id>/        - brief directory
#   $dir/fakebin/          - mocked gh, tmux, treehouse
#   $dir/mock-data/        - mock control files
#   $dir/data/projects.md  - registry (codespace mode, optional slug)
# No local clone is created: codespace mode must not require one.
# Echoes the sandbox dir.
make_spawn_case() {
  local name=$1 cs_name=${2:-my-codespace} cs_count=${3:-1} slug=${4-owner/myproj}
  local dir fakebin
  dir="$TMP_ROOT/spawn-$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/data/task-cs1" "$dir/mock-data"

  # Fake watcher beacon so fm-guard stays quiet.
  touch "$dir/state/.last-watcher-beat"

  # Registry with codespace mode (carrying owner/repo) and a brief. No clone.
  if [ -n "$slug" ]; then
    printf -- '- myproj [codespace %s] - test project (added 2026-06-22)\n' "$slug" > "$dir/data/projects.md"
  else
    printf -- '- myproj [codespace] - test project (added 2026-06-22)\n' > "$dir/data/projects.md"
  fi
  printf 'You are a crewmate.\n' > "$dir/data/task-cs1/brief.md"

  # Mock tmux: silently accept all subcommands.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'testsession\n' ;;
  list-windows) printf '\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"

  # Mock gh: codespace list, cp, ssh (shell-ready, lease, return).
  local cs_list_output
  if [ "$cs_count" = "0" ]; then
    cs_list_output=""
  elif [ "$cs_count" = "1" ]; then
    cs_list_output="$cs_name"
  else
    cs_list_output="$(printf '%s\n%s\n' "$cs_name" "${cs_name}-extra")"
  fi
  printf '%s\n' "$cs_list_output" > "$dir/mock-data/cs-list-out"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "list" ]; then
  cat "$dir/mock-data/cs-list-out"
  exit 0
fi
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "cp" ]; then
  exit 0
fi
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "ssh" ]; then
  case "\$*" in
    *"treehouse get --lease"*) echo "/workspaces/myproj-wt/fm-task-cs1"; exit 0 ;;
    *"treehouse return"*) exit 0 ;;
    *) exit 0 ;;   # shell-ready ("-- true") and the interactive launch
  esac
fi
exit 0
SH
  chmod +x "$fakebin/gh"

  # Mock treehouse (not used in codespace path, present for safety).
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"

  printf '%s\n' "$dir"
}

# Run fm-spawn.sh in a sandboxed environment.
run_spawn() {
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_PROJECTS_OVERRIDE="$dir/projects" \
  FM_SPAWN_NO_GUARD=1 \
  TMUX=1 \
  PATH="$dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# ── (e) check.sh generated for codespace tasks ─────────────────────────────

test_check_sh_generated() {
  local dir rc out
  dir=$(make_spawn_case "check-gen" "my-codespace" "1")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "check-gen: spawn should succeed (got exit $rc)\noutput: $out"
  [ -f "$dir/state/task-cs1.check.sh" ] || fail "check-gen: state/task-cs1.check.sh not generated"
  grep -q 'gh codespace ssh' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing 'gh codespace ssh'"
  grep -q 'my-codespace' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing codespace name"
  grep -q 'firstmate-state' "$dir/state/task-cs1.check.sh" \
    || fail "check-gen: check.sh missing remote state path"
  pass "check.sh generated with codespace polling logic"
}

# ── (f) meta records codespace + leased remote_worktree ────────────────────

test_meta_records_lease() {
  local dir rc out meta
  dir=$(make_spawn_case "meta-lease" "my-codespace" "1")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "meta-lease: spawn should succeed (got exit $rc)\noutput: $out"
  meta="$dir/state/task-cs1.meta"
  [ -f "$meta" ] || fail "meta-lease: meta not written"
  grep -q '^codespace=my-codespace$' "$meta" || fail "meta-lease: meta missing codespace name"
  grep -q '^remote_worktree=/workspaces/myproj-wt/fm-task-cs1$' "$meta" \
    || fail "meta-lease: meta missing leased remote_worktree path"
  grep -q '^remote_state=' "$meta" || fail "meta-lease: meta missing remote_state"
  grep -q '^mode=codespace$' "$meta" || fail "meta-lease: meta missing mode=codespace"
  pass "spawn records codespace name + leased remote_worktree in meta"
}

# ── (g) codespace scout records kind=scout ─────────────────────────────────

test_scout_spawn_kind() {
  local dir rc out meta
  dir=$(make_spawn_case "scout-kind" "my-codespace" "1")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj --scout 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "scout-kind: spawn should succeed (got exit $rc)\noutput: $out"
  meta="$dir/state/task-cs1.meta"
  grep -q '^kind=scout$' "$meta" || fail "scout-kind: meta missing kind=scout"
  grep -q '^remote_worktree=' "$meta" || fail "scout-kind: scout meta missing remote_worktree"
  pass "codespace scout spawn records kind=scout with a leased worktree"
}

# ── (h) error when no Available codespace found ────────────────────────────

test_no_codespace_errors() {
  local dir rc out
  dir=$(make_spawn_case "no-cs" "" "0")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "no-cs: spawn should fail when no codespace found"
  printf '%s\n' "$out" | grep -qi 'no Available codespace' \
    || fail "no-cs: error message missing 'no Available codespace'"
  pass "spawn errors when no Available codespace found"
}

# ── (i) error when >1 Available codespaces found ───────────────────────────

test_multiple_codespaces_errors() {
  local dir rc out
  dir=$(make_spawn_case "multi-cs" "cs-one" "2")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "multi-cs: spawn should fail when >1 codespaces found"
  printf '%s\n' "$out" | grep -qiE 'Available codespaces.*expected exactly one|expected exactly one' \
    || fail "multi-cs: error message missing expected-exactly-one wording"
  pass "spawn errors when more than one Available codespace found"
}

# ── (j) error when the registry line has no owner/repo slug ─────────────────

test_no_slug_errors() {
  local dir rc out
  dir=$(make_spawn_case "no-slug" "my-codespace" "1" "")

  set +e
  out=$(run_spawn "$dir" task-cs1 projects/myproj 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "no-slug: spawn should fail when registry has no owner/repo"
  printf '%s\n' "$out" | grep -qi 'owner/repo' \
    || fail "no-slug: error message missing owner/repo guidance"
  pass "spawn errors when the registry line carries no owner/repo slug"
}

# ── (k) fm-brief.sh writes a codespace scout brief ─────────────────────────

test_codespace_scout_brief() {
  local dir brief out
  dir="$TMP_ROOT/brief-scout"
  mkdir -p "$dir/data"
  printf -- '- myproj [codespace owner/myproj] - test project (added 2026-06-22)\n' > "$dir/data/projects.md"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    FM_STATE_OVERRIDE="$dir/state" "$BRIEF" scout-cs1 myproj --scout 2>&1)
  set -e

  brief="$dir/data/scout-cs1/brief.md"
  [ -f "$brief" ] || fail "scout-brief: brief not generated ($out)"
  grep -q 'firstmate-state/scout-cs1-report.md' "$brief" \
    || fail "scout-brief: report not directed to the remote firstmate-state path"
  grep -q 'firstmate-state/scout-cs1.status' "$brief" \
    || fail "scout-brief: status not directed to the remote firstmate-state path"
  grep -qi 'Never push' "$brief" || fail "scout-brief: missing never-push rule"
  pass "fm-brief.sh writes a codespace scout brief (remote report + status, no push)"
}

# ── Helpers for teardown tests ──────────────────────────────────────────────

# Create a teardown sandbox: a meta for a codespace task plus mocked gh/tmux.
# Mock gh behaviour is steered by control files under mock-data/:
#   dirty       -> contents returned by `git status --porcelain`
#   unpushed    -> contents returned by `git log ... --not --remotes`
#   report      -> contents returned by `cat <remote>/<id>-report.md` (empty = absent)
#   return-fail -> if present, `treehouse return` exits non-zero
#   check-fail  -> if present, the git status/log checks exit non-zero (check could not run)
# Echoes the sandbox dir.
make_teardown_case() {
  local name=$1 kind=$2 id=${3:-task-cs1}
  local dir fakebin
  dir="$TMP_ROOT/td-$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/data/$id" "$dir/mock-data"
  touch "$dir/state/.last-watcher-beat"

  cat > "$dir/state/$id.meta" <<META
window=testsession:fm-$id
worktree=
project=
harness=claude
kind=$kind
mode=codespace
yolo=off
codespace=my-codespace
remote_worktree=/workspaces/myproj-wt/fm-$id
remote_state=~/firstmate-state
META

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
md="$dir/mock-data"
if [ "\${1:-}" = "codespace" ] && [ "\${2:-}" = "ssh" ]; then
  case "\$*" in
    *"status --porcelain"*) [ -f "\$md/check-fail" ] && exit 1; cat "\$md/dirty" 2>/dev/null; exit 0 ;;
    *"--not --remotes"*) [ -f "\$md/check-fail" ] && exit 1; cat "\$md/unpushed" 2>/dev/null; exit 0 ;;
    *-report.md*)
      if [ -s "\$md/report" ]; then cat "\$md/report"; exit 0; else exit 1; fi ;;
    *"treehouse return"*)
      if [ -f "\$md/return-fail" ]; then exit 1; else exit 0; fi ;;
    *) exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/gh"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"

  printf '%s\n' "$dir"
}

run_teardown() {
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_DATA_OVERRIDE="$dir/data" \
  FM_PROJECTS_OVERRIDE="$dir/projects" \
  PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

# ── (l) scout teardown copies the report back, then succeeds ────────────────

test_scout_report_copyback() {
  local dir rc out
  dir=$(make_teardown_case "scout-copyback" scout)
  printf '# Findings\nall good\n' > "$dir/mock-data/report"   # report exists remotely

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "scout-copyback: teardown should succeed (got $rc)\n$out"
  [ -f "$dir/data/task-cs1/report.md" ] || fail "scout-copyback: report not copied back locally"
  grep -q 'all good' "$dir/data/task-cs1/report.md" || fail "scout-copyback: copied report content wrong"
  [ ! -f "$dir/state/task-cs1.meta" ] || fail "scout-copyback: meta should be removed on success"
  pass "scout teardown copies the report back over SSH, then succeeds"
}

# ── (m) scout teardown refuses when no report exists anywhere ───────────────

test_scout_no_report_refuses() {
  local dir rc out
  dir=$(make_teardown_case "scout-noreport" scout)
  : > "$dir/mock-data/report"   # empty = report absent remotely

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "scout-noreport: teardown should refuse without a report"
  printf '%s\n' "$out" | grep -qi 'no report' || fail "scout-noreport: missing refusal message"
  [ -f "$dir/state/task-cs1.meta" ] || fail "scout-noreport: meta should remain on refusal"
  pass "scout teardown refuses when no report exists anywhere"
}

# ── (n) ship teardown refuses when the codespace worktree is dirty ──────────

test_ship_dirty_refuses() {
  local dir rc out
  dir=$(make_teardown_case "ship-dirty" ship)
  printf ' M file.txt\n' > "$dir/mock-data/dirty"

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "ship-dirty: teardown should refuse dirty codespace worktree"
  printf '%s\n' "$out" | grep -qi 'not on any remote' || fail "ship-dirty: missing refusal message"
  [ -f "$dir/state/task-cs1.meta" ] || fail "ship-dirty: meta should remain on refusal"
  pass "ship teardown refuses when the codespace worktree is dirty"
}

# ── (n2) ship teardown refuses when the unpushed-work check cannot run ──────

test_ship_check_failure_refuses() {
  local dir rc out
  dir=$(make_teardown_case "ship-checkfail" ship)
  touch "$dir/mock-data/check-fail"   # SSH/git check exits non-zero (could not run)

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "ship-checkfail: teardown should refuse when the check cannot run"
  printf '%s\n' "$out" | grep -qi 'could not verify' || fail "ship-checkfail: missing refusal message"
  [ -f "$dir/state/task-cs1.meta" ] || fail "ship-checkfail: meta should remain on refusal (lease still held)"
  pass "ship teardown refuses when the unpushed-work check cannot run"
}

# ── (o) teardown stops with state intact when treehouse return fails ────────

test_return_failure_stops() {
  local dir rc out
  dir=$(make_teardown_case "return-fail" ship)
  touch "$dir/mock-data/return-fail"   # clean worktree, but return fails

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "return-fail: teardown should stop when treehouse return fails"
  printf '%s\n' "$out" | grep -qi 'treehouse return failed' || fail "return-fail: missing error message"
  [ -f "$dir/state/task-cs1.meta" ] || fail "return-fail: meta must stay intact (lease still held)"
  pass "teardown stops with state intact when treehouse return fails"
}

# ── (p) teardown releases the lease and removes state on success ────────────

test_clean_teardown_succeeds() {
  local dir rc out
  dir=$(make_teardown_case "clean" ship)   # clean worktree, return succeeds

  set +e
  out=$(run_teardown "$dir" task-cs1 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "clean: teardown should succeed (got $rc)\n$out"
  [ ! -f "$dir/state/task-cs1.meta" ] || fail "clean: meta should be removed on success"
  [ ! -f "$dir/state/task-cs1.check.sh" ] || fail "clean: check.sh should be removed on success"
  pass "ship teardown releases the lease and removes state on success"
}

test_codespace_mode_parses
test_codespace_yolo_parses
test_slug_parses
test_slug_absent_errors
test_check_sh_generated
test_meta_records_lease
test_scout_spawn_kind
test_no_codespace_errors
test_multiple_codespaces_errors
test_no_slug_errors
test_codespace_scout_brief
test_scout_report_copyback
test_scout_no_report_refuses
test_ship_dirty_refuses
test_ship_check_failure_refuses
test_return_failure_stops
test_clean_teardown_succeeds
