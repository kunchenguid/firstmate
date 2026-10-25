#!/usr/bin/env bash
set -euo pipefail

if [[ -z ${FM_HOME:-} ]]; then
    echo 'chat-tsv-refresh: FM_HOME must be set to the main Firstmate home' >&2
    exit 1
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
transcripts=${CHAT_TSV_TRANSCRIPTS:-$HOME/.claude/projects/-home-umer-firstmate}
if [[ ! -d $transcripts || ! -r $transcripts ]]; then
    echo "chat-tsv-refresh: transcripts directory is missing or unreadable: $transcripts" >&2
    exit 1
fi
result=$(python3 "$script_dir/chat-tsv.py" 2>&1) || {
    echo "chat-tsv-refresh: $result" >&2
    exit 1
}
appended=$(sed -n 's/^appended=\([0-9][0-9]*\).*/\1/p' <<<"$result")
if [[ ! $appended =~ ^[0-9]+$ ]]; then
    echo 'chat-tsv-refresh: extractor did not report an append count' >&2
    exit 1
fi
total=$(wc -l < "$FM_HOME/data/chat.tsv")
printf 'appended=%s rows total=%s\n' "$appended" "$total"
