# Firstmate delivery adaptation for `show-me`

This is firstmate's own text; it is not part of the upstream skill body.
Read [UPSTREAM.md](UPSTREAM.md) for provenance and license.

The vendored [SKILL.md](SKILL.md) states how to communicate visually: skip the preamble, pick the smallest view that makes the point, and use one view type per judgement.
It ends by telling the reader to write an HTML file and open it in a browser with `Bash(open …)`.
That last instruction is the only thing here that does not survive contact with a firstmate captain, who reads answers in WeChat rather than in a browser tab.
This file replaces the delivery surface and nothing else.
It does not change which view to pick or when a view earns its cost.

## 1. Replace the delivery surface

Rule: a visual that the captain never receives did not happen.
Never substitute a filesystem path, a filename, or "I wrote it to X" for delivery; a path is at best a pointer the captain cannot open on a phone.

Try these in order and stop at the first that actually lands.

| Rank | Surface | Use it for | Verified behaviour |
|---|---|---|---|
| 1 | Image sent into the conversation | One view the captain can read at a glance: a sequence diagram, a call tree, a diff-shaped sketch | Tool `send_image_to_wechat`, parameter `imagePath`, accepts png/jpg/gif/webp and only paths inside the session's project directory |
| 2 | Interactive decision board (`lavish-axi`) | Comparing several options side by side, or a view the captain needs to expand and compare rather than glance at | Named in firstmate's supervisor contract as the visual-decisions and reports tool |
| 3 | Minimal structured text in chat | Fallback when neither surface can deliver | Always available; see the shape below |

### Getting an image out of the upstream HTML instruction

The upstream HTML artifact is still the right container for a dense view; it simply has to become pixels before it is useful here.
With no renderer installed, the cheapest measured path reuses a browser already on the machine:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=<width>,<height> \
  --screenshot=<project-dir>/out.png file://<abs>/show-me-<description>.html
```

This was run against a real file on macOS and produced a 384x140 PNG (5.9 KB), so it needs no new package.
Two constraints come from the delivery tool, not from the renderer: the image must be rasterised (an `.html` file is not an accepted image format) and it must live inside the session's project directory.
Mermaid source can be embedded as SVG in that HTML page and rasterised the same way, which keeps the upstream menu intact.
Do not install npm or pip packages to make rendering prettier; if the cheap path produces something unreadable, fall back to rank 3 instead of adding a dependency.

### Honest fallback shape

When rank 1 and rank 2 both fail - no bridge running, no board tool, no display path - say which one failed, then send the structure as text: the node list, the edge list, and the open questions, in short lines.
Say plainly that the picture itself did not reach the captain, so he knows he is reading the reduced form rather than the intended view.

## 2. Which view answers which judgement

Each view type helps exactly one kind of judgement; producing two for the same question is the cost the upstream skill warns about.
These three bindings are the ones worth spending a picture on in this fleet.

| Judgement in front of you | View | Checkpoints the view must expose |
|---|---|---|
| A collection, measurement, or time-anchor defect ("the number is wrong", "the event is missing", "the mark landed out of order") | Sequence diagram over pseudocode | Was the write committed before it was read; primary or cache; did the event fire before or after the commit; was a version or revision compared at all |
| Reviewing a PR with no CI backing it | Diff shape plus risk path, per the upstream `diff` bullet | New entry point, then the permission check, then the write, then any outbound message, then cache invalidation, then the failure branch |
| A choice the captain has to make between options (a threshold, a setting, a variant) | Comparison view, delivered as the rank-2 board rather than a long markdown table | The options as columns, the consequence of each, and which option each row rules out |

Static views miss dynamic behaviour and failure paths, which is exactly where this fleet's defects have been living.
So a view is navigation, not approval: label every node you did not personally verify as **to confirm**, and keep that label visible in the fallback text too.
A view with unverified nodes drawn as settled is worse than no view, because it reads like a verdict.

## 3. Cost discipline

Extra standing instructions are not free; the upstream author's own estimate is that a prompt budget raises reasoning cost noticeably, and firstmate's experience agrees.

- This skill stays manual-only.
  Upstream ships `disable-model-invocation: true` and firstmate keeps it; verified against pi 0.84.2, that flag hides the skill from the system prompt entirely, so it costs context only when a human invokes it.
- Do not wire it into the supervision chain, do not add it to any per-turn briefing, and do not reference it from a generated worker brief.
  If it ever needs to be reachable automatically, that is a deliberate decision to pay the per-session tax, not a convenience.
- Trial window: two weeks on medium-complexity work, judging one view type at a time.
  Keep the view types that measurably prevented a rework; delete the ones that did not, using the removal note below.
- Removing the whole thing is one step: delete `skills/show-me/`.
  There is no script, no config entry, no installer hook, and no state file, so deletion leaves no residue.

## 4. How to invoke it, and what remains unverified

Verified facts about the installed harness:

- Pi discovers a skill as any directory containing `SKILL.md`, recursively, under `.agents/skills/` in the project and its ancestors, under `.pi/skills/`, under the global agent skill directories, or through an explicit `--skill <path>`; confirmed from pi 0.84.2's own skills documentation and loader source.
- `skills/` at a repository root is **not** one of those discovery locations.
  So this directory is an installer-facing public surface, and it loads in a given session only after something installs it into a discovered location or passes it with `--skill`.
- Project-local discovery (`.agents/skills/…`) applies only after the project is trusted for that session.
- Explicit `--skill` loading works from this session: a non-interactive run pointed at this directory started and completed cleanly.
- `/skill:<name>` expands to the full body of that skill's single `SKILL.md` file, with relative references resolved against the skill directory.

Unverified combinations; do not document or advertise these as supported until they are actually run:

- Whether `/skill:show-me` resolves inside a real interactive firstmate session, as opposed to registering in principle.
  A forced-load attempt in a disposable project copy was blocked by a model-quota refusal before it could answer, so the invocation itself is recorded as expected-but-unproven.
- Any harness other than pi: Claude Code, Codex, opencode, grok, kimi, cursor, omp and the rest named in firstmate's contract were not exercised for this skill.
- Whether `chrome-devtools-axi` or `lavish-axi` is present in a given session; both were unavailable in the session that wrote this file, which is why rank 1's fallback wording is written first.
- Rendering quality at real diagram sizes, and whether HTML attached as a chat file previews usefully on a phone; only the small proof-of-concept PNG was measured.

If skill auto-discovery is not available in your harness, use one of these instead, in preference order:

1. Install this directory into a location your harness does discover, then invoke it by name.
2. Pass it explicitly: `pi --skill <repo>/skills/show-me`.
3. Paste the ask with the file attached, e.g. "read skills/show-me/SKILL.md and apply it to <topic>", which works in any harness that can read a file and needs no discovery at all.
4. As a prompt template: copy the body into a session-start append. Understand that this pays the standing-instruction cost section 3 warns about and defeats manual-only triggering, so treat it as an experiment to measure, not a default.
