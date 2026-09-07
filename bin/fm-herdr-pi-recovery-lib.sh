#!/usr/bin/env bash
# fm-herdr-pi-recovery-lib.sh - pure process-topology proof shared by the two
# halves of fm-control's task-scoped stale Herdr/Pi relaunch transaction.
#
# This is not a fleet-wide liveness classifier and deliberately performs no
# mutation. Given Herdr's pane-shell pid and foreground process-group id, it
# prints one stable fingerprint only when the complete process table proves the
# exact post-Pi Treehouse shape: pane shell -> `treehouse get` -> nested shell,
# with no other descendant below the pane shell. Any malformed row, unknown
# descendant, process churn, or unrecognized shell refuses.

fm_herdr_pi_treehouse_copy_matches() {  # <project> <worktree>
  local project=${1:-} worktree=${2:-} slot pool pool_state project_common slot_common wt_top
  [ -d "$project" ] && [ -d "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  pool_state="$pool/treehouse-state.json"
  [ -f "$pool_state" ] && [ ! -L "$pool_state" ] || return 1
  wt_top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
  wt_top=$(CDPATH='' cd -- "$wt_top" 2>/dev/null && pwd -P) || return 1
  [ "$wt_top" = "$slot" ] || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" = "$slot_common" ]
}

fm_herdr_pi_nested_shell_process_fingerprint() {  # <pane-shell-pid> <foreground-pgid>
  local shell_pid=${1:-} foreground_pgid=${2:-} ps_bin rows
  case "$shell_pid:$foreground_pgid" in *[!0-9:]*) return 1 ;; esac
  [ -n "$shell_pid" ] && [ -n "$foreground_pgid" ] || return 1
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  rows=$("$ps_bin" -axo pid=,ppid=,pgid=,stat=,comm=,args= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v shell="$shell_pid" -v foreground="$foreground_pgid" '
    function base(value, count, parts) {
      sub(/^-/, "", value)
      count = split(value, parts, "/")
      return parts[count]
    }
    function is_shell(value) {
      value = base(value)
      return value == "sh" || value == "bash" || value == "zsh" || value == "dash" || value == "ksh" || value == "fish"
    }
    {
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || NF < 5 || seen[$1]++) {
        bad = 1
        next
      }
      pid = $1
      parent[pid] = $2
      group[pid] = $3
      state[pid] = $4
      command[pid] = $5
      $1 = $2 = $3 = $4 = $5 = ""
      sub(/^[[:space:]]+/, "")
      arguments[pid] = $0
      present[pid] = 1
    }
    END {
      if (bad || !present[shell] || !is_shell(command[shell]) || state[shell] !~ /^[SI]/) exit 1
      outer_children = 0
      for (pid in present) if (parent[pid] == shell) { tree = pid; outer_children++ }
      if (outer_children != 1 || base(command[tree]) != "treehouse" || state[tree] !~ /^[SI]/) exit 1
      count = split(arguments[tree], words, /[[:space:]]+/)
      if (count < 2 || base(words[1]) != "treehouse" || words[2] != "get") exit 1
      tree_children = 0
      for (pid in present) if (parent[pid] == tree) { nested = pid; tree_children++ }
      if (tree_children != 1 || !is_shell(command[nested]) || state[nested] !~ /^[SI]/) exit 1
      count = split(arguments[nested], nested_words, /[[:space:]]+/)
      if (count < 1 || !is_shell(nested_words[1])) exit 1
      nested_children = 0
      for (pid in present) if (parent[pid] == nested) nested_children++
      if (nested_children != 0 || nested != foreground || group[nested] != foreground) exit 1
      printf "%s:%s:%s:%s", shell, tree, nested, foreground
    }
  '
}

# Print one command value per process strictly below <pane-shell-pid>, one per
# line, skipping exited rows. This is the positive-evidence half of the same
# proof: the fingerprint above refuses on any descendant it cannot name, while
# this names them so a caller can recognize a still-running engine instead of
# reading an unrecognized descendant as ambiguity. The ps format keeps `comm`
# last so a process name containing spaces survives as one whole value.
fm_herdr_pi_descendant_commands() {  # <pane-shell-pid>
  local shell_pid=${1:-} ps_bin rows
  case "$shell_pid" in ''|*[!0-9]*) return 1 ;; esac
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  rows=$("$ps_bin" -axo pid=,ppid=,stat=,comm= 2>/dev/null) || return 1
  printf '%s\n' "$rows" | awk -v shell="$shell_pid" '
    {
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || NF < 4 || seen[$1]++) next
      pid = $1
      parent[pid] = $2
      state[pid] = $3
      line = $0
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", line)
      command[pid] = line
      present[pid] = 1
    }
    END {
      if (!present[shell]) exit 1
      owned[shell] = 1
      do {
        changed = 0
        for (pid in present) if (owned[pid] != 1 && owned[parent[pid]] == 1) {
          owned[pid] = 1
          changed = 1
        }
      } while (changed)
      for (pid in owned) {
        if (owned[pid] != 1 || pid == shell || state[pid] ~ /^Z/) continue
        print command[pid]
      }
    }
  '
}
