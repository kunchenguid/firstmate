#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file is an append-only event log, not current-state evidence.
# These cases reconcile semantic busy state, backend liveness and publication
# proof with that log over disposable repositories and fake backend transports.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
# Stamp origin/main at the current HEAD so a later ship done: is not refused
# solely for being a fixture with no remote-tracking refs; tests that need an
# unpreserved named head point those refs at a different commit.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse HEAD)"
}

# Fake forge and runtime transports answer each case's controlled native reads.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "api graphql")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh\n' >> "$FM_FAKE_PR_READ_LOG"
    number=1
    for arg in "$@"; do
      case "$arg" in
        number=*) number=${arg#number=} ;;
      esac
    done
    case "$number" in *[!0-9]*|'') number=1 ;; esac
    state=${FM_FAKE_PR_STATE:-MERGED}
    merged=${FM_FAKE_PR_MERGED:-true}
    eval "state=\${FM_FAKE_PR_${number}_STATE:-\$state}"
    eval "merged=\${FM_FAKE_PR_${number}_MERGED:-\$merged}"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'state=%s\nmerged=%s\n' "$state" "$merged"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pr view")
    [ -z "${FM_FAKE_PR_READ_LOG:-}" ] || printf 'gh-axi\n' >> "$FM_FAKE_PR_READ_LOG"
    [ "${FM_FAKE_PR_READ_FAIL:-0}" = 1 ] && exit 1
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-1}" "${FM_FAKE_PR_STATE_AXI:-merged}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/glab" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "mr view")
    [ -z "${FM_FAKE_GLAB_READ_LOG:-}" ] || printf '%s|%s\n' "${GITLAB_HOST:-}" "$*" >> "$FM_FAKE_GLAB_READ_LOG"
    [ "${FM_FAKE_GLAB_READ_FAIL:-0}" = 1 ] && exit 1
    printf '{"state":"%s"}\n' "${FM_FAKE_GLAB_STATE:-merged}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/gerrit-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    [ -z "${FM_FAKE_GERRIT_READ_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GERRIT_READ_LOG"
    [ "${FM_FAKE_GERRIT_READ_FAIL:-0}" = 1 ] && exit 1
    # url defaults to null, the shape a server whose gerrit.canonicalWebUrl is
    # unset returns, so every case here reads a record that carries no URL.
    printf '{"ok":true,"op":"show","changes":[{"change":%s,"subject":"fixture change","status":"%s","url":%s}]}\n' \
      "${FM_FAKE_GERRIT_CHANGE:-${2:-0}}" "${FM_FAKE_GERRIT_STATUS:-MERGED}" \
      "${FM_FAKE_GERRIT_URL_JSON:-null}"
    exit 0 ;;
esac
exit 1
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
# FM_FAKE_TMUX_MISSING: the window is authoritatively gone - every addressed
# call fails, but the session inventory still answers successfully and simply
# omits the window, which is what proves absence.
# FM_FAKE_TMUX_UNREADABLE: tmux itself cannot answer - it fails to execute (a
# trimmed PATH) or errors non-definitively - so even the inventory fails, with
# a message that is NOT one of the definitive no-session/no-server/no-socket
# responses that fm_backend_tmux_agent_state owns as death.
[ "${FM_FAKE_TMUX_UNREADABLE:-0}" = 1 ] && { printf 'no current client\n' >&2; exit 1; }
case "${1:-}" in
  list-windows)
    # A successful but empty inventory: it omits the crew's window, so absence
    # is proved by the answer rather than by an addressed call failing. Only
    # reached once display-message has already failed.
    ;;
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        [ "${FM_FAKE_HERDR_READ_FAIL:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
      get)
        if [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ]; then
          printf '{"error":{"code":"pane_not_found","message":"no such pane"}}\n'
          exit 1
        fi
        printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
        exit 0 ;;
      process-info)
        # The process-level view a registration is verified against (#4115):
        # `agent` puts a live claude in the foreground, `shell` a bare zsh whose
        # pid is the test script itself (a real, long-lived process with no
        # harness descendant, so the adapter's real process-table walk finds
        # it), and anything else answers nothing (unreadable).
        pane=""; args=("$@"); for ((i=0; i<${#args[@]}; i++)); do [ "${args[$i]}" = --pane ] && pane=${args[$((i+1))]:-}; done
        case "${FM_FAKE_HERDR_PROCESS:-agent}" in
          agent) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
          shell) printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}\n' "$pane" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" "${FM_FAKE_HERDR_SHELL_PID:-$PPID}" ;;
        esac
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        if [ "${FM_FAKE_HERDR_HUSK:-0}" = 1 ]; then
          printf '{"error":{"code":"agent_not_found","message":"no agent in pane"}}\n'
          exit 0
        fi
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/gh-axi" "$fb/glab" "$fb/gerrit-axi" "$fb/tmux" "$fb/herdr"
  printf '%s\n' "$fb"
}

