#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

# Assert that <claude> is a real duplicate of <agents>: <agents>'s exact
# content as a strict line prefix, plus exactly one trailing marker line.
# Checks the generated file's actual shape rather than the script's own
# marker literal, so it stays valid if that wording ever changes.
assert_synced_duplicate() {
  local agents=$1 claude=$2 msg=$3 agents_lines
  agents_lines=$(wc -l < "$agents")
  head -n "$agents_lines" "$claude" | cmp -s - "$agents" \
    || fail "$msg (CLAUDE.md's leading content diverges from AGENTS.md)"
  [ "$(wc -l < "$claude")" -eq "$((agents_lines + 1))" ] \
    || fail "$msg (expected exactly one trailing marker line)"
  assert_grep "fm-ensure-agents-md" "$claude" "$msg (missing sync marker)"
}

test_created_agents_md_includes_self_governance() {
  local repo agents
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md symlink was not created"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink"
  assert_grep "## Maintaining this file" "$agents" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$agents" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$agents" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$agents" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: created AGENTS.md includes self-governance section"
}

test_promoted_claude_md_stays_real_not_symlink() {
  # Requirement: a repo that already has a real, regular CLAUDE.md must
  # never be converted into a symlink arrangement by this helper (the
  # site-feasibility regression). Promotion must copy, not move+symlink,
  # and the result must stay idempotent on a re-run.
  local repo agents out count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) || fail "fm-ensure-agents-md.sh failed for CLAUDE.md promotion"
  assert_contains "$out" "promoted:" "promotion did not report a promoted: line"
  assert_contains "$out" "managed mirror" "promoted: line did not explain CLAUDE.md is now a managed mirror"
  assert_contains "$out" "edit AGENTS.md" "promoted: line did not point future edits at AGENTS.md"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created during promotion"
  [ ! -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md was converted into a symlink during promotion"
  [ -f "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a real file after promotion"
  assert_grep "Run tests with \`make test\`." "$agents" \
    "promotion lost existing CLAUDE.md content"
  assert_grep "Run tests with \`make test\`." "$repo/CLAUDE.md" \
    "promotion lost CLAUDE.md's own original content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "promotion wrote $count self-governance sections"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "promoted AGENTS.md missing self-governance wording"
  assert_synced_duplicate "$agents" "$repo/CLAUDE.md" "promoted AGENTS.md and CLAUDE.md are not kept in sync"
  # Re-run must stay idempotent: still no symlink, reported unchanged.
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run after promotion"
  assert_contains "$out" "unchanged:" "idempotent re-run after promotion did not report unchanged"
  [ ! -L "$repo/CLAUDE.md" ] || fail "idempotent re-run turned CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: promoted CLAUDE.md stays a real file, never a symlink, and is idempotent"
}

test_promoted_claude_md_without_trailing_newline_keeps_blank_separator() {
  local repo agents before
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_grep "Run tests with make test." "$agents" \
    "newline-less promotion lost or mangled the last content line"
  assert_grep "## Maintaining this file" "$agents" \
    "newline-less promotion did not append the self-governance section"
  before=$(grep -B1 -Fx '## Maintaining this file' "$agents" | head -n 1)
  [ -z "$before" ] || fail "self-governance heading not preceded by a blank line (got: $before)"
  [ ! -L "$repo/CLAUDE.md" ] || fail "newline-less promotion converted CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: newline-less promotion keeps a blank separator line"
}

test_promotion_of_marked_claude_md_strips_the_marker_from_agents_md() {
  # A marked CLAUDE.md can reach the promotion path when AGENTS.md vanishes
  # out of band (stray deletion, partial checkout, reverted commit) while its
  # mirror survives. Promotion must not copy this helper's own marker line
  # into AGENTS.md - that file is what every agent session reads - and must
  # still leave CLAUDE.md a normal marked duplicate carrying exactly one.
  local repo agents claude out count
  repo="$TMP_ROOT/orphaned-marked-mirror-project"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  printf '# Existing agent memory\n\nRun tests with make test.\n' > "$agents"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed creating the initial marked duplicate"
  [ ! -L "$claude" ] || fail "expected a real duplicate, not a symlink, on a core.symlinks=false repo"
  assert_grep "fm-ensure-agents-md" "$claude" "initial duplicate is missing its sync marker"
  rm -f "$agents"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed promoting an orphaned marked CLAUDE.md"
  assert_contains "$out" "promoted:" "orphaned marked mirror was not promoted"
  assert_present "$agents" "promotion did not recreate AGENTS.md"
  grep -Fq "fm-ensure-agents-md" "$agents" \
    && fail "promotion copied the sync marker into AGENTS.md"
  assert_grep "Run tests with make test." "$agents" "promotion lost the original memory content"
  count=$(grep -Fc "fm-ensure-agents-md" "$claude")
  [ "$count" -eq 1 ] || fail "promoted CLAUDE.md carries $count sync markers"
  assert_synced_duplicate "$agents" "$claude" "promoted orphaned mirror is not a synced duplicate"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on the re-run after orphan promotion"
  assert_contains "$out" "unchanged:" "re-run after orphan promotion did not report unchanged"
  pass "fm-ensure-agents-md.sh: promoting an orphaned marked mirror leaves AGENTS.md marker-free"
}

test_existing_agents_md_with_symlink_gains_self_governance() {
  local repo agents out count
  repo="$TMP_ROOT/existing-symlinked-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md with symlink"
  assert_contains "$out" "updated:" "injection into existing AGENTS.md did not report an update"
  assert_grep "Build with make." "$agents" "injection dropped existing AGENTS.md content"
  assert_grep "## Maintaining this file" "$agents" "existing AGENTS.md did not gain the self-governance section"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a symlink after injection"
  # Re-run must be a byte-exact no-op reporting unchanged.
  cp "$agents" "$repo/.after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run"
  assert_contains "$out" "unchanged:" "idempotent re-run did not report unchanged"
  diff "$repo/.after-first" "$agents" >/dev/null \
    || fail "idempotent re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: existing symlinked AGENTS.md gains the section idempotently"
}

test_existing_agents_md_without_claude_gains_section_and_symlink() {
  local repo agents out count
  repo="$TMP_ROOT/existing-bare-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md without CLAUDE.md"
  assert_contains "$out" "updated:" "injection without CLAUDE.md did not report an update"
  [ -L "$repo/CLAUDE.md" ] || fail "CLAUDE.md symlink was not created"
  assert_grep "Deploy with kubectl." "$agents" "injection dropped existing AGENTS.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  pass "fm-ensure-agents-md.sh: existing AGENTS.md without CLAUDE.md gains section and symlink"
}

test_existing_agents_md_with_section_reports_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/fully-formed-project"
  mkdir -p "$repo"
  # Build a fully-formed project (AGENTS.md with the section + correct symlink).
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the fully-formed fixture"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on already-formed project"
  assert_contains "$out" "unchanged:" "already-formed project was not reported unchanged"
  diff "$repo/.before" "$agents" >/dev/null \
    || fail "already-formed AGENTS.md was modified"
  pass "fm-ensure-agents-md.sh: AGENTS.md that already has the section stays unchanged"
}

