#!/usr/bin/env bash
# fm-speak.sh - render a markdown or text file to spoken MP3 audio with a local
# neural voice, and index what was rendered beside the audio.
#
# Usage:
#   fm-speak.sh <input.md|txt> [--engine kokoro|piper] [--out <dir>]
#               [--title <t>] [--max-minutes <n>] [--voice <id>] [--speed <n>]
#               [--name <stem>] [--print-text]
#   fm-speak.sh --setup
#   fm-speak.sh --help
#
# WHAT IT DOES. Reads one input file, turns its prose into speakable sentences,
# synthesises each chunk with a local neural voice, encodes mono MP3 with ffmpeg,
# and keeps an index of what it rendered. Everything stays on this machine: no
# cloud text to speech, no API key, and no network call except the one-time model
# and voice fetches named below.
#
# ENGINES. Kokoro-82M (ONNX, CPU only) is the default and reads `af_heart` at
# speed 1.0 unless --voice or --speed says otherwise; it is the voice this tool
# was built around. `--engine piper` selects piper-tts instead, where the default
# voice is `en_US-lessac-high`. Both engines honour --voice and --speed, and both
# are local: nothing leaves the machine, and nothing is fetched or synthesised
# until a render actually runs.
#
# AUDIO STAYS LOCAL. The default output directory is "audio-briefings" in your
# home directory, and the tool REFUSES to write anywhere whose path names a
# Dropbox folder, so rendered speech cannot drift onto a synced drive by
# accident. Moving a file somewhere else is a deliberate human action.
#
# SPEAKABLE PROSE, NOT RAW MARKDOWN. Code fences, tables, HTML, link and image
# syntax, bare URLs, footnote markers, front matter, list markers and emphasis
# markers are removed. Headings become their own sentence with a pause around
# them, so they read as section breaks rather than as shouted lines. Obvious
# abbreviations are expanded ("e.g." to "for example", "i.e." to "that is", "etc."
# to "et cetera", "vs" to "versus", "&" to "and", "%" to "percent", arrows to
# "to"), typographic quotes and dashes become their plain equivalents, and the
# text is transliterated to ASCII so an emoji or an accented name cannot stall
# the phonemiser.
#
# CHUNKING. Long input is split on sentence boundaries into as many files as
# needed to keep every output file under --max-minutes (default 10). Packing uses
# a conservative words-per-minute estimate, then the real duration of every
# rendered chunk is measured with ffprobe; if any chunk still runs past the limit
# the whole set is re-packed with a lower budget and re-rendered, up to four
# attempts before it refuses rather than shipping an over-long file. One chunk
# produces `<name>.mp3`; several produce `<name>-part1.mp3`, `<name>-part2.mp3`...
# Each part is its own synthesis, so render time grows with the part count.
#
# OUTPUT NAMING. By default `YYYY-MM-DD-<slug>.mp3`, where the slug comes from
# --title or from the input filename, and a same-day collision gets a counter
# suffix rather than overwriting the earlier briefing. --name <stem> writes
# exactly that stem instead, which is what a fixed comparison set needs, and
# replaces an existing render of the same stem.
#
# --voice names a voice for the selected engine (a Kokoro voice id such as
# `af_heart`, or a piper voice id such as `en_US-ryan-high`), and --speed scales
# the delivery rate: 1.0 is the voice's own pace, 0.9 is slower, 1.1 faster.
# Voice quality as such is the voice model's business; there is no other prosody
# knob.
#
# INDEX. `<out-dir>/index.md` gets one row per rendered file - date, title,
# duration, file name, source path - with the newest row on top. It is a record
# of what was rendered, not a feed or a schedule: nothing here renders anything
# on its own, and nothing is ever re-read aloud automatically. The file is
# created with its header on first use and edited in place afterwards.
#
# DEPENDENCIES AND CACHES, all local, all outside any checkout so the tool keeps
# working after the checkout that installed it is gone. ffmpeg and ffprobe must
# be on PATH; the default engine also needs python3 3.10-3.13 on PATH to build
# its venv once.
#   Kokoro (default). Everything lives in $FM_TTS_KOKORO_DIR, default
#   $HOME/.local/share/fm-tts/kokoro: a python venv (`venv/`) holding
#   kokoro-onnx and soundfile, `kokoro-v1.0.onnx` and `voices-v1.0.bin`. Create
#   it, or repair it, with the one command `fm-speak.sh --setup`. onnxruntime
#   does not find a C++ runtime by itself on every Linux host, so the script
#   locates libstdc++ (a Nix store build, or a standard multiarch /usr/lib path)
#   and sets LD_LIBRARY_PATH for its own child process; no caller environment is
#   needed. That lookup is Linux only: on macOS onnxruntime links the platform
#   C++ runtime, so a render there needs nothing extra.
#   piper (optional). `piper` comes from PATH or from the pinned build linked at
#   $FM_TTS_CACHE_DIR/piper-tts (default $HOME/.cache/fm-tts/piper-tts), and its
#   voice models live in $FM_TTS_CACHE_DIR/voices. Missing pieces fail loudly
#   with the exact command that installs them:
#     nix build 'nixpkgs#piper-tts' --out-link "$HOME/.cache/fm-tts/piper-tts"
#     curl -sSL -o "$HOME/.cache/fm-tts/voices/en_US-lessac-high.onnx" \
#       https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx
#     curl -sSL -o "$HOME/.cache/fm-tts/voices/en_US-lessac-high.onnx.json" \
#       https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx.json
#
# --setup prepares or repairs the default engine's cache (venv, python packages,
# model files) and reports where it lives and which C++ runtime it found. It is
# idempotent and safe to re-run.
#
# ENVIRONMENT. FM_TTS_ENGINE picks the default engine, FM_TTS_KOKORO_DIR the
# Kokoro cache, FM_TTS_CACHE_DIR the piper cache root, FM_TTS_VOICE the default
# voice id, and FM_TTS_PIPER an explicit piper binary.
#
# --print-text writes the cleaned speakable prose to stdout in place of the
# audio and exits, which is how an alternate synthesiser or a human can check and
# reuse exactly what this tool would read aloud.
#
# OUTPUT. One `file:`, one `duration:` and one `size:` line per rendered MP3,
# then `index:`, `engine:`, `voice:`, `speed:` and `total:`. Exit 0 on success,
# non-zero with a plain reason on any missing input, dependency, cache, model, or
# unwritable output directory.
set -u
set -o pipefail

