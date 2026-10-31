# shellcheck shell=bash
# Profile validation and known domain/pair resolution.
# Usage: . bin/fm-profile-lib.sh
# fm_profile_file_valid <file> sets normalized FM_PROFILE_JSON or FM_PROFILE_ERROR.
# fm_profile_entry <profession-id> sets FM_PROFILE_ENTRY from the shipped catalog.
# fm_profile_pair_entry <domain/pair> resolves only an exact known pair.
# Code/data always come from this library's checkout, never the private home.
# docs/configuration.md "Professional profile" owns the public schema.
FM_PROFILE_CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_PROFILE_CATALOG_JSON=
FM_PROFILE_ENTRY=
FM_PROFILE_JSON=
FM_PROFILE_ERROR=

fm_profile_catalog_load() {
  local file="$FM_PROFILE_CODE_ROOT/docs/professions/catalog.json"
  FM_PROFILE_ERROR="missing or invalid shipped profession catalog"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  FM_PROFILE_CATALOG_JSON=$(jq -cse '
    select(length == 1) | .[0]
    | select(.schema_version == 1 and (.themes | type == "object"))
    | select(.shared_duties == "docs/professions/partnership-v1.md")
    | select(.professions["firstmate-v1"].contract == "docs/professions/firstmate-v1.md")
    | select(.professions | to_entries | all(.[];
        (.key == "firstmate-v1") or
        (.value.pair | type == "string" and test("^[a-z][a-z0-9-]*/[a-z][a-z0-9-]*\\z"))))
  ' "$file" 2>/dev/null) && [ -n "$FM_PROFILE_CATALOG_JSON" ] || return 1
  FM_PROFILE_ERROR=
}

fm_profile_entry() {
  local ident=$1
  fm_profile_catalog_load || return 1
  FM_PROFILE_ERROR="unknown profession; use a selector from the shipped catalog"
  FM_PROFILE_ENTRY=$(printf '%s\n' "$FM_PROFILE_CATALOG_JSON" | jq -ce --arg ident "$ident" '
    . as $catalog | .professions[$ident] | select(. != null)
    | . + {profession: $ident, pair: (.pair // null),
        contract: (if .pair then "docs/professions/" + .pair + "/profession.md" else .contract end),
        preset: (if .pair then "docs/professions/" + .pair + "/profile.json" else null end),
        duties: (if .pair then $catalog.shared_duties else null end)}
  ') && [ -n "$FM_PROFILE_ENTRY" ] || return 1
  FM_PROFILE_ERROR=
}

fm_profile_pair_entry() {
  local pair=$1 ident
  fm_profile_catalog_load || return 1
  FM_PROFILE_ERROR="unknown preset; use an exact domain/pair from fm-profile.sh presets"
  ident=$(printf '%s\n' "$FM_PROFILE_CATALOG_JSON" | jq -er --arg pair "$pair" '
    [.professions | to_entries[] | select(.value.pair == $pair) | .key]
    | select(length == 1) | .[0]
  ') || return 1
  fm_profile_entry "$ident"
}

fm_profile_file_valid() {
  local file=$1 links bytes raw ident preset defaults
  FM_PROFILE_JSON=
  FM_PROFILE_ERROR="expected a regular single-linked profile beneath a non-symlinked parent"
  [ ! -L "${file%/*}" ] && [ ! -L "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then links=$(/usr/bin/stat -f %l "$file") || return 1
  else links=$(stat -c %h "$file") || return 1; fi
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]') || return 1
  FM_PROFILE_ERROR="profile must be at most 4096 bytes"
  [ "$bytes" -le 4096 ] || return 1
  FM_PROFILE_ERROR="invalid profile schema or fields; see docs/configuration.md Professional profile"
  raw=$(jq -cse '
    select(length == 1) | .[0] | select(type == "object")
    | select((keys - ["schema_version", "profession", "theme", "chat"] | length) == 0)
    | select(.schema_version == 1 and (.profession | type == "string"))
    | select((has("chat") | not) or (.chat | type == "object"))
    | select((.chat // {} | keys - ["user_address", "user_marker", "assistant_reply_marker"] | length) == 0)
  ' "$file" 2>/dev/null) && [ -n "$raw" ] || return 1
  ident=$(printf '%s\n' "$raw" | jq -r .profession)
  fm_profile_entry "$ident" || return 1
  preset=$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -r '.preset // empty')
  FM_PROFILE_ERROR="missing or invalid shipped profile preset"
  if [ -n "$preset" ]; then
    [ -f "$FM_PROFILE_CODE_ROOT/$preset" ] && [ ! -L "$FM_PROFILE_CODE_ROOT/$preset" ] || return 1
    defaults=$(jq -cse --arg ident "$ident" 'select(length == 1) | .[0] | select(.profession == $ident)' "$FM_PROFILE_CODE_ROOT/$preset" 2>/dev/null) || return 1
  else
    defaults=$(printf '%s\n' "$FM_PROFILE_ENTRY" | jq -ce .defaults) || return 1
  fi
  printf '%s\n' "$defaults" | jq -e '
    .schema_version == 1 and (.theme | type == "string") and (.chat | type == "object")
    and (.chat.user_address | type == "string") and (.chat.user_marker | type == "string")
    and (.chat.assistant_reply_marker | type == "string")
  ' >/dev/null || return 1
  FM_PROFILE_ERROR="invalid profile theme or chat field; see docs/configuration.md Professional profile"
  # Validate user-controlled fields before merging their defaults.
  FM_PROFILE_JSON=$(printf '%s\n' "$raw" | jq -ce --argjson defaults "$defaults" --argjson catalog "$FM_PROFILE_CATALOG_JSON" '
    def address: . == "Captain (Κυβερνήτης)" or (type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,31}$") and all(explode[]; . >= 32 and . != 127));
    select((has("theme") | not) or (.theme | type == "string"))
    | .theme = (.theme // $defaults.theme)
    | .theme as $theme | select($catalog.themes | has($theme))
    | .chat = (.chat // {})
    | select((.chat | has("user_address") | not) or (.chat.user_address | address))
    | select((.chat | has("user_marker") | not) or .chat.user_marker == ""
      or .chat.user_marker == $defaults.chat.user_marker
      or .chat.user_marker == $catalog.professions["firstmate-v1"].defaults.chat.user_marker)
    | select((.chat | has("assistant_reply_marker") | not) or .chat.assistant_reply_marker == $defaults.chat.assistant_reply_marker)
    | .chat = ($defaults.chat + .chat) | .configured = true
  ' 2>/dev/null) && [ -n "$FM_PROFILE_JSON" ] || return 1
  FM_PROFILE_ERROR=
}
