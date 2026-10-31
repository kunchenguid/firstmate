# Verification: `show-me` skill availability on pi

Active empirical facts for the vendored [`skills/show-me/`](../../skills/show-me/) public skill.
[FIRSTMATE.md](../../.agents/skills/show-me/FIRSTMATE.md) owns how to deliver a visual and which view answers which judgement; this record owns what was measured on a real harness, the exact commands, and what is still unproven.

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
    --mode text --print "/skill:show-me Report exactly three lines ..."
SEEN=YES, SIBLING=NO, LISTED=NO
```

Two controls bracket that result, same flags, one variable changed each time:

| Control | Result |
|---|---|
| No `--skill` registration at all | `SEEN=NO` - the command passes through as unknown text |
| Registered while the cwd holds no discovered copy | `SEEN=YES` - the explicit path is what makes the name resolvable |
| Same prompt without the leading `/skill:` token | `SEEN=NO` - naming the command in prose does not load it |

Consequences the vendor layout depends on:
- A forced load injects only `SKILL.md`; `FIRSTMATE.md` never arrives unless read explicitly (`SIBLING=NO`), which is why the adaptation is referenced rather than assumed.
- Expansion keys on the message's **leading** token: a prompt that says "you were invoked with /skill:show-me" answers `SEEN=NO`. Any automation that forces this skill must send the literal command first.
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
The same command rendered a realistic 800x330 diagram containing an embedded SVG and Chinese labels into a 26.9 KB PNG, so neither size nor CJK text needed a dependency.

## Confirmed: the WeChat image surface and its limits

`send_image_to_wechat` comes from the installed `pi-wechat-assistant` extension (`src/index.ts`), takes one parameter `imagePath`, documents png/jpg/gif/webp, and restricts sends to the session's project directory.
Calling it in this session returned `微信桥接未启动，请先在 TUI 执行 /wechat start`: the bridge was not running, which is the concrete case the rank-2 fallback in [FIRSTMATE.md](../../.agents/skills/show-me/FIRSTMATE.md) exists for.

## Confirmed: the internal `.agents/skills/show-me/` copy loads by discovery, and a forced load produced a view (2026-09-28)

Ruling 1a required a real invocation record before calling this installed. That record now exists, obtained only after three earlier instruments were shown to be broken.

Measurement that counts (`tests/fm-show-me-skill.test.sh`, run with `FM_SHOW_ME_LIVE=1`):

| Assertion | Result |
|---|---|
| A fixture git project holding only `.agents/skills/show-me/`, asked to force-load the skill | the delivered user message begins `<skill name="show-me" location=".../.agents/skills/show-me/SKILL.md">` - **FOUND** |
| The same command in a project holding no skills directory | the raw text passes through unexpanded - **MISSING** |
| The body's own visible anchor, never typed into any prompt | present in the injected message, so the arrival came from the discovered file |
| An ordinary prompt in the fixture project | no `<name>show-me</name>` in the listing, so manual-only still costs nothing per session |
| The working note's separate anchor | absent from the injection, so a forced load brings the body alone |

Real invocation producing the deliverable: in that fixture project, `/skill:show-me` plus one collection-defect ask returned a sequence-shaped view of seven nodes and seven edges, two defect points named, missing edges drawn explicitly, and every unverified node labelled `to confirm`.
The reply opened by stating it was the reduced text form and that no image had been delivered, which is the rank-2 honesty rule behaving as written rather than being quoted.

How the answer is read, and why the earlier probes lied: `tests/pi-stream-user-text.cjs` parses the harness's own json stream and takes the first **message event** whose role is user.
Three dead ends are recorded here because each produced a confident wrong answer:

- Asking a model whether a token appears in its own message confirmed a token that exists nowhere on the machine. Model self-report is not an instrument; the character-count variant of the same question did behave correctly, so the failure is specific to self-description.
- A marker inside an HTML comment could never be seen: comments are stripped from injected bodies, and the prompt echoing the question supplied the token anyway. Anchors must sit in visible prose, one unique string per file.
- Reading the stream's first record found the pre-flight `prompt` echo instead of the delivered message, and serializing a content array left inner quotes escaped so a plain needle missed. Both made a genuine load read as MISSING.

Trust precondition, stated because it bounds the result: pi collects project `.agents/skills/` directories only while the project is trusted (`package-manager.js`, `collectAncestorAgentsSkillDirs` gated on `isProjectTrusted()`), and these runs passed `--approve`, whose help documents it as trusting project-local files for one run.
A firstmate home already carries a saved decision for its own path, and the control run in this repository enumerated its internal skills without any flag. What remains unproven is the interactive pane itself: no live TUI session was opened to watch `/skill:show-me` resolve there.

## Not proven

One item previously listed here is now measured and moved to the section above: discovery of the internal `.agents/skills/show-me/` copy.

- End-to-end delivery of a rendered diagram to a captain's WeChat conversation. Attempted twice from this task, including with a real rendered PNG sitting in the project directory, and both attempts returned `微信桥接未启动，请先在 TUI 执行 /wechat start`.
  The renderer and the tool contract are proven; the round trip is not, and it needs a session whose bridge is started.
- Any harness besides pi: claude, codex, opencode, grok, kimi, cursor, omp, and the rest of firstmate's verified adapters were not exercised for this skill.
- Whether `chrome-devtools-axi` or the interactive board tool is reachable in a given session; neither was available in the sessions that produced this record.
- Rendering quality at realistic diagram sizes, and whether an attached HTML file previews usefully on a phone.

## Reproducing these probes

The portable regression is [`tests/fm-show-me-skill.test.sh`](../../tests/fm-show-me-skill.test.sh); run it with `bash tests/fm-show-me-skill.test.sh`.
It hashes the shipped public body against the pinned upstream fingerprint on every host, compares the real upstream bytes only when this home still holds the private retrieval copy under `data/` (gitignored, so CI compares the fingerprint alone), and asserts the delivery rules in the adaptation text. None of it spends a model token; it finishes in about a tenth of a second.
It does not ask the loader question at all unless opted in: `fm_live_gate opt-in` exits successfully at the opt-in check, before it looks for pi, so a default run skips the guard whether or not pi is installed.
The loader observations above come from the same file's live guard, which submits prompts and therefore sits behind `FM_SHOW_ME_LIVE=1` per `tests/lib.sh`'s `fm_live_gate`.
Run it after a pi upgrade with `FM_SHOW_ME_LIVE=1 bash tests/fm-show-me-skill.test.sh`.
That guard must stay last in the file: a skipped `fm_live_gate` exits the script successfully, so anything appended after it would stop running without ever failing.
When the guard does run, it refuses to convert a provider quota refusal into a pass and reports it as a failure instead.

## Refreshing this record

Re-run the three commands above in a session whose provider quota is available and whose WeChat bridge is started, then update the dated rows.
The structural claims (`disable-model-invocation` filtering, single-file expansion, discovery locations) refresh by reading the installed pi package's `dist/core/skills.js` and `dist/core/agent-session.js` for the version in use.