SCRIPT_NAME=fm-speak.sh
ENGINE=${FM_TTS_ENGINE:-kokoro}
CACHE_DIR=${FM_TTS_CACHE_DIR:-$HOME/.cache/fm-tts}
VOICE_DIR=$CACHE_DIR/voices
KOKORO_DIR=${FM_TTS_KOKORO_DIR:-$HOME/.local/share/fm-tts/kokoro}
KOKORO_VENV=$KOKORO_DIR/venv
KOKORO_MODEL=$KOKORO_DIR/kokoro-v1.0.onnx
KOKORO_VOICES=$KOKORO_DIR/voices-v1.0.bin
# VOICE stays empty until the engine is known, so each engine can keep its own
# default without the other one leaking into it.
VOICE=${FM_TTS_VOICE:-}
DEFAULT_OUT=$HOME/audio-briefings
# Conservative spoken pace (a touch under the measured ~150 words per minute)
# used only to pack sentences into chunks; the real
# duration is measured after synthesis, and a bad estimate is corrected.
WORDS_PER_MINUTE=145
MAX_ATTEMPTS=4
# Only Linux needs the C++ runtime lookup below: macOS and Windows onnxruntime
# builds link the platform runtime themselves.
HOST_OS=$(uname -s)
libstdcpp_dir=

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  # The whole header block, found rather than counted: everything after the
  # shebang up to the first line that is not a comment.
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

slugify() {
  # ASCII-only, dash-separated, no leading or trailing dash, bounded length.
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' |
    cut -c1-60 |
    sed -E 's/-+$//'
}

fmt_duration() {
  # Seconds (may be fractional) to M:SS.
  awk -v s="$1" 'BEGIN { t = int(s + 0.5); printf "%d:%02d", int(t / 60), t % 60 }'
}

probe_seconds() {
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null
}

escape_cell() {
  # A markdown table cell cannot hold a pipe or a newline.
  printf '%s' "$1" | tr '\n' ' ' | sed 's/|/\\|/g'
}

# --setup failure text is one line so it can be pasted as-is.
setup_hint='prepare it once with: bin/fm-speak.sh --setup'

engine_default_voice() {
  case $1 in
    kokoro) printf 'af_heart' ;;
    *) printf 'en_US-lessac-high' ;;
  esac
}

