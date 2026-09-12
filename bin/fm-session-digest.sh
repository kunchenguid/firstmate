#!/usr/bin/env bash
# fm-session-digest.sh - write one local day's session digest to
# data/improvements/<YYYY-MM-DD>.md from the Claude, Pi, and Codex session logs
# this machine already writes.
#
# Hand-run only: there is no scheduler, no daemon, and no hook. The reader is
# bin/fm-session-digest.mjs, which shares its log discovery and line parsing
# with bin/fm-model-usage.mjs.
#
# The digest is local fleet material: it is written mode 0600 inside a mode
# 0700 data/improvements/, it stays gitignored with the rest of data/, and it is
# never posted. It stores counts plus at most the first 120 characters of a
# captain correction - never assistant text, tool output, or file contents.
#
# Usage:
#   fm-session-digest.sh [-h] [--today] [--date YYYY-MM-DD]
#
#   -h, --help           print this help and exit
#   --today              digest the current local day instead of yesterday
#   --date YYYY-MM-DD    digest one explicit local day
#
# Environment:
#   FM_IMPROVEMENTS_DIR       output directory (default <repo>/data/improvements)
#   FM_CLAUDE_PROJECTS_OVERRIDE, FM_PI_SESSIONS_OVERRIDE,
#   FM_CODEX_SESSIONS_OVERRIDE
#                             session-log roots, the same fakes the model-usage
#                             reader honors, used by tests/fm-session-digest.test.sh
#
# Exit codes: 0 wrote the digest, 2 bad arguments, 1 the reader failed.
# The last line of the digest file and of stdout is the run's own elapsed time
# against the 30 s one-day budget.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
READER="$ROOT/bin/fm-session-digest.mjs"
OUT_DIR=${FM_IMPROVEMENTS_DIR:-$ROOT/data/improvements}

usage() {
  sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --today) ARGS+=(--today); shift ;;
    --date)
      [ $# -ge 2 ] || { printf 'fm-session-digest.sh: --date needs a value\n' >&2; exit 2; }
      ARGS+=(--date "$2"); shift 2 ;;
    --date=*) ARGS+=(--date "${1#--date=}"); shift ;;
    *) printf 'fm-session-digest.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || {
  printf 'fm-session-digest.sh: node is required for the session-log reader\n' >&2
  exit 1
}

# data/improvements/README.md is the usefulness plan: motive, how to run, field
# meanings, and the schedule-or-kill contract. It is written once per home and
# never overwritten, so the captain's own accepted-change notes survive.
write_readme() {
  if [ -e "$OUT_DIR/README.md" ]; then
    return 0
  fi
  cat >"$OUT_DIR/README.md" <<'README'
# Session improvements

Daily digests of the Claude, Pi, and Codex session logs this machine already writes, mined for friction instead of adding a telemetry extension.
The research verdict behind it is `data/research-pi-telemetry-verdict/verdict.md`.

## Motive

The fleet already pays for every session log; nothing reads them back.
This folder turns them into one small file per day that names where the agents fought the tooling, so improvements land in skills, `bin/` scripts, captain rules, and briefs instead of being rediscovered by feel.

## How to run

```sh
bin/fm-session-digest.sh              # yesterday, the default
bin/fm-session-digest.sh --today      # the current local day
bin/fm-session-digest.sh --date 2026-09-12
bin/fm-session-digest.sh -h           # full help
```

Each run writes `data/improvements/<YYYY-MM-DD>.md`, mode 0600, and prints its own elapsed time against a 30 s budget on the last line.
It is local-only fleet material: gitignored with the rest of `data/`, never posted, and it stores counts plus at most the first 120 characters of a captain correction - never assistant text, tool output, or file contents.

## Field meanings

One row per session that started on that local day.

| field | meaning |
|---|---|
| session | last 8 characters of the harness session id |
| harness | `claude`, `pi`, or `codex` |
| place | `home:<name>` for a Firstmate home or project checkout, `wt:<name>` for a disposable worktree or scratch dir |
| task | Firstmate task id, from the status path in the launch brief or from a `/tmp/fm-*` worktree path; `-` when the session is not a Firstmate worker |
| model, effort | last model seen, and the reasoning/thinking level (`-` when the harness does not record one) |
| in, out, cache | input, output, and cache tokens; Codex reports its own cumulative thread totals, Claude and Pi sum per-message usage |
| wall_s | active wall time, first to last recorded timestamp |
| tools | tool calls issued |
| errs | tool calls that failed: a Pi `isError` result, a Claude `is_error` tool result, a Codex failed command or MCP call |
| retries | repeat calls of the same tool with the same arguments, counted past the first |
| turns | user turns counted after injected traffic is dropped |
| corr | user turns whose head matches a redirect marker |

The redirect markers - `no,`, `not that`, `wrong`, `actually`, `instead`, `stop`, `again`, and their PT-BR equivalents - live in one table (`CORRECTION_PATTERNS`) at the top of `bin/fm-session-digest.mjs`.
Only the first 200 characters of a message are matched, because a redirect starts a message, and firstmate operation blocks, Claude command caveats, and skill bodies are never corrections.

`## Friction` lists the top 5 sessions by errors + retries + corrections.
`## Candidates` proposes at most 3 one-line improvements, each naming the session, the pattern, and the likely owner, from these thresholds: 3+ identical retries points at a `bin` script, 2+ corrections points at a brief, 5+ tool errors points at a skill.
A quiet day says so in one line rather than inventing candidates.

## Usefulness contract

1. Five daily hand runs, 2026-09-12 through 2026-09-16. No scheduler yet.
2. On 2026-09-17 the captain decides schedule-or-kill from what those five runs produced.
3. Weekly, the captain runs `/weekly-insights` over this folder, and it must yield at least one accepted change per week: a rule edit, a skill fix, a script fix, or a backlog item.
4. Two consecutive weeks with zero accepted changes kills the routine and any scheduler, keeping only the reader.
5. Every run must finish inside its 30 s budget; the elapsed line is the check.
README
  chmod 600 "$OUT_DIR/README.md"
}

umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
write_readme

start_seconds=$(date +%s)
wrote=$(FM_IMPROVEMENTS_DIR="$OUT_DIR" node "$READER" ${ARGS[@]+"${ARGS[@]}"} | sed -n 's/^WROTE //p')
[ -n "$wrote" ] || {
  printf 'fm-session-digest.sh: the reader wrote no digest\n' >&2
  exit 1
}
elapsed=$(( $(date +%s) - start_seconds ))
elapsed_line="elapsed: ${elapsed}s (budget 30s)"
[ "$elapsed" -le 30 ] || elapsed_line="$elapsed_line - OVER BUDGET"
printf '%s\n' "$elapsed_line" >>"$wrote"
chmod 600 "$wrote"
printf '%s\n%s\n' "$wrote" "$elapsed_line"
