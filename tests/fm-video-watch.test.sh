#!/usr/bin/env bash
# Contract tests for Firstmate's public video-watch evidence preparer.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-video-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-video-watch-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_PYTHON=$(command -v python3)
REAL_BASH=$(command -v bash)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  ln -s "$REAL_PYTHON" "$fakebin/python3"
  cat > "$fakebin/yt-dlp" <<'SH'
#!/usr/bin/env bash
printf 'yt-dlp %s\n' "$*" >> "$FM_FAKE_COMMAND_LOG"
if [ "${FM_FAKE_YTDLP_FAIL:-0}" = 1 ]; then
  printf 'raw secret noise %s\n' "${FM_FAKE_SECRET:-SECRET_SHOULD_NOT_LEAK}" >&2
  exit 1
fi
out_template=
prev=
for arg in "$@"; do
  if [ "$prev" = -o ]; then
    out_template=$arg
  fi
  prev=$arg
done
case " $* " in
  *" --dump-single-json "*)
    if [ -n "${FM_FAKE_YTDLP_METADATA:-}" ]; then
      printf '%s\n' "$FM_FAKE_YTDLP_METADATA"
    else
      cat <<'JSON'
{"id":"abc123","title":"Fixture video","duration":120,"availability":"public","subtitles":{"en":[{"ext":"vtt"}]},"chapters":[{"start_time":0,"end_time":60,"title":"Pricing hook"},{"start_time":60,"end_time":120,"title":"Demo"}]}
JSON
    fi
    exit 0
    ;;
  *" --skip-download "*)
    [ "${FM_FAKE_NO_CAPTION_FILE:-0}" = 1 ] && exit 0
    out=${out_template/'%(ext)s'/en.vtt}
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<'VTT'
WEBVTT

00:00:05.000 --> 00:00:08.000
Opening setup.

00:00:20.000 --> 00:00:25.000
The pricing hook appears on screen.

00:01:05.000 --> 00:01:09.000
The demo shows the dashboard.
VTT
    exit 0
    ;;
  *)
    out=${out_template/'%(ext)s'/mp4}
    mkdir -p "$(dirname "$out")"
    printf 'video\n' > "$out"
    exit 0
    ;;
esac
SH
  cat > "$fakebin/ffprobe" <<'SH'
#!/usr/bin/env bash
printf 'ffprobe %s\n' "$*" >> "$FM_FAKE_COMMAND_LOG"
if [ -n "${FM_FAKE_FFPROBE_JSON:-}" ]; then
  printf '%s\n' "$FM_FAKE_FFPROBE_JSON"
else
  cat <<'JSON'
{"format":{"duration":"120.0","size":"1000"},"streams":[{"codec_type":"video","width":1280,"height":720,"codec_name":"h264"},{"codec_type":"audio"}]}
JSON
fi
SH
  cat > "$fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
printf 'ffmpeg %s\n' "$*" >> "$FM_FAKE_COMMAND_LOG"
case " $* " in
  *showinfo*)
    [ "${FM_FAKE_SCENE_FAIL:-0}" = 1 ] && exit 1
    printf 'showinfo pts_time:2.5\nshowinfo pts_time:21.0\nshowinfo pts_time:67.0\n' >&2
    exit 0
    ;;
esac
if [ "${FM_FAKE_FFMPEG_EXTRACT_FAIL:-0}" = 1 ]; then
  printf 'extract failed with secret %s\n' "${FM_FAKE_SECRET:-SECRET_SHOULD_NOT_LEAK}" >&2
  exit 1
fi
out=${@: -1}
mkdir -p "$(dirname "$out")"
printf 'jpg\n' > "$out"
exit 0
SH
  chmod +x "$fakebin/yt-dlp" "$fakebin/ffprobe" "$fakebin/ffmpeg"
  printf '%s\n' "$fakebin"
}

json_get() {
  local file=$1 expr=$2
  "$REAL_PYTHON" - "$file" "$expr" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(eval(sys.argv[2], {}, {'data': data}))
PY
}

