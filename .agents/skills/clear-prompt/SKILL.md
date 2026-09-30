---
name: clear-prompt
description: >-
  Agent-only procedure for filling the CLEAR block on a crewmate brief.
  Load before filling any crewmate brief.
  Owns how Context, Layout, Examples, Audience, Role, Fallback, and Evidence are written for that job.
user-invocable: false
metadata:
  internal: true
---

# clear-prompt

Load this before filling the `## CLEAR` block on any ship or scout brief.
`bin/fm-brief.sh` scaffolds that block as `{CLEAR}`.
`bin/fm-dod-lib.sh` owns detection of an unfilled block, and `bin/fm-spawn.sh` refuses the launch and names the missing piece.
A secondmate charter has no CLEAR block.

Replace `{CLEAR}` with seven lines.
Each line is one of Context, Layout, Examples, Audience, Role, Fallback, and Evidence, then a colon, then real text for this job.
Do not leave the scaffold token as a field's only text.
Do not paste the blank Helix Craft sheet.
The practice note to read, not copy, is `practice/clear-prompt.md` in the helix-craft repo.

Role matches the job.
A client page, a proposal, or a statement of work is a writer.
Name the real reader, and include an example of the voice.
A code change is a careful builder.
Do not reuse a writer role on a build, or a builder role on a page.

Context says why this job matters now and what done looks like.
Layout says the shape of the output.
Examples point at a real sample of the voice or the pattern to match.
Audience names who reads the result and what they use it to decide.
Fallback says what to do when a fact is missing: flag it, and do not invent it.
Evidence names the claims to check before calling the work done.

A brief written before this scaffold has no `## CLEAR` heading.
Leave that brief alone so an in-flight relaunch still starts.
The start refuses a heading that is present and unfilled.
A new brief whose heading was removed cannot be told apart from one of those older briefs, so that case is not refused.
