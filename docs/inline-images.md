# Inline images

Firstmate's Pi sessions can show a local image inline in the terminal instead of only printing its path.
The tracked `.pi/extensions/fm-image.ts` extension adds this for Pi only; every other primary harness, including the omp fork, keeps printing paths.

## Show an image

- `/image <path>` shows one PNG, JPEG, or WebP file in the transcript.
  It is stored as a custom session entry, which Pi keeps out of model context, so it spends no model tokens.
- The `fm_show_image` tool lets the agent show a generated image, screenshot, or other visual artifact the same way.
  The model receives only a text result naming the file and what the transcript shows, never the pixels; the agent uses `read` when it must inspect an image itself.
- A path can be absolute, relative to the working directory, start with `~/`, or be a local `file://` URL.

Every shown image begins with a path line in Pi's own image format, such as `[Image: ~/shots/login.png [image/png] 1280x800]`, which Pi links to the file when the terminal supports hyperlinks.
The path line stays even when the image draws, so a terminal path that silently drops graphics still leaves a way to open the file.

## How the image reaches the screen

Pi's TUI owns the terminal image protocol.
Its image component draws Kitty graphics, an iTerm2 inline image, or only the path line, from Pi's own terminal detection, its `PI_IMAGE_PROTOCOL` and `terminal.images` overrides, and its `terminal.showImages` switch in `/settings`; the extension writes no terminal escape of its own.
Kitty's transmission accepts PNG only, so the extension converts JPEG and WebP and hands Pi a bounded PNG copy.

| Terminal path | What appears |
|---|---|
| kitty, Ghostty, or WezTerm directly | The image, through Kitty graphics |
| iTerm2 | The image, through iTerm2 inline images |
| Herdr 0.9.0 or newer inside kitty, Ghostty, or WezTerm | The image, relayed by Herdr as Kitty graphics |
| tmux | The path line only, because Pi turns inline images off under tmux |
| A terminal where Pi detects no image support | The path line only |

Herdr parses a pane's Kitty graphics itself and redraws each image for every attached client whose cell size it knows.
Pane images are on by default from Herdr 0.9.0; `terminal.kitty_graphics = false` turns them off, and a server started by an older release keeps its old behavior until it restarts.
Releases before 0.9.0 kept pane images behind `experimental.kitty_graphics`, so images shown under them never appeared.

Inside a Herdr pane, Pi identifies the terminal from the environment the Herdr server started with, because Herdr passes that environment to every pane.
A server started from WezTerm therefore carries WezTerm's identity into every pane, and Pi picks Kitty graphics.
A server started some other way, or a client attached later from a different terminal, can leave that identity wrong; Pi's `PI_IMAGE_PROTOCOL` override corrects it, and Pi's own guidance applies: force Kitty only when every hop supports it.

WezTerm enables Kitty graphics by default through its `enable_kitty_graphics` option.

## Limits

- Only PNG, JPEG, and WebP files are shown, identified by their content signature rather than their name.
- Only ordinary local files are read: a symbolic link as the final path component, a directory, a FIFO, a device, an empty file, and a non-local URL are refused, and nothing is fetched over a network.
- A file may be at most 32 MiB, and its header must declare at most 16384 pixels per side and 40 megapixels; both are checked before any decoding.
- The display copy is at most 1200 pixels per side and 3 MiB encoded.
  The session stores that copy with the image, so a resumed session shows the image as it was shown even if the file changed.
- Pi's own image codec builds the display copy; when it cannot, only the path line appears.
- A file is read once, when it is shown, with no daemon, file watcher, or upload.
- Herdr consumes the graphics command inside the pane, so pane reads, including Firstmate's own pane captures, never contain image bytes or graphics escapes.

## Regression entry points

```sh
tests/fm-pi-image-extension.test.sh
tests/fm-pi-image-herdr-live-e2e.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#inline-kitty-images) records the dated Pi, Herdr, and WezTerm evidence and when to refresh it.
