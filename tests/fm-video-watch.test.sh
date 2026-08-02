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
# Real ffmpeg exits non-zero and writes nothing when -ss lands at or past the
# last decodable frame, so the stub must refuse it too.
seek=
prev=
for arg in "$@"; do
  if [ "$prev" = -ss ]; then
    seek=$arg
  fi
  prev=$arg
done
if [ -n "$seek" ]; then
  awk -v ss="$seek" -v dur="${FM_FAKE_MEDIA_DURATION:-120}" 'BEGIN { exit (ss > dur - 0.04) ? 0 : 1 }' && {
    printf 'Output file does not contain any stream\n' >&2
    exit 234
  }
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

# A refused or failed prepare deliberately retains its owned evidence directory
# behind the receipt it prints on stderr. Tests must hand that receipt back so a
# suite run leaves nothing in the system temp directory.
cleanup_retained() {
  local err=$1 receipt
  [ -f "$err" ] || return 0
  receipt=$(grep -o 'fmvw1\.[A-Za-z0-9_-]*' "$err" | head -1)
  [ -n "$receipt" ] || return 0
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null 2>&1
  printf '%s\n' "$receipt"
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

  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare \
    'https://video.example/watch/one?id=42&Signature=SECRET_SHOULD_NOT_LEAK' \
    --question 'summarize' > "$dir/signed.out" 2> "$dir/signed.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "signed URL is rejected before any fetch"
  output=$(cat "$dir/signed.out" "$dir/signed.err")
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "signed rejection does not leak the signature value"
  [ ! -s "$dir/commands.log" ] || fail "signed URL reached yt-dlp before rejection"
  pass "playlist and credential-bearing query rejection is value-safe"
}

test_supplied_url_is_fetched_exactly() {
  local dir="$TMP_ROOT/exact-url" out err commands receipt
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  run_prepare "$dir" "$out" "$err" 'https://player.vimeo.com/video/76979871?h=8272103f6e&utm_source=SECRET_SHOULD_NOT_LEAK' \
    --question 'summarize'
  commands=$(cat "$dir/commands.log")
  assert_contains "$commands" 'https://player.vimeo.com/video/76979871?h=8272103f6e&utm_source=SECRET_SHOULD_NOT_LEAK' \
    "yt-dlp did not receive the exact supplied URL"
  [ "$(json_get "$out" "data['source']['sanitized']")" = 'https://player.vimeo.com/video/76979871?h=redacted' ] \
    || fail "identity-bearing query parameter was not retained and redacted for display"
  [ "$(json_get "$out" "data['source']['query_keys']")" = "['h']" ] || fail "retained query key names missing"
  assert_not_contains "$(cat "$out" "$err")" 'SECRET_SHOULD_NOT_LEAK' "manifest leaked a tracking query value"
  assert_not_contains "$(cat "$out" "$err")" '8272103f6e' "manifest printed a non-identifier query value"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "the exact supplied public URL is fetched while the manifest stays value-safe"
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
    cleanup_retained "$dir/err" >/dev/null
  done
  pass "playlist, live, authenticated, and DRM metadata are rejected"
}

