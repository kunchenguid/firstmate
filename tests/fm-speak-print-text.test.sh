#!/usr/bin/env bash
# tests/fm-speak-print-text.test.sh - bin/fm-speak.sh's speakable-text output,
# its rendered-file report, and the cache validity gate a render applies.
#
# The sentences the first case expects are hand-derived from what
# docs/audio-briefings.md promises ("The tool speaks prose, not markup ... headings
# become their own sentence, abbreviations are expanded, and the text is
# transliterated to ASCII before synthesis") rather than captured from a run, so a
# pipeline rewrite that drops a normalisation step fails here instead of quietly
# reading markup aloud. That same output is what the chunk packer consumes - one
# sentence per line - so the case also pins the boundary that --max-minutes
# splitting depends on.
#
# The render case checks the report against the file on disk: `size:` must be the
# real byte count of the mp3 that was produced, and the index row must name it.
#
# The cache cases are the ones a fresh user hits: a venv that exists but cannot
# import its packages, and a download that failed. Both used to look present to
# `--setup` and to the render preflight, which then died inside python. They run
# entirely offline against PATH shims for python3, curl, piper, ffmpeg and
# ffprobe. `uname` is shimmed to Darwin in the two platform cases so the
# Linux-only C++ runtime lookup stays out of the way on any CI host, which is also
# what proves a macOS host reaches synthesis without libstdc++.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEAK=$ROOT/bin/fm-speak.sh
TMP_ROOT=$(fm_test_tmproot fm-speak)
HOME_DIR=$TMP_ROOT/home
mkdir -p "$HOME_DIR"

# fake_darwin <fakebin>: answer `uname -s` with Darwin, everything else real.
fake_darwin() {
  cat > "$1/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Darwin
SH
  chmod +x "$1/uname"
}

# fake_curl <fakebin> [http-error]: model the two curl behaviours that matter
# here. A response body is written to -o in both modes, because a transfer can
# fail after part of the body has arrived; -f is what turns an HTTP error into a
# non-zero exit, so without it the caller sees success and keeps the error page.
fake_curl() {
  local fakebin=$1 mode=${2:-ok}
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
out=
fatal=0
while [ \$# -gt 0 ]; do
  case \$1 in
    -o) out=\$2; shift 2 ;;
    -*) case \$1 in *f*) fatal=1 ;; esac; shift ;;
    *) shift ;;
  esac
done
if [ "$mode" = http-error ]; then
  [ -n "\$out" ] && printf '%s' '<html>404 Not Found</html>' > "\$out"
  [ "\$fatal" -eq 1 ] && exit 22
  exit 0
fi
[ -n "\$out" ] && printf '%s' cached-bytes > "\$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

# fake_venv_builder <fakebin>: `python3 -m venv DIR` builds a DIR whose python can
# import the Kokoro packages, which is what a working `pip install` leaves behind.
fake_venv_builder() {
  cat > "$1/python3" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -m ] && [ "${2:-}" = venv ] || exit 9
mkdir -p "$3/bin"
cat > "$3/bin/python" <<'PY'
#!/usr/bin/env bash
[ "${1:-}" = -c ] || exit 1
exit 0
PY
cat > "$3/bin/pip" <<'PY'
#!/usr/bin/env bash
exit 0
PY
chmod +x "$3/bin/python" "$3/bin/pip"
SH
  chmod +x "$1/python3"
}

test_print_text_reads_prose_not_markup() {
  local input=$TMP_ROOT/report.md out expected
  cat > "$input" <<'MD'
# Release notes

The build finished “early” — about 40 checks. It ran `fm-lint` and ≈ 25±2 seconds elapsed.

Use e.g. `--setup`; etc. works, vs. a fresh fetch. See https://example.com/docs for w/o pain.

- First item with *emphasis* and **bold** and _underscores_.
- Second item → third item, 3x4 sizes, 50% faster.

| a | b |
| --- | --- |
| 1 | 2 |

```
code fence
```
MD
  IFS= read -r -d '' expected <<'TXT' || true
Release notes.
The build finished "early" - about 40 checks.
It ran fm-lint and about 25 plus or minus 2 seconds elapsed.
Use for example, --setup; et cetera, works, versus a fresh fetch.
See for without pain.
First item with emphasis and bold and underscores.
Second item to third item, 3 by 4 sizes, 50 percent faster.
TXT
  expected=${expected%$'\n'}
  out=$(HOME="$HOME_DIR" "$SPEAK" "$input" --print-text) ||
    fail "print-text failed: $out"
  [ "$out" = "$expected" ] ||
    fail "spoken text changed"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- got ---"$'\n'"$out"
  pass "print-text: markup, typography and abbreviations become one sentence per line"
}

