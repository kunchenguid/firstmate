#!/usr/bin/env bash
# tests/fm-osmo.test.sh - test suite for Osmo Pocket cataloging and classification.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OSMO_CMD="$ROOT/bin/fm-osmo.sh"
TMP_ROOT=$(fm_test_tmproot fm-osmo-tests)

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label: expected '$expected' but got '$actual'"
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label: expected text to contain '$needle'"
  fi
}

# -----------------------------------------------------------------------------
# Test 1: Discover missing drive
# -----------------------------------------------------------------------------
test_discover_missing_drive() {
  local missing_path="$TMP_ROOT/nonexistent-osmo-drive"
  local json_out
  json_out=$("$OSMO_CMD" discover --drive "$missing_path" --json)

  local found
  found=$(echo "$json_out" | jq -r '.found')
  assert_eq "false" "$found" "discover missing drive returns found=false"

  local rc=0
  "$OSMO_CMD" discover --drive "$missing_path" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "discover missing drive exits with non-zero status"
  else
    fail "discover missing drive should have exited non-zero"
  fi
}

# -----------------------------------------------------------------------------
# Test 2: Discover empty drive (no DCIM or videos)
# -----------------------------------------------------------------------------
test_discover_empty_drive() {
  local empty_path="$TMP_ROOT/empty-drive"
  mkdir -p "$empty_path"

  local json_out
  json_out=$("$OSMO_CMD" discover --drive "$empty_path" --json)

  local found
  found=$(echo "$json_out" | jq -r '.found')
  assert_eq "false" "$found" "discover empty drive without DCIM returns found=false"
}

# -----------------------------------------------------------------------------
# Test 3: Discover valid drive with DCIM and AppleDouble dot-underscore files
# -----------------------------------------------------------------------------
test_discover_valid_drive() {
  local fixture_drive="$TMP_ROOT/drive-valid"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  # Create dummy video files
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914120000_0001_D.MP4"
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914120000_0001_D.LRF"
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914121500_0002_D.MP4"

  # Create macOS dot-underscore hidden file that must be ignored
  touch "$fixture_drive/DCIM/DJI_001/._DJI_20260914120000_0001_D.MP4"

  local json_out
  json_out=$("$OSMO_CMD" discover --drive "$fixture_drive" --json)

  local found ro total
  found=$(echo "$json_out" | jq -r '.found')
  ro=$(echo "$json_out" | jq -r '.read_only_verified')
  total=$(echo "$json_out" | jq -r '.total_files')

  assert_eq "true" "$found" "discover valid drive finds DCIM"
  assert_eq "true" "$ro" "discover verifies read-only access"
  assert_eq "3" "$total" "discover ignores dot-underscore metadata files"
}

# -----------------------------------------------------------------------------
# Test 4: Scan and pair MP4 and LRF files
# -----------------------------------------------------------------------------
test_scan_pairing() {
  local fixture_drive="$TMP_ROOT/drive-pairing"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  # Pair 1: Both MP4 and LRF exist
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914150000_0001_D.MP4"
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914150000_0001_D.LRF"

  # Clip 2: MP4 only
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914153000_0002_D.MP4"

  # Clip 3: LRF only
  touch "$fixture_drive/DCIM/DJI_001/DJI_20260914160000_0003_D.LRF"

  local scan_json
  scan_json=$("$OSMO_CMD" scan --drive "$fixture_drive" --json)

  local clip1_pair clip2_pair clip3_pair clip1_dt
  clip1_pair=$(echo "$scan_json" | jq -r '.clips[] | select(.stem=="DJI_20260914150000_0001_D") | .pair_status')
  clip2_pair=$(echo "$scan_json" | jq -r '.clips[] | select(.stem=="DJI_20260914153000_0002_D") | .pair_status')
  clip3_pair=$(echo "$scan_json" | jq -r '.clips[] | select(.stem=="DJI_20260914160000_0003_D") | .pair_status')
  clip1_dt=$(echo "$scan_json" | jq -r '.clips[] | select(.stem=="DJI_20260914150000_0001_D") | .recorded_at')

  assert_eq "paired" "$clip1_pair" "scan correctly identifies paired clip"
  assert_eq "mp4_only" "$clip2_pair" "scan correctly identifies mp4_only clip"
  assert_eq "lrf_only" "$clip3_pair" "scan correctly identifies lrf_only clip"
  assert_eq "2026-09-14T15:00:00" "$clip1_dt" "scan parses timestamp from DJI filename"
}

