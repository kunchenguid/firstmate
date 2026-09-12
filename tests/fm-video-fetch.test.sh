#!/usr/bin/env bash
# Verify video-fetch URL policy and output confinement without network access.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$ROOT/bin/fm-video-fetch.sh"

for url in \
  https://tiktok.com/@user/video/1 \
  https://www.tiktok.com/@user/video/1 \
  https://vt.tiktok.com/ZSfixture/ \
  https://youtube.com/watch?v=fixture \
  https://www.youtube.com/watch?v=fixture \
  https://youtu.be/fixture \
  https://vimeo.com/fixture \
  https://www.vimeo.com/fixture \
  https://x.com/user/status/1 \
  https://www.x.com/user/status/1; do
  output=$("$script" --validate-only "$url")
  assert_contains "$output" "allowed:" "allowlisted HTTPS URL should validate"
done

for url in \
  http://youtube.com/watch?v=fixture \
  https://evil.example/video \
  https://notyoutube.com/watch?v=fixture \
  file:///tmp/video.mp4 \
  https://youtube.com:443/watch?v=fixture; do
  if output=$("$script" --validate-only "$url" 2>&1); then
    fail "refused URL unexpectedly validated: $url"
  fi
  assert_contains "$output" "refusing" "disallowed URL should fail loudly"
done

output=$("$script" --validate-redirect https://youtube.com/watch?v=fixture https://youtu.be/fixture)
assert_contains "$output" "redirect allowed" "allowlisted redirect should validate without network"
if output=$("$script" --validate-redirect https://youtube.com/watch?v=fixture https://evil.example/video 2>&1); then
  fail "redirect to disallowed host unexpectedly validated"
fi
assert_contains "$output" "refusing host" "redirect refusal should name the policy failure"

tmp=$(fm_test_tmproot fm-video-fetch)
mkdir -p "$tmp/home" "$tmp/outside"
ln -s "$tmp/outside" "$tmp/home/data"
if output=$(FM_HOME="$tmp/home" "$script" -h https://youtube.com/watch?v=fixture 2>&1); then
  fail "symlinked output root unexpectedly accepted"
fi
assert_contains "$output" "refusing symlinked output directory" "output must remain confined to the calling home"
[ -z "$(find "$tmp/outside" -mindepth 1 -print -quit)" ] || fail "confinement refusal must not write outside the calling home"

pass "video fetch URL allowlist, redirect policy, and output confinement"