test_existing_crlf_agents_md_with_section_stays_unchanged() {
  local repo agents out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF AGENTS.md with the section"
  assert_contains "$out" "unchanged:" "complete CRLF AGENTS.md was not reported unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "complete CRLF AGENTS.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$agents")
  [ "$count" -eq 1 ] || fail "complete CRLF AGENTS.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md with the section stays unchanged"
}

test_existing_crlf_agents_md_without_section_preserves_crlf() {
  local repo agents out
  repo="$TMP_ROOT/crlf-injected-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed injecting into CRLF AGENTS.md"
  assert_contains "$out" "updated:" "CRLF AGENTS.md injection did not report an update"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/.expected"
  cmp -s "$repo/.expected" "$agents" \
    || fail "CRLF AGENTS.md injection did not preserve CRLF line endings"
  cp "$agents" "$repo/.after-first"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed on idempotent CRLF re-run"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "idempotent CRLF re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: CRLF injection preserves line endings idempotently"
}

test_windows_style_repo_promotion_never_symlinks_claude_md() {
  # The concrete site-feasibility regression: a repo checked out where git
  # will not materialize symlinks (core.symlinks=false, as git records on a
  # native Windows checkout) already has a real CLAUDE.md. Running the
  # helper must not reproduce the reverted bug by turning it into a symlink.
  local repo agents out
  repo="$TMP_ROOT/site-feasibility-shaped"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  cat > "$repo/CLAUDE.md" <<'EOF'
# site-feasibility agent memory

Build with the Windows toolchain.
EOF
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for the site-feasibility-shaped repo"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created for the site-feasibility-shaped repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  [ -f "$repo/CLAUDE.md" ] || fail "CLAUDE.md is no longer a real file"
  assert_grep "Build with the Windows toolchain." "$repo/CLAUDE.md" \
    "original CLAUDE.md content was lost"
  assert_grep "Build with the Windows toolchain." "$agents" \
    "promoted AGENTS.md missing the original CLAUDE.md content"
  pass "fm-ensure-agents-md.sh: never symlinks CLAUDE.md on a core.symlinks=false (Windows-shaped) repo"
}