# onnxruntime needs a C++ runtime that some Linux hosts do not put on the
# default loader path. Find one there and hand it to the child process only.
# Elsewhere the platform runtime is used, so an empty result means "not needed".
find_libstdcpp_dir() {
  local candidate dirs=()
  [ "$HOST_OS" = Linux ] || return 0
  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    IFS=: read -r -a dirs <<<"$LD_LIBRARY_PATH"
    for candidate in "${dirs[@]}"; do
      [ -n "$candidate" ] && [ -e "$candidate/libstdc++.so.6" ] && {
        printf '%s' "$candidate"
        return 0
      }
    done
  fi
  for candidate in \
    /nix/store/*-gcc-*-lib/lib/libstdc++.so.6 \
    /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
    /usr/lib/aarch64-linux-gnu/libstdc++.so.6 \
    /usr/lib/arm-linux-gnu/libstdc++.so.6 \
    /usr/lib/i386-linux-gnu/libstdc++.so.6 \
    /usr/lib/riscv64-linux-gnu/libstdc++.so.6 \
    /usr/lib/powerpc64le-linux-gnu/libstdc++.so.6 \
    /usr/lib/s390x-linux-gnu/libstdc++.so.6 \
    /usr/lib64/libstdc++.so.6 \
    /usr/lib/libstdc++.so.6; do
    [ -e "$candidate" ] && {
      dirname "$candidate"
      return 0
    }
  done
  return 1
}

# The renderer runs inside the durable venv; on Linux it is also the one child
# that needs the located C++ runtime on its loader path.
kokoro_python() {
  if [ -n "$libstdcpp_dir" ]; then
    LD_LIBRARY_PATH="$libstdcpp_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$KOKORO_VENV/bin/python" "$@"
  else
    "$KOKORO_VENV/bin/python" "$@"
  fi
}

# One validity test for the cache, shared by --setup (what to repair) and the
# render preflight (what to refuse), so a cache a render cannot use is never
# reported as present.
kokoro_venv_ready() {
  [ -x "$KOKORO_VENV/bin/python" ] || return 1
  kokoro_python -c 'import kokoro_onnx, soundfile' >/dev/null 2>&1
}

kokoro_cache_ready() {
  [ -s "$KOKORO_MODEL" ] && [ -s "$KOKORO_VOICES" ] && kokoro_venv_ready
}

# A download reaches the cache only after it completes, so an interrupted or
# error response is never mistaken for a finished file.
fetch_kokoro_file() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  if ! curl -fsSL -o "$tmp" "$url" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest" || {
    rm -f "$tmp"
    return 1
  }
}

# The Kokoro renderer runs inside the durable venv, so the tool carries it as an
# embedded program and writes it into the throwaway work directory per run.
write_kokoro_renderer() {
  cat >"$workdir/kokoro_render.py" <<'KOKORO_PY'
import sys

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

model, voices, text_path, out_path, voice, speed, lang = sys.argv[1:8]
speed = float(speed)

sentences = [line.strip() for line in open(text_path, encoding="utf-8") if line.strip()]
batches = []
buffer = ""
for sentence in sentences:
    if buffer and len(buffer) + len(sentence) + 1 > 240:
        batches.append(buffer)
        buffer = sentence
    else:
        buffer = f"{buffer} {sentence}".strip()
if buffer:
    batches.append(buffer)

kokoro = Kokoro(model, voices)
parts = []
pause = np.zeros(int(24000 * 0.25), dtype=np.float32)
for batch in batches:
    samples, _rate = kokoro.create(batch, voice=voice, speed=speed, lang=lang)
    parts.append(np.asarray(samples, dtype=np.float32))
    parts.append(pause)
if not parts:
    sys.stderr.write("kokoro: nothing to speak\n")
    raise SystemExit(4)
sf.write(out_path, np.concatenate(parts), 24000)
KOKORO_PY
}

# Build or repair the default engine's cache. Idempotent; every step is skipped
# when its output is already there, so a re-run costs nothing.
cmd_setup() {
  printf 'kokoro cache: %s\n' "$KOKORO_DIR"
  mkdir -p "$KOKORO_DIR" || die "cannot create the Kokoro cache directory: $KOKORO_DIR"
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-speak-setup.XXXXXX") ||
    die "cannot create a temporary work directory"
  trap 'rm -rf "$workdir"' EXIT

  libstdcpp_dir=$(find_libstdcpp_dir)
  if [ -n "$libstdcpp_dir" ]; then
    printf 'cxx-runtime: %s\n' "$libstdcpp_dir"
  elif [ "$HOST_OS" = Linux ]; then
    printf 'cxx-runtime: none found; install a C++ runtime (glibc or the gcc C++ library), or set LD_LIBRARY_PATH\n'
  else
    printf 'cxx-runtime: not needed on %s\n' "$HOST_OS"
  fi

  if kokoro_venv_ready; then
    printf 'venv: present\n'
  else
    command -v python3 >/dev/null 2>&1 ||
      die "python3 is needed to build the Kokoro venv and is not on PATH"
    if [ -x "$KOKORO_VENV/bin/python" ]; then
      printf 'venv: repairing %s\n' "$KOKORO_VENV"
      rm -rf "$KOKORO_VENV" || die "could not replace the unusable venv at $KOKORO_VENV"
    else
      printf 'venv: creating %s\n' "$KOKORO_VENV"
    fi
    python3 -m venv "$KOKORO_VENV" || die "could not create the venv at $KOKORO_VENV"
    "$KOKORO_VENV/bin/pip" install --quiet --disable-pip-version-check \
      kokoro-onnx soundfile || die "could not install kokoro-onnx and soundfile into $KOKORO_VENV"
    kokoro_venv_ready ||
      die "the venv at $KOKORO_VENV cannot import kokoro-onnx and soundfile"
  fi

  if [ -s "$KOKORO_MODEL" ]; then
    printf 'model: present\n'
  else
    printf 'model: fetching %s\n' "$KOKORO_MODEL"
    fetch_kokoro_file \
      https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx \
      "$KOKORO_MODEL" || die "could not download the Kokoro model to $KOKORO_MODEL"
  fi

  if [ -s "$KOKORO_VOICES" ]; then
    printf 'voices: present\n'
  else
    printf 'voices: fetching %s\n' "$KOKORO_VOICES"
    fetch_kokoro_file \
      https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin \
      "$KOKORO_VOICES" || die "could not download the Kokoro voice pack to $KOKORO_VOICES"
  fi
  printf 'default-voice: %s\n' "$(engine_default_voice kokoro)"
  printf 'done: %s\n' "$KOKORO_DIR"
}

# The piper-voices catalogue organises models by language/name/quality; an idle
# voice outside that map still gets a clear message naming the two files it needs.
voice_path_in_catalogue() {
  case $1 in
    en_US-lessac-high) printf 'en/en_US/lessac/high' ;;
    en_US-lessac-medium) printf 'en/en_US/lessac/medium' ;;
    en_US-ryan-high) printf 'en/en_US/ryan/high' ;;
    en_US-ljspeech-high) printf 'en/en_US/ljspeech/high' ;;
    en_GB-cori-high) printf 'en/en_GB/cori/high' ;;
    en_GB-alan-medium) printf 'en/en_GB/alan/medium' ;;
    en_US-amy-medium) printf 'en/en_US/amy/medium' ;;
    *) printf '' ;;
  esac
}

# --- arguments ---------------------------------------------------------------

input=
out_dir=$DEFAULT_OUT
title=
max_minutes=10
speed=1.0
name_stem=
print_text=0

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    --out)
      [ $# -ge 2 ] || die "--out needs a directory"
      out_dir=$2
      shift 2
      ;;
    --title)
      [ $# -ge 2 ] || die "--title needs a value"
      title=$2
      shift 2
      ;;
    --max-minutes)
      [ $# -ge 2 ] || die "--max-minutes needs a value"
      max_minutes=$2
      shift 2
      ;;
    --engine)
      [ $# -ge 2 ] || die "--engine needs 'kokoro' or 'piper'"
      ENGINE=$2
      shift 2
      ;;
    --voice)
      [ $# -ge 2 ] || die "--voice needs a voice id for the selected engine"
      VOICE=$2
      shift 2
      ;;
    --setup)
      cmd_setup
      exit 0
      ;;
    --speed)
      [ $# -ge 2 ] || die "--speed needs a number, for example 0.9 or 1.1"
      speed=$2
      shift 2
      ;;
    --name)
      [ $# -ge 2 ] || die "--name needs a file stem"
      name_stem=$2
      shift 2
      ;;
    --print-text)
      print_text=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      [ -z "$input" ] || die "one input file at a time (already got: $input)"
      input=$1
      shift
      ;;
  esac
done

# Anything after -- is the input file, still only one of them.
if [ -n "${1:-}" ]; then
  [ -z "$input" ] || die "one input file at a time (already got: $input)"
  input=$1
  shift
  [ $# -eq 0 ] || die "unexpected arguments after the input file: $*"
fi

case $ENGINE in
  kokoro|piper) ;;
  *) die "--engine must be 'kokoro' or 'piper' (got: $ENGINE)" ;;
esac
[ -n "$VOICE" ] || VOICE=$(engine_default_voice "$ENGINE")

case $max_minutes in
  ''|*[!0-9]*) die "--max-minutes needs a whole number of minutes (got: $max_minutes)" ;;
esac
# Read as decimal: an all-digit value may still carry a leading zero, which the
# arithmetic expansion would otherwise treat as octal.
max_minutes=$((10#$max_minutes))
[ "$max_minutes" -ge 1 ] || die "--max-minutes needs at least 1 minute"
max_seconds=$((max_minutes * 60))

case $speed in
  ''|*[!0-9.]*|*.*.*) die "--speed needs a plain number such as 0.9 or 1.1 (got: $speed)" ;;
esac
awk -v s="$speed" 'BEGIN { exit !(s >= 0.5 && s <= 2.0) }' ||
  die "--speed must be between 0.5 and 2.0 (got: $speed)"
# piper scales DURATION, so a faster delivery is a smaller length scale.
length_scale=$(awk -v s="$speed" 'BEGIN { printf "%.4f", 1 / s }')

if [ -n "$name_stem" ]; then
  case $name_stem in
    */*) die "--name must be a bare file stem, not a path: $name_stem" ;;
  esac
  [ -n "$(slugify "$name_stem")" ] || die "--name needs at least one letter or digit: $name_stem"