receipt_root() {
  local receipt=$1
  "$REAL_PYTHON" - "$receipt" <<'PY'
import base64, json, sys
receipt = sys.argv[1]
payload = receipt.split('.', 1)[1]
payload += '=' * (-len(payload) % 4)
print(json.loads(base64.urlsafe_b64decode(payload))['root'])
PY
}

mutate_receipt_nonce() {
  local receipt=$1
  "$REAL_PYTHON" - "$receipt" <<'PY'
import base64, json, sys
prefix, payload = sys.argv[1].split('.', 1)
payload += '=' * (-len(payload) % 4)
data = json.loads(base64.urlsafe_b64decode(payload))
data['nonce'] = '0' * 32
raw = json.dumps(data, separators=(',', ':')).encode()
print(prefix + '.' + base64.urlsafe_b64encode(raw).decode().rstrip('='))
PY
}

run_prepare() {
  local dir=$1 out=$2 err=$3
  shift 3
  local fakebin
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$@" > "$out" 2> "$err"
}

test_doctor_missing_is_detect_only() {
  local dir="$TMP_ROOT/doctor" fakebin out err rc
  mkdir -p "$dir/fakebin"
  ln -s "$REAL_PYTHON" "$dir/fakebin/python3"
  ln -s "$REAL_BASH" "$dir/fakebin/bash"
  cat > "$dir/fakebin/brew" <<'SH'
#!/usr/bin/env bash
echo brew-called >> "$FM_FAKE_COMMAND_LOG"
exit 99
SH
  chmod +x "$dir/fakebin/brew"
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$dir/fakebin:$BASE_PATH" "$WATCH" doctor > "$dir/out.json" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 3 "$rc" "doctor reports missing dependencies"
  assert_contains "$(cat "$dir/out.json")" '"auto_install_attempted": false' "doctor records detect-only behavior"
  [ ! -s "$dir/commands.log" ] || fail "doctor attempted an installer"
  pass "doctor is detect-only when dependencies are missing"
}

test_url_rejections_are_sanitized() {
  local dir="$TMP_ROOT/reject-url" fakebin out err rc output
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare \
    'https://www.youtube.com/watch?v=abc&signature=SECRET_SHOULD_NOT_LEAK&list=PL123' \
    --question 'summarize' > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 4 "$rc" "playlist URL is rejected"
  output=$(cat "$dir/out" "$dir/err")
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "rejected URL does not leak signed query values"
  assert_not_contains "$output" 'signature=' "rejected URL does not echo signed query names"
  pass "playlist and signed-query rejection is value-safe"
}

test_metadata_rejections() {
  local case dir fakebin rc metadata
  for case in playlist live auth drm; do
    dir="$TMP_ROOT/meta-$case"
    mkdir -p "$dir"
    fakebin=$(make_fakebin "$dir")
    : > "$dir/commands.log"
    case "$case" in
      playlist) metadata='{"_type":"playlist","entries":[{}]}' ;;
      live) metadata='{"id":"x","title":"Live","duration":0,"availability":"public","is_live":true}' ;;
      auth) metadata='{"id":"x","title":"Private","duration":10,"availability":"private"}' ;;
      drm) metadata='{"id":"x","title":"DRM","duration":10,"availability":"public","drm":true}' ;;
    esac
    set +e
    FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA="$metadata" PATH="$fakebin:$BASE_PATH" \
      "$WATCH" prepare 'https://video.example/watch/one' --question 'summarize' > "$dir/out" 2> "$dir/err"
    rc=$?
    set +e
    expect_code 4 "$rc" "metadata rejection for $case"
  done
  pass "playlist, live, authenticated, and DRM metadata are rejected"
}

