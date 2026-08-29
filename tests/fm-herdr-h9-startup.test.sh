#!/usr/bin/env bash
# GATE h9 - startup tells you when the fleet cannot dispatch.
#
# THE DEFECT THIS FREEZES (Quarterdeck reject, attempt 2). The cutover made a
# reachable herdr server MANDATORY to spawn anything - fm_herdr_require stops the
# spawn and escalates rather than degrading, which is what the captain asked for.
# But bin/fm-bootstrap.sh never learned about herdr: TOOLS listed
# `tmux node gh treehouse no-mistakes gh-axi chrome-devtools-axi lavish-axi` and
# install_cmd had no herdr case. Verified: with herdr off PATH, bootstrap printed
# no problem line and exited 0.
#
# So a fresh or headless host passed startup clean and then hard-failed on every
# single dispatch. That is worse than either half alone: the tier that exists to
# say "you cannot work yet" said nothing, and the failure surfaced later, per
# task, as an escalation the captain had to interpret. The brief called this out
# as a safety requirement, not scope creep - "do not strand a headless
# firstmate" - and the requirement outlived the design that prompted it.
#
# TWO DISTINCT PROBLEMS, because they have different fixes:
#   * the BINARY is absent          -> install it
#   * the binary is there, NO SERVER -> start or attach one
# Reporting both as "MISSING: herdr" would send someone to reinstall a tool that
# is already installed.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

BOOT="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-h9)

HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects"

# Resolved BEFORE any PATH surgery. fm_herdr_path_without_binary removes whole
# directories that contain a herdr, and on this machine that is ~/.local/bin -
# which also holds timeout. Calling `timeout` by name after the strip silently
# produced no bootstrap output at all, and the assertion failed for a reason
# that had nothing to do with what it was testing.
TIMEOUT_BIN=$(command -v timeout || true)

run_boot() {  # runs bootstrap against a throwaway home; echoes its output
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_FLEET_PRUNE=0 \
    FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=2 \
    ${TIMEOUT_BIN:+"$TIMEOUT_BIN" 90} bash "$BOOT" 2>&1
}

# --- the binary is absent ---------------------------------------------------

test_an_absent_herdr_binary_is_reported_as_missing() {
  local out clean
  clean=$(fm_herdr_path_without_binary herdr)
  out=$(PATH="$clean" run_boot)
  assert_contains "$out" "MISSING: herdr" \
    "startup said nothing about an absent herdr; the host would pass and then dispatch nothing"
  pass "startup: an absent herdr binary is reported as a missing tool"
}

test_the_missing_line_carries_an_install_command() {
  local out clean
  clean=$(fm_herdr_path_without_binary herdr)
  out=$(PATH="$clean" run_boot)
  # The contract every other tool follows: MISSING: <tool> (install: <command>).
  printf '%s\n' "$out" | grep -qE 'MISSING: herdr \(install: .+\)' \
    || fail "the herdr MISSING line has no install command; the captain cannot act on it"
  pass "startup: the herdr MISSING line carries an install command, like every other tool"
}

# Assert the install command RESOLVES; never invoke the installer.
#
# The first version of this case ran `fm-bootstrap.sh install herdr`, which
# reaches `eval "brew install herdr"`. A recording brew shim caught it:
# `FAKE-BREW-INVOKED: install herdr`. CI runs every tests/*.test.sh on
# ubuntu-latest with linuxbrew on PATH, so a test would have installed a package
# on the runner - a test that changes the machine it runs on is not a test.
test_install_knows_how_to_install_herdr() {
  local cmd
  # Source the script's own resolver rather than driving the install path.
  cmd=$(FM_BOOTSTRAP_LIB_ONLY=1 bash -c '. "$1"; install_cmd herdr' _ "$BOOT" 2>/dev/null || true)
  [ -n "$cmd" ] || fail "bootstrap has no install command for herdr; it can report it missing but not fix it"
  case "$cmd" in
    *herdr*) : ;;
    *) fail "the herdr install command does not mention herdr: '$cmd'" ;;
  esac
  pass "startup: bootstrap resolves an install command for herdr (without running it)"
}

# The guard that keeps it that way: nothing in this suite may reach a package
# manager. Proven with a recording shim rather than trusted.
test_no_case_here_invokes_a_package_manager() {
  local shim log out
  shim="$TMP_ROOT/pkgshim"; mkdir -p "$shim"
  log="$TMP_ROOT/pkg.log"; : > "$log"
  for tool in brew apt-get npm; do
    # shellcheck disable=SC2016  # the shim's own $0/$* must reach it unexpanded
    printf '#!/usr/bin/env bash\nprintf "INVOKED: %%s %%s\\n" "$(basename "$0")" "$*" >> "%s"\nexit 0\n' "$log" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Output is irrelevant here; what matters is that the log stays empty.
  PATH="$shim:$PATH" run_boot >/dev/null
  if [ -s "$log" ]; then
    fail "a startup case invoked a package manager: $(head -1 "$log")"
  fi
  pass "startup: detection never reaches a package manager - a test must not change the host"
}

# --- the binary is there but no server is running ---------------------------

# A different problem with a different fix. `brew install herdr` does not help
# someone whose server simply is not running.
test_an_unreachable_server_is_its_own_problem_line() {
  local fb out
  fb=$(fm_herdr_fake_server "$TMP_ROOT/stopped")
  out=$(PATH="$fb:$PATH" HERDR_SERVER=stopped run_boot)
  assert_contains "$out" "NEEDS_HERDR_SERVER" \
    "an installed herdr with no running server was not reported at all"
  assert_not_contains "$out" "MISSING: herdr" \
    "an installed herdr was reported as missing; that sends the captain to reinstall it"
  pass "startup: an installed herdr with no server is its own problem line, not a MISSING"
}

