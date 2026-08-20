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

entry_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

test_non_default_modes_migrate_and_converge() {
  local home first second
  home=$(new_home)
  mkdir -p "$home/.gemini/skills/alpha/scripts"
  printf '%s\n' body > "$home/.gemini/skills/alpha/SKILL.md"
  printf '%s\n' 'echo hi' > "$home/.gemini/skills/alpha/scripts/run.sh"
  chmod 664 "$home/.gemini/skills/alpha/scripts/run.sh"
  chmod 775 "$home/.gemini/skills/alpha/scripts"

  first=$(umask 022; run_sync "$home" --apply)

  assert_contains "$first" "user skills converged" "migration of non-default modes did not converge"
  [ "$(entry_mode "$home/.agents/skills/alpha/scripts/run.sh")" = 664 ] \
    || fail "canonical copy did not preserve the source file mode"
  [ "$(entry_mode "$home/.agents/skills/alpha/scripts")" = 775 ] \
    || fail "canonical copy did not preserve the source directory mode"
  [ ! -e "$home/.gemini/skills/alpha" ] || fail "migrated Gemini source was not removed"
  second=$(run_sync "$home" --apply)
  [ "$second" = "user skills already converged; no changes" ] \
    || fail "rerun after migration did not converge: $second"
  pass "migration preserves source modes and converges under a default umask"
}

test_restrictive_umask_migration_converges() {
  local home first
  home=$(new_home)
  make_skill "$home/.opencode/skills" beta body

  first=$(umask 077; run_sync "$home" --apply)

  assert_contains "$first" "user skills converged" "migration under a restrictive umask did not converge"
  [ -f "$home/.agents/skills/beta/SKILL.md" ] || fail "canonical skill was not established under umask 077"
  [ ! -e "$home/.opencode/skills/beta" ] || fail "migrated OpenCode source was not removed"
  pass "migration converges under a restrictive umask"
}

test_control_character_nested_name_refuses() {
  local home out nested
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  nested=$(printf 'note\nname.txt')
  printf '%s\n' text > "$home/.agents/skills/alpha/$nested" 2>/dev/null || {
    pass "control-character nested names are unsupported by this filesystem (skipped)"
    return 0
  }

  out=$(expect_failure "$home" "control-character nested name" --apply)

  assert_contains "$out" "control character" "control-character refusal lacked diagnosis"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "refused run mutated the canonical skill"
  pass "a control character in a nested skill name refuses before mutation"
}

test_codex_home_separator_spelling_converges() {
  local home resolved expected second
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body

  HOME="$home" CODEX_HOME="$home/.codex/" "$SCRIPT" --apply >/dev/null

  [ -L "$home/.codex/skills/alpha" ] || fail "trailing-slash CODEX_HOME did not create the Codex link"
  resolved=$(cd "$home/.codex/skills/alpha" 2>/dev/null && pwd -P) \
    || fail "trailing-slash CODEX_HOME produced a link that does not resolve"
  expected=$(cd "$home/.agents/skills/alpha" && pwd -P)
  [ "$resolved" = "$expected" ] || fail "Codex link resolves outside the canonical store: $resolved"
  [ -f "$home/.codex/skills/alpha/SKILL.md" ] || fail "SKILL.md is unreadable through the Codex link"

  second=$(run_sync "$home" --apply)
  [ "$second" = "user skills already converged; no changes" ] \
    || fail "canonically spelled rerun did not converge: $second"

  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  HOME="$home" CODEX_HOME="$home//.codex//" "$SCRIPT" --apply >/dev/null
  resolved=$(cd "$home/.codex/skills/alpha" 2>/dev/null && pwd -P) \
    || fail "repeated-separator CODEX_HOME produced a link that does not resolve"
  [ "$resolved" = "$(cd "$home/.agents/skills/alpha" && pwd -P)" ] \
    || fail "repeated-separator CODEX_HOME resolves outside the canonical store"
  pass "odd CODEX_HOME separator spelling still links correctly and converges"
}

