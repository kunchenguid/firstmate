#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP/home" FM_STATE_OVERRIDE="$TMP/home/state"
export FM_DISCORD_BOT_TOKEN=test FM_DISCORD_TEST_MODE=1
mkdir -p "$FM_HOME"
adapter="$ROOT/bin/fm-procevent-discord-mention.sh"

message() {
  jq -cn --arg id "$1" --arg author "$2" --arg mention "$3" \
    --arg content "${4:-hello}" --argjson bot "${5:-false}" \
    '{id:$id,author:{id:$author,username:"tester",bot:$bot},mentions:(if $mention == "none" then [] else [{id:$mention}] end),content:$content,attachments:[]}'
}

poll() { FM_DISCORD_TEST_MESSAGES="$1" "$adapter" poll; }
seed() { mkdir -p "$FM_STATE_OVERRIDE/procevent"; printf '{"last_id":"%s"}\n' "$1" > "$FM_STATE_OVERRIDE/procevent/discord-mention.cursor"; }
cursor() { jq -r .last_id "$FM_STATE_OVERRIDE/procevent/discord-mention.cursor"; }

latest=$(message 100 human none)
result=$(poll "[$latest]")
[ "$(jq -r .status <<<"$result")" = no-result ]
[ "$(cursor)" = 100 ]

seed 100
match=$(message 101 human 1532391545356161094)
result=$(poll "[$match]")
[ "$(jq -r .message_id <<<"$result")" = 101 ]

seed 100
bot=$(message 101 bot 1532391545356161094 ignored true)
wrong=$(message 102 human 999 wrong)
valid=$(message 103 human 1532391545356161094 accepted)
result=$(poll "[$bot,$wrong,$valid]")
[ "$(jq -r .message_id <<<"$result")" = 103 ]

seed 100
many='[]'
for n in $(seq 1 205); do
  id=$((100 + n))
  if [ "$id" -eq 101 ]; then item=$(message "$id" human 1532391545356161094 oldest); else item=$(message "$id" human none); fi
  many=$(jq -cn --argjson old "$many" --argjson item "$item" '$old + [$item]')
done
result=$(poll "$many")
[ "$(jq -r .message_id <<<"$result")" = 101 ]

seed 100
mkdir -p "$FM_STATE_OVERRIDE/procevent-inbox"
printf '{"cursor_after":"101"}\n' > "$FM_STATE_OVERRIDE/procevent-inbox/discord-claude-mentions.1.result"
next=$(message 102 human 1532391545356161094 next)
result=$(poll "[$next]")
[ "$(jq -r .message_id <<<"$result")" = 102 ]

seed 100
plain=$(message 103 human none)
result=$(poll "[$plain]")
[ "$(jq -r .status <<<"$result")" = no-result ]
[ "$(cursor)" = 103 ]

result=$(poll '{"error":401}')
[ "$(jq -r .error <<<"$result")" = http-401 ]
printf '%s\n' "$result" > "$TMP/error.result"
"$adapter" terminal "$TMP/error.result"

seed 100
content=$(printf '%1801s' x | tr ' ' x)
long=$(message 104 human 1532391545356161094 "$content")
result=$(poll "[$long]")
[ "$(jq -r '.content | length' <<<"$result")" = 1800 ]

printf '%s\n' "PASS: Discord mention adapter public poll behavior"
