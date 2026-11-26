# Audio briefings

`bin/fm-speak.sh` renders one markdown or text file to spoken MP3 audio with a local neural voice, and records what it rendered in an index beside the audio.
A report, an update, or a set of notes can then be listened to later instead of read.
It is on demand only: nothing renders on a schedule, nothing watches a directory, and a spoken file exists because someone ran one command for one named input.

## Engine

The tool ships one local engine: Kokoro-82M (ONNX, CPU only), reading `af_heart` (US female) at speed 1.0 unless `--voice` or `--speed` says otherwise.
It is local and neural, and it needs no API key, an account, or a cloud service.
The only network calls in the whole flow are the one-time downloads named below.
One engine is the design: choosing a different one is deliberately out of scope, and a maintainer who wants more can ask for it as its own change.

## Install

The engine needs `python3` 3.10 to 3.13 with its `venv` module (the Kokoro python package refuses newer interpreters, and Debian or Ubuntu users also need the `python3-venv` package), `ffmpeg`, and `ffprobe` on `PATH`, plus `curl` for the one-time downloads.
`ffmpeg` and `ffprobe` ship together, and any platform build works: `brew install ffmpeg`, `apt install ffmpeg`, or `nix shell nixpkgs#ffmpeg`.
A render never needs `curl`: only a `--setup` that has to download something does, and it names `curl` and how to install it when it is missing.
Plan for about 530 MB of disk for the cache.

It runs on macOS and Linux.
The text pipeline uses only portable tools (`awk`, `sed`, `iconv`, `tr`, `wc`), so `--print-text` and the sentence split produce the same sentences under the BSD tools macOS ships and under GNU tools.

Prepare the engine once:

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

Every missing piece is reported with the command that installs it rather than failing part-way through a render, and a Kokoro cache this build cannot use - files missing, or a venv whose packages will not import - is reported as one line naming `bin/fm-speak.sh --setup`, never as a Python traceback.
A venv whose packages are installed but cannot import on Linux is a different failure: it is reported as a C++ runtime cause, naming the located `libstdc++` or saying that none was found, plus `LD_LIBRARY_PATH`, and `--setup` leaves the venv in place instead of reinstalling it.

## Caches

Everything durable lives outside any checkout, so the tool keeps working after the checkout that installed it is gone.

| Path | Holds | Size |
| --- | --- | --- |
| `~/.local/share/fm-tts/kokoro/venv` | Kokoro python venv (`kokoro-onnx`, `soundfile`) | 188,685,171 bytes |
| `~/.local/share/fm-tts/kokoro/kokoro-v1.0.onnx` | Kokoro-82M model | 325,532,387 bytes |
| `~/.local/share/fm-tts/kokoro/voices-v1.0.bin` | Kokoro voice pack | 28,214,398 bytes |

`FM_TTS_KOKORO_DIR` relocates the cache root.
The cache is pure cache: `rm -rf ~/.local/share/fm-tts/kokoro` clears everything, and the next `bin/fm-speak.sh --setup` recreates it.
Nothing in it is needed to re-render a file you still have, and no audio is stored there.

## Usage

```sh
bin/fm-speak.sh <input.md|txt> [--out <dir>] [--title <t>]
                [--max-minutes <n>] [--voice <id>] [--speed <n>]
                [--print-text]
```

```sh
bin/fm-speak.sh notes/report.md --title "Release review"
bin/fm-speak.sh notes/report.md --voice af_bella --speed 0.9
bin/fm-speak.sh notes/report.md --max-minutes 5
bin/fm-speak.sh notes/report.md --print-text   # what it would read aloud, no audio
```

The tool speaks prose, not markup: code fences, tables, HTML tags, link and image syntax, bare URLs, footnotes, front matter and emphasis markers are removed, headings become their own sentence, abbreviations are expanded, and the text is transliterated to ASCII before synthesis.
`--print-text` prints those cleaned sentences and exits without touching a synthesiser, creates no output directory, needs no model cache, and is also how a human or another tool can reuse exactly the same words.

Long input is split on sentence boundaries so every output file stays under `--max-minutes` (default 10).
One part produces `<name>.mp3`; several produce `<name>-part1.mp3`, `<name>-part2.mp3` and so on, and each part is its own synthesis, so a long report takes proportionally longer to render.
The packer estimates pace and then measures every rendered part with `ffprobe`, so an under-estimate is corrected by re-packing and re-rendering rather than by shipping an over-long file.

Rendering is CPU-bound and faster than playback: a 48-word note became 18 seconds of audio in under 9 seconds of wall time on a 16-core x86_64 CPU, with the synthesis spread across cores.
The one-time setup download dominates the first run and is never repeated.

## Where the audio lands

The default output directory is `$HOME/audio-briefings`, created if missing, and `--out` overrides it.
`<out-dir>/index.md` records every rendered file with its date, title, duration, file name and source path, newest row on top, so the directory itself answers what has been spoken. It is append-only: one row per rendered file, written as soon as that file is encoded and measured, and no row is ever rewritten or pruned.
The engine, voice and speed of each render are printed on the command line rather than stored in the index.
Each render is named `YYYY-MM-DD-<slug>.mp3` from `--title` or the input filename, and a same-day collision gets a counter suffix instead of overwriting the earlier briefing.
Re-running into a fixed file name is deliberately out of scope: overwrite semantics need their own file-deletion and index rules, so a maintainer who wants them can add them as their own change.

Rendered audio stays on this machine.
The tool refuses outright to write into any path that names a Dropbox folder, so a synced drive cannot become an accidental destination; moving a file elsewhere is a deliberate human action, not something the tool does.

## What this does not do

- **It never uploads anything:** a render makes no network call at all, because the voice models are already on disk and synthesis happens in a local process.
- **It never renders on its own:** there is no daemon, scheduler, watcher, or queue, and one command renders exactly one named file.
- **It never overwrites or deletes a render:** every run writes newly named files and appends its own index rows.
- **It has no web surface and no feed:** audio and an index file are the whole output.
- **It is not a conversion service:** every spoken file is one deliberate render of one input file on your machine, not a standing pipeline for other people's documents.
- **It has no prosody controls beyond `--voice` and `--speed`:** the model's own defaults are the default.
- **It offers no second engine:** one local voice model is the whole synthesiser, by design.
