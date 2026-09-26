# Herdr checklist

A [Herdr](https://herdr.dev) plugin that gives you one at-a-glance view of everything in flight — what only you can unblock, what your agents are running, what is parked, and what just landed — as a single markdown file rendered in a dedicated, auto-refreshing pane.

It is a real Herdr plugin (a `herdr-plugin.toml` manifest plus a small shell entrypoint), so you install it with `herdr plugin` and open its pane with `herdr plugin pane open`.
The convention it packages — the four sections and the invariants that keep the file trustworthy — is the actual value; the code is tiny.

## What it looks like

```
# CHECKLIST — you                                 2026-09-15 14:22 local
# ════════════════════════════════════════════════════════════

## 🔴 ACT NOW — only you can do these
1. Paste the API key into the deploy config — unblocks the staging release.
   reply-word: "keyed"

## 🔵 IN FLIGHT — agents working right now
- Refactor the auth module (pane w3:p2). Done = green PR.

## 🟡 WAITING — parked on a word or an external event
- Design review: waiting on Sam's reply in the thread.

## 🟢 RECENTLY DONE
- Shipped the logging fix.
```

Follow [checklist-template.md](checklist-template.md) for the section, placement, and formatting contract on every edit.

## Install (under 5 minutes)

Link it as a local plugin (works with no remote):

```sh
herdr plugin link /path/to/firstmate/herdr-checklist
```

Or install it from the GitHub repo you got it from:

```sh
herdr plugin install <owner>/<repo>/herdr-checklist
```

Then create a checklist and open its pane:

```sh
herdr plugin action invoke herdr-checklist.new     # scaffolds the checklist file
herdr plugin pane open --plugin herdr-checklist --entrypoint checklist
```

Find the created file's path in the [plugin log](#where-the-file-lives), then edit it to fill in your checklist.
The pane refreshes automatically as you edit; see [Rendering](#rendering) for how it handles unavailable files.
To bind checklist creation to a key, add the action to Herdr's `config.toml`:

```toml
[[keys.command]]
key = "prefix+k"
type = "plugin_action"
command = "herdr-checklist.new"
description = "new checklist"
```

## Where the file lives

By default the checklist is `CHECKLIST.md` under the plugin's Herdr-managed state directory.
Actions run asynchronously, and Herdr captures `new`'s output in its plugin log:

```sh
herdr plugin log list --plugin herdr-checklist
```

Find the completed `new` action and read its `stdout` for the exact checklist path; if it is still running, run the log command again after it finishes.
To keep it somewhere you choose (for example a project's own `CHECKLIST.md`), set these variables in the environment that starts Herdr's server so both the action and pane inherit them:

```sh
export HERDR_CHECKLIST_FILE=/abs/path/to/CHECKLIST.md
export HERDR_CHECKLIST_OWNER="Your Name"    # written into the starter header
```

If the server is already running, exporting these in another shell will not update it: restart the server with this environment before invoking `new` and reopening the pane.
Passing `--env HERDR_CHECKLIST_FILE=/abs/path/to/CHECKLIST.md` to `herdr plugin pane open` overrides only the viewer's path; it does not change where the `new` action creates the file.

## Rendering

The pane uses [`glow`](https://github.com/charmbracelet/glow), `mdcat`, or `bat` if any is installed, and falls back to plain `cat` otherwise — nothing extra is required.
Force a choice by adding `--env HERDR_CHECKLIST_RENDERER=glow` to `herdr plugin pane open`.

The viewer checks for edits once per second by default.
If the checklist is missing or unreadable, it keeps the current frame and retries; a pane opened before the file exists stays blank until it can read it.
A failed render is retried on the next poll.

## Keeping it useful

You or your agent maintain the checklist's content; the plugin creates and displays the file.
Follow the format contract's [update discipline](checklist-template.md#update-discipline), including its guidance for agents after a context reset.

## Tests

```sh
./herdr-checklist.test.sh
```

Covers change detection, recovery from transient read and render failures, file-path resolution, renderer selection, and the starter skeleton.