# -----------------------------------------------------------------------------
# Test 5: End-to-end cataloging, sampling, classification, and reporting
# -----------------------------------------------------------------------------
test_catalog_e2e() {
  local fixture_drive="$TMP_ROOT/drive-catalog-e2e"
  local cache_dir="$TMP_ROOT/cache-catalog-e2e"
  local out_report="$TMP_ROOT/custom-report.md"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  # Check if ffmpeg is available
  if ! command -v ffmpeg >/dev/null 2>&1; then
    fail "ffmpeg is required for test_catalog_e2e"
  fi

  # Clip 1: A-roll candidate (high speech frequency audio, 2 seconds)
  ffmpeg -f lavfi -i testsrc=duration=2:size=640x360:rate=24 \
         -f lavfi -i sine=frequency=300:duration=2 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914100001_0001_D.MP4" -y >/dev/null 2>&1
  ffmpeg -f lavfi -i testsrc=duration=2:size=320x180:rate=24 \
         -f lavfi -i sine=frequency=300:duration=2 \
         -c:v libx264 -c:a aac -f mp4 \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914100001_0001_D.LRF" -y >/dev/null 2>&1

  # Clip 2: B-roll candidate (ambient / silent audio, 2 seconds)
  ffmpeg -f lavfi -i testsrc=duration=2:size=640x360:rate=24 \
         -f lavfi -i anullsrc=duration=2 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914100500_0002_D.MP4" -y >/dev/null 2>&1
  ffmpeg -f lavfi -i testsrc=duration=2:size=320x180:rate=24 \
         -f lavfi -i anullsrc=duration=2 \
         -c:v libx264 -c:a aac -f mp4 \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914100500_0002_D.LRF" -y >/dev/null 2>&1

  # Run catalog command
  local catalog_json
  catalog_json=$("$OSMO_CMD" catalog \
    --drive "$fixture_drive" \
    --cache-dir "$cache_dir" \
    --output "$out_report" \
    --json)

  # Check summary counts
  local total_clips paired_count a_count b_count
  total_clips=$(echo "$catalog_json" | jq -r '.summary.total_clips')
  paired_count=$(echo "$catalog_json" | jq -r '.summary.paired_count')
  a_count=$(echo "$catalog_json" | jq -r '.summary.a_roll_count')
  b_count=$(echo "$catalog_json" | jq -r '.summary.b_roll_count')

  assert_eq "2" "$total_clips" "catalog found 2 clips"
  assert_eq "2" "$paired_count" "catalog paired 2 MP4/LRF clips"
  assert_eq "1" "$a_count" "catalog identified 1 A-roll clip"
  assert_eq "1" "$b_count" "catalog identified 1 B-roll clip"

  # Check individual classification
  local clip1_cat clip2_cat
  clip1_cat=$(echo "$catalog_json" | jq -r '.clips[] | select(.stem=="DJI_20260914100001_0001_D") | .classification.category')
  clip2_cat=$(echo "$catalog_json" | jq -r '.clips[] | select(.stem=="DJI_20260914100500_0002_D") | .classification.category')
  assert_eq "A-roll" "$clip1_cat" "clip with audio activity is classified as A-roll"
  assert_eq "B-roll" "$clip2_cat" "clip with silent audio is classified as B-roll"

  # Check that frames and audio were extracted outside the device into cache
  local frame1 audio1
  frame1="$cache_dir/frames/DJI_20260914100001_0001_D/frame_01.jpg"
  audio1="$cache_dir/audio/DJI_20260914100001_0001_D/audio.wav"
  if [ -f "$frame1" ] && [ -s "$frame1" ]; then
    pass "visual sample frame extracted to local cache"
  else
    fail "expected frame file at $frame1"
  fi
  if [ -f "$audio1" ] && [ -s "$audio1" ]; then
    pass "audio track extracted to local cache"
  else
    fail "expected audio file at $audio1"
  fi

  # Check Superwhisper limitation documentation
  local note
  note=$(echo "$catalog_json" | jq -r '.superwhisper.limitation_note')
  assert_contains "Superwhisper is a macOS menu bar dictation tool" "$note" "superwhisper interface note documented"

  # Check custom output report
  if [ -f "$out_report" ]; then
    local report_content
    report_content=$(cat "$out_report")
    assert_contains "Osmo Pocket Footage Catalog & Classification Report" "$report_content" "report title present"
    assert_contains "DJI_20260914100001_0001_D" "$report_content" "clip 1 present in report"
    assert_contains "A-roll" "$report_content" "A-roll present in report table"
    assert_contains "B-roll" "$report_content" "B-roll present in report table"
    assert_contains "Creator Workflow Recommendations" "$report_content" "recommendations section present"
  else
    fail "expected custom report at $out_report"
  fi
}