test_symlinks_unreliable_creates_real_synced_claude_md() {
  # No CLAUDE.md yet, but this repo's git will not materialize symlinks:
  # the helper must still succeed and produce a usable, real CLAUDE.md
  # instead of a symlink that would dangle as a text stub on checkout.
  local repo agents out
  repo="$TMP_ROOT/unsafe-symlink-fresh"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a core.symlinks=false repo"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created for a core.symlinks=false repo"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md was not created for a core.symlinks=false repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  assert_synced_duplicate "$agents" "$repo/CLAUDE.md" "real CLAUDE.md is not kept in sync with AGENTS.md"
  assert_grep "## Maintaining this file" "$repo/CLAUDE.md" \
    "real CLAUDE.md missing the self-governance section"
  # Re-run must stay idempotent.
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run for a core.symlinks=false repo"
  assert_contains "$out" "unchanged:" "idempotent re-run on a core.symlinks=false repo did not report unchanged"
  pass "fm-ensure-agents-md.sh: symlinks-unreliable repo gets a real, synced CLAUDE.md and stays idempotent"
}

test_symlinks_unreliable_agents_only_creates_real_claude_md() {
  # AGENTS.md already exists (no CLAUDE.md yet) on a repo whose git will not
  # materialize symlinks: the CLAUDE.md this helper adds must be real too.
  local repo agents out
  repo="$TMP_ROOT/unsafe-symlink-agents-only"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  printf '# Existing agent memory\n\nDeploy with the release script.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed adding CLAUDE.md on a core.symlinks=false repo"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a core.symlinks=false repo"
  assert_synced_duplicate "$agents" "$repo/CLAUDE.md" "real CLAUDE.md is not kept in sync with existing AGENTS.md"
  pass "fm-ensure-agents-md.sh: adds a real, synced CLAUDE.md when only AGENTS.md exists and symlinks are unreliable"
}

