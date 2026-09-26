#!/usr/bin/env bash
# fm-osmo.sh - DJI Osmo Pocket video clip cataloging, pairing, sampling, and classification.
#
# Discovers the connected DJI Osmo Pocket drive strictly read-only, pairs master
# MP4 and low-resolution proxy LRF files, transcribes audio via local headless CLI
# or Superwhisper, samples frames locally, classifies clips as A-roll, B-roll, or
# mixed, caches derived analysis deterministically outside the device, and
# generates a local Markdown report.
#
# Hard safety boundary:
#   The Osmo storage drive (/Volumes/Osmo) is treated as strictly read-only.
#   Never writes, deletes, renames, moves, or creates sidecars on the drive.
#   All caches, extracted frames, audio files, and reports are stored locally
#   in a cache directory outside the device.
#
# Subcommands:
#   discover             Verify Osmo drive discovery and read-only status.
#   scan                 Scan DCIM directory and pair MP4/LRF video clips.
#   catalog              Run full visual sampling, audio speech analysis, clip
#                        classification (A-roll/B-roll/Mixed), caching, and report.
#   report               Display the latest generated catalog report.
#
# Options:
#   --drive <path>       Custom Osmo drive mount path (default: /Volumes/Osmo).
#   --cache-dir <path>   Local directory for derived caches and reports
#                        (default: ~/.firstmate/osmo-catalog-cache).
#   --output <path>      Custom path to write Markdown report.
#   --transcriber <cmd>  Free fully local headless CLI transcriber command.
#   --sample-count <N>   Number of visual frames to sample per clip (default: 5).
#   --force              Force re-processing of cached clips.
#   --json               Output structured JSON instead of human-readable text.
#   -h, --help           Print this help text.
#
# Environment variables:
#   FM_OSMO_DRIVE        Default drive mount point override.
#   FM_OSMO_CACHE_DIR    Default local cache directory override.
#   FM_OSMO_TRANSCRIBER  Default local headless CLI transcriber command override.
#   FM_OSMO_WHISPER_MODEL Local whisper model checkpoint path override.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="${PYTHON_EXEC:-python3}"

usage() {
  cat <<'EOF'
Usage:
  fm-osmo.sh [discover] [--drive <path>] [--json]
  fm-osmo.sh scan       [--drive <path>] [--json]
  fm-osmo.sh catalog    [--drive <path>] [--cache-dir <dir>] [--output <file>]
                        [--transcriber <cmd>] [--sample-count <N>] [--force] [--json]
  fm-osmo.sh report     [--cache-dir <dir>] [--json]
  fm-osmo.sh -h | --help

Subcommands:
  discover    Verify Osmo drive discovery and read-only status.
  scan        Scan DCIM directory and pair MP4/LRF video clips.
  catalog     Run full sampling, audio analysis, classification, and reporting (default).
  report      Display the latest generated catalog report.

Options:
  --drive <path>       Osmo drive mount path (default: /Volumes/Osmo).
  --cache-dir <dir>    Local cache directory (default: ~/.firstmate/osmo-catalog-cache).
  --output <file>      Path to write Markdown report.
  --transcriber <cmd>  Free fully local headless CLI transcriber command.
  --sample-count <N>   Number of visual frames to sample per clip (default: 5).
  --force              Force re-processing of cached clips.
  --json               Output JSON format.
  -h, --help           Show this help message.
EOF
}

# Check for help flag in arguments
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    usage
    exit 0
  fi
done

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
  echo "fm-osmo: error: python3 is required but not found in PATH" >&2
  exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-osmo.py" "$@"