# -----------------------------------------------------------------------------
# Test 6: Read-only invariant (drive files are never modified)
# -----------------------------------------------------------------------------
test_read_only_invariant() {
  local fixture_drive="$TMP_ROOT/drive-readonly-check"
  local cache_dir="$TMP_ROOT/cache-readonly-check"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  ffmpeg -f lavfi -i testsrc=duration=1:size=320x180:rate=24 \
         -f lavfi -i sine=frequency=300:duration=1 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914110000_0001_D.MP4" -y >/dev/null 2>&1

  local before_files before_hash
  before_files=$(find "$fixture_drive" | sort)
  before_hash=$(shasum "$fixture_drive/DCIM/DJI_001/DJI_20260914110000_0001_D.MP4" | awk '{print $1}')

  "$OSMO_CMD" catalog --drive "$fixture_drive" --cache-dir "$cache_dir" >/dev/null 2>&1

  local after_files after_hash
  after_files=$(find "$fixture_drive" | sort)
  after_hash=$(shasum "$fixture_drive/DCIM/DJI_001/DJI_20260914110000_0001_D.MP4" | awk '{print $1}')

  assert_eq "$before_files" "$after_files" "drive file list unchanged after catalog run"
  assert_eq "$before_hash" "$after_hash" "source video file hash unchanged after catalog run"
}

# -----------------------------------------------------------------------------
# Test 7: Deterministic incremental caching
# -----------------------------------------------------------------------------
test_incremental_caching() {
  local fixture_drive="$TMP_ROOT/drive-cache-test"
  local cache_dir="$TMP_ROOT/cache-incremental"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  ffmpeg -f lavfi -i testsrc=duration=1:size=320x180:rate=24 \
         -f lavfi -i sine=frequency=300:duration=1 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914120000_0001_D.MP4" -y >/dev/null 2>&1

  # First run: processes from source
  local run1_json
  run1_json=$("$OSMO_CMD" catalog --drive "$fixture_drive" --cache-dir "$cache_dir" --json)
  local from_cache1
  from_cache1=$(echo "$run1_json" | jq -r '.clips[0].from_cache')
  assert_eq "false" "$from_cache1" "first run processes clip from source"

  # Second run: reuses cache
  local run2_json
  run2_json=$("$OSMO_CMD" catalog --drive "$fixture_drive" --cache-dir "$cache_dir" --json)
  local from_cache2
  from_cache2=$(echo "$run2_json" | jq -r '.clips[0].from_cache')
  assert_eq "true" "$from_cache2" "second run reuses cached clip analysis"

  # Third run with --force: re-processes
  local run3_json
  run3_json=$("$OSMO_CMD" catalog --drive "$fixture_drive" --cache-dir "$cache_dir" --force --json)
  local from_cache3
  from_cache3=$(echo "$run3_json" | jq -r '.clips[0].from_cache')
  assert_eq "false" "$from_cache3" "forced run re-processes cached clip"
}