fi

[ -n "$input" ] || die "no input file (usage: $SCRIPT_NAME <input.md|txt> [options]; try --help)"
[ -e "$input" ] || die "input file does not exist: $input"
[ -f "$input" ] || die "input is not a regular file: $input"
[ -r "$input" ] || die "input file is not readable: $input"
[ -s "$input" ] || die "input file is empty: $input"

# --- output policy -----------------------------------------------------------

# Rendered speech never belongs on a synced drive, so a Dropbox path is refused
# outright rather than quietly accepted.
if [ "$print_text" -eq 0 ]; then
  out_lower=$(printf '%s' "$out_dir" | tr '[:upper:]' '[:lower:]')
  case $out_lower in
    *dropbox*)
      die "refusing to write into a Dropbox folder: $out_dir
Rendered audio stays on this machine. Move a file yourself if you want it elsewhere."
      ;;
  esac
fi

# --- dependencies ------------------------------------------------------------

# --print-text needs the text pipeline only, so the audio dependencies below are
# required only on a real render.
if [ "$print_text" -eq 0 ]; then
command -v ffmpeg >/dev/null 2>&1 ||
  die "ffmpeg is not on PATH; it is required to encode the MP3 (install it with your package manager, for example nix shell nixpkgs#ffmpeg or brew install ffmpeg)"
