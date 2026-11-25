# Audio briefings

`bin/fm-speak.sh` renders one markdown or text file to spoken MP3 audio with a local neural voice, and records what it rendered in an index beside the audio.
A report, an update, or a set of notes can then be listened to later instead of read.
It is on demand only: nothing renders on a schedule, nothing watches a directory, and a spoken file exists because someone ran one command for one named input.

Both engines are local and neural, and neither needs an API key, an account, or a cloud service.
The only network calls in the whole flow are the one-time downloads named below.

## Engines

| Engine | Default voice | Selected by | Notes |
| --- | --- | --- | --- |
| Kokoro-82M (ONNX, CPU only) | `af_heart` (US female) | default, or `--engine kokoro` | The tool's default voice and speed 1.0 |
| piper-tts | `en_US-lessac-high` | `--engine piper` | Optional second engine with its own voices |

Both engines honour `--voice` and `--speed`, and `--print-text` behaves identically on either.

## Install

The default engine needs `python3` 3.10 to 3.13 with its `venv` module (the Kokoro python package refuses newer interpreters, and Debian or Ubuntu users also need the `python3-venv` package), `ffmpeg`, and `ffprobe` on `PATH`, plus `curl` for the one-time downloads.
`ffmpeg` and `ffprobe` ship together, and any platform build works: `brew install ffmpeg`, `apt install ffmpeg`, or `nix shell nixpkgs#ffmpeg`.
A render never needs `curl`: only `--setup` and the piper voice download do.
Plan for about 530 MB of disk for the default engine's cache.

Both engines run on macOS and Linux.
The text pipeline is the same on either: it uses only portable tools (`awk`, `sed`, `iconv`, `tr`, `wc`), so `--print-text` and the sentence split produce the same sentences under the BSD tools macOS ships and under GNU tools.

Prepare the default engine once:

```sh
bin/fm-speak.sh --setup
```

`--setup` creates a python venv, installs `kokoro-onnx` and `soundfile` into it, downloads the Kokoro model and voice pack, and reports the C++ runtime it found.
It is idempotent: a re-run prints what is already present and downloads nothing.
It is also the repair: a venv that cannot import its packages is rebuilt, and each download is written to a temporary file and moved into place only when it completes, so a run interrupted by a network failure leaves nothing that a later run mistakes for a finished cache.

The C++ runtime step is Linux only.
On some Linux hosts onnxruntime cannot find a C++ runtime by itself, so the script locates `libstdc++` (a Nix store gcc build, or a standard multiarch `/usr/lib` path) and hands it to its own child process through `LD_LIBRARY_PATH`.
No caller environment is needed; a shell with `PATH` and `HOME` set is enough.
When no C++ runtime is found on Linux, `--setup` says so and a render stops with a message naming `LD_LIBRARY_PATH`.
On macOS onnxruntime links the platform C++ runtime, so `--setup` reports the runtime as not needed there and a render asks for nothing extra.

The optional piper engine needs its own binary, which the tool takes from `PATH` first and otherwise from a pinned build:

```sh
nix build 'nixpkgs#piper-tts' --out-link "$HOME/.cache/fm-tts/piper-tts"
```

Every missing piece is reported with the command that installs it rather than failing part-way through a render, and a Kokoro cache this build cannot use - files missing, or a venv whose packages will not import - is reported as one line naming `bin/fm-speak.sh --setup`, never as a Python traceback.

## Caches

Everything durable lives outside any checkout, so the tool keeps working after the checkout that installed it is gone.

| Path | Holds | Size |
| --- | --- | --- |
| `~/.local/share/fm-tts/kokoro/venv` | Kokoro python venv (`kokoro-onnx`, `soundfile`) | 188,685,171 bytes |
| `~/.local/share/fm-tts/kokoro/kokoro-v1.0.onnx` | Kokoro-82M model | 325,532,387 bytes |
| `~/.local/share/fm-tts/kokoro/voices-v1.0.bin` | Kokoro voice pack | 28,214,398 bytes |
| `~/.cache/fm-tts/piper-tts` | pinned piper build, only for `--engine piper` | a store or install path |
| `~/.cache/fm-tts/voices` | piper voice models | about 114 MB per high-tier voice |