test_abbreviations_expand_every_occurrence() {
  local input=$TMP_ROOT/abbreviations.md out expected
  cat > "$input" <<'MD'
x w/o w/o y. A vs. vs. B. Use e.g.e.g. done. Repeat etc. etc. and approx.approx. end.
MD
  IFS= read -r -d '' expected <<'TXT' || true
x without without y.
A versus versus B.
Use for example,for example, done.
Repeat et cetera, et cetera, and approximatelyapproximately end.
TXT
  expected=${expected%$'\n'}
  out=$(HOME="$HOME_DIR" "$SPEAK" "$input" --print-text) ||
    fail "print-text failed: $out"
  [ "$out" = "$expected" ] ||
    fail "repeated and adjacent abbreviations must all expand"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- got ---"$'\n'"$out"
  pass "abbreviations: repeated and adjacent forms all expand"
}

test_render_reports_the_mp3_size_and_indexes_it() {
  local root fakebin cache outdir input out mp3
  root=$TMP_ROOT/render
  cache=$root/cache
  outdir=$root/out
  input=$root/report.md
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$cache/voices"
  : > "$cache/voices/en_US-lessac-high.onnx"
  : > "$cache/voices/en_US-lessac-high.onnx.json"
  printf '%s\n' 'One sentence here. Second sentence there.' > "$input"

  cat > "$fakebin/piper" <<'SH'
#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do
  case $1 in
    -f) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' wav-bytes > "$out"
SH
  cat > "$fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
for last; do :; done
printf '%s' mp3-bytes > "$last"
SH
  cat > "$fakebin/ffprobe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 12.5
SH
  chmod +x "$fakebin/piper" "$fakebin/ffmpeg" "$fakebin/ffprobe"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_CACHE_DIR="$cache" \
    FM_TTS_ENGINE=piper "$SPEAK" "$input" --out "$outdir" --title "Fixture report") ||
    fail "render failed: $out"

  mp3=$(printf '%s\n' "$out" | sed -n 's/^file: //p')
  [ -f "$mp3" ] || fail "render reported a file that does not exist: $mp3"
  [ "$(printf '%s\n' "$out" | sed -n 's/^duration: //p')" = "0:13" ] ||
    fail "duration line must round the measured 12.5 seconds to 0:13 (got: $out)"
  [ "$(printf '%s\n' "$out" | sed -n 's/^size: //p')" = "$(wc -c <"$mp3" | tr -d '[:space:]')" ] ||
    fail "size line must be the byte count of the rendered mp3"$'\n'"--- output ---"$'\n'"$out"
  grep -F -- "| Fixture report | 0:13 |" "$outdir/index.md" >/dev/null ||
    fail "index does not hold the rendered row"
  pass "render: reports the real mp3 byte count and indexes the row"
}

test_setup_on_macos_does_not_require_libstdcxx() {
  local root fakebin kokoro out
  root=$TMP_ROOT/darwin-setup
  kokoro=$root/kokoro
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" = -c ] || exit 1' 'exit 0' \
    > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  fake_darwin "$fakebin"
  fake_curl "$fakebin"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" --setup) || fail "--setup failed on a Darwin host: $out"
  assert_contains "$out" "cxx-runtime: not needed on Darwin" \
    "setup on macOS must not ask for a libstdc++ the platform does not need"
  assert_contains "$out" "venv: present" \
    "setup must report a venv that can import its packages as present"
  pass "setup: macOS needs no C++ runtime step and a working venv is present"
}