test_unreadable_managed_root_refuses() {
  local home out rc
  if [ "$(id -u)" -eq 0 ]; then
    pass "unreadable managed roots refuse (skipped: running as root bypasses permissions)"
    return 0
  fi

  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  make_skill "$home/.gemini/skills" alpha body
  chmod 000 "$home/.gemini/skills"
  set +e
  out=$(run_sync "$home" --apply 2>&1)
  rc=$?
  set -e
  chmod 755 "$home/.gemini/skills"
  [ "$rc" -ne 0 ] || fail "unreadable managed skill root was reported as converged"
  assert_contains "$out" "cannot inspect managed skill root" "unreadable root refusal lacked diagnosis"
  [ -d "$home/.gemini/skills/alpha" ] || fail "refused run mutated the unreadable root"

  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  make_skill "$home/.gemini/skills" alpha body
  chmod 000 "$home/.gemini"
  set +e
  out=$(run_sync "$home" --apply 2>&1)
  rc=$?
  set -e
  chmod 755 "$home/.gemini"
  [ "$rc" -ne 0 ] || fail "unreadable managed skill parent was reported as converged"
  assert_contains "$out" "cannot inspect managed skill parent" "unreadable parent refusal lacked diagnosis"
  [ -d "$home/.gemini/skills/alpha" ] || fail "refused run mutated the unreadable parent tree"
  pass "an unreadable managed root refuses instead of claiming convergence"
}

test_mode_only_difference_names_permission_bits() {
  local home out
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  make_skill "$home/.gemini/skills" alpha body
  chmod 700 "$home/.gemini/skills/alpha/sub"

  out=$(expect_failure "$home" "mode-only difference" --apply)

  assert_contains "$out" "permission bits differ" "mode-only refusal did not name permission bits"
  assert_contains "$out" "/sub" "mode-only refusal did not name the differing entry"
  assert_contains "$out" "700" "mode-only refusal did not report the differing modes"
  [ -d "$home/.gemini/skills/alpha" ] || fail "refused run mutated the differing duplicate"
  pass "a permission-bit-only difference is diagnosed as such"
}

# Shadows one external command with a stub that announces itself and blocks
# until the test releases it, giving a deterministic pause point inside the run.
make_blocking_stub() {
  local fakebin=$1 name=$2 real=$3
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
: > "\${STUB_STARTED:?}"
waited=0
while [ ! -e "\${STUB_RELEASE:?}" ] && [ "\$waited" -lt 600 ]; do
  sleep 0.1
  waited=\$((waited + 1))
done
exec $real "\$@"
SH
  chmod +x "$fakebin/$name"
}

# The apply loop is paused deterministically by shadowing `cp` with a stub that
# blocks after the canonical copy is planned, so the signal is always delivered
# mid-plan rather than racing the run to completion. Bash defers the trap until
# the foreground child returns, so the stub is released after signalling.
test_interrupt_stops_apply() {
  local home out pid rc fakebin waited
  home=$(new_home)
  make_skill "$home/.gemini/skills" alpha body
  out="$home/apply.out"
  fakebin=$(fm_fakebin "$home")
  make_blocking_stub "$fakebin" cp /bin/cp

  PATH="$fakebin:$PATH" STUB_STARTED="$home/stub.started" STUB_RELEASE="$home/stub.release" \
    HOME="$home" CODEX_HOME="$home/.codex" "$SCRIPT" --apply > "$out" 2>&1 &
  pid=$!

  waited=0
  while [ ! -e "$home/stub.started" ]; do
    kill -0 "$pid" 2>/dev/null || fail "apply exited before reaching the canonical copy"
    [ "$waited" -lt 600 ] || fail "apply never reached the canonical copy"
    sleep 0.1
    waited=$((waited + 1))
  done

  kill -TERM "$pid" || fail "apply was no longer running when the signal was sent"
  : > "$home/stub.release"
  set +e
  wait "$pid"
  rc=$?
  set -e

  [ "$rc" -eq 143 ] || fail "interrupted apply exited $rc instead of 143"
  assert_contains "$(cat "$out")" "interrupted by SIGTERM" "interrupted apply lacked an interruption diagnosis"
  assert_contains "$(cat "$out")" "may already be applied" \
    "mid-apply interruption did not report that changes may be applied"
  assert_not_contains "$(cat "$out")" "user skills converged" "interrupted apply still claimed convergence"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "the copy that was in flight did not complete"
  [ -d "$home/.gemini/skills/alpha" ] || fail "the interrupted apply kept executing later plan steps"
  [ ! -e "$home/.claude/skills/alpha" ] || fail "the interrupted apply kept linking after the signal"
  pass "an interrupted apply stops at the signal instead of finishing the plan"
}

