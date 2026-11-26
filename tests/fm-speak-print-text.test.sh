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
# It renders through the shipped engine rather than a fixture engine, with the
# venv python, ffmpeg and ffprobe shimmed at those process boundaries.
#
# The cache cases are the ones a fresh user hits: a venv that exists but cannot
# import its packages, and a download that failed. Both used to look present to
# `--setup` and to the render preflight, which then died inside python. They run
# entirely offline against PATH shims for python3, curl, ffmpeg and ffprobe.
# `uname` is shimmed to Darwin in the two platform cases so the Linux-only C++
# runtime lookup stays out of the way on any CI host, which is also what proves a
# macOS host reaches synthesis without libstdc++.
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

# fake_linux <fakebin>: answer `uname -s` with Linux so the C++ runtime lookup
# runs, with the located runtime supplied through LD_LIBRARY_PATH by the caller.
fake_linux() {
  cat > "$1/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
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

# cache_entries <dir>: the names directly under a cache directory, space
# separated, so an assertion can name exactly what a run left behind.
cache_entries() {
  find "$1" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort | tr '\n' ' '
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

Only split when x < 10 and y > 5 here.
Run `cmd <in >out` to convert the file.
<b>bold</b> and <https://example.com/x> here.
<div class="x">text</div>
MD
  IFS= read -r -d '' expected <<'TXT' || true
Release notes.
The build finished "early" - about 40 checks.
It ran fm-lint and about 25 plus or minus 2 seconds elapsed.
Use for example, --setup; et cetera, works, versus a fresh fetch.
See for without pain.
First item with emphasis and bold and underscores.
Second item to third item, 3 by 4 sizes, 50 percent faster.
Only split when x < 10 and y > 5 here.
Run cmd <in >out to convert the file.
bold and here.
text
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
Ends with vs.
MD
  IFS= read -r -d '' expected <<'TXT' || true
x without without y.
A versus versus B.
Use for example, for example, done.
Repeat et cetera, et cetera, and approximately approximately end.
Ends with versus.
TXT
  expected=${expected%$'\n'}
  out=$(HOME="$HOME_DIR" "$SPEAK" "$input" --print-text) ||
    fail "print-text failed: $out"
  [ "$out" = "$expected" ] ||
    fail "repeated and adjacent abbreviations must all expand"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- got ---"$'\n'"$out"
  pass "abbreviations: repeated and adjacent forms all expand"
}

# docs/audio-briefings.md: --print-text "prints those cleaned sentences and
# exits without touching a synthesiser, creates no output directory". A text-only
# run is therefore judged by what it does not leave behind, and by the prose it
# still prints.
test_print_text_creates_no_output_directory() {
  local home input out
  home=$TMP_ROOT/text-only-home
  input=$TMP_ROOT/text-only.md
  mkdir -p "$home"
  printf '%s\n' 'Only the words, nothing else.' > "$input"

  out=$(HOME="$home" "$SPEAK" "$input" --print-text --out "$home/Dropbox/briefings") ||
    fail "a text-only run must not fail on its output directory: $out"
  [ "$out" = "Only the words, nothing else." ] ||
    fail "--print-text must print the cleaned prose (got: $out)"
  [ ! -e "$home/audio-briefings" ] ||
    fail "--print-text created the default output directory"
  [ ! -e "$home/Dropbox" ] ||
    fail "--print-text created the directory named by --out"
  pass "print-text: prints the prose and creates no output directory"
}

# CommonMark's flanking rules: an intraword underscore is not emphasis, and a
# `*` followed by a space cannot open emphasis. docs/audio-briefings.md promises
# that emphasis *markers* are removed, not that identifier or arithmetic
# characters are.
test_emphasis_keeps_identifiers_and_arithmetic() {
  local input out expected
  input=$TMP_ROOT/emphasis.md
  cat > "$input" <<'MD'
Set `FM_TTS_KOKORO_DIR` and `kokoro_venv_ready` or leave _emphasis_ alone.
The range 2 * 3 * 4 stays, and *real*, **strong**, __solid__ and _under_ markers go.
Use ***bold italic***, ___both___ and ****x**** here.
Nested **bold *em*** and _ital **bold**_ and *italic with **bold*** lose theirs too.
*see **this** note* and _a __b__ c_ and **bold with *emphasis*** are emphasis too.
MD
  IFS= read -r -d '' expected <<'TXT' || true
Set FM_TTS_KOKORO_DIR and kokoro_venv_ready or leave emphasis alone.
The range 2 * 3 * 4 stays, and real, strong, solid and under markers go.
Use bold italic, both and x here.
Nested bold em and ital bold and italic with bold lose theirs too.
see this note and a b c and bold with emphasis are emphasis too.
TXT
  expected=${expected%$'\n'}
  out=$(HOME="$HOME_DIR" "$SPEAK" "$input" --print-text) ||
    fail "print-text failed: $out"
  [ "$out" = "$expected" ] ||
    fail "emphasis stripping must keep identifiers and asterisks"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- got ---"$'\n'"$out"
  pass "emphasis: identifiers and asterisks survive, real markers are removed"
}

# The removed URL is not the sentence: its terminal punctuation stays behind so
# the sentence split still sees a boundary (docs/audio-briefings.md: "Long input
# is split on sentence boundaries").
test_removed_urls_keep_the_sentence_boundary() {
  local input out expected
  input=$TMP_ROOT/urls.md
  cat > "$input" <<'MD'
Read https://example.com/docs. Then open notes/report.md.
Also see www.example.org/a. Next step done.
MD
  IFS= read -r -d '' expected <<'TXT' || true
Read.
Then open notes/report.md.
Also see.
Next step done.
TXT
  expected=${expected%$'\n'}
  out=$(HOME="$HOME_DIR" "$SPEAK" "$input" --print-text) ||
    fail "print-text failed: $out"
  [ "$out" = "$expected" ] ||
    fail "a removed URL must leave its sentence period in place"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- got ---"$'\n'"$out"
  pass "urls: a removed URL or www. host leaves the sentence period behind"
}

test_render_reports_the_mp3_size_and_indexes_it() {
  local root fakebin kokoro outdir input out mp3
  root=$TMP_ROOT/render
  kokoro=$root/kokoro
  outdir=$root/out
  input=$root/report.md
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin" "$root/lib"
  # A file named libstdc++.so.6 gives the Linux C++ runtime lookup something to
  # find, so the case runs the same way on a host that has none.
  : > "$root/lib/libstdc++.so.6"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  printf '%s\n' 'One sentence here. Second sentence there.' > "$input"

  # The renderer is invoked as
  # python <renderer.py> <model> <voices> <chunk> <wav> <voice> <speed> <lang>.
  cat > "$kokoro/venv/bin/python" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -c ] && exit 0
printf '%s' wav-bytes > "$5"
SH
  chmod +x "$kokoro/venv/bin/python"
  cat > "$fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
for last; do :; done
printf '%s' mp3-bytes > "$last"
SH
  cat > "$fakebin/ffprobe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 12.5
SH
  chmod +x "$fakebin/ffmpeg" "$fakebin/ffprobe"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    LD_LIBRARY_PATH="$root/lib" "$SPEAK" "$input" --out "$outdir" --title "Fixture report") ||
    fail "render failed: $out"

  mp3=$(printf '%s\n' "$out" | sed -n 's/^file: //p')
  [ -f "$mp3" ] || fail "render reported a file that does not exist: $mp3"
  [ "$(printf '%s\n' "$out" | sed -n 's/^voice: //p')" = "af_heart" ] ||
    fail "a render without --voice must report the documented default voice af_heart (got: $out)"
  [ "$(printf '%s\n' "$out" | sed -n 's/^duration: //p')" = "0:13" ] ||
    fail "duration line must round the measured 12.5 seconds to 0:13 (got: $out)"
  [ "$(printf '%s\n' "$out" | sed -n 's/^size: //p')" = "$(wc -c <"$mp3" | tr -d '[:space:]')" ] ||
    fail "size line must be the byte count of the rendered mp3"$'\n'"--- output ---"$'\n'"$out"
  grep -F -- "| Fixture report | 0:13 |" "$outdir/index.md" >/dev/null ||
    fail "index does not hold the rendered row"
  pass "render: reports the real mp3 byte count and indexes the row"
}