test_the_server_line_says_how_to_fix_it() {
  local fb out line
  fb=$(fm_herdr_fake_server "$TMP_ROOT/stopped2")
  out=$(PATH="$fb:$PATH" HERDR_SERVER=stopped run_boot)
  line=$(printf '%s\n' "$out" | grep 'NEEDS_HERDR_SERVER' | head -1)
  case "$line" in
    *herdr*) : ;;
    *) fail "the server problem line does not say what to run: '$line'" ;;
  esac
  pass "startup: the server problem line names the fix"
}

# --- a healthy host stays silent --------------------------------------------

# Silence is the contract: bootstrap prints one line per problem and nothing
# otherwise. A herdr check that chatters on a healthy host would be ignored.
test_a_reachable_server_says_nothing() {
  local fb out
  fb=$(fm_herdr_fake_server "$TMP_ROOT/running")
  out=$(PATH="$fb:$PATH" HERDR_SERVER=running run_boot)
  assert_not_contains "$out" "MISSING: herdr" "a present herdr was reported missing"
  assert_not_contains "$out" "NEEDS_HERDR_SERVER" "a running server was reported as stopped"
  pass "startup: a reachable herdr server produces no line at all"
}

# --- the captain's own startup context --------------------------------------

# A restarted supervisor is shown the fleet and taught the lifecycle. Showing it
# only tmux means it sees an EMPTY fleet while herdr crew are live, and teaches
# it to expect a tmux window that spawn no longer creates.
# Behavioural, not a grep: run the real hook against a fake herdr holding one
# named agent and assert the agent appears in the context the captain is handed.
# A source grep would pass on a mention of herdr in a comment.
test_the_captain_digest_inventories_herdr() {
  local fb fm out ctx
  fb=$(fm_herdr_fake_server "$TMP_ROOT/digest")
  fm="$TMP_ROOT/digest-home"; mkdir -p "$fm/data" "$fm/state"
  printf 'demo [no-mistakes] - a demo project\n' > "$fm/data/projects.md"
  : > "$fm/data/secondmates.md"
  printf -- '- an item\n' > "$fm/data/backlog.md"
  out=$(printf '%s' '{"source":"startup","cwd":"/tmp/x","session_id":"sess-h9"}' \
    | PATH="$fb:$PATH" HERDR_AGENTS="archify-leak-fixes" FIRSTMATE_ROLE=captain \
      FM_HOME="$fm" FM_CTX_WINDOW=h9test ${TIMEOUT_BIN:+"$TIMEOUT_BIN" 30} bash "$ROOT/bin/fm-captain-bootstrap.sh") \
    || fail "the captain hook did not exit 0"
  ctx=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
  assert_contains "$ctx" "archify-leak-fixes" \
    "a live herdr agent is missing from the captain's boot context; a restart is shown an empty fleet"
  pass "startup: the captain digest lists live herdr agents"
}

# THE DEFECT THIS FREEZES. The digest pulled names out of `"agent_name":"..."`,
# a key herdr 0.8.2's AgentInfo does not have, so the primary regex always came
# back empty and the pane-id fallback silently became the whole answer: the
# captain's restart digest read `herdr: wM:p9, wM:pA` - the opaque ids the whole
# <project>-<work> naming convention exists to remove. The readable name lives on
# the agent's TAB, and a pane id is a LAST RESORT that has to say so.
test_the_digest_falls_back_to_a_pane_id_only_explicitly() {
  local fb fm out ctx
  fb=$(fm_herdr_fake_server "$TMP_ROOT/unnamed")
  fm="$TMP_ROOT/unnamed-home"; mkdir -p "$fm/data" "$fm/state"
  printf 'demo [no-mistakes] - a demo project\n' > "$fm/data/projects.md"
  : > "$fm/data/secondmates.md"
  printf -- '- an item\n' > "$fm/data/backlog.md"
  out=$(printf '%s' '{"source":"startup","cwd":"/tmp/x","session_id":"sess-h9b"}' \
    | PATH="$fb:$PATH" HERDR_AGENTS="archify-leak-fixes" HERDR_UNNAMED_AGENTS="stray" \
      FIRSTMATE_ROLE=captain FM_HOME="$fm" FM_CTX_WINDOW=h9btest \
      ${TIMEOUT_BIN:+"$TIMEOUT_BIN" 30} bash "$ROOT/bin/fm-captain-bootstrap.sh") \
    || fail "the captain hook did not exit 0"
  ctx=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
  assert_contains "$ctx" "archify-leak-fixes" \
    "the named agent lost its name to the fallback"
  assert_contains "$ctx" "unnamed:" \
    "a nameless pane was listed as a bare id, which reads like a name"
  pass "startup: an unnamed pane is marked as such, never passed off as a name"
}

test_the_captain_digest_teaches_the_herdr_lifecycle() {
  local body
  body=$(grep -vE '^[[:space:]]*#' "$ROOT/bin/fm-captain-bootstrap.sh")
  case "$body" in
    *"opens tmux window fm-<id> in session 'firstmate'"*)
      fail "the digest still teaches the tmux spawn lifecycle that no longer happens" ;;
  esac
  pass "startup: the captain digest teaches the lifecycle the fleet actually runs"
}

test_an_absent_herdr_binary_is_reported_as_missing
test_the_missing_line_carries_an_install_command
test_install_knows_how_to_install_herdr
test_no_case_here_invokes_a_package_manager
test_an_unreachable_server_is_its_own_problem_line
test_the_server_line_says_how_to_fix_it
test_a_reachable_server_says_nothing
test_the_captain_digest_inventories_herdr
test_the_digest_falls_back_to_a_pane_id_only_explicitly
test_the_captain_digest_teaches_the_herdr_lifecycle