# Run the helper for one case dir. FM_FAKE_* backend controls are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_TMUX_UNREADABLE=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_READ_FAIL=0
  FM_FAKE_HERDR_HUSK=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_HERDR_PROCESS=agent
  FM_FAKE_HERDR_SHELL_PID=$$
  FM_FAKE_PR_STATE=MERGED
  FM_FAKE_PR_MERGED=true
  FM_FAKE_PR_READ_FAIL=0
  FM_FAKE_PR_READ_LOG=
  FM_FAKE_PR_STATE_AXI=merged
  FM_FAKE_GLAB_STATE=merged
  FM_FAKE_GLAB_READ_FAIL=0
  FM_FAKE_GLAB_READ_LOG=
  FM_FAKE_GERRIT_STATUS=MERGED
  FM_FAKE_GERRIT_CHANGE=
  FM_FAKE_GERRIT_URL_JSON=
  FM_FAKE_GERRIT_READ_FAIL=0
  FM_FAKE_GERRIT_READ_LOG=
  unset FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
  export FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING FM_FAKE_TMUX_UNREADABLE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_READ_FAIL FM_FAKE_HERDR_HUSK FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_HERDR_PROCESS FM_FAKE_HERDR_SHELL_PID
  export FM_FAKE_PR_STATE FM_FAKE_PR_MERGED FM_FAKE_PR_READ_FAIL FM_FAKE_PR_READ_LOG FM_FAKE_PR_STATE_AXI
  export FM_FAKE_GLAB_STATE FM_FAKE_GLAB_READ_FAIL FM_FAKE_GLAB_READ_LOG
  export FM_FAKE_GERRIT_STATUS FM_FAKE_GERRIT_CHANGE FM_FAKE_GERRIT_URL_JSON
  export FM_FAKE_GERRIT_READ_FAIL FM_FAKE_GERRIT_READ_LOG
  export FM_FAKE_PR_47_STATE FM_FAKE_PR_47_MERGED FM_FAKE_PR_48_STATE FM_FAKE_PR_48_MERGED
}

seed_retired_pr_receipt() {  # <state> <id> <url>
  local state=$1 id=$2 url=$3 template provider host path number
  template="$ROOT/bin/fm-pr-poll.sh"
  fm_pr_url_parse "$url" || fail "retirement fixture URL was invalid"
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$state" "$id" "$provider" "$url" "$host" "$path" "$number" "$template" \
    || fail "could not prepare retirement fixture"
  fm_pr_poll_publish_prepared || fail "could not publish retirement fixture"
  fm_pr_poll_snapshot_capture "$state" "$id" "$template" || fail "could not snapshot retirement fixture"
  fm_pr_poll_retirement_publish "$state" "$id" "$template" merged \
    || fail "could not publish retirement receipt"
}

# A ship done: whose named head lives only in the disposable copy is not
# current-state done (issue 4768). The worker's claim stays a blocked
# preservation failure rather than finished-and-safe.
test_unpushed_ship_done_is_blocked() {
  reset_fakes
  local d sha out
  d=$(new_case unpushed-done)
  make_repo_on_branch "$d/wt" fm/unpushed
  git -C "$d/wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$d/wt" rev-parse HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/unpushed.meta" \
    "window=fm:fm-unpushed" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' \
    > "$d/state/unpushed.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" unpushed
  out=$(run_crew_state "$d" unpushed)
  assert_contains "$out" "state: blocked" "unpushed ship done: must not read as done"
  assert_contains "$out" "source: status-log" "preservation refusal stays status-log sourced"
  assert_contains "$out" "named head $sha is unreachable outside the worker copy" \
    "refusal must name the unpushed head"
  assert_not_contains "$out" "state: done" "unpushed ship done: must not remain done"
  pass "unpushed ship done: is current-state blocked"
}

