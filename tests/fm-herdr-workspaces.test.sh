#!/usr/bin/env bash
# Behavior tests for fm-herdr-workspaces.sh.
#
# The captain's standing order is that every project gets its own herdr
# workspace and every agent pane is named for the WORK it is doing, not for a
# task id. herdr addresses agents BY NAME, so the name is the address - a bad
# one is not just untidy, it is unaddressable. These cases pin the parsing, the
# naming convention, and the refusal paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-herdr-workspaces.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-ws)

# A fake herdr: reports a running server, records rename/create calls.
fake_herdr() {  # <dir> <workspace-list-output>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CALLS"
case "\$1 \$2" in
  "session list")   printf 'name status\ndefault running\n' ;;
  "workspace list") printf '%s\n' "$2" ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"; printf '%s\n' "$fb"
}
FB=$(fake_herdr "$TMP_ROOT" "w1 cellarandsky")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS

# A fake FM_HOME with a registry and project dirs.
HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects/cellarandsky" "$HOME_DIR/projects/afs-extractor"
cat > "$HOME_DIR/data/projects.md" <<'MD'
# Projects

- cellarandsky [direct-PR] - marketing site (added 2026-06-24)
- afs-extractor [local-only] - scraping fleet (added 2026-08-26)
- ghost-project [local-only] - registered but never cloned (added 2026-08-26)
MD

# The registry is the source of which workspaces should exist. A project with a
# registry line but no directory must be reported, not silently created.
test_plan_reads_registry_and_flags_missing_dirs() {
  local out
  out=$(FM_HOME="$HOME_DIR" bash "$SCRIPT" 2>&1)
  assert_contains "$out" "afs-extractor"  "plan lists a registered project"
  assert_contains "$out" "would-add"      "plan proposes creating the missing workspace"
  assert_contains "$out" "exists"         "plan skips a workspace that already exists"
  assert_contains "$out" "NO-DIR"         "plan flags a registry line with no directory"
  pass "plan: reads the registry, skips existing, flags a missing directory"
}

# Planning must never mutate. This is what makes it safe to run any time.
test_plan_creates_nothing() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" >/dev/null 2>&1
  if grep -q 'workspace create' "$CALLS"; then
    fail "plan mode created a workspace"
  else
    pass "plan mode changes nothing"
  fi
}

test_apply_creates_only_the_missing_one() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --apply >/dev/null 2>&1
  grep -q 'workspace create .*--label afs-extractor' "$CALLS" || fail "apply did not create the missing workspace"
  grep -q 'workspace create .*--label cellarandsky' "$CALLS" && fail "apply recreated an existing workspace"
  pass "apply: idempotent — creates only what is absent"
}

# --- the naming convention --------------------------------------------------

# A name is an ADDRESS. It must describe the work, and survive being typed.
test_name_normalises_to_the_convention() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p2 afs "Resource Registry" >/dev/null 2>&1
  grep -q 'agent rename w9:p2 afs/resource-registry' "$CALLS" \
    || { echo "calls: $(cat "$CALLS")"; fail "name not normalised to <project>/<work>"; }
  pass "naming: 'Resource Registry' -> afs/resource-registry"
}

test_name_strips_unsafe_characters() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p3 afs 'fix: booking (v2)!' >/dev/null 2>&1
  grep -qE 'agent rename w9:p3 afs/[a-z0-9/-]+$' "$CALLS" \
    || { echo "calls: $(cat "$CALLS")"; fail "unsafe characters survived into the name"; }
  pass "naming: punctuation stripped, kebab-case enforced"
}

# An unreadably long name defeats the whole point — it must be refused.
test_overlong_name_is_refused() {
  if FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p4 afs \
       "an extremely long description of the work that will never fit in a tab bar" >/dev/null 2>&1; then
    fail "an overlong name was accepted"
  else
    pass "naming: an unreadably long name is refused"
  fi
}

# --- refusal paths ----------------------------------------------------------

test_refuses_when_no_server() {
  local fb2="$TMP_ROOT/nofakebin"; mkdir -p "$fb2"
  printf '#!/usr/bin/env bash\nprintf "name status\\ndefault stopped\\n"\nexit 0\n' > "$fb2/herdr"
  chmod +x "$fb2/herdr"
  local out
  out=$(PATH="$fb2:$PATH" FM_HOME="$HOME_DIR" bash "$SCRIPT" 2>&1) && fail "ran with no server"
  assert_contains "$out" "no herdr server is running" "refusal names the actual problem"
  assert_contains "$out" "herdr\` to start"           "refusal gives the fix"
  pass "refuses with an actionable message when the server is down"
}

test_refuses_without_a_registry() {
  local out
  out=$(FM_HOME="$TMP_ROOT/empty" bash "$SCRIPT" 2>&1) && fail "ran without a registry"
  assert_contains "$out" "no project registry" "refusal names the missing registry"
  pass "refuses when the project registry is absent"
}

test_plan_reads_registry_and_flags_missing_dirs
test_plan_creates_nothing
test_apply_creates_only_the_missing_one
test_name_normalises_to_the_convention
test_name_strips_unsafe_characters
test_overlong_name_is_refused
test_refuses_when_no_server
test_refuses_without_a_registry
