#!/usr/bin/env bash
# Behavior tests for the bin/fm-herdr.sh reconcile CLI.
#
# The captain's standing order is that every project gets its own herdr
# workspace and every agent pane is named for the WORK it is doing, not for a
# task id. herdr addresses agents BY NAME, so the name is the address - a bad
# one is not just untidy, it is unaddressable. These cases pin the parsing, the
# naming convention, and the refusal paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-herdr.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-ws)

# A fake herdr: reports a running server, records rename/create calls.
#
# `workspace list` answers with the JSON the real binary answers with, read from
# a file so the shape stays literal. It used to answer with the plain text
# `w1 cellarandsky`, and a fake that speaks a language the binary does not is
# how a `grep -w` over rendered output passed for a workspace lookup.
fake_herdr() {  # <dir>
  local fb="$1/fakebin"; mkdir -p "$fb"
  cat > "$fb/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CALLS"
case "\$1 \$2" in
  "session list")   printf 'name status\ndefault running\n' ;;
  "workspace list") cat "\$WS_JSON" ;;
  "pane get")       printf '{"result":{"pane":{"pane_id":"\$3","tab_id":"wT:t9"}}}\n' ;;
  "tab rename")     printf '{"result":{"type":"ok"}}\n' ;;
  "agent rename")
    # herdr 0.8.2's REAL constraint. Without it this fake is a yes-machine and
    # would happily "accept" a slash the live binary rejects - the exact way a
    # gate passes against a stub while the fleet ends up unaddressable.
    if printf '%s' "\$4" | grep -qE '^[a-z][a-z0-9_-]{0,31}$'; then
      printf '{"result":{"type":"ok"}}\n'
    else
      printf '{"error":{"code":"invalid_agent_name"}}\n'; exit 1
    fi ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"; printf '%s\n' "$fb"
}
FB=$(fake_herdr "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
WS_JSON="$TMP_ROOT/workspaces.json"; export WS_JSON
printf '%s\n' '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"cellarandsky","number":1,"workspace_id":"w1"}]}}' > "$WS_JSON"

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

# THE DEFECT THIS FREEZES. Workspace existence was answered by `grep -qw` over
# the raw listing, and `-w` treats `-` as a word boundary: project `fm` matched a
# workspace labelled `fm-x` and was reported as already present. It then never
# got a workspace of its own, and its first spawn landed in someone else's.
# A label match must be exact, and there is one owner of that question.
test_a_workspace_label_match_is_exact_not_a_word_boundary() {
  local home ws out
  home="$TMP_ROOT/boundary"; mkdir -p "$home/data" "$home/projects/fm"
  printf -- '- fm [local-only] - a project whose name prefixes another workspace\n' \
    > "$home/data/projects.md"
  ws="$TMP_ROOT/boundary-workspaces.json"
  printf '%s\n' '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"fm-x","number":1,"workspace_id":"w7"}]}}' > "$ws"
  out=$(FM_HOME="$home" WS_JSON="$ws" bash "$SCRIPT" 2>&1)
  case "$out" in
    *"exists"*) fail "project 'fm' matched workspace 'fm-x'; it will never get its own workspace" ;;
  esac
  assert_contains "$out" "would-add" "project 'fm' was not proposed its own workspace"
  pass "plan: a workspace label matches exactly, not on a hyphen boundary"
}

# --- the naming convention --------------------------------------------------

# A name is an ADDRESS. It must describe the work, and survive being typed.
test_name_normalises_to_the_convention() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p2 afs "Resource Registry" >/dev/null 2>&1
  grep -q 'agent rename w9:p2 afs-resource-registry' "$CALLS" \
    || { echo "calls: $(cat "$CALLS")"; fail "name not normalised to <project>-<work>"; }
  pass "naming: 'Resource Registry' -> afs-resource-registry"
}

# THE SEPARATOR. A slash is not a style question: herdr 0.8.2 rejects it with
# invalid_agent_name, so a slashed name renames nothing and leaves the pane
# unaddressable. This case is what turns restoring the slash RED.
test_separator_is_a_hyphen_never_a_slash() {
  : > "$CALLS"
  local out
  out=$(FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p9 afs "resource registry" 2>&1)
  assert_contains "$out" "afs-resource-registry" "the applied name is not project-first with a hyphen"
  assert_no_grep "afs/resource-registry" "$CALLS" "a slash-separated name was sent to herdr"
  # And prove the fake would have refused one, so the case above is not vacuous.
  if bash -c 'printf "%s" "afs/resource-registry" | grep -qE "^[a-z][a-z0-9_-]{0,31}$"'; then
    fail "the name check would accept a slash; this gate proves nothing"
  fi
  pass "naming: the separator is a hyphen, and a slash is provably rejected"
}

test_name_strips_unsafe_characters() {
  : > "$CALLS"
  FM_HOME="$HOME_DIR" bash "$SCRIPT" --name w9:p3 afs 'fix: booking (v2)!' >/dev/null 2>&1
  grep -qE 'agent rename w9:p3 afs-[a-z0-9-]+$' "$CALLS" \
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
test_a_workspace_label_match_is_exact_not_a_word_boundary
test_name_normalises_to_the_convention
test_separator_is_a_hyphen_never_a_slash
test_name_strips_unsafe_characters
test_overlong_name_is_refused
test_refuses_when_no_server
test_refuses_without_a_registry