test_prepare_transcript_first_and_manifest_contract() {
  local dir="$TMP_ROOT/prepare" out err commands receipt root cleanup
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  run_prepare "$dir" "$out" "$err" 'https://www.youtube.com/watch?v=abc123&si=SECRET_SHOULD_NOT_LEAK' --question 'Where is the dashboard demo?'
  [ "$(json_get "$out" "data['schema']")" = 'fm.video-watch.manifest.v1' ] || fail "manifest schema mismatch"
  [ "$(json_get "$out" "data['source']['sanitized']")" = 'https://www.youtube.com/watch?v=abc123' ] || fail "sanitized YouTube URL mismatch"
  assert_not_contains "$(cat "$out" "$err")" 'SECRET_SHOULD_NOT_LEAK' "manifest does not leak tracking query canary"
  [ "$(json_get "$out" "data['media']['acquired']")" = True ] || fail "media acquisition not recorded"
  [ "$(json_get "$out" "data['media']['visual_coverage']")" = 'full' ] || fail "full visual coverage not recorded"
  [ "$(json_get "$out" "data['media']['byte_ceiling'] > 0")" = True ] || fail "transient media ceiling missing"
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
  assert_contains "$(cat "$dir/commands.log")" '--download-sections *10.000-20.000' "focused run did not request a bounded provider section"
  assert_contains "$warnings" 'ignored the bounded section request' "unbounded section fallback was not disclosed"
  [ "$(json_get "$out" "data['media']['visual_coverage']")" = 'full' ] || fail "full media fallback coverage not recorded"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "focused ranges use absolute timestamps, denser caps, and requested captions"
}

test_section_download_keeps_absolute_timestamps() {
  local dir="$TMP_ROOT/section" out err fakebin receipt commands
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_MEDIA_DURATION=10 \
    FM_FAKE_FFPROBE_JSON='{"format":{"duration":"10.0","size":"1000"},"streams":[{"codec_type":"video","width":1280,"height":720,"codec_name":"h264"}]}' \
    PATH="$fakebin:$BASE_PATH" "$WATCH" prepare 'https://video.example/watch/one' --question 'read the text' \
    --start 00:10 --end 00:20 --max-frames 6 > "$out" 2> "$err"
  [ "$(json_get "$out" "data['media']['visual_coverage']")" = 'section' ] || fail "section coverage not recorded"
  [ "$(json_get "$out" "data['media']['acquired_range']['start_seconds']")" = '10.0' ] || fail "acquired section range missing"
  [ "$(json_get "$out" "min(f['timestamp_seconds'] for f in data['frames']) >= 10.0")" = True ] \
    || fail "section frames did not keep absolute timestamps"
  [ "$(json_get "$out" "max(f['timestamp_seconds'] for f in data['frames']) <= 19.5")" = True ] \
    || fail "section frames were planned past the last decodable frame of the acquired media"
  assert_contains "$(json_get "$out" "' '.join(data['warnings'])")" 'covers only the requested section' \
    "section-only coverage was not disclosed"
  commands=$(cat "$dir/commands.log")
  assert_contains "$commands" '-ss 0.000' "section media was not seeked relative to the acquired section"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "bounded section downloads keep manifest timestamps absolute and coverage honest"
}

test_wide_focus_range_takes_the_cheaper_full_download() {
  local dir="$TMP_ROOT/wide-focus" out err fakebin metadata commands receipt
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  metadata='{"id":"abc","title":"Wide focus","duration":120,"availability":"public","filesize_approx":20000000,"subtitles":{"en":[{"ext":"vtt"}]}}'
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA="$metadata" PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one' --question 'read the text' \
    --start 00:00 --end 02:00 > "$out" 2> "$err"
  commands=$(cat "$dir/commands.log")
  assert_not_contains "$commands" '--download-sections' "a whole-span focus range still paid for a re-encoded section"
  [ "$(json_get "$out" "data['media']['visual_coverage']")" = 'full' ] || fail "the cheaper full route did not report full coverage"
  [ "$(json_get "$out" "data['media']['acquisition_reason']")" = 'the_full_media_is_projected_cheaper_than_a_re_encoded_section' ] \
    || fail "the acquisition route reason was not recorded"
  [ "$(json_get "$out" "data['selected_ranges'][0]['reason']")" = 'focused_range' ] || fail "the focus range was lost by the full route"
  [ "$(json_get "$out" "data['selected_ranges'][0]['end_seconds']")" = '120.0' ] || fail "the focus range span changed"
  assert_contains "$(json_get "$out" "' '.join(data['warnings'])")" 'cheaper than a re-encoded provider section' \
    "the route choice was not disclosed"
  assert_contains "$(cat "$dir/commands.log")" '--dump-single-json' "metadata was not gathered before acquisition"
  assert_contains "$commands" 'bv*[height<=720]' "the declared size was not scoped to the format actually downloaded"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "a focus range that covers most of the source takes the cheaper full download without losing the range"
}