`FM_TTS_KOKORO_DIR` and `FM_TTS_CACHE_DIR` relocate the two cache roots.
Both directories are pure caches: `rm -rf ~/.local/share/fm-tts/kokoro ~/.cache/fm-tts` clears everything, and the next `bin/fm-speak.sh --setup` recreates it.
Nothing in either directory is needed to re-render a file you still have, and no audio is stored there.

Fetched piper voices are public assets from the [piper-voices catalogue](https://huggingface.co/rhasspy/piper-voices); each needs its `.onnx` file and matching `.onnx.json` config.

| Voice id | Model file size | Reads as |
| --- | --- | --- |
| `en_US-lessac-high` (piper default) | 113,895,201 bytes | US female |
| `en_US-ryan-high` | 120,786,792 bytes | US male |
| `en_US-ljspeech-high` | 114,199,011 bytes | US female |
| `en_GB-cori-high` | 114,219,352 bytes | UK female |

A piper voice outside that catalogue map still works; the tool then names the two files it needs instead of guessing a download URL.

## Usage

```sh
bin/fm-speak.sh <input.md|txt> [--engine kokoro|piper] [--out <dir>]
                [--title <t>] [--max-minutes <n>] [--voice <id>] [--speed <n>]
                [--name <stem>] [--print-text]
```

```sh
bin/fm-speak.sh notes/report.md --title "Release review"
bin/fm-speak.sh notes/report.md --engine piper --voice en_US-ryan-high --speed 0.9
bin/fm-speak.sh notes/report.md --voice af_bella --speed 1.1
bin/fm-speak.sh notes/report.md --max-minutes 5
bin/fm-speak.sh notes/report.md --print-text   # what it would read aloud, no audio
```

The tool speaks prose, not markup: code fences, tables, HTML, link and image syntax, bare URLs, footnotes, front matter and emphasis markers are removed, headings become their own sentence, abbreviations are expanded, and the text is transliterated to ASCII before synthesis.
`--print-text` prints those cleaned sentences and exits without touching a synthesiser, needs no model cache, and is also how an alternate engine can reuse exactly the same words.

Long input is split on sentence boundaries so every output file stays under `--max-minutes` (default 10).
One part produces `<name>.mp3`; several produce `<name>-part1.mp3`, `<name>-part2.mp3` and so on, and each part is its own synthesis, so a long report takes proportionally longer to render.
The packer estimates pace and then measures every rendered part with `ffprobe`, so an under-estimate is corrected by re-packing and re-rendering rather than by shipping an over-long file.

Rendering is CPU-bound and faster than playback: a 48-word note became 18 seconds of audio in under 9 seconds of wall time on a 16-core x86_64 CPU, with the synthesis spread across cores.
The one-time setup download dominates the first run and is never repeated.

## Where the audio lands

The default output directory is `$HOME/audio-briefings`, created if missing, and `--out` overrides it.
`<out-dir>/index.md` records every rendered file with its date, title, duration, file name and source path, newest row on top, so the directory itself answers what has been spoken.
The engine, voice and speed of each render are printed on the command line rather than stored in the index.

Rendered audio stays on this machine.
The tool refuses outright to write into any path that names a Dropbox folder, so a synced drive cannot become an accidental destination; moving a file elsewhere is a deliberate human action, not something the tool does.

## What this does not do

- **It never uploads anything:** a render makes no network call at all, because the voice models are already on disk and synthesis happens in a local process.
- **It never renders on its own:** there is no daemon, scheduler, watcher, or queue, and one command renders exactly one named file.
- **It has no web surface and no feed:** audio and an index file are the whole output.
- **It is not a conversion service:** every spoken file is one deliberate render of one input file on your machine, not a standing pipeline for other people's documents.
- **It has no prosody controls beyond `--voice` and `--speed`:** the model's own defaults are the default.