test_fresh_repo_on_drvfs_never_symlinks_claude_md() {
  # The captain's own production checkouts live on WSL's DrvFs (a native
  # Windows drive bind-mounted under /mnt/<letter>). A brand-new repo there
  # has no core.symlinks recorded yet, and `ln -s` succeeds on DrvFs, so
  # neither the core.symlinks check nor the live ln -s probe alone catches
  # it - only reading the real mount table does. A fake /proc/mounts (via
  # FM_PROC_ROOT_OVERRIDE) simulates the exact mount line observed on a live
  # WSL2 host so this is testable without one.
  local repo real_repo proc_root out
  repo="$TMP_ROOT/drvfs-fresh-project"
  mkdir -p "$repo"
  real_repo=$(cd "$repo" && pwd -P)
  git init -q "$repo"
  proc_root="$TMP_ROOT/fake-proc-drvfs"
  mkdir -p "$proc_root"
  printf 'drvfs-device %s 9p rw,noatime,aname=drvfs,symlinkroot=/mnt/ 0 0\n' "$real_repo" > "$proc_root/mounts"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc_root" "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a fresh repo on a simulated DrvFs mount"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a CLAUDE.md symlink was created on a simulated DrvFs mount"
  assert_present "$repo/AGENTS.md" "AGENTS.md was not created on a simulated DrvFs mount"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md was not created on a simulated DrvFs mount"
  assert_synced_duplicate "$repo/AGENTS.md" "$repo/CLAUDE.md" \
    "real CLAUDE.md is not kept in sync with AGENTS.md on a simulated DrvFs mount"
  # Prove the DrvFs signal - not an incidental local filesystem limit - is
  # what blocked the symlink: a real ln -s in this same directory succeeds.
  ln -s "AGENTS.md" "$repo/.drvfs-probe-sanity-check" \
    || fail "sanity check: this test's own filesystem does not actually support ln -s"
  [ -L "$repo/.drvfs-probe-sanity-check" ] || fail "sanity check: ln -s did not create a real symlink here"
  rm -f "$repo/.drvfs-probe-sanity-check"
  pass "fm-ensure-agents-md.sh: never symlinks CLAUDE.md for a fresh repo on a simulated DrvFs (Windows) mount"
}

test_non_drvfs_mnt_mount_still_symlinks_claude_md() {
  # A /mnt/<x> mount that is NOT DrvFs (an ordinary ext4 filesystem, say)
  # must not be penalized by path-prefix guesswork - only the real fstype
  # and options decide. The repo itself must sit under a genuinely
  # /mnt-shaped mountpoint, not merely somewhere under $TMP_ROOT, or this
  # test would still pass even if on_drvfs() regressed into matching on the
  # /mnt/ path prefix instead of reading the real mount table.
  local repo real_repo proc_root out
  repo="$TMP_ROOT/mnt/z/plain-project"
  mkdir -p "$repo"
  real_repo=$(cd "$repo" && pwd -P)
  case "$real_repo" in
    */mnt/z/plain-project) : ;;
    *) fail "test fixture repo path is not /mnt-shaped (got: $real_repo)" ;;
  esac
  proc_root="$TMP_ROOT/fake-proc-plain-mnt"
  mkdir -p "$proc_root"
  printf '/dev/sdz1 %s ext4 rw,relatime 0 0\n' "$real_repo" > "$proc_root/mounts"
  out=$(FM_PROC_ROOT_OVERRIDE="$proc_root" "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a plain ext4 mount under /mnt"
  [ -L "$repo/CLAUDE.md" ] || fail "a real ext4 mount under /mnt was mistaken for DrvFs"
  pass "fm-ensure-agents-md.sh: a non-DrvFs /mnt mount still gets a real CLAUDE.md symlink"
}

test_both_real_files_with_different_content_still_conflicts() {
  # A genuine conflict - two real files that were never synced by this
  # helper - must still be refused rather than silently merged.
  local repo out rc
  repo="$TMP_ROOT/genuine-conflict"
  mkdir -p "$repo"
  printf '# AGENTS content\n' > "$repo/AGENTS.md"
  printf '# different CLAUDE content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for distinct real AGENTS.md and CLAUDE.md"
  assert_contains "$out" "conflict:" "distinct real files did not report a conflict"
  assert_present "$repo/AGENTS.md" "AGENTS.md was disturbed by the conflict check"
  assert_present "$repo/CLAUDE.md" "CLAUDE.md was disturbed by the conflict check"
  assert_grep "different CLAUDE content" "$repo/CLAUDE.md" "CLAUDE.md content was overwritten"
  pass "fm-ensure-agents-md.sh: refuses two real files with different content"
}