test_prepare_transcript_first_and_manifest_contract() {
  local dir="$TMP_ROOT/prepare" out err commands receipt root cleanup
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  run_prepare "$dir" "$out" "$err" 'https://www.youtube.com/watch?v=abc123&signature=SECRET_SHOULD_NOT_LEAK' --question 'Where is the dashboard demo?'
  [ "$(json_get "$out" "data['schema']")" = 'fm.video-watch.manifest.v1' ] || fail "manifest schema mismatch"
  [ "$(json_get "$out" "data['source']['sanitized']")" = 'https://www.youtube.com/watch?v=abc123' ] || fail "sanitized YouTube URL mismatch"
  assert_not_contains "$(cat "$out" "$err")" 'SECRET_SHOULD_NOT_LEAK' "manifest does not leak signed query canary"
  [ "$(json_get "$out" "data['transcript']['provenance']")" = 'captions:manual' ] || fail "manual caption provenance missing"
  [ "$(json_get "$out" "len(data['selected_ranges'])")" -ge 1 ] || fail "selected range missing"
  [ "$(json_get "$out" "data['selected_ranges'][0]['start_seconds']")" != '0.0' ] || fail "question terms did not narrow transcript range"
  [ "$(json_get "$out" "len(data['frames'])")" -le 36 ] || fail "default frame budget exceeded"
  assert_contains "$(json_get "$out" "','.join(sorted({f['reason'] for f in data['frames']}))")" 'periodic_coverage' "periodic evidence missing"
  assert_contains "$(json_get "$out" "','.join(sorted({f['reason'] for f in data['frames']}))")" 'scene_or_slide_change' "scene evidence missing"
  [ "$(json_get "$out" "data['token_budget']['estimated_total_tokens'] > 0")" = True ] || fail "token estimate missing"
  commands=$(cat "$dir/commands.log")
  [[ "$commands" == *"--dump-single-json"*"--skip-download --write-subs"*"--merge-output-format"* ]] \
    || fail "yt-dlp was not called metadata/captions before media download"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  root=$(receipt_root "$receipt")
  [ -d "$root/frames" ] || fail "frame directory missing before cleanup"
  cleanup="$dir/cleanup.json"
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" > "$cleanup"
  [ "$(json_get "$cleanup" "data['removed']")" = True ] || fail "cleanup did not report removal"
  [ ! -e "$root" ] || fail "cleanup did not prove absence"
  pass "transcript-first planning emits a bounded value-safe manifest and cleans up exactly"
}

test_focused_range_caps_and_language_choice() {
  local dir="$TMP_ROOT/focus" out err metadata warnings
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  metadata='{"id":"abc","title":"Auto caps","duration":120,"availability":"public","automatic_captions":{"fr":[{"ext":"vtt"}],"en":[{"ext":"vtt"}]}}'
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA="$metadata" PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one' --question 'read the text' --start 00:10 --end 00:20 \
    --caption-lang fr --max-frames 999 --resolution 9999 > "$out" 2> "$err"
  [ "$(json_get "$out" "data['selected_ranges'][0]['reason']")" = 'focused_range' ] || fail "focused range not recorded"
  [ "$(json_get "$out" "data['transcript']['language']")" = 'fr' ] || fail "requested caption language not selected"
  [ "$(json_get "$out" "data['token_budget']['max_frames']")" = 80 ] || fail "focused frame hard cap not applied"
  [ "$(json_get "$out" "data['token_budget']['resolution_px_wide']")" = 1280 ] || fail "focused resolution hard cap not applied"
  warnings=$(json_get "$out" "' '.join(data['warnings'])")
  assert_contains "$warnings" 'hard cap' "cap warning missing"
  assert_contains "$(json_get "$out" "','.join(f['reason'] for f in data['frames'])")" 'focused_range_start' "focused start frame missing"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "focused ranges use absolute timestamps, denser caps, and requested captions"
}