# Fleet snapshot hands crew-state a captured meta copy outside state/. The
# poll's merge marker stays in the live state dir, so a squash-merged PR whose
# branch fleet sync pruned still reads done there.
test_merged_pr_reads_done_under_captured_meta() {
  reset_fakes
  local d out
  d=$(new_case merged-captured)
  make_repo_on_branch "$d/wt" fm/merged
  git -C "$d/wt" commit -q --allow-empty -m 'squash-merged fix, branch pruned'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/merged.meta" \
    "window=fm:fm-merged" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude" "pr=https://github.com/o/r/pull/7"
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com o/r 7 \
    > "$d/state/merged.pr-poll-merge-notified"
  chmod 600 "$d/state/merged.pr-poll-merge-notified"
  printf 'done: PR https://github.com/o/r/pull/7\n' > "$d/state/merged.status"
  mkdir -p "$d/captured"
  cp "$d/state/merged.meta" "$d/captured/merged.meta"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" merged
  out=$(FM_CREW_STATE_META_OVERRIDE="$d/captured/merged.meta" run_crew_state "$d" merged)
  assert_contains "$out" "state: done" "recorded merged PR must read done under a captured meta"
  assert_not_contains "$out" "state: blocked" "merge marker must be read from the live state dir"
  pass "recorded merged PR reads done under the fleet snapshot's captured meta"
}


test_moved_remote_branch_without_named_head_is_blocked() {
  reset_fakes
  local d main_sha fix_sha out
  d=$(new_case moved-branch)
  make_repo_on_branch "$d/wt" fm/moved
  main_sha=$(git -C "$d/wt" rev-parse refs/remotes/origin/main)
  git -C "$d/wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/moved.meta" \
    "window=fm:fm-moved" "worktree=$d/wt" "project=$d/wt" \
    "kind=ship" "mode=direct-PR" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/8\n' > "$d/state/moved.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" moved
  out=$(run_crew_state "$d" moved)
  assert_contains "$out" "state: blocked" "a moved remote branch must not count as preserved"
  assert_contains "$out" "named head $fix_sha is unreachable outside the worker copy" \
    "refusal must name the missing fix, not the moved branch"
  pass "moved remote branch without the named head is current-state blocked"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A launch pinned at the fm-spawn seed (no hook has posted yet) whose pane
# renders a recognized interactive prompt must read unknown, never working -
# this is the load-bearing link the launch-prompt backstop depends on:
# fm-watch.sh's pause_state_class absorbs a stale pane as "provably working"
# whenever THIS script reports `state: working · source: pane`, so if this
# authoritative read still said working, the watcher would silently swallow
# the wake even though bin/fm-busy-lib.sh's own classifier had already flipped
# to unknown launch-prompt. crew_busy_verdict must therefore capture a real
# tail for every harness, not only grok, so the backstop's own tail-based
# check ever runs here at all.
test_no_run_launch_prompt_parked_is_not_working() {
  reset_fakes
  local d; d=$(new_case launch-prompt)
  make_repo_on_branch "$d/wt" fm/feat-lp
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-lp.meta" "window=fm:fm-feat-lp" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Quick safety check: Is this a project you created or one you trust? ...
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
  export FM_FAKE_BUSY_TEXT
  # arm only, never apply: the launch turn has never advanced past the seed
  # fm-spawn.sh writes at spawn time.
  "$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-lp >/dev/null
  local out; out=$(run_crew_state "$d" feat-lp)
  assert_not_contains "$out" "state: working" "a launch parked on its trust dialog must never read working"
  assert_contains "$out" "state: unknown" "a parked launch reads unknown, not busy or idle"
  assert_contains "$out" "launch-prompt" "the unknown verdict names the launch-prompt backstop as its source"
  pass "a launch parked on a recognized interactive prompt never reads working, closing the absorb path a stale watcher poll depends on"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-09 G7 stale-claim incident): a herdr CLI that errors or
# stalls under load made pane_readable's capture fail, and the fallback read
# that single failure as "backend target gone" - text the stale sweep matches
# as positive death - so a busy box briefly scored dozens of live claims dead.
# The reader must separate the two outcomes: only a successful herdr answer
# proving the pane absent may say gone; a CLI that failed to answer is unknown
# and unreachable, never death.
test_no_run_herdr_cli_failure_reads_unreachable_not_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr cli-failure fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-cli-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-cli
  make_fakebin "$d" >/dev/null
  # A herdr whose server is up but whose endpoint calls cannot answer at all:
  # every pane/agent invocation exits non-zero, the busiest-box form of a
  # stalled CLI (capture and pane get alike fail). `status` still answers so
  # the reader probes the endpoint instead of waiting out a server start.
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] && { printf '{"server":{"running":true}}\n'; exit 0; }
exit 1
SH
  chmod +x "$d/fakebin/herdr"
  fm_write_meta "$d/state/feat-herdr-cli.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-herdr-cli)
  assert_contains "$out" "state: unknown" "a failed herdr CLI must stay unknown"
  assert_contains "$out" "source: none" "a failed herdr CLI has no state source"
  assert_contains "$out" "backend unreachable" "a failed herdr CLI must read as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "a failed herdr CLI is not positive death evidence"
  pass "a herdr CLI that fails to answer reads unknown/unreachable, never gone"
}