test_marked_duplicate_resyncs_after_agents_only_edit() {
  # The normal workflow on a symlink-unsafe project: a task edits only
  # AGENTS.md (per bin/fm-brief.sh's Project memory section), then re-runs
  # this helper. A previously helper-created real CLAUDE.md duplicate must
  # self-heal instead of hard-refusing the resulting mismatch.
  local repo agents claude out
  repo="$TMP_ROOT/marked-drift-project"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed creating the initial marked duplicate"
  [ ! -L "$claude" ] || fail "expected a real duplicate, not a symlink, on a core.symlinks=false repo"
  assert_grep "fm-ensure-agents-md: this CLAUDE.md is a synced duplicate" "$claude" \
    "initial CLAUDE.md duplicate was not marked"
  printf '\n- New durable note added after the initial sync.\n' >> "$agents"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a marked duplicate's drift instead of resyncing"
  assert_contains "$out" "synced:" "drifted marked duplicate was not reported as resynced"
  assert_grep "New durable note added after the initial sync." "$claude" \
    "resync did not propagate the AGENTS.md-only edit into CLAUDE.md"
  cmp -s "$agents" "$claude" \
    && fail "resynced CLAUDE.md should still carry the trailing marker, not be byte-identical to AGENTS.md"
  # Re-run with nothing changed must be a byte-exact idempotent no-op.
  cp "$claude" "$repo/.after-resync"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run after resync"
  assert_contains "$out" "unchanged:" "idempotent re-run after resync did not report unchanged"
  cmp -s "$repo/.after-resync" "$claude" \
    || fail "idempotent re-run after resync modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: a marked duplicate resyncs instead of conflicting after an AGENTS.md-only edit"
}

# Assert every line of <file> ends with CR, i.e. the file has no mixed line
# endings after this script wrote to it.
assert_all_crlf() {
  local file=$1 msg=$2 total crlf
  total=$(wc -l < "$file")
  crlf=$(LC_ALL=C grep -a -c $'\r$' "$file" || true)
  [ "$crlf" -eq "$total" ] \
    || fail "$msg ($crlf of $total lines end with CR)"
}

# Rewrite <file> in place with CRLF line endings, the way a native Windows
# git checkout with the installer-default core.autocrlf=true materializes a
# tracked text file.
crlf_normalize() {
  LC_ALL=C sed -e 's/\r*$/\r/' "$1" > "$1.crlf"
  mv "$1.crlf" "$1"
}

test_crlf_marked_duplicate_stays_synced_and_resyncs() {
  # A real CLAUDE.md duplicate written for a CRLF worktree - the normal case
  # on the Windows checkouts this mode exists for - must carry a CRLF marker
  # line, be recognized as already in sync on a re-run, and still resync
  # rather than conflict after a CRLF AGENTS.md-only edit.
  local repo agents claude out
  repo="$TMP_ROOT/crlf-marked-duplicate-project"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Build with the Windows toolchain.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$agents"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed creating a duplicate for a CRLF AGENTS.md"
  [ ! -L "$claude" ] || fail "expected a real duplicate, not a symlink, on a core.symlinks=false repo"
  assert_synced_duplicate "$agents" "$claude" "CRLF duplicate is not a synced duplicate"
  assert_all_crlf "$claude" "CRLF duplicate has mixed line endings"
  cp "$claude" "$repo/.after-create"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a freshly written CRLF duplicate"
  assert_contains "$out" "unchanged:" "a synced CRLF duplicate was not recognized as in sync"
  cmp -s "$repo/.after-create" "$claude" \
    || fail "idempotent re-run modified the CRLF duplicate"
  printf '%s\r\n' '' '- New durable CRLF note.' >> "$agents"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a CRLF marked duplicate's drift instead of resyncing"
  assert_contains "$out" "synced:" "drifted CRLF duplicate was not reported as resynced"
  assert_grep "New durable CRLF note." "$claude" \
    "CRLF resync did not propagate the AGENTS.md-only edit into CLAUDE.md"
  assert_all_crlf "$claude" "resynced CRLF duplicate has mixed line endings"
  pass "fm-ensure-agents-md.sh: a CRLF marked duplicate stays synced and resyncs after a CRLF AGENTS.md edit"
}

