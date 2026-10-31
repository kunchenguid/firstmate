# shellcheck shell=bash
# Versioned profile parser shared by rendering and config inheritance.
# Usage: . bin/fm-profile-lib.sh
# fm_profile_file_valid <file> validates without changing any file and sets
# FM_PROFILE_JSON (normalized JSON) or FM_PROFILE_ERROR (diagnostic).
# The schema is owned by docs/configuration.md "Professional profile".

FM_PROFILE_JSON=
FM_PROFILE_ERROR=

fm_profile_file_valid() {
  local file=$1 links bytes
  FM_PROFILE_JSON=
  FM_PROFILE_ERROR="expected a regular single-linked profile beneath a non-symlinked config directory"
  [ ! -L "${file%/*}" ] && [ ! -L "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(/usr/bin/stat -f %l "$file") || return 1
  else
    links=$(stat -c %h "$file") || return 1
  fi
  [ "$links" = 1 ] || return 1
  bytes=$(LC_ALL=C wc -c < "$file" | tr -d '[:space:]') || return 1
  FM_PROFILE_ERROR="profile must be at most 4096 bytes"
  [ "$bytes" -le 4096 ] || return 1
  FM_PROFILE_ERROR="invalid profile schema, profession, theme or chat field; see docs/configuration.md Professional profile"
  FM_PROFILE_JSON=$(jq -cse '
    def only($fields): (keys - $fields | length) == 0;
    def address: type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,31}$") and all(explode[]; . >= 32 and . != 127);
    if length != 1 then error("one JSON object required") else .[0] end
    | select(type == "object")
    | select(only(["schema_version", "profession", "theme", "chat"]))
    | select(.schema_version == 1 and (.profession == "firstmate-v1" or .profession == "director-v1"))
    | select((has("theme") | not) or .theme == "nautical" or .theme == "space-fleet")
    | select((has("chat") | not) or (.chat | type == "object"))
    | .theme = (.theme // "nautical")
    | .chat = (.chat // {})
    | select(.chat | only(["user_address", "user_marker", "assistant_reply_marker"]))
    | select((.chat | has("user_address") | not) or (.chat.user_address | address))
    | select((.chat | has("user_marker") | not) or (.chat.user_marker == "✈️" or .chat.user_marker == ""))
    | .profession as $profession
    | select((.chat | has("assistant_reply_marker") | not)
      or .chat.assistant_reply_marker == (if $profession == "director-v1" then "🎬" else "" end))
    | .chat.user_address = (.chat.user_address // "pilot")
    | .chat.user_marker = (.chat.user_marker // "✈️")
    | .chat.assistant_reply_marker = (if .profession == "director-v1" then "🎬" else "" end)
    | .configured = true
  ' "$file" 2>/dev/null) && [ -n "$FM_PROFILE_JSON" ] || return 1
  FM_PROFILE_ERROR=
}
