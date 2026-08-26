# shellcheck shell=bash
# fm-update-guard-lib.sh - TOR "update": no home advances onto a commit that
# quietly disarms the fleet.
#
# Usage:
#   . bin/fm-update-guard-lib.sh
#   fm_update_guard <repo-dir> <ziel-commit>   # 0 = green, 1 = red
#
#   bash bin/fm-update-guard-lib.sh <repo-dir> <ziel-commit>
#       Same check as a standalone command (diagnostics, and how the colocated
#       test drives it): exit 0 only when everything is green, exit 1 otherwise
#       with "update-guard: red at <commit>: <first violation>" on stderr.
#
# THE PROBLEM IT OWNS: an update is a fast-forward of tracked files. A commit
# that deletes a gate script, drops a hook registration, or removes the rule
# database therefore lands exactly like a typo fix - silently - and the fleet is
# disarmed from that moment on, with no refusal anywhere in the log. The advance
# itself is safe (nothing is forced, merged, or stashed); what is unsafe is what
# the advanced-to commit no longer contains.
#
# THE CHECK: before the advance, the target commit is checked out into a
# throwaway detached worktree (git worktree add --detach) and judged there:
#   1. every row of regeln/INVARIANTEN.tsv (that file owns the row format), and
#   2. the TARGET's OWN bin/fm-regel-eval.sh check, when that script exists in
#      the worktree - the incoming commit's rule gate must pass on the incoming
#      commit's own rulebook, so a rulebook change cannot arrive already broken.
# The worktree is removed either way. Nothing in the caller's working copy is
# read, written, or moved by this gate: an advance is either taken by the caller
# afterwards or not taken at all.
#
# WHICH INVARIANT LIST IS AUTHORITATIVE: <repo-dir>/regeln/INVARIANTEN.tsv, the
# list of the fleet that is RUNNING RIGHT NOW - not the one shipped inside the
# target commit. A commit must not be able to wave itself through by deleting the
# expectations it fails. Only when the running checkout has no list at all (an
# older home, mid-transition) does the worktree's own copy stand in; with neither
# present the invariant part is skipped with a warning and only regel-eval runs.
#
# TOR CONTRACT:
#   1. Scharfschalt-Flag $FM_HOME/state/.tor-update-scharf is checked FIRST.
#      Absent => return 0 in total silence, no log line: the gate never looked
#      (same convention as bin/fm-git-guard.sh). Every gate here is built before
#      it goes live, so an unarmed gate must be indistinguishable from no gate.
#   2. Armed and refusing => LOUD on stderr, naming both the source that decided
#      (the invariant row, or regel-eval's own violation line) and the Ausweg.
#   3. Every decision of an ARMED gate writes one JSONL line via fm_tor_log
#      (state/tor-log/update.jsonl), green passages included.
#
# AUSWEG (emergency only): FM_UPDATE_GUARD_SKIP=1 passes the gate without
# checking anything. It is deliberately loud - one stderr line per skipped
# advance plus a `warn` line in state/tor-log/update.jsonl naming the exit that
# was taken - because the whole point of an emergency exit is that it leaves a
# trace. Use it when a home must move NOW and the guard itself is the thing that
# is broken; never as a way to land a red commit.
#
# FAIL-CLOSED: when the verification worktree cannot be created, or the target
# commit cannot be resolved, the gate is RED. A gate that cannot look must not
# report "green"; the home simply stays where it is, which is always safe.

fm_update_guard_state_dir() { # -> the state dir whose .tor-update-scharf decides
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME/state"
  else
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state"
  fi
}

# Tor-Log: the shared owner, or a no-op stand-in so this lib runs standalone.
if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tor-log-lib.sh" ]; then
  # shellcheck source=bin/fm-tor-log-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tor-log-lib.sh"
else
  fm_tor_log() { :; }
fi

FM_UPDATE_GUARD_TOR="update"

# Extract every registered hook command for one event from a settings file.
# Prints one command per line; returns 1 when the file cannot be read as JSON.
fm_update_guard_hook_commands() { # <settings-file> <event>
  jq -r --arg ev "$2" \
    '(.hooks[$ev] // [])[]? | (.hooks // [])[]? | (.command // empty)' \
    "$1" 2>/dev/null
}