test_marked_duplicate_survives_crlf_checkout_normalization() {
  # Regression: an LF marked duplicate committed on one machine and checked
  # out by a git that normalizes to CRLF (Windows installer default
  # core.autocrlf=true) comes back with a CR on the marker line too. That
  # must still read as this helper's own duplicate and resync, not hard-exit
  # as an unreconcilable conflict.
  local repo agents claude out
  repo="$TMP_ROOT/crlf-checkout-project"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed creating the initial LF marked duplicate"
  crlf_normalize "$agents"
  crlf_normalize "$claude"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a CRLF-normalized marked duplicate instead of resyncing"
  assert_grep "fm-ensure-agents-md: this CLAUDE.md is a synced duplicate" "$claude" \
    "CRLF-normalized duplicate lost its sync marker"
  assert_all_crlf "$claude" "CRLF-normalized duplicate was rewritten with mixed line endings"
  assert_synced_duplicate "$agents" "$claude" "CRLF-normalized duplicate is not back in sync"
  cp "$claude" "$repo/.after-heal"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on the idempotent re-run after CRLF self-heal"
  assert_contains "$out" "unchanged:" "healed CRLF duplicate was not reported unchanged"
  cmp -s "$repo/.after-heal" "$claude" \
    || fail "idempotent re-run modified the healed CRLF duplicate"
  pass "fm-ensure-agents-md.sh: a marked duplicate survives a CRLF checkout normalization"
}

test_newline_less_agents_md_duplicate_keeps_marker_on_its_own_line() {
  # A memory file with no final newline is a normal input (a hand-trimmed
  # file, or a promoted newline-less CLAUDE.md). The marker must still land
  # on a line of its own, or it is glued onto the last content line, is
  # never recognized as this helper's own again, and the first AGENTS.md-only
  # edit hard-refuses instead of resyncing.
  local repo agents claude out last
  repo="$TMP_ROOT/newline-less-duplicate-project"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config core.symlinks false
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  {
    printf '%s\n' \
      '# Existing agent memory' \
      '' \
      '## Maintaining this file' \
      '' \
      'Keep this file for knowledge useful to almost every future agent session in this project.' \
      'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
      'Prefer rewriting or pruning existing entries over appending new ones.'
    printf '%s' 'When updating this file, preserve this bar for all agents and keep entries concise.'
  } > "$agents"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed creating a duplicate for a newline-less AGENTS.md"
  [ ! -L "$claude" ] || fail "expected a real duplicate, not a symlink, on a core.symlinks=false repo"
  last=$(tail -n 1 "$claude")
  case "$last" in
    '<!-- fm-ensure-agents-md:'*) ;;
    *) fail "sync marker was glued onto a content line (last line: $last)" ;;
  esac
  assert_grep "preserve this bar for all agents and keep entries concise." "$claude" \
    "newline-less duplicate lost or mangled AGENTS.md's last content line"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a freshly written newline-less duplicate"
  assert_contains "$out" "unchanged:" "a synced newline-less duplicate was not recognized as in sync"
  printf '\n- New durable note after the newline-less sync.\n' >> "$agents"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a newline-less duplicate's drift instead of resyncing"
  assert_contains "$out" "synced:" "drifted newline-less duplicate was not reported as resynced"
  assert_grep "New durable note after the newline-less sync." "$claude" \
    "resync did not propagate the AGENTS.md-only edit into CLAUDE.md"
  assert_synced_duplicate "$agents" "$claude" "resynced newline-less duplicate is not a synced duplicate"
  pass "fm-ensure-agents-md.sh: a newline-less AGENTS.md still gets the marker on its own line and resyncs"
}

test_unmarked_claude_still_refuses_on_mismatch() {
  # A hand-authored CLAUDE.md this helper never created has no marker, so a
  # content mismatch must still fail safe as a genuine conflict rather than
  # being silently overwritten - the marker's absence must never be read as
  # license to resync.
  local repo out rc
  repo="$TMP_ROOT/unmarked-mismatch-project"
  mkdir -p "$repo"
  printf '# AGENTS content\n\nOriginal.\n' > "$repo/AGENTS.md"
  printf '# AGENTS content\n\nHand-authored, deliberately different.\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for an unmarked, mismatched real CLAUDE.md"
  assert_contains "$out" "conflict:" "unmarked mismatched CLAUDE.md did not report a conflict"
  assert_grep "Hand-authored, deliberately different." "$repo/CLAUDE.md" \
    "unmarked CLAUDE.md content was overwritten instead of refusing"
  pass "fm-ensure-agents-md.sh: an unmarked real CLAUDE.md still refuses on mismatch rather than resyncing"
}

