#!/usr/bin/env bash
# Reproduce the public ingest boundary for correlated UTF-8 status text.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="${TMPDIR:-/tmp}/utf8-ingest-repro"
rm -rf "$TMP"
mkdir -p "$TMP/parent/state" "$TMP/parent/data" "$TMP/remote/state"
cat > "$TMP/parent/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $TMP/remote; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf 'working [corr=0123456789abcdef]: reviewer\xe2\x80\x99s note complete\n' > "$TMP/remote/state/parent-replies.status"
PAYLOAD="$TMP/payload.txt"
cp "$TMP/remote/state/parent-replies.status" "$PAYLOAD"
BYTES=$(LC_ALL=C wc -c < "$PAYLOAD" | tr -d ' ')
HASH=$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')
EMPTY_HASH=$(shasum -a 256 /dev/null | awk '{print $1}')
{
  printf 'schema=fm-remote-delta.v1\n'
  printf 'status=delta\n'
  printf 'path=state/parent-replies.status\n'
  printf 'from_offset=0\n'
  printf 'to_offset=%s\n' "$BYTES"
  printf 'from_prefix_sha256=%s\n' "$EMPTY_HASH"
  printf 'to_prefix_sha256=%s\n' "$HASH"
  printf 'payload_sha256=%s\n' "$HASH"
  printf 'payload_bytes=%s\n' "$BYTES"
  printf 'reason=\n\n'
  cat "$PAYLOAD"
} > "$TMP/utf8.result"
FM_HOME="$TMP/parent" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "$TMP/utf8.result"
