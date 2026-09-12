#!/usr/bin/env bash
# fm-startup-surface-budget.sh - budget guard for the always-loaded startup surface.
#
# Usage:
#   bin/fm-startup-surface-budget.sh                 # enforce the budget (CI and local)
#   bin/fm-startup-surface-budget.sh --report        # print the measurement, enforce nothing
#   bin/fm-startup-surface-budget.sh --report --digest  # ... and the empty-home digest too
#   bin/fm-startup-surface-budget.sh --root <path>   # measure another checkout (tests)
#
# WHAT IS GATED, AND WHY EXACTLY THIS.
# Every session of every fleet member pays for AGENTS.md and for the one
# supervision block bin/fm-supervision-instructions.sh renders into the session
# digest, whether or not that session ever reaches the situation a given line
# describes. Both are tracked prose, so both can grow silently in an ordinary
# PR - which is what happened before: AGENTS.md went from 585 to 958 lines
# between two restructures, entirely from conditional detail added inline
# instead of routed to its owner. This guard is the deterministic backstop for
# .agents/skills/firstmate-coding-guidelines/SKILL.md's size discipline.
#
# The composed number is AGENTS.md plus the LARGEST rendered supervision block
# across docs/supervision-protocols/, because a session gets exactly one block
# and the guard must hold for the worst harness, not the average one.
#
# WHAT IS NOT GATED, DELIBERATELY. The rest of the session digest is home and
# machine state - fleet metadata, status tails, bootstrap diagnostics naming
# whichever tools this host is missing, the lock verdict, the worktree-tangle
# banner. None of it is tracked bytes a PR can grow, and all of it differs
# between a contributor's laptop and a CI runner, so gating it would make the
# check environment-dependent rather than change-dependent. `--report --digest`
# generates an empty-home digest and prints its size alongside the gated
# number, so the full composed startup floor stays visible to a human; only the
# tracked half is ever enforced.
#
# Token estimates use the repo's own documented estimate, ceil(bytes / 3).
#
# RAISING THE CEILING is a reviewed decision, not a merge-unblocking edit:
# state in the PR which always-loaded fact could not be routed to an owner.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Measured ceilings. Keep them at the measured size of the surface they guard:
# headroom here is future silent growth.
AGENTS_BYTES_MAX=56277
BLOCK_BYTES_MAX=6807
COMPOSED_BYTES_MAX=63084

REPORT_ONLY=false
WITH_DIGEST=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report) REPORT_ONLY=true; shift ;;
    --digest) WITH_DIGEST=true; shift ;;
    --root)
      [ "$#" -gt 1 ] || { echo "startup surface: --root requires a path" >&2; exit 2; }
      ROOT=$(cd "$2" 2>/dev/null && pwd) || { echo "startup surface: --root path not found: $2" >&2; exit 2; }
      shift 2
      ;;
    *) echo "usage: fm-startup-surface-budget.sh [--report [--digest]] [--root <path>]" >&2; exit 2 ;;
  esac
done
[ "$WITH_DIGEST" = false ] || [ "$REPORT_ONLY" = true ] \
  || { echo "startup surface: --digest is a --report option; the gate never measures the digest" >&2; exit 2; }

estimated_tokens() { # <bytes>
  printf '%s\n' $(( ( $1 + 2 ) / 3 ))
}

file_bytes() { # <path>
  LC_ALL=C command wc -c < "$1" | tr -d '[:space:]'
}

AGENTS_MD="$ROOT/AGENTS.md"
[ -f "$AGENTS_MD" ] || { echo "startup surface: AGENTS.md not found at $AGENTS_MD" >&2; exit 1; }
AGENTS_BYTES=$(file_bytes "$AGENTS_MD")

