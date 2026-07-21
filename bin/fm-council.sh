#!/usr/bin/env bash
# fm-council.sh - authoritative CLI for the thin persistent council MVP.
#
# Usage:
#   fm-council.sh create <name> --project <absolute-path> \
#     --participant claude/claude-fable-5/xhigh \
#     --participant codex/gpt-5.6-sol/xhigh [--clean-slate] [--herdr-session <name>]
#   fm-council.sh provider-consent anthropic|openai --project <absolute-path> \
#     --acknowledge-project-disclosure
#   fm-council.sh ask <name> <task>
#   fm-council.sh ready <name>
#   fm-council.sh wait <name> [--timeout <seconds>] [--poll <seconds>]
#   fm-council.sh collect <name>
#   fm-council.sh present <name> --file <canonical-decision> --kind best|synthesis|only
#   fm-council.sh accept <name>
#   fm-council.sh accept-and-implement <name>
#   fm-council.sh reject <name> [--reason <text>]
#   fm-council.sh rerun <name> [--clarify <constraint>]
#   fm-council.sh recover <name>
#   fm-council.sh retry <name> [--clarify <constraint>]
#   fm-council.sh close <name>
#   fm-council.sh status [<name>]
#
# `submit` is the private answer-ingest command used by deterministic transports:
#   fm-council.sh submit <name> <member-id> --round <id> --nonce <nonce> --file <answer>
#
# Exact contract:
# - Council names are durable and globally unique inside one FM_HOME.
# - The only supported lane is Linux x86_64 with Herdr and the two exact participant profiles shown above.
# - `create` launches fresh persistent participant conversations in one Herdr workspace.
# - Linux Landlock denies project writes and hides the source project; seccomp denies
#   terminal-control Unix sockets while provider TCP remains available. Participants
#   see only immutable filtered round views and their own writable home.
# - A round starts only after project-specific consent exists for every cloud provider.
# - One council has one active round; separate council locks permit independent councils.
# - `collect` records available answers and names unavailable members. Firstmate chooses
#   the best answer or writes a short synthesis, then freezes that exact text with
#   `present`. `--kind only` is mandatory when only one answer is available.
# - `accept` atomically saves exactly `presented.md` before sending that canonical text.
#   Missed decisions are delivered before that participant receives its next round.
# - `accept-and-implement` accepts identically, then prints a structured instruction for
#   a separate ordinary implementation task. Council participants never implement.
# - `reject`, `rerun`, and `retry` delete raw answers and any rejected presentation.
# - `recover` marks an interrupted collecting round for explicit `retry`; it never
#   duplicates or silently resumes participant endpoints.
# - `close` is the only participant termination command. It verifies every exact
#   response-derived endpoint before closing only those panes and deleting lane homes.
#   A partially failed close is retryable: only members recorded in the durable
#   close journal are skipped, and an absent or ambiguous pane is never assumed owned.
#
# State ownership:
# - data/councils/<id>/council.json owns council identity and phase.
# - data/councils/<id>/rounds/<round>/ owns durable round metadata and the currently
#   presented canonical text; raw collections and answer outboxes stay under state/.
# - data/council-projects/<path-hash>/decisions/ owns exact accepted decision bodies.
# - state/councils/<id>/members/<member>/runtime.json owns exact endpoint identity.
# - config/council-provider-consent.json owns project-specific provider disclosure.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help|help|'')
    usage
    ;;
  *)
    exec python3 "$ROOT/bin/fm-council.py" "$@"
    ;;
esac