test_local_file_refusals() {
  local dir="$TMP_ROOT/local" fakebin rc file link out receipt root
  mkdir -p "$dir"
  file="$dir/video.mp4"
  printf 'video\n' > "$file"
  link="$dir/link.mp4"
  ln -s "$file" "$link"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$link" --question 'what happens?' > "$dir/link.out" 2> "$dir/link.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "local symlink is refused"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$file" --max-local-bytes 2 --question 'what happens?' > "$dir/size.out" 2> "$dir/size.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "oversized local file is refused"
  printf 'video\n' > "$dir/video.txt"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$dir/video.txt" --question 'what happens?' > "$dir/type.out" 2> "$dir/type.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "unsupported local extension is refused"
  out="$dir/local-success.json"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$file" --question 'what happens?' > "$out" 2> "$dir/local-success.err"
  [ "$(json_get "$out" "data['source']['kind']")" = 'local_file' ] || fail "local success did not record local source kind"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  root=$(receipt_root "$receipt")
  [ -f "$root/media/local.mp4" ] || fail "local media was not copied into the owned temp directory"
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  [ ! -e "$root" ] || fail "local success cleanup did not remove owned temp directory"
  pass "local file mode refuses unsafe files and copies accepted media into owned temp storage"
}

test_malformed_metadata_and_failure_receipt_are_safe() {
  local dir="$TMP_ROOT/malformed" fakebin rc output
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA='{' PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one?token=SECRET_SHOULD_NOT_LEAK' --question 'summarize' > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 5 "$rc" "malformed yt-dlp metadata is refused"
  output=$(cat "$dir/out" "$dir/err")
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "malformed metadata diagnostic leaked URL canary"

  dir="$TMP_ROOT/extract-fail"
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_FFMPEG_EXTRACT_FAIL=1 FM_FAKE_SECRET=SECRET_SHOULD_NOT_LEAK PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one?token=SECRET_SHOULD_NOT_LEAK' --question 'pricing' > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 5 "$rc" "frame extraction failure is reported"
  output=$(cat "$dir/out" "$dir/err")
  assert_contains "$output" 'evidence retained for cleanup with receipt fmvw1.' "failure did not provide cleanup receipt"
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "failure diagnostic leaked raw command canary"
  pass "malformed metadata and extraction failures stay value-safe"
}

test_cleanup_receipt_mismatch_and_symlink_marker_resistance() {
  local dir="$TMP_ROOT/cleanup" out err receipt bad root fakebin outside rc
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  run_prepare "$dir" "$out" "$err" 'https://video.example/watch/one' --question 'pricing'
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  bad=$(mutate_receipt_nonce "$receipt")
  root=$(receipt_root "$receipt")
  set +e
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$bad" > "$dir/bad.out" 2> "$dir/bad.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "mismatched cleanup receipt is refused"
  [ -d "$root" ] || fail "receipt mismatch removed evidence directory"
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  [ ! -e "$root" ] || fail "valid cleanup did not remove directory after mismatch"

  dir="$TMP_ROOT/cleanup-symlink"
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  run_prepare "$dir" "$out" "$err" 'https://video.example/watch/one' --question 'pricing'
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  root=$(receipt_root "$receipt")
  outside="$TMP_ROOT/outside-marker"
  printf 'outside\n' > "$outside"
  rm -f "$root/.fm-video-watch-owned.json"
  ln -s "$outside" "$root/.fm-video-watch-owned.json"
  set +e
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" > "$dir/sym.out" 2> "$dir/sym.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "symlinked ownership marker is refused"
  [ -e "$outside" ] || fail "cleanup followed symlinked ownership marker"
  rm -f "$root/.fm-video-watch-owned.json"
  rm -rf "$root"
  pass "cleanup requires matching receipt and resists symlink marker replacement"
}

test_real_smoke_requires_two_opt_ins() {
  local dir="$TMP_ROOT/smoke" fakebin rc
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" smoke --url 'https://www.youtube.com/watch?v=8ZgpAXe5V5w' \
    --question 'summarize' --i-understand-this-uses-network > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 2 "$rc" "real smoke requires environment opt-in"
  [ ! -s "$dir/commands.log" ] || fail "real smoke ran tools without env opt-in"
  pass "real public smoke cannot run accidentally"
}

test_doctor_missing_is_detect_only
test_url_rejections_are_sanitized
test_metadata_rejections
test_prepare_transcript_first_and_manifest_contract
test_focused_range_caps_and_language_choice
test_local_file_refusals
test_malformed_metadata_and_failure_receipt_are_safe
test_cleanup_receipt_mismatch_and_symlink_marker_resistance
test_real_smoke_requires_two_opt_ins
