#!/usr/bin/env bash
# GATE h5 - a LIVE herdr pane, end to end through the real library.
#
# WHY THIS EXISTS. Every other herdr case here runs over a fakebin, and a fake
# answers whatever it was written to answer. The whole claim of the herdr driver
# is that delivery is ACKNOWLEDGED - `agent prompt --wait` returns only once the
# agent has consumed the prompt - and no stub can prove that. So one gate talks
# to a real herdr server and does the whole loop:
#
#   workspace -> new_tab -> shell-ready -> run -> read -> cwd -> label -> close
#
# plus, when a real agent harness is available, the acknowledged send round-trip
# that is the reason this seam exists at all.
#
# IT NEVER TOUCHES THE FLEET. The gate makes its OWN throwaway workspace, does
# everything inside it, and closes it again. It never spawns into a project
# workspace and never addresses a pane it did not create.
#
# NO SERVER -> LOUD SKIP, NOT A QUIET PASS. On a machine with no herdr server
# (CI, a headless box) this cannot run. It says so on stderr and exits 0 rather
# than pretending the herdr direction was proven, because a gate that reports
# green without touching a multiplexer is worse than one that reports nothing.
set -u

# This gate needs the REAL binary; tests/lib.sh otherwise shims it away so no
# suite can touch the captain's live server by accident.
FM_TEST_ALLOW_LIVE_HERDR=1

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"


# A live gate that quietly skips is indistinguishable from a proven one once the
# result reaches a ledger. FM_TEST_REQUIRE_LIVE=1 makes the skip a FAILURE, so a
# verifier can demand real proof rather than accepting a green that means
# "nothing ran here". CI has no herdr server and does not set it.
if [ "${FM_TEST_REQUIRE_LIVE:-0}" = 1 ] && ! fm_herdr_up; then
  printf 'not ok - FM_TEST_REQUIRE_LIVE=1 but no herdr server is reachable; this gate cannot be proven here\n' >&2
  exit 1
fi
if ! fm_herdr_up; then
  printf 'SKIP - GATE h5 needs a live herdr server; none is reachable here.\n' >&2
  printf '  The herdr direction is NOT proven by this run. Run it on a machine\n' >&2
  printf '  with a herdr server up to exercise it; the fakes in fm-mux-h1..h4\n' >&2
  printf '  cover the branches a live run cannot reach on demand.\n' >&2
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-mux-h5)
WORKDIR="$TMP_ROOT/work"; mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd -P)
WS_LABEL="fm-gate-h5-$$"
WS=""
TARGET=""

cleanup() {
  [ -z "$TARGET" ] || fm_herdr_close "$TARGET" 2>/dev/null || true
  [ -z "$WS" ] || herdr workspace close "$WS" >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- scope: a real workspace, resolved and created ---------------------------

test_live_scope_creates_and_resolves_a_workspace() {
  WS=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for "$WS_LABEL" "$WORKDIR") \
    || fail "scope could not create a workspace on a live server"
  [ -n "$WS" ] || fail "scope returned an empty workspace id"
  # Resolving again must find the SAME one, not make a second.
  local again
  again=$(FM_HERDR_WORKSPACE='' fm_herdr_workspace_for "$WS_LABEL" "$WORKDIR")
  assert_eq "$again" "$WS" "a second resolve created a duplicate workspace instead of finding it"
  pass "live herdr: scope creates a real workspace by label, then finds it again ($WS)"
}

# --- the tab, scoped and named ----------------------------------------------

test_live_new_window_lands_in_that_workspace() {
  TARGET=$(fm_herdr_new_tab "$WS" "gate-h5-probe" "$WORKDIR") \
    || fail "new_window failed against a live herdr server"
  [ -n "$TARGET" ] || fail "new_window returned an empty target"
  # The tab must be IN the workspace we resolved - not wherever focus was.
  herdr tab list --workspace "$WS" 2>/dev/null | tr '{' '\n' | grep -qF '"label":"gate-h5-probe"' \
    || fail "the tab is not in the resolved workspace; it landed by focus"
  pass "live herdr: the tab is created in the resolved workspace ($TARGET)"
}

test_live_shell_readiness() {
  if ! FM_SHELL_READY_TIMEOUT=25 fm_herdr_wait_shell_ready "$TARGET" 25; then
    fail "wait_ready never got its marker back from a real herdr shell"
  fi
  pass "live herdr: wait_ready proves a real shell reached a prompt"
}

test_live_run_and_read() {
  local marker out waited
  marker="h5live$$"
  fm_herdr_run "$TARGET" "printf '%s\\n' $marker-ran" || fail "run failed against a live herdr pane"
  out=""
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    out=$(fm_herdr_read "$TARGET" 40)
    case "$out" in *"$marker-ran"*) break ;; esac
    sleep 0.25
  done
  assert_contains "$out" "$marker-ran" "read never saw the output of a command run in a real herdr pane"
  pass "live herdr: run executes in the pane and read returns what it printed"
}

test_live_cwd_tracks_the_pane() {
  local sub got waited
  sub="$WORKDIR/deeper"; mkdir -p "$sub"; sub=$(cd "$sub" && pwd -P)
  assert_eq "$(fm_herdr_cwd "$TARGET")" "$WORKDIR" "cwd did not report the pane's real directory"
  fm_herdr_run "$TARGET" "cd '$sub'"
  got=""
  waited=0
  while [ "$waited" -lt 40 ]; do
    waited=$((waited + 1))
    got=$(fm_herdr_cwd "$TARGET"); [ "$got" = "$sub" ] && break; sleep 0.25
  done
  assert_eq "$got" "$sub" "cwd did not follow a real chdir; the worktree wait would hang"
  fm_herdr_run "$TARGET" "cd '$WORKDIR'"
  pass "live herdr: cwd reports the pane's real directory and follows a chdir"
}