# Decision follow-up (2026-09-05 review): an `alive` endpoint answer is
# authoritative even when the heavy scrollback read failed - the live state is
# classified by the normal flow, never discarded as unreachable.
test_no_run_herdr_alive_with_failed_read_stays_live() {
  command -v jq >/dev/null 2>&1 || { pass "herdr alive/read-fail test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-alive-readfail)
  make_repo_on_branch "$d/wt" fm/feat-herdr-alive
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-alive.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_TMUX_MISSING=1
  # The 200-line scrollback read fails while the cheap pane get / agent get
  # pair answers: the pane is present and its agent is working.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr-alive)
  assert_contains "$out" "state: working" "an alive endpoint with a failed scrollback read stays live"
  assert_not_contains "$out" "backend unreachable" "an authoritative alive answer is never unreachable"
  assert_not_contains "$out" "backend target gone" "an authoritative alive answer is never death"
  pass "an alive endpoint whose scrollback read failed stays working"
}

# Issue #4115: a registration Herdr kept after its Pi exited to a plain shell is
# not an agent. The recovery-grade read proves the process level, so the
# shell-only pane reads as positive agent-gone evidence, never as a live agent
# or as unreachable.
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-registration test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-reg)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale)
  assert_contains "$out" "state: unknown" "a stale registration over a shell-only pane is not a live state"
  assert_contains "$out" "backend target gone" "a stale registration over a shell-only pane must read as positive agent-gone evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the agent-gone reason must name the remaining shell"
  assert_not_contains "$out" "backend unreachable" "a readable shell-only pane is not unreachable"
  pass "herdr stale registration over a shell-only pane reads agent gone, not alive"
}

