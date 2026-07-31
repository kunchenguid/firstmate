#!/usr/bin/env bash
# Render one secure Markdown-subset source into a restart-stable private
# Telegram HTML/plain snapshot bound to an outbound receipt ID.
# Existing snapshots are immutable: the same receipt/source hash is idempotent,
# while a different source is an identity collision.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-telegram-lib.sh
. "$SCRIPT_DIR/fm-telegram-lib.sh"

usage() {
  echo "usage: fm-telegram-render.sh <receipt_id> --text-file <mode-0600-file>" >&2
}

receipt_id=${1:-}
shift || true
fmtg_safe_slug "$receipt_id" 128 || { usage; exit 2; }
TEXT_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file)
      [ "$#" -gt 1 ] || { usage; exit 2; }
      TEXT_FILE=$2
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$TEXT_FILE" ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "telegram render: jq is required" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "telegram render: perl is required" >&2; exit 1; }
fmtg_prepare_state || { echo "telegram render: private state is unsafe" >&2; exit 1; }

SOURCE_TMP=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-telegram-render-source.XXXXXX") || exit 1
chmod 0600 "$SOURCE_TMP" || { rm -f -- "$SOURCE_TMP"; exit 1; }
trap 'rm -f -- "$SOURCE_TMP"' EXIT
fm_private_read_file "$TEXT_FILE" 600 > "$SOURCE_TMP" \
  || { echo "telegram render: text file must be owner-only mode 0600, regular, and single-link" >&2; exit 1; }
SOURCE_HASH=$(perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)' < "$SOURCE_TMP") \
  || { echo "telegram render: could not hash source" >&2; exit 1; }
SNAPSHOT="$FMTG_STATE/rendered/$receipt_id.json"
if [ -e "$SNAPSHOT" ] || [ -L "$SNAPSHOT" ]; then
  existing=$(fm_private_read_file "$SNAPSHOT" 600 2>/dev/null) \
    || { echo "telegram render: existing snapshot is unsafe" >&2; exit 1; }
  if ! printf '%s' "$existing" | jq -e --arg receipt "$receipt_id" --arg hash "$SOURCE_HASH" '
    .schema == "firstmate.telegram-rendered.v1"
    and .receipt_id == $receipt
    and .source_sha256 == $hash
    and (.presentation.schema == "firstmate.telegram-presentation.v1")
  ' >/dev/null 2>&1; then
    echo "telegram render: receipt presentation identity collision" >&2
    exit 1
  fi
  printf 'rendered %s %s\n' "$receipt_id" "$(printf '%s' "$existing" | jq -r '.presentation.messages | length')"
  exit 0
fi

PRESENTATION=$("$SCRIPT_DIR/fm-telegram-present.pl" < "$SOURCE_TMP" 2>/dev/null) \
  || { echo "telegram render: source is invalid or exceeds presentation bounds" >&2; exit 1; }
SNAPSHOT_JSON=$(printf '%s' "$PRESENTATION" | jq -c \
  --arg receipt "$receipt_id" --arg hash "$SOURCE_HASH" '
    {schema:"firstmate.telegram-rendered.v1",receipt_id:$receipt,source_sha256:$hash,presentation:.}
  ') || { echo "telegram render: presentation output is invalid" >&2; exit 1; }
printf '%s\n' "$SNAPSHOT_JSON" | fmtg_json_publish_once "$FMTG_STATE/rendered" "$receipt_id.json"
rc=$?
case "$rc" in
  0) ;;
  1) echo "telegram render: concurrent snapshot already exists; retry exact receipt" >&2; exit 1 ;;
  *) echo "telegram render: could not publish private snapshot" >&2; exit 1 ;;
esac
printf 'rendered %s %s\n' "$receipt_id" "$(printf '%s' "$PRESENTATION" | jq -r '.messages | length')"
