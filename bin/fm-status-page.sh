#!/usr/bin/env bash
# Present one saved unread-status page, then acknowledge only its contiguous
# byte range. Usage: fm-status-page.sh <page-directory>
# Pages are private immutable artifacts produced by fm-wake-drain.sh; they
# survive resets and failed stdout. Re-reading a delivered page is harmless.
# A page from a replaced log or with an undelivered predecessor is refused.
# Display receipts never process branch outcomes, answer decisions, or resolve
# correlations. Artifacts are retained for explicit inspection, not deleted.
set -eu
case "${1:-}" in
  -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/fm-classify-lib.sh"
page=${1:?usage: fm-status-page.sh <page-directory>}
[ -d "$page" ] && [ ! -L "$page" ] || exit 1
for part in body receipt state checksum; do
  [ -f "$page/$part" ] && [ ! -L "$page/$part" ] || exit 1
done
state=$(cat "$page/state")
export FM_STATE_OVERRIDE="$state"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
IFS=$'\t' read -r task start end ident < "$page/receipt"
case "$task" in ''|*[!a-zA-Z0-9_.-]*) exit 1 ;; esac
case "$start:$end" in *[!0-9:]*|:*|*:) exit 1 ;; esac
[ "$start" -le "$end" ] || exit 1
digest=$(perl -MDigest::SHA -e 'my $d=Digest::SHA->new(256); for (@ARGV) { open my $f,"<",$_ or exit 1; binmode $f; $d->addfile($f); } print $d->hexdigest' \
  "$page/body" "$page/receipt" "$page/state")
[ "$digest" = "$(cat "$page/checksum")" ] || { echo 'status page: damaged evidence; drain again' >&2; exit 1; }
lock="$state/.status-presentation-lock"
fm_lock_acquire_wait_bounded "$lock" 10 || exit 1
trap 'fm_lock_release "$lock"' EXIT
f="$state/$task.status"
[ "$(_fm_open_decisions_file_ident "$f")" = "$ident" ] || { echo 'status page: source generation changed; drain again' >&2; exit 1; }
offset=$(status_presentation_cursor_offset "$f")
[ "$offset" -ge "$start" ] || { echo 'status page: present the preceding page first' >&2; exit 1; }
[ "$end" -le "$(_fm_status_file_size "$f")" ] || exit 1
snapshot=$(status_presentation_snapshot "$state")
receipt=''
while IFS=$'\t' read -r row endpoint generation; do
  [ -n "$row" ] || continue
  position=$(status_presentation_cursor_offset "$state/$row.status")
  if [ "$row" = "$task" ] && [ "$position" -lt "$end" ]; then position=$end; fi
  receipt="$receipt$row"$'\t'"$position"$'\t'"$generation"$'\n'
done <<< "$snapshot"
cat "$page/body" || exit 1
status_commit_presentation_snapshot "$state" "$receipt"
if [ -f "$page/next" ]; then
  printf 'UNREAD STATUS continuation: bash %q %q\n' "$SCRIPT_DIR/fm-status-page.sh" "$(cat "$page/next")"
fi