# The busy half of the same defect: a `working` record Herdr kept after the
# agent was killed mid-turn must never make a shell-only pane read as working.
test_no_run_herdr_stale_working_record_is_never_busy() {
  command -v jq >/dev/null 2>&1 || { pass "herdr stale-working test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-stale-working)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stale-working
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stale-working.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=pi"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  FM_FAKE_HERDR_PROCESS=shell
  local out; out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_not_contains "$out" "state: working" "a stale working record over a shell-only pane must never read busy"
  assert_not_contains "$out" "herdr-native" "the native busy verdict must not be trusted for a shell-only pane"
  # The control: the same record with a live harness in the foreground is busy.
  FM_FAKE_HERDR_PROCESS=agent
  out=$(run_crew_state "$d" feat-herdr-stale-working)
  assert_contains "$out" "state: working" "the same working record with a live harness process must still read working"
  pass "herdr stale working record never reports a shell-only pane busy"
}

# Decision follow-up (2026-09-05 review): a husk pane (pane present,
# agent_not_found) is authoritative death evidence - it keeps the gone-class
# text so the stale sweep may still reclaim it, never unknown/unreachable.
test_no_run_herdr_husk_dead_still_reads_gone() {
  command -v jq >/dev/null 2>&1 || { pass "herdr husk test skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-husk-dead)
  make_repo_on_branch "$d/wt" fm/feat-herdr-husk
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-husk.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_TMUX_MISSING=1
  # The pane exists and answers pane get, but no agent is registered in it,
  # and the scrollback read fails besides.
  FM_FAKE_HERDR_READ_FAIL=1
  FM_FAKE_HERDR_HUSK=1
  local out; out=$(run_crew_state "$d" feat-herdr-husk)
  assert_contains "$out" "state: unknown" "a husk pane has no live current state"
  assert_contains "$out" "backend target gone" "a husk pane keeps its gone-class death evidence"
  assert_contains "$out" "agent gone, pane shell remains" "the husk verdict names what actually died"
  assert_not_contains "$out" "backend unreachable" "a husk pane is not an unreachable backend"
  pass "a husk pane (agent gone) still reads gone for reclaim"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew waiting on a long-running foreground
# native check is not generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # The crew's semantic busy record remains authoritative while not streaming.
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  printf 'The release window opens tomorrow.\n\n' >> "$d/state/feat-pause.status"
  out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "continuation prose and trailing blanks preserve the pause"
  assert_contains "$out" "holding for the upstream tool release" "multiline pause preserves its declared reason"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}






test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  assert_contains "$out" "backend target gone" "an inventory that omits the window is positive death evidence"
  pass "dead window ignores stale status log"
}

# Regression (2026-09 G7 stale-claim incident, tmux half): the default backend
# reached the same false-death path as herdr. A tmux that cannot answer at all
# - a trimmed PATH, or any non-definitive error - made every live crew report
# "backend target gone", the text the stale sweep matches as positive death.
# Absence must be proved by tmux's own answer: a window inventory that omits
# the recorded window, or one of its definitive no-session/no-server/no-socket
# responses. Anything else is a tmux that failed to answer: unknown, never
# death. (A socket-connection error is deliberately NOT in this test's scope -
# fm_backend_tmux_agent_state classifies it as `missing` so fm-bootstrap and
# fm-session-start can respawn after a genuine server death.)
test_no_run_tmux_unreadable_reads_unreachable_not_gone() {
  reset_fakes
  local d; d=$(new_case tmux-unreadable)
  make_repo_on_branch "$d/wt" fm/feat-tmux-unread
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-tmux-unread.meta" "window=fm:fm-feat-tmux-unread" \
    "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-tmux-unread.status"
  FM_FAKE_TMUX_UNREADABLE=1
  local out; out=$(run_crew_state "$d" feat-tmux-unread)
  assert_contains "$out" "state: unknown" "an unreadable tmux must stay unknown"
  assert_contains "$out" "source: none" "an unreadable tmux has no state source"
  assert_contains "$out" "backend unreachable" "an unreadable tmux reads as unreachable, not gone"
  assert_not_contains "$out" "backend target gone" "an unreadable tmux is not positive death evidence"
  pass "a tmux that fails to answer reads unknown/unreachable, never gone"
}

# A scout uses its semantic busy record like other workers.
test_scout_reads_semantic_busy_state() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout reads its semantic busy state"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # An idle pane with no fresh semantic busy record is not working.
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}


test_unpushed_ship_done_is_blocked
test_merged_pr_reads_done_under_captured_meta
test_moved_remote_branch_without_named_head_is_blocked
test_no_run_busy_pane
test_no_run_launch_prompt_parked_is_not_working
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_cli_failure_reads_unreachable_not_gone
test_no_run_herdr_alive_with_failed_read_stays_live
test_no_run_herdr_husk_dead_still_reads_gone
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_no_run_tmux_unreadable_reads_unreachable_not_gone
test_scout_reads_semantic_busy_state
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_not_provably_working_when_stopped
test_usage_error
test_no_run_herdr_stale_registration_over_shell_reads_agent_gone
test_no_run_herdr_stale_working_record_is_never_busy

echo "all fm-crew-state tests passed"