command -v ffprobe >/dev/null 2>&1 ||
  die "ffprobe is not on PATH; it is required to verify the rendered audio (it ships with ffmpeg)"
fi

if [ "$print_text" -eq 0 ] && [ "$ENGINE" = kokoro ]; then
  libstdcpp_dir=$(find_libstdcpp_dir) ||
    die "no libstdc++ found for the Kokoro runtime; install a C++ runtime (for example nix build nixpkgs#gcc.cc.lib on NixOS) or set LD_LIBRARY_PATH"
  kokoro_cache_ready ||
    die "the Kokoro cache at $KOKORO_DIR is incomplete; $setup_hint"
  case $VOICE in
    b*) kokoro_lang=en-gb ;;
    *) kokoro_lang=en-us ;;
  esac
fi

if [ "$print_text" -eq 0 ] && [ "$ENGINE" = piper ]; then
piper_bin=${FM_TTS_PIPER:-}
if [ -z "$piper_bin" ]; then
  if command -v piper >/dev/null 2>&1; then
    piper_bin=$(command -v piper)
  elif [ -x "$CACHE_DIR/piper-tts/bin/piper" ]; then
    piper_bin=$CACHE_DIR/piper-tts/bin/piper
  else
    die "piper-tts is not available. Install the local synthesiser once with:
  nix build 'nixpkgs#piper-tts' --out-link \"$CACHE_DIR/piper-tts\"
or put a 'piper' binary on PATH."
  fi
fi
[ -x "$piper_bin" ] || die "piper binary is not executable: $piper_bin"

model_onnx=$VOICE_DIR/$VOICE.onnx
model_json=$VOICE_DIR/$VOICE.onnx.json
voice_url_base=https://huggingface.co/rhasspy/piper-voices/resolve/main
voice_url_dir=$(voice_path_in_catalogue "$VOICE")
if [ ! -r "$model_onnx" ] || [ ! -r "$model_json" ]; then
  if [ -n "$voice_url_dir" ]; then
    die "voice model '$VOICE' is not in $VOICE_DIR. Fetch it once with:
  mkdir -p \"$VOICE_DIR\"
  curl -sSL -o \"$model_onnx\" $voice_url_base/$voice_url_dir/$VOICE.onnx
  curl -sSL -o \"$model_json\" $voice_url_base/$voice_url_dir/$VOICE.onnx.json"
  else
    die "voice model '$VOICE' is not in $VOICE_DIR. That id is not in this
script's catalogue map, so place both files there yourself:
  $model_onnx
  $model_json
The public catalogue is https://huggingface.co/rhasspy/piper-voices (paths are
<language>/<locale>/<voice>/<quality>/<voice-id>.onnx[.json])."
  fi
fi
fi

# --- output directory --------------------------------------------------------

mkdir -p "$out_dir" 2>/dev/null ||
  die "cannot create the output directory: $out_dir"
[ -w "$out_dir" ] || die "output directory is not writable: $out_dir"

# --- work area ---------------------------------------------------------------

workdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-speak.XXXXXX") || die "cannot create a temporary work directory"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

text=$workdir/text.txt
sentences=$workdir/sentences.txt

# --- speakable prose ---------------------------------------------------------

