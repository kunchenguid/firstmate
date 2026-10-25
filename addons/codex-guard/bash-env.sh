#!/usr/bin/env bash
# Fleet guards for Codex (installed by firstmate-addons codex-guard/install.sh as Codex's shell BASH_ENV).
# Codex runs each agent command as bash -lc '<snapshot wrapper>', and the wrapper ends in exec bash -c '<command>' with
# BASH_ENV kept, so the inner shell arrives here holding exactly the agent's command. Each installed fleet guard judges it
# through the same entry its Claude hook uses; exit 2 is a final block. BASH_ENV is then dropped, so scripts and shells
# the command itself starts run unchecked, as under the Claude hook.
case ${BASH_EXECUTION_STRING-} in
  '' | __CODEX_SNAPSHOT_*) ;;
  *)
    unset BASH_ENV
    fm_codex_guard() { # <guard dir> [args]: 0 allows (also when that guard is not installed), 2 blocks
      [ -f "__DATA__/$1/guard.mjs" ] || return 0
      local err rc=0
      err=$(node "__DATA__/$1/guard.mjs" "${@:2}" 2>&1 >/dev/null <<<"$fm_codex_guard_in") || rc=$?
      [ "$rc" -ne 2 ] || { printf '%s\n' "$err" >&2; return 2; }
      [ "$rc" -eq 0 ] || printf 'fleet guard %s could not check this command (exit %s): %s\n' "$1" "$rc" "$err" >&2
    }
    if fm_codex_guard_in=$(jq -n --arg c "$BASH_EXECUTION_STRING" --arg d "$PWD" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'); then
      fm_codex_guard fm-delete-guard --runtime codex && fm_codex_guard fm-kill-guard --caller "$PPID" && fm_codex_guard fm-read-guard || exit 2
    else
      echo "fleet guards could not check this command: jq failed to encode it" >&2
    fi
    unset -f fm_codex_guard; unset fm_codex_guard_in
    ;;
esac
