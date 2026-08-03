#!/usr/bin/env bash
# fm-video-watch.sh - prepare bounded video evidence manifests for Firstmate /watch.
#
# Public interface:
#   fm-video-watch.sh doctor
#   fm-video-watch.sh prepare <public-url-or-local-video> [options]
#   fm-video-watch.sh cleanup <opaque-receipt>
#   fm-video-watch.sh smoke --url <public-url> --i-understand-this-uses-network [prepare options]
#
# This script owns the user-visible mechanics, limits, media and coverage contract,
# cleanup receipt handling, and exit-code classes for the Firstmate watch skill.
# A public URL is fetched exactly as supplied, so providers that carry the video
# identity in query parameters keep working; URLs bearing credential, signature,
# session, or token query fields are refused, and the manifest description prints
# query values only for known public identifier keys.
# Transient public media is bounded by --max-media-bytes: 4 GiB by default, up to
# 16 GiB when local free space proves sufficient, enforced before download and
# again after acquisition. A focused run takes whichever bounded route is
# projected cheaper: a provider section when the requested span is a small share
# of the source, otherwise the whole media when it already fits the ceiling,
# because a section is re-encoded rather than stream-copied. Manifest field
# media.visual_coverage reports full, section, or none, media.acquisition_reason
# records why that route was taken, and a refused acquisition still returns
# transcript and chapter evidence plus a focused-pass recommendation.
# Its private Python implementation preserves and adapts useful MIT mechanics from
# bradautomates/claude-video at git revision 755c157466738dda102c939158a0116b972925a3.
# It does not depend on ~/.claude/skills/watch, does not install dependencies,
# does not use browser profiles or cookies, and does not read or write
# ~/.config/watch/.env.
#
# Exit codes:
#   0 success
#   2 command-line usage or invalid input
#   3 missing required local dependency
#   4 unsupported, unsafe, authenticated, DRM, playlist, or live source
#   5 media probing, download, frame extraction, or cleanup failed, insufficient local
#     free space for the transient copy, or an unexpected internal failure
#
# This header and the exit classes above are the prose contract; use --help for the
# exact subcommands, flags, defaults, and limits, and read the emitted manifest for
# its own field set.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$SELF_DIR/fm-video-watch-impl.py"

exec python3 "$IMPL" "$@"