# Judge one invariant row inside the checked-out worktree.
# Echoes a violation sentence and returns 1 (red), echoes a warning sentence and
# returns 2 (warn, not fatal), or returns 0 silently (green).
fm_update_guard_check_row() { # <worktree> <art> <ziel>
  local wt=$1 art=$2 ziel=$3 event needle settings cmds
  case "$art" in
    pfad)
      if [ ! -e "$wt/$ziel" ]; then
        printf 'missing path %s (regeln/INVARIANTEN.tsv: pfad)' "$ziel"
        return 1
      fi
      ;;
    exec)
      if [ ! -f "$wt/$ziel" ]; then
        printf 'missing tool %s (regeln/INVARIANTEN.tsv: exec)' "$ziel"
        return 1
      fi
      case "$ziel" in
        *-lib.sh)
          # Sourced by its callers, so "runnable" means it parses.
          if ! bash -n "$wt/$ziel" 2>/dev/null; then
            printf 'tool %s does not parse (regeln/INVARIANTEN.tsv: exec)' "$ziel"
            return 1
          fi
          ;;
        *)
          if [ ! -x "$wt/$ziel" ]; then
            printf 'tool %s is not executable (regeln/INVARIANTEN.tsv: exec)' "$ziel"
            return 1
          fi
          ;;
      esac
      ;;
    hook)
      event=${ziel%%:*}
      needle=${ziel#*:}
      if [ -z "$event" ] || [ -z "$needle" ] || [ "$event" = "$ziel" ]; then
        printf 'malformed hook row %s (expected <event>:<script>)' "$ziel"
        return 1
      fi
      settings="$wt/.claude/settings.json"
      if [ ! -f "$settings" ]; then
        printf 'missing .claude/settings.json, so hook %s cannot be registered' "$ziel"
        return 1
      fi
      if ! command -v jq >/dev/null 2>&1; then
        printf 'jq is missing, so hook row %s could not be verified' "$ziel"
        return 2
      fi
      cmds=$(fm_update_guard_hook_commands "$settings" "$event") || cmds=""
      if ! printf '%s\n' "$cmds" | grep -Fq -- "$needle"; then
        printf 'hook %s is not registered in .claude/settings.json (regeln/INVARIANTEN.tsv: hook)' "$ziel"
        return 1
      fi
      ;;
    golden)
      if [ ! -e "$wt/$ziel" ]; then
        # Transition, by the file's own contract: a golden fixture that does not
        # exist yet warns, it does not refuse.
        printf 'golden fixture %s does not exist yet (warning, not a refusal)' "$ziel"
        return 2
      fi
      ;;
    *)
      printf 'unknown invariant art %s (pfad|exec|hook|golden)' "$art"
      return 1
      ;;
  esac
  return 0
}

