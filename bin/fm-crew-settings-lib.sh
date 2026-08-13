#!/usr/bin/env bash
# fm-crew-settings-lib.sh - the single owner of the .claude/settings.local.json
# firstmate writes into a claude crewmate's worktree.
#
# The file carries two independent guarantees that MUST ride in the same JSON
# document, because it is written once by a single redirect: a second writer
# would truncate whatever the first one put there.
#
#   1. The semantic busy-state hooks and the turn-end notification, under the
#      contract owned by bin/fm-busy-lib.sh. UserPromptSubmit opens a turn;
#      Stop (normal completion), StopFailure (API-error turn end), and
#      SessionEnd (process shutdown) all close it, so an abnormal end can never
#      leave a stale busy record. Claude fires no hook for a manual interrupt:
#      fm-control preserves the adapter-owned state, while the legacy fm-send
#      --key Escape path records idle/fm-interrupt. Stop also touches the
#      turn-end file, which is how a claude crewmate tells the watcher its turn
#      ended; losing it blinds supervision. Every hook command tolerates a
#      refused event (|| true) so a stale-gen writer can never break Claude's
#      own lifecycle.
#   2. The merge block. A crewmate launches with --dangerously-skip-permissions,
#      so allow/deny rules it could simply bypass are not the control here;
#      permissions.ask is, because an unattended crewmate has no approver and an
#      "ask" it cannot answer is a stop. The crewmate can still push its branch
#      and open a PR - those verbs are deliberately not gated. Landing is the
#      captain's, per AGENTS.md section 1's never-merge-without-explicit-word
#      boundary.
#
# Rule syntax is Claude Code's, and it is strict: ":*" means prefix match and is
# only legal at the very END of the pattern. Anywhere else the rule is not a
# soft warning - Claude Code reports it as invalid and SKIPS it, so a malformed
# rule silently removes the very protection it was written to add while also
# stopping every fresh spawn on a blocking settings dialog. Use a bare "*" for
# wildcard matching in the middle of a pattern.
#
# The gh api rules are matched against the whole command line, so they stay
# narrow on purpose: they name the merge ENDPOINTS rather than gating "gh api"
# wholesale, which would break the ordinary reads a crewmate needs to do its
# job. See tests/fm-crew-settings.test.sh for the enforced invariants.
#
# Rules are per-executable, because a rule is a prefix match on the literal
# argv[0] token: "Bash(gh pr merge:*)" cannot match "gh-axi pr merge". gh-axi is
# the GitHub tool the briefs hand a crewmate (AGENTS.md, bin/fm-brief.sh) and the
# one bin/fm-pr-merge.sh lands PRs with, so it needs its own rule or the most
# likely merge command is the one left open.
#
# Known residual: every rule is matched against the top-level command string, so
# the block covers DIRECT forge merge invocations and nothing else. Three shapes
# fall outside it. A wrapper that reaches a merge verb in a subprocess matches no
# pattern - including bin/fm-pr-merge.sh, the entrypoint AGENTS.md section 7 names
# for every task PR merge, and equally any bash -c, script, or make target. So
# does a GraphQL merge whose query text never reaches the command line, read from
# a file or piped in on stdin. Local landing carries no rule at all, because the
# list gates forge merge verbs rather than git: bin/fm-merge-local.sh and a bare
# git merge --ff-only are ungated. Command-line rules cannot see any of that, so
# this is a boundary by construction rather than an oversight, and the rule list
# must not be read as full coverage; AGENTS.md section 1's captain-only landing
# boundary is what covers the rest.

# Print the merge-block permission rules as a JSON array.
# Kept as one canonical list so the rules and their regression test cannot drift.
fm_crew_merge_block_rules() {
  printf '%s' '["Bash(gh pr merge:*)","Bash(gh-axi pr merge:*)","Bash(gh api *pulls/*/merge*)","Bash(gh api *repos/*/merges*)","Bash(gh api graphql*mergePullRequest*)","Bash(tk-feature land:*)","Bash(tk-feature-land:*)"]'
}

# Quote a string as one literal POSIX shell word.
# Every value below is interpolated into a command line the hook shell runs, and
# none is guaranteed benign: the turn-end path and the state directory come from
# FM_HOME/FM_STATE_OVERRIDE, and the task id is caller-supplied.
fm_crew_shell_quote() {
  local s=$1 q="'" esc="'\\''"
  printf "'%s'" "${s//$q/$esc}"
}

# Escape a string for use inside a JSON double-quoted scalar.
# An unescaped quote or backslash makes the whole document invalid, and Claude
# Code then rejects the file - losing the busy-state hooks AND the merge block at
# once, which is the failure this library exists to prevent.
fm_crew_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Print the complete settings.local.json for a claude crewmate worktree.
#   $1 - absolute path to the task's turn-end file
#   $2 - absolute path to bin/fm-busy-event.sh
#   $3 - absolute path to the home's state directory
#   $4 - task id
#   $5 - busy-state generation token
fm_crew_settings_local_json() {
  local turnend=$1 busy_event=$2 state=$3 id=$4 gen=$5
  local prefix suffix j_submit j_stop j_stopfail j_sessionend
  prefix="$(fm_crew_shell_quote "$busy_event") apply $(fm_crew_shell_quote "$state") $(fm_crew_shell_quote "$id")"
  suffix="--gen $(fm_crew_shell_quote "$gen") --source claude-hook"
  j_submit=$(fm_crew_json_escape "$prefix busy $suffix --event user-prompt-submit 2>/dev/null || true")
  j_stop=$(fm_crew_json_escape "touch $(fm_crew_shell_quote "$turnend"); $prefix idle $suffix --event stop 2>/dev/null || true")
  j_stopfail=$(fm_crew_json_escape "$prefix idle $suffix --event stop-failure 2>/dev/null || true")
  j_sessionend=$(fm_crew_json_escape "$prefix idle $suffix --event session-end 2>/dev/null || true")
  printf '%s\n' "{\"hooks\":{\"UserPromptSubmit\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_submit\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_stop\"}]}],\"StopFailure\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_stopfail\"}]}],\"SessionEnd\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$j_sessionend\"}]}]},\"permissions\":{\"ask\":$(fm_crew_merge_block_rules)}}"
}
