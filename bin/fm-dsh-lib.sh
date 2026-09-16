#!/usr/bin/env bash
# DeepSeek Harness process identity.
# Sourced by bin/fm-harness.sh and bin/fm-session-lock-lib.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: a DSH host is a node process, so `ps` reports comm=node and
# nothing about its command NAME says dsh. The launcher path in argv is the only
# identity, and two independent owners need it - the ancestry walk that names
# firstmate's own harness, and the per-home session-lock registry that decides
# whether this session owns state/.lock. Both previously carried their own copy
# of the pattern in their own syntax (a shell case glob in one, an ERE in the
# other), which made three copies of one fact across two files.
#
# Measured 2026-09-16 against the npx-installed CLI (dsh 0.1.5-rc.1, dsh-base
# 0.1.5-rc.2):
#
#   comm : node
#   args : node /Users/<user>/.npm/_npx/<id>/node_modules/.bin/dsh web
#
# A source launch reports .../apps/cli/src/bin.ts, a direct package launch
# .../@deepseek-ai/dsh/lib/bin.js, and a global npm install the symlink it was
# exec'd through, node <prefix>/bin/dsh, because the interpreter is handed the
# path the shebang ran from rather than its resolved target.
#
# Every pattern is an anchored PATH SHAPE, never a bare *dsh* glob: an ordinary
# firstmate path such as bin/fm-dsh-sessionstart.sh, or an unrelated dshish.js,
# must not claim the identity. bin/fm-dsh-harness.test.sh pins both directions.
#
# Why the ancestry walk and not a pid probe: like bin/fm-cursor-lib.sh and
# bin/fm-gemini-lib.sh, this is structural only and starts no subprocess.
# Probing a stranger's binary during a liveness poll is exactly what must not
# happen.

# Print which DSH launcher shape <args> carries, or return 1.
fm_dsh_args_evidence() {  # <args>
  local args=${1:-}
  case "$args" in
    */.bin/dsh\ *|*/.bin/dsh) printf '%s\n' 'bin-dsh' ;;
    */bin/dsh\ *|*/bin/dsh) printf '%s\n' 'global-bin-dsh' ;;
    *@deepseek-ai/dsh/lib/bin.js*) printf '%s\n' 'installed-bin-js' ;;
    *apps/cli/src/bin.ts*) printf '%s\n' 'source-bin-ts' ;;
    *) return 1 ;;
  esac
}

# True when one argv string is a DSH launcher.
fm_dsh_args_are_dsh() {  # <args>
  fm_dsh_args_evidence "$1" >/dev/null
}

# The same launcher shapes as ERE alternation, for a caller that
# classifies a whole command string in one grep rather than testing it in a case
# arm (bin/fm-session-lock-lib.sh composes it into FM_HARNESS_RE). Kept beside
# the case arms above so the two spellings cannot drift apart.
fm_dsh_args_ere() {
  printf '%s\n' '/\.?bin/dsh([[:space:]]|$)|/@deepseek-ai/dsh/lib/bin\.js|/apps/cli/src/bin\.ts'
}

# True when a genuine DSH launcher sits within sixteen parents of [<pid>], the
# depth the session lock walks. Inside the session-start digest the host is the
# ninth process up: the hooks.json wrapper, this adapter's command substitution
# and fm-session-start.sh's timeout wrapper all sit between.
fm_dsh_ancestry() {  # [<pid>]
  local pid=${1:-$$} args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
    fm_dsh_args_are_dsh "$args" && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}