test_interrupt_during_preflight_reports_no_mutation() {
  local home out pid rc fakebin waited real_diff
  home=$(new_home)
  make_skill "$home/.agents/skills" alpha body
  make_skill "$home/.gemini/skills" alpha body
  out="$home/dryrun.out"
  fakebin=$(fm_fakebin "$home")
  real_diff=$(command -v diff)
  make_blocking_stub "$fakebin" diff "$real_diff"

  PATH="$fakebin:$PATH" STUB_STARTED="$home/stub.started" STUB_RELEASE="$home/stub.release" \
    HOME="$home" CODEX_HOME="$home/.codex" "$SCRIPT" > "$out" 2>&1 &
  pid=$!

  waited=0
  while [ ! -e "$home/stub.started" ]; do
    kill -0 "$pid" 2>/dev/null || fail "dry run exited before reaching the preflight comparison"
    [ "$waited" -lt 600 ] || fail "dry run never reached the preflight comparison"
    sleep 0.1
    waited=$((waited + 1))
  done

  kill -TERM "$pid" || fail "dry run was no longer running when the signal was sent"
  : > "$home/stub.release"
  set +e
  wait "$pid"
  rc=$?
  set -e

  [ "$rc" -eq 143 ] || fail "interrupted dry run exited $rc instead of 143"
  assert_contains "$(cat "$out")" "before any planned change began" \
    "preflight interruption did not report that nothing was mutated"
  assert_not_contains "$(cat "$out")" "may already be applied" \
    "preflight interruption wrongly claimed applied changes"
  [ -f "$home/.agents/skills/alpha/SKILL.md" ] || fail "interrupted dry run mutated the canonical skill"
  [ -d "$home/.gemini/skills/alpha" ] || fail "interrupted dry run removed the duplicate"
  [ ! -e "$home/.claude" ] || fail "interrupted dry run created a managed root"
  pass "an interrupted read-only run reports that nothing was mutated"
}

test_unresolvable_codex_home_reports_one_cause() {
  local home out errors rc
  home=$(new_home)
  printf '%s\n' text > "$home/afile"

  set +e
  out=$(HOME="$home" CODEX_HOME="$home/afile" "$SCRIPT" 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "CODEX_HOME pointing at a regular file was accepted"
  assert_contains "$out" "existing CODEX_HOME ancestor is not a directory" \
    "unresolvable CODEX_HOME refusal lacked its cause"
  assert_not_contains "$out" "must resolve to an absolute path" \
    "unresolvable CODEX_HOME emitted a cascading empty-path error"
  errors=$(printf '%s\n' "$out" | grep -c '^error:')
  [ "$errors" -eq 1 ] || fail "unresolvable CODEX_HOME reported $errors errors instead of one"
  pass "an unresolvable CODEX_HOME reports exactly one cause"
}

remote_registry_home() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/secondmates.md" <<EOF
- mac - registered Mac (host: remote-mac; root: /remote/firstmate; home: /remote/firstmate-home; scope: user tools; projects: ; added 2026-08-20)
- studio - registered studio Mac (host: studio-mac; root: /studio/firstmate; home: /studio/firstmate-home; scope: user tools; projects: ; added 2026-08-20)
- studio-standby - standby account on the studio Mac (host: studio-mac; root: /studio/firstmate-standby; home: /studio/standby-home; scope: user tools; projects: ; added 2026-08-20)
EOF
}