# Block level pass: drop front matter, code fences, tables and rules; unwrap
# headings into their own sentences; strip list, quote and HTML scaffolding.
awk '
  NR == 1 && $0 ~ /^---[[:space:]]*$/ { front = 1; next }
  front { if ($0 ~ /^---[[:space:]]*$/) front = 0; next }
  /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
  fence { next }
  /^[[:space:]]*\|/ { next }
  /^[[:space:]]*[-:]+[[:space:]]*\|/ { next }
  /^[[:space:]]*([-*_][[:space:]]*){3,}$/ { next }
  /^[[:space:]]*$/ { print ""; next }
  {
    line = $0
    if (line ~ /^[[:space:]]*#+[[:space:]]/) {
      sub(/^[[:space:]]*#+[[:space:]]*/, "", line)
      sub(/[[:space:]]*#+[[:space:]]*$/, "", line)
      if (line != "" && line !~ /[.!?:;,]$/) { line = line "." }
      print ""
      if (line != "") { print line }
      print ""
      next
    }
    sub(/^[[:space:]]*>+[[:space:]]?/, "", line)
    sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)
    sub(/\[[ xX]\][[:space:]]+/, "", line)
    gsub(/<!--.*-->/, "", line)
    gsub(/<[^>]*>/, "", line)
    if (line ~ /^[[:space:]]*$/) { next }
    print line
  }
' "$input" >"$text" || die "could not read the input as text: $input"

# Inline pass: unwrap links, images, inline code and emphasis; normalise
# typography, HTML entities, bullets and abbreviations into spoken words. The
# typographic single quotes are built from bytes so the shell never has to carry
# a literal that reads as an unbalanced apostrophe.
rsquo=$(printf '\xe2\x80\x99')
lsquo=$(printf '\xe2\x80\x98')
sed -E \
  -e 's/!\[[^]]*\]\([^)]*\)//g' \
  -e 's/\[\[([^]]*)\]\]/\1/g' \
  -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
  -e 's/\(([A-Za-z0-9.-]+\.(com|org|net|nz|io|dev|app|co|uk|de|ca|ai)(\/[^ )]*)?(,[[:space:]]?[A-Za-z0-9.-]+\.(com|org|net|nz|io|dev|app|co|uk|de|ca|ai)(\/[^ )]*)?)*)\)//g' \
  -e 's/\[([^]]*)\]\[[^]]*\]/\1/g' \
  -e 's/\[\^[^]]*\]//g' \
  -e 's/\[[0-9]+\]//g' \
  -e 's/`+([^`]*)`+/\1/g' \
  -e 's/\*\*([^*]+)\*\*/\1/g' \
  -e 's/__([^_]+)__/\1/g' \
  -e 's/\*([^*]+)\*/\1/g' \
  -e 's/_([^_]+)_/\1/g' \
  -e 's/&nbsp;/ /g' \
  -e 's/&amp;/\&/g' \
  -e 's/&lt;/</g' \
  -e 's/&gt;/>/g' \
  -e "s/${rsquo}/'/g" \
  -e "s/${lsquo}/'/g" \
  -e 's/“/"/g' \
  -e 's/”/"/g' \
  -e 's/—/ - /g' \
  -e 's/–/ - /g' \
  -e 's/…/... /g' \
  -e 's/→/ to /g' \
  -e 's/←/ from /g' \
  -e 's/↔/ and /g' \
  -e 's/≈/ about /g' \
  -e 's/±/ plus or minus /g' \
  -e 's/°/ degrees/g' \
  -e 's/•/ /g' \
  -e 's/ ?-> ?/ to /g' \
  -e 's/([0-9])x([0-9])/\1 by \2/g' \
  -e 's#(https?|ftp)://[^ )>]*##g' \
  -e 's#(^|[^[:alnum:]_])www\.[^ )>]*#\1#g' \
  -e 's/§ ?/section /g' \
  -e 's/[[:space:]]+([.,;:!?])/\1/g' \
  "$text" >"$workdir/inline.txt" || die "could not normalise the input text"

# Abbreviation pass. The scan steps over the expansion, never over the boundary
# character before it, so repeated or adjacent forms all expand: `w/o w/o` and
# `e.g.e.g.` become two spoken forms, not one.
awk '
  function word_char(c) {
    return c != "" && c ~ /^[[:alnum:]_]$/
  }
  function expand(head) {
    if (substr(head, 1, 4) == "e.g.") { consumed = 4; return "for example," }
    if (substr(head, 1, 4) == "i.e.") { consumed = 4; return "that is," }
    if (substr(head, 1, 4) == "etc.") { consumed = 4; return "et cetera," }
    if (substr(head, 1, 7) == "approx.") { consumed = 7; return "approximately" }
    if (substr(head, 1, 3) == "vs." && substr(head, 4, 1) ~ /[[:space:]]/) {
      consumed = 3
      return "versus"
    }
    if (substr(head, 1, 2) == "vs" && substr(head, 3, 1) ~ /[[:space:]]/) {
      consumed = 2
      return "versus"
    }
    if (substr(head, 1, 3) == "w/o" && !word_char(substr(head, 4, 1))) {
      consumed = 3
      return "without"
    }
    if (substr(head, 1, 2) == "w/") { consumed = 2; return "with " }
    return ""
  }
  {
    line = $0
    n = length(line)
    start = 1
    i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      expansion = ""
      if (c == "&") {
        end = i - 1
        while (end >= start && substr(line, end, 1) ~ /[[:space:]]/) end--
        if (end >= start) printf "%s", substr(line, start, end - start + 1)
        printf " and "
        i++
        while (i <= n && substr(line, i, 1) ~ /[[:space:]]/) i++
        start = i
        continue
      }
      if (c == "%") {
        expansion = " percent"
        consumed = 1
      } else if (index("eiavw", c) > 0 && (i == 1 || !word_char(substr(line, i - 1, 1)))) {
        expansion = expand(substr(line, i, 7))
      }
      if (expansion != "") {
        if (i > start) printf "%s", substr(line, start, i - start)
        printf "%s", expansion
        i += consumed
        start = i
        continue
      }
      i++
    }
    if (start <= n) printf "%s", substr(line, start, n - start + 1)
    printf "\n"
  }