test_setup_on_macos_does_not_require_libstdcxx() {
  local root fakebin kokoro out tmp
  root=$TMP_ROOT/darwin-setup
  kokoro=$root/kokoro
  # A TMPDIR that does not exist: --setup must need no throwaway work directory.
  tmp=$root/no-such-tmp
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin"
  cat > "$kokoro/venv/bin/python" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -c ] || exit 1
exit 0
SH
  chmod +x "$kokoro/venv/bin/python"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  fake_darwin "$fakebin"
  fake_curl "$fakebin"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" TMPDIR="$tmp" \
    "$SPEAK" --setup) ||
    fail "--setup failed on a Darwin host and must not need a temporary work directory: $out"
  assert_contains "$out" "cxx-runtime: not needed on Darwin" \
    "setup on macOS must not ask for a libstdc++ the platform does not need"
  assert_contains "$out" "venv: present" \
    "setup must report a venv that can import its packages as present"
  pass "setup: macOS needs no C++ runtime step, needs no temporary work directory, and a working venv is present"
}

# docs/audio-briefings.md: a venv whose packages are installed but whose C++
# runtime cannot be loaded is reported as that runtime cause, never as missing
# packages, and --setup leaves such a venv alone instead of reinstalling it.
test_unusable_cpp_runtime_is_reported_as_the_cause() {
  local root fakebin kokoro input outdir out rc
  root=$TMP_ROOT/runtime-cause
  kokoro=$root/kokoro
  input=$root/report.md
  outdir=$root/out
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin" "$root/lib"
  # A file named libstdc++.so.6 is what the Linux lookup hands the child process.
  : > "$root/lib/libstdc++.so.6"
  : > "$kokoro/venv/marker"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  printf '%s\n' 'One sentence here.' > "$input"
  fake_linux "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/ffmpeg"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/ffprobe"
  chmod +x "$fakebin/ffmpeg" "$fakebin/ffprobe"
  # The packages are installed (find_spec succeeds) but importing them fails the
  # way an unusable C++ runtime does.
  cat > "$kokoro/venv/bin/python" <<'SH'
#!/usr/bin/env bash
case ${2:-} in
  *find_spec*) exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$kokoro/venv/bin/python"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    LD_LIBRARY_PATH="$root/lib" "$SPEAK" --setup 2>&1)
  rc=$?
  expect_code 1 "$rc" "--setup must fail when the located C++ runtime cannot load the packages"
  assert_contains "$out" "the C++ runtime at $root/lib cannot be loaded" \
    "--setup must name the C++ runtime as the cause"
  assert_not_contains "$out" "venv: repairing" \
    "--setup must not rebuild a venv whose packages are installed"
  [ -e "$kokoro/venv/marker" ] ||
    fail "--setup deleted a venv that only the C++ runtime made unusable"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    LD_LIBRARY_PATH="$root/lib" "$SPEAK" "$input" --out "$outdir" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a render must refuse a venv that only the C++ runtime makes unusable"
  assert_contains "$out" "the C++ runtime at $root/lib cannot be loaded" \
    "a render must report the C++ runtime cause"
  assert_not_contains "$out" "prepare it once with" \
    "a render must not ask for --setup when the cache itself is fine"
  [ ! -d "$outdir" ] || fail "the render wrote output before the runtime was usable"
  pass "cache: an unusable C++ runtime is reported as the cause, not as missing packages"
}