test_legacy_unmarked_duplicate_upgrades_to_marker() {
  # A real CLAUDE.md duplicate from before this marker existed (byte-
  # identical to AGENTS.md, no trailing marker) must still be recognized as
  # in sync today, and gets upgraded with the marker so future drift on the
  # same project self-heals instead of hard-refusing.
  local repo agents claude out
  repo="$TMP_ROOT/legacy-duplicate-project"
  mkdir -p "$repo"
  agents="$repo/AGENTS.md"
  claude="$repo/CLAUDE.md"
  printf '%s\n' \
    '# Existing agent memory' \
    '' \
    'Build with the legacy script.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$agents"
  cp "$agents" "$claude"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on a legacy byte-identical unmarked duplicate"
  # The upgrade run actually rewrites CLAUDE.md's bytes (adds the marker),
  # so it must not claim "unchanged" - a crewmate reads this line to decide
  # whether anything needs committing.
  assert_contains "$out" "updated:" "legacy unmarked duplicate's marker upgrade was not reported as a change"
  assert_not_contains "$out" "unchanged:" "legacy unmarked duplicate's marker upgrade was misreported as unchanged"
  assert_grep "fm-ensure-agents-md: this CLAUDE.md is a synced duplicate" "$claude" \
    "legacy unmarked duplicate was not upgraded with the sync marker"
  assert_grep "Build with the legacy script." "$claude" \
    "legacy duplicate's original content was lost during the marker upgrade"
  # A further re-run has nothing left to change and must report unchanged -
  # the marker survives the round trip rather than being re-added or lost.
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on the re-run after the marker upgrade"
  assert_contains "$out" "unchanged:" "re-run after the marker upgrade did not report unchanged"
  pass "fm-ensure-agents-md.sh: a legacy byte-identical unmarked duplicate is upgraded with the sync marker and reports the change accurately"
}

test_lowercase_agents_md_refuses_case_fragile_symlink() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict message did not name the offending file"
  assert_absent "$repo/CLAUDE.md" "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  assert_present "$repo/agents.md" "the real lowercase agents.md was disturbed"
  pass "fm-ensure-agents-md.sh: refuses a case-variant lowercase agents.md (issue #389)"
}

test_created_agents_md_includes_self_governance
test_promoted_claude_md_stays_real_not_symlink
test_promoted_claude_md_without_trailing_newline_keeps_blank_separator
test_promotion_of_marked_claude_md_strips_the_marker_from_agents_md
test_existing_agents_md_with_symlink_gains_self_governance
test_existing_agents_md_without_claude_gains_section_and_symlink
test_existing_agents_md_with_section_reports_unchanged
test_existing_crlf_agents_md_with_section_stays_unchanged
test_existing_crlf_agents_md_without_section_preserves_crlf
test_windows_style_repo_promotion_never_symlinks_claude_md
test_symlinks_unreliable_creates_real_synced_claude_md
test_symlinks_unreliable_agents_only_creates_real_claude_md
test_fresh_repo_on_drvfs_never_symlinks_claude_md
test_non_drvfs_mnt_mount_still_symlinks_claude_md
test_both_real_files_with_different_content_still_conflicts
test_marked_duplicate_resyncs_after_agents_only_edit
test_crlf_marked_duplicate_stays_synced_and_resyncs
test_marked_duplicate_survives_crlf_checkout_normalization
test_newline_less_agents_md_duplicate_keeps_marker_on_its_own_line
test_unmarked_claude_still_refuses_on_mismatch
test_legacy_unmarked_duplicate_upgrades_to_marker
test_lowercase_agents_md_refuses_case_fragile_symlink