' "$workdir/inline.txt" >"$workdir/abbrev.txt" || die "could not expand abbreviations"

# Transliterate to ASCII: accented names and emoji must not reach the phonemiser
# raw. iconv drops what it cannot transliterate, which is exactly the intent.
if command -v iconv >/dev/null 2>&1; then
  iconv -f UTF-8 -t ASCII//TRANSLIT "$workdir/abbrev.txt" >"$workdir/ascii.txt" 2>/dev/null ||
    iconv -f UTF-8 -t ASCII//IGNORE "$workdir/abbrev.txt" >"$workdir/ascii.txt" 2>/dev/null ||
    cp "$workdir/abbrev.txt" "$workdir/ascii.txt"
else
  cp "$workdir/abbrev.txt" "$workdir/ascii.txt"
fi

# Collapse runs of whitespace, then put one sentence per line so packing can cut
# on real sentence starts instead of mid-clause. The split is awk rather than a
# sed replacement with an embedded newline, which GNU sed and BSD sed spell
# differently.
tr -s ' \t' ' ' <"$workdir/ascii.txt" |
  awk '
    {
      sub(/^ +/, "")
      sub(/ +$/, "")
      if ($0 == "") next
      rest = $0
      while (match(rest, /[.!?] +[A-Z0-9"\047]/)) {
        printf "%s\n", substr(rest, 1, RSTART)
        rest = substr(rest, RSTART + RLENGTH - 1)
      }
      if (rest != "") print rest
    }
  ' >"$sentences" || die "could not split the input into sentences"

[ -s "$sentences" ] || die "no speakable text survived cleanup: $input"

if [ "$print_text" -eq 1 ]; then
  cat "$sentences"
  exit 0
fi

# --- chunking and synthesis --------------------------------------------------

pack_chunks() {
  local budget=$1
  rm -f "$workdir"/chunk-*.txt "$workdir"/chunk-*.wav 2>/dev/null
  awk -v budget="$budget" -v dir="$workdir" '
    {
      if ($0 == "") next
      w = split($0, parts, /[ \t]+/)
      if (words > 0 && words + w > budget) { close(out); n++; words = 0 }
      if (words == 0) { out = sprintf("%s/chunk-%03d.txt", dir, n); printf "" > out }
      print >> out
      words += w
    }
    END { close(out) }
  ' "$sentences" || return 1
}

synthesise_chunk() {
  # One chunk text file in, one WAV out, for the selected engine.
  local chunk=$1 wav=$2
  if [ "$ENGINE" = kokoro ]; then
    kokoro_python "$workdir/kokoro_render.py" \
      "$KOKORO_MODEL" "$KOKORO_VOICES" "$chunk" "$wav" "$VOICE" "$speed" "$kokoro_lang" \
      >/dev/null 2>"$workdir/kokoro.err" ||
      die "kokoro failed on $(basename "$chunk"): $(tail -n 3 "$workdir/kokoro.err")"
  else
    # piper writes the WAV, not the transcript, so its chatter goes to stderr.
    "$piper_bin" -m "$model_onnx" -c "$model_json" -i "$chunk" -f "$wav" \
      --length-scale "$length_scale" \
      >/dev/null 2>"$workdir/piper.err" ||
      die "piper failed on $(basename "$chunk"): $(tail -n 3 "$workdir/piper.err")"
  fi
  [ -s "$wav" ] || die "$ENGINE produced no audio for $(basename "$chunk")"
}

render_chunks() {
  # Synthesise every chunk file. Returns non-zero if any chunk runs long.
  local over=0 chunk wav seconds
  for chunk in "$workdir"/chunk-*.txt; do
    [ -e "$chunk" ] || return 1
    wav=${chunk%.txt}.wav
    synthesise_chunk "$chunk" "$wav"
    seconds=$(probe_seconds "$wav")
    [ -n "$seconds" ] || die "cannot measure the duration of $(basename "$wav")"
    awk -v s="$seconds" -v limit="$max_seconds" 'BEGIN { exit !(s > limit) }' && over=1
  done
  return "$over"
}

if [ "$ENGINE" = kokoro ]; then
  write_kokoro_renderer
fi

words_per_chunk=$((max_minutes * WORDS_PER_MINUTE))
attempt=1
while :; do
  pack_chunks "$words_per_chunk" || die "could not split the input into chunks"
  render_chunks && break
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    die "could not keep every part under $max_minutes minute(s) after $attempt attempts; lower --max-minutes or shorten the input"
  fi
  # The estimate was optimistic: shrink the budget proportionally and retry.
  words_per_chunk=$((words_per_chunk * 3 / 4))
  [ "$words_per_chunk" -ge 40 ] || words_per_chunk=40
  attempt=$((attempt + 1))
done

chunk_count=0
for chunk in "$workdir"/chunk-*.txt; do
  [ -e "$chunk" ] || continue
  chunk_count=$((chunk_count + 1))
done
[ "$chunk_count" -ge 1 ] || die "no audio was rendered from $input"

# --- naming and encoding -----------------------------------------------------

input_stem=$(basename -- "$input")
input_stem=${input_stem%.*}
name_seed=${title:-$input_stem}
today=$(date +%Y-%m-%d)

if [ -n "$name_stem" ]; then
  candidate=$out_dir/$name_stem
else
  slug=$(slugify "$name_seed")
  [ -n "$slug" ] || slug=briefing
  base=$out_dir/$today-$slug
  candidate=$base
  suffix=2
  while [ -e "$candidate.mp3" ] || [ -e "$candidate-part1.mp3" ]; do
    [ "$suffix" -le 99 ] || die "too many briefings named '$today-$slug' in $out_dir"
    candidate=$base-$suffix
    suffix=$((suffix + 1))
  done
fi

rows=$workdir/rows.md
: >"$rows"
total_seconds=0
part=0
for chunk in "$workdir"/chunk-*.txt; do
  [ -e "$chunk" ] || continue
  part=$((part + 1))
  wav=${chunk%.txt}.wav
  if [ "$chunk_count" -eq 1 ]; then
    dest=$candidate.mp3
    row_title=$name_seed
  else
    dest=$candidate-part$part.mp3
    row_title="$name_seed (part $part of $chunk_count)"
  fi
  ffmpeg -nostdin -v error -y -i "$wav" -ac 1 -ar 22050 -codec:a libmp3lame -b:a 64k "$dest" \
    >/dev/null 2>&1 || die "ffmpeg could not encode $dest"
  [ -s "$dest" ] || die "ffmpeg produced no audio at $dest"

  seconds=$(probe_seconds "$dest")
  [ -n "$seconds" ] || die "cannot measure the duration of $dest"
  total_seconds=$(awk -v a="$total_seconds" -v b="$seconds" 'BEGIN { printf "%.3f", a + b }')
  size=$(wc -c <"$dest" | tr -d '[:space:]')
  duration=$(fmt_duration "$seconds")
  abs_source=$(cd -- "$(dirname -- "$input")" && pwd)/$(basename -- "$input")

  printf '| %s | %s | %s | %s | %s |\n' \
    "$today" \
    "$(escape_cell "$row_title")" \
    "$duration" \
    "$(escape_cell "$(basename -- "$dest")")" \
    "$(escape_cell "$abs_source")" >>"$rows"

  printf 'file: %s\n' "$dest"
  printf 'duration: %s\n' "$duration"
  printf 'size: %s\n' "$size"
done

# --- index -------------------------------------------------------------------

index=$out_dir/index.md
if [ ! -f "$index" ]; then
  {
    printf '# Rendered audio\n\n'
    printf "Rendered by \`bin/fm-speak.sh\`. A record of what was spoken, newest first.\n\n"
    printf '| Date | Title | Duration | File | Source |\n'
    printf '| --- | --- | --- | --- | --- |\n'
  } >"$index" || die "cannot write the index: $index"
fi

awk -v rows_file="$rows" '
  BEGIN {
    rows = ""
    while ((getline line < rows_file) > 0) { rows = rows line "\n" }
    close(rows_file)
  }
  { print }
  /^\|[[:space:]]*-/ && !inserted { printf "%s", rows; inserted = 1 }
  END { if (!inserted) { printf "%s", rows } }
' "$index" >"$workdir/index.new" || die "cannot update the index: $index"
mv -f "$workdir/index.new" "$index" || die "cannot replace the index: $index"

printf 'index: %s\n' "$index"
printf 'engine: %s\n' "$ENGINE"
printf 'voice: %s\n' "$VOICE"
printf 'speed: %s\n' "$speed"
printf 'total: %s\n' "$(fmt_duration "$total_seconds")"
