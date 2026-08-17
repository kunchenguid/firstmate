#!/usr/bin/env bash
# fm-instructions-generated-parity.sh - compare generated instruction surfaces
# with the exact upstream parent of the current prompt overlay.
#
# This checks canonical ship, scout, and secondmate briefs; all supported and
# fallback primary supervision renderings; the operational launch wrapper; and
# normalized hook configuration. It prints one result line per surface class
# and exits nonzero on the first difference.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINEAGE="$ROOT/docs/verification/prompt-lineage.json"
ARCHIVE_META=$(python3 - "$ROOT" "$LINEAGE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
lineage = Path(sys.argv[2])
data = json.loads(lineage.read_text(encoding="utf-8"))
live = next(
    (item for item in data["generations"] if item.get("kind") == "live-overlay"),
    None,
)
if live is None or not live.get("upstream_commit"):
    raise SystemExit("lineage does not bind the generated-parity upstream commit")
baseline = live["upstream_commit"]
refresh = data.get("semantic_refresh")
if refresh is None:
    if baseline != "9823ff899c58319e5a09846b18f2958018598b38":
        raise SystemExit("generated-parity lineage does not match the fixed upstream baseline")
elif refresh.get("schema_version") != 1 or refresh.get("upstream") != baseline or not refresh.get("overlay"):
    raise SystemExit("generated-parity lineage has malformed semantic-refresh evidence")
encoded_hash = live.get("generated_parity_artifact_sha256")
archive_hash = live.get("generated_parity_archive_sha256")
if not all(isinstance(value, str) and value for value in (baseline, encoded_hash, archive_hash)):
    raise SystemExit("generated-parity lineage has incomplete semantic-refresh bindings")
artifact = (root / live.get("generated_parity_artifact", "")).resolve()
try:
    artifact.relative_to(root)
except ValueError:
    raise SystemExit("generated-parity archive escapes the repository") from None
if not artifact.is_file():
    raise SystemExit("generated-parity archive is missing")
if hashlib.sha256(artifact.read_bytes()).hexdigest() != encoded_hash:
    raise SystemExit("generated-parity artifact bytes differ from lineage authority")
print(artifact)
print(baseline)
print(archive_hash)
PY
)
ARCHIVE=$(printf '%s\n' "$ARCHIVE_META" | sed -n '1p')
EXPECTED_ARCHIVE_SHA256=$(printf '%s\n' "$ARCHIVE_META" | sed -n '3p')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-instructions-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/baseline" "$TMP/current" "$TMP/home/data" "$TMP/home/state" "$TMP/render-root/config"
python3 - "$ARCHIVE" "$TMP/baseline" "$EXPECTED_ARCHIVE_SHA256" <<'PY'
import base64
import hashlib
import io
import sys
import tarfile
from pathlib import Path, PurePosixPath

archive, destination = map(Path, sys.argv[1:3])
encoded = b"".join(archive.read_bytes().split())
try:
    raw = base64.b64decode(encoded, validate=True)
except ValueError as error:
    raise SystemExit(f"generated-parity archive is malformed: {error}") from error
if hashlib.sha256(raw).hexdigest() != sys.argv[3]:
    raise SystemExit("generated-parity archive hash differs from fixed authority")
with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as source:
    for member in source.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
            raise SystemExit(f"generated-parity archive has unsafe member: {member.name}")
    source.extractall(destination)
PY

generate_briefs() { # <source-root> <output-dir>
  local source_root=$1 output_dir=$2 id
  rm -rf "$TMP/home/data"
  mkdir -p "$TMP/home/data" "$output_dir"
  for mode in no-mistakes direct-PR local-only; do
    id="parity-ship-${mode}"
    FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/render-root" \
      "$source_root/bin/fm-brief.sh" "$id" firstmate --mode "$mode" >/dev/null
    cp "$TMP/home/data/$id/brief.md" "$output_dir/ship-$mode.md"
  done
  id=parity-scout
  FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/render-root" \
    "$source_root/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null
  cp "$TMP/home/data/$id/brief.md" "$output_dir/scout.md"
  id=parity-secondmate
  FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/render-root" \
    FM_SECONDMATE_CHARTER='Parity charter.' FM_SECONDMATE_SCOPE='Parity scope.' \
    "$source_root/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null
  cp "$TMP/home/data/$id/brief.md" "$output_dir/secondmate.md"
}

generate_supervision() { # <source-root> <output>
  local source_root=$1 output=$2 harness read_only afk x_mode queue
  : > "$output"
  for harness in claude codex opencode pi pi-signed grok cursor kimi muse unknown; do
    for flags in '0 0 0 0' '1 0 0 1' '0 1 1 1'; do
      read -r read_only afk x_mode queue <<EOF
$flags
EOF
      {
        printf '=== %s %s ===\n' "$harness" "$flags"
        FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/render-root" \
          "$source_root/bin/fm-supervision-instructions.sh" --harness "$harness" \
          --read-only "$read_only" --afk "$afk" --x-mode "$x_mode" \
          --queue-pending "$queue"
        FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/render-root" \
          "$source_root/bin/fm-supervision-instructions.sh" --harness "$harness" \
          --read-only "$read_only" --afk "$afk" --x-mode "$x_mode" \
          --queue-pending "$queue" --repair-line
      } >> "$output"
    done
  done
}

generate_briefs "$TMP/baseline" "$TMP/baseline-output"
generate_briefs "$ROOT" "$TMP/current-output"
diff -ru "$TMP/baseline-output" "$TMP/current-output" >&2 || {
  echo 'generated ship/scout/secondmate brief bytes differ from baseline' >&2
  exit 1
}
echo 'ok generated briefs ship/scout/secondmate'

generate_supervision "$TMP/baseline" "$TMP/baseline-supervision"
generate_supervision "$ROOT" "$TMP/current-supervision"
cmp -s "$TMP/baseline-supervision" "$TMP/current-supervision" || {
  echo 'generated supervision bytes differ from baseline' >&2
  exit 1
}
echo 'ok generated supervision all primary harness identities and fallbacks'

printf '%s' 'Read the brief before acting.' | "$TMP/baseline/bin/fm-operational-input.sh" encode launch-brief > "$TMP/baseline-launch"
printf '%s' 'Read the brief before acting.' | "$ROOT/bin/fm-operational-input.sh" encode launch-brief > "$TMP/current-launch"
cmp -s "$TMP/baseline-launch" "$TMP/current-launch" || {
  echo 'generated operational launch wrapper differs from baseline' >&2
  exit 1
}
echo 'ok generated operational launch wrapper'

python3 - "$TMP/baseline" "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

baseline, current = map(Path, sys.argv[1:])
for relative in (".claude/settings.json", ".codex/hooks.json"):
    with (baseline / relative).open(encoding="utf-8") as handle:
        expected = json.load(handle)
    with (current / relative).open(encoding="utf-8") as handle:
        actual = json.load(handle)
    if actual != expected:
        raise SystemExit(f"normalized hook configuration differs from baseline: {relative}")
PY
echo 'ok normalized hook configuration semantics'