test_setup_repairs_a_venv_that_cannot_import() {
  local root fakebin kokoro out
  root=$TMP_ROOT/setup-repair
  kokoro=$root/kokoro
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"
  fake_venv_builder "$fakebin"
  fake_curl "$fakebin"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" --setup) || fail "--setup did not repair the venv: $out"
  assert_contains "$out" "venv: repairing" \
    "a venv that cannot import its packages must be rebuilt, not reported present"
  "$kokoro/venv/bin/python" -c 'import kokoro_onnx, soundfile' ||
    fail "the rebuilt venv still cannot import kokoro_onnx and soundfile"
  [ -s "$kokoro/kokoro-v1.0.onnx" ] && [ -s "$kokoro/voices-v1.0.bin" ] ||
    fail "setup did not finish the cache after repairing the venv"
  pass "setup: rebuilds a venv that cannot import its packages"
}

test_setup_leaves_no_cache_file_after_a_failed_download() {
  local root fakebin kokoro input outdir out rc
  root=$TMP_ROOT/setup-download
  kokoro=$root/kokoro
  input=$root/report.md
  outdir=$root/out
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/usr/bin/env bash' '[ "${1:-}" = -c ] || exit 1' 'exit 0' \
    > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  printf '%s\n' 'One sentence here.' > "$input"
  fake_darwin "$fakebin"
  fake_curl "$fakebin" http-error

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" --setup 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed download must fail --setup (got: $out)"
  assert_contains "$out" "could not download" \
    "a failed download must name what could not be fetched"
  [ ! -e "$kokoro/kokoro-v1.0.onnx" ] ||
    fail "a failed download left a cache file holding the error body, which the next run would treat as present"
  [ "$(ls -A "$kokoro" | tr '\n' ' ')" = "venv voices-v1.0.bin " ] ||
    fail "a failed download left temporary files behind: $(ls -A "$kokoro" | tr '\n' ' ')"

  # The damaged model must not read as present to a render either.
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || {
    pass "setup: a failed download leaves no cache file and a render refuses it (skipped render: ffmpeg and ffprobe are not on PATH)"
    return 0
  }
  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" "$input" --out "$outdir" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a render must refuse a cache whose model never downloaded"
  assert_contains "$out" "prepare it once with: bin/fm-speak.sh --setup" \
    "a cache damaged by a failed download must be reported as the one --setup line"
  assert_not_contains "$out" "Traceback" \
    "a damaged cache must not surface a python traceback"
  [ ! -d "$outdir" ] || fail "the render wrote output from a cache that never finished downloading"
  pass "setup: a failed download leaves no cache file and a render refuses it"
}

test_render_refuses_a_cache_that_cannot_import() {
  local root fakebin kokoro input outdir out rc
  root=$TMP_ROOT/preflight
  kokoro=$root/kokoro
  outdir=$root/out
  input=$root/report.md
  fakebin=$(fm_fakebin "$root")
  command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 ||
    { pass "render preflight: cache gate (skipped: ffmpeg and ffprobe are not on PATH)"; return 0; }
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  printf '%s\n' 'One sentence here.' > "$input"
  fake_darwin "$fakebin"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" "$input" --out "$outdir" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a render must refuse a cache whose venv cannot import its packages"
  assert_contains "$out" "prepare it once with: bin/fm-speak.sh --setup" \
    "an unusable cache must be reported as the one --setup line"
  assert_not_contains "$out" "Traceback" \
    "an unusable cache must not surface a python traceback"
  [ ! -d "$outdir" ] ||
    fail "the render created its output directory before validating the cache"
  pass "render: refuses a presence-only cache with the --setup line"
}

fm_test_run \
  test_print_text_reads_prose_not_markup \
  test_abbreviations_expand_every_occurrence \
  test_render_reports_the_mp3_size_and_indexes_it \
  test_setup_on_macos_does_not_require_libstdcxx \
  test_setup_repairs_a_venv_that_cannot_import \
  test_setup_leaves_no_cache_file_after_a_failed_download \
  test_render_refuses_a_cache_that_cannot_import