# -----------------------------------------------------------------------------
# Test 8: Report command
# -----------------------------------------------------------------------------
test_report_command() {
  local fixture_drive="$TMP_ROOT/drive-report-test"
  local cache_dir="$TMP_ROOT/cache-report"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  ffmpeg -f lavfi -i testsrc=duration=1:size=320x180:rate=24 \
         -f lavfi -i anullsrc=duration=1 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914130000_0001_D.MP4" -y >/dev/null 2>&1

  "$OSMO_CMD" catalog --drive "$fixture_drive" --cache-dir "$cache_dir" >/dev/null 2>&1

  local report_out
  report_out=$("$OSMO_CMD" report --cache-dir "$cache_dir")
  assert_contains "Osmo Pocket Footage Catalog & Classification Report" "$report_out" "report command prints title"
  assert_contains "DJI_20260914130000_0001_D" "$report_out" "report command prints cataloged clip"
}

# -----------------------------------------------------------------------------
# Test 9: Free local headless CLI transcription
# -----------------------------------------------------------------------------
test_cli_transcription() {
  local fixture_drive="$TMP_ROOT/drive-transcribe-test"
  local cache_dir="$TMP_ROOT/cache-transcribe-test"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  ffmpeg -f lavfi -i testsrc=duration=1:size=320x180:rate=24 \
         -f lavfi -i sine=frequency=300:duration=1 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914140000_0001_D.MP4" -y >/dev/null 2>&1

  local catalog_json
  catalog_json=$("$OSMO_CMD" catalog \
    --drive "$fixture_drive" \
    --cache-dir "$cache_dir" \
    --transcriber "echo This is transcribed dialogue from the clip" \
    --json)

  local status text source
  status=$(echo "$catalog_json" | jq -r '.clips[0].transcription.status')
  text=$(echo "$catalog_json" | jq -r '.clips[0].transcription.text')
  source=$(echo "$catalog_json" | jq -r '.clips[0].transcription.source')

  assert_eq "transcribed" "$status" "cli transcriber marks status transcribed"
  assert_contains "This is transcribed dialogue" "$text" "cli transcriber captures output text"
  assert_eq "cli_transcriber" "$source" "transcription source indicates cli_transcriber"
}

# -----------------------------------------------------------------------------
# Test 10: Model approval requirement when no local model or CLI transcriber is provided
# -----------------------------------------------------------------------------
test_transcription_approval_required() {
  local fixture_drive="$TMP_ROOT/drive-approval-test"
  local cache_dir="$TMP_ROOT/cache-approval-test"
  mkdir -p "$fixture_drive/DCIM/DJI_001"

  ffmpeg -f lavfi -i testsrc=duration=1:size=320x180:rate=24 \
         -f lavfi -i sine=frequency=300:duration=1 \
         -c:v libx264 -c:a aac \
         "$fixture_drive/DCIM/DJI_001/DJI_20260914140500_0001_D.MP4" -y >/dev/null 2>&1

  local catalog_json
  catalog_json=$("$OSMO_CMD" catalog \
    --drive "$fixture_drive" \
    --cache-dir "$cache_dir" \
    --json)

  local status tool footprint cmd
  status=$(echo "$catalog_json" | jq -r '.clips[0].transcription.status')
  tool=$(echo "$catalog_json" | jq -r '.clips[0].transcription.approval_request.tool')
  footprint=$(echo "$catalog_json" | jq -r '.clips[0].transcription.approval_request.disk_footprint')
  cmd=$(echo "$catalog_json" | jq -r '.clips[0].transcription.approval_request.install_command')

  assert_eq "approval_required" "$status" "untranscribed clip requires approval before downloading model"
  assert_contains "whisper" "$tool" "approval request specifies tool"
  assert_contains "MB" "$footprint" "approval request specifies disk footprint"
  assert_contains "whisper" "$cmd" "approval request specifies install/exec command"
}

# Run all test functions
test_discover_missing_drive
test_discover_empty_drive
test_discover_valid_drive
test_scan_pairing
test_catalog_e2e
test_read_only_invariant
test_incremental_caching
test_report_command
test_cli_transcription
test_transcription_approval_required

pass "all fm-osmo tests passed successfully"