# fm_update_guard <repo-dir> <ziel-commit>
# 0 = green (or gate unarmed, or emergency exit taken), 1 = red.
fm_update_guard() {
  local repo=${1:-} target=${2:-} flag short wt tmp art ziel rest detail rc
  local -a violations=() warnings=()

  flag="$(fm_update_guard_state_dir)/.tor-update-scharf"
  [ -f "$flag" ] || return 0

  if [ "${FM_UPDATE_GUARD_SKIP:-0}" = "1" ]; then
    printf 'update-guard: SKIPPED by FM_UPDATE_GUARD_SKIP=1 - %s advances to %s unchecked (emergency exit; the next advance is checked again)\n' \
      "${repo:-<no repo>}" "${target:-<no commit>}" >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten warn FM_UPDATE_GUARD_SKIP \
      "repo=$repo ziel=$target: gate skipped by env exit"
    return 0
  fi

  if [ -z "$repo" ] || [ -z "$target" ]; then
    printf 'update-guard: red at %s: usage is fm_update_guard <repo-dir> <ziel-commit>\n' \
      "${target:-<no commit>}" >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten rot - "repo=$repo ziel=$target: bad arguments"
    return 1
  fi

  short=$(git -C "$repo" rev-parse --short "$target^{commit}" 2>/dev/null) || short=""
  if [ -z "$short" ]; then
    printf 'update-guard: red at %s: commit does not resolve in %s. Ausweg: fetch the commit first, or FM_UPDATE_GUARD_SKIP=1 for one advance.\n' \
      "$target" "$repo" >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten rot - "repo=$repo ziel=$target: commit does not resolve"
    return 1
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-update-guard.XXXXXX") || tmp=""
  if [ -z "$tmp" ]; then
    printf 'update-guard: red at %s: cannot create a temp dir for the verification worktree. Ausweg: free space in %s, or FM_UPDATE_GUARD_SKIP=1 for one advance.\n' \
      "$short" "${TMPDIR:-/tmp}" >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten rot - "repo=$repo ziel=$short: no temp dir"
    return 1
  fi
  wt="$tmp/wt"
  if ! detail=$(git -C "$repo" worktree add --detach --quiet "$wt" "$target" 2>&1); then
    rm -rf "$tmp"
    printf 'update-guard: red at %s: cannot check out the target for verification: %s. Ausweg: prune stale worktrees in %s, or FM_UPDATE_GUARD_SKIP=1 for one advance.\n' \
      "$short" "$(printf '%s' "$detail" | tr '\n' ' ')" "$repo" >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten rot - "repo=$repo ziel=$short: worktree add failed"
    return 1
  fi

  # --- invariant rows ------------------------------------------------------
  local list=""
  if [ -f "$repo/regeln/INVARIANTEN.tsv" ]; then
    list="$repo/regeln/INVARIANTEN.tsv"
  elif [ -f "$wt/regeln/INVARIANTEN.tsv" ]; then
    list="$wt/regeln/INVARIANTEN.tsv"
  fi
  if [ -z "$list" ]; then
    warnings+=("no regeln/INVARIANTEN.tsv in either the running checkout or the target - invariant check skipped")
  else
    while IFS=$'\t' read -r art ziel rest || [ -n "${art:-}" ]; do
      case "${art:-}" in ''|'#'*) continue ;; esac
      if [ -z "${ziel:-}" ]; then
        violations+=("malformed row '$art' in regeln/INVARIANTEN.tsv (needs art, ziel, beschreibung)")
        continue
      fi
      rc=0
      detail=$(fm_update_guard_check_row "$wt" "$art" "$ziel") || rc=$?
      case "$rc" in
        0) ;;
        2) warnings+=("$detail") ;;
        *) violations+=("$detail") ;;
      esac
    done < "$list"
  fi

  # --- the target's own rule gate ------------------------------------------
  if [ -f "$wt/bin/fm-regel-eval.sh" ]; then
    if ! detail=$(FM_ROOT_OVERRIDE="$wt" bash "$wt/bin/fm-regel-eval.sh" check 2>&1); then
      local firstline
      # Its own finding lines win over the summary line, whichever label the
      # target's version of that script uses; the last line is the fallback.
      firstline=$(printf '%s\n' "$detail" | grep -m1 -E '^(VIOLATION|FATAL): ' || true)
      [ -n "$firstline" ] || firstline=$(printf '%s\n' "$detail" | sed -n '$p')
      firstline=${firstline#VIOLATION: }
      violations+=("regel-eval check fails on the target itself: ${firstline#FATAL: }")
    fi
  else
    warnings+=("target has no bin/fm-regel-eval.sh - rule gate not run")
  fi

  # --- teardown ------------------------------------------------------------
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  rm -rf "$tmp"

  local w
  for w in "${warnings[@]:-}"; do
    [ -n "$w" ] || continue
    printf 'update-guard: warn at %s: %s\n' "$short" "$w" >&2
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    for w in "${violations[@]}"; do
      printf 'update-guard: violation at %s: %s\n' "$short" "$w" >&2
    done
    printf 'update-guard: red at %s: %s\n' "$short" "${violations[0]}" >&2
    printf 'update-guard: the home stays where it is. Ausweg: fix the target commit and update again, or FM_UPDATE_GUARD_SKIP=1 for one emergency advance (logged).\n' >&2
    fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten rot - \
      "repo=$repo ziel=$short: ${#violations[@]} violation(s), first: ${violations[0]}"
    return 1
  fi

  fm_tor_log "$FM_UPDATE_GUARD_TOR" invarianten gruen - \
    "repo=$repo ziel=$short: all invariants green, ${#warnings[@]} warning(s)"
  return 0
}

# Standalone invocation: `bash bin/fm-update-guard-lib.sh <repo-dir> <commit>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_update_guard "$@"
  exit $?
fi