# docs/audio-briefings.md: a missing prerequisite is reported with how to install
# it. A host without curl must get that line, not a shell `command not found`
# followed by a failed download, and nothing may be written to the cache first.
test_setup_reports_missing_curl_before_downloading() {
  local root fakebin kokoro out rc
  root=$TMP_ROOT/setup-no-curl
  kokoro=$root/kokoro
  fakebin=$(fm_fakebin "$root")
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" Darwin' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  ln -s "$(command -v mkdir)" "$fakebin/mkdir"
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"

  out=$(PATH="$fakebin" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$BASH" "$SPEAK" --setup 2>&1)
  rc=$?
  expect_code 1 "$rc" "--setup must fail when curl is missing and a download is needed"
  assert_contains "$out" "curl is needed to download" \
    "a missing curl must be reported as the missing tool"
  assert_contains "$out" "install it with your package manager" \
    "the missing-curl line must say how to install it"
  assert_not_contains "$out" "command not found" \
    "setup must not let the shell report the missing curl"
  assert_not_contains "$out" "could not download" \
    "a missing curl must not be reported as a failed download"
  [ ! -e "$kokoro/kokoro-v1.0.onnx" ] ||
    fail "setup downloaded the model after reporting the missing curl"
  [ ! -e "$kokoro/voices-v1.0.bin" ] ||
    fail "setup downloaded the voices after reporting the missing curl"
  pass "setup: a missing curl is named with its install line before any download"
}

# docs/audio-briefings.md: a missing prerequisite is reported with how to install
# it, so python3 gets the same install line curl gets.
test_setup_reports_missing_python3_with_an_install_hint() {
  local root fakebin kokoro out rc
  root=$TMP_ROOT/setup-no-python3
  kokoro=$root/kokoro
  fakebin=$(fm_fakebin "$root")
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" Darwin' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  ln -s "$(command -v mkdir)" "$fakebin/mkdir"
  fake_curl "$fakebin"

  out=$(PATH="$fakebin" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$BASH" "$SPEAK" --setup 2>&1)
  rc=$?
  expect_code 1 "$rc" "--setup must fail when python3 is missing and a venv must be built"
  assert_contains "$out" "python3 is needed to build the Kokoro venv" \
    "a missing python3 must be reported as the missing tool"
  assert_contains "$out" "install python3 3.10 to 3.13" \
    "the missing-python3 line must say which python3 to install"
  assert_contains "$out" "python3-venv" \
    "the missing-python3 line must name the venv module Debian and Ubuntu users need"
  assert_not_contains "$out" "command not found" \
    "setup must not let the shell report the missing python3"
  pass "setup: a missing python3 is named with its install line"
}

# docs/audio-briefings.md: the C++ runtime is a Linux cause. Off Linux a venv
# that cannot import its packages is rebuilt, never blamed on a runtime the
# platform does not use.
test_setup_repairs_an_unimportable_venv_off_linux() {
  local root fakebin kokoro out
  root=$TMP_ROOT/setup-repair-darwin
  kokoro=$root/kokoro
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$kokoro/venv/bin/python"
  chmod +x "$kokoro/venv/bin/python"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  fake_darwin "$fakebin"
  fake_venv_builder "$fakebin"
  fake_curl "$fakebin"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    "$SPEAK" --setup 2>&1) || fail "--setup did not repair the venv on macOS: $out"
  assert_contains "$out" "venv: repairing" \
    "an unimportable venv off Linux must be rebuilt"
  assert_not_contains "$out" "C++ runtime" \
    "a macOS venv must not be blamed on a C++ runtime the platform does not use"
  "$kokoro/venv/bin/python" -c 'import kokoro_onnx, soundfile' ||
    fail "the rebuilt venv still cannot import kokoro_onnx and soundfile"
  pass "setup: an unimportable venv off Linux is rebuilt, not blamed on a runtime"
}

# docs/audio-briefings.md: the index records every rendered file, written as
# soon as that file is encoded, so a later failure leaves no part unrecorded.
test_failed_later_part_still_leaves_earlier_parts_indexed() {
  local root fakebin kokoro outdir input out rc part1 f n
  root=$TMP_ROOT/partial-render
  kokoro=$root/kokoro
  outdir=$root/out
  input=$root/report.md
  fakebin=$(fm_fakebin "$root")
  mkdir -p "$kokoro/venv/bin" "$root/lib"
  : > "$root/lib/libstdc++.so.6"
  printf '%s' model > "$kokoro/kokoro-v1.0.onnx"
  printf '%s' voices > "$kokoro/voices-v1.0.bin"
  cat > "$kokoro/venv/bin/python" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -c ] && exit 0
printf '%s' wav-bytes > "$5"
SH
  chmod +x "$kokoro/venv/bin/python"
  # The second encode fails, the way a full disk or a dying encoder would.
  cat > "$fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
n=0
[ -f "$FM_RENDER_FFMPEG_COUNT" ] && n=$(cat "$FM_RENDER_FFMPEG_COUNT")
n=$((n + 1))
printf '%s' "$n" > "$FM_RENDER_FFMPEG_COUNT"
[ "$n" -ge 2 ] && exit 1
for last; do :; done
printf '%s' mp3-bytes > "$last"
SH
  cat > "$fakebin/ffprobe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 12.5
SH
  chmod +x "$fakebin/ffmpeg" "$fakebin/ffprobe"
  # Nine words a line and twenty lines: more than one --max-minutes 1 chunk.
  for ((n = 1; n <= 20; n++)); do
    printf 'Paragraph %s has ten words in it right here.\n' "$n"
  done > "$input"

  out=$(PATH="$fakebin:$PATH" HOME="$HOME_DIR" FM_TTS_KOKORO_DIR="$kokoro" \
    LD_LIBRARY_PATH="$root/lib" FM_RENDER_FFMPEG_COUNT="$root/ffmpeg-count" \
    "$SPEAK" "$input" --out "$outdir" --max-minutes 1 --title "Partial report" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a render must fail when a later part cannot be encoded"
  part1=
  for f in "$outdir"/*-part1.mp3; do
    [ -e "$f" ] || continue
    part1=$f
    break
  done
  [ -n "$part1" ] || fail "the encoded first part must stay on disk: $out"
  assert_contains "$(cat "$outdir/index.md")" "$(basename "$part1")" \
    "an encoded part must be indexed even when a later part fails"
  [ "$(grep -c '^| [[:digit:]]' "$outdir/index.md")" -eq 1 ] ||
    fail "the index must hold exactly one row for the one rendered file"
  pass "render: a later failure still leaves earlier parts on disk and indexed"
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
  cat > "$kokoro/venv/bin/python" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -c ] || exit 1
exit 0
SH
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
  [ "$(cache_entries "$kokoro")" = "venv voices-v1.0.bin " ] ||
    fail "a failed download left temporary files behind: $(cache_entries "$kokoro")"

  # The damaged model must not read as present to a render either.
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    pass "setup: a failed download leaves no cache file and a render refuses it (skipped render: ffmpeg and ffprobe are not on PATH)"
    return 0
  fi
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
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    pass "render preflight: cache gate (skipped: ffmpeg and ffprobe are not on PATH)"
    return 0
  fi
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
  test_print_text_creates_no_output_directory \
  test_emphasis_keeps_identifiers_and_arithmetic \
  test_removed_urls_keep_the_sentence_boundary \
  test_render_reports_the_mp3_size_and_indexes_it \
  test_setup_on_macos_does_not_require_libstdcxx \
  test_unusable_cpp_runtime_is_reported_as_the_cause \
  test_setup_reports_missing_curl_before_downloading \
  test_setup_reports_missing_python3_with_an_install_hint \
  test_setup_repairs_an_unimportable_venv_off_linux \
  test_failed_later_part_still_leaves_earlier_parts_indexed \
  test_setup_repairs_a_venv_that_cannot_import \
  test_setup_leaves_no_cache_file_after_a_failed_download \
  test_render_refuses_a_cache_that_cannot_import