# --- naming, against the binary that judges it -------------------------------

# THE SEPARATOR GATE. herdr 0.8.2 rejects an agent name containing '/' with
# invalid_agent_name, so a slashed name renames nothing and leaves the pane
# unaddressable. Asserting that against the REAL binary is the only way to know;
# a fake would accept whatever it was told to.
test_live_the_convention_is_a_name_herdr_accepts() {
  local name
  name=$(fm_herdr_pane_name firstmate "fleet view")
  assert_eq "$name" "firstmate-fleet-view" "the convention did not produce <project>-<work>"
  fm_herdr_label "$TARGET" "$name"
  case $? in
    0|1) : ;;  # 0 = tab and agent named; 1 = tab named, no agent detected yet
    *) fail "the live server refused '$name' as a tab label" ;;
  esac
  herdr tab list --workspace "$WS" 2>/dev/null | tr '{' '\n' | grep -qF "\"label\":\"$name\"" \
    || fail "herdr did not actually apply the label '$name'"
  pass "live herdr: '$name' is accepted and applied by the real binary"
}

# And the shape that was there before must be rejected BY THE BINARY, not merely
# disliked by us. If herdr ever accepted a slash this case would fail and the
# convention could be revisited on evidence.
test_live_a_slashed_name_is_rejected_by_herdr() {
  local out
  out=$(herdr agent rename "$TARGET" "firstmate/fleet-view" 2>&1) && \
    fail "herdr ACCEPTED a slashed agent name; the hyphen rule rests on a false premise"
  case "$out" in
    *invalid_agent_name*|*agent_not_found*) : ;;
    *) fail "herdr rejected the slashed name for an unexpected reason: $out" ;;
  esac
  pass "live herdr: a slashed agent name is rejected by the binary itself"
}

# --- acknowledged delivery, the reason the seam exists -----------------------
#
# Needs a real agent in the pane. Skipped loudly (never silently passed) when no
# harness is available; set FM_HERDR_LIVE_AGENT=0 to skip it deliberately.
test_live_send_is_actually_consumed() {
  if [ "${FM_HERDR_LIVE_AGENT:-1}" = 0 ] || ! command -v claude >/dev/null 2>&1; then
    if [ "${FM_TEST_REQUIRE_LIVE:-0}" = 1 ]; then
      fail "FM_TEST_REQUIRE_LIVE=1 but no agent harness is available; the acknowledged send cannot be proven here"
    fi
    printf 'SKIP - the acknowledged-send case needs a real agent harness in the pane\n' >&2
    return 0
  fi
  local marker out rc=0 waited
  marker="H5ACK$$"
  fm_herdr_run "$TARGET" \
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions 'reply with exactly: READY and nothing else'"
  # Clear the trust dialog if herdr reports one, then wait for the agent to be
  # genuinely ready. herdr can report `idle` while the TUI is still booting - a
  # prompt sent then stalls - so require the composer to be on screen as well as
  # the status to have settled. This is the same "positive proof, not elapsed
  # time" discipline the shell-readiness probe uses.
  waited=0
  while [ "$waited" -lt 90 ]; do
    waited=$((waited + 1))
    if herdr agent get "$TARGET" 2>/dev/null | grep -q '"agent_status":"blocked"'; then
      fm_herdr_send_key "$TARGET" enter
    fi
    if herdr agent get "$TARGET" 2>/dev/null | grep -qE '"agent_status":"(idle|done)"' \
       && fm_herdr_read "$TARGET" 40 | grep -q 'bypass permissions'; then
      break
    fi
    sleep 1
  done
  herdr agent get "$TARGET" >/dev/null 2>&1 || fail "no agent was ever detected in the live pane"

  # THE GATE: one call that returns only once the agent has taken the prompt.
  fm_herdr_prompt "$TARGET" "reply with exactly: $marker and nothing else" || rc=$?
  # 0 = acknowledged. 4 = delivered but unacknowledged, which is still a
  # delivery - the reply check below is what actually proves it landed.
  case "$rc" in
    0|4) : ;;
    *) fail "the live send failed outright (rc=$rc); pane: $(fm_herdr_read "$TARGET" 12)" ;;
  esac
  out=""
  waited=0
  while [ "$waited" -lt 30 ]; do
    waited=$((waited + 1))
    out=$(fm_herdr_read "$TARGET" 60)
    case "$out" in *"$marker"*) break ;; esac
    sleep 1
  done
  assert_contains "$out" "$marker" \
    "the agent never produced the reply; --wait returned without the prompt being consumed"
  pass "live herdr: agent prompt --wait delivered AND the agent consumed it"
}

test_live_close_removes_the_tab() {
  fm_herdr_close "$TARGET"
  local waited=0 gone=0
  while [ "$waited" -lt 20 ]; do
    waited=$((waited + 1))
    if ! herdr pane get "$TARGET" >/dev/null 2>&1; then gone=1; break; fi
    sleep 0.25
  done
  [ "$gone" = 1 ] || fail "close did not remove the live tab"
  TARGET=""
  pass "live herdr: close tears the real tab down"
}

test_live_scope_creates_and_resolves_a_workspace
test_live_new_window_lands_in_that_workspace
test_live_shell_readiness
test_live_run_and_read
test_live_cwd_tracks_the_pane
test_live_the_convention_is_a_name_herdr_accepts
test_live_a_slashed_name_is_rejected_by_herdr
test_live_send_is_actually_consumed
test_live_close_removes_the_tab
