# Firstmate delivery adaptation for `show-me`

This is firstmate's own text; it is not part of the upstream skill body.
Read [UPSTREAM.md](../../../skills/show-me/UPSTREAM.md) for provenance and license.

The vendored public body at `skills/show-me/SKILL.md` - kept byte-for-byte identical to upstream and never edited locally - states how to communicate visually: skip the preamble, pick the smallest view that makes the point, and use one view type per judgement.
Its forced-load injection reaches only that `SKILL.md`, which is why this note links out rather than assuming a reader has seen either file.
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
| 2 | Minimal structured text in chat | Fallback when no image surface can deliver | Always available; see the shape below |

### Getting an image out of the upstream HTML instruction

The upstream HTML artifact is still the right container for a dense view; it simply has to become pixels before it is useful here.
With no renderer installed, the cheapest measured path reuses a browser already on the machine:

```bash
tmpdir=$(mktemp -d)
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --window-size=<width>,<height> \
  --screenshot="$tmpdir/out.png" "file://$tmpdir/show-me-<description>.html"
cp "$tmpdir/out.png" scratchpad-show-me.png   # an already-ignored project path
# ...send scratchpad-show-me.png, then clean up in the same turn:
rm -f scratchpad-show-me.png && rm -rf "$tmpdir"
```

Cleanup is part of the recipe, not an afterthought.
Never leave a rendered artifact where the landing checks would call the local copy dirty: untracked files count as dirt there, so a stray `out.png` at the project root blocks landing and invites a forced cleanup.

This was run against a real file on macOS and produced a 384x140 PNG (5.9 KB), so it needs no new package.
Two constraints come from the delivery tool, not from the renderer: the image must be rasterised (an `.html` file is not an accepted image format) and it must live inside the session's project directory.
Mermaid source can be embedded as SVG in that HTML page and rasterised the same way, which keeps the upstream menu intact.
Do not install npm or pip packages to make rendering prettier; if the cheap path produces something unreadable, fall back to rank 2 instead of adding a dependency.

### Honest fallback shape (rank 2)

When rank 1 fails - no bridge running, no display path - say so, then send the structure as text: the node list, the edge list, and the open questions, in short lines.
Say plainly that the picture itself did not reach the captain, so he knows he is reading the reduced form rather than the intended view.

## 2. Which view answers which judgement

Each view type helps exactly one kind of judgement; producing two for the same question is the cost the upstream skill warns about.
These three bindings are the ones worth spending a picture on in this fleet.

| Judgement in front of you | View | Checkpoints the view must expose |
|---|---|---|
| A collection, measurement, or time-anchor defect ("the number is wrong", "the event is missing", "the mark landed out of order") | Sequence diagram over pseudocode | Was the write committed before it was read; primary or cache; did the event fire before or after the commit; was a version or revision compared at all |
| Reviewing a PR with no CI backing it | Diff shape plus risk path, per the upstream `diff` bullet | New entry point, then the permission check, then the write, then any outbound message, then cache invalidation, then the failure branch |
| A choice the captain has to make between options (a threshold, a setting, a variant) | Comparison view, delivered as rank 1's image or rank 2's short text table - never a long markdown wall | The options as columns, the consequence of each, and which option each row rules out |

Static views miss dynamic behaviour and failure paths, which is exactly where this fleet's defects have been living.
So a view is navigation, not approval: label every node you did not personally verify as **to confirm**, and keep that label visible in the fallback text too.
A view with unverified nodes drawn as settled is worse than no view, because it reads like a verdict.

## 3. Cost discipline

Extra standing instructions are not free; the upstream author's own estimate is that a prompt budget raises reasoning cost noticeably, and firstmate's experience agrees.

- This skill stays manual-only.
  Upstream ships `disable-model-invocation: true` and firstmate keeps it; measured on the installed harness, that flag keeps the skill out of the system prompt entirely, so it costs context only when a human invokes it.
- Do not wire it into the supervision chain, do not add it to any per-turn briefing, and do not reference it from a generated worker brief.
  If it ever needs to be reachable automatically, that is a deliberate decision to pay the per-session tax, not a convenience.
- Trial window: two weeks on medium-complexity work, judging one view type at a time.
  Keep the view types that measurably prevented a rework; delete the ones that did not, using the removal note below.
- Removing the whole thing is one step: delete `.agents/skills/show-me/`.
  There is no script, no config entry, no installer hook, and no state file, so deletion leaves no residue.
  Deleting only the public `skills/show-me/` directory stops installation but leaves this loaded adaptation standing.

## 4. How to invoke it, and what is measured

This file is a working note for the adaptation in [SKILL.md](SKILL.md); section 4 of that file owns the invocation routes.
Read them together rather than trusting either alone, because SKILL.md now carries the honest labels and the failed discoverability probe.

Facts kept here because they were actually run against the installed harness:

- Skill loading excludes any skill whose frontmatter sets `disable-model-invocation: true` from the system prompt; confirmed from the harness's own skills documentation and its loader, which filters on that flag. That is why this skill costs context only when a human invokes it.
- A forced load injects only the `SKILL.md` of the matched skill directory; sibling files such as this one arrive only if read explicitly. Every cross-reference is therefore a link, never an assumption.
- Invocation keys on the **leading token** of the message: `/skill:show-me` must come first, and prose that merely names it loads nothing.
- Registration and discovery are separate claims: with no registration the command resolves to nothing, while a registered copy injects its body.
- Explicit `--skill <path>` loading was measured to start and complete cleanly.

Unverified combinations; do not describe these as supported until they are actually run:

- Whether an internal `.agents/skills/show-me/` copy is discovered in a real session - see SKILL.md section 5, which records the probes that returned nothing and why they do not settle the question.
- Whether `/skill:show-me` resolves inside a live interactive firstmate pane; every measurement used non-interactive runs against project copies.
- Any harness other than pi: claude, codex, opencode, grok, kimi, cursor, omp and the rest named in the supervisor contract were not exercised for this skill.
- Whether `chrome-devtools-axi` or the interactive board tool is present in a given session; neither was available in the sessions that wrote these notes.
- Rendering quality at realistic diagram sizes, and whether an attached HTML file previews usefully on a phone; only the small proof-of-concept PNG was measured.