# One block per harness protocol document, rendered as the digest renders it.
# The flags pin the posture and the two sentinel paths pin the only other
# variable the renderer has - it substitutes absolute extension and config
# paths into the prose, so an unpinned render would measure how deep this
# checkout happens to sit on disk. With them pinned, the number moves only when
# the tracked prose does.
FM_SURFACE_SENTINEL_ROOT=/fm-startup-surface
BLOCK_BYTES=0
BLOCK_HARNESS=
FOUND_BLOCK=false
for protocol in "$ROOT"/docs/supervision-protocols/*.md; do
  [ -f "$protocol" ] || continue
  harness=$(basename "$protocol" .md)
  rendered=$(FM_ROOT_OVERRIDE="$FM_SURFACE_SENTINEL_ROOT" FM_HOME="$FM_SURFACE_SENTINEL_ROOT" \
    "$ROOT/bin/fm-supervision-instructions.sh" \
    --harness "$harness" --read-only false --afk false --x-mode false 2>/dev/null) || {
    echo "startup surface: supervision block for '$harness' could not be rendered" >&2
    exit 1
  }
  FOUND_BLOCK=true
  bytes=$(printf '%s\n' "$rendered" | LC_ALL=C command wc -c | tr -d '[:space:]')
  if [ "$bytes" -gt "$BLOCK_BYTES" ]; then
    BLOCK_BYTES=$bytes
    BLOCK_HARNESS=$harness
  fi
done
[ "$FOUND_BLOCK" = true ] || { echo "startup surface: no supervision protocol documents found" >&2; exit 1; }

COMPOSED_BYTES=$(( AGENTS_BYTES + BLOCK_BYTES ))

printf 'STARTUP SURFACE  AGENTS.md            %8s bytes  %7s estimated tokens  (ceiling %s / %s)\n' \
  "$AGENTS_BYTES" "$(estimated_tokens "$AGENTS_BYTES")" "$AGENTS_BYTES_MAX" "$(estimated_tokens "$AGENTS_BYTES_MAX")"
printf 'STARTUP SURFACE  supervision block    %8s bytes  %7s estimated tokens  (largest: %s; ceiling %s / %s)\n' \
  "$BLOCK_BYTES" "$(estimated_tokens "$BLOCK_BYTES")" "$BLOCK_HARNESS" "$BLOCK_BYTES_MAX" "$(estimated_tokens "$BLOCK_BYTES_MAX")"
printf 'STARTUP SURFACE  composed             %8s bytes  %7s estimated tokens  (ceiling %s / %s)\n' \
  "$COMPOSED_BYTES" "$(estimated_tokens "$COMPOSED_BYTES")" "$COMPOSED_BYTES_MAX" "$(estimated_tokens "$COMPOSED_BYTES_MAX")"

if [ "$REPORT_ONLY" = true ]; then
  [ "$WITH_DIGEST" = true ] || exit 0
  # Informational only: the whole empty-home digest, so the ungated half of the
  # startup floor is still visible to a human reading the report.
  digest_home=$(mktemp -d "${TMPDIR:-/tmp}/fm-startup-surface.XXXXXX") || exit 1
  digest_bytes=$(FM_HOME="$digest_home" "$ROOT/bin/fm-session-start.sh" 2>&1 \
    | LC_ALL=C command wc -c | tr -d '[:space:]') || digest_bytes=
  rm -rf -- "$digest_home"
  if [ -n "$digest_bytes" ]; then
    printf 'STARTUP SURFACE  empty-home digest    %8s bytes  %7s estimated tokens  (not gated: home and machine state)\n' \
      "$digest_bytes" "$(estimated_tokens "$digest_bytes")"
  fi
  exit 0
fi

over=false
if [ "$AGENTS_BYTES" -gt "$AGENTS_BYTES_MAX" ]; then
  printf 'STARTUP SURFACE BUDGET EXCEEDED: AGENTS.md is %s bytes (%s estimated tokens), over its %s-byte (%s-token) ceiling by %s bytes.\n' \
    "$AGENTS_BYTES" "$(estimated_tokens "$AGENTS_BYTES")" "$AGENTS_BYTES_MAX" \
    "$(estimated_tokens "$AGENTS_BYTES_MAX")" "$(( AGENTS_BYTES - AGENTS_BYTES_MAX ))" >&2
  over=true
fi
if [ "$BLOCK_BYTES" -gt "$BLOCK_BYTES_MAX" ]; then
  printf 'STARTUP SURFACE BUDGET EXCEEDED: the largest supervision block (%s) is %s bytes (%s estimated tokens), over its %s-byte (%s-token) ceiling by %s bytes.\n' \
    "$BLOCK_HARNESS" "$BLOCK_BYTES" "$(estimated_tokens "$BLOCK_BYTES")" "$BLOCK_BYTES_MAX" \
    "$(estimated_tokens "$BLOCK_BYTES_MAX")" "$(( BLOCK_BYTES - BLOCK_BYTES_MAX ))" >&2
  over=true
fi
if [ "$COMPOSED_BYTES" -gt "$COMPOSED_BYTES_MAX" ]; then
  printf 'STARTUP SURFACE BUDGET EXCEEDED: the composed always-loaded surface is %s bytes (%s estimated tokens), over its %s-byte (%s-token) ceiling by %s bytes.\n' \
    "$COMPOSED_BYTES" "$(estimated_tokens "$COMPOSED_BYTES")" "$COMPOSED_BYTES_MAX" \
    "$(estimated_tokens "$COMPOSED_BYTES_MAX")" "$(( COMPOSED_BYTES - COMPOSED_BYTES_MAX ))" >&2
  over=true
fi

if [ "$over" = true ]; then
  cat >&2 <<'MSG'

Every fleet session pays for these bytes on every turn, whether or not it ever
reaches the situation the new lines describe. Route the addition to its owner
instead of adding it inline:

  - Needed only in a nameable situation (a spawn, a recovery, one wake type,
    one lifecycle step)? An agent-only skill under .agents/skills/, with a
    one-line load trigger in AGENTS.md section 13.
  - Exact flags, commands, paths, or a wire format? The producing script's own
    header comment and --help.
  - Operator or contributor reference? Its classified owner under docs/.

The decision tree is .agents/skills/firstmate-coding-guidelines/SKILL.md
("Knowledge-placement decision tree" and "Size discipline").

If the addition genuinely has to be always-loaded, raise the ceilings in
bin/fm-startup-surface-budget.sh in the same PR and say in the PR body which
fact could not be routed to an owner.
MSG
  exit 1
fi

printf 'STARTUP SURFACE: within budget.\n'
