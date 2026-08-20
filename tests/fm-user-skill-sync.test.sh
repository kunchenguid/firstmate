#!/usr/bin/env bash
# Behavior tests for the user-skill canonicalization command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-user-skill-sync)
SCRIPT="$ROOT/bin/fm-user-skill-sync.sh"
new_home() {
  mktemp -d "$TMP_ROOT/home.XXXXXX"
}

make_skill() {
  local root=$1 name=$2 body=$3
  mkdir -p "$root/$name/sub"
  printf '%s\n' "$body" > "$root/$name/SKILL.md"
  printf '%s\n' asset > "$root/$name/sub/asset.txt"
}

run_sync() {
  local home=$1
  shift
  HOME="$home" CODEX_HOME="$home/.codex" "$SCRIPT" "$@"
}

expect_failure() {
  local home=$1 message=$2
  shift 2
  local out rc
  set +e
  out=$(run_sync "$home" "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$message: command unexpectedly succeeded"
  printf '%s\n' "$out"
}

test_canonicalizes_and_links() {
  local home out
  home=$(new_home)
  make_skill "$home/.gemini/skills" alpha content

  out=$(run_sync "$home" --apply)

  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "canonical skill was not established"
  [ ! -e "$home/.gemini/skills/alpha" ] || fail "verified Gemini duplicate remained"
  [ -L "$home/.claude/skills/alpha" ] || fail "Claude per-skill link missing"
  [ "$(readlink "$home/.claude/skills/alpha")" = '../../.agents/skills/alpha' ] \
    || fail "Claude link is not the expected relative target"
  [ -L "$home/.codex/skills/alpha" ] || fail "Codex per-skill link missing"
  [ "$(readlink "$home/.codex/skills/alpha")" = '../../.agents/skills/alpha' ] \
    || fail "Codex link is not the expected relative target"
  assert_contains "$out" "user skills converged" "apply did not report convergence"
  pass "real user skill migrates to canonical content with relative harness links"
}

test_duplicate_removal_and_idempotence() {
  local home first second
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha same
  make_skill "$home/.pi/agent/skills" alpha same
  make_skill "$home/.config/opencode/skills" alpha same

  first=$(run_sync "$home" --apply)
  [ ! -e "$home/.pi/agent/skills/alpha" ] || fail "Pi duplicate remained"
  [ ! -e "$home/.config/opencode/skills/alpha" ] || fail "OpenCode duplicate remained"
  second=$(run_sync "$home" --apply)
  assert_contains "$first" "remove" "first apply omitted duplicate-removal plan"
  [ "$second" = "user skills already converged; no changes" ] \
    || fail "second apply did not converge to no changes: $second"
  pass "verified duplicate removal is idempotent"
}

test_conflict_refuses_without_mutation() {
  local home out before
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha canonical
  make_skill "$home/.claude/skills" alpha conflicting
  before=$(cat "$home/.claude/skills/alpha/SKILL.md")

  out=$(expect_failure "$home" "conflicting trees")

  assert_contains "$out" "conflicting skill trees" "conflict refusal lacked diagnosis"
  [ -d "$home/.claude/skills/alpha" ] || fail "conflicting source was mutated"
  [ "$(cat "$home/.claude/skills/alpha/SKILL.md")" = "$before" ] || fail "conflicting source content changed"
  [ ! -e "$home/.codex/skills/alpha" ] || fail "preflight conflict allowed partial Codex mutation"
  pass "byte-different skill trees refuse before mutation"
}

test_dry_run_changes_nothing() {
  local home out
  home=$(new_home)
  make_skill "$home/.opencode/skills" beta body

  out=$(run_sync "$home")

  assert_contains "$out" "DRY RUN - no changes made" "default run was not visibly dry"
  [ -d "$home/.opencode/skills/beta" ] || fail "dry-run removed source"
  [ ! -e "$home/.agents" ] || fail "dry-run created canonical root"
  [ ! -e "$home/.claude" ] || fail "dry-run created Claude root"
  [ ! -e "$home/.codex" ] || fail "dry-run created Codex root"
  pass "dry-run is the mutation-free default"
}

test_codex_system_preserved() {
  local home before
  home=$(new_home)
  mkdir -p "$home/.codex/skills/.system"
  printf '%s\n' vendor > "$home/.codex/skills/.system/owned.txt"
  before=$(cat "$home/.codex/skills/.system/owned.txt")
  make_skill "$home/.agents/skills" alpha body

  run_sync "$home" --apply >/dev/null

  [ "$(cat "$home/.codex/skills/.system/owned.txt")" = "$before" ] || fail "Codex .system content changed"
  [ -L "$home/.codex/skills/alpha" ] || fail "Codex user link was not created beside .system"
  pass "Codex vendor-managed .system is preserved"
}

test_links_and_unexpected_entries_refuse() {
  local home out
  home=$(new_home)
  mkdir -p "$home/.agents/skills/alpha"
  printf '%s\n' body > "$home/.agents/skills/alpha/SKILL.md"
  ln -s missing "$home/.claude/skills" 2>/dev/null || {
    mkdir -p "$home/.claude"
    ln -s missing "$home/.claude/skills"
  }
  out=$(expect_failure "$home" "broken root link")
  assert_contains "$out" "broken managed skill root link" "broken root link refusal lacked diagnosis"

  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  make_skill "$home/outside" alpha body
  mkdir -p "$home/.claude/skills"
  ln -s "$home/outside/alpha" "$home/.claude/skills/alpha"
  out=$(expect_failure "$home" "unsafe per-skill link")
  assert_contains "$out" "unsafe skill link points outside" "unsafe per-skill link refusal lacked diagnosis"

  home=$(new_home)
  mkdir -p "$home/.agents/skills"
  printf '%s\n' surprise > "$home/.agents/skills/README.txt"
  out=$(expect_failure "$home" "unexpected root file")
  assert_contains "$out" "unexpected entry" "unexpected-entry refusal lacked diagnosis"
  pass "broken links and unexpected entries refuse conservatively"
}

test_safe_whole_root_links_converge() {
  local home
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  mkdir -p "$home/.claude" "$home/.pi/agent"
  ln -s ../.agents/skills "$home/.claude/skills"
  ln -s ../../.agents/skills "$home/.pi/agent/skills"

  run_sync "$home" --apply >/dev/null

  [ -d "$home/.claude/skills" ] && [ ! -L "$home/.claude/skills" ] \
    || fail "safe Claude whole-root link did not become a real per-skill root"
  [ -L "$home/.claude/skills/alpha" ] || fail "Claude per-skill link missing after root conversion"
  [ ! -e "$home/.pi/agent/skills" ] || fail "native Pi whole-root duplicate link remained"
  pass "verified whole-root canonical links converge without touching their target"
}

test_codex_relative_link_resolves_in_isolated_home() {
  local home resolved expected
  home=$(new_home)
  make_skill "$home/.agents/skills" probe body
  run_sync "$home" --apply >/dev/null
  resolved=$(cd "$home/.codex/skills/probe" && pwd -P)
  expected=$(cd "$home/.agents/skills/probe" && pwd -P)
  [ "$resolved" = "$expected" ] || fail "isolated Codex link does not resolve to canonical skill"
  [ -f "$home/.codex/skills/probe/SKILL.md" ] || fail "SKILL.md is unreadable through isolated Codex link"
  pass "isolated Codex per-skill link resolves and exposes SKILL.md"
}

test_colliding_managed_roots_refuse() {
  local home out rc
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/.agents" "$SCRIPT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "colliding Codex and canonical roots were not refused"
  assert_contains "$out" "same directory" "collision refusal lacked diagnosis"

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/.agents" "$SCRIPT" --apply 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "colliding roots were applied"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "colliding apply destroyed the canonical skill"
  [ ! -L "$home/.agents/skills/alpha" ] || fail "colliding apply replaced the canonical skill with a link"

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/.agents/skills" "$SCRIPT" --apply 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "nested Codex root inside the canonical root was applied"
  assert_contains "$out" "nested inside" "nested-root refusal lacked diagnosis"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "nested apply destroyed the canonical skill"
  pass "colliding or nested managed roots refuse before any mutation"
}

# A managed root that differs only in spelling still names one directory on a
# case-insensitive volume, which is the captain's default macOS filesystem.
filesystem_is_case_insensitive() {
  local probe=$1
  mkdir -p "$probe/casefold"
  [ -d "$probe/CASEFOLD" ]
}

test_aliased_managed_roots_refuse() {
  local home out rc probe
  home=$(new_home)

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/.Agents" "$SCRIPT" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "case-variant Codex root was not refused before the roots existed"
  assert_contains "$out" "same directory" "case-variant refusal lacked diagnosis"
  [ ! -e "$home/.agents" ] || fail "refused run created the canonical root"

  probe=$(new_home)
  if ! filesystem_is_case_insensitive "$probe"; then
    pass "case-variant managed roots refuse before creation (case-sensitive volume: alias case skipped)"
    return 0
  fi

  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/.Agents" "$SCRIPT" --apply 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "case-variant Codex root aliasing the canonical store was applied"
  assert_contains "$out" "same directory" "aliased-root refusal lacked diagnosis"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "aliased apply destroyed the canonical skill"
  [ ! -L "$home/.agents/skills/alpha" ] || fail "aliased apply replaced the canonical skill with a link"
  pass "aliased managed roots that name one directory refuse before any mutation"
}

make_script_skill() {
  local root=$1 name=$2 mode=$3
  mkdir -p "$root/$name/scripts"
  printf '%s\n' body > "$root/$name/SKILL.md"
  printf '%s\n' 'echo hi' > "$root/$name/scripts/run.sh"
  chmod "$mode" "$root/$name/scripts/run.sh"
}

test_mode_differing_duplicate_refuses() {
  local home out second
  home=$(new_home)
  make_script_skill "$home/.agents/skills" alpha 644
  make_script_skill "$home/.pi/agent/skills" alpha 755

  out=$(expect_failure "$home" "mode-differing duplicate" --apply)

  assert_contains "$out" "conflicting skill trees" "mode-difference refusal lacked diagnosis"
  [ -x "$home/.pi/agent/skills/alpha/scripts/run.sh" ] \
    || fail "executable duplicate was removed despite differing from the canonical copy"
  [ ! -x "$home/.agents/skills/alpha/scripts/run.sh" ] || fail "canonical script mode changed"

  chmod 644 "$home/.pi/agent/skills/alpha/scripts/run.sh"
  second=$(run_sync "$home" --apply)
  [ ! -e "$home/.pi/agent/skills/alpha" ] || fail "mode-identical duplicate was not removed"
  assert_contains "$second" "user skills converged" "mode-identical duplicate did not converge"
  pass "duplicate removal proves permission bits as well as bytes"
}

test_executable_skill_script_survives_migration() {
  local home
  home=$(new_home)
  make_script_skill "$home/.gemini/skills" alpha 755

  run_sync "$home" --apply >/dev/null

  [ -x "$home/.agents/skills/alpha/scripts/run.sh" ] \
    || fail "migration dropped the executable bit on a skill script"
  [ -x "$home/.claude/skills/alpha/scripts/run.sh" ] \
    || fail "executable script is not executable through the Claude link"
  pass "migration preserves executable skill scripts"
}

test_remote_routes_through_registered_home() {
  local home fakebin argv encoded decoded home_encoded remote_home
  home=$(new_home)
  mkdir -p "$home/data"
  cat > "$home/data/secondmates.md" <<EOF
- mac - registered Mac (host: remote-mac; root: /remote/firstmate; home: /remote/firstmate-home; scope: user tools; projects: ; added 2026-08-20)
EOF
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SSH_ARGV:?}"
SH
  chmod +x "$fakebin/ssh"
  argv="$home/ssh.argv"

  HOME="$home" FM_HOME="$home" FM_SSH_BIN="$fakebin/ssh" SSH_ARGV="$argv" \
    "$SCRIPT" --remote mac --apply

  assert_grep 'remote-mac' "$argv" "remote operation did not use the registered SSH host"
  home_encoded=$(tail -n 2 "$argv" | head -n 1)
  remote_home=$(printf '%s' "$home_encoded" | base64 --decode 2>/dev/null \
    || printf '%s' "$home_encoded" | base64 -D)
  [ "$remote_home" = /remote/firstmate-home ] || fail "remote operation changed the registered home: $remote_home"
  encoded=$(tail -n 1 "$argv")
  decoded=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null | tr '\0' '\n' \
    || printf '%s' "$encoded" | base64 -D | tr '\0' '\n')
  assert_contains "$decoded" "fm-user-skill-sync.sh" "remote argv omitted the authoritative command"
  assert_contains "$decoded" "--apply" "remote argv lost explicit apply intent"
  assert_not_contains "$(cat "$argv")" "different-host" "remote route changed hosts"
  pass "remote invocation binds the registered host and forwards explicit apply"
}

test_canonicalizes_and_links
test_duplicate_removal_and_idempotence
test_conflict_refuses_without_mutation
test_dry_run_changes_nothing
test_codex_system_preserved
test_links_and_unexpected_entries_refuse
test_safe_whole_root_links_converge
test_codex_relative_link_resolves_in_isolated_home
test_colliding_managed_roots_refuse
test_aliased_managed_roots_refuse
test_mode_differing_duplicate_refuses
test_executable_skill_script_survives_migration
test_remote_routes_through_registered_home