remote_ssh_stub() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SSH_ARGV:?}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$fakebin/ssh"
}

decode_b64() {
  printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D
}

test_remote_routes_through_registered_home() {
  local home ssh_bin argv decoded remote_root remote_home
  home=$(new_home)
  remote_registry_home "$home"
  ssh_bin=$(remote_ssh_stub "$home")
  argv="$home/ssh.argv"

  HOME="$home" FM_HOME="$home" FM_SSH_BIN="$ssh_bin" SSH_ARGV="$argv" \
    "$SCRIPT" --remote mac --apply

  assert_grep 'remote-mac' "$argv" "remote operation did not use the registered SSH host"
  remote_root=$(decode_b64 "$(tail -n 3 "$argv" | head -n 1)")
  remote_home=$(decode_b64 "$(tail -n 2 "$argv" | head -n 1)")
  [ "$remote_root" = /remote/firstmate ] || fail "remote operation changed the registered root: $remote_root"
  [ "$remote_home" = /remote/firstmate-home ] || fail "remote operation changed the registered home: $remote_home"
  decoded=$(decode_b64 "$(tail -n 1 "$argv")" | tr '\0' '\n')
  assert_contains "$decoded" "fm-user-skill-sync.sh" "remote argv omitted the authoritative command"
  assert_contains "$decoded" "--apply" "remote argv lost explicit apply intent"
  assert_not_contains "$(cat "$argv")" "studio-mac" "remote route reached another registered host"
  assert_not_contains "$remote_home" "studio" "remote route bound another registered home"
  pass "remote invocation binds exactly the selected record's host, root, and home"
}

test_remote_second_record_binds_its_own_placement() {
  local home ssh_bin argv remote_root remote_home
  home=$(new_home)
  remote_registry_home "$home"
  ssh_bin=$(remote_ssh_stub "$home")
  argv="$home/ssh.argv"

  HOME="$home" FM_HOME="$home" FM_SSH_BIN="$ssh_bin" SSH_ARGV="$argv" \
    "$SCRIPT" --remote studio --dry-run

  assert_grep 'studio-mac' "$argv" "selecting the second record did not use its own SSH host"
  assert_not_contains "$(cat "$argv")" "remote-mac" "selecting the second record reached the first host"
  remote_root=$(decode_b64 "$(tail -n 3 "$argv" | head -n 1)")
  remote_home=$(decode_b64 "$(tail -n 2 "$argv" | head -n 1)")
  [ "$remote_root" = /studio/firstmate ] || fail "second record bound root $remote_root"
  [ "$remote_home" = /studio/firstmate-home ] || fail "second record bound home $remote_home"
  pass "each registered record binds its own host, root, and home"
}

test_remote_ambiguous_alias_refuses_without_transport() {
  local home ssh_bin argv out rc
  home=$(new_home)
  remote_registry_home "$home"
  ssh_bin=$(remote_ssh_stub "$home")
  argv="$home/ssh.argv"

  set +e
  out=$(HOME="$home" FM_HOME="$home" FM_SSH_BIN="$ssh_bin" SSH_ARGV="$argv" \
    "$SCRIPT" --remote studio-mac --apply 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "an ambiguous host alias was accepted"
  assert_contains "$out" "ambiguous" "ambiguous alias refusal did not name the ambiguity"
  [ ! -e "$argv" ] || fail "ambiguous alias still opened a remote transport"
  pass "an ambiguous host alias refuses instead of selecting a host"
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
test_non_default_modes_migrate_and_converge
test_restrictive_umask_migration_converges
test_control_character_nested_name_refuses
test_codex_home_separator_spelling_converges
test_unreadable_managed_root_refuses
test_mode_only_difference_names_permission_bits
test_interrupt_stops_apply
test_interrupt_during_preflight_reports_no_mutation
test_unresolvable_codex_home_reports_one_cause
test_remote_routes_through_registered_home
test_remote_second_record_binds_its_own_placement
test_remote_ambiguous_alias_refuses_without_transport