test_media_ceiling_refuses_before_download() {
  local dir="$TMP_ROOT/ceiling" out err fakebin metadata receipt commands
  mkdir -p "$dir"
  out="$dir/out.json"
  err="$dir/err"
  metadata='{"id":"big","title":"Huge","duration":1200,"availability":"public","filesize_approx":9000000000,"subtitles":{"en":[{"ext":"vtt"}]},"chapters":[{"start_time":0,"end_time":600,"title":"Pricing hook"}]}'
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA="$metadata" PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one' --question 'pricing' --max-media-bytes 1000000 > "$out" 2> "$err"
  [ "$(json_get "$out" "data['media']['acquired']")" = False ] || fail "oversized media was still acquired"
  [ "$(json_get "$out" "data['media']['visual_coverage']")" = 'none' ] || fail "absent visual coverage not recorded"
  [ "$(json_get "$out" "len(data['frames'])")" = 0 ] || fail "frames were emitted without acquired media"
  [ "$(json_get "$out" "data['transcript']['available']")" = True ] || fail "transcript evidence was not returned"
  [ "$(json_get "$out" "len(data['chapters']) > 0")" = True ] || fail "chapter evidence was not returned"
  assert_contains "$(json_get "$out" "data['media']['focused_pass_recommendation']")" '--start' \
    "focused-pass recommendation missing"
  assert_contains "$(json_get "$out" "' '.join(data['warnings'])")" 'do not claim any visual coverage' \
    "manifest did not warn against claiming visual coverage"
  commands=$(cat "$dir/commands.log")
  assert_not_contains "$commands" '--merge-output-format' "media download ran despite exceeding the byte ceiling"
  receipt=$(json_get "$out" "data['cleanup_receipt']")
  PATH="$(dirname "$REAL_PYTHON"):$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  pass "declared media above the transient ceiling is refused before download with transcript evidence returned"
}

