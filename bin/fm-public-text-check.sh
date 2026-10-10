#!/usr/bin/env bash
# Public evidence policy and deterministic text check for Firstmate publication.
# Public PR descriptions, comments, review descriptions and Relay replies use
# self-contained factual explanations or verified public URLs as evidence.
# Keep machine-local paths and local-only evidence references in private task
# records, not in publication text, even when labeled "Private proof".
# Repository-relative source paths and intended system-path examples are valid.
# This check rejects recognizable local locations and private evidence roots;
# it does not prove a URL is public, inspect attachments, or classify arbitrary
# prose. Authors must verify URL accessibility and inspect remaining text.
# Run before create/edit/post on the exact outgoing text. Relay enforces this
# before transport; GitHub PR readiness checks are later detection, not prevention.
# GitLab and Gerrit receive written pre-publication instructions only, without
# automatic readiness refusal; provider read-back is separate follow-up work.
# no-mistakes and forge CLIs own their generated outbound text: Firstmate cannot
# intercept those publications with this check alone.
# Usage: fm-public-text-check.sh <text-file|->
# Exit 0: no recognized private reference; 1: unsafe/unreadable; 2: usage.
# Diagnostics name only line numbers, never echo sensitive input. No redaction
# or input mutation: retain the original privately and author useful public text.
set -eu
case "${1:-}" in
  --help|-h)
    printf '%s\n' 'Usage: fm-public-text-check.sh <text-file|->' \
      'Check exact outgoing publication text; rejected input is never changed.' \
      'Use verified public URLs or self-contained facts; retain local evidence privately.' \
      'Recognizes local filesystem locations and private evidence roots, not all secrets.' \
      'Repository-relative source paths and system-path examples remain valid.'
    exit 0 ;;
esac
[ "$#" -eq 1 ] || { echo 'error: expected one text file or stdin (-)' >&2; exit 2; }
if [ "$1" != - ]; then
  [ -f "$1" ] && [ -r "$1" ] || { echo 'error: publication text is unreadable' >&2; exit 1; }
  exec < "$1"
fi
awk '
{
  text = tolower($0)
  # URL paths are not filesystem paths. Reject explicitly local URL hosts first.
  unsafe = text ~ /https?:\/\/([^\/@[:space:]]+@)?(localhost|127\.[0-9.]+|10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+|\[::1\]|[^\/[:space:]]+\.local)([:\/[:space:]]|$)/
  gsub(/https?:\/\/[^[:space:]<>"`]+/, "", text)
  if (text ~ /file:\/\// ||
      text ~ /(^|[^[:alnum:]_.-])\/(users|home|root|tmp|private|volumes|mnt|media|workspace|srv|opt)\// ||
      text ~ /(^|[^[:alnum:]_.-])\/var\/(folders|tmp)\// ||
      text ~ /(^|[^[:alnum:]_.-])~\// ||
      text ~ /(^|[^[:alnum:]_.-])[a-z]:[\\\/]/ ||
      text ~ /\\\\[[:alnum:]_.-]+\\/ ||
      text ~ /(^|[^[:alnum:]_.-])(\.no-mistakes|\.treehouse)\// ||
      text ~ /(^|[^[:alnum:]_])(private proof|private evidence|local proof|local evidence)[[:space:]]*:/)
    unsafe = 1
  if (unsafe) {
    printf "error: publication text contains a local or private reference at line %d; retain evidence privately and supply public facts or a verified public URL\n", NR > "/dev/stderr"
    failed = 1
  }
}
END { exit failed ? 1 : 0 }
'
