# browser-harness-herdr — browser automation through a visible Herdr pane

Reached from [`../SKILL.md`](../SKILL.md) when task = browser-harness-dispatch and engine = herdr.

## Overview

`browser-harness-herdr-axi` (`/home/adrian/dev/subagent-factory/tools/browser-harness-herdr-axi`) bridges `browser-harness` (direct CDP browser control, no LLM of its own) and Herdr: it opens an isolated, visible Herdr pane, connects `browser-harness` to the local Chrome CDP endpoint, reports Herdr agent status (`working` → `idle`), and leaves the pane's daemon alive across multiple `run` calls so page/tab state persists for the length of a task.

Unlike `references/reasonix-herdr.md` (one-shot dispatch, closes immediately after), this is session-shaped: `open` once, `run` as many scripts as the task needs, `close` explicitly when done. `run` does not auto-close the pane — you must call `close` yourself.

Facts to keep in mind:

- `browser-harness` scripts are Python, with helpers pre-imported (`page_info()`, `new_tab(url)`, `click_at_xy(x, y)`, `js(...)`, `cdp(...)`). First navigation is `new_tab(url)`, not `goto_url(url)`.
- Local Chrome requires `chrome://inspect/#remote-debugging` to be enabled with "Allow remote debugging for this browser instance" ticked, and the user must click Allow on Chrome's own permission popup — this cannot be done by the agent, only the user.
- If that permission is missing, `browser-harness` doesn't fail fast — it blocks/hangs waiting for the daemon rather than exiting. Don't assume a stuck pane is a code bug; check `close <pane_id> --force` is the way out, not a longer timeout.
- This tool never installs or auto-triggers itself outside Herdr — it does not compete with `browser-use`/`claude-in-chrome` for general web tasks.

## Step 1 — Open a session

Run: `browser-harness-herdr-axi open --purpose "<short label>"`

This creates/reuses the shared `browser-harness` tab, opens a new pane in it, and immediately checks the CDP connection with `page_info()`.

IF `open.status` is `"connected"`:
→ save the returned `pane_id`. Proceed to Step 2.

ELSE IF `open.status` is `"connect_failed"` or `"timeout"`:
→ go to Step 4 (Chrome permission).

## Step 2 — Drive the browser

Run: `browser-harness-herdr-axi run <pane_id> "<script>"` for each script — the daemon keeps page/tab state between calls, so a multi-step task (navigate, then click, then extract) is several `run` calls against the same `pane_id`, not one big script.

IF `run.status` is `"success"`:
→ treat the relayed output as the result. Continue with more `run` calls, or proceed to Step 3 when the task is done.

ELSE IF `run.status` is `"error"`:
→ read the relayed output and `exit_code` for why (a Python traceback from the script is normal here — fix the script and re-run, same pane).

ELSE IF `run.status` is `"timeout"`:
→ check `still_running`. If `true`, the browser task may just be slow (e.g. waiting on a real page load) — check again later with `status <pane_id>`. If `false`, the command already returned but the completion signal was missed — safe to just `run` a follow-up in the same pane.

### Navigating

IF this is the first navigation in the session:
→ `run <pane_id> "new_tab('<url>')\nwait_for_load()\nprint(page_info())"` — opens a new tab. `goto_url` has no tab to navigate yet at this point.

ELSE (a tab is already open from an earlier `run` call in this same pane):
→ `run <pane_id> "goto_url('<url>')\nwait_for_load()\nprint(page_info())"` — navigates within the already-open tab, keeping the same session/state. Verified 2026-07-20: `new_tab` then `goto_url` in the same pane correctly landed on two different pages in the same tab, confirmed each time via `page_info()`'s returned `url`/`title`.

Always call `wait_for_load()` after navigating, then confirm with `page_info()` before acting on the page — don't assume a navigation call succeeded just because `run.status` was `"success"`.

## Step 3 — Clean up

Run: `browser-harness-herdr-axi close <pane_id>` once the task is fully done. Always do this — leaving the pane open leaves the `browser-harness` process (and the Chrome CDP connection) running indefinitely.

IF `close.status` is `"closed"`:
→ done. If this was the last pane in the `browser-harness` tab, Herdr auto-closed the tab too.

ELSE IF `close.status` is `"still_running"`:
→ a script looks like it's still active in that pane. Don't force it if it might genuinely be doing real work (e.g. waiting on a slow page). If you're sure it's just hung (see Step 4's hang note), re-run with `--force`.

## Step 4 — Chrome permission blocks the connection

IF `open` or `run` reports a connection failure, or a pane looks stuck with no output progressing:
→ tell the user, in plain terms: open `chrome://inspect/#remote-debugging` in Chrome, tick "Allow remote debugging for this browser instance", and click Allow on the popup if one appears. This step requires the user — it cannot be automated.
→ STOP and wait for the user to confirm it's done.

ELSE (permission already confirmed enabled):
→ run `browser-harness --doctor` for a fuller diagnostic (`chrome running` / `daemon alive` / `active browser connections`), or read `https://github.com/browser-use/browser-harness/blob/main/install.md` for other failure modes (remote/cloud browser setup, `--doctor` output meanings).

## Notes for future updates

| Question | Action |
|---|---|
| New failure mode not covered? | Add it to Step 2 or Step 4 |
| Chrome permission flow changed upstream? | Update Step 4 |
| Cost, timing, or hang behavior different than documented? | Update the Overview |

If anything changed, snapshot the parent skill (`../SKILL.md` → `../SKILL.v<N+1>.md`) and add a row to `../VERSIONING.md`.