test_media_ceiling_override_requires_free_space() {
  local dir="$TMP_ROOT/ceiling-override" fakebin rc output
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one' --question 'pricing' \
    --max-media-bytes 99999999999999 > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 2 "$rc" "a media ceiling above the 16 GiB hard cap is refused"
  output=$(cat "$dir/out" "$dir/err")
  assert_contains "$output" 'hard cap for transient public media' "hard-cap refusal did not name the bound"
  cleanup_retained "$dir/err" >/dev/null

  "$REAL_PYTHON" - "$ROOT/bin/fm-video-watch-impl.py" <<'PY' || fail "free-space preflight does not gate only the override"
import importlib.util, shutil, sys, tempfile
from collections import namedtuple
from pathlib import Path

spec = importlib.util.spec_from_file_location("fmvw", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["fmvw"] = mod
spec.loader.exec_module(mod)

usage = namedtuple("usage", "total used free")
mod.shutil.disk_usage = lambda _path: usage(0, 0, 3 * 1024 * 1024 * 1024)
work = Path(tempfile.gettempdir())

warnings = []
ceiling = mod.resolve_media_ceiling(None, work, warnings)
assert ceiling < mod.DEFAULT_MAX_MEDIA_BYTES, "default ceiling must clamp to free space, not refuse"
assert any("free space is the binding limit" in w for w in warnings), warnings

assert mod.tail_seek_limit(10.0, 25.0) == 9.5, mod.tail_seek_limit(10.0, 25.0)
assert mod.tail_seek_limit(10.0, 1.0) == 8.0, mod.tail_seek_limit(10.0, 1.0)
assert mod.tail_seek_limit(10.0, 0.0) == 9.0, mod.tail_seek_limit(10.0, 0.0)
assert mod.tail_seek_limit(0.2, 25.0) == 0.0, mod.tail_seek_limit(0.2, 25.0)

GiB = 1024 ** 3
assert mod.choose_acquisition(None, 120.0, 1000, 4 * GiB)[0] is None
assert mod.choose_acquisition((0.0, 10.0), 120.0, 20_000_000, 4 * GiB)[0] == (0.0, 10.0)
assert mod.choose_acquisition((0.0, 120.0), 120.0, 20_000_000, 4 * GiB)[0] is None
assert mod.choose_acquisition((0.0, 60.0), 120.0, 20_000_000, 4 * GiB)[0] is None
assert mod.choose_acquisition((0.0, 30.0), 120.0, None, 4 * GiB)[0] == (0.0, 30.0)
assert mod.choose_acquisition((0.0, 120.0), 0.0, None, 4 * GiB)[0] == (0.0, 120.0)
assert mod.choose_acquisition((0.0, 120.0), 120.0, 9 * GiB, 4 * GiB)[0] == (0.0, 120.0)
assert mod.projected_section_share(10.0, 0.0) is None

assert mod.scene_timestamp_timeout(60.0) == 300, mod.scene_timestamp_timeout(60.0)
assert mod.scene_timestamp_timeout(3709.0) == 900, mod.scene_timestamp_timeout(3709.0)


def _refuse(*_a, **_k):
    raise mod.WatchError("command timed out after 300s: ffmpeg", 5)


mod.run_quiet = _refuse
scenes, scene_warnings = mod.scene_timestamps(Path("missing.mp4"), [mod.Range(0.0, 3709.0, "full_video")])
assert scenes == [], scenes
assert scene_warnings and "periodic coverage was still used" in scene_warnings[0], scene_warnings

try:
    mod.resolve_media_ceiling(8 * 1024 * 1024 * 1024, work, [])
except mod.WatchError as exc:
    assert exc.code == 2, exc.code
    assert "proven local free space" in str(exc), str(exc)
else:
    raise AssertionError("override above the default must require proven free space")
PY
  pass "the transient media ceiling clamps by default, keeps seeks inside the media, and requires proven free space only when raised"
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
  cleanup_retained "$dir/link.err" >/dev/null
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$file" --max-local-bytes 2 --question 'what happens?' > "$dir/size.out" 2> "$dir/size.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "oversized local file is refused"
  cleanup_retained "$dir/size.err" >/dev/null
  printf 'video\n' > "$dir/video.txt"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" PATH="$fakebin:$BASE_PATH" "$WATCH" prepare "$dir/video.txt" --question 'what happens?' > "$dir/type.out" 2> "$dir/type.err"
  rc=$?
  set +e
  expect_code 4 "$rc" "unsupported local extension is refused"
  cleanup_retained "$dir/type.err" >/dev/null
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
  local dir="$TMP_ROOT/malformed" fakebin rc output receipt
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_YTDLP_METADATA='{' PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one?h=SECRET_SHOULD_NOT_LEAK' --question 'summarize' > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 5 "$rc" "malformed yt-dlp metadata is refused"
  output=$(cat "$dir/out" "$dir/err")
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "malformed metadata diagnostic leaked URL canary"
  cleanup_retained "$dir/err" >/dev/null

  dir="$TMP_ROOT/extract-fail"
  mkdir -p "$dir"
  fakebin=$(make_fakebin "$dir")
  : > "$dir/commands.log"
  set +e
  FM_FAKE_COMMAND_LOG="$dir/commands.log" FM_FAKE_FFMPEG_EXTRACT_FAIL=1 FM_FAKE_SECRET=SECRET_SHOULD_NOT_LEAK PATH="$fakebin:$BASE_PATH" \
    "$WATCH" prepare 'https://video.example/watch/one?h=SECRET_SHOULD_NOT_LEAK' --question 'pricing' > "$dir/out" 2> "$dir/err"
  rc=$?
  set +e
  expect_code 5 "$rc" "frame extraction failure is reported"
  output=$(cat "$dir/out" "$dir/err")
  assert_contains "$output" 'evidence retained for cleanup with receipt fmvw1.' "failure did not provide cleanup receipt"
  assert_not_contains "$output" 'SECRET_SHOULD_NOT_LEAK' "failure diagnostic leaked raw command canary"
  receipt=$(cleanup_retained "$dir/err")
  [ -n "$receipt" ] || fail "the retained failure directory exposed no usable receipt"
  [ ! -e "$(receipt_root "$receipt")" ] || fail "the retained failure directory survived its own receipt"
  pass "malformed metadata and extraction failures stay value-safe and clean up by their retained receipt"
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

test_default_whole_video_completes_on_real_media() {
  local dir="$TMP_ROOT/whole-video" bin out err rc receipt root duration
  local real_ffmpeg real_ffprobe
  real_ffmpeg=$(command -v ffmpeg 2>/dev/null)
  real_ffprobe=$(command -v ffprobe 2>/dev/null)
  if [ -z "$real_ffmpeg" ] || [ -z "$real_ffprobe" ]; then
    pass "default whole-video extraction on real media (skipped: ffmpeg and ffprobe are not installed)"
    return 0
  fi
  mkdir -p "$dir"
  bin="$dir/realbin"
  mkdir -p "$bin"
  ln -sf "$real_ffmpeg" "$bin/ffmpeg"
  ln -sf "$real_ffprobe" "$bin/ffprobe"
  ln -sf "$REAL_PYTHON" "$bin/python3"
  duration=6
  PATH="$bin:$BASE_PATH" ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=duration=$duration:size=160x120:rate=10" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$dir/clip.mp4" 2> "$dir/gen.err" \
    || fail "could not synthesize the regression clip"
  out="$dir/out.json"
  err="$dir/err"
  set +e
  PATH="$bin:$BASE_PATH" "$WATCH" prepare "$dir/clip.mp4" --question 'what is shown' \
    --max-frames 8 --resolution 128 > "$out" 2> "$err"
  rc=$?
  set +e
  expect_code 0 "$rc" "the default whole-video path completes without a focus range"
  receipt=$("$REAL_PYTHON" - "$out" "$duration" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
duration = float(sys.argv[2])
assert data['selected_ranges'][0]['reason'] == 'full_video', data['selected_ranges']
assert data['media']['visual_coverage'] == 'full', data['media']
assert len(data['frames']) >= 3, len(data['frames'])
assert data['frames'][-1]['timestamp_seconds'] < duration, data['frames'][-1]
for frame in data['frames']:
    assert os.path.getsize(frame['path']) > 0, frame['path']
print(data['cleanup_receipt'])
PY
  ) || fail "the whole-video manifest did not extract every planned frame inside the media"
  root=$(receipt_root "$receipt")
  PATH="$bin:$BASE_PATH" "$WATCH" cleanup "$receipt" >/dev/null
  [ ! -e "$root" ] || fail "whole-video cleanup did not remove the owned directory"
  pass "the default whole-video path extracts every planned frame from real media and cleans up exactly"
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
test_supplied_url_is_fetched_exactly
test_metadata_rejections
test_prepare_transcript_first_and_manifest_contract
test_focused_range_caps_and_language_choice
test_section_download_keeps_absolute_timestamps
test_wide_focus_range_takes_the_cheaper_full_download
test_media_ceiling_refuses_before_download
test_media_ceiling_override_requires_free_space
test_local_file_refusals
test_malformed_metadata_and_failure_receipt_are_safe
test_cleanup_receipt_mismatch_and_symlink_marker_resistance
test_default_whole_video_completes_on_real_media
test_real_smoke_requires_two_opt_ins
