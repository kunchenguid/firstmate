# Verification: `show-me` skill availability on pi

Active empirical facts for the vendored [`skills/show-me/`](../../skills/show-me/) public skill.
[FIRSTMATE.md](../../skills/show-me/FIRSTMATE.md) owns how to deliver a visual and which view answers which judgement; this record owns what was measured on a real harness, the exact commands, and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-09-28 |
| Harness | pi 0.84.2 (`pi --version`) |
| Package source | `@earendil-works/pi-coding-agent/dist/core/skills.js` and `dist/core/agent-session.js`, read directly |
| Pi docs read | `docs/skills.md` of the same installed package |
| Platform | macOS arm64, in a disposable firstmate task worktree |
| Model surface | Non-interactive `--mode text --print` runs against the session's configured provider |

Every probe below ran outside any captain fleet state; no firstmate home file other than the task's own status record was written.

## Confirmed: `disable-model-invocation: true` keeps the skill out of context

```js
// dist/core/skills.js
export function formatSkillsForPrompt(skills) {
    const visibleSkills = skills.filter((s) => !s.disableModelInvocation);
    if (visibleSkills.length === 0) {
        return "";
    }
```

and the field it reads:

```js
disableModelInvocation: frontmatter["disable-model-invocation"] === true,
```

Consequence: with the upstream flag set, the skill's name and description never enter the system prompt, so it costs context only when a human invokes it.
This is why the vendor copy keeps the flag unchanged.

## Confirmed: `/skill:show-me` loads the body, and registration alone does not

Run from a project copy that holds the skill at `.agents/skills/show-me/`, with the skill registered by path:

```
$ cd <project-copy>
$ pi --skill <project-copy>/.agents/skills/show-me --no-context-files --offline \
    --mode text --print "/skill:show-me Reply exactly two lines ..."
SEEN=YES
SIBLING=NO
```

Two controls bracket that result, same flags, one variable changed each time:

| Control | Result |
|---|---|
| No `--skill` registration at all | `SEEN=NO` - the command passes through as unknown text |
| Registered from elsewhere while the cwd has no discovered copy | `SEEN=YES` - registration is what makes the name resolvable |
| Ordinary prompt, no `/skill:` invocation, skill registered and discoverable | `LISTED=NO` - manual-only keeps it out of the system-prompt skill list |
| Ask for the sibling by name instead (`name: peekaboo`) | `SEEN=NO` - expansion is keyed to the skill's own name |

Consequences the vendor layout depends on:
- A forced load injects only `SKILL.md`; `FIRSTMATE.md` never arrives unless read explicitly (`SIBLING=NO`), which is why the adaptation is referenced rather than assumed.
- The cost gate is real: an ordinary session pays nothing for this skill until a human invokes it.
- Registration and discovery are separate steps, so "installed" and "invocable" are different claims; both were needed above.

## Confirmed: discovery locations and the `skills/` gap

From `docs/skills.md`: project discovery covers `.pi/skills/` and `.agents/skills/` in the working directory and its ancestors (only after the project is trusted), plus the global agent skill directories, package `skills/` resources, a `settings.json` `skills` array, and `--skill <path>`.
A repository-root `skills/` directory is not among them, so this public installer-facing copy loads only once something installs it into a discovered location or passes `--skill` explicitly.

Loader behaviour checked alongside it: `loadSkillsFromDirInternal` recurses into subdirectories looking for `SKILL.md`, treats a path that is a file as a single skill, and returns silently (`{ skills: [], diagnostics: [] }`) when the given directory contains none.

## Confirmed: explicit `--skill` run starts and completes

```
$ cd /tmp && pi --skill <worktree>/skills/show-me --no-context-files --offline --mode text \
    --print "Reply with exactly the line: SKILL_SURFACE_OK"
SKILL_SURFACE_OK
```

A bare directory with no `SKILL.md` passed to `--skill` also exits cleanly with zero skills loaded, so installing `skills/show-me/` anywhere cannot break a session that points at it.

## Confirmed: HTML to image with no new dependency

```
$ "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
    --hide-scrollbars --window-size=384,140 --screenshot=/tmp/shot/out.png file:///tmp/shot/t.html
5900 bytes written to file /tmp/shot/out.png
$ file /tmp/shot/out.png
/tmp/shot/out.png: PNG image data, 384 x 140, 8-bit/color RGB, non-interlaced
```

Measured on a machine with none of `mmdc`, `wkhtmltoimage`, `rsvg-convert`, `convert`, `magick`, or a Chromium CLI installed; the existing Google Chrome app supplied the rasterisation.

## Confirmed: the WeChat image surface and its limits

`send_image_to_wechat` comes from the installed `pi-wechat-assistant` extension (`src/index.ts`), takes one parameter `imagePath`, documents png/jpg/gif/webp, and restricts sends to the session's project directory.
Calling it in this session returned `微信桥接未启动，请先在 TUI 执行 /wechat start`: the bridge was not running, which is the concrete case the rank-3 fallback in [FIRSTMATE.md](../../skills/show-me/FIRSTMATE.md) exists for.

## Not proven

- End-to-end delivery of a rendered diagram to a captain's WeChat conversation: blocked by the bridge being stopped above, so only the renderer and the tool contract are proven, not the round trip.
- Any harness besides pi: claude, codex, opencode, grok, kimi, cursor, omp, and the rest of firstmate's verified adapters were not exercised for this skill.
- Whether `chrome-devtools-axi` or `lavish-axi` is reachable in a given session; neither was available in the session that produced this record.
- Rendering quality at realistic diagram sizes, and whether an attached HTML file previews usefully on a phone.

## Reproducing these probes

The portable regression is [`tests/fm-show-me-skill.test.sh`](../../tests/fm-show-me-skill.test.sh); run it with `bash tests/fm-show-me-skill.test.sh`.
It drives the loader and the gating control above through pi itself, skips cleanly when pi is absent, and fails loudly on a provider quota refusal rather than reporting a pass it did not observe.

## Refreshing this record

Re-run the three commands above in a session whose provider quota is available and whose WeChat bridge is started, then update the dated rows.
The structural claims (`disable-model-invocation` filtering, single-file expansion, discovery locations) refresh by reading the installed pi package's `dist/core/skills.js` and `dist/core/agent-session.js` for the version in use.
